import Foundation

/// The `corral` command: the app binary run with one of `commands` as its first argument. It only
/// parses, asks the running app over `ControlServer` and prints; it never starts any UI itself.
public enum CorralCLI {
    public static let commands: Set<String> = [
        "spawn", "list", "status", "wait", "approve", "deny", "send", "output", "close", "report", "stats", "folder", "events",
        "skill", "help",
    ]
    /// Exit status of `wait` and `spawn --wait`, by what the session did, so a script can branch on it.
    public static func exitStatus(state: String?, failed: Bool) -> Int32 {
        switch state {
        case "done": return failed ? 3 : 0
        case "needs_permission": return 10
        case "needs_input": return 11
        case "error": return 12
        case "exited", "closed": return 13
        default: return 0
        }
    }
    /// Exit status of `corral wait --timeout` when nothing happened in time (as timeout(1)).
    public static let timedOut: Int32 = 124
    /// The session a command is run from; unlike CORRAL_SURFACE_ID it reaches the agent's own commands.
    public static let sessionVariable = "CORRAL_SESSION"

    public struct UsageError: Error, Equatable {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    public struct Invocation {
        public var request: [String: Any]
        public var json = false
        /// `spawn --wait`: then wait for the new session's first event.
        public var thenWait = false
        /// With `thenWait`: only the session's end counts.
        public var final = false
        /// The exit status tells the session's state (`exitStatus`).
        public var statusFromState = false
        /// The app keeps answering, line by line (`events`).
        public var follows = false
        /// Seconds the app may take to answer; nil = as long as it takes (`wait`).
        public var timeout: TimeInterval? = 10
    }

    public enum Parsed {
        case help
        /// `skill install [claude|opencode|<folder>]`
        case skill(String?)
        case request(Invocation)
    }

    public static let usage = """
    corral: start and steer sessions in the Corral app

      corral spawn [--agent claude|opencode|pi] [--model easy|medium|high|NAME] [--cwd DIR]
                   [--name NAME] [--folder PATH] [--focus] [--trust] [--wait [--done]] [PROMPT | --prompt-file FILE|-] [-- AGENT ARGS]
      corral list [--mine]                 open sessions (--mine: the ones this session started)
      corral status ID                     state, and the request or result that goes with it
      corral wait [ID…] [--timeout S] [--done]   until a session needs permission or input, is done, failed
                                           or gone (--done: only when it is finished, failed or gone)
      corral approve ID | corral deny ID   answer a permission prompt
      corral send ID TEXT [--raw]          type a prompt and submit it (--raw: keys only, no Return; - reads stdin)
      corral output ID [--screen] [--lines N]   the last answer, or the terminal's screen
      corral close ID
      corral report [--fail] TEXT          from a started session: hand its result to whoever waits for it
      corral stats [ID]                    token use and flagged inefficiencies (Settings › Agents)
      corral events [ID…] [--mine]         every state change as it happens, one line each, until interrupted
      corral folder list | create PATH | move PATH ID… | collapse PATH | expand PATH
                    | rename PATH NAME | delete PATH
                                           sidebar folders; PATH is names from the top, like Monitoring/Disk
                                           (move makes missing folders, / is the top level; delete keeps the sessions)
      corral skill install [claude|opencode|FOLDER]

    IDs may be shortened to a unique prefix. --json prints the app's answer as JSON.
    Without IDs, wait watches the sessions started from the session it runs in.
    wait and spawn --wait exit with 0 done, 3 done but reported as failed, 10 needs permission,
    11 needs input, 12 error, 13 exited or closed, 124 timeout.
    """

    // MARK: Parsing

    public static func parse(_ args: [String], env: [String: String], cwd: String,
                             stdin: () -> String = { String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) },
                             readFile: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) throws -> Parsed {
        guard let command = args.first, command != "help", command != "--help", command != "-h" else { return .help }
        var rest = Array(args.dropFirst())
        var extra: [String] = []
        if command == "spawn", let split = rest.firstIndex(of: "--") {
            extra = Array(rest[(split + 1)...])
            rest = Array(rest[..<split])
        }
        var flags: Set<String> = []
        var values: [String: String] = [:]
        var positional: [String] = []
        let (takesValue, switches) = options(command)
        var i = 0
        while i < rest.count {
            let arg = rest[i]
            i += 1
            guard arg.hasPrefix("--"), arg.count > 2 else { positional.append(arg); continue }
            let name = String(arg.dropFirst(2))
            if name == "json" || switches.contains(name) {
                flags.insert(name)
            } else if takesValue.contains(name) {
                guard i < rest.count else { throw UsageError("--\(name) needs a value") }
                values[name] = rest[i]
                i += 1
            } else {
                throw UsageError("Unknown option \(arg) for corral \(command)")
            }
        }

        var request: [String: Any] = ["cmd": command]
        if let caller = env[sessionVariable], !caller.isEmpty { request["caller"] = caller }
        var call = Invocation(request: [:], json: flags.contains("json"))

        func oneId() throws -> String {
            guard let id = positional.first, positional.count == 1 else { throw UsageError("corral \(command) ID") }
            return id
        }

        switch command {
        case "spawn":
            request["agent"] = values["agent"] ?? "claude"
            if let model = values["model"] { request["model"] = model }
            request["cwd"] = values["cwd"].map { absolute($0, cwd: cwd) } ?? cwd
            if let name = values["name"] { request["name"] = name }
            if let folder = values["folder"] { request["folder"] = folder }
            if flags.contains("focus") { request["focus"] = true }
            if flags.contains("trust") { request["trust"] = true }
            if !extra.isEmpty { request["extra"] = extra }
            var prompt = positional.isEmpty ? nil : positional.joined(separator: " ")
            if let file = values["prompt-file"] {
                guard prompt == nil else { throw UsageError("Give the prompt as text or with --prompt-file, not both") }
                guard let text = file == "-" ? stdin() : readFile(absolute(file, cwd: cwd)) else {
                    throw UsageError("Can't read \(file)")
                }
                prompt = text
            }
            if let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty { request["prompt"] = prompt }
            call.thenWait = flags.contains("wait")
            guard call.thenWait || !flags.contains("done") else { throw UsageError("--done goes with --wait") }
            call.final = flags.contains("done")
        case "list":
            guard positional.isEmpty else { throw UsageError("corral list [--mine]") }
            if flags.contains("mine") { request["mine"] = true }
        case "status", "approve", "deny", "close":
            request["id"] = try oneId()
        case "wait":
            if !positional.isEmpty { request["ids"] = positional }
            if let t = values["timeout"] {
                guard let seconds = Double(t), seconds > 0 else { throw UsageError("--timeout takes seconds") }
                request["timeout"] = seconds
            }
            if flags.contains("done") { request["final"] = true }
            call.timeout = nil
            call.statusFromState = true
        case "report":
            guard request["caller"] != nil else { throw UsageError("corral report works inside a session Corral started") }
            let text = positional.count == 1 && positional[0] == "-" ? stdin() : positional.joined(separator: " ")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw UsageError("corral report [--fail] TEXT") }
            request["text"] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if flags.contains("fail") { request["failed"] = true }
        case "folder":
            let usage = UsageError("corral folder list | create PATH | move PATH ID… | collapse PATH | expand PATH | rename PATH NAME | delete PATH")
            guard let action = positional.first else { throw usage }
            let rest = Array(positional.dropFirst())
            request["action"] = action
            switch (action, rest.count) {
            case ("list", 0): break
            case ("create", 1), ("collapse", 1), ("expand", 1), ("delete", 1): request["path"] = rest[0]
            case ("rename", 2):
                request["path"] = rest[0]
                request["name"] = rest[1]
            case ("move", 2...):
                request["path"] = rest[0]
                request["ids"] = Array(rest.dropFirst())
            default: throw usage
            }
        case "events":
            if !positional.isEmpty { request["ids"] = positional }
            if flags.contains("mine") { request["mine"] = true }
            call.follows = true
        case "stats":
            guard positional.count <= 1 else { throw UsageError("corral stats [ID]") }
            if let id = positional.first { request["id"] = id }
            // Large transcripts take a while to read.
            call.timeout = nil
        case "send":
            guard let id = positional.first, positional.count >= 2 else { throw UsageError("corral send ID TEXT [--raw]") }
            request["id"] = id
            let words = positional.dropFirst()
            let text = words.count == 1 && words.first == "-" ? stdin() : words.joined(separator: " ")
            guard !text.isEmpty else { throw UsageError("Nothing to send") }
            request["text"] = text
            if flags.contains("raw") { request["raw"] = true }
        case "output":
            request["id"] = try oneId()
            if flags.contains("screen") { request["screen"] = true }
            if let n = values["lines"] {
                guard let lines = Int(n), lines > 0 else { throw UsageError("--lines takes a number") }
                request["lines"] = lines
            }
        case "skill":
            guard positional.first == "install", positional.count <= 2 else {
                throw UsageError("corral skill install [claude|opencode|FOLDER]")
            }
            return .skill(positional.count == 2 ? positional[1] : nil)
        default:
            throw UsageError("Unknown command \(command)")
        }
        call.request = request
        return .request(call)
    }

    private static func options(_ command: String) -> (values: Set<String>, switches: Set<String>) {
        switch command {
        case "spawn": return (["agent", "model", "cwd", "name", "folder", "prompt-file"], ["focus", "trust", "wait", "done"])
        case "list", "events": return ([], ["mine"])
        case "wait": return (["timeout"], ["done"])
        case "report": return ([], ["fail"])
        case "send": return ([], ["raw"])
        case "output": return (["lines"], ["screen"])
        default: return ([], [])
        }
    }

    private static func absolute(_ path: String, cwd: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? expanded : URL(fileURLWithPath: cwd).appendingPathComponent(expanded).standardized.path
    }

    // MARK: Output

    /// "1f3a9c2e  working  claude  Name: detail"
    public static func line(_ s: [String: Any]) -> String {
        let id = String((s["id"] as? String ?? "").prefix(8))
        var text = [id, s["state"] as? String ?? "?", s["agent"] as? String ?? "?", s["name"] as? String ?? ""]
            .joined(separator: "  ")
        if let detail = s["detail"] as? String, !detail.isEmpty { text += ": \(detail)" }
        if let folder = s["folder"] as? String { text += "  [\(folder)]" }
        return text
    }

    public static func render(_ answer: [String: Any]) -> String {
        var out: [String] = []
        if let sessions = answer["sessions"] as? [[String: Any]] {
            out += sessions.isEmpty ? ["No sessions."] : sessions.map(line)
        }
        for f in answer["folders"] as? [[String: Any]] ?? [] {
            let n = f["sessions"] as? Int ?? 0
            out.append("\(f["path"] as? String ?? "?")  (\(n) session\(n == 1 ? "" : "s")\(f["expanded"] as? Bool == false ? ", collapsed" : ""))")
        }
        if (answer["folders"] as? [[String: Any]])?.isEmpty == true { out.append("No folders.") }
        if let s = answer["session"] as? [String: Any] {
            out.append(line(s))
            if let model = s["model"] as? String { out.append("model: \(model)") }
            if let parent = s["parent"] as? String { out.append("started by: \(parent.prefix(8))") }
            if let cwd = s["cwd"] as? String { out.append("cwd: \(cwd)") }
        }
        if answer["timeout"] as? Bool == true { out.insert("Nothing happened in time.", at: 0) }
        if let input = answer["request"] as? String { out.append("request: \(input)") }
        if let report = answer["report"] as? [String: Any], let text = report["text"] as? String {
            out.append("report\(report["failed"] as? Bool == true ? " (failed)" : ""): \(text)")
        }
        if let screen = answer["screen"] as? String { out.append("screen:\n\(screen)") }
        if let result = answer["result"] as? String { out.append("result:\n\(result)") }
        for row in answer["stats"] as? [[String: Any]] ?? [] {
            if let s = row["session"] as? [String: Any] { out.append(line(s)) }
            if let stats = row["stats"] as? [String: Any] {
                out.append("  " + SessionAnalysis.summary(stats))
                for flag in stats["flags"] as? [String] ?? [] { out.append("  ! \(flag)") }
            } else {
                out.append("  no transcript to measure")
            }
        }
        if let text = answer["text"] as? String { out.append(text) }
        if let note = answer["note"] as? String { out.append(note) }
        return out.joined(separator: "\n")
    }

    // MARK: Running

    public struct IO {
        /// Flushed per line: into a pipe or file `events` would otherwise hold its lines back.
        public var out: (String) -> Void = { print($0); fflush(stdout) }
        public var err: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
        public var env: [String: String] = ProcessInfo.processInfo.environment
        public var cwd: String = FileManager.default.currentDirectoryPath
        public var request: ([String: Any], TimeInterval?) -> Result<[String: Any], ControlClient.Failure> = {
            ControlClient.request($0, timeout: $1)
        }
        /// Starts the app in the background; false when it can't.
        public var stream: ([String: Any], ([String: Any]) -> Bool) -> ControlClient.Failure? = {
            ControlClient.stream($0, each: $1)
        }
        public var launchApp: () -> Bool = CorralCLI.launchApp
        /// Corral runs (its hook socket answers) even though the control socket doesn't: control is off.
        public var appRunning: () -> Bool = { UnixSocket.answers(CorralPaths.socket.path) }
        public var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
        public var installSkill: (String?) throws -> String = { try AgentSkill.install(named: $0).path }

        public init() {}
    }

    /// How long a freshly started app gets to open its socket.
    static let launchWait: TimeInterval = 15
    static let controlOff = "corral: command line control is off. Turn it on in Corral › Settings › Agents."

    public static func run(_ args: [String], io: IO = IO()) -> Int32 {
        let call: Invocation
        do {
            switch try parse(args, env: io.env, cwd: io.cwd) {
            case .help:
                io.out(usage)
                return 0
            case .skill(let target):
                do {
                    io.out("Installed \(try io.installSkill(target))")
                    return 0
                } catch {
                    io.err("corral: \(error.localizedDescription)")
                    return 1
                }
            case .request(let c): call = c
            }
        } catch let error as UsageError {
            io.err("corral: \(error.message)")
            return 2
        } catch {
            io.err("corral: \(error)")
            return 2
        }

        if call.follows { return follow(call, io: io) }
        guard var answer = ask(call.request, timeout: call.timeout, io: io) else { return 1 }
        guard answer["ok"] as? Bool == true else {
            io.err("corral: \(answer["error"] as? String ?? "failed")")
            return 1
        }
        if call.thenWait, let id = (answer["session"] as? [String: Any])?["id"] as? String {
            if !call.json { io.out(render(answer)) }
            var wait: [String: Any] = ["cmd": "wait", "ids": [id]]
            if call.final { wait["final"] = true }
            guard let event = ask(wait, timeout: nil, io: io) else { return 1 }
            guard event["ok"] as? Bool == true else {
                io.err("corral: \(event["error"] as? String ?? "failed")")
                return 1
            }
            answer = event
        }
        if call.json {
            let data = (try? JSONSerialization.data(withJSONObject: answer, options: [.sortedKeys, .prettyPrinted])) ?? Data()
            io.out(String(decoding: data, as: UTF8.self))
        } else {
            let text = render(answer)
            if !text.isEmpty { io.out(text) }
        }
        if answer["timeout"] as? Bool == true { return timedOut }
        guard call.statusFromState || call.thenWait else { return 0 }
        let report = answer["report"] as? [String: Any]
        return exitStatus(state: (answer["session"] as? [String: Any])?["state"] as? String,
                          failed: report?["failed"] as? Bool == true)
    }

    /// `corral events`: one line per event (`--json`: the event as one JSON line) until the app goes
    /// or the command is interrupted.
    private static func follow(_ call: Invocation, io: IO) -> Int32 {
        var status: Int32 = 0
        func run() -> ControlClient.Failure? {
            io.stream(call.request) { event in
                if event["ok"] as? Bool == false {
                    io.err("corral: \(event["error"] as? String ?? "failed")")
                    status = 1
                    return false
                }
                guard event["event"] != nil else { return true }
                if call.json {
                    let data = (try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
                    io.out(String(decoding: data, as: UTF8.self))
                } else {
                    io.out(render(event).replacingOccurrences(of: "\n", with: " | "))
                }
                return true
            }
        }
        var failure = run()
        if failure == .notRunning, io.appRunning() {
            io.err(controlOff)
            return 1
        }
        if failure == .notRunning {
            guard io.launchApp() else {
                io.err("corral: Corral isn't running and couldn't be started")
                return 1
            }
            var waited: TimeInterval = 0
            while failure == .notRunning, waited < launchWait {
                io.sleep(0.25)
                waited += 0.25
                failure = run()
            }
        }
        if let failure {
            io.err(failure == .notRunning ? "corral: Corral didn't start" : "corral: no answer from Corral")
            return 1
        }
        return status
    }

    /// Asks the app, starting it first when it isn't running.
    private static func ask(_ request: [String: Any], timeout: TimeInterval?, io: IO) -> [String: Any]? {
        var result = io.request(request, timeout)
        if result == .failure(.notRunning), io.appRunning() {
            io.err(controlOff)
            return nil
        }
        if result == .failure(.notRunning) {
            guard io.launchApp() else {
                io.err("corral: Corral isn't running and couldn't be started")
                return nil
            }
            var waited: TimeInterval = 0
            while result == .failure(.notRunning), waited < launchWait {
                io.sleep(0.25)
                waited += 0.25
                result = io.request(request, timeout)
            }
        }
        switch result {
        case .success(let answer): return answer
        case .failure(.notRunning): io.err("corral: Corral didn't start")
        case .failure(.noAnswer): io.err("corral: no answer from Corral")
        }
        return nil
    }

    /// Variables an agent session sets for the commands it runs. Corral started from such a command
    /// (`corral spawn` by an agent, with Corral not running yet) would pass them on to every terminal:
    /// Claude Code then takes each new session for a child of that one and keeps no transcript for it.
    public static func agentSessionVariables(in env: [String: String]) -> [String] {
        let exact: Set<String> = ["CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT", "OPENCODE", sessionVariable,
                                  "CORRAL_SURFACE_ID", "CORRAL_HOOK", "CORRAL_SOCKET"]
        let prefixes = ["CLAUDE_CODE_SESSION", "CLAUDE_CODE_CHILD", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_EXECPATH",
                        "CLAUDE_CODE_MESSAGING", "CLAUDE_CODE_SSE"]
        return env.keys.filter { key in exact.contains(key) || prefixes.contains { key.hasPrefix($0) } }.sorted()
    }

    /// At app start: this process, and so its terminals, belong to no agent session.
    public static func leaveAgentSession() {
        for name in agentSessionVariables(in: ProcessInfo.processInfo.environment) { unsetenv(name) }
    }

    /// The app bundle this binary sits in, opened without coming forward.
    static func launchApp() -> Bool {
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return false }
        let bundle = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard bundle.pathExtension == "app" else { return false }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-a", bundle.path]
        var env = ProcessInfo.processInfo.environment
        agentSessionVariables(in: env).forEach { env[$0] = nil }
        open.environment = env
        do { try open.run() } catch { return false }
        open.waitUntilExit()
        return open.terminationStatus == 0
    }

    /// The app's entry point: the exit status when `args` (without argv[0]) are a `corral` command,
    /// nil when the app should start.
    public static func main(_ args: [String], invokedAs: String = CommandLine.arguments.first ?? "") -> Int32? {
        // Through its link the binary is always the command: `corral` alone prints the usage, never starts the app.
        let asCommand = invokedAs.pathLeaf == "corral"
        guard let first = args.first else { return asCommand ? run([]) : nil }
        if commands.contains(first) || first == "--help" || first == "-h" { return run(args) }
        guard asCommand else { return nil }
        FileHandle.standardError.write(Data("corral: Unknown command \(first). Try corral help.\n".utf8))
        return 2
    }
}

extension Result where Success == [String: Any], Failure == ControlClient.Failure {
    static func == (a: Self, b: Self) -> Bool {
        if case .failure(let x) = a, case .failure(let y) = b { return x == y }
        return false
    }
}
