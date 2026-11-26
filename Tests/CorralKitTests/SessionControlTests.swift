import AppKit
import Testing
@testable import CorralCore
@testable import CorralKit

@MainActor
@Suite(.serialized) struct SessionControlTests {
    /// A manager with the command on and one Claude session (the orchestrator).
    private func setup(control: Bool = true) throws -> (Fixture, UUID) {
        let f = Fixture()
        f.manager.setControl(control)
        let boss = f.manager.newSession(agent: .claude, cwd: f.dir.path)
        return (f, boss)
    }

    private func ask(_ f: Fixture, _ request: [String: Any]) -> [String: Any] {
        var answer: [String: Any] = [:]
        f.manager.handleControl(request) { answer = $0 }
        return answer
    }

    private func spawn(_ f: Fixture, from boss: UUID?, _ more: [String: Any] = [:]) throws -> UUID {
        var request: [String: Any] = ["cmd": "spawn", "agent": "claude", "cwd": f.dir.path]
        if let boss { request["caller"] = boss.uuidString }
        request.merge(more) { $1 }
        let answer = ask(f, request)
        let raw = (answer["session"] as? [String: Any])?["id"] as? String ?? ""
        return try #require(UUID(uuidString: raw), "\(answer)")
    }

    private func hook(_ event: String, message: String? = nil, tool: String? = nil) -> HookEvent {
        HookEvent(agent: .claude, event: event, message: message, tool: tool)
    }

    private func state(_ f: Fixture, _ id: UUID) -> String { f.manager.controlState(id) }

    @Test func offUntilTheUserTurnsItOn() throws {
        let (f, _) = try setup(control: false)
        defer { f.cleanup() }
        let answer = ask(f, ["cmd": "list"])
        #expect(answer["ok"] as? Bool == false && answer["error"] as? String == SessionManager.controlOff)
        #expect(f.manager.live.count == 1)
        f.manager.setControl(true)
        f.manager.setControl(true)
        #expect(ask(f, ["cmd": "list"])["ok"] as? Bool == true)
        #expect(ask(f, ["cmd": "dance"])["error"] as? String == "Unknown command dance")
    }

    @Test func spawnStartsAChildBelowItsParentWithoutTakingTheScreen() throws {
        let (f, boss) = try setup()
        defer { f.cleanup() }
        let other = f.manager.newSession(agent: .shell, cwd: f.dir.path)
        f.manager.select(boss)
        let id = try spawn(f, from: boss, ["model": "easy", "prompt": "count the files", "name": "Counter",
                                           "extra": ["--permission-mode", "plan"]])
        let record = try #require(f.manager.workspace.sessions[id])
        #expect(record.parent == boss && record.model == "haiku" && record.customName == "Counter" && record.agent == .claude)
        let sid = try #require(record.agentSessionId)
        let launch = try #require(f.terminal(id)?.launch)
        #expect(launch.agentInput == "claude --session-id \(sid) --model haiku --permission-mode plan 'count the files'")
        #expect(launch.env[CorralCLI.sessionVariable] == id.uuidString && launch.cwd == f.dir.path)
        #expect(f.selected == boss)
        #expect(f.manager.workspace.openSessionsInOrder == [boss, id, other])
        #expect(state(f, id) == "starting")
        // Resumed after a restart, it stays on its model.
        #expect(record.restoreInput == "claude --resume \(sid) --model haiku")
        // --focus shows it; an exact model name is passed on; no model leaves it to the agent.
        let shown = try spawn(f, from: boss, ["focus": true, "model": "claude-x-9"])
        #expect(f.selected == shown && f.terminal(shown)?.launch.agentInput?.hasSuffix("--model claude-x-9") == true)
        let plain = try spawn(f, from: nil)
        #expect(f.manager.workspace.sessions[plain]?.parent == nil && f.manager.workspace.sessions[plain]?.model == nil)
        #expect(f.terminal(plain)?.launch.agentInput?.contains("--model") == false)
    }

    @Test func spawnRefusesWhatCannotStart() throws {
        let f = Fixture { $0.agentInstalled = { agent, _ in agent != .pi } }
        defer { f.cleanup() }
        f.manager.setControl(true)
        #expect(ask(f, ["cmd": "spawn", "agent": "pi", "cwd": f.dir.path])["error"] as? String == "PI isn't installed on this Mac.")
        #expect((ask(f, ["cmd": "spawn", "agent": "shell"])["error"] as? String)?.hasPrefix("Unknown agent") == true)
        #expect((ask(f, ["cmd": "spawn", "agent": "vim"])["error"] as? String)?.hasPrefix("Unknown agent") == true)
        #expect(ask(f, ["cmd": "spawn", "agent": "claude", "cwd": "/no/such/dir"])["error"] as? String == "No such directory: /no/such/dir")
        for extra in [["--dangerously-skip-permissions"], ["--permission-mode", "bypassPermissions"]] {
            #expect(ask(f, ["cmd": "spawn", "agent": "claude", "cwd": f.dir.path, "extra": extra])["error"] as? String
                == "Sessions started through corral keep their permission prompts.")
        }
        let long = String(repeating: "a", count: SessionManager.maxPrompt + 1)
        #expect((ask(f, ["cmd": "spawn", "agent": "claude", "cwd": f.dir.path, "prompt": long])["error"] as? String)?
            .hasPrefix("The prompt is too long") == true)
        #expect(f.manager.live.isEmpty)
    }

    @Test func newSessionsStartOnTheStandardTier() throws {
        let f = Fixture()
        defer { f.cleanup() }
        var models = f.manager.workspace.settings.models(for: .claude)
        models.standard = .high
        f.manager.setModels(models, for: .claude)
        f.manager.setModels(models, for: .claude)
        let id = f.manager.newSession(agent: .claude, cwd: f.dir.path)
        #expect(f.terminal(id)?.launch.agentInput?.hasSuffix("--model opus") == true)
        #expect(f.manager.workspace.sessions[id]?.model == "opus")
        // Not for a session that resumes a conversation, nor for agents without that tier.
        let resumed = f.manager.newSession(agent: .claude, cwd: f.dir.path, input: "claude --resume abc", agentSessionId: "abc")
        #expect(f.terminal(resumed)?.launch.agentInput == "claude --resume abc" && f.manager.workspace.sessions[resumed]?.model == nil)
        let pi = f.manager.newSession(agent: .pi, cwd: f.dir.path)
        #expect(f.terminal(pi)?.launch.agentInput == "pi")
        let shell = f.manager.newSession(agent: .shell, cwd: f.dir.path)
        #expect(f.terminal(shell)?.launch.agentInput == nil)
    }

    @Test func listAndStatusReadSessionsByIdPrefix() throws {
        let (f, boss) = try setup()
        defer { f.cleanup() }
        let child = try spawn(f, from: boss, ["name": "Child", "model": "medium"])
        let all = try #require(ask(f, ["cmd": "list"])["sessions"] as? [[String: Any]])
        #expect(all.map { $0["id"] as? String } == [boss, child].map { $0.uuidString.lowercased() })
        let mine = try #require(ask(f, ["cmd": "list", "mine": true, "caller": boss.uuidString])["sessions"] as? [[String: Any]])
        #expect(mine.count == 1 && mine[0]["name"] as? String == "Child" && mine[0]["parent"] as? String == boss.uuidString.lowercased())
        #expect(mine[0]["model"] as? String == "sonnet" && mine[0]["agent"] as? String == "claude")
        #expect(ask(f, ["cmd": "list", "mine": true])["error"] as? String == "--mine works inside a Corral session.")
        let prefix = String(child.uuidString.prefix(8))
        let status = try #require(ask(f, ["cmd": "status", "id": prefix])["session"] as? [String: Any])
        #expect(status["id"] as? String == child.uuidString.lowercased())
        #expect((ask(f, ["cmd": "status", "id": "zzzz"])["error"] as? String)?.hasPrefix("No open session") == true)
        #expect((ask(f, ["cmd": "status", "id": ""])["error"] as? String)?.hasPrefix("No open session") == true)
        #expect(ask(f, ["cmd": "status"])["error"] as? String == "Which session?")
    }

    @Test func statesFollowTheSession() throws {
        let (f, boss) = try setup()
        defer { f.cleanup() }
        let id = try spawn(f, from: boss)
        #expect(state(f, id) == "starting")
        // The agent shows (its first hook, or the launch probe).
        f.manager.launchReady(id)
        #expect(state(f, id) == "idle")
        f.manager.apply(.hook(hook("UserPromptSubmit")), to: id)
        #expect(state(f, id) == "working")
        f.manager.apply(.hook(hook("PermissionRequest", message: "Bash: ls", tool: "Bash")), to: id)
        #expect(state(f, id) == "needs_permission")
        f.manager.apply(.hook(hook("PermissionRequest", tool: "AskUserQuestion")), to: id)
        #expect(state(f, id) == "needs_input")
        f.manager.apply(.hook(hook("Stop")), to: id)
        #expect(state(f, id) == "done")
        f.manager.apply(.hook(hook("StopFailure", message: "API error")), to: id)
        #expect(state(f, id) == "error")
        // The agent quits: the terminal is a shell again, the record still names the agent.
        f.manager.apply(.hook(hook("SessionEnd")), to: id)
        #expect(state(f, id) == "exited")
        #expect((ask(f, ["cmd": "status", "id": id.uuidString])["session"] as? [String: Any])?["agent"] as? String == "claude")
        f.manager.apply(.foregroundProcess(.claude), to: id)
        #expect(state(f, id) == "idle")
        f.manager.apply(.processExited, to: id)
        #expect(state(f, id) == "exited")
        #expect(state(f, UUID()) == "starting")
    }

    @Test func waitReturnsEachEventOnce() throws {
        let (f, boss) = try setup()
        defer { f.cleanup() }
        let id = try spawn(f, from: boss)
        var answers: [[String: Any]] = []
        let waiting: [String: Any] = ["cmd": "wait", "caller": boss.uuidString]
        f.manager.handleControl(waiting) { answers.append($0) }
        f.manager.apply(.hook(hook("UserPromptSubmit")), to: id)
        #expect(answers.isEmpty && f.manager.control.waiters.count == 1)

        // A permission prompt: the request comes with it.
        f.manager.handleHook(.init(surface: id, event: {
            var e = hook("PermissionRequest", message: "Bash: git push", tool: "Bash")
            e.toolInput = #"{"command":"git push"}"#
            return e
        }()))
        #expect(answers.count == 1 && f.manager.control.waiters.isEmpty)
        #expect((answers[0]["session"] as? [String: Any])?["state"] as? String == "needs_permission")
        #expect((answers[0]["session"] as? [String: Any])?["detail"] as? String == "Bash: git push")
        #expect(answers[0]["request"] as? String == #"{"command":"git push"}"#)
        // Reported: the next wait blocks instead of repeating it.
        f.manager.handleControl(waiting) { answers.append($0) }
        #expect(answers.count == 1 && f.manager.control.waiters.count == 1)

        #expect(ask(f, ["cmd": "approve", "id": id.uuidString, "caller": boss.uuidString])["ok"] as? Bool == true)
        #expect(f.terminal(id)?.bindings.last == "text:1" && state(f, id) == "working")
        #expect(f.manager.control.requests[id] == nil)

        // The turn ends: the result is the closing message.
        f.manager.handleHook(.init(surface: id, event: {
            var e = hook("Stop")
            e.lastMessage = "Pushed 2 commits."
            return e
        }()))
        #expect(answers.count == 2 && answers[1]["result"] as? String == "Pushed 2 commits.")
        #expect((answers[1]["session"] as? [String: Any])?["state"] as? String == "done")
        // Something that happened while nobody waited is reported by the next wait at once.
        f.manager.handleHook(.init(surface: id, event: hook("UserPromptSubmit")))
        f.manager.apply(.hook(hook("StopFailure", message: "API error")), to: id)
        f.manager.handleControl(waiting) { answers.append($0) }
        #expect(answers.count == 3 && (answers[2]["session"] as? [String: Any])?["state"] as? String == "error")
        #expect(answers[2]["result"] == nil && f.manager.control.results[id] == nil)
        // The agent quits: reported once, whatever the shell left behind does afterwards.
        f.manager.apply(.hook(hook("SessionEnd")), to: id)
        f.manager.handleControl(waiting) { answers.append($0) }
        #expect(answers.count == 4 && (answers[3]["session"] as? [String: Any])?["state"] as? String == "exited")
        f.manager.handleControl(waiting) { answers.append($0) }
        f.manager.apply(.commandFinished(exitCode: 0, seconds: 60), to: id)
        #expect(answers.count == 4)
        // Turned off: whoever still waits is told, and nothing cached stays.
        f.manager.setControl(false)
        #expect(answers.count == 5 && answers[4]["error"] as? String == SessionManager.controlOff)
        #expect(f.manager.control.waiters.isEmpty)
    }

    @Test func waitWatchesNamedSessionsOrTheCallersChildren() throws {
        let (f, boss) = try setup()
        defer { f.cleanup() }
        let child = try spawn(f, from: boss)
        let stranger = try spawn(f, from: nil)
        var mine: [[String: Any]] = [], named: [[String: Any]] = []
        f.manager.handleControl(["cmd": "wait", "caller": boss.uuidString]) { mine.append($0) }
        f.manager.handleControl(["cmd": "wait", "ids": [String(stranger.uuidString.prefix(8))]]) { named.append($0) }
        f.manager.apply(.hook(hook("Stop")), to: stranger)
        #expect(mine.isEmpty && named.count == 1)
        f.manager.apply(.hook(hook("Stop")), to: child)
        #expect(mine.count == 1)
        // The orchestrator's own events don't wake its wait.
        f.manager.handleControl(["cmd": "wait", "caller": boss.uuidString]) { mine.append($0) }
        f.manager.apply(.hook(hook("Stop")), to: boss)
        #expect(mine.count == 1)
        // Who to wait for has to be clear.
        #expect((ask(f, ["cmd": "wait"])["error"] as? String)?.hasPrefix("Which sessions?") == true)
        #expect(ask(f, ["cmd": "wait", "caller": child.uuidString])["error"] as? String == "No open sessions to wait for.")
        #expect((ask(f, ["cmd": "wait", "ids": ["nope"]])["error"] as? String)?.hasPrefix("No open session") == true)
        // A caller that isn't an open session counts as none.
        #expect((ask(f, ["cmd": "wait", "caller": UUID().uuidString])["error"] as? String)?.hasPrefix("Which sessions?") == true)
    }

    @Test func waitEndsOnTimeoutCloseAndWhenTheClientLeaves() async throws {
        let (f, boss) = try setup()
        defer { f.cleanup() }
        let child = try spawn(f, from: boss)
        var answers: [[String: Any]] = []
        f.manager.handleControl(["cmd": "wait", "caller": boss.uuidString, "timeout": 0.05]) { answers.append($0) }
        await waitUntil { !answers.isEmpty }
        #expect(answers.first?["timeout"] as? Bool == true && (answers.first?["sessions"] as? [[String: Any]])?.count == 1)
        #expect(f.manager.control.waiters.isEmpty)

        // The client goes away (Ctrl-C): the waiter goes with it, and its timeout never answers.
        let cancel = f.manager.handleControl(["cmd": "wait", "caller": boss.uuidString, "timeout": 0.05]) { answers.append($0) }
        #expect(f.manager.control.waiters.count == 1)
        cancel?()
        #expect(f.manager.control.waiters.isEmpty)
        try await Task.sleep(for: .milliseconds(120))
        #expect(answers.count == 1)

        // A watched session that closes is reported as closed, to everyone watching it.
        var first: [[String: Any]] = [], second: [[String: Any]] = []
        f.manager.handleControl(["cmd": "wait", "caller": boss.uuidString, "timeout": 30]) { first.append($0) }
        f.manager.handleControl(["cmd": "wait", "ids": [child.uuidString]]) { second.append($0) }
        #expect(ask(f, ["cmd": "close", "id": child.uuidString, "caller": boss.uuidString])["ok"] as? Bool == true)
        #expect(f.manager.live[child] == nil && f.manager.control.waiters.isEmpty)
        for answer in [first, second] {
            #expect(answer.count == 1 && (answer.first?["session"] as? [String: Any])?["state"] as? String == "closed")
        }
        // Nothing of the closed session is kept.
        #expect(f.manager.control.delivered.isEmpty && f.manager.control.results.isEmpty && f.manager.control.quit.isEmpty)
        #expect(ask(f, ["cmd": "close", "id": boss.uuidString, "caller": boss.uuidString])["error"] as? String
            == "A session can't close itself this way.")
    }

    @Test func approveAndDenyAnswerOnlyARealPermissionPrompt() throws {
        let (f, boss) = try setup()
        defer { f.cleanup() }
        let id = try spawn(f, from: boss)
        let typed = { f.terminal(id)?.bindings ?? [] }
        // Nothing is up.
        #expect((ask(f, ["cmd": "approve", "id": id.uuidString])["error"] as? String)?.contains("state: starting") == true)
        f.manager.launchReady(id)
        // A question isn't a permission prompt.
        f.manager.apply(.hook(hook("PermissionRequest", tool: "AskUserQuestion")), to: id)
        #expect(ask(f, ["cmd": "approve", "id": id.uuidString])["ok"] as? Bool == false && typed().isEmpty)
        f.manager.apply(.hook(hook("PermissionRequest", message: "Bash: rm -rf build", tool: "Bash")), to: id)
        // Not by the session itself.
        #expect(ask(f, ["cmd": "approve", "id": id.uuidString, "caller": id.uuidString])["error"] as? String
            == "A session can't answer its own prompt.")
        #expect(typed().isEmpty)
        #expect(ask(f, ["cmd": "deny", "id": id.uuidString, "caller": boss.uuidString])["ok"] as? Bool == true)
        #expect(typed() == ["text:\\x1b"] && state(f, id) == "idle")
        #expect(ask(f, ["cmd": "deny", "id": id.uuidString])["ok"] as? Bool == false)
        #expect(ask(f, ["cmd": "approve"])["error"] as? String == "Which session?")
    }

    @Test func sendTypesAPromptAndSubmitsIt() async throws {
        let (f, boss) = try setup()
        defer { f.cleanup() }
        SessionManager.submitDelay = 0.01
        let id = try spawn(f, from: boss)
        let terminal = try #require(f.terminal(id))
        f.manager.apply(.hook(hook("Stop")), to: id)
        #expect(ask(f, ["cmd": "send", "id": id.uuidString, "text": "now run: make test"])["ok"] as? Bool == true)
        #expect(terminal.bindings == ["text:now run\\x3a make test"])
        await waitUntil { terminal.bindings.count == 2 }
        #expect(terminal.bindings.last == "text:\\r")
        // Several lines are pasted as one block.
        _ = ask(f, ["cmd": "send", "id": id.uuidString, "text": "a\nb"])
        #expect(terminal.bindings.last == "text:\\x1b\\x5b200\\x7ea\\x0ab\\x1b\\x5b201\\x7e")
        await waitUntil { terminal.bindings.count == 4 }
        // --raw: keys only, also at a prompt; a plain send would answer the permission prompt by accident.
        f.manager.apply(.hook(hook("PermissionRequest", message: "Bash: ls", tool: "Bash")), to: id)
        #expect((ask(f, ["cmd": "send", "id": id.uuidString, "text": "hello"])["error"] as? String)?.contains("approve or deny") == true)
        #expect(ask(f, ["cmd": "send", "id": id.uuidString, "text": "2", "raw": true])["ok"] as? Bool == true)
        #expect(terminal.bindings.count == 5 && terminal.bindings.last == "text:2")
        try await Task.sleep(for: .milliseconds(60))
        #expect(terminal.bindings.count == 5)
        // A text can't end the paste it travels in.
        f.manager.apply(.hook(hook("Stop")), to: id)
        _ = ask(f, ["cmd": "send", "id": id.uuidString, "text": "a\n\u{1b}[201~b"])
        #expect(terminal.bindings.last == "text:\\x1b\\x5b200\\x7ea\\x0ab\\x1b\\x5b201\\x7e")
        await waitUntil { terminal.bindings.count == 7 }
        terminal.bindingResult = false
        #expect(ask(f, ["cmd": "send", "id": id.uuidString, "text": "x", "raw": true])["error"] as? String == "The terminal didn't take the text.")
        #expect(ask(f, ["cmd": "send", "text": "x"])["error"] as? String == "Which session?")
        // Back at its shell, typed text would be a command: refused, raw or not.
        terminal.bindingResult = true
        f.manager.apply(.hook(hook("SessionEnd")), to: id)
        for raw in [true, false] {
            #expect(ask(f, ["cmd": "send", "id": id.uuidString, "text": "rm -rf x", "raw": raw])["error"] as? String
                == "No agent is running in that session.")
        }
        #expect(terminal.bindings.count == 8)
        #expect(SessionManager.textBinding("é ok") == "text:\\xc3\\xa9 ok")
        #expect(!f.manager.typeText("x", into: UUID(), submit: true))
    }

    @Test func outputIsTheLastAnswerOrTheScreen() throws {
        let (f, boss) = try setup()
        defer { f.cleanup() }
        let id = try spawn(f, from: boss)
        let terminal = try #require(f.terminal(id))
        terminal.text = "one\ntwo  \nthree\n\n\n"
        // No answer yet: the screen.
        #expect(ask(f, ["cmd": "output", "id": id.uuidString])["text"] as? String == "one\ntwo\nthree")
        #expect(ask(f, ["cmd": "output", "id": id.uuidString, "lines": 1])["text"] as? String == "three")
        // The transcript, when the Stop hook carried no message.
        let transcript = f.dir.appendingPathComponent("t.jsonl")
        let line: [String: Any] = ["type": "assistant", "message": ["content": [["type": "text", "text": "From the transcript."]]]]
        try JSONSerialization.data(withJSONObject: line).write(to: transcript)
        var stop = hook("Stop")
        stop.transcriptPath = transcript.path
        f.manager.handleHook(.init(surface: id, event: stop))
        #expect(ask(f, ["cmd": "output", "id": id.uuidString])["text"] as? String == "From the transcript.")
        #expect(ask(f, ["cmd": "status", "id": id.uuidString])["result"] as? String == "From the transcript.")
        stop.lastMessage = "From the hook."
        f.manager.handleHook(.init(surface: id, event: stop))
        #expect(ask(f, ["cmd": "output", "id": id.uuidString])["text"] as? String == "From the hook.")
        #expect(ask(f, ["cmd": "output", "id": id.uuidString, "screen": true])["text"] as? String == "one\ntwo\nthree")
        #expect(ask(f, ["cmd": "output"])["error"] as? String == "Which session?")
        // Hooks for a session that isn't open leave nothing behind.
        f.manager.controlNote(.init(surface: UUID(), event: stop))
        #expect(f.manager.control.results.count == 1)
    }

    @Test func theCommandReachesTheAppOverItsSocket() async throws {
        let path = NSTemporaryDirectory() + "ctl-\(UInt32.random(in: 0...UInt32.max)).sock"
        let f = Fixture(start: true) { $0.controlPath = path }
        defer { f.cleanup() }
        f.manager.setControl(true)
        func run(_ args: [String]) async -> (Int32, [String]) {
            await withCheckedContinuation { done in
                DispatchQueue.global().async {
                    var io = CorralCLI.IO()
                    var out: [String] = []
                    io.out = { out.append($0) }
                    io.err = { out.append($0) }
                    io.env = [:]
                    io.cwd = f.dir.path
                    io.request = { ControlClient.request($0, path: path, timeout: $1) }
                    io.launchApp = { false }
                    io.appRunning = { false }
                    let status = CorralCLI.run(args, io: io)
                    done.resume(returning: (status, out))
                }
            }
        }
        let (status, out) = await run(["spawn", "--name", "Over the wire", "--model", "high", "say hi"])
        #expect(status == 0 && out.first?.contains("starting  claude  Over the wire") == true)
        let id = try #require(f.manager.workspace.openSessionsInOrder.first)
        #expect(f.terminal(id)?.launch.agentInput?.hasSuffix("--model opus 'say hi'") == true)
        // wait blocks in the client until the session's turn ends.
        async let waited = run(["wait", String(id.uuidString.prefix(8))])
        await waitUntil { f.manager.control.waiters.count == 1 }
        var stop = HookEvent(agent: .claude, event: "Stop")
        stop.lastMessage = "hi"
        f.manager.handleHook(.init(surface: id, event: stop))
        let (waitStatus, waitOut) = await waited
        #expect(waitStatus == 0 && waitOut.first?.hasSuffix("result:\nhi") == true)
        let (off, offOut) = await { f.manager.setControl(false); return await run(["list"]) }()
        #expect(off == 1 && offOut == ["corral: " + SessionManager.controlOff])
    }
}

@MainActor
@Suite(.serialized) struct SessionCallbackTests {
    private func ask(_ f: Fixture, _ request: [String: Any]) -> [String: Any] {
        var answer: [String: Any] = [:]
        f.manager.handleControl(request) { answer = $0 }
        return answer
    }

    private func setup(configure: ((inout ManagerEnvironment) -> Void)? = nil) throws -> (Fixture, UUID, UUID) {
        let f = Fixture(configure: configure)
        f.manager.setControl(true)
        // Hooks installed, so spawn has nothing to warn about.
        _ = try Integrations.installClaude(settingsURL: f.env.integrationPaths.claudeSettings)
        f.manager.refreshIntegrations()
        let boss = f.manager.newSession(agent: .claude, cwd: f.dir.path)
        let answer = ask(f, ["cmd": "spawn", "agent": "claude", "cwd": f.dir.path, "caller": boss.uuidString, "prompt": "do it"])
        #expect(answer["note"] == nil && answer["screen"] == nil)
        let child = try #require(UUID(uuidString: (answer["session"] as? [String: Any])?["id"] as? String ?? ""))
        f.manager.launchReady(child)
        return (f, boss, child)
    }

    private func hook(_ event: String, message: String? = nil, tool: String? = nil) -> HookWire.Message {
        .init(surface: UUID(), event: HookEvent(agent: .claude, event: event, message: message, tool: tool))
    }

    private func send(_ f: Fixture, _ id: UUID, _ event: String, message: String? = nil, tool: String? = nil) {
        var m = hook(event, message: message, tool: tool)
        m.surface = id
        f.manager.handleHook(m)
    }

    @Test func aStartedSessionReportsItsResult() throws {
        let (f, boss, child) = try setup()
        defer { f.cleanup() }
        send(f, child, "UserPromptSubmit")
        #expect(ask(f, ["cmd": "report", "caller": child.uuidString, "text": "3 tests fixed"])["ok"] as? Bool == true)
        var answers: [[String: Any]] = []
        f.manager.handleControl(["cmd": "wait", "caller": boss.uuidString]) { answers.append($0) }
        send(f, child, "Stop")
        let report = try #require(answers.first?["report"] as? [String: Any])
        #expect(report["text"] as? String == "3 tests fixed" && report["failed"] as? Bool == false)
        // The next turn starts clean; a failure is marked.
        send(f, child, "UserPromptSubmit")
        #expect(ask(f, ["cmd": "status", "id": child.uuidString])["report"] == nil)
        _ = ask(f, ["cmd": "report", "caller": child.uuidString, "text": String(repeating: "x", count: 9_000), "failed": true])
        let long = try #require(ask(f, ["cmd": "status", "id": child.uuidString])["report"] as? [String: Any])
        #expect(long["failed"] as? Bool == true && (long["text"] as? String)?.count == SessionManager.maxReport)
        #expect((ask(f, ["cmd": "report", "text": "x"])["error"] as? String)?.hasPrefix("corral report works inside") == true)
        #expect(ask(f, ["cmd": "report", "caller": child.uuidString])["error"] as? String == "Nothing to report.")
        f.manager.close(child)
        #expect(f.manager.control.reports.isEmpty)
    }

    @Test func waitDoneSkipsPromptsAndLeavesThemToOthers() throws {
        let (f, boss, child) = try setup()
        defer { f.cleanup() }
        var final: [[String: Any]] = [], any: [[String: Any]] = []
        f.manager.handleControl(["cmd": "wait", "caller": boss.uuidString, "final": true]) { final.append($0) }
        send(f, child, "PermissionRequest", message: "Bash: ls", tool: "Bash")
        #expect(final.isEmpty)
        // Not reported yet: a plain wait still gets it, at once.
        f.manager.handleControl(["cmd": "wait", "caller": boss.uuidString]) { any.append($0) }
        #expect(any.count == 1 && (any[0]["session"] as? [String: Any])?["state"] as? String == "needs_permission")
        send(f, child, "Stop")
        #expect(final.count == 1 && (final[0]["session"] as? [String: Any])?["state"] as? String == "done")
        // Already at its end when the wait starts.
        send(f, child, "UserPromptSubmit")
        send(f, child, "StopFailure", message: "API error")
        f.manager.handleControl(["cmd": "wait", "caller": boss.uuidString, "final": true]) { final.append($0) }
        #expect(final.count == 2)
    }

    @Test func theUserIsNotNotifiedOfWhatAnOrchestratorHandles() throws {
        let (f, boss, child) = try setup { $0.notifications = true }
        defer { f.cleanup() }
        f.manager.select(boss)
        send(f, child, "UserPromptSubmit")
        // Nobody waits: the user hears about the prompt.
        send(f, child, "PermissionRequest", message: "Bash: ls", tool: "Bash")
        #expect(f.effects.notes.count == 1)
        _ = ask(f, ["cmd": "approve", "id": child.uuidString])
        // An orchestrator waits for it: it is told, the user isn't.
        var answers: [[String: Any]] = []
        f.manager.handleControl(["cmd": "wait", "caller": boss.uuidString]) { answers.append($0) }
        send(f, child, "PermissionRequest", message: "Bash: make", tool: "Bash")
        #expect(answers.count == 1 && f.effects.notes.count == 1)
        _ = ask(f, ["cmd": "approve", "id": child.uuidString])
        // One that only waits for the end doesn't take prompts off the user.
        f.manager.handleControl(["cmd": "wait", "caller": boss.uuidString, "final": true]) { answers.append($0) }
        send(f, child, "PermissionRequest", message: "Bash: rm x", tool: "Bash")
        #expect(answers.count == 1 && f.effects.notes.count == 2)
        #expect(!f.manager.controlWatched(boss))
        // What was already reported isn't held back a second time: with the agent gone, a long command
        // ending in its shell is the user's news.
        _ = ask(f, ["cmd": "deny", "id": child.uuidString])
        send(f, child, "SessionEnd")
        f.manager.handleControl(["cmd": "wait", "caller": boss.uuidString]) { answers.append($0) }
        #expect(answers.count == 2 && (answers[1]["session"] as? [String: Any])?["state"] as? String == "exited")
        f.manager.handleControl(["cmd": "wait", "caller": boss.uuidString]) { answers.append($0) }
        let before = f.effects.notes.count
        f.manager.apply(.commandFinished(exitCode: 0, seconds: 60), to: child)
        #expect(answers.count == 2 && f.effects.notes.count == before + 1)
    }

    @Test func spawnAddsTheStandingNoteAndWarnsWithoutHooks() throws {
        let f = Fixture()
        defer { f.cleanup() }
        f.manager.setControl(true)
        #expect(f.manager.workspace.settings.spawnNote == AppSettings.defaultSpawnNote && !f.manager.workspace.settings.spawnNoteOn)
        func spawned(_ request: [String: Any]) throws -> (String?, [String: Any]) {
            let answer = ask(f, ["cmd": "spawn", "agent": "claude", "cwd": f.dir.path].merging(request) { $1 })
            let id = try #require(UUID(uuidString: (answer["session"] as? [String: Any])?["id"] as? String ?? ""))
            return (f.terminal(id)?.launch.agentInput, answer)
        }
        let (plain, answer) = try spawned(["prompt": "count"])
        #expect(plain?.hasSuffix(" count") == true)
        // No hooks installed: said once, with the session.
        #expect((answer["note"] as? String)?.hasPrefix("Claude Code's status hooks aren't installed") == true)
        f.manager.setSpawnNote(on: true, text: "Answer in one line.")
        f.manager.setSpawnNote(on: true, text: "Answer in one line.")
        #expect(try spawned(["prompt": "count"]).0?.hasSuffix(" 'count\n\nAnswer in one line.'") == true)
        // Nothing to add to a session started without a prompt, and nothing when the text is blank.
        #expect(try spawned([:]).0?.contains("Answer") == false)
        f.manager.setSpawnNote(on: true, text: "  ")
        #expect(try spawned(["prompt": "count"]).0?.hasSuffix(" count") == true)
        // The addition counts toward the prompt's limit.
        f.manager.setSpawnNote(on: true, text: String(repeating: "n", count: SessionManager.maxPrompt))
        #expect((ask(f, ["cmd": "spawn", "agent": "claude", "cwd": f.dir.path, "prompt": "count"])["error"] as? String)?
            .hasPrefix("The prompt is too long") == true)
    }

    @Test func statusShowsTheScreenOfASessionThatSitsThere() throws {
        let (f, _, child) = try setup()
        defer { f.cleanup() }
        f.terminal(child)?.text = "Do you trust the files in this folder?\n> Yes\n"
        #expect(ask(f, ["cmd": "status", "id": child.uuidString])["screen"] as? String == "Do you trust the files in this folder?\n> Yes")
        send(f, child, "UserPromptSubmit")
        #expect(ask(f, ["cmd": "status", "id": child.uuidString])["screen"] == nil)
        // Not a plain shell's.
        let shell = f.manager.newSession(agent: .shell, cwd: f.dir.path)
        f.terminal(shell)?.text = "$ secret"
        #expect(ask(f, ["cmd": "status", "id": shell.uuidString])["screen"] == nil)
    }

    @Test func foldersGroupSessionsFromTheCommandLine() throws {
        let (f, boss, child) = try setup()
        defer { f.cleanup() }
        let m = f.manager!
        func folders() -> [String] { (ask(f, ["cmd": "folder", "action": "list"])["folders"] as? [[String: Any]] ?? []).map { "\($0["path"]!) \($0["sessions"]!) \($0["expanded"]!)" } }
        // The setup's spawn named no folder: it went into one of the boss's own.
        let own = "\(m.workspace.sessions[boss]!.displayTitle) · agents"
        #expect(folders() == ["\(own) 1 true"])
        // spawn --folder makes the path and wins over "below the parent".
        let answer = ask(f, ["cmd": "spawn", "agent": "claude", "cwd": f.dir.path, "caller": boss.uuidString, "folder": "Jobs / Disk"])
        let inFolder = try #require(UUID(uuidString: (answer["session"] as? [String: Any])?["id"] as? String ?? ""))
        #expect((answer["session"] as? [String: Any])?["folder"] as? String == "Jobs/Disk")
        #expect(folders() == ["\(own) 1 true", "Jobs 0 true", "Jobs/Disk 1 true"])
        // Names match without case; nothing is made twice.
        #expect(m.resolveFolder("jobs/DISK", create: true) == m.workspace.parent(of: inFolder) ?? nil)
        #expect(m.workspace.folders.count == 3 && m.resolveFolder("Nope", create: false) == nil && m.resolveFolder(" / ", create: true) == nil)
        // Move by id prefix into a new subfolder, then back to the top.
        let moved = ask(f, ["cmd": "folder", "action": "move", "path": "Jobs/Net", "ids": [String(child.uuidString.prefix(8)), boss.uuidString]])
        #expect((moved["sessions"] as? [[String: Any]])?.map { $0["folder"] as? String } == ["Jobs/Net", "Jobs/Net"])
        // Moving out its last session removed the boss's folder.
        #expect(folders() == ["Jobs 0 true", "Jobs/Disk 1 true", "Jobs/Net 2 true"])
        _ = ask(f, ["cmd": "folder", "action": "move", "path": "/", "ids": [boss.uuidString]])
        #expect((m.workspace.parent(of: boss) ?? nil) == nil)
        #expect(ask(f, ["cmd": "folder", "action": "move", "path": "Jobs", "ids": ["zz"]])["ok"] as? Bool == false)
        #expect(ask(f, ["cmd": "folder", "action": "move", "path": "Jobs"])["error"] as? String == "Which sessions?")
        // Collapse hides a group, expand shows it.
        _ = ask(f, ["cmd": "folder", "action": "collapse", "path": "Jobs/Disk"])
        #expect(folders().contains("Jobs/Disk 1 false"))
        _ = ask(f, ["cmd": "folder", "action": "expand", "path": "jobs/disk"])
        #expect(folders().contains("Jobs/Disk 1 true"))
        _ = ask(f, ["cmd": "folder", "action": "create", "path": "Later"])
        _ = ask(f, ["cmd": "folder", "action": "rename", "path": "Jobs", "name": "Work"])
        #expect(folders() == ["Work 0 true", "Work/Disk 1 true", "Work/Net 1 true", "Later 0 true"])
        #expect((ask(f, ["cmd": "folder", "action": "rename", "path": "Work", "name": "a/b"])["error"] as? String)?.contains("slash") == true)
        // Deleting a folder keeps what is in it.
        _ = ask(f, ["cmd": "folder", "action": "delete", "path": "Work/Net"])
        #expect(folders() == ["Work 1 true", "Work/Disk 1 true", "Later 0 true"] && m.live[child] != nil)
        #expect(ask(f, ["cmd": "folder", "action": "delete", "path": "Gone"])["error"] as? String == "No folder Gone.")
        #expect(ask(f, ["cmd": "folder", "action": "create", "path": ""])["error"] as? String == "A folder needs a name.")
        #expect(ask(f, ["cmd": "folder", "action": "paint", "path": "Work"])["error"] as? String == "Unknown folder command paint.")
        #expect(ask(f, ["cmd": "spawn", "agent": "claude", "cwd": f.dir.path, "folder": "/"])["ok"] as? Bool == false)
    }

    @Test func spawnsWithoutAFolderAreGrouped() throws {
        let (f, boss, child) = try setup()
        defer { f.cleanup() }
        let m = f.manager!
        // The boss's folder sits right below it and takes its later spawns too.
        let own = try #require(m.workspace.parent(of: child) ?? nil)
        #expect(m.workspace.folders[own]?.owner == boss && m.workspace.folders[own]?.auto == true)
        let top = m.workspace.tree.map(\.id)
        #expect(top.firstIndex(of: own) == top.firstIndex(of: boss).map { $0 + 1 })
        let second = ask(f, ["cmd": "spawn", "agent": "claude", "cwd": f.dir.path, "caller": boss.uuidString])
        let id = try #require(UUID(uuidString: (second["session"] as? [String: Any])?["id"] as? String ?? ""))
        #expect((m.workspace.parent(of: id) ?? nil) == own)
        // A child's own spawns nest inside the boss's folder.
        let grand = ask(f, ["cmd": "spawn", "agent": "claude", "cwd": f.dir.path, "caller": child.uuidString])
        let g = try #require(UUID(uuidString: (grand["session"] as? [String: Any])?["id"] as? String ?? ""))
        let childOwn = try #require(m.workspace.parent(of: g) ?? nil)
        #expect(childOwn != own && (m.workspace.parent(of: childOwn) ?? nil) == own)
        // Scripts share one folder.
        let a = ask(f, ["cmd": "spawn", "agent": "claude", "cwd": f.dir.path])
        let b = ask(f, ["cmd": "spawn", "agent": "claude", "cwd": f.dir.path])
        let paths = [a, b].map { ($0["session"] as? [String: Any])?["folder"] as? String }
        #expect(paths == [SessionManager.scriptFolder, SessionManager.scriptFolder])
        // Folders the command made go once their last session closes; the user's own stay.
        let mine = m.newFolder(name: "Mine")
        _ = m.move(id, to: mine, at: nil)
        m.close(g)
        #expect(m.workspace.folders[childOwn] == nil && m.workspace.folders[own] != nil)
        m.close(child)
        #expect(m.workspace.folders[own] == nil && m.workspace.folders[mine] != nil)
    }

    @Test func aSessionSteersOnlyWhatItStarted() throws {
        let (f, boss, child) = try setup()
        defer { f.cleanup() }
        let m = f.manager!
        let stranger = m.newSession(agent: .claude, cwd: f.dir.path, select: false)
        let grandchild = m.newSession(agent: .claude, cwd: f.dir.path, parent: child, select: false)
        for id in [stranger, grandchild] {
            m.launchReady(id)
            send(f, id, "PermissionRequest", message: "Bash: ls", tool: "Bash")
        }
        // Its own line of descent: yes. Anyone else's session: no, for approve, deny, send and close.
        #expect(m.mayAct(boss, on: child) && m.mayAct(boss, on: grandchild) && !m.mayAct(child, on: boss) && !m.mayAct(boss, on: stranger))
        #expect(ask(f, ["cmd": "approve", "id": grandchild.uuidString, "caller": boss.uuidString])["ok"] as? Bool == true)
        for request in [["cmd": "approve"], ["cmd": "deny"], ["cmd": "send", "text": "1", "raw": true], ["cmd": "close"]] as [[String: Any]] {
            let answer = ask(f, request.merging(["id": stranger.uuidString, "caller": boss.uuidString]) { $1 })
            #expect(answer["error"] as? String == SessionManager.notYours, "\(request)")
        }
        #expect(f.terminal(stranger)?.bindings.isEmpty == true && m.live[stranger] != nil)
        // Reading stays open, and so does everything for the user's own scripts (no caller).
        #expect(ask(f, ["cmd": "status", "id": stranger.uuidString, "caller": boss.uuidString])["ok"] as? Bool == true)
        #expect(ask(f, ["cmd": "output", "id": stranger.uuidString, "caller": boss.uuidString, "screen": true])["ok"] as? Bool == true)
        #expect(ask(f, ["cmd": "approve", "id": stranger.uuidString])["ok"] as? Bool == true)
        // The user can open it up.
        send(f, stranger, "PermissionRequest", message: "Bash: make", tool: "Bash")
        m.setControlAll(true)
        m.setControlAll(true)
        #expect(ask(f, ["cmd": "approve", "id": stranger.uuidString, "caller": boss.uuidString])["ok"] as? Bool == true)
    }

    @Test func openCodePermissionPromptsAreAnsweredWithReturnAndEscape() throws {
        let f = Fixture()
        defer { f.cleanup() }
        f.manager.setControl(true)
        let id = f.manager.newSession(agent: .opencode, cwd: f.dir.path, select: false)
        f.manager.launchReady(id)
        let terminal = try #require(f.terminal(id))
        func asked() { f.manager.apply(.hook(HookEvent(agent: .opencode, event: "permission.asked", message: "bash: ls")), to: id) }
        // A question isn't a permission prompt.
        f.manager.apply(.hook(HookEvent(agent: .opencode, event: "question.asked", message: "Which one?")), to: id)
        #expect(ask(f, ["cmd": "approve", "id": id.uuidString])["ok"] as? Bool == false && terminal.bindings.isEmpty)
        asked()
        #expect(ask(f, ["cmd": "approve", "id": id.uuidString])["ok"] as? Bool == true)
        #expect(terminal.bindings == ["text:\\r"] && f.manager.controlState(id) == "working")
        asked()
        #expect(ask(f, ["cmd": "deny", "id": id.uuidString])["ok"] as? Bool == true)
        #expect(terminal.bindings.last == "text:\\x1b" && f.manager.controlState(id) == "idle")
        asked()
        terminal.bindingResult = false
        #expect(ask(f, ["cmd": "approve", "id": id.uuidString])["ok"] as? Bool == false)
    }

    @Test func anEndNobodyWaitedForSurvivesARestart() throws {
        let (f, boss, child) = try setup()
        defer { f.cleanup() }
        send(f, child, "UserPromptSubmit")
        var stop = HookEvent(agent: .claude, event: "Stop")
        let transcript = f.dir.appendingPathComponent("t.jsonl")
        let line: [String: Any] = ["type": "assistant", "message": ["content": [["type": "text", "text": "All done."]]]]
        try JSONSerialization.data(withJSONObject: line).write(to: transcript)
        stop.transcriptPath = transcript.path
        f.manager.handleHook(.init(surface: child, event: stop))
        #expect(f.manager.workspace.sessions[child]?.unreported == "done")
        // A prompt nobody waited for isn't kept: after a restart it is gone anyway.
        send(f, boss, "PermissionRequest", message: "Bash: ls", tool: "Bash")
        #expect(f.manager.workspace.sessions[boss]?.unreported == nil)

        // Corral restarts: the child is resumed and sits idle.
        f.manager.saveNow(wait: true)
        f.manager.prepareForTermination()
        f.makeManager()
        f.manager.start()
        #expect(f.manager.controlState(child) != "done" && f.manager.workspace.sessions[child]?.unreported == "done")
        f.transcripts(try #require(f.manager.workspace.sessions[child]?.agentSessionId))
        var answers: [[String: Any]] = []
        f.manager.handleControl(["cmd": "wait", "ids": [child.uuidString]]) { answers.append($0) }
        #expect(answers.count == 1 && (answers[0]["session"] as? [String: Any])?["state"] as? String == "done")
        #expect(answers[0]["screen"] == nil)
        // Once: the next wait blocks.
        f.manager.handleControl(["cmd": "wait", "ids": [child.uuidString]]) { answers.append($0) }
        #expect(answers.count == 1 && f.manager.workspace.sessions[child]?.unreported == nil)
    }

    @Test func unreportedEndsAreDroppedWhenReportedContinuedOrClosed() throws {
        let (f, boss, child) = try setup()
        defer { f.cleanup() }
        let record = { f.manager.workspace.sessions[child]?.unreported }
        send(f, child, "Stop")
        #expect(record() == "done")
        // The next turn starts: old news.
        send(f, child, "UserPromptSubmit")
        #expect(record() == nil)
        send(f, child, "StopFailure", message: "API error")
        #expect(record() == "error")
        var answers: [[String: Any]] = []
        f.manager.handleControl(["cmd": "wait", "caller": boss.uuidString]) { answers.append($0) }
        #expect(answers.count == 1 && record() == nil)
        // Delivered straight to a waiter: never stored.
        f.manager.handleControl(["cmd": "wait", "caller": boss.uuidString]) { answers.append($0) }
        send(f, child, "UserPromptSubmit")
        send(f, child, "Stop")
        #expect(answers.count == 2 && record() == nil)
        send(f, child, "UserPromptSubmit")
        send(f, child, "Stop")
        f.transcripts(try #require(f.manager.workspace.sessions[child]?.agentSessionId))
        f.manager.close(child)
        #expect(f.manager.workspace.sessions[child]?.unreported == nil)
        // With the command off nothing is recorded.
        f.manager.setControl(false)
        send(f, boss, "Stop")
        #expect(f.manager.workspace.sessions[boss]?.unreported == nil)
    }

    @Test func folderTrustQuestionIsSeenAndAnswered() async throws {
        let (f, boss, _) = try setup()
        defer { f.cleanup() }
        SessionManager.trustChecks = [0.01]
        SessionManager.submitDelay = 0.01
        let question = "Is this a project you created or one you trust?\n ❯ No, exit\n   Yes, I trust this folder\n Enter to confirm · Esc to cancel"
        func spawn(_ more: [String: Any] = [:]) throws -> (UUID, FakeTerminal) {
            let answer = ask(f, ["cmd": "spawn", "agent": "claude", "cwd": f.dir.path, "caller": boss.uuidString].merging(more) { $1 })
            let id = try #require(UUID(uuidString: (answer["session"] as? [String: Any])?["id"] as? String ?? ""))
            let terminal = try #require(f.terminal(id))
            terminal.text = question
            f.manager.launchReady(id)
            return (id, terminal)
        }
        // Seen: the session needs input, a waiter hears of it, approve says yes (down to "Yes", Return).
        let (id, terminal) = try spawn()
        var answers: [[String: Any]] = []
        f.manager.handleControl(["cmd": "wait", "ids": [id.uuidString]]) { answers.append($0) }
        await waitUntil { !answers.isEmpty }
        let session = try #require(answers.first?["session"] as? [String: Any])
        #expect(session["state"] as? String == "needs_input" && session["detail"] as? String == SessionManager.trustDetail)
        #expect(ask(f, ["cmd": "approve", "id": id.uuidString, "caller": boss.uuidString])["ok"] as? Bool == true)
        #expect(terminal.bindings == ["text:\\x1b\\x5bB"])
        await waitUntil { terminal.bindings.count == 2 }
        #expect(terminal.bindings.last == "text:\\r" && f.manager.controlState(id) == "working")
        // --trust answers by itself; with the pointer already on Yes it only confirms.
        let (auto, autoTerminal) = try spawn(["trust": true])
        autoTerminal.text = question.replacingOccurrences(of: "❯ No", with: "  No").replacingOccurrences(of: "  Yes", with: "❯ Yes")
        await waitUntil { autoTerminal.bindings.count == 1 }
        #expect(autoTerminal.bindings == ["text:\\r"] && f.manager.controlState(auto) == "working")
        // deny says no (Esc); nothing is typed once the question is gone or a hook has come.
        let (no, noTerminal) = try spawn()
        await waitUntil { f.manager.controlState(no) == "needs_input" }
        #expect(ask(f, ["cmd": "deny", "id": no.uuidString])["ok"] as? Bool == true && noTerminal.bindings == ["text:\\x1b"])
        noTerminal.text = "Welcome"
        #expect(!f.manager.answerTrust(no, yes: true) && !f.manager.answerTrust(UUID(), yes: true))
        let (hooked, hookedTerminal) = try spawn()
        send(f, hooked, "SessionStart")
        f.manager.checkTrustPrompt(hooked)
        #expect(f.manager.controlState(hooked) == "idle" && hookedTerminal.bindings.isEmpty)
        f.manager.close(auto)
        #expect(f.manager.control.trusted.isEmpty)
    }

    @Test func eventsAnnounceEveryStateChange() throws {
        let (f, boss, child) = try setup()
        defer { f.cleanup() }
        var all: [[String: Any]] = [], mine: [[String: Any]] = [], named: [[String: Any]] = []
        func states(_ events: [[String: Any]]) -> [String] { events.compactMap { $0["event"] as? String } }
        let stopAll = f.manager.handleControl(["cmd": "events"], push: { all.append($0) }) { all.append($0) }
        _ = f.manager.handleControl(["cmd": "events", "mine": true, "caller": boss.uuidString], push: { mine.append($0) }) { mine.append($0) }
        _ = f.manager.handleControl(["cmd": "events", "ids": [boss.uuidString]], push: { named.append($0) }) { named.append($0) }
        #expect(all.first?["ok"] as? Bool == true && states(all).isEmpty)
        send(f, child, "UserPromptSubmit")
        send(f, child, "PostToolUse")  // still working: nothing new
        send(f, child, "PermissionRequest", message: "Bash: ls", tool: "Bash")
        _ = ask(f, ["cmd": "approve", "id": child.uuidString])
        send(f, child, "Stop")
        send(f, boss, "UserPromptSubmit")
        #expect(states(mine) == ["working", "needs_permission", "working", "done"])
        #expect(states(all) == states(mine) + ["working"] && states(named) == ["working"])
        let asked = try #require(all.first { $0["event"] as? String == "needs_permission" })
        #expect((asked["session"] as? [String: Any])?["detail"] as? String == "Bash: ls" && asked["ok"] == nil)
        // A new session and a closed one are events too; events don't use up what `wait` reports.
        let answer = ask(f, ["cmd": "spawn", "agent": "claude", "cwd": f.dir.path, "caller": boss.uuidString])
        let fresh = try #require(UUID(uuidString: (answer["session"] as? [String: Any])?["id"] as? String ?? ""))
        f.manager.launchReady(fresh)
        f.manager.close(fresh)
        #expect(states(mine).suffix(3) == ["starting", "idle", "closed"])
        var waited: [[String: Any]] = []
        f.manager.handleControl(["cmd": "wait", "caller": boss.uuidString]) { waited.append($0) }
        #expect((waited.first?["session"] as? [String: Any])?["state"] as? String == "done")
        // A listener that leaves is dropped; turning the command off ends the rest.
        stopAll?()
        #expect(f.manager.control.subscribers.count == 2)
        let before = all.count
        send(f, child, "UserPromptSubmit")
        #expect(all.count == before)
        f.manager.setControl(false)
        #expect(f.manager.control.subscribers.isEmpty && mine.last?["error"] as? String == SessionManager.controlOff)
        f.manager.setControl(true)
        // Without a connection that stays open, and for unknown sessions: refused.
        #expect(ask(f, ["cmd": "events"])["ok"] as? Bool == false)
        var refused: [[String: Any]] = []
        _ = f.manager.handleControl(["cmd": "events", "ids": ["zz"]], push: { refused.append($0) }) { refused.append($0) }
        _ = f.manager.handleControl(["cmd": "events", "mine": true], push: { refused.append($0) }) { refused.append($0) }
        #expect(refused.count == 2 && refused.allSatisfy { $0["ok"] as? Bool == false })
    }

    @Test func finishedStartedSessionsAreClosedAfterAWhile() async throws {
        let (f, boss, child) = try setup()
        defer { f.cleanup() }
        SessionManager.tidyUnit = 0.001
        let m = f.manager!
        f.transcripts(try #require(m.workspace.sessions[child]?.agentSessionId))
        // Into a folder the command makes; the orchestrator itself wasn't started through corral.
        _ = ask(f, ["cmd": "folder", "action": "move", "path": "Auto/Run", "ids": [child.uuidString]])
        let keep = m.newFolder(name: "Mine")
        m.select(boss)
        send(f, child, "Stop")
        send(f, boss, "Stop")
        // Off: nothing happens.
        try await Task.sleep(for: .milliseconds(80))
        #expect(m.live[child] != nil && m.control.tidy.isEmpty)
        m.setTidyMinutes(5)
        await waitUntil { m.live[child] == nil }
        #expect(m.workspace.sessions[child]?.closedAt != nil && m.live[boss] != nil)
        // The folders corral made are gone with their last session; the user's stays.
        #expect(m.resolveFolder("Auto", create: false) == nil && m.workspace.folders[keep] != nil)
        // Work that goes on cancels it; one the user is looking at stays; errors stay.
        func spawned() throws -> UUID {
            let a = ask(f, ["cmd": "spawn", "agent": "claude", "cwd": f.dir.path, "caller": boss.uuidString])
            let id = try #require(UUID(uuidString: (a["session"] as? [String: Any])?["id"] as? String ?? ""))
            m.launchReady(id)
            return id
        }
        SessionManager.tidyUnit = 0.02
        let busy = try spawned(), watched = try spawned(), failed = try spawned()
        send(f, busy, "Stop")
        #expect(m.control.tidy[busy] != nil)
        send(f, busy, "UserPromptSubmit")
        #expect(m.control.tidy[busy] == nil)
        m.select(watched)
        send(f, watched, "Stop")
        send(f, failed, "StopFailure", message: "API error")
        try await Task.sleep(for: .milliseconds(400))
        #expect(m.live[busy] != nil && m.live[watched] != nil && m.live[failed] != nil && m.control.tidy[watched] != nil)
        m.setTidyMinutes(0)
        #expect(m.control.tidy.isEmpty)
    }

    @Test func quietStartedSessionsNotifyOnlyOnFailureOrALongWait() async throws {
        let (f, boss, child) = try setup { $0.notifications = true }
        defer { f.cleanup() }
        SessionManager.quietWait = 0.05
        let m = f.manager!
        m.select(boss)
        m.setQuietSpawned(true)
        let notes = { f.effects.notes.count }
        // A finished turn: nothing. A prompt answered in time: nothing.
        send(f, child, "UserPromptSubmit")
        send(f, child, "Stop")
        send(f, child, "UserPromptSubmit")
        send(f, child, "PermissionRequest", message: "Bash: ls", tool: "Bash")
        #expect(notes() == 0 && m.control.quiet[child] != nil)
        _ = ask(f, ["cmd": "approve", "id": child.uuidString])
        try await Task.sleep(for: .milliseconds(120))
        #expect(notes() == 0 && m.control.quiet[child] == nil)
        // One that keeps waiting reaches the user after all.
        send(f, child, "PermissionRequest", message: "Bash: make", tool: "Bash")
        await waitUntil { notes() == 1 }
        #expect(f.effects.notes.last?.body.contains("Bash: make") == true || f.effects.notes.count == 1)
        _ = ask(f, ["cmd": "deny", "id": child.uuidString])
        // A failure is news at once; sessions the user started are as loud as ever.
        send(f, child, "UserPromptSubmit")
        send(f, child, "StopFailure", message: "API error")
        #expect(notes() == 2)
        let own = m.newSession(agent: .claude, cwd: f.dir.path, select: false)
        m.launchReady(own)
        send(f, own, "UserPromptSubmit")
        send(f, own, "Stop")
        #expect(notes() == 3)
    }

    @Test func aFailedReportDoesNotOutliveItsTurnWithoutHooks() throws {
        let (f, _, child) = try setup()
        defer { f.cleanup() }
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "UserPromptSubmit")), to: child)
        _ = ask(f, ["cmd": "report", "caller": child.uuidString, "text": "no", "failed": true])
        // A permission prompt on the way keeps it; the next turn (seen only as a status change) drops it.
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "PermissionRequest", message: "Bash: ls", tool: "Bash")), to: child)
        _ = ask(f, ["cmd": "approve", "id": child.uuidString])
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "Stop")), to: child)
        #expect(f.manager.control.reports[child]?.failed == true)
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "PostToolUse")), to: child)
        #expect(f.manager.control.reports[child] == nil)
    }

    @Test func debugAnswersOnlyWithDiagnosticsOn() throws {
        let (f, _, child) = try setup()
        defer { f.cleanup() }
        #expect(!f.manager.workspace.settings.diagnostics)
        #expect(ask(f, ["cmd": "debug", "id": child.uuidString])["error"] as? String == SessionManager.diagnosticsOff)
        f.manager.setDiagnostics(true)
        #expect(f.manager.diagnostics)
        let answer = ask(f, ["cmd": "debug", "id": child.uuidString])
        #expect(answer["ok"] as? Bool == true)
        #expect(answer["render"] is [String: Any])
    }

    @Test func statsMeasureSessionsOnlyWhenTurnedOn() async throws {
        let (f, boss, child) = try setup()
        defer { f.cleanup() }
        #expect(ask(f, ["cmd": "stats"])["error"] as? String == SessionManager.measureOff)
        f.manager.setMeasure(true)
        f.manager.setMeasure(true)
        // The child's transcript is found by its conversation id; the orchestrator has none.
        let sid = try #require(f.manager.workspace.sessions[child]?.agentSessionId)
        let project = f.env.roots.claudeProjects.appendingPathComponent("-p")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let line: [String: Any] = ["type": "assistant", "message": [
            "id": "m1", "model": "claude-haiku-x", "content": [["type": "text", "text": "ok"]],
            "usage": ["input_tokens": 5, "output_tokens": 7, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0]]]
        try JSONSerialization.data(withJSONObject: line).write(to: project.appendingPathComponent("\(sid).jsonl"))
        var answer: [String: Any] = [:]
        f.manager.handleControl(["cmd": "stats"]) { answer = $0 }
        await waitUntil { !answer.isEmpty }
        let rows = try #require(answer["stats"] as? [[String: Any]])
        #expect(rows.count == 2 && rows[0]["stats"] == nil && (rows[1]["stats"] as? [String: Any])?["tokens"] as? Int == 12)
        // From a session: its children; one named; the path its hooks gave wins.
        answer = [:]
        f.manager.handleControl(["cmd": "stats", "caller": boss.uuidString]) { answer = $0 }
        await waitUntil { !answer.isEmpty }
        #expect((answer["stats"] as? [[String: Any]])?.count == 1)
        f.manager.control.transcripts[child] = "/no/such.jsonl"
        answer = [:]
        f.manager.handleControl(["cmd": "stats", "id": child.uuidString]) { answer = $0 }
        await waitUntil { !answer.isEmpty }
        #expect((answer["stats"] as? [[String: Any]])?.first?["stats"] == nil)
        #expect(ask(f, ["cmd": "stats", "caller": child.uuidString])["error"] as? String == "No sessions to measure.")
    }
}

@MainActor
@Suite struct ControlSettingsTests {
    @Test func commandLineSectionHoldsThePromptAdditionAndMeasuring() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let w = SettingsWindowController(manager: f.manager)
        #expect(w.spawnNoteSwitch.state == .off && w.measureSwitch.state == .off)
        #expect(w.spawnNoteField.stringValue == AppSettings.defaultSpawnNote && !w.spawnNoteField.isEnabled)
        w.spawnNoteSwitch.state = .on
        w.spawnNoteChanged(w.spawnNoteSwitch)
        #expect(f.manager.workspace.settings.spawnNoteOn && w.spawnNoteField.isEnabled)
        w.spawnNoteField.stringValue = " Keep it short. "
        w.spawnNoteChanged(w.spawnNoteField)
        #expect(f.manager.workspace.settings.spawnNote == "Keep it short.")
        // Emptied: back to the suggestion.
        w.spawnNoteField.stringValue = ""
        w.spawnNoteChanged(w.spawnNoteField)
        #expect(f.manager.workspace.settings.spawnNote == AppSettings.defaultSpawnNote && w.spawnNoteField.stringValue == AppSettings.defaultSpawnNote)
        w.measureSwitch.state = .on
        w.measureChanged(w.measureSwitch)
        #expect(f.manager.workspace.settings.measure)
        f.manager.setMeasure(false)
        #expect(w.measureSwitch.state == .off)
        #expect(w.tidyPopup.itemTitles == ["Never", "After 5 minutes", "After 30 minutes", "After 2 hours"] && w.tidyPopup.indexOfSelectedItem == 0)
        w.tidyPopup.selectItem(at: 2)
        w.tidyChanged(w.tidyPopup)
        #expect(f.manager.workspace.settings.tidyMinutes == 30)
        f.manager.setTidyMinutes(0)
        #expect(w.tidyPopup.indexOfSelectedItem == 0)
        w.quietSwitch.state = .on
        w.quietChanged(w.quietSwitch)
        #expect(f.manager.workspace.settings.quietSpawned)
        f.manager.setQuietSpawned(false)
        f.manager.setQuietSpawned(false)
        #expect(w.quietSwitch.state == .off)
        #expect(w.controlAllSwitch.state == .off)
        w.controlAllSwitch.state = .on
        w.controlAllChanged(w.controlAllSwitch)
        #expect(f.manager.workspace.settings.controlAll)
        f.manager.setControlAll(false)
        #expect(w.controlAllSwitch.state == .off)
    }

    @Test func agentsPageSetsModelsPerAgent() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let w = SettingsWindowController(manager: f.manager)
        #expect(w.modelFields[.shell] == nil && w.standardModelPopups[.shell] == nil)
        let fields = try #require(w.modelFields[.claude])
        #expect(fields.map(\.stringValue) == ["haiku", "sonnet", "opus"] && fields.map(\.placeholderString) == ["Easy", "Medium", "High"])
        #expect(w.modelFields[.pi]?.map(\.stringValue) == ["", "", ""])
        fields[2].stringValue = "  claude-big-1 "
        w.modelChanged(fields[2])
        #expect(f.manager.workspace.settings.model(for: .claude, named: "high") == "claude-big-1")
        #expect(f.manager.workspace.settings.model(for: .claude, named: "easy") == "haiku")
        let popup = try #require(w.standardModelPopups[.claude])
        #expect(popup.itemTitles == ["Agent's default", "Easy", "Medium", "High"] && popup.indexOfSelectedItem == 0)
        popup.selectItem(at: 3)
        w.standardModelChanged(popup)
        #expect(f.manager.workspace.settings.model(for: .claude, named: nil) == "claude-big-1")
        popup.selectItem(at: 0)
        w.standardModelChanged(popup)
        #expect(f.manager.workspace.settings.models(for: .claude).standard == nil)
        // Saved, and shown again by another window.
        f.manager.saveNow(wait: true)
        f.makeManager()
        let again = SettingsWindowController(manager: f.manager)
        #expect(again.modelFields[.claude]?.map(\.stringValue) == ["haiku", "sonnet", "claude-big-1"])
    }

    @Test func commandLineSectionTurnsControlOnAndInstallsTheSkill() throws {
        let f = Fixture { $0.skillHome = $0.store.url.deletingLastPathComponent().appendingPathComponent("home") }
        defer { f.cleanup() }
        let home = try #require(f.env.skillHome)
        let w = SettingsWindowController(manager: f.manager)
        let exe = f.dir.appendingPathComponent("Corral.app/Contents/MacOS/Corral")
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("bin".utf8).write(to: exe)
        w.skillExecutable = { exe.resolvingSymlinksInPath() }
        #expect(w.controlSwitch.state == .off)
        w.controlSwitch.state = .on
        w.controlChanged(w.controlSwitch)
        #expect(f.manager.workspace.settings.control)
        w.controlSwitch.state = .off
        w.controlChanged(w.controlSwitch)
        #expect(!f.manager.workspace.settings.control)

        let claude = try #require(w.skillButtons[.claudeCode]), opencode = try #require(w.skillButtons[.openCode])
        #expect(claude.image == nil && claude.isEnabled && claude.title == "Claude Code" && opencode.title == "OpenCode")
        w.installSkill(claude)
        // Claude's skills sit next to its settings.json.
        let file = f.env.integrationPaths.claudeSettings.deletingLastPathComponent().appendingPathComponent("skills/corral/SKILL.md")
        #expect(try String(contentsOf: file, encoding: .utf8) == AgentSkill.markdown)
        #expect(claude.image != nil && opencode.image == nil)
        #expect(f.manager.workspace.settings.control && w.controlSwitch.state == .on)
        #expect(FileManager.default.fileExists(atPath: CommandLineLink.url(home: home).path))
        // A skills folder that can't be written is reported.
        try Data("x".utf8).write(to: home.appendingPathComponent(".config"))
        w.installSkill(opencode)
        #expect(f.effects.alerts.last == "Couldn't install the OpenCode skill" && opencode.image == nil)
        // Without a home (tests, benches) nothing is offered.
        let g = Fixture()
        defer { g.cleanup() }
        let w2 = SettingsWindowController(manager: g.manager)
        #expect(w2.skillButtons[.claudeCode]?.isEnabled == false)
        w2.installSkill(try #require(w2.skillButtons[.claudeCode]))
        #expect(!g.manager.workspace.settings.control)
    }
}
