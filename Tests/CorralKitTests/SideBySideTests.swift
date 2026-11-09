import AppKit
@testable import CorralCore
import Testing
@testable import CorralKit

/// Sessions side by side on one card: showing one beside another, the selection following focus,
/// leaving and closing, drag and drop from the sidebar, and restoring the card after a relaunch.
@MainActor
struct SideBySideTests {
    /// Window + three Claude sessions (a, b, c), a selected.
    func setup(_ configure: ((inout ManagerEnvironment) -> Void)? = nil) -> (Fixture, MainWindowController, UUID, UUID, UUID) {
        let f = Fixture(configure: configure)
        let w = MainWindowController(manager: f.manager)
        var ids: [UUID] = []
        for _ in 0..<3 {
            f.manager.newSession(agent: .claude, cwd: f.dir.path)
            ids.append(f.selected!)
            f.manager.launchReady(ids.last!)
        }
        f.manager.select(ids[0])
        return (f, w, ids[0], ids[1], ids[2])
    }

    @Test func showBesideSharesTheCardAndFocusMovesTheSelection() throws {
        let (f, w, a, b, c) = setup()
        defer { f.cleanup() }
        let m = f.manager!
        m.showBeside(b, of: a)
        #expect(m.paneLayouts[a] == .split(sideBySide: true, first: .leaf(a), second: .leaf(b)))
        #expect(f.selected == b && m.sideBySide(a) == [a, b])
        let host = try #require(w.container.splitHosts[a])
        let split = try #require(host.subviews.first as? NSSplitView)
        #expect(split.subviews.map { $0 } == [m.live[a]!.terminal.view, m.live[b]!.terminal.view])
        #expect(!host.isHidden && w.container.shownHost == a && w.container.shownSession == b)
        #expect(w.window?.firstResponder === m.live[b]!.terminal.view)

        // Both are on screen (key window, active app): neither is unread or notified when it finishes.
        let windowUI = m.ui
        m.ui = f.ui
        #expect(m.isFocused(a) && m.isFocused(b) && !m.isFocused(c))
        m.apply(.hook(HookEvent(agent: .claude, event: "UserPromptSubmit")), to: a)
        m.apply(.hook(HookEvent(agent: .claude, event: "Stop")), to: a)
        #expect(m.status(a)?.unread == false)
        m.ui = windowUI

        // Clicking into the other session selects it, without moving focus again.
        m.live[a]!.terminal.onFocus?()
        #expect(f.selected == a && w.container.shownHost == a)
        #expect(m.focusedTerminal(a) === m.live[a]!.terminal)

        // ⌘] walks the card: the next session gets selected.
        m.focusPane(in: a, offset: 1)
        #expect(f.selected == b)
        m.focusPane(in: b, offset: 1)
        #expect(f.selected == a)

        // Another session hides the card; coming back shows it again with both.
        m.select(c)
        #expect(host.isHidden && w.container.shownHost == c)
        #expect(m.live[c]!.terminal.view.superview === w.container.stack && !m.live[c]!.terminal.view.isHidden)
        m.select(b)
        #expect(!host.isHidden && !m.live[b]!.terminal.view.isHidden)

        // Already on the card / itself / not open: nothing.
        m.showBeside(a, of: b)
        m.showBeside(a, of: a)
        m.showBeside(UUID(), of: a)
        #expect(m.paneLayouts[a]?.leaves == [a, b])
    }

    @Test func showSeparatelyAndClosingLeaveTheCardToTheOthers() throws {
        let (f, w, a, b, c) = setup()
        defer { f.cleanup() }
        let m = f.manager!
        m.showBeside(b, of: a)
        m.showBeside(c, of: b, direction: .down)
        #expect(m.paneLayouts[a] == .split(sideBySide: false, first: .split(sideBySide: true, first: .leaf(a), second: .leaf(b)), second: .leaf(c)))
        // A shell split on the card belongs to the card.
        m.select(b)
        w.splitRight(nil)
        let pane = try #require(m.panes.values.first)
        #expect(pane.owner == a && m.sideBySide(b) == [a, b, c])
        #expect(m.focusedTerminal(b) === pane.terminal)

        m.showSeparately(c)
        #expect(m.paneLayouts[a]?.leaves == [a, b, pane.id] && m.sideBySide(c) == [c])
        #expect(m.live[c]!.terminal.view.superview === w.container.stack)
        m.showSeparately(c)

        // The holder closes: the next session holds the card, shell included.
        m.close(a)
        #expect(m.paneLayouts[a] == nil && m.paneLayouts[b]?.leaves == [b, pane.id])
        #expect(m.panes[pane.id]?.owner == b && w.container.splitHosts[b] != nil && w.container.splitHosts[a] == nil)
        // c was taken off the card before: b and its shell are no side-by-side state.
        #expect(m.workspace.splits.isEmpty)
        // A session alone with its shell: closing it closes the shell like before.
        m.close(b)
        #expect(m.panes.isEmpty && (pane.terminal as? FakeTerminal)?.destroyed == true && m.paneLayouts.isEmpty)
        #expect(m.workspace.splits.isEmpty)
    }

    @Test func aSessionWithItsShellsBringsThemAlong() throws {
        let (f, w, a, b, c) = setup()
        defer { f.cleanup() }
        let m = f.manager!
        m.select(b)
        w.splitDown(nil)
        let shell = try #require(m.panes.values.first)
        m.showBeside(b, of: a, direction: .left)
        #expect(m.paneLayouts[a] == .split(sideBySide: true, first: .split(sideBySide: false, first: .leaf(b), second: .leaf(shell.id)), second: .leaf(a)))
        #expect(m.paneLayouts[b] == nil && m.panes[shell.id]?.owner == a && w.container.splitHosts[b] == nil)
        // Saved without the shell.
        #expect(m.workspace.splits[a] == .split(sideBySide: true, first: .leaf(b), second: .leaf(a)))
        // A member of another card moves alone.
        m.showBeside(c, of: b)
        m.showBeside(b, of: c, direction: .up)
        #expect(m.sideBySide(c).contains(b) && m.layoutOwner(of: b) == m.layoutOwner(of: c))
    }

    @Test func theCardComesBackAfterARelaunch() throws {
        let f = Fixture()
        defer { f.cleanup() }
        f.transcripts("s0", "s1", "s2", "s3")
        var ids: [UUID] = []
        for i in 0..<4 {
            // Resumable sessions: a relaunch replays them (bounded by `restoreConcurrency`).
            f.manager.newSession(agent: .claude, cwd: f.dir.path, agentSessionId: "s\(i)")
            ids.append(f.selected!)
        }
        let (a, b, c, d) = (ids[0], ids[1], ids[2], ids[3])
        f.manager.showBeside(b, of: a)
        f.manager.showBeside(c, of: a, direction: .down)
        f.manager.close(c)
        f.manager.select(b)
        f.manager.saveNow(wait: true)
        f.manager.prepareForTermination()

        f.env.restoreConcurrency = 1
        f.makeManager()
        let m = f.manager!
        let w = MainWindowController(manager: m)
        m.start()
        // The selected session's card partner starts with it, though only one resume may run at a time.
        #expect(m.live[a] != nil && m.live[b] != nil && m.live[d] == nil && m.isPendingRestore(d))
        #expect(m.paneLayouts[a] == .split(sideBySide: true, first: .leaf(a), second: .leaf(b)))
        #expect(w.container.splitHosts[a] != nil && w.container.shownHost == a)
        #expect(m.workspace.splits == m.paneLayouts)
    }

    @Test func closingAMemberLeavesTheHolderAlone() throws {
        let (f, w, a, b, _) = setup()
        defer { f.cleanup() }
        let m = f.manager!
        m.showBeside(b, of: a)
        let host = try #require(w.container.splitHosts[a])
        m.close(b)
        #expect(w.container.splitHosts[a] == nil && host.superview == nil)
        #expect(m.live[a]!.terminal.view.superview === w.container.stack)
        // The selection stays on what was the card, not the next row.
        #expect(f.selected == a)
    }

    @Test func closeStaysOnTheCardAndDoesNotAskForShellsThatStay() throws {
        let (f, w, a, b, c) = setup()
        defer { f.cleanup() }
        let m = f.manager!
        // Sidebar order a, b, c; card [a, c].
        m.showBeside(c, of: a)
        #expect(f.selected == c)
        m.close(c)
        #expect(f.selected == a)
        m.showBeside(b, of: a)
        m.select(a)
        w.splitRight(nil)
        let shell = try #require(m.panes.values.first)
        (shell.terminal as? FakeTerminal)?.needsConfirmQuit = true
        f.ui.confirms = []
        m.ui = f.ui
        m.requestClose(a)
        // The busy shell stays on the card with b: nothing to confirm.
        #expect(f.ui.confirms.isEmpty && m.live[a] == nil && m.panes[shell.id]?.owner == b)
    }

    @Test func keyboardFollowsTheSelectionOnACard() throws {
        let (f, w, a, b, _) = setup()
        defer { f.cleanup() }
        let m = f.manager!
        m.showBeside(b, of: a)
        let window = try #require(w.window)
        #expect(window.firstResponder === m.live[b]!.terminal.view)
        // Selected without focus (the sidebar's edge chip) while typing in b: the keys go to a.
        m.select(a, focus: false)
        #expect(window.firstResponder === m.live[a]!.terminal.view)
        // Card changes from the sidebar leave its focus alone.
        window.makeFirstResponder(w.sidebar.outline)
        m.showSeparately(b)
        #expect(window.firstResponder === w.sidebar.outline)
    }

    @Test func comingBackToTheWindowMarksTheWholeCardSeen() throws {
        let (f, w, a, b, _) = setup()
        defer { f.cleanup() }
        let m = f.manager!
        m.showBeside(b, of: a)
        f.effects.active = false
        m.ui = f.ui
        m.apply(.hook(HookEvent(agent: .claude, event: "UserPromptSubmit")), to: a)
        m.apply(.hook(HookEvent(agent: .claude, event: "Stop")), to: a)
        #expect(m.status(a)?.unread == true)
        f.effects.active = true
        w.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        #expect(m.status(a)?.unread == false)
    }

    @Test func noLaunchCoverOverASharedCard() throws {
        let (f, w, a, _, _) = setup()
        defer { f.cleanup() }
        let m = f.manager!
        m.newSession(agent: .claude, cwd: f.dir.path)
        let d = try #require(f.selected)
        w.container.updateLaunchCover(animated: false)
        #expect(w.container.launchCover.isShowing)
        m.showBeside(d, of: a)
        w.container.updateLaunchCover(animated: false)
        #expect(!w.container.launchCover.isShowing)
    }

    // MARK: Sidebar

    @Test func sidebarOffersSideBySideAndMarksTheCompanion() throws {
        let (f, w, a, b, _) = setup()
        defer { f.cleanup() }
        let m = f.manager!
        let sidebar = w.sidebar
        let menu = NSMenu()
        sidebar.populate(menu, for: sidebar.node(.session(b)))
        let show = try #require(menu.items.first { $0.title == "Show Side by Side" })
        #expect(!menu.items.contains { $0.title == "Show Separately" })
        sidebar.sideBySideClicked(show)
        #expect(m.sideBySide(a) == [a, b] && f.selected == b)

        sidebar.populate(menu, for: sidebar.node(.session(a)))
        #expect(!menu.items.contains { $0.title == "Show Side by Side" })
        let separately = try #require(menu.items.first { $0.title == "Show Separately" })
        // The selected session's card partner gets the quieter fill.
        let window = try #require(w.window)
        window.contentView?.layoutSubtreeIfNeeded()
        let row = sidebar.outline.row(forItem: sidebar.node(.session(a)))
        let rowView = sidebar.outline.rowView(atRow: row, makeIfNecessary: true) as? SidebarRowView
        sidebar.refreshCompanions()
        #expect(rowView?.companion == true)
        sidebar.separatelyClicked(separately)
        #expect(m.sideBySide(a) == [a])
        #expect(rowView?.companion == false)
    }

    @Test func companionFillSitsBetweenSelectedAndHovered() {
        typealias R = SidebarRowView
        #expect(R.fillState(kind: .session, tone: .plain, selected: false, focused: false, windowKey: true,
                            hovered: true, dropTarget: false, companion: true) == .companion)
        #expect(R.fillState(kind: .session, tone: .plain, selected: true, focused: true, windowKey: true,
                            hovered: false, dropTarget: false, companion: true) == .selectedFocused)
        #expect(R.look(.companion).fill != nil && R.look(.companion).gutter == nil)
    }

    // MARK: Drag and drop

    @Test func draggingASessionOntoTheCardPreviewsAndDropsItOnThatSide() throws {
        let (f, w, a, b, c) = setup()
        defer { f.cleanup() }
        let m = f.manager!
        let container = w.container
        w.window?.contentView?.layoutSubtreeIfNeeded()
        let bounds = container.stack.bounds
        #expect(TerminalContainerViewController.dropSide(NSPoint(x: bounds.minX + 5, y: bounds.midY), in: bounds) == .left)
        #expect(TerminalContainerViewController.dropSide(NSPoint(x: bounds.maxX - 5, y: bounds.midY), in: bounds) == .right)
        #expect(TerminalContainerViewController.dropSide(NSPoint(x: bounds.midX, y: bounds.maxY - 5), in: bounds) == .up)
        #expect(TerminalContainerViewController.dropSide(NSPoint(x: bounds.midX, y: bounds.minY + 5), in: bounds) == .down)
        for side in [SplitDirection.left, .right, .up, .down] {
            let frame = container.dropFrame(side)
            #expect(frame.width > 0 && frame.height > 0)
        }

        // Only open sessions not already on the card.
        #expect(container.droppableSession("s:\(b.uuidString)") == b)
        #expect(container.droppableSession("s:\(a.uuidString)") == nil)
        #expect(container.droppableSession("f:\(b.uuidString)") == nil)
        #expect(container.droppableSession(nil) == nil)

        let right = container.card.convert(NSPoint(x: bounds.maxX - 5, y: bounds.midY), from: container.stack)
        #expect(container.dragOver(token: "s:\(b.uuidString)", at: right) == .move)
        #expect(!container.dropPreview.isHidden && container.dropPreview.side == .right)
        #expect(container.dropPreview.label.stringValue == m.workspace.sessions[b]?.displayTitle)
        #expect(container.dragOver(token: "s:\(a.uuidString)", at: right) == [])
        #expect(container.dropPreview.isHidden)
        container.cardDragEnded()
        #expect(container.drop(token: "s:\(b.uuidString)", at: right))
        #expect(container.dropPreview.isHidden)
        #expect(m.paneLayouts[a] == .split(sideBySide: true, first: .leaf(a), second: .leaf(b)))
        let top = container.card.convert(NSPoint(x: bounds.midX, y: bounds.maxY - 5), from: container.stack)
        #expect(container.drop(token: "s:\(c.uuidString)", at: top))
        #expect(m.paneLayouts[a] == .split(sideBySide: false, first: .leaf(c), second: .split(sideBySide: true, first: .leaf(a), second: .leaf(b))))
        #expect(!container.drop(token: "s:\(c.uuidString)", at: top))
    }
}
