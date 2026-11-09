import AppKit
@testable import CorralCore
import Testing
@testable import CorralKit

/// ⌥⌘ arrows: the terminal on that side on the card, then (↑ / ↓) the previous / next session.
@MainActor
struct FocusNavigationTests {
    /// Window + four Claude sessions a, b, c, d in sidebar order, a selected.
    func setup() -> (Fixture, MainWindowController, [UUID]) {
        let f = Fixture()
        let w = MainWindowController(manager: f.manager)
        var ids: [UUID] = []
        for _ in 0..<4 {
            f.manager.newSession(agent: .claude, cwd: f.dir.path)
            ids.append(f.selected!)
            f.manager.launchReady(ids.last!)
        }
        f.manager.select(ids[0])
        return (f, w, ids)
    }

    @Test func arrowsMoveAcrossTheCardByWhereThingsAre() throws {
        let (f, w, ids) = setup()
        defer { f.cleanup() }
        let m = f.manager!
        let (a, b, c, d) = (ids[0], ids[1], ids[2], ids[3])
        // Card [(a | b) / c].
        m.showBeside(b, of: a)
        m.showBeside(c, of: a, direction: .down)
        m.select(a)
        w.focusRight(nil)
        #expect(f.selected == b)
        w.focusDown(nil)
        #expect(f.selected == c)
        w.focusUp(nil)
        #expect(f.selected == b)  // a and b sit equally above c: back where focus came from
        w.focusLeft(nil)
        #expect(f.selected == a)
        w.focusLeft(nil)
        #expect(f.selected == a)  // the card's left edge: nothing
        // Off the bottom: the next session in the sidebar that isn't on the card.
        m.select(c)
        w.focusDown(nil)
        #expect(f.selected == d && w.container.shownHost == d)
        // And back up onto the card from below: the previous session not on d's card.
        w.focusUp(nil)
        #expect(f.selected == c)
        // Off the top of the card with nothing above a: stays.
        m.select(a)
        w.focusUp(nil)
        #expect(f.selected == a)
        // Ghostty's own goto_split actions take the same way.
        _ = m.perform(.gotoSplit(.toward(.right)), terminal: m.live[a]!.terminal)
        #expect(f.selected == b)
        _ = m.perform(.gotoSplit(.previous), terminal: m.live[b]!.terminal)
        #expect(f.selected == a)
    }

    @Test func aloneUpAndDownWalkTheSidebarWithoutWrapping() throws {
        let (f, w, ids) = setup()
        defer { f.cleanup() }
        let m = f.manager!
        w.focusDown(nil)
        #expect(f.selected == ids[1])
        w.focusRight(nil)
        #expect(f.selected == ids[1])
        m.select(ids[3])
        w.focusDown(nil)
        #expect(f.selected == ids[3])
        w.focusUp(nil)
        #expect(f.selected == ids[2])
        // Sessions inside a collapsed folder are skipped, like the rows on screen.
        let folder = m.newFolder(name: "F")
        m.move(ids[1], to: folder, at: 0)
        m.setExpanded(folder, false)
        m.select(ids[0])
        w.focusDown(nil)
        #expect(f.selected == ids[2])
        // From a session hidden that way, its neighbors in the full order.
        // (A new folder goes last: b is now the last session, in the folder.)
        let full = m.workspace.openSessionsInOrder
        #expect(full.last == ids[1])
        m.select(ids[1])
        w.focusDown(nil)
        #expect(f.selected == ids[1])
        w.focusUp(nil)
        #expect(f.selected == full[full.count - 2])
    }

    @Test func fromTheSidebarTheKeyboardStaysThere() throws {
        let (f, w, ids) = setup()
        defer { f.cleanup() }
        let window = try #require(w.window)
        window.makeFirstResponder(w.sidebar.outline)
        w.focusDown(nil)
        #expect(f.selected == ids[1])
        #expect(window.firstResponder === w.sidebar.outline)
        // From a terminal, the next session's terminal gets it.
        window.makeFirstResponder(f.manager.live[ids[1]]!.terminal.view)
        w.focusDown(nil)
        #expect(f.selected == ids[2] && window.firstResponder === f.manager.live[ids[2]]!.terminal.view)
    }

    @Test func fromTheSidebarOnACardOnlyTheSelectionMoves() throws {
        let (f, w, ids) = setup()
        defer { f.cleanup() }
        let m = f.manager!
        let (a, b) = (ids[0], ids[1])
        m.showBeside(b, of: a)
        m.select(a)
        w.splitDown(nil)  // a shell under a's terminal, focused
        let window = try #require(w.window)
        window.makeFirstResponder(w.sidebar.outline)
        w.focusRight(nil)
        #expect(f.selected == b && window.firstResponder === w.sidebar.outline)
        w.focusLeft(nil)
        #expect(f.selected == a && window.firstResponder === w.sidebar.outline)
        // Down from a: the shell is skipped (no session below a on the card): the next session.
        w.focusDown(nil)
        #expect(f.selected == ids[2] && window.firstResponder === w.sidebar.outline)
    }

    @Test func aRoundTripComesBackAndRealFramesCount() throws {
        let (f, w, ids) = setup()
        defer { f.cleanup() }
        let m = f.manager!
        let (a, b, c) = (ids[0], ids[1], ids[2])
        // [(a / b) | c]
        m.showBeside(b, of: a, direction: .down)
        m.showBeside(c, of: a)
        #expect(m.paneLayouts[a] == .split(sideBySide: true, first: .split(sideBySide: false, first: .leaf(a), second: .leaf(b)), second: .leaf(c)))
        m.select(b)
        w.focusRight(nil)
        #expect(f.selected == c)
        w.focusLeft(nil)
        #expect(f.selected == b)  // where it came from, not the first of the tie
        // The container reports where the terminals are.
        w.window?.contentView?.layoutSubtreeIfNeeded()
        let boxes = try #require(w.container.cardBoxes(a))
        #expect(Set(boxes.keys) == [a, b, c])
        #expect(abs((boxes[c]?.x ?? 0) - 0.5) < 0.01 && abs((boxes[b]?.y ?? 0) - 0.5) < 0.01)
        #expect(w.container.cardBoxes(ids[3]) == nil)
    }

    @Test func panesTakePartLikeAnyTerminal() throws {
        let (f, w, ids) = setup()
        defer { f.cleanup() }
        let m = f.manager!
        let a = ids[0]
        w.splitRight(nil)
        let pane = try #require(m.panes.values.first)
        let window = try #require(w.window)
        #expect(window.firstResponder === pane.terminal.view)
        w.focusLeft(nil)
        #expect(m.focusedTerminal(a) === m.live[a]!.terminal)
        w.focusRight(nil)
        #expect(m.focusedTerminal(a) === pane.terminal)
        // From the pane's own Ghostty action too.
        _ = m.perform(.gotoSplit(.toward(.left)), terminal: pane.terminal)
        #expect(m.focusedTerminal(a) === m.live[a]!.terminal)
        // Down from the pane: no terminal below, the next session.
        window.makeFirstResponder(pane.terminal.view)
        w.focusDown(nil)
        #expect(f.selected == ids[1])
    }

    @Test func theArrowsAreMenuShortcuts() {
        _ = NSApplication.shared
        let menu = AppDelegate(makeTerminals: { FakeFactory() }).buildMenu()
        let rows = ShortcutList.sections(from: menu).flatMap(\.rows)
        for (name, keys) in [("Focus Up", "⌥⌘↑"), ("Focus Down", "⌥⌘↓"), ("Focus Left", "⌥⌘←"), ("Focus Right", "⌥⌘→")] {
            #expect(rows.contains(.init(name: name, keys: keys)), "\(name)")
        }
    }
}
