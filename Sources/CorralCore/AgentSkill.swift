import Foundation

/// The SKILL.md that teaches agents the `corral` command, and where it goes. Claude Code and OpenCode
/// read `<skills>/<name>/SKILL.md`.
public enum AgentSkill {
    public static let name = "corral"

    public enum Target: Equatable, CaseIterable, Sendable {
        case claudeCode, openCode

        public var title: String {
            switch self {
            case .claudeCode: return "Claude Code"
            case .openCode: return "OpenCode"
            }
        }

        /// The agent's skills folder. `claudeDir`: Claude's config folder when it isn't `~/.claude`.
        public func skillsFolder(home: URL, claudeDir: URL? = nil) -> URL {
            switch self {
            case .claudeCode: return (claudeDir ?? home.appendingPathComponent(".claude")).appendingPathComponent("skills", isDirectory: true)
            case .openCode: return home.appendingPathComponent(".config/opencode/skills", isDirectory: true)
            }
        }
    }

    public struct InstallError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    static func file(in skills: URL) -> URL { skills.appendingPathComponent("\(name)/SKILL.md") }

    /// In the text, so another tool's skill of the same name is never taken for this one.
    static let marker = "<!-- Written by the Corral app; reinstalled on updates. -->"

    static func isOurs(_ file: URL) -> Bool {
        (try? String(contentsOf: file, encoding: .utf8))?.contains(marker) == true
    }

    public static func isInstalled(_ target: Target, home: URL, claudeDir: URL? = nil) -> Bool {
        isOurs(file(in: target.skillsFolder(home: home, claudeDir: claudeDir)))
    }

    /// Writes the skill into `skills` and points `~/.local/bin/corral` at `executable`. Returns SKILL.md.
    @discardableResult
    public static func install(into skills: URL, home: URL, executable: URL? = CommandLineLink.executable) throws -> URL {
        let file = file(in: skills)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: file.path) || isOurs(file) else {
            throw InstallError(message: "\(file.path) belongs to another skill named \(name).")
        }
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(markdown.utf8).write(to: file, options: .atomic)
        guard try CommandLineLink.ensure(home: home, executable: executable) else {
            throw InstallError(message: "The skill is in place, but the corral command couldn't be linked at "
                + "~/.local/bin/corral: something else is there, or Corral runs from a disk image. Move Corral to "
                + "Applications or remove that file, then install again.")
        }
        return file
    }

    /// `corral skill install [claude|opencode|FOLDER]`, from the command line (no login-shell lookup:
    /// CLAUDE_CONFIG_DIR is in the caller's environment).
    static func install(named target: String?, env: [String: String] = ProcessInfo.processInfo.environment,
                        home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        let claudeDir = env["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let skills: URL
        switch target {
        case nil, "claude": skills = Target.claudeCode.skillsFolder(home: home, claudeDir: claudeDir)
        case "opencode": skills = Target.openCode.skillsFolder(home: home)
        case let folder?: skills = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
        }
        return try install(into: skills, home: home)
    }

    /// At launch: installed copies follow the app's version of the text, and the link its location.
    public static func refreshInstalled(home: URL, claudeDir: URL? = nil, executable: URL? = CommandLineLink.executable) {
        var installed = false
        for target in Target.allCases {
            let file = file(in: target.skillsFolder(home: home, claudeDir: claudeDir))
            guard isOurs(file) else { continue }
            installed = true
            if (try? Data(contentsOf: file)) != Data(markdown.utf8) { try? Data(markdown.utf8).write(to: file, options: .atomic) }
        }
        let linked = (try? FileManager.default.destinationOfSymbolicLink(atPath: CommandLineLink.url(home: home).path)) != nil
        if installed || linked { _ = try? CommandLineLink.ensure(home: home, executable: executable) }
    }

    /// Static on purpose: no paths, user names or other details of this Mac (agents send skill text
    /// to their model provider).
    public static let markdown = """
    ---
    name: \(name)
    description: Start, watch and steer other agent sessions in Corral.
    ---
    \(marker)

    `c=~/.local/bin/corral` (starts Corral if needed; missing or "control is off": the user fixes it in Corral › Settings › Agents). `$c help` lists all; `--json` on any command; ids shorten to a unique prefix.

    ```sh
    $c spawn --model easy|medium|high --cwd DIR --name "Fix login test" --folder "Job/Checks" "PROMPT"   # prints the id, returns at once
    $c wait [ID…] [--done] [--timeout S]   # blocks until one needs permission or input, is done, failed or gone
    $c approve ID | deny ID                # permission prompt, or the folder trust question
    $c send ID "follow-up"                 # --raw 2: press keys only (menus)
    $c status ID | output ID [--screen] | list [--mine] | close ID
    $c folder list | move PATH ID… | collapse PATH | expand PATH | rename PATH NAME | delete PATH
    $c events [ID…] [--mine] [--json]      # every state change as a line, until interrupted (one watcher for many sessions)
    $c stats [ID]                          # tokens and flagged waste, if the user turned measuring on
    $c report [--fail] "one-line result"   # when another session started you: once, before your final answer
    ```

    - Spawn: the prompt must stand alone (goal, paths, what done looks like, what to report). Pick the cheapest tier that does the job, or name a model. `--trust` answers Claude's folder trust question with yes (only for folders the user works in). `--prompt-file F`, `--agent opencode|pi`, `--focus`, agent arguments after `--`.
    - Wait: without ids it watches what you started. Run it as a background command, handle the event, run it again; each event comes once. `--done` returns only at the end and leaves prompts to the user.
    - Events: `needs_permission` shows `request:` (tool and input); `needs_input` is a question (read it with `output ID --screen`); `done` has `result:` and the child's `report:`. From scripts `spawn --wait --done` blocks; exit status 0 done, 3 reported failed, 10 permission, 11 input, 12 error, 13 gone, 124 timeout.
    - You may approve, type into and close only sessions you started. Approve what you would run yourself for the task you gave; deny or leave the rest for the user.
    - Group what you start in folders and collapse what the user needn't see. Close sessions you are done with; don't spawn what you can do faster yourself.
    """
}

/// `~/.local/bin/corral` → the app binary: a fixed command for agents that names no user or folder.
/// Created with the skill, repointed at launch when the app moved. A real file there, or a link to
/// something that isn't a Corral app, is left alone.
public enum CommandLineLink {
    public static func url(home: URL) -> URL { home.appendingPathComponent(".local/bin/corral") }

    public static var executable: URL? { Bundle.main.executableURL?.resolvingSymlinksInPath() }

    @discardableResult
    public static func ensure(home: URL, executable: URL? = executable) throws -> Bool {
        // From the disk image or Downloads macOS runs the app from a temporary copy.
        guard let executable, !executable.path.contains("/AppTranslocation/") else { return false }
        let fm = FileManager.default
        let link = url(home: home)
        if let destination = try? fm.destinationOfSymbolicLink(atPath: link.path) {
            let target = URL(fileURLWithPath: destination, relativeTo: link.deletingLastPathComponent()).resolvingSymlinksInPath()
            if target.path == executable.path { return true }
            let dangling = !fm.fileExists(atPath: target.path)
            guard dangling || target.path.hasSuffix(".app/Contents/MacOS/\(executable.lastPathComponent)") else { return false }
            try fm.removeItem(at: link)
        } else if fm.fileExists(atPath: link.path) {
            return false
        }
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: executable)
        return true
    }
}
