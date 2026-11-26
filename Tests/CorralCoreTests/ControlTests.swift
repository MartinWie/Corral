import Foundation
import Testing
@testable import CorralCore

@Suite struct CLIParserTests {
    private func request(_ args: [String], env: [String: String] = [:], stdin: String = "",
                         files: [String: String] = [:]) throws -> CorralCLI.Invocation {
        guard case .request(let call) = try CorralCLI.parse(args, env: env, cwd: "/work", stdin: { stdin },
                                                             readFile: { files[$0] }) else {
            throw CorralCLI.UsageError("not a request")
        }
        return call
    }

    @Test func spawnCarriesEverythingTheSessionNeeds() throws {
        let call = try request(["spawn", "--model", "easy", "--cwd", "sub", "--name", "Look", "--focus", "--wait",
                                "check", "the", "logs", "--", "--permission-mode", "acceptEdits"],
                               env: [CorralCLI.sessionVariable: "ABC"])
        let r = call.request
        #expect(r["cmd"] as? String == "spawn" && r["agent"] as? String == "claude" && r["model"] as? String == "easy")
        #expect(r["cwd"] as? String == "/work/sub" && r["name"] as? String == "Look" && r["focus"] as? Bool == true)
        #expect(r["prompt"] as? String == "check the logs" && r["caller"] as? String == "ABC")
        #expect(r["extra"] as? [String] == ["--permission-mode", "acceptEdits"])
        #expect(call.thenWait && !call.json)
        // Defaults: the caller's directory, no model, no prompt.
        let plain = try request(["spawn", "--agent", "pi", "--json"]).request
        #expect(plain["cwd"] as? String == "/work" && plain["model"] == nil && plain["prompt"] == nil && plain["caller"] == nil)
        #expect(try request(["spawn", "--json"]).json)
    }

    @Test func debugReportsHowATerminalIsDrawn() throws {
        #expect(try request(["debug"]).request["id"] == nil)
        #expect(try request(["debug", "1f"]).request["id"] as? String == "1f")
        #expect(throws: CorralCLI.UsageError.self) { try request(["debug", "a", "b"]) }
        let text = CorralCLI.render(["ok": true, "render": ["problems": "no frame", "draws_since_shown": 0]])
        #expect(text == "draws_since_shown: 0\nproblems: no frame")
    }

    @Test func promptsComeFromFilesAndStdin() throws {
        #expect(try request(["spawn", "--prompt-file", "task.md"], files: ["/work/task.md": "from a file\n"])
            .request["prompt"] as? String == "from a file")
        #expect(try request(["spawn", "--prompt-file", "-"], stdin: "line one\nline two\n")
            .request["prompt"] as? String == "line one\nline two")
        #expect(throws: CorralCLI.UsageError("Can't read gone.md")) { try request(["spawn", "--prompt-file", "gone.md"]) }
        #expect(throws: CorralCLI.UsageError.self) { try request(["spawn", "text", "--prompt-file", "task.md"]) }
        #expect(try request(["send", "1f", "-"], stdin: "typed").request["text"] as? String == "typed")
    }

    @Test func theOtherCommands() throws {
        #expect(try request(["list", "--mine"]).request["mine"] as? Bool == true)
        #expect(try request(["status", "1f3a"]).request["id"] as? String == "1f3a")
        let wait = try request(["wait", "1f", "2b", "--timeout", "90"])
        #expect(wait.request["ids"] as? [String] == ["1f", "2b"] && wait.request["timeout"] as? Double == 90)
        #expect(wait.timeout == nil)
        #expect(try request(["wait"]).request["ids"] == nil)
        let send = try request(["send", "1f", "do", "it", "--raw"]).request
        #expect(send["text"] as? String == "do it" && send["raw"] as? Bool == true)
        let output = try request(["output", "1f", "--screen", "--lines", "5"]).request
        #expect(output["screen"] as? Bool == true && output["lines"] as? Int == 5)
        for command in ["approve", "deny", "close"] {
            #expect(try request([command, "1f"]).request["cmd"] as? String == command)
        }
    }

    @Test func mistakesAreUsageErrors() {
        for args in [["status"], ["approve", "a", "b"], ["send", "1f"], ["wait", "--timeout", "soon"], ["wait", "--timeout"],
                     ["output", "1f", "--lines", "0"], ["list", "extra"], ["spawn", "--colour", "red"], ["skill"],
                     ["skill", "remove"]] {
            #expect(throws: CorralCLI.UsageError.self, "\(args)") { _ = try CorralCLI.parse(args, env: [:], cwd: "/") }
        }
    }

    @Test func helpAndSkill() throws {
        for args in [[], ["help"], ["--help"], ["-h"]] {
            guard case .help = try CorralCLI.parse(args, env: [:], cwd: "/") else { Issue.record("\(args)"); continue }
        }
        guard case .skill(let target) = try CorralCLI.parse(["skill", "install", "opencode"], env: [:], cwd: "/") else {
            Issue.record("skill"); return
        }
        #expect(target == "opencode")
        #expect(CorralCLI.main([]) == nil && CorralCLI.main(["-NSDocumentRevisionsDebugMode", "YES"]) == nil)
    }
}

@Suite struct CLIRunTests {
    final class Recorder {
        var out: [String] = []
        var err: [String] = []
        var requests: [[String: Any]] = []
        var launches = 0
        var running = false
        var slept: TimeInterval = 0
        var answers: [Result<[String: Any], ControlClient.Failure>] = []
        var skill: Result<String, AgentSkill.InstallError> = .success("/skills/corral/SKILL.md")

        var io: CorralCLI.IO {
            var io = CorralCLI.IO()
            io.out = { self.out.append($0) }
            io.err = { self.err.append($0) }
            io.env = [:]
            io.cwd = "/work"
            io.request = { request, _ in
                self.requests.append(request)
                return self.answers.isEmpty ? .failure(.notRunning) : self.answers.removeFirst()
            }
            io.launchApp = { self.launches += 1; return true }
            io.appRunning = { self.running }
            io.sleep = { self.slept += $0 }
            io.installSkill = { _ in try self.skill.get() }
            return io
        }
    }

    private let session: [String: Any] = ["id": "1f3a9c2e-0000-0000-0000-000000000000", "state": "done", "agent": "claude",
                                          "name": "Look", "cwd": "/work", "model": "haiku"]

    @Test func printsSessionsAndReports() {
        let r = Recorder()
        r.answers = [.success(["ok": true, "sessions": [session, ["id": "2b", "state": "needs_permission", "agent": "pi",
                                                                   "name": "Other", "detail": "Bash: ls"]]])]
        #expect(CorralCLI.run(["list"], io: r.io) == 0)
        #expect(r.out == ["1f3a9c2e  done  claude  Look\n2b  needs_permission  pi  Other: Bash: ls"])
        r.answers = [.success(["ok": true, "session": session, "result": "All good."])]
        #expect(CorralCLI.run(["status", "1f"], io: r.io) == 0)
        #expect(r.out.last == "1f3a9c2e  done  claude  Look\nmodel: haiku\ncwd: /work\nresult:\nAll good.")
        r.answers = [.success(["ok": true, "sessions": [[String: Any]]()])]
        #expect(CorralCLI.run(["list"], io: r.io) == 0 && r.out.last == "No sessions.")
        r.answers = [.success(["ok": true, "session": session, "request": "{\"command\":\"ls\"}"])]
        #expect(CorralCLI.run(["status", "1f", "--json"], io: r.io) == 0)
        #expect(r.out.last?.contains("\"request\" : \"{\\\"command\\\":\\\"ls\\\"}\"") == true)
    }

    @Test func failuresAndTimeouts() {
        let r = Recorder()
        r.answers = [.success(["ok": false, "error": "Command line control is off."])]
        #expect(CorralCLI.run(["list"], io: r.io) == 1 && r.err == ["corral: Command line control is off."])
        r.answers = [.success(["ok": true, "timeout": true, "sessions": [session]])]
        #expect(CorralCLI.run(["wait", "1f", "--timeout", "1"], io: r.io) == CorralCLI.timedOut)
        #expect(r.out.last?.hasPrefix("Nothing happened in time.") == true)
        #expect(CorralCLI.run(["status"], io: r.io) == 2 && r.err.last == "corral: corral status ID")
        r.answers = [.failure(.noAnswer)]
        #expect(CorralCLI.run(["list"], io: r.io) == 1 && r.err.last == "corral: no answer from Corral")
        #expect(CorralCLI.run(["help"], io: r.io) == 0 && r.out.last == CorralCLI.usage)
    }

    @Test func startsTheAppWhenItIsNotRunning() {
        let r = Recorder()
        r.answers = [.failure(.notRunning), .failure(.notRunning), .success(["ok": true, "sessions": [session]])]
        #expect(CorralCLI.run(["list"], io: r.io) == 0)
        #expect(r.launches == 1 && r.requests.count == 3 && r.slept == 0.5)
        // It never comes up: gives up after the launch wait.
        let dead = Recorder()
        #expect(CorralCLI.run(["list"], io: dead.io) == 1)
        #expect(dead.err == ["corral: Corral didn't start"] && dead.slept == CorralCLI.launchWait)
        var io = dead.io
        io.launchApp = { false }
        #expect(CorralCLI.run(["list"], io: io) == 1)
        #expect(dead.err.last == "corral: Corral isn't running and couldn't be started")
        // Corral runs with control off: said at once, nothing started or waited for.
        let off = Recorder()
        off.running = true
        #expect(CorralCLI.run(["list"], io: off.io) == 1)
        #expect(off.err == [CorralCLI.controlOff] && off.launches == 0 && off.slept == 0)
        #expect(CorralCLI.run(["events"], io: off.io) == 1 && off.err.last == CorralCLI.controlOff)
    }

    @Test func spawnWaitWaitsForTheNewSession() {
        let r = Recorder()
        var working = session
        working["state"] = "starting"
        r.answers = [.success(["ok": true, "session": working]), .success(["ok": true, "session": session, "result": "Found it."])]
        #expect(CorralCLI.run(["spawn", "--wait", "look"], io: r.io) == 0)
        #expect(r.requests.last?["cmd"] as? String == "wait")
        #expect(r.requests.last?["ids"] as? [String] == ["1f3a9c2e-0000-0000-0000-000000000000"])
        #expect(r.out.first?.hasPrefix("1f3a9c2e  starting") == true && r.out.last?.hasSuffix("result:\nFound it.") == true)
        r.answers = [.success(["ok": true, "session": working]), .success(["ok": false, "error": "gone"])]
        #expect(CorralCLI.run(["spawn", "--wait", "look"], io: r.io) == 1 && r.err.last == "corral: gone")
    }

    @Test func skillInstallReportsThePath() {
        let r = Recorder()
        #expect(CorralCLI.run(["skill", "install"], io: r.io) == 0 && r.out == ["Installed /skills/corral/SKILL.md"])
        r.skill = .failure(.init(message: "belongs to another skill"))
        #expect(CorralCLI.run(["skill", "install"], io: r.io) == 1 && r.err == ["corral: belongs to another skill"])
    }
}

@Suite struct ControlSocketTests {
    private func path() -> String { NSTemporaryDirectory() + "cc-\(UInt32.random(in: 0...UInt32.max)).sock" }

    private func ask(_ request: [String: Any], _ path: String, timeout: TimeInterval? = 5) async -> Result<[String: Any], ControlClient.Failure> {
        await withCheckedContinuation { done in
            DispatchQueue.global().async { done.resume(returning: ControlClient.request(request, path: path, timeout: timeout)) }
        }
    }

    @Test func answersNowOrLater() async throws {
        let path = path()
        let big = String(repeating: "x", count: 200_000)
        let server = ControlServer(path: path) { request, connection in
            switch request["cmd"] as? String {
            case "late":
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { connection.reply(["ok": true, "late": true]) }
                return
            case "big": connection.reply(["ok": true, "text": big])
            default: connection.reply(["ok": true, "echo": request["cmd"] ?? ""])
            }
            // A second answer goes nowhere.
            connection.reply(["ok": false])
        }
        try server.start()
        defer { server.stop() }
        #expect(try await ask(["cmd": "hello"], path).get()["echo"] as? String == "hello")
        #expect(try await ask(["cmd": "big"], path).get()["text"] as? String == big)
        #expect(try await ask(["cmd": "late"], path).get()["late"] as? Bool == true)
        var mode = stat()
        #expect(stat(path, &mode) == 0 && mode.st_mode & 0o777 == 0o600)
    }

    @Test func aListeningClientGetsLinesUntilItLeaves() async throws {
        let path = path()
        final class Box: @unchecked Sendable { var closed = 0; var got: [[String: Any]] = [] }
        let box = Box()
        let server = ControlServer(path: path) { _, connection in
            connection.onClose = { box.closed += 1 }
            for i in 0..<3 { connection.push(["n": i]) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                connection.push(["n": 3])
                connection.reply(["n": 4])
            }
        }
        try server.start()
        defer { server.stop() }
        let failure: ControlClient.Failure? = await withCheckedContinuation { done in
            DispatchQueue.global().async {
                done.resume(returning: ControlClient.stream(["cmd": "events"], path: path) { box.got.append($0); return true })
            }
        }
        // All five lines, then the app closed the connection: an orderly end.
        #expect(failure == nil && box.got.compactMap { $0["n"] as? Int } == [0, 1, 2, 3, 4] && box.closed == 0)
        // A client that stops after the first line.
        box.got = []
        _ = await withCheckedContinuation { (done: CheckedContinuation<ControlClient.Failure?, Never>) in
            DispatchQueue.global().async {
                done.resume(returning: ControlClient.stream(["cmd": "events"], path: path) { box.got.append($0); return false })
            }
        }
        #expect(box.got.count == 1)
    }

    @Test func aClientThatLeavesIsNoticed() async throws {
        let path = path()
        final class Box: @unchecked Sendable { var closed = 0; var held: [ControlServer.Connection] = [] }
        let box = Box()
        let server = ControlServer(path: path) { _, connection in
            box.held.append(connection)
            connection.onClose = { box.closed += 1 }
        }
        try server.start()
        defer { server.stop() }
        // The client gives up after a second without an answer.
        #expect(await ask(["cmd": "wait"], path, timeout: 1) == .failure(.noAnswer))
        let deadline = Date().addingTimeInterval(5)
        while box.closed == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(box.closed == 1)
        box.held.first?.reply(["ok": true])
        #expect(box.closed == 1)
    }

    @Test func nothingListeningAndBrokenRequests() async throws {
        let path = path()
        #expect(await ask(["cmd": "x"], path) == .failure(.notRunning))
        #expect(ControlClient.request(["cmd": "x"], path: String(repeating: "p", count: 300)) == .failure(.notRunning))
        let server = ControlServer(path: path) { _, connection in connection.reply(["ok": true]) }
        try server.start()
        defer { server.stop() }
        // Not JSON: the connection is dropped without an answer.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = try #require(UnixSocket.address(path))
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(rc == 0)
        _ = "nope\n".withCString { write(fd, $0, 5) }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var byte: UInt8 = 0
        #expect(read(fd, &byte, 1) == 0)
        #expect(throws: POSIXError.self) {
            try ControlServer(path: NSTemporaryDirectory() + String(repeating: "p", count: 300)) { _, _ in }.start()
        }
    }
}

@Suite struct AgentSkillTests {
    private func home() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("skill-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func app(_ home: URL, _ name: String = "Corral.app") -> URL {
        let exe = home.appendingPathComponent("\(name)/Contents/MacOS/Corral")
        try? FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("bin".utf8).write(to: exe)
        return exe.resolvingSymlinksInPath()
    }

    @Test func installsTheSkillAndTheCommand() throws {
        let home = home()
        defer { try? FileManager.default.removeItem(at: home) }
        let exe = app(home)
        let fm = FileManager.default
        #expect(!AgentSkill.isInstalled(.claudeCode, home: home))
        let file = try AgentSkill.install(into: AgentSkill.Target.claudeCode.skillsFolder(home: home), home: home, executable: exe)
        #expect(file.path.hasSuffix(".claude/skills/corral/SKILL.md"))
        #expect(try String(contentsOf: file, encoding: .utf8) == AgentSkill.markdown)
        #expect(AgentSkill.isInstalled(.claudeCode, home: home) && !AgentSkill.isInstalled(.openCode, home: home))
        let link = CommandLineLink.url(home: home)
        #expect(URL(fileURLWithPath: try fm.destinationOfSymbolicLink(atPath: link.path)).resolvingSymlinksInPath().path == exe.path)
        // Claude's config elsewhere, OpenCode's own folder.
        let custom = home.appendingPathComponent("cfg")
        #expect(AgentSkill.Target.claudeCode.skillsFolder(home: home, claudeDir: custom).path == custom.appendingPathComponent("skills").path)
        #expect(AgentSkill.Target.openCode.skillsFolder(home: home).path.hasSuffix(".config/opencode/skills"))
        #expect(AgentSkill.Target.allCases.map(\.title) == ["Claude Code", "OpenCode"])
        // The skill text names nothing of this Mac.
        #expect(!AgentSkill.markdown.contains(NSHomeDirectory()) && !AgentSkill.markdown.contains(NSUserName()))
    }

    @Test func anotherToolsSkillAndCommandAreLeftAlone() throws {
        let home = home()
        defer { try? FileManager.default.removeItem(at: home) }
        let exe = app(home)
        let skills = AgentSkill.Target.openCode.skillsFolder(home: home)
        let file = skills.appendingPathComponent("corral/SKILL.md")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("---\nname: corral\n---\nHorses.\n".utf8).write(to: file)
        #expect(throws: AgentSkill.InstallError.self) { try AgentSkill.install(into: skills, home: home, executable: exe) }
        #expect(try String(contentsOf: file, encoding: .utf8).contains("Horses"))
        // The skill without the command is said, not passed off as installed.
        let taken = home.appendingPathComponent("taken")
        try FileManager.default.createDirectory(at: taken.appendingPathComponent(".local/bin"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: CommandLineLink.url(home: taken))
        #expect(throws: AgentSkill.InstallError.self) {
            try AgentSkill.install(into: AgentSkill.Target.claudeCode.skillsFolder(home: taken), home: taken, executable: exe)
        }
        // A real file named corral in ~/.local/bin stays.
        let link = CommandLineLink.url(home: home)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: link)
        #expect(try !CommandLineLink.ensure(home: home, executable: exe))
        #expect(try String(contentsOf: link, encoding: .utf8) == "#!/bin/sh\n")
        // So does a link to something that isn't a Corral app, and nothing is linked from a translocated copy.
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/bin/ls"))
        #expect(try !CommandLineLink.ensure(home: home, executable: exe))
        try FileManager.default.removeItem(at: link)
        #expect(try !CommandLineLink.ensure(home: home, executable: URL(fileURLWithPath: "/private/var/AppTranslocation/X/Corral.app/Contents/MacOS/Corral")))
        #expect(try !CommandLineLink.ensure(home: home, executable: nil))
    }

    @Test func launchRefreshesInstalledCopiesAndFollowsTheApp() throws {
        let home = home()
        defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        let old = app(home, "Old/Corral.app"), new = app(home, "New/Corral.app")
        // Nothing installed: nothing appears.
        AgentSkill.refreshInstalled(home: home, executable: new)
        #expect(!fm.fileExists(atPath: CommandLineLink.url(home: home).path))
        #expect(!fm.fileExists(atPath: AgentSkill.Target.claudeCode.skillsFolder(home: home).path))
        let file = try AgentSkill.install(into: AgentSkill.Target.claudeCode.skillsFolder(home: home), home: home, executable: old)
        try Data("---\nname: corral\n---\n\(AgentSkill.marker)\nold text\n".utf8).write(to: file)
        AgentSkill.refreshInstalled(home: home, executable: new)
        #expect(try String(contentsOf: file, encoding: .utf8) == AgentSkill.markdown)
        let link = CommandLineLink.url(home: home)
        #expect(URL(fileURLWithPath: try fm.destinationOfSymbolicLink(atPath: link.path)).resolvingSymlinksInPath().path == new.path)
        // A link whose app is gone is repointed too, and an up-to-date one is kept.
        try fm.removeItem(at: new)
        #expect(try CommandLineLink.ensure(home: home, executable: old))
        #expect(try CommandLineLink.ensure(home: home, executable: old))
        #expect(URL(fileURLWithPath: try fm.destinationOfSymbolicLink(atPath: link.path)).resolvingSymlinksInPath().path == old.path)
    }

    @Test func commandLineInstallPicksTheFolder() throws {
        let home = home()
        defer { try? FileManager.default.removeItem(at: home) }
        let cfg = home.appendingPathComponent("claude-cfg")
        // Bundle.main in tests is the test runner: the link points there, inside this temp home.
        #expect(try AgentSkill.install(named: nil, env: ["CLAUDE_CONFIG_DIR": cfg.path], home: home).path
            == cfg.appendingPathComponent("skills/corral/SKILL.md").path)
        #expect(try AgentSkill.install(named: "claude", env: [:], home: home).path.hasSuffix(".claude/skills/corral/SKILL.md"))
        #expect(try AgentSkill.install(named: "opencode", env: [:], home: home).path.hasSuffix(".config/opencode/skills/corral/SKILL.md"))
        let folder = home.appendingPathComponent("my skills")
        #expect(try AgentSkill.install(named: folder.path, env: [:], home: home).path == folder.appendingPathComponent("corral/SKILL.md").path)
    }
}

@Suite struct ModelAndHookFieldTests {
    @Test func startAndResumeCommandsCarryTheModel() {
        #expect(AgentKind.claude.startInput(sessionId: "abc", model: "opus", prompt: "fix it's bug", extra: ["--permission-mode", "plan"])
            == "claude --session-id abc --model opus --permission-mode plan 'fix it'\\''s bug'")
        #expect(AgentKind.claude.startInput() == "claude" && AgentKind.claude.startCommand(sessionId: "abc") == "claude --session-id abc")
        #expect(AgentKind.opencode.startInput(sessionId: "ignored", model: "anthropic/x", prompt: "go") == "opencode --model anthropic/x --prompt=go")
        // A prompt that starts like an option.
        #expect(AgentKind.claude.startInput(prompt: "- [ ] fix") == "claude ' - [ ] fix'")
        #expect(AgentKind.opencode.startInput(prompt: "--help") == "opencode --prompt=' --help'")
        #expect(AgentKind.pi.startInput(model: "", prompt: "go") == "pi go")
        #expect(AgentKind.shell.startInput(prompt: "go") == nil && AgentKind.pi.startCommand(sessionId: "x") == nil)
        #expect(AgentKind.claude.resumeCommand(sessionId: "abc", model: "haiku") == "claude --resume abc --model haiku")
        #expect(AgentKind.opencode.resumeCommand(sessionId: "s", model: "") == "opencode -s s")
        var record = SessionRecord(cwd: "/x", agent: .claude, agentSessionId: "abc")
        record.model = "sonnet"
        #expect(record.restoreInput == "claude --resume abc --model sonnet" && record.reopenInput == record.restoreInput)
    }

    @Test func tiersResolveThroughSettings() throws {
        var settings = AppSettings()
        #expect(settings.model(for: .claude, named: "easy") == "haiku" && settings.model(for: .claude, named: "HIGH") == "opus")
        #expect(settings.model(for: .claude, named: nil) == nil && settings.model(for: .claude, named: "") == nil)
        #expect(settings.model(for: .claude, named: "claude-x-1") == "claude-x-1")
        #expect(settings.model(for: .pi, named: "medium") == nil)
        var models = settings.models(for: .claude)
        models[.medium] = "big"
        models.standard = .medium
        settings.models["claude"] = models
        #expect(settings.model(for: .claude, named: nil) == "big" && models[.easy] == "haiku" && models[.high] == "opus")
        models[.easy] = ""
        models[.high] = "top"
        models.standard = .easy
        settings.models["claude"] = models
        #expect(settings.model(for: .claude, named: nil) == nil && settings.model(for: .claude, named: "high") == "top")
        // Round trip, and state from before the fields existed.
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(back == settings)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"keepAwake":true}"#.utf8))
        #expect(!old.control && old.models.isEmpty && !old.measure && !old.spawnNoteOn && old.spawnNote == AppSettings.defaultSpawnNote)
        let partial = try JSONDecoder().decode(AgentModels.self, from: Data(#"{"high":"x","standard":"nope"}"#.utf8))
        #expect(partial == AgentModels(high: "x"))
        #expect(ModelTier.allCases.map(\.title) == ["Easy", "Medium", "High"])
    }

    private func decode(_ event: String, _ payload: [String: Any]) -> HookEvent? {
        HookWire.encode(surface: UUID().uuidString, agent: "claude", event: event, payload: payload)
            .flatMap { HookWire.decode(line: $0.dropLast()) }?.event
    }

    @Test func hooksCarryTheRequestAndTheResult() throws {
        let ask = try #require(decode("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "git push", "b": 1],
                                                            "transcript_path": "/t/a.jsonl"]))
        #expect(ask.toolInput == #"{"b":1,"command":"git push"}"# && ask.transcriptPath == "/t/a.jsonl" && ask.lastMessage == nil)
        let long = try #require(decode("PermissionRequest", ["tool_name": "Write", "tool_input": ["content": String(repeating: "a", count: 20_000)]]))
        #expect(long.toolInput?.count == HookWire.maxToolInput)
        let stop = try #require(decode("Stop", ["last_assistant_message": "Done: 3 files."]))
        #expect(stop.lastMessage == "Done: 3 files." && stop.toolInput == nil)
        #expect(decode("PostToolUse", ["last_assistant_message": "x"])?.lastMessage == nil)
        #expect(decode("PermissionRequest", ["tool_name": "Bash"])?.toolInput == nil)
    }

    @Test func transcriptTailFindsTheLastAnswer() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tail-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        func line(_ type: String, _ content: [[String: Any]], sidechain: Bool = false) -> String {
            let obj: [String: Any] = ["type": type, "isSidechain": sidechain, "message": ["content": content]]
            return String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
        }
        let lines = [
            line("assistant", [["type": "text", "text": "first answer"]]),
            line("user", [["type": "text", "text": "more"]]),
            line("assistant", [["type": "text", "text": "the answer"], ["type": "tool_use", "name": "Bash"], ["type": "text", "text": "second part"]]),
            line("assistant", [["type": "tool_use", "name": "Bash"]]),
            line("assistant", [["type": "text", "text": "a subagent's"]], sidechain: true),
            "not json",
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: file)
        #expect(TranscriptTail.lastAssistantText(path: file.path) == "the answer\nsecond part")
        // Only the window's end is read.
        #expect(TranscriptTail.lastAssistantText(path: file.path, window: 40) == nil)
        #expect(TranscriptTail.lastAssistantText(path: file.path + ".gone") == nil)
    }
}

@Suite struct CallbackAndStatsTests {
    private func request(_ args: [String], env: [String: String] = [:], stdin: String = "") throws -> CorralCLI.Invocation {
        guard case .request(let call) = try CorralCLI.parse(args, env: env, cwd: "/work", stdin: { stdin }) else {
            throw CorralCLI.UsageError("not a request")
        }
        return call
    }

    @Test func exitStatusTellsWhatTheSessionDid() {
        #expect(CorralCLI.exitStatus(state: "done", failed: false) == 0 && CorralCLI.exitStatus(state: "done", failed: true) == 3)
        #expect(["needs_permission", "needs_input", "error", "exited", "closed", "working", nil]
            .map { CorralCLI.exitStatus(state: $0, failed: false) } == [10, 11, 12, 13, 13, 0, 0])
        let r = CLIRunTests.Recorder()
        func session(_ state: String) -> [String: Any] { ["id": "1f", "state": state, "agent": "claude", "name": "S"] }
        r.answers = [.success(["ok": true, "session": session("needs_permission"), "request": "{}"])]
        #expect(CorralCLI.run(["wait", "1f"], io: r.io) == 10)
        r.answers = [.success(["ok": true, "session": session("done"), "report": ["text": "no luck", "failed": true]])]
        #expect(CorralCLI.run(["wait", "1f", "--done"], io: r.io) == 3)
        #expect(r.requests.last?["final"] as? Bool == true && r.out.last == "1f  done  claude  S\nreport (failed): no luck")
        // spawn --wait --done passes the filter on; status never maps the state.
        r.answers = [.success(["ok": true, "session": session("starting")]), .success(["ok": true, "session": session("error")])]
        #expect(CorralCLI.run(["spawn", "--wait", "--done", "go"], io: r.io) == 12 && r.requests.last?["final"] as? Bool == true)
        r.answers = [.success(["ok": true, "session": session("error"), "screen": "Trust this folder?"])]
        #expect(CorralCLI.run(["status", "1f"], io: r.io) == 0 && r.out.last?.hasSuffix("screen:\nTrust this folder?") == true)
        #expect(throws: CorralCLI.UsageError("--done goes with --wait")) { try request(["spawn", "--done", "go"]) }
    }

    @Test func reportAndStatsCommands() throws {
        let caller = [CorralCLI.sessionVariable: "ABC"]
        let report = try request(["report", "--fail", "could", "not", "build"], env: caller).request
        #expect(report["text"] as? String == "could not build" && report["failed"] as? Bool == true && report["caller"] as? String == "ABC")
        #expect(try request(["report", "-"], env: caller, stdin: " from stdin\n").request["text"] as? String == "from stdin")
        #expect(throws: CorralCLI.UsageError.self) { try request(["report", "x"]) }
        #expect(throws: CorralCLI.UsageError.self) { try request(["report"], env: caller) }
        #expect(try request(["stats"]).request["id"] == nil && request(["stats", "1f"]).request["id"] as? String == "1f")
        #expect(throws: CorralCLI.UsageError.self) { try request(["stats", "a", "b"]) }
        #expect(try request(["stats"]).timeout == nil)
        // Folders.
        #expect(try request(["spawn", "--folder", "Jobs/Disk", "go"]).request["folder"] as? String == "Jobs/Disk")
        #expect(try request(["folder", "list"]).request["action"] as? String == "list")
        let move = try request(["folder", "move", "Jobs/Disk", "1f", "2b"]).request
        #expect(move["action"] as? String == "move" && move["path"] as? String == "Jobs/Disk" && move["ids"] as? [String] == ["1f", "2b"])
        let rename = try request(["folder", "rename", "Jobs", "Work"]).request
        #expect(rename["path"] as? String == "Jobs" && rename["name"] as? String == "Work")
        for action in ["create", "collapse", "expand", "delete"] {
            #expect(try request(["folder", action, "Jobs"]).request["path"] as? String == "Jobs")
        }
        for bad in [["folder"], ["folder", "list", "x"], ["folder", "move", "Jobs"], ["folder", "create"], ["folder", "paint", "Jobs"]] {
            #expect(throws: CorralCLI.UsageError.self, "\(bad)") { try request(bad) }
        }
        #expect(CorralCLI.render(["folders": [["path": "Jobs", "sessions": 0, "expanded": true],
                                              ["path": "Jobs/Disk", "sessions": 1, "expanded": false]]])
            == "Jobs  (0 sessions)\nJobs/Disk  (1 session, collapsed)")
        #expect(CorralCLI.render(["folders": [[String: Any]]()]) == "No folders.")
        #expect(CorralCLI.line(["id": "1f", "state": "idle", "agent": "pi", "name": "S", "folder": "Jobs/Disk"]) == "1f  idle  pi  S  [Jobs/Disk]")
        let stats: [String: Any] = ["tokens": 184_500, "input": 2_100, "output": 9_000, "cache_read": 160_000, "cache_write": 13_400,
                                    "turns": 1, "tool_calls": 41, "tool_errors": 2, "seconds": 720, "flags": ["Read a.swift 5 times"]]
        let text = CorralCLI.render(["ok": true, "stats": [["session": ["id": "1f", "state": "done", "agent": "claude", "name": "S", "parent": "abcdef123"],
                                                             "stats": stats], ["session": ["id": "2b"]]]])
        #expect(text == "1f  done  claude  S\n  184k tokens (in 2.1k, out 9.0k, cache read 160k, cache write 13k), 1 turn, 41 tool calls (2 failed), 12 min working\n"
            + "  ! Read a.swift 5 times\n2b  ?  ?  \n  no transcript to measure")
        #expect(SessionAnalysis.summary(["tokens": 900, "turns": 2, "tool_calls": 1, "seconds": 45])
            == "900 tokens (in 0, out 0, cache read 0, cache write 0), 2 turns, 1 tool call, 45 s working")
        #expect(CorralCLI.render(["session": ["id": "1f", "parent": "abcdef123"]]).hasSuffix("started by: abcdef12"))
    }

    @Test func eventsAreFollowedLineByLine() throws {
        let call = try request(["events", "1f", "--mine", "--json"], env: [CorralCLI.sessionVariable: "ABC"])
        #expect(call.follows && call.json && call.request["ids"] as? [String] == ["1f"] && call.request["mine"] as? Bool == true)
        let r = CLIRunTests.Recorder()
        var io = r.io
        let done: [String: Any] = ["event": "done", "session": ["id": "1f", "state": "done", "agent": "claude", "name": "S"], "result": "ok\nfine"]
        var feeds: [[[String: Any]]] = [[["ok": true], done, ["event": "closed", "session": ["id": "1f", "state": "closed", "agent": "claude", "name": "S"]]]]
        var failures: [ControlClient.Failure?] = [nil]
        io.stream = { _, each in
            for line in feeds.isEmpty ? [] : feeds.removeFirst() where !each(line) { break }
            return failures.isEmpty ? nil : failures.removeFirst()
        }
        #expect(CorralCLI.run(["events"], io: io) == 0)
        #expect(r.out == ["1f  done  claude  S | result: | ok | fine", "1f  closed  claude  S"])
        feeds = [[["ok": true], done]]
        failures = [nil]
        #expect(CorralCLI.run(["events", "--json"], io: io) == 0 && r.out.last?.hasPrefix("{\"event\":\"done\"") == true)
        // Refused, not running (started, then followed), and never coming up.
        feeds = [[["ok": false, "error": "off"]]]
        failures = [nil]
        #expect(CorralCLI.run(["events"], io: io) == 1 && r.err.last == "corral: off")
        feeds = [[], [["ok": true]]]
        failures = [.notRunning, nil]
        #expect(CorralCLI.run(["events"], io: io) == 0 && r.launches == 1)
        feeds = []
        failures = Array(repeating: .notRunning, count: 100)
        #expect(CorralCLI.run(["events"], io: io) == 1 && r.err.last == "corral: Corral didn't start")
        failures = [.noAnswer]
        #expect(CorralCLI.run(["events"], io: io) == 1 && r.err.last == "corral: no answer from Corral")
        failures = [.notRunning]
        io.launchApp = { false }
        #expect(CorralCLI.run(["events"], io: io) == 1)
    }

    @Test func theAppLeavesTheAgentSessionItWasStartedFrom() {
        let env = ["CLAUDECODE": "1", "CLAUDE_CODE_CHILD_SESSION": "1", "CLAUDE_CODE_SESSION_ID": "x", "CLAUDE_PID": "1",
                   "CLAUDE_CODE_ENTRYPOINT": "cli", "CORRAL_SESSION": "y", "CORRAL_SURFACE_ID": "y",
                   // The user's own settings stay.
                   "CLAUDE_CONFIG_DIR": "/cfg", "CLAUDE_CODE_USE_BEDROCK": "1", "PATH": "/bin", "CORRAL_SUPPORT_DIR": "/s"]
        #expect(CorralCLI.agentSessionVariables(in: env) == ["CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_ENTRYPOINT",
                                                             "CLAUDE_CODE_SESSION_ID", "CLAUDE_PID", "CORRAL_SESSION", "CORRAL_SURFACE_ID"])
        setenv("CLAUDE_CODE_CHILD_SESSION", "1", 1)
        CorralCLI.leaveAgentSession()
        #expect(getenv("CLAUDE_CODE_CHILD_SESSION") == nil)
    }

    @Test func throughItsLinkTheBinaryIsAlwaysTheCommand() {
        #expect(CorralCLI.main([], invokedAs: "/Applications/Corral.app/Contents/MacOS/Corral") == nil)
        #expect(CorralCLI.main(["-psn_0_1"], invokedAs: "/Applications/Corral.app/Contents/MacOS/Corral") == nil)
        #expect(CorralCLI.main(["frobnicate"], invokedAs: "/Users/x/.local/bin/corral") == 2)
    }

    private func transcript(_ lines: [[String: Any]]) throws -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("stats-\(UUID().uuidString).jsonl")
        let text = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
        try Data((text + "\nnot json\n").utf8).write(to: file)
        return file.path
    }

    private func assistant(_ id: String, model: String = "claude-opus-x", tokens: [Int] = [10, 20, 300, 40], at: String,
                           _ blocks: [[String: Any]]) -> [String: Any] {
        ["type": "assistant", "timestamp": at, "message": [
            "id": id, "model": model, "content": blocks,
            "usage": ["input_tokens": tokens[0], "output_tokens": tokens[1], "cache_read_input_tokens": tokens[2],
                      "cache_creation_input_tokens": tokens[3]]]]
    }

    private func tool(_ name: String, _ input: [String: Any]) -> [String: Any] { ["type": "tool_use", "name": name, "input": input] }
    private func result(error: Bool) -> [String: Any] {
        ["type": "user", "message": ["content": [["type": "tool_result", "is_error": error]]]]
    }

    @Test func countsTokensOncePerResponseAndFlagsWaste() throws {
        var lines: [[String: Any]] = [
            ["type": "user", "timestamp": "2026-01-01T10:00:00.000Z", "message": ["content": "fix the build"]],
            // One response written as two lines (a line per content block): its usage counts once.
            assistant("m1", at: "2026-01-01T10:00:05.000Z", [["type": "text", "text": "Looking."]]),
            assistant("m1", at: "2026-01-01T10:00:06.000Z", [tool("Read", ["file_path": "/p/a.swift"])]),
            result(error: false),
        ]
        for i in 2...5 {
            lines.append(assistant("m\(i)", at: "2026-01-01T10:0\(i):00.000Z",
                                   [tool("Read", ["file_path": "/p/a.swift"]), tool("Bash", ["command": "make"])]))
            lines.append(result(error: true))
        }
        lines += [
            assistant("m6", at: "2026-01-01T10:20:00.000Z", [tool("Task", ["prompt": "look"]), ["type": "text", "text": "Done."]]),
            // One compaction writes a boundary and a summary: counted once.
            ["type": "system", "subtype": "compact_boundary"],
            ["type": "user", "isCompactSummary": true, "message": ["content": "summary"]],
            ["type": "user", "isMeta": true, "message": ["content": "meta"]],
            ["type": "user", "isSidechain": true, "message": ["content": "to a subagent"]],
            // What Claude Code files as user messages itself is no turn.
            ["type": "user", "message": ["content": "<task-notification>done</task-notification>"]],
            ["type": "user", "message": ["content": [["type": "text", "text": "[Request interrupted by user]"]]]],
            ["type": "user", "origin": ["kind": "task"], "message": ["content": "looks typed, isn't"]],
            ["type": "user", "origin": ["kind": "human"], "message": ["content": [["type": "text", "text": "thanks"]]]],
            ["type": "assistant", "message": ["id": "m7", "model": "<synthetic>", "content": [[String: Any]]()]],
            // Logs between the messages are skipped unparsed.
            ["type": "api-request", "message": ["id": "x", "usage": ["input_tokens": 999_999]]],
        ]
        let path = try transcript(lines)
        let stats = try #require(SessionAnalysis.analyze(path: path))
        #expect(stats.responses == 6 && stats.input == 60 && stats.output == 120 && stats.cacheRead == 1800 && stats.cacheWrite == 240)
        #expect(stats.tokens == 2220 && stats.turns == 2 && stats.toolCalls == 10 && stats.toolErrors == 4)
        #expect(stats.tools == ["Read": 5, "Bash": 4, "Task": 1] && stats.subagents == 1 && stats.compactions == 1)
        #expect(stats.seconds == 1200 && stats.models == ["claude-opus-x"] && stats.subagentTokens == 0)
        #expect(stats.flags == ["4 of 10 tool calls failed", "Same call 4 times: Bash: make",
                                "Read a.swift 5 times", "Context compacted 1 time: earlier work had to be summarized"])
        #expect(stats.json["tokens"] as? Int == 2220 && stats.json["flags"] as? [String] == stats.flags)
        #expect(SessionAnalysis.analyze(path: "/no/such/file.jsonl") == nil)

        // Subagents' own transcripts count toward the session; working time comes from the turn records.
        let folder = URL(fileURLWithPath: path).deletingPathExtension().appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sub = [assistant("a1", tokens: [1, 2, 3, 4], at: "2026-01-01T10:00:00.000Z", []),
                   assistant("a1", tokens: [1, 2, 3, 4], at: "2026-01-01T10:00:01.000Z", [])]
        try FileManager.default.moveItem(atPath: try transcript(sub), toPath: folder.appendingPathComponent("agent-1.jsonl").path)
        let timed = lines + [["type": "system", "subtype": "turn_duration", "durationMs": 90_000],
                             ["type": "system", "subtype": "turn_duration", "durationMs": 30_000]]
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.moveItem(atPath: try transcript(timed), toPath: path)
        let whole = try #require(SessionAnalysis.analyze(path: path))
        #expect(whole.subagentTokens == 10 && whole.tokens == 2230 && whole.responses == 6 && whole.seconds == 120)
        #expect(SessionAnalysis.summary(whole.json).contains("10 of the tokens in subagents, 2 min working"))
    }

    @Test func repeatsCountWithinOneStretchOfWork() throws {
        // The same file read twice in each of three turns, and across a compaction: nothing to flag.
        var lines: [[String: Any]] = []
        for turn in 0..<3 {
            lines.append(["type": "user", "message": ["content": "again"]])
            lines.append(assistant("r\(turn)", model: "claude-haiku-x", at: "2026-01-01T10:00:00.000Z",
                                   [tool("Read", ["file_path": "/p/a.swift"]), tool("Read", ["file_path": "/p/a.swift"]),
                                    tool("Bash", ["command": "make"]), tool("Bash", ["command": "make"])]))
        }
        lines.append(["type": "system", "subtype": "compact_boundary"])
        lines.append(assistant("r9", model: "claude-haiku-x", at: "2026-01-01T10:00:00.000Z",
                               [tool("Read", ["file_path": "/p/a.swift"]), tool("Bash", ["command": "make"])]))
        let stats = try #require(SessionAnalysis.analyze(path: try transcript(lines)))
        #expect(stats.toolCalls == 14 && stats.turns == 3)
        #expect(stats.flags == ["Context compacted 1 time: earlier work had to be summarized"])
        #expect(SessionAnalysis.isPrompt([:], text: " plain words") && !SessionAnalysis.isPrompt([:], text: nil))
    }

    @Test func flagsACacheThatIsNotReusedAndALargeModelOnASmallJob() throws {
        let cold = (1...10).map { assistant("c\($0)", model: "claude-sonnet-x", tokens: [100, 10, 50, 900], at: "2026-01-01T10:00:00.000Z", []) }
        #expect(try #require(SessionAnalysis.analyze(path: try transcript(cold))).flags
            == ["Prompt cache reused for only 4% of the input: long pauses between steps"])
        let small = [assistant("s1", at: "2026-01-01T10:00:00.000Z", [["type": "text", "text": "42"]])]
        #expect(try #require(SessionAnalysis.analyze(path: try transcript(small))).flags == ["Small job on a large model: a lower tier would do"])
        let fine = [assistant("s1", model: "claude-haiku-x", at: "2026-01-01T10:00:00.000Z", [["type": "text", "text": "42"]])]
        let stats = try #require(SessionAnalysis.analyze(path: try transcript(fine)))
        #expect(stats.flags.isEmpty && stats.compactions == 0)
        #expect(SessionAnalysis.flags(SessionStats(), calls: [:], reads: [:]).isEmpty)
    }
}
