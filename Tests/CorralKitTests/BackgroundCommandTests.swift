import AppKit
@testable import CorralCore
import Testing
@testable import CorralKit

/// A Claude turn that ends while a command it started runs in the background isn't finished yet.
@MainActor
struct BackgroundCommandTests {
    final class Fake {
        var shells: [pid_t] = []
        var exits: [pid_t: () -> Void] = [:]
        var released = 0
        final class Token { let done: () -> Void; init(_ done: @escaping () -> Void) { self.done = done }; deinit { done() } }
    }

    func fixture(_ fake: Fake) -> Fixture {
        Fixture {
            $0.backgroundShells = { _ in fake.shells }
            $0.watchExit = { pid, exited in
                fake.exits[pid] = exited
                return Fake.Token { fake.released += 1 }
            }
            $0.backgroundGrace = 0
        }
    }

    func hook(_ f: Fixture, _ id: UUID, _ event: String, type: String? = nil) {
        var e = HookEvent(agent: .claude, event: event)
        e.notificationType = type
        f.manager.handleHook(HookWire.Message(surface: id, event: e))
    }

    @Test func stopWithABackgroundCommandStaysWorkingUntilItEnds() async throws {
        let fake = Fake()
        let f = fixture(fake)
        defer { f.cleanup() }
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        let id = try #require(f.selected)
        f.manager.newSession(agent: .shell, cwd: f.dir.path)  // elsewhere, so a finish would be unread
        hook(f, id, "UserPromptSubmit")
        fake.shells = [4242]
        hook(f, id, "Stop")
        #expect(f.manager.live[id]?.status.activity == .working)
        #expect(f.manager.live[id]?.status.detail == "Background command")
        // Claude's idle notice a minute later doesn't finish it either.
        hook(f, id, "Notification", type: "idle_prompt")
        #expect(f.manager.live[id]?.status.activity == .working && f.manager.backgroundHolds[id] != nil)

        // The command ends and Claude stays quiet: finished after the grace period.
        fake.shells = []
        fake.exits[4242]?()
        #expect(f.manager.live[id]?.status.activity == .working)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(f.manager.live[id]?.status.activity == .done && f.manager.live[id]?.status.unread == true)
        #expect(f.manager.backgroundHolds[id] == nil && fake.released >= 1)
    }

    @Test func claudeGoingOnEndsTheHold() async throws {
        let fake = Fake()
        let f = fixture(fake)
        defer { f.cleanup() }
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        let id = try #require(f.selected)
        fake.shells = [7]
        hook(f, id, "Stop")
        #expect(f.manager.backgroundHolds[id] != nil)
        // The command finished and Claude picked up: normal status from here on.
        fake.shells = []
        hook(f, id, "PreToolUse")
        #expect(f.manager.backgroundHolds[id] == nil && f.manager.live[id]?.status.detail != "Background command")
        hook(f, id, "Stop")
        #expect(f.manager.live[id]?.status.activity == .done)
        // A late exit report from the released watch changes nothing.
        fake.exits[7]?()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(f.manager.live[id]?.status.activity == .done)
    }

    @Test func closingTheSessionStopsWatching() throws {
        let fake = Fake()
        let f = fixture(fake)
        defer { f.cleanup() }
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        let id = try #require(f.selected)
        fake.shells = [1, 2]
        hook(f, id, "Stop")
        #expect(fake.exits.count == 2 && fake.released == 0)
        f.manager.close(id)
        #expect(f.manager.backgroundHolds[id] == nil && fake.released == 2)
    }

    @Test func onlyClaudeTurnEndsAreHeld() {
        #expect(SessionManager.endsTurn(HookEvent(agent: .claude, event: "Stop")))
        var idle = HookEvent(agent: .claude, event: "Notification")
        idle.notificationType = "idle_prompt"
        #expect(SessionManager.endsTurn(idle))
        idle.notificationType = "permission_prompt"
        #expect(!SessionManager.endsTurn(idle))
        #expect(!SessionManager.endsTurn(HookEvent(agent: .opencode, event: "session.idle")))
    }

    /// The real lookup: a child started from Claude's shell snapshot counts, other children don't.
    @Test func backgroundShellsAreSnapshotShellsOnly() throws {
        let snapshot = Process()
        snapshot.executableURL = URL(fileURLWithPath: "/bin/sh")
        snapshot.arguments = ["-c", "sleep 5; true # /tmp/x/shell-snapshots/snapshot-zsh-1.sh"]
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/bin/sleep")
        other.arguments = ["5"]
        try snapshot.run()
        try other.run()
        defer { snapshot.terminate(); other.terminate() }
        let me = getpid()
        #expect(ProcessInspector.children(of: me).contains(snapshot.processIdentifier))
        #expect(ProcessInspector.claudeBackgroundShells(agent: me) == [snapshot.processIdentifier])
        #expect(ProcessInspector.claudeBackgroundShells(agent: 0).isEmpty)
    }

    /// A working job writes its timeline next to its state: only state.json is re-read, no `claude agents`.
    @Test func jobFileChangesRereadOnlyThatJobsState() async throws {
        let f = fixture(Fake())
        defer { f.cleanup() }
        let jobs = f.manager.env.jobsDir
        let dir = jobs.appendingPathComponent("j1")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let other = BackgroundAgent(id: "j2", sessionId: "s2", name: "Other", cwd: "/", state: "working")
        f.manager.applyBackground([BackgroundAgent(id: "j1", sessionId: "s", name: "Job", cwd: "/", state: "working"), other])
        var emits = 0
        f.manager.observe { if case .background = $0 { emits += 1 } }
        let state: [String: Any] = ["state": "working", "tempo": "idle", "name": "Renamed", "inFlight": ["tasks": 1]]
        try JSONSerialization.data(withJSONObject: state).write(to: dir.appendingPathComponent("state.json"))
        let paths = ["timeline.jsonl", "state.json", "tmp/x"].map { dir.appendingPathComponent($0).path }
        f.manager.backgroundChanged(paths)
        #expect(f.manager.background.first?.name == "Renamed" && f.manager.background.first?.inFlight == 1)
        #expect(f.manager.background.last == other && emits == 1)
        // Unchanged state: nothing re-applied.
        f.manager.backgroundChanged(paths)
        #expect(emits == 1)
        // A new job folder needs the full list (no claude binary here: an empty one).
        f.manager.backgroundChanged([jobs.appendingPathComponent("j3").path])
        await waitUntil { f.manager.background.isEmpty }
        #expect(f.manager.background.isEmpty)
    }

    /// The job file can say "a script still runs" before the turn's Stop arrives; a later batch with
    /// only the timeline (state unchanged) still puts the attached session on hold.
    @Test func anAttachedJobIsHeldEvenWhenItsStateWroteFirst() throws {
        let f = fixture(Fake())
        defer { f.cleanup() }
        let dir = f.manager.env.jobsDir.appendingPathComponent("job1")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let job = BackgroundAgent(id: "job1", sessionId: "s-job1", name: "Job", cwd: f.dir.path, state: "working")
        f.manager.applyBackground([job])
        f.manager.attach(job)
        let id = try #require(f.selected)
        hook(f, id, "UserPromptSubmit")
        let state: [String: Any] = ["state": "working", "tempo": "idle", "inFlight": ["tasks": 1]]
        try JSONSerialization.data(withJSONObject: state).write(to: dir.appendingPathComponent("state.json"))
        f.manager.backgroundChanged([dir.appendingPathComponent("state.json").path])
        hook(f, id, "Stop")
        #expect(f.manager.live[id]?.status.activity == .done)
        f.manager.backgroundChanged([dir.appendingPathComponent("timeline.jsonl").path])
        #expect(f.manager.live[id]?.status.activity == .working && f.manager.live[id]?.status.detail == StatusReducer.backgroundDetail)
    }

    @Test func aBackgroundJobsScriptsKeepItWorkingAfterItsTurn() throws {
        let f = fixture(Fake())
        defer { f.cleanup() }
        var job = BackgroundAgent(id: "job1", sessionId: "s-job1", name: "Job", cwd: f.dir.path, state: "working")
        f.manager.attach(job)
        let id = try #require(f.selected)
        hook(f, id, "UserPromptSubmit")
        hook(f, id, "Stop")
        #expect(f.manager.live[id]?.status.activity == .done)
        // The job file says its script still runs (it lives in Claude's daemon, not this terminal).
        job.tempo = "idle"
        job.inFlight = 1
        f.manager.applyBackground([job])
        #expect(f.manager.live[id]?.status.activity == .working && f.manager.live[id]?.status.detail == StatusReducer.backgroundDetail)
        // The script ends without another turn: done.
        job.inFlight = 0
        job.state = "done"
        f.manager.applyBackground([job])
        #expect(f.manager.live[id]?.status.activity == .done)
        // Hooks keep the say over a job between turns otherwise.
        hook(f, id, "UserPromptSubmit")
        f.manager.applyBackground([job])
        #expect(f.manager.live[id]?.status.activity == .working && f.manager.live[id]?.status.detail == nil)
    }

    @Test func anInterruptedTurnGoesIdle() async throws {
        let fake = Fake()
        let f = fixture(fake)
        defer { f.cleanup() }
        SessionManager.interruptChecks = [0]
        defer { SessionManager.interruptChecks = [0.3, 1, 2] }
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        let id = try #require(f.selected)
        hook(f, id, "UserPromptSubmit")
        let esc = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                 context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                 isARepeat: false, keyCode: 53))
        // Esc that didn't stop the turn (no notice on screen): still working.
        f.terminal(id)?.text = "✻ Working…\n> "
        f.manager.handleKey(esc, session: id)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(f.manager.live[id]?.status.activity == .working)
        // Claude's notice: idle, nothing announced.
        f.terminal(id)?.text = "  ⎿  Interrupted · What should Claude do instead?\n\n> "
        f.manager.handleKey(esc, session: id)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(f.manager.live[id]?.status.activity == .idle && f.manager.live[id]?.status.unread == false)
        // An old notice far up the screen doesn't count.
        hook(f, id, "UserPromptSubmit")
        f.terminal(id)?.text = "  ⎿  Interrupted · What should Claude do instead?" + String(repeating: "\nline", count: 20)
        f.manager.checkInterrupt(id)
        #expect(f.manager.live[id]?.status.activity == .working)
    }
}
