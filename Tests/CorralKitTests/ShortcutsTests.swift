import AppKit
@testable import CorralCore
import Testing
@testable import CorralKit

/// Keyboard-shortcuts sheet: built from the menu, shown through Presenter (never on screen here).
@MainActor
@Suite(.serialized)
struct ShortcutsTests {
    func item(_ title: String, _ action: Selector?, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        return i
    }

    @Test func listReadsTheMenuCollapsesNumberedRunsAndSkipsStandardCommands() {
        let bar = NSMenu()
        func top(_ title: String, _ items: [NSMenuItem]) {
            let t = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            items.forEach { m.addItem($0) }
            t.submenu = m
            bar.addItem(t)
        }
        let go = #selector(MainWindowController.selectSessionByNumber(_:))
        top("Go", [item("Search All Sessions…", #selector(MainWindowController.searchSessions(_:)), "k"), .separator()]
            + (1...8).map { item("Session \($0)", go, "\($0)") }
            + [item("Last Session", go, "9"), item("No Key", #selector(MainWindowController.nextSession(_:)), "")])
        top("Edit", [item("Copy", #selector(NSText.copy(_:)), "c"),
                     item("Clear Screen", #selector(MainWindowController.clearTerminal(_:)), "k", [.command, .shift])])
        top("Window", [item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")])
        bar.addItem(NSMenuItem(title: "No submenu", action: nil, keyEquivalent: ""))

        let sections = ShortcutList.sections(from: bar)
        #expect(sections.map(\.title) == ["Go", "Edit"])
        #expect(sections[0].rows == [.init(name: "Search All Sessions", keys: "⌘K"),
                                     .init(name: "Session 1–8", keys: "⌘1–8"),
                                     .init(name: "Last Session", keys: "⌘9")])
        #expect(sections[1].rows == [.init(name: "Clear Screen", keys: "⇧⌘K")])
    }

    @Test func realMenuListsCorralShortcuts() {
        _ = NSApplication.shared  // buildMenu registers the Window and Help menus with NSApp
        let d = AppDelegate(makeTerminals: { FakeFactory() })
        let menu = d.buildMenu()
        #expect(menu.items.last?.title == "Help")
        let rows = ShortcutList.sections(from: menu).flatMap(\.rows)
        for (name, keys) in [("Search All Sessions", "⌘K"), ("Clear Screen", "⇧⌘K"), ("Next Session Needing Input", "⌘I"),
                             ("Session 1–8", "⌘1–8"), ("Last Session", "⌘9"), ("New Claude Session", "⌃⌘C")] {
            #expect(rows.contains(.init(name: name, keys: keys)), "\(name) \(keys)")
        }
        // Standard commands, window management and the sheet itself (named in its footer) are left out.
        #expect(!rows.contains { ["Copy", "Minimize", "Show Main Window", "Keyboard Shortcuts"].contains($0.name) })
        let columns = ShortcutList.columns(ShortcutList.sections(from: menu))
        #expect(columns.count == 2)
        let heights = columns.map { $0.map { $0.rows.count + 2 }.reduce(0, +) }
        #expect(abs(heights[0] - heights[1]) <= 6)
    }

    @Test func columnsSplitEvenlyAndKeepOrder() {
        func sec(_ t: String, _ n: Int) -> ShortcutSection {
            ShortcutSection(title: t, rows: (0..<n).map { .init(name: "\(t)\($0)", keys: "⌘\($0)") })
        }
        #expect(ShortcutList.columns([]).count == 1)
        #expect(ShortcutList.columns([sec("A", 3)]).map { $0.map(\.title) } == [["A"]])
        #expect(ShortcutList.columns([sec("A", 3), sec("B", 9), sec("C", 2), sec("D", 7), sec("E", 1)]).map { $0.map(\.title) }
                == [["A", "B"], ["C", "D", "E"]])
    }

    @Test func sheetShowsEverySection() {
        let sections = [ShortcutSection(title: "Go", rows: [.init(name: "Search", keys: "⌘K"), .init(name: "Next", keys: "⌘I")]),
                        ShortcutSection(title: "Edit", rows: [.init(name: "Clear Screen", keys: "⇧⌘K")])]
        let v = ShortcutsView(sections: sections)
        v.layoutSubtreeIfNeeded()
        #expect(v.rowLabels.map(\.stringValue) == ["Search", "Next", "Clear Screen"])
        #expect(v.keyCaps.map(\.stringValue) == ["⌘K", "⌘I", "⇧⌘K"])
        // Two columns side by side (plus 16 pt margins and the 24 pt gutter).
        #expect(v.fittingSize.width == 2 * ShortcutsView.columnWidth + 24 + 32)
        #expect(ShortcutsView.note.hasSuffix("Hold ⌘ to see the session numbers in the sidebar."))
        let p = ShortcutsView.popover(menu: nil)
        #expect(p.behavior == .transient)
        #expect(p.contentSize.width == ShortcutsView.columnWidth + 32)
    }

    @Test func iconAndMenuOpenTheSheetNextToTheCounts() {
        let f = Fixture()
        defer { f.cleanup() }
        var shown: [(NSView, NSRectEdge)] = []
        let saved = Presenter.popover
        Presenter.popover = { _, _, view, edge in shown.append((view, edge)) }
        defer { Presenter.popover = saved }
        let w = MainWindowController(manager: f.manager)
        let button = w.sidebar.bottomBar.shortcutsButton
        #expect(button.action == #selector(MainWindowController.showShortcuts(_:)))
        #expect(button.accessibilityLabel() == "Keyboard Shortcuts")
        w.showShortcuts(nil)
        // Opens above the button: the button is flipped, so "above" is its minY edge.
        #expect(button.isFlipped)
        #expect(shown.last?.0 === button && shown.last?.1 == .minY)
        let first = try! #require(w.shortcutsPopover)
        // The click that closed the transient popover lands right after it closed: no reopen.
        w.popoverDidClose(Notification(name: NSPopover.didCloseNotification, object: first))
        #expect(w.shortcutsPopover == nil)
        w.showShortcuts(nil)
        #expect(shown.count == 1)
        // Sidebar hidden: anchored low in the window instead (once the close has settled).
        Thread.sleep(forTimeInterval: 0.35)
        w.container.sidebarCollapsed = true
        w.showShortcuts(nil)
        let content = try! #require(w.window?.contentView)
        #expect(shown.count == 2 && shown.last?.0 === content)
        #expect(shown.last?.1 == (content.isFlipped ? .minY : .maxY))
        w.container.sidebarCollapsed = false
    }

    /// Corral's layer over the user's Ghostty config: ⌘K belongs to Search All Sessions.
    @Test func ghosttyDefaultsUnbindCommandK() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("corral-gd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try #require(GhosttyDefaults.write(to: dir))
        #expect(try String(contentsOfFile: path, encoding: .utf8) == GhosttyDefaults.config)
        #expect(GhosttyDefaults.config.contains("keybind = super+k=unbind"))
        #expect(GhosttyDefaults.config.contains("keybind = super+shift+t=unbind"))
        #expect(GhosttyDefaults.write(to: dir) == path)
        #expect(GhosttyDefaults.write(to: URL(fileURLWithPath: "/dev/null/nope")) == nil)
    }
}
