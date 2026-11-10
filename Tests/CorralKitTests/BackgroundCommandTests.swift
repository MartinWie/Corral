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
}
