import Foundation

/// A Claude Code background job (`claude --bg`), as listed by `claude agents --json`.
public struct BackgroundAgent: Equatable, Sendable {
    public var id: String
    public var sessionId: String
    public var name: String
    public var cwd: String
    public var state: String
    public var needs: String?
    public var detail: String?
    /// Last state change (the job's state.json `updatedAt`, else its start).
    public var updatedAt: Date?
    /// What the job is doing right now (state.json `tempo`, else the list's `status`). `state` is the
    /// job's standing as a whole ("working" on a weekend-long task, "blocked" while a new turn runs).
    public var tempo: String?
    /// Background tasks the job still runs (state.json `inFlight`: shells, monitors).
    public var inFlight: Int = 0

    public var activity: Activity {
        switch tempo {
        case "active", "busy", "working", "running": return .working
        case "blocked": return .needsInput
        case "idle":
            // The turn is over. Still running scripts: working; an open question: needs input;
            // otherwise done, whatever the job's overall standing says.
            if inFlight > 0 { return .working }
            if state == "blocked", let needs, !needs.isEmpty { return .needsInput }
            switch state {
            case "failed", "error": return .error
            case "stopped": return .exited
            default: return .done
            }
        default: break
        }
        switch state {
        case "working", "running", "busy": return .working
        case "blocked", "waiting", "needs_input": return .needsInput
        case "done", "completed", "idle": return .done
        case "failed", "error": return .error
        case "stopped": return .exited
        default: return .idle
        }
    }

    public var attachCommand: String { "claude attach \(shellQuote(id))" }
}

/// Lists background agents. Triggered by FSEvents on ~/.claude/jobs, never polled.
public enum BackgroundAgents {
    public static var jobsDir: URL {
        let claudeDir = ShellEnvironment.value("CLAUDE_CONFIG_DIR").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return claudeDir.appendingPathComponent("jobs")
    }

    /// Where installers put `claude` when the login shell's PATH doesn't have it (native installer,
    /// Homebrew, npm/volta/bun global bins).
    public static func fallbackDirs(home: String) -> [String] {
        ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin",
         "\(home)/.npm-global/bin", "\(home)/.volta/bin", "\(home)/.bun/bin"]
    }

    /// `claude` on the login shell's PATH (absolute entries only: relative ones would resolve against
    /// Corral's own directory), else in `fallbacks`. A file, never a folder named claude.
    public static func claudeBinary(path: String? = ShellEnvironment.value("PATH"),
                                    fallbacks: [String] = fallbackDirs(home: FileManager.default.homeDirectoryForCurrentUser.path))
        -> String? {
        let dirs = (path ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") } + fallbacks
        return dirs.lazy.map { ($0 as NSString).appendingPathComponent("claude") }.first { candidate in
            var dir: ObjCBool = false
            return FileManager.default.fileExists(atPath: candidate, isDirectory: &dir) && !dir.boolValue
                && FileManager.default.isExecutableFile(atPath: candidate)
        }
    }

    /// Runs `claude agents --json` off the main thread; completion on main. With the login shell's
    /// PATH: an npm-installed `claude` is a `#!/usr/bin/env node` script.
    public static func load(binary: String? = claudeBinary(), jobsDir: URL = jobsDir,
                            completion: @escaping ([BackgroundAgent]) -> Void) {
        guard let bin = binary else { DispatchQueue.main.async { completion([]) }; return }
        let environment = ShellEnvironment.childEnvironment(first: (bin as NSString).deletingLastPathComponent)
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.environment = environment
            p.arguments = ["agents", "--json"]
            p.standardInput = FileHandle.nullDevice
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            var agents: [BackgroundAgent] = []
            do {
                try p.run()
                // A hung CLI must not wedge the refresh forever.
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: killer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                agents = parse(data, jobsDir: jobsDir)
            } catch {
                NSLog("Corral: claude agents failed: \(error)")
            }
            DispatchQueue.main.async { completion(agents) }
        }
    }

    public static func parse(_ data: Data, jobsDir: URL) -> [BackgroundAgent] {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap { a in
            guard a["kind"] as? String == "background", let id = a["id"] as? String else { return nil }
            let agent = BackgroundAgent(
                id: id, sessionId: a["sessionId"] as? String ?? id,
                name: (a["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id,
                cwd: a["cwd"] as? String ?? NSHomeDirectory(),
                state: a["state"] as? String ?? "unknown",
                updatedAt: TranscriptIndexer.timestamp(a["startedAt"]).map(Date.init(timeIntervalSince1970:)),
                tempo: a["status"] as? String)
            return refreshState(agent, jobsDir: jobsDir)
        }
    }

    /// Updates state / needs / detail from the job's state.json (cheap, no process spawn).
    public static func refreshState(_ agent: BackgroundAgent, jobsDir: URL) -> BackgroundAgent {
        var agent = agent
        let stateFile = jobsDir.appendingPathComponent(agent.id).appendingPathComponent("state.json")
        guard let d = try? Data(contentsOf: stateFile),
              let job = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return agent }
        agent.needs = job["needs"] as? String
        agent.detail = job["detail"] as? String
        if let s = job["state"] as? String { agent.state = s }
        if let t = job["tempo"] as? String { agent.tempo = t }
        if let f = job["inFlight"] as? [String: Any] {
            agent.inFlight = ((f["tasks"] as? Int) ?? 0) + ((f["queued"] as? Int) ?? 0)
        }
        if let t = TranscriptIndexer.timestamp(job["updatedAt"]) { agent.updatedAt = Date(timeIntervalSince1970: t) }
        return agent
    }
}
