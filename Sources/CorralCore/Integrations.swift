import Foundation

/// Installs the small agent-side pieces that report status to Corral.
/// All of them are no-ops outside Corral terminals (they check CORRAL_SURFACE_ID / CORRAL_HOOK).
public enum Integrations {
    public struct Status: Equatable, Sendable {
        public var claude: Bool
        public var opencode: Bool
        public var pi: Bool
        public var allInstalled: Bool { claude && opencode && pi }

        public init(claude: Bool, opencode: Bool, pi: Bool) {
            self.claude = claude
            self.opencode = opencode
            self.pi = pi
        }

        public func installed(_ agent: AgentKind) -> Bool {
            switch agent {
            case .shell: return true
            case .claude: return claude
            case .opencode: return opencode
            case .pi: return pi
            }
        }
    }

    /// Hook events Corral listens to.
    public static let claudeEvents = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PostToolUse", "PermissionRequest",
        "Notification", "Stop", "StopFailure", "PreCompact",
    ]
    /// Runs only inside Corral, where CORRAL_HOOK points at the bundled corral-hook binary.
    /// The event name is passed as an argument so the hook never has to parse JSON.
    public static func claudeCommand(_ event: String) -> String {
        "[ -z \"$CORRAL_HOOK\" ] || \"$CORRAL_HOOK\" claude \(event)"
    }
    static let marker = "CORRAL_HOOK"

    public struct Paths {
        public var claudeSettings: URL
        public var opencodePluginDir: URL
        public var piExtensionDir: URL

        public init(claudeSettings: URL, opencodePluginDir: URL, piExtensionDir: URL) {
            self.claudeSettings = claudeSettings
            self.opencodePluginDir = opencodePluginDir
            self.piExtensionDir = piExtensionDir
        }

        public static var standard: Paths {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let claudeDir = ShellEnvironment.value("CLAUDE_CONFIG_DIR").map { URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".claude")
            let ocConfig = home.appendingPathComponent(".config/opencode")
            // OpenCode loads "plugin" or "plugins"; this machine uses "Plugins" (case-insensitive FS).
            let existing = ["Plugins", "plugins", "plugin"].map { ocConfig.appendingPathComponent($0) }
                .first { FileManager.default.fileExists(atPath: $0.path) }
            return Paths(
                claudeSettings: claudeDir.appendingPathComponent("settings.json"),
                opencodePluginDir: existing ?? ocConfig.appendingPathComponent("plugins"),
                piExtensionDir: home.appendingPathComponent(".pi/agent/extensions"))
        }
    }

    /// Whether the agent seems to be set up on this Mac: its config folder exists (~/.claude,
    /// ~/.config/opencode, ~/.pi). Integrations are only offered for agents that are.
    public static func toolPresent(_ agent: AgentKind, paths: Paths = .standard) -> Bool {
        let fm = FileManager.default
        switch agent {
        case .shell: return true
        case .claude: return fm.fileExists(atPath: paths.claudeSettings.deletingLastPathComponent().path)
        case .opencode: return fm.fileExists(atPath: paths.opencodePluginDir.deletingLastPathComponent().path)
        case .pi: return fm.fileExists(atPath: paths.piExtensionDir.deletingLastPathComponent().deletingLastPathComponent().path)
        }
    }

    /// Installed on this Mac: its config folder exists or its command is on `path` (the login shell's
    /// PATH) or in `fallbacks`. Menus offer only installed agents; Settings greys out the rest. Hooks
    /// are offered by the stricter `toolPresent` (the agent has run here).
    public static func installed(_ agent: AgentKind, paths: Paths = .standard,
                                 path: String? = ShellEnvironment.value("PATH"),
                                 fallbacks: [String] = BackgroundAgents.defaultFallbacks) -> Bool {
        guard let command = agent.launchCommand else { return true }
        return toolPresent(agent, paths: paths) || BackgroundAgents.command(command, path: path, fallbacks: fallbacks) != nil
    }

    public static func status(paths: Paths = .standard) -> Status {
        let settings = (try? String(contentsOf: paths.claudeSettings, encoding: .utf8)) ?? ""
        let fm = FileManager.default
        return Status(
            claude: claudeEvents.allSatisfy { ev in hooksJSON(settings, event: ev) },
            opencode: fm.fileExists(atPath: paths.opencodePluginDir.appendingPathComponent("corral.js").path),
            pi: fm.fileExists(atPath: paths.piExtensionDir.appendingPathComponent("corral.ts").path))
    }

    private static func hooksJSON(_ settings: String, event: String) -> Bool {
        guard let data = settings.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = obj["hooks"] as? [String: Any], let groups = hooks[event] as? [[String: Any]] else { return false }
        return groups.contains { group in
            (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(marker) == true }
        }
    }

    public struct InstallError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Merges Corral's hooks into Claude's settings.json (backup kept next to it). Idempotent.
    /// Refuses rather than guesses: unreadable files and unexpected shapes throw and leave the file alone.
    /// Symlinks are followed (dotfile setups) and the original permissions are kept.
    public static func installClaude(settingsURL: URL) throws -> URL? {
        try rewriteSettings(settingsURL, mergeHooks(into:))
    }

    /// Takes Corral's hooks out of Claude's settings.json (backup kept next to it); everything else stays
    /// as it was. Returns the backup, or nil when there were none.
    public static func uninstallClaude(settingsURL: URL) throws -> URL? {
        try rewriteSettings(settingsURL, removeHooks(from:))
    }

    /// Applies `change` to settings.json (nil: nothing to do) with a backup of the old file.
    static func rewriteSettings(_ settingsURL: URL, _ change: ([String: Any]) throws -> [String: Any]?) throws -> URL? {
        let target = settingsURL.resolvingSymlinksInPath()
        let fm = FileManager.default
        var attempts = 0
        while true {
            attempts += 1
            let original = try readIfPresent(target)
            var root: [String: Any] = [:]
            if let original, !original.isEmpty {
                guard let obj = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                    throw InstallError(message: "\(target.path) is not a JSON object")
                }
                root = obj
            }
            guard let merged = try change(root) else { return nil }
            let out = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])

            // Claude may rewrite settings.json (e.g. "don't ask again"); merge again if it changed meanwhile.
            if try readIfPresent(target) != original {
                if attempts < 3 { continue }
                throw InstallError(message: "\(target.path) keeps changing; try again")
            }
            let perms = (try? fm.attributesOfItem(atPath: target.path)[.posixPermissions]) as? NSNumber
            var backup: URL?
            if let original {
                let b = target.deletingLastPathComponent()
                    .appendingPathComponent("\(target.lastPathComponent).corral-backup-\(Int(Date().timeIntervalSince1970))")
                try original.write(to: b)
                if let perms { try fm.setAttributes([.posixPermissions: perms], ofItemAtPath: b.path) }
                backup = b
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try out.write(to: target, options: .atomic)
            if let perms { try fm.setAttributes([.posixPermissions: perms], ofItemAtPath: target.path) }
            return backup
        }
    }

    /// nil when the file doesn't exist; throws for any other read problem.
    static func readIfPresent(_ url: URL) throws -> Data? {
        var st = stat()
        if lstat(url.path, &st) != 0 {
            if errno == ENOENT { return nil }
            throw InstallError(message: "\(url.path): \(String(cString: strerror(errno)))")
        }
        return try Data(contentsOf: url)
    }

    /// Returns the settings with Corral's hooks added, or nil when nothing is missing.
    static func mergeHooks(into root: [String: Any]) throws -> [String: Any]? {
        var root = root
        var hooks: [String: Any] = [:]
        if let existing = root["hooks"] {
            guard let dict = existing as? [String: Any] else {
                throw InstallError(message: "\"hooks\" in settings.json is not an object; not touching it")
            }
            hooks = dict
        }
        var changed = false
        for event in claudeEvents {
            var groups: [[String: Any]] = []
            if let existing = hooks[event] {
                guard let list = existing as? [[String: Any]] else {
                    throw InstallError(message: "hooks.\(event) in settings.json is not a list; not touching it")
                }
                groups = list
            }
            let present = groups.contains { g in
                (g["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(marker) == true }
            }
            if present { continue }
            var group: [String: Any] = ["hooks": [["type": "command", "command": claudeCommand(event), "timeout": 5]]]
            if event == "PostToolUse" { group["matcher"] = "*" }
            groups.append(group)
            hooks[event] = groups
            changed = true
        }
        guard changed else { return nil }
        root["hooks"] = hooks
        return root
    }

    /// Returns the settings without Corral's hook commands (groups and events left empty go too), or nil
    /// when there are none.
    static func removeHooks(from root: [String: Any]) throws -> [String: Any]? {
        guard let existing = root["hooks"] else { return nil }
        guard var hooks = existing as? [String: Any] else {
            throw InstallError(message: "\"hooks\" in settings.json is not an object; not touching it")
        }
        var changed = false
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept = groups.compactMap { group -> [String: Any]? in
                guard let list = group["hooks"] as? [[String: Any]] else { return group }
                let others = list.filter { ($0["command"] as? String)?.contains(marker) != true }
                guard others.count != list.count else { return group }
                changed = true
                if others.isEmpty { return nil }
                var group = group
                group["hooks"] = others
                return group
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        guard changed else { return nil }
        var root = root
        root["hooks"] = hooks.isEmpty ? nil : hooks
        return root
    }

    public static func installOpenCode(pluginDir: URL) throws {
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        try opencodePlugin.write(to: pluginDir.appendingPathComponent("corral.js"), atomically: true, encoding: .utf8)
    }

    public static func installPi(extensionDir: URL) throws {
        try FileManager.default.createDirectory(at: extensionDir, withIntermediateDirectories: true)
        try piExtension.write(to: extensionDir.appendingPathComponent("corral.ts"), atomically: true, encoding: .utf8)
    }

    public static func uninstallOpenCode(pluginDir: URL) throws {
        try removeOwnFile(pluginDir.appendingPathComponent("corral.js"))
    }

    public static func uninstallPi(extensionDir: URL) throws {
        try removeOwnFile(extensionDir.appendingPathComponent("corral.ts"))
    }

    /// Deletes a plugin file only when it is Corral's (its first line says so); a missing one is fine.
    static func removeOwnFile(_ url: URL) throws {
        guard let data = try readIfPresent(url) else { return }
        let first = String(decoding: data.prefix(200), as: UTF8.self)
        guard first.hasPrefix("// Corral status reporter") else {
            throw InstallError(message: "\(url.path) isn't Corral's; not removing it")
        }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: Agent-side sources

    public static let opencodePlugin = #"""
    // Corral status reporter for OpenCode. Installed by Corral; no-op outside Corral terminals.
    import net from "node:net"

    export const CorralPlugin = async ({ client }) => {
      const surface = process.env.CORRAL_SURFACE_ID
      const socketPath = process.env.CORRAL_SOCKET
      if (!surface || !socketPath) return {}

      const roots = new Map()
      const isRoot = async (id) => {
        if (!id) return false
        if (roots.has(id)) return roots.get(id)
        const r = await client.session.get({ path: { id } }).catch(() => undefined)
        if (!r?.data) return false  // unknown: never let it replace the resumable session id
        const root = !r.data.parentID
        roots.set(id, root)
        return root
      }
      const send = (event, payload) => {
        try {
          const s = net.createConnection(socketPath)
          s.on("error", () => {})
          s.end(JSON.stringify({ surface, agent: "opencode", event, payload: { cwd: process.cwd(), ...payload } }) + "\n")
        } catch {}
      }

      return {
        event: async ({ event }) => {
          const p = event.properties ?? {}
          const sid = p.sessionID ?? p.info?.id
          switch (event.type) {
            case "session.created":
            case "session.updated":
              if (p.info && !p.info.parentID) send(event.type, { session_id: p.info.id, title: p.info.title })
              break
            case "session.status":
              if (await isRoot(sid)) send(event.type, { session_id: sid, status: p.status?.type })
              break
            case "session.idle":
            case "session.error":
              if (await isRoot(sid)) send(event.type, { session_id: sid, message: p.error?.data?.message ?? p.error?.name })
              break
            // Sub-agents ask too: keep the needs-input signal, but only a root id may become the resume id.
            case "permission.asked":
            case "permission.updated":
              send(event.type, { session_id: (await isRoot(sid)) ? sid : undefined, message: p.title ?? p.permission ?? "Permission needed" })
              break
            case "permission.replied":
            case "question.asked":
            case "question.replied":
              send(event.type, { session_id: (await isRoot(sid)) ? sid : undefined, message: p.questions?.[0]?.question })
              break
          }
        },
      }
    }
    """#

    public static let piExtension = #"""
    // Corral status reporter for PI. Installed by Corral; no-op outside Corral terminals.
    import net from "node:net"

    export default function (pi: any) {
      const surface = process.env.CORRAL_SURFACE_ID
      const socketPath = process.env.CORRAL_SOCKET
      if (!surface || !socketPath) return

      const send = (event: string, ctx?: any, extra: Record<string, unknown> = {}) => {
        try {
          const sessionFile = ctx?.sessionManager?.getSessionFile?.()
          const s = net.createConnection(socketPath)
          s.on("error", () => {})
          s.end(JSON.stringify({
            surface, agent: "pi", event,
            payload: { session_id: sessionFile, cwd: ctx?.cwd ?? process.cwd(), ...extra },
          }) + "\n")
        } catch {}
      }

      for (const ev of ["session_start", "agent_start", "agent_end", "session_shutdown"]) {
        pi.on(ev, async (_event: any, ctx: any) => { send(ev, ctx) })
      }
    }
    """#
}
