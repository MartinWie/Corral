import AppKit
import Carbon.HIToolbox
@testable import CorralCore
import Testing
@testable import CorralKit

/// Customizable shortcuts: the store over the real menu, the recorder field and the window (never on screen).
@MainActor
@Suite(.serialized)
struct ShortcutCustomizeTests {
    /// A store over the app's real menu, on throwaway defaults.
    final class Setup {
        let name = "corral-shortcuts-\(UUID().uuidString)"
        let defaults: UserDefaults
        let app: AppDelegate
        let menu: NSMenu
        let savedUnbinds = GhosttyDefaults.unbinds

        init(name: String? = nil) {
            _ = NSApplication.shared
            let n = name ?? self.name
            defaults = UserDefaults(suiteName: n)!
            app = AppDelegate(makeTerminals: { FakeFactory() }, shortcutDefaults: defaults)
            // Import from claude-sessions: the one menu command without a built-in shortcut.
            app.trackerAvailable = { true }
            menu = app.buildMenu()
        }

        var store: ShortcutStore { app.shortcuts }

        func item(_ action: Selector, tag: Int? = nil) -> NSMenuItem? {
            func find(_ m: NSMenu) -> NSMenuItem? {
                for i in m.items {
                    if i.action == action, tag == nil || i.tag == tag { return i }
                    if let sub = i.submenu, let hit = find(sub) { return hit }
                }
                return nil
            }
            return find(menu)
        }

        func keys(_ action: Selector, tag: Int? = nil) -> String? {
            item(action, tag: tag).map { $0.keyEquivalent.isEmpty ? "" : KeyHint.format($0.keyEquivalent, $0.keyEquivalentModifierMask) }
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: name)
            GhosttyDefaults.unbinds = savedUnbinds
        }
    }

    static let search = NSStringFromSelector(#selector(MainWindowController.searchSessions(_:)))
    static let clear = NSStringFromSelector(#selector(MainWindowController.clearTerminal(_:)))
    static let showMain = NSStringFromSelector(#selector(AppDelegate.showMain(_:)))

    func key(_ chars: String, _ code: Int, _ mods: NSEvent.ModifierFlags = [], repeat: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: `repeat`, keyCode: UInt16(code))!
    }

    // MARK: KeyCombo

    @Test func comboReadsMenuItemsEventsAndStoredText() throws {
        let item = NSMenuItem(title: "X", action: nil, keyEquivalent: "K")
        item.keyEquivalentModifierMask = .command
        let fromItem = try #require(KeyCombo(item: item))
        #expect(fromItem == KeyCombo(key: "k", mods: [.command, .shift]))  // uppercase implies ⇧
        #expect(fromItem.display == "⇧⌘K")
        #expect(KeyCombo(item: NSMenuItem(title: "", action: nil, keyEquivalent: "")) == nil)
        #expect(KeyCombo(key: "k", mods: [.command, .capsLock, .function]).mods == .command)

        #expect(KeyCombo(event: key("k", kVK_ANSI_K, [.command, .shift])) == KeyCombo(key: "k", mods: [.command, .shift]))
        #expect(KeyCombo(event: key("\u{7f}", kVK_Delete, .command))?.key == "\u{8}")
        #expect(KeyCombo(event: key("\u{3}", kVK_ANSI_KeypadEnter, .command))?.key == "\r")
        #expect(KeyCombo(event: NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                 context: nil, characters: "k", charactersIgnoringModifiers: "k",
                                                 isARepeat: false, keyCode: 40)!) == nil)

        let c = KeyCombo(key: "]", mods: [.command, .control, .option, .shift])
        #expect(KeyCombo(encoded: c.encoded) == c)
        #expect(KeyCombo(encoded: "nope") == nil && KeyCombo(encoded: "1|ab") == nil && KeyCombo(encoded: "x|k") == nil)
    }

    @Test func comboNamesKeysForMenusAndGhostty() {
        let f5 = String(UnicodeScalar(NSF5FunctionKey)!)
        let up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        #expect(KeyCombo(key: "]", mods: [.command, .control, .option, .shift]).ghosttyTriggers == ["ctrl+alt+shift+super+]"])
        #expect(KeyCombo(key: "+", mods: .command).ghosttyTriggers == ["super++"])
        #expect(KeyCombo(key: f5, mods: []).ghosttyTriggers == ["f5"])
        // Ghostty binds ⌘1… by character and by physical key.
        #expect(KeyCombo(key: "3", mods: [.command, .control]).ghosttyTriggers == ["ctrl+super+3", "ctrl+super+digit_3"])
        // Keys neither side can name are refused.
        #expect(KeyCombo.isUsable("k") && KeyCombo.isUsable(f5) && KeyCombo.isUsable(up))
        #expect(!KeyCombo.isUsable(">") && !KeyCombo.isUsable(String(UnicodeScalar(NSF25FunctionKey)!)))
        #expect(!KeyCombo.isUsable(String(UnicodeScalar(NSClearLineFunctionKey)!)) && !KeyCombo.isUsable(""))
        #expect(KeyCombo(key: f5, mods: []).isFunctionKey)
        #expect(!KeyCombo(key: "k", mods: .command).isFunctionKey)
        let named: [(String, String, String)] = [
            ("\r", "enter", "↩"), ("\t", "tab", "⇥"), ("\u{8}", "backspace", "⌫"), ("\u{1b}", "escape", "esc"),
            (" ", "space", "Space"), (up, "arrow_up", "↑"), (String(UnicodeScalar(NSDownArrowFunctionKey)!), "arrow_down", "↓"),
            (String(UnicodeScalar(NSLeftArrowFunctionKey)!), "arrow_left", "←"),
            (String(UnicodeScalar(NSRightArrowFunctionKey)!), "arrow_right", "→"),
            (String(UnicodeScalar(NSHomeFunctionKey)!), "home", "↖"), (String(UnicodeScalar(NSEndFunctionKey)!), "end", "↘"),
            (String(UnicodeScalar(NSPageUpFunctionKey)!), "page_up", "⇞"),
            (String(UnicodeScalar(NSPageDownFunctionKey)!), "page_down", "⇟"),
            (String(UnicodeScalar(NSDeleteFunctionKey)!), "delete", "⌦"), (f5, "f5", "F5"), ("k", "k", "K"),
        ]
        for (k, ghostty, shown) in named {
            #expect(KeyCombo.ghosttyKey(k) == ghostty, "\(ghostty)")
            #expect(KeyHint.keyName(k) == shown, "\(shown)")
        }
        #expect(KeyHint.keyName("\u{7f}") == "⌫")
        #expect(KeyHint.modifierGlyphs([.command, .shift, .control, .option]) == ["⌃", "⌥", "⇧", "⌘"])
    }

    // MARK: Store

    @Test func storeListsMenuCommandsButNotStandardOnes() throws {
        let s = Setup()
        defer { s.cleanup() }
        let titles = s.store.actions.map(\.title)
        for t in ["Search All Sessions", "Clear Screen", "Split Right", "Settings", "Open Ghostty Config",
                  "Keyboard Shortcuts", "Show Main Window", "Session by Number", "Import from claude-sessions"] {
            #expect(titles.contains(t), "\(t)")
        }
        for t in ["Copy", "Paste", "Quit Corral", "Minimize", "Zoom", "About Corral", "Session 2", "Last Session"] {
            #expect(!titles.contains(t), "\(t)")
        }
        #expect(titles.filter { $0 == "Session by Number" }.count == 1)
        #expect(Array(NSOrderedSet(array: s.store.actions.map(\.section))) as? [String]
                == ["Corral", "Session", "Edit", "Go", "View", "Window", "Help"])
        let numbered = try #require(s.store.action(ShortcutStore.numberedId))
        #expect(numbered.isNumbered && numbered.section == "Go")
        #expect(s.store.combo(for: Self.search) == KeyCombo(key: "k", mods: .command))
        #expect(s.store.combo(for: NSStringFromSelector(#selector(AppDelegate.importFromTracker(_:)))) == nil)
        #expect(!s.store.hasOverrides && s.store.ghosttyUnbinds.isEmpty)
        #expect(s.store.set(KeyCombo(key: "g", mods: .command), for: "nope") == .rejected("Unknown command"))
    }

    @Test func movingFocusUpFreesGhosttysArrowBinding() {
        let s = Setup()
        defer { s.cleanup() }
        let focusUp = NSStringFromSelector(#selector(MainWindowController.focusUp(_:)))
        #expect(s.keys(#selector(MainWindowController.focusUp(_:))) == "⌥⌘↑")
        #expect(s.store.set(KeyCombo(key: "u", mods: [.command, .option]), for: focusUp) == .accepted(displaced: []))
        // ⌥⌘↑ goes back to the terminal (no more goto_split there), ⌥⌘U reaches the menu.
        #expect(s.store.ghosttyUnbinds == ["alt+super+arrow_up", "alt+super+u"])
    }

    @Test func settingMovesTheMenuKeyPersistsAndUnbindsInTerminals() {
        let s = Setup()
        defer { s.cleanup() }
        var changes = 0
        let saved = s.store.onChange
        s.store.onChange = { changes += 1; saved?($0) }
        let posted = NotificationCenter.default.addObserver(forName: .corralShortcutsChanged, object: s.store, queue: nil) { _ in }
        defer { NotificationCenter.default.removeObserver(posted) }

        let search = #selector(MainWindowController.searchSessions(_:))
        #expect(s.store.set(KeyCombo(key: "g", mods: .command), for: Self.search) == .accepted(displaced: []))
        #expect(s.keys(search) == "⌘G")
        #expect(s.store.isCustomized(Self.search) && s.store.hasOverrides)
        #expect(changes == 1)
        // ⌘K is freed in terminals too (Ghostty's own ⌘K would clear the screen), ⌘G is unbound so the menu gets it.
        #expect(s.store.ghosttyUnbinds == ["super+g", "super+k"])
        #expect(GhosttyDefaults.unbinds == ["super+g", "super+k"])
        #expect(GhosttyDefaults.config.hasSuffix("keybind = super+g=unbind\nkeybind = super+k=unbind\n"))
        #expect(GhosttyDefaults.config.hasPrefix(GhosttyDefaults.base))

        // A fresh launch reads it back.
        let again = Setup(name: s.name)
        #expect(again.keys(search) == "⌘G")

        // Back to the built-in combo: no override left, nothing stored.
        s.store.set(KeyCombo(key: "k", mods: .command), for: Self.search)
        #expect(!s.store.isCustomized(Self.search))
        #expect(s.defaults.dictionary(forKey: ShortcutStore.defaultsKey) == nil)
        #expect(GhosttyDefaults.unbinds.isEmpty)
        #expect(GhosttyDefaults.config == GhosttyDefaults.base)
    }

    @Test func takenShortcutMovesAndTheOtherCommandLosesIt() {
        let s = Setup()
        defer { s.cleanup() }
        let clear = #selector(MainWindowController.clearTerminal(_:))
        #expect(s.store.set(KeyCombo(key: "k", mods: [.command, .shift]), for: Self.search) == .accepted(displaced: [Self.clear]))
        #expect(s.keys(clear) == "")
        #expect(s.store.combo(for: Self.clear) == nil && s.store.isCustomized(Self.clear))
        // Clear Screen takes its shortcut back: Search loses it (its own ⌘K stays free, it is an override).
        #expect(s.store.reset(Self.clear) == .accepted(displaced: [Self.search]))
        #expect(s.keys(clear) == "⇧⌘K")
        #expect(s.store.combo(for: Self.search) == nil)
        #expect(s.store.reset(Self.search) == .accepted(displaced: []))
        #expect(!s.store.hasOverrides)
        #expect(s.store.reset(Self.search) == .accepted(displaced: []))  // nothing to reset

        // A command without a built-in shortcut that is displaced just has none again.
        let reindex = NSStringFromSelector(#selector(AppDelegate.importFromTracker(_:)))
        s.store.set(KeyCombo(key: "j", mods: .command), for: reindex)
        #expect(s.store.set(KeyCombo(key: "j", mods: .command), for: Self.search) == .accepted(displaced: [reindex]))
        #expect(!s.store.isCustomized(reindex))
        // Removing: built-in → cleared; no built-in → back to nothing stored.
        s.store.set(nil, for: Self.clear)
        #expect(s.store.combo(for: Self.clear) == nil && s.store.isCustomized(Self.clear))
        s.store.set(KeyCombo(key: "y", mods: .command), for: reindex)
        s.store.set(nil, for: reindex)
        #expect(!s.store.isCustomized(reindex))
        let reset = s.store.resetAll()
        #expect(Set(reset) == [Self.search, Self.clear])
        #expect(s.store.resetAll().isEmpty)
        #expect(s.keys(#selector(MainWindowController.searchSessions(_:))) == "⌘K")
    }

    @Test func refusesReservedAndModifierlessCombos() {
        let s = Setup()
        defer { s.cleanup() }
        #expect(s.store.set(KeyCombo(key: "q", mods: .command), for: Self.search) == .rejected("⌘Q is Quit Corral"))
        #expect(s.store.set(KeyCombo(key: "c", mods: .command), for: Self.search) == .rejected("⌘C is Copy"))
        #expect(s.store.set(KeyCombo(key: "x", mods: .command), for: Self.search) == .rejected("⌘X is Cut"))
        #expect(s.store.set(KeyCombo(key: "f", mods: [.command, .control]), for: Self.search) == .rejected("⌃⌘F is Enter Full Screen"))
        #expect(s.store.set(KeyCombo(key: "k", mods: .option), for: Self.search) == .rejected("Needs ⌘ (⌃ and ⌥ belong to the terminal)"))
        #expect(s.store.set(KeyCombo(key: "k", mods: .control), for: Self.search) != .accepted(displaced: []))
        #expect(s.store.set(KeyCombo(key: "\r", mods: [.command, .control]), for: Self.search) == .rejected("⌃↩ belongs to the terminal"))
        #expect(s.store.set(KeyCombo(key: "\r", mods: .command), for: Self.search) == .accepted(displaced: []))
        // A function key works on its own.
        #expect(s.store.set(KeyCombo(key: String(UnicodeScalar(NSF6FunctionKey)!), mods: []), for: Self.search) == .accepted(displaced: []))
        #expect(s.keys(#selector(MainWindowController.searchSessions(_:))) == "F6")
        // The digits belong to Session by Number.
        #expect(s.store.set(KeyCombo(key: "4", mods: .command), for: Self.search) == .rejected("⌘4 is Session 4"))
        #expect(s.store.set(KeyCombo(key: "9", mods: .command), for: Self.search) == .rejected("⌘9 is Last Session"))
        #expect(!s.store.isCustomized(Self.clear))
    }

    @Test func sessionByNumberChangesOnlyItsModifiers() {
        let s = Setup()
        defer { s.cleanup() }
        let go = ShortcutStore.numbered
        let id = ShortcutStore.numberedId
        #expect(s.store.set(KeyCombo(key: "k", mods: .command), for: id) == .rejected("Press a number key"))
        #expect(s.store.set(KeyCombo(key: "3", mods: [.command, .shift]), for: id) == .rejected("⇧⌘3 is Screenshot"))
        #expect(s.store.set(KeyCombo(key: "5", mods: [.command, .control]), for: id) == .accepted(displaced: []))
        for n in 1...9 { #expect(s.keys(go, tag: n) == "⌃⌘\(n)") }
        #expect(s.store.combo(for: id) == KeyCombo(key: "1", mods: [.command, .control]))
        // ⌘1… are free now, ⌃⌘1… unbound in terminals.
        for t in ["super+1", "super+digit_1", "ctrl+super+9", "ctrl+super+digit_9"] { #expect(s.store.ghosttyUnbinds.contains(t), "\(t)") }
        #expect(s.store.set(KeyCombo(key: "4", mods: .command), for: Self.search) == .accepted(displaced: []))
        // ⌥⌘ takes Show Main Window's ⌥⌘1.
        #expect(s.store.set(KeyCombo(key: "1", mods: [.command, .option]), for: id) == .accepted(displaced: [Self.showMain]))
        #expect(s.keys(#selector(AppDelegate.showMain(_:))) == "")
        // …which can't take it back while the sessions hold it.
        #expect(s.store.reset(Self.showMain) == .rejected("⌥⌘1 is Session 1"))
        s.store.set(nil, for: id)
        for n in 1...9 { #expect(s.keys(go, tag: n) == "") }
        let saved = NSApplication.shared.mainMenu
        NSApplication.shared.mainMenu = nil
        #expect(SidebarViewController.numberHint(3) == "⌘3")  // no main menu: the built-in hint
        NSApplication.shared.mainMenu = saved
    }

    @Test func sidebarNumberHintsReadTheMenu() {
        let s = Setup()
        defer { s.cleanup() }
        let saved = NSApplication.shared.mainMenu
        NSApplication.shared.mainMenu = s.menu
        defer { NSApplication.shared.mainMenu = saved }
        #expect(SidebarViewController.numberHint(2) == "⌘2")
        s.store.set(KeyCombo(key: "1", mods: [.command, .control]), for: ShortcutStore.numberedId)
        #expect(SidebarViewController.numberHint(9) == "⌃⌘9")
        s.store.set(nil, for: ShortcutStore.numberedId)
        #expect(SidebarViewController.numberHint(2) == nil)
        #expect(KeyHint.string(for: #selector(MainWindowController.searchSessions(_:))) == "⌘K")
        #expect(KeyHint.string(for: ShortcutStore.numbered, tag: 4) == nil)
    }

    @Test func hintsAcrossTheWindowFollowAChange() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let s = Setup()
        defer { s.cleanup() }
        let saved = NSApplication.shared.mainMenu
        NSApplication.shared.mainMenu = s.menu
        defer { NSApplication.shared.mainMenu = saved }
        let w = MainWindowController(manager: f.manager)
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        w.sidebar.shortcutsChanged()
        #expect(w.sidebar.bottomBar.newFolderButton.toolTip == "New Folder (⇧⌘N)")
        s.store.set(KeyCombo(key: "n", mods: [.command, .option]), for: NSStringFromSelector(#selector(MainWindowController.newFolder(_:))))
        #expect(w.sidebar.bottomBar.newFolderButton.toolTip == "New Folder (⌥⌘N)")
        s.store.set(KeyCombo(key: "/", mods: [.command, .shift]), for: NSStringFromSelector(#selector(MainWindowController.showShortcuts(_:))))
        #expect(w.sidebar.bottomBar.shortcutsButton.toolTip == "Keyboard Shortcuts (⇧⌘/)")
        s.store.set(nil, for: NSStringFromSelector(#selector(MainWindowController.nextAttention(_:))))
        #expect(SidebarStatusBar.tooltip(.needsInput) == "Next needing input")
        #expect(w.container.placeholder.attentionKey.stringValue == "")
    }

    // MARK: Recorder

    @Test func recorderShowsCapsRecordsAndRefuses() {
        let r = ShortcutRecorderView()
        r.name = "Search"
        r.setCombo(KeyCombo(key: "k", mods: [.command, .shift]), animated: false)
        r.layoutSubtreeIfNeeded()
        #expect(r.tokens == ["⇧", "⌘", "K"])
        #expect(r.caps.map(\.token) == ["⇧", "⌘", "K"])
        #expect(r.displayText == "⇧⌘K" && r.promptText == "")
        #expect(r.accessibilityLabel() == "Search shortcut")
        #expect(r.accessibilityValue() as? String == "⇧⌘K")
        #expect(r.accessibilityRole() == .button && r.isAccessibilityElement())
        // Caps sit centered, side by side.
        let xs = r.caps.map(\.position.x)
        #expect(xs == xs.sorted())
        #expect(abs((r.caps.first!.frame.minX + r.caps.last!.frame.maxX) / 2 - r.bounds.midX) < 0.5)

        var offered: [KeyCombo?] = []
        var refusal: String? = "⌘Q is Quit Corral"
        r.onRecord = { c in
            offered.append(c)
            return refusal.map { .refused($0) } ?? .taken(c)
        }
        #expect(!r.performKeyEquivalent(with: key("q", kVK_ANSI_Q, .command)))
        r.mouseDown(with: NSEvent())
        #expect(r.isRecording && r.tokens.isEmpty && r.promptText == ShortcutRecorderView.recordingPrompt)
        #expect(r.accessibilityValue() as? String == "Recording")
        r.setLiveMods([.command, .shift, .capsLock])
        #expect(r.tokens == ["⇧", "⌘"] && r.promptText == "")
        // Refused: still recording, says why in place of the caps.
        #expect(r.performKeyEquivalent(with: key("q", kVK_ANSI_Q, .command)))
        #expect(offered == [KeyCombo(key: "q", mods: .command)])
        #expect(r.isRecording && r.message == "⌘Q is Quit Corral" && r.tokens.isEmpty && r.promptText == "⌘Q is Quit Corral")
        #expect(r.accessibilityValue() as? String == "⌘Q is Quit Corral")
        // Holding a modifier again starts the next try.
        r.setLiveMods(.command)
        #expect(r.message == nil && r.tokens == ["⌘"])
        r.keyDown(with: key("g", kVK_ANSI_G, .command, repeat: true))  // repeats are ignored
        #expect(offered.count == 1)
        refusal = nil
        r.keyDown(with: key("g", kVK_ANSI_G, .command))
        #expect(!r.isRecording && r.combo == KeyCombo(key: "g", mods: .command) && r.tokens == ["⌘", "G"])
        #expect(r.caps.map(\.token) == ["⌘", "G"])

        // esc cancels, ⌫ removes the shortcut.
        r.keyDown(with: key(" ", kVK_Space))
        #expect(r.isRecording)
        r.keyDown(with: key("\u{1b}", kVK_Escape))
        #expect(!r.isRecording && r.combo == KeyCombo(key: "g", mods: .command))
        _ = r.accessibilityPerformPress()
        #expect(r.isRecording)
        _ = r.accessibilityPerformPress()
        #expect(!r.isRecording)
        r.beginRecording()
        r.keyDown(with: key("\u{7f}", kVK_Delete))
        #expect(offered.last == .some(nil) && r.combo == nil)
        #expect(r.promptText == ShortcutRecorderView.nonePrompt && r.displayText == "None" && r.caps.isEmpty)
        // ⌘⌫ is a shortcut like any other.
        r.beginRecording()
        r.keyDown(with: key("\u{7f}", kVK_Delete, .command))
        #expect(r.combo == KeyCombo(key: "\u{8}", mods: .command) && r.tokens == ["⌘", "⌫"])
        // Clicking again while recording cancels; losing focus does too.
        r.beginRecording()
        r.mouseDown(with: NSEvent())
        #expect(!r.isRecording)
        r.beginRecording()
        _ = r.resignFirstResponder()
        #expect(!r.isRecording)
        // Not recording: other keys and flags pass through.
        r.setLiveMods(.command)
        #expect(r.liveMods.isEmpty)
        r.flagsChanged(with: NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .command, timestamp: 0,
                                              windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                              isARepeat: false, keyCode: 55)!)
        r.beginRecording()
        r.flagsChanged(with: NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
                                              windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                              isARepeat: false, keyCode: 58)!)
        #expect(r.tokens == ["⌥", "⌘"])
        r.cancelRecording()
        r.cancelRecording()
        #expect(r.acceptsFirstResponder && r.focusRingMaskBounds == r.bounds)
        // The store's form wins (Session by Number keeps "1" whatever digit was typed).
        r.onRecord = { _ in .taken(KeyCombo(key: "1", mods: .command)) }
        r.beginRecording()
        r.submit(KeyCombo(key: "5", mods: .command))
        #expect(r.combo == KeyCombo(key: "1", mods: .command))
        // No handler: takes what was typed.
        r.onRecord = nil
        r.beginRecording()
        r.submit(KeyCombo(key: "j", mods: .command))
        #expect(r.combo == KeyCombo(key: "j", mods: .command))
    }

    @Test func recorderRefusalFadesAndNumberedRowShowsItsRange() async throws {
        let r = ShortcutRecorderView()
        r.keyLabel = "1–9"
        r.setCombo(KeyCombo(key: "1", mods: .command), animated: false)
        #expect(r.tokens == ["⌘", "1–9"])
        #expect(r.caps.last!.width > ShortcutRecorderView.capHeight)  // words get wider caps
        #expect(r.caps.first!.width == ShortcutRecorderView.capHeight)
        r.refuse("⌥⌘1 is Session 1")
        #expect(r.message != nil && r.tokens.isEmpty)
        try await Task.sleep(for: .seconds(ShortcutRecorderView.messageDuration + 0.3))
        #expect(r.message == nil && r.tokens == ["⌘", "1–9"])
        // Same combo, accepted: still lands (the bounce), no state change.
        r.setCombo(KeyCombo(key: "1", mods: .command), change: .accepted)
        #expect(r.combo == KeyCombo(key: "1", mods: .command))
        r.setCombo(nil, change: .displaced)
        #expect(r.caps.isEmpty && r.promptText == "None")
    }

    /// Every animation path, in an invisible click-through window (Reduce Motion off, then on).
    @Test func recorderAnimatesInAWindow() {
        let wasEnabled = Motion.enabled, wasReduced = Motion.reduced
        Motion.enabled = true
        Motion.assumeVisible = true
        defer {
            Motion.enabled = wasEnabled
            Motion.assumeVisible = false
            Motion.setReduced(wasReduced)
        }
        for reduced in [false, true] {
            Motion.setReduced(reduced)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            let r = ShortcutRecorderView()
            window.contentView?.addSubview(r)
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            r.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            r.setCombo(KeyCombo(key: "k", mods: .command))
            r.onRecord = { $0?.key == "q" ? .refused("no") : .taken($0) }
            r.beginRecording()
            #expect(r.isRecording && (window.firstResponder === r || !window.isKeyWindow))
            #expect(r.body.animation(forKey: "breathe") != nil)
            r.setLiveMods(.command)
            r.setLiveMods([.command, .shift])
            r.submit(KeyCombo(key: "q", mods: .command))
            #expect(r.message == "no")
            if !reduced { #expect(r.body.animation(forKey: "shake") != nil) }
            r.submit(KeyCombo(key: "g", mods: [.command, .shift]))
            #expect(!r.isRecording && r.body.animation(forKey: "breathe") == nil && r.body.animation(forKey: "flash") != nil)
            if !reduced { #expect(r.body.animation(forKey: "settle") != nil) }
            r.setCombo(KeyCombo(key: "g", mods: .command))  // ⇧ shrinks away, ⌘ and G slide over
            r.setCombo(nil, change: .displaced)
            #expect(r.body.animation(forKey: "ring") != nil)
            r.mouseEntered(with: NSEvent())
            r.updateLayer()
            r.mouseExited(with: NSEvent())
            r.updateTrackingAreas()
            r.viewDidChangeBackingProperties()
            NotificationCenter.default.post(name: .corralThemeDidChange, object: nil)
            r.beginRecording()
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
            #expect(!r.isRecording)
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            #expect(r.caps.allSatisfy { $0.superlayer === r.body })
            r.removeFromSuperview()
        }
    }

    // MARK: Window

    @Test func pageListsEveryCommandAndFollowsTheStore() throws {
        let s = Setup()
        defer { s.cleanup() }
        let c = ShortcutSettingsView(store: s.store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView?.addSubview(c)
        #expect(c.rows.map(\.id) == s.store.actions.map(\.id))
        #expect(c.sections().map(\.0) == ["Corral", "Session", "Edit", "Go", "View", "Window", "Help"])
        #expect(c.groups.count == 7 && c.sectionLabels.count == 7)
        #expect(!c.restoreButton.isEnabled)
        let search = try #require(c.row(Self.search))
        let clear = try #require(c.row(Self.clear))
        #expect(search.recorder.displayText == "⌘K" && search.reset.alphaValue == 0 && !search.reset.isEnabled)
        #expect(c.row(ShortcutStore.numberedId)?.recorder.tokens == ["⌘", "1–9"])

        // Typing ⇧⌘K into Search: it takes it, Clear Screen loses it.
        search.recorder.beginRecording()
        search.recorder.keyDown(with: key("k", kVK_ANSI_K, [.command, .shift]))
        #expect(!search.recorder.isRecording && search.recorder.displayText == "⇧⌘K")
        #expect(clear.recorder.displayText == "None")
        #expect(search.reset.alphaValue == 1 && clear.reset.alphaValue == 1 && search.reset.isEnabled)
        #expect(c.restoreButton.isEnabled)
        // ↺ on another row while Search records: recording ends, Search shows what the store has.
        search.recorder.beginRecording()
        c.resetRow(clear.reset)
        #expect(!search.recorder.isRecording && search.recorder.displayText == "None" && clear.recorder.displayText == "⇧⌘K")
        s.store.set(KeyCombo(key: "k", mods: [.command, .shift]), for: Self.search)
        #expect(search.recorder.displayText == "⇧⌘K" && clear.recorder.displayText == "None")
        // The store changing under a recording row: esc shows the new value, not the old one.
        search.recorder.beginRecording()
        s.store.set(KeyCombo(key: "k", mods: [.command, .shift]), for: Self.clear)
        #expect(search.recorder.isRecording && search.recorder.combo == nil)
        search.recorder.cancelRecording()
        #expect(search.recorder.displayText == "None")
        s.store.set(KeyCombo(key: "k", mods: [.command, .shift]), for: Self.search)
        // Session by Number keeps its canonical "1" whatever digit is typed (no endless re-sync).
        let numbered = try #require(c.row(ShortcutStore.numberedId))
        numbered.recorder.beginRecording()
        numbered.recorder.keyDown(with: key("5", kVK_ANSI_5, [.command, .control]))
        #expect(numbered.recorder.combo == KeyCombo(key: "1", mods: [.command, .control]))
        #expect(numbered.recorder.displayText == "⌃⌘1–9")
        s.store.reset(ShortcutStore.numberedId)
        // A refused combo leaves everything as it was.
        search.recorder.beginRecording()
        search.recorder.keyDown(with: key("c", kVK_ANSI_C, .command))
        #expect(search.recorder.isRecording && search.recorder.message == "⌘C is Copy")
        search.recorder.cancelRecording()

        // ↺ on Clear Screen takes ⇧⌘K back.
        c.resetRow(clear.reset)
        #expect(clear.recorder.displayText == "⇧⌘K" && search.recorder.displayText == "None")
        c.restoreDefaults(nil)
        #expect(search.recorder.displayText == "⌘K" && clear.recorder.displayText == "⇧⌘K")
        #expect(!c.restoreButton.isEnabled && search.reset.alphaValue == 0)

        // A refused reset shakes the row and says why.
        let main = try #require(c.row(Self.showMain))
        s.store.set(KeyCombo(key: "1", mods: [.command, .option]), for: ShortcutStore.numberedId)
        #expect(main.recorder.displayText == "None")
        c.resetRow(main.reset)
        #expect(main.recorder.message == "⌥⌘1 is Session 1")
        let bogus = NSButton()
        bogus.tag = 999
        c.resetRow(bogus)
        // Animated: ↺ fades in and out.
        Motion.assumeVisible = true
        defer { Motion.assumeVisible = false }
        s.store.set(KeyCombo(key: "j", mods: .command), for: Self.search)
        s.store.reset(Self.search)
        #expect(search.recorder.displayText == "⌘K")
        c.surface = .chrome
        #expect(search.recorder.surface == .chrome && c.groups.allSatisfy { $0.surface == .chrome })
        // Leaving the page ends a recording.
        search.recorder.beginRecording()
        c.endRecording()
        #expect(!search.recorder.isRecording)
    }

    @Test func storedShortcutsAreCheckedAgainstTodaysMenu() {
        let s = Setup()
        defer { s.cleanup() }
        let newShell = NSStringFromSelector(#selector(MainWindowController.newShell(_:)))
        // Saved by an older version: a command that is gone, a combo that is reserved now, and ⌘G on
        // New Shell while (say) a new built-in also wants it: here Search's ⌘K.
        s.defaults.set(["gone:": "1048576|g", Self.clear: "1048576|q", newShell: "1048576|k"], forKey: ShortcutStore.defaultsKey)
        let again = Setup(name: s.name)
        #expect(again.store.overrides[ "gone:"] == nil)
        #expect(!again.store.isCustomized(Self.clear) && again.keys(#selector(MainWindowController.clearTerminal(_:))) == "⇧⌘K")
        #expect(again.keys(#selector(MainWindowController.newShell(_:))) == "⌘K")
        #expect(again.keys(#selector(MainWindowController.searchSessions(_:))) == "")
        #expect(again.store.overrides[Self.search] == .cleared)
        let stored = again.defaults.dictionary(forKey: ShortcutStore.defaultsKey) as? [String: String]
        #expect(stored == [newShell: "1048576|k", Self.search: ""])
    }

    @Test func hiddenMenuCommandsKeepTheirShortcutsAndDroppedOnesGiveKeysBack() {
        let s = Setup()
        defer { s.cleanup() }
        let importId = NSStringFromSelector(#selector(AppDelegate.importFromTracker(_:)))
        s.store.set(KeyCombo(key: "j", mods: [.command, .option]), for: importId)
        // Next launch without the tracker: the item is hidden, its shortcut stays, the page doesn't list it.
        let suite = s.name
        let defaults = UserDefaults(suiteName: suite)!
        let app = AppDelegate(makeTerminals: { FakeFactory() }, shortcutDefaults: defaults)
        app.trackerAvailable = { false }
        _ = app.buildMenu()
        #expect(app.shortcuts.combo(for: importId) == KeyCombo(key: "j", mods: [.command, .option]))
        #expect(app.shortcuts.action(importId)?.hidden == true)
        #expect(!ShortcutSettingsView(store: app.shortcuts).rows.contains { $0.id == importId })
        // A command an older version had (now gone) took ⇧⌘K from Clear Screen: Clear Screen gets it back.
        defaults.set(["gone:": "\(KeyCombo(key: "k", mods: [.command, .shift]).modsRaw)|k", Self.clear: ""],
                     forKey: ShortcutStore.defaultsKey)
        let next = AppDelegate(makeTerminals: { FakeFactory() }, shortcutDefaults: defaults)
        next.trackerAvailable = { true }
        _ = next.buildMenu()
        #expect(!next.shortcuts.isCustomized(Self.clear))
        #expect(next.shortcuts.combo(for: Self.clear) == KeyCombo(key: "k", mods: [.command, .shift]))
    }

    @Test func sidebarHintsFollowSessionByNumberAndCloseTooltipKeepsItsName() {
        let s = Setup()
        defer { s.cleanup() }
        let saved = NSApplication.shared.mainMenu
        defer { NSApplication.shared.mainMenu = saved }
        NSApplication.shared.mainMenu = nil
        #expect(SidebarViewController.numberModifiers == .command)  // no main menu: built-in
        #expect(SidebarViewController.closeTooltip() == "Close Session")
        NSApplication.shared.mainMenu = s.menu
        #expect(SidebarViewController.closeTooltip() == "Close Session (⌘W)")
        #expect(SidebarViewController.numberModifiers == .command)
        s.store.set(KeyCombo(key: "1", mods: [.command, .control]), for: ShortcutStore.numberedId)
        #expect(SidebarViewController.numberModifiers == [.command, .control])
        s.store.set(nil, for: ShortcutStore.numberedId)
        #expect(SidebarViewController.numberModifiers == nil)
        s.store.set(KeyCombo(key: "w", mods: [.command, .option]), for: NSStringFromSelector(#selector(MainWindowController.closeSession(_:))))
        #expect(SidebarViewController.closeTooltip() == "Close Session (⌥⌘W)")

        let f = Fixture()
        defer { f.cleanup() }
        let w = MainWindowController(manager: f.manager)
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        w.sidebar.shortcutsChanged()
        let row = w.sidebar.outline.view(atColumn: 0, row: w.sidebar.outline.numberOfRows - 1, makeIfNecessary: true) as? SessionRowView
        #expect(row == nil || row?.closeButton.toolTip == "Close Session (⌥⌘W)")
    }

    @Test func sheetLinksToTheWindowAndMenuHasTheItem() {
        let s = Setup()
        defer { s.cleanup() }
        let v = ShortcutsView(sections: [])
        #expect(v.customizeButton.action == #selector(AppDelegate.customizeShortcuts(_:)))
        #expect(v.customizeButton.target == nil)
        // Customizing lives in Settings › Shortcuts now, not in the menu.
        #expect(s.item(#selector(AppDelegate.customizeShortcuts(_:))) == nil)
    }
}
