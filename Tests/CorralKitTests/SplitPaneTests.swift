import AppKit
@testable import CorralCore
import Testing
@testable import CorralKit

/// ⌘D split panes: throwaway shells next to a session's terminal; an agent started in one becomes
/// a session of its own, beside the first.
@MainActor
struct SplitPaneTests {
    func setup() -> (Fixture, MainWindowController, UUID) {
        let f = Fixture()
        let w = MainWindowController(manager: f.manager)
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        let id = f.selected!
        f.manager.launchReady(id)
        return (f, w, id)
    }

    @Test func splitRightAndDownBuildNestedPanes() throws {
        let (f, w, id) = setup()
        defer { f.cleanup() }
        let m = f.manager!
        w.splitRight(nil)
        let a = try #require(m.panes.values.first)
        #expect(a.owner == id)
        let pa = try #require(a.terminal as? FakeTerminal)
        #expect(pa.launch.cwd == f.dir.path)
        #expect(pa.launch.env["CORRAL_HOOK"] != nil && pa.launch.command == nil && pa.launch.initialInput == nil)
        #expect(m.paneLayouts[id] == .split(sideBySide: true, first: .leaf(id), second: .leaf(a.id)))
        #expect(m.focusedTerminal(id) === a.terminal)
        let host = try #require(w.container.splitHosts[id])
        let split = try #require(host.subviews.first as? NSSplitView)
        #expect(split.isVertical)
        #expect(split.subviews.map { $0 } == [m.live[id]!.terminal.view, a.terminal.view])
        #expect(w.container.hostView(id) === host)
        #expect(w.container.terminals(of: id).count == 2)
        #expect(w.window?.firstResponder === a.terminal.view)

        // ⇧⌘D from the pane splits the pane, below it.
        w.splitDown(nil)
        let b = try #require(m.panes.values.first { $0.id != a.id })
        #expect(m.paneLayouts[id]?.leaves == [id, a.id, b.id])
        let rebuilt = try #require(w.container.splitHosts[id]?.subviews.first as? NSSplitView)
        let inner = try #require(rebuilt.subviews.last as? NSSplitView)
        #expect(!inner.isVertical)
        #expect(inner.subviews.map { $0 } == [a.terminal.view, b.terminal.view])

        // ⌘] / ⌘[ walk the panes in reading order.
        w.nextPane(nil)
        #expect(m.focusedTerminal(id) === m.live[id]!.terminal)
        w.previousPane(nil)
        #expect(m.focusedTerminal(id) === b.terminal)
        _ = m.perform(.gotoSplit(.next), terminal: b.terminal)
        #expect(m.focusedTerminal(id) === m.live[id]!.terminal)
        _ = m.perform(.gotoSplit(.next), terminal: m.live[id]!.terminal)
        #expect(m.focusedTerminal(id) === a.terminal)
    }

    @Test func panesCloseByCommandExitAndWithTheirSession() async throws {
        let (f, w, id) = setup()
        defer { f.cleanup() }
        let m = f.manager!
        w.splitRight(nil)
        let a = try #require(m.panes.values.first)
        // ⌘W with the pane focused closes the pane, not the session.
        w.window?.makeFirstResponder(a.terminal.view)
        w.closeSession(nil)
        #expect(m.panes.isEmpty && m.paneLayouts[id] == nil)
        #expect((a.terminal as? FakeTerminal)?.destroyed == true)
        #expect(m.live[id] != nil)
        #expect(w.container.splitHosts[id] == nil)
        #expect(m.live[id]!.terminal.view.superview === w.container.stack)

        // A pane whose shell exits: Ghostty closes the surface after its callback (never freed inside
        // it), and the close request closes the pane.
        _ = m.perform(.newSplit(.right), terminal: m.live[id]!.terminal)
        let b = try #require(m.panes.values.first)
        #expect(!m.perform(.childExited, terminal: b.terminal))
        #expect(m.panes[b.id] != nil && (b.terminal as? FakeTerminal)?.destroyed == false)
        m.closeRequested(b.terminal, processAlive: false)
        #expect(m.panes.isEmpty)
        _ = m.perform(.newSplit(.down), terminal: m.live[id]!.terminal)
        let c = try #require(m.panes.values.first)
        (c.terminal as? FakeTerminal)?.needsConfirmQuit = true
        var asked: [String] = []
        let saved = Presenter.alert
        Presenter.alert = { alert, _, done in asked.append(alert.messageText); done(.alertSecondButtonReturn) }
        defer { Presenter.alert = saved }
        _ = m.perform(.closeSession, terminal: c.terminal)
        #expect(asked.isEmpty)  // not from inside Ghostty's key handling
        await waitUntil { !asked.isEmpty }
        #expect(asked == ["Close this pane?"])
        #expect(m.panes[c.id] != nil)
        // Closing the session asks too when one of its panes runs something.
        m.requestClose(id)
        #expect(asked.last == "Close “\(m.workspace.sessions[id]!.displayTitle)”?")
        #expect(m.live[id] != nil)
        m.closeRequested(c.terminal, processAlive: false)
        #expect(m.panes.isEmpty)

        // Closing the session takes its panes and its split host along; a reopen shows the terminal.
        _ = m.perform(.newSplit(.right), terminal: m.live[id]!.terminal)
        let d = try #require(m.panes.values.first)
        #expect(w.container.splitHosts[id] != nil)
        m.close(id)
        #expect(m.panes.isEmpty && (d.terminal as? FakeTerminal)?.destroyed == true)
        #expect(w.container.splitHosts[id] == nil)
        #expect(!w.container.stack.subviews.contains { $0.subviews.first is NSSplitView })
        m.reopen(id)
        let reopened = try #require(m.live[id]?.terminal.view)
        #expect(reopened.superview === w.container.stack && !reopened.isHidden)
    }

    /// Find and Clear Screen act on the focused pane; ⌘D only splits the terminal on screen.
    @Test func findClearAndSplitFollowTheFocusedPane() throws {
        let (f, w, id) = setup()
        defer { f.cleanup() }
        let m = f.manager!
        w.splitRight(nil)
        let a = try #require(m.panes.values.first)
        let pane = try #require(a.terminal as? FakeTerminal)
        w.findInTerminal(nil)
        w.clearTerminal(nil)
        #expect(pane.bindings.suffix(2) == ["start_search", "clear_screen"])
        // A search in the pane survives a refresh of the same session.
        w.container.findAction(.startSearch(nil), terminal: a.terminal)
        w.container.showSelected(focus: false)
        #expect(w.container.findTargetSession == a.id)
        // Behind a Closed preview nothing splits.
        m.newSession(agent: .claude, cwd: f.dir.path)
        let other = f.selected!
        m.close(other)
        m.select(id)
        w.sidebarShowClosed(other)
        let before = m.panes.count
        w.splitDown(nil)
        #expect(m.panes.count == before)
    }

    @Test func panesStayQuietAndForwardGeneralActions() throws {
        let (f, w, id) = setup()
        defer { f.cleanup() }
        let m = f.manager!
        w.splitRight(nil)
        let a = try #require(m.panes.values.first)
        let before = m.status(id)
        #expect(m.perform(.desktopNotification(title: "x", body: "y"), terminal: a.terminal))
        #expect(m.perform(.bell, terminal: a.terminal))
        #expect(m.perform(.pwd("/tmp"), terminal: a.terminal))
        #expect(m.status(id) == before)
        // A further split from the pane starts in the pane's directory.
        _ = m.perform(.newSplit(.down), terminal: a.terminal)
        let b = try #require(m.panes.values.first { $0.id != a.id })
        #expect((b.terminal as? FakeTerminal)?.launch.cwd == "/tmp")
        // Everything else works as from any terminal.
        let count = m.live.count
        #expect(m.perform(.newSession, terminal: a.terminal))
        #expect(m.live.count == count + 1)
    }

    @Test func anAgentStartedInAPaneBecomesASessionBesideTheFirst() throws {
        let (f, w, id) = setup()
        defer { f.cleanup() }
        let m = f.manager!
        m.newSession(agent: .shell, cwd: f.dir.path)
        let after = f.selected!
        m.select(id)
        w.splitRight(nil)
        let a = try #require(m.panes.values.first)
        m.handleHook(HookWire.Message(surface: a.id, event: HookEvent(agent: .claude, event: "SessionStart", sessionId: "s-9", cwd: f.dir.path)))
        // A session now, still on the card where it was started.
        #expect(m.panes.isEmpty)
        #expect(m.paneLayouts[id] == .split(sideBySide: true, first: .leaf(id), second: .leaf(a.id)))
        #expect(m.sideBySide(id) == [id, a.id] && m.sideBySide(a.id) == [id, a.id] && m.layoutOwner(of: a.id) == id)
        #expect(m.live[a.id]?.terminal === a.terminal)
        #expect(m.workspace.sessions[a.id]?.agent == .claude)
        #expect(m.status(a.id)?.agentSessionId == "s-9")
        #expect(m.workspace.openSessionsInOrder == [id, a.id, after])
        #expect(f.selected == a.id)
        let host = try #require(w.container.splitHosts[id])
        #expect(a.terminal.view.isDescendant(of: host) && w.container.hostId(a.id) == id && w.container.shownHost == id)
        #expect(m.workspace.splits[id] == m.paneLayouts[id])
        // Status from now on is the new session's, like any session's.
        m.handleHook(HookWire.Message(surface: a.id, event: HookEvent(agent: .claude, event: "PermissionRequest", message: "Allow Bash?")))
        #expect(m.status(a.id)?.activity == .needsInput)
        #expect(m.status(id)?.activity != .needsInput)
    }

    @Test func splitMenuItemsAreListedInTheShortcutsSheet() {
        _ = NSApplication.shared
        let rows = ShortcutList.sections(from: AppDelegate(makeTerminals: { FakeFactory() }).buildMenu()).flatMap(\.rows)
        for (name, keys) in [("Split Right", "⌘D"), ("Split Down", "⇧⌘D"), ("Next Pane", "⌘]"), ("Previous Pane", "⌘[")] {
            #expect(rows.contains(.init(name: name, keys: keys)), "\(name)")
        }
    }
}
