import AppKit
@testable import CorralCore
import Testing
@testable import CorralKit

/// Serialized: the tests swap global state (theme tokens, Motion, the main menu, split autosave). One test at a
/// time also keeps a burst of synchronous main-actor work from queueing ahead of other suites' callbacks.
@MainActor
@Suite(.serialized)
struct MainWindowTests {
    /// Runs `body` with animations on and Reduce Motion as given, restoring the global state after.
    func withMotion(reduced: Bool, _ body: () -> Void) {
        let wasEnabled = Motion.enabled, wasReduced = Motion.reduced
        Motion.enabled = true
        Motion.setReduced(reduced)
        defer {
            Motion.enabled = wasEnabled
            Motion.setReduced(wasReduced)
        }
        body()
    }

    /// A main menu carrying the real shortcuts for the actions the toolbar hints at.
    func withMainMenu(_ body: () -> Void) {
        let menu = NSMenu()
        let top = NSMenuItem(title: "Go", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.addItem(NSMenuItem(title: "Search", action: #selector(MainWindowController.searchSessions(_:)), keyEquivalent: "k"))
        sub.addItem(NSMenuItem(title: "Next", action: #selector(MainWindowController.nextAttention(_:)), keyEquivalent: "i"))
        let toggle = NSMenuItem(title: "Sidebar", action: #selector(MainWindowController.toggleSidebarAction(_:)), keyEquivalent: "s")
        toggle.keyEquivalentModifierMask = [.command, .control]
        sub.addItem(toggle)
        let claude = NSMenuItem(title: "Claude", action: #selector(MainWindowController.newClaude(_:)), keyEquivalent: "c")
        claude.keyEquivalentModifierMask = [.command, .control]
        sub.addItem(claude)
        top.submenu = sub
        menu.addItem(top)
        let saved = NSApplication.shared.mainMenu
        NSApplication.shared.mainMenu = menu
        defer { NSApplication.shared.mainMenu = saved }
        body()
    }

    func needsInput(_ f: Fixture, _ id: UUID) {
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "PermissionRequest", message: "Bash: ls")), to: id)
    }

    /// Hiding the focused terminal hands focus over first: to the new terminal, or to the sidebar
    /// list when the switch must not focus (edge chips), never leaving the window without a key view.
    @Test func switchHandsFocusAwayFromHiddenTerminal() {
        let f = Fixture()
        defer { f.cleanup() }
        let w = MainWindowController(manager: f.manager)
        let window = w.window!
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        let a = f.selected!
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        let b = f.selected!
        f.manager.select(a, focus: true)
        #expect(window.makeFirstResponder(f.terminal(a)!.view))
        f.manager.select(b, focus: true)
        #expect(window.firstResponder === f.terminal(b)!.view)
        f.manager.select(a, focus: false)
        #expect(window.firstResponder === w.sidebar.outline)
        #expect(window.makeFirstResponder(f.terminal(a)!.view))
        w.container.sidebarCollapsed = true
        f.manager.select(b, focus: false)
        #expect(window.firstResponder === window)
        w.container.sidebarCollapsed = false
    }

    /// A background refresh reaches the open background page (FSEvents → manager → window → container).
    @Test func backgroundRefreshUpdatesTheOpenPage() {
        let f = Fixture()
        defer { f.cleanup() }
        let w = MainWindowController(manager: f.manager)
        let job = BackgroundAgent(id: "j", sessionId: "s", name: "Job", cwd: "/", state: "working")
        f.manager.applyBackground([job])
        w.sidebarShowBackground(job)
        #expect(w.container.placeholder.chip.stringValue == "Working")
        var done = job
        done.state = "done"
        done.updatedAt = Date()
        f.manager.applyBackground([done])
        #expect(w.container.placeholder.chip.stringValue == "Done")
        #expect(w.container.placeholder.gridRows.last?.0 == "Changed")
    }

    /// ⌘W on a closed session's preview takes it off the Closed list and shows the next closed one; the
    /// open session behind it stays. After the last one, the open session shows again.
    @Test func closeOnClosedPreviewForgetsIt() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let w = MainWindowController(manager: f.manager)
        w.newShell(nil)
        let open = try #require(f.selected)
        for _ in 0..<2 {
            w.newClaude(nil)
            f.manager.close(try #require(f.selected))
        }
        f.manager.select(open)
        let s = w.sidebar
        s.outline.expandItem(s.node(.closedHeader))
        let closed = f.manager.workspace.recentlyClosed(limit: 40).map(\.id)
        #expect(closed.count == 2)
        s.outline.selectRowIndexes([s.outline.row(forItem: s.node(.closed(closed[0])))], byExtendingSelection: false)
        #expect(w.container.placeholder.page == .closed(closed[0]))
        w.closeSession(nil)
        #expect(f.manager.workspace.sessions[closed[0]] == nil && f.manager.live[open] != nil)
        #expect(w.container.placeholder.page == .closed(closed[1]) && !w.container.placeholder.isHidden)
        w.closeSession(nil)
        #expect(f.manager.workspace.sessions[closed[1]] == nil && f.manager.live[open] != nil)
        #expect(w.container.placeholder.isHidden && w.container.shownSession == open)
    }

    @Test func actionsAndTitle() {
        let f = Fixture()
        defer { f.cleanup() }
        let w = MainWindowController(manager: f.manager)
        #expect(f.manager.ui === w)
        w.newShell(nil)
        w.newClaude(nil)
        w.newOpenCode(nil)
        w.newPi(nil)
        #expect(f.manager.live.count == 4)
        #expect(w.window?.title.isEmpty == false)
        w.nextSession(nil)
        w.previousSession(nil)
        let item = NSMenuItem()
        item.tag = 1
        w.selectSessionByNumber(item)
        #expect(f.selected == f.manager.workspace.openSessionsInOrder.first)
        w.findInTerminal(nil)
        #expect(f.terminal(f.selected)?.bindings.last == "start_search")
        w.clearTerminal(nil)
        #expect(f.terminal(f.selected)?.bindings.last == "clear_screen")
        w.nextAttention(nil)
        // Only sessions that ran an agent land in Closed: close the Claude one.
        f.manager.select(f.manager.workspace.openSessionsInOrder.first { f.manager.workspace.sessions[$0]?.agent == .claude })
        w.closeSession(nil)
        #expect(f.manager.live.count == 3)
        w.reopenClosed(nil)
        #expect(f.manager.live.count == 4)
        let closedId = f.manager.workspace.openSessionsInOrder.last!
        f.manager.close(closedId)
        w.sidebarShowClosed(closedId)
        #expect(w.window?.subtitle == "Closed")
        w.sidebarShowBackground(BackgroundAgent(id: "j", sessionId: "s", name: "Job", cwd: "/", state: "working"))
        #expect(w.window?.subtitle == "Background agent")
        w.sidebarFocusTerminal()
        w.focusSidebar(nil)
        w.toggleSidebarAction(nil)
        #expect(w.sidebarItem?.isCollapsed == true)
        w.toggleSidebarAction(nil)
        #expect(w.sidebarItem?.isCollapsed == false)
        w.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        #expect(w.windowShouldClose(w.window!) == false)
        #expect(!w.isWindowKey)
        w.findAction(.startSearch(nil), terminal: f.terminal(f.selected)!)
        f.manager.reloadTerminalConfig()
        while let id = f.manager.workspace.openSessionsInOrder.first { f.manager.close(id) }
        #expect(w.window?.title == "Corral")
        #expect(w.window?.subtitle == "")
    }

    @Test func themedChromeAndSplit() throws {
        let f = Fixture()
        defer { f.cleanup() }
        f.factory.backgroundColor = RGB(hex: 0x1E1E2E).color
        f.factory.foregroundColor = RGB(hex: 0xCDD6F4).color
        let w = MainWindowController(manager: f.manager)
        let window = try #require(w.window)
        let t = Theme.tokens
        #expect(t.chrome == ThemeTokens.make(background: f.factory.backgroundColor, foreground: f.factory.foregroundColor,
                                             windowTheme: nil, systemDark: true, increaseContrast: false,
                                             accent: .controlAccentColor).chrome)
        #expect(window.titlebarAppearsTransparent)
        #expect(window.titlebarSeparatorStyle == .none)
        #expect(window.toolbarStyle == .unifiedCompact)
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.backgroundColor == t.chrome)
        #expect(window.appearance?.name == .darkAqua)
        #expect(window.minSize.width == 720)
        #expect(window.minSize.height >= 420, "AppKit adds the toolbar's height")
        #expect(NSApp.appearance == nil, "never set app-wide")

        let split = try #require(w.split.splitView as? CorralSplitView)
        #expect(split.isVertical)
        #expect(split.dividerThickness == 1)
        #expect(split.dividerColor == .clear)
        split.drawDivider(in: .zero)
        #expect(w.split.view.layer?.backgroundColor == t.chrome.cgColor)
        let side = try #require(w.sidebarItem)
        #expect(side.behavior == .default, "plain item: no sidebar material")
        #expect(side.canCollapse)
        #expect(side.minimumThickness == 220)
        #expect(side.maximumThickness == 420)
        #expect(side.holdingPriority.rawValue == 260)
        #expect(w.split.splitViewItems.count == 2)
        #expect(w.container.sidebarCollapsed == side.isCollapsed)

        let toolbar = try #require(window.toolbar)
        #expect(toolbar.delegate === w.toolbarDelegate)
        #expect(toolbar.items.map(\.itemIdentifier) == [ToolbarDelegate.sidebarToggleID, .flexibleSpace,
                                                         ToolbarDelegate.newID, ToolbarDelegate.attentionID,
                                                         ToolbarDelegate.searchID])
        for item in toolbar.items where item.view != nil { #expect(!item.isBordered) }
        #expect(toolbar.items[0].isNavigational, "fixed before the title")
        window.layoutIfNeeded()
        #expect(w.attentionView.frame.size == AttentionToolbarView.size, "the toolbar never stretches the slot")
    }

    @Test func themeFollowsTerminalConfig() throws {
        let f = Fixture()
        defer { f.cleanup() }
        f.factory.backgroundColor = RGB(hex: 0x1E1E2E).color
        f.factory.foregroundColor = RGB(hex: 0xCDD6F4).color
        let w = MainWindowController(manager: f.manager)
        let window = try #require(w.window)
        let dark = Theme.tokens.chrome

        // Config reload to Solarized Light: chrome, appearance and the split layer follow.
        f.factory.backgroundColor = RGB(hex: 0xFDF6E3).color
        f.factory.foregroundColor = RGB(hex: 0x657B83).color
        f.manager.reloadTerminalConfig()
        #expect(Theme.tokens.chrome != dark)
        #expect(window.backgroundColor == Theme.tokens.chrome)
        #expect(window.appearance?.name == .aqua)
        #expect(w.split.view.layer?.backgroundColor == Theme.tokens.chrome.cgColor)

        // Forced window-theme: the chrome uses the pseudo palette; unchanged reloads re-apply only.
        f.factory.windowTheme = "dark"
        f.manager.reloadTerminalConfig()
        #expect(window.appearance?.name == .darkAqua)
        f.manager.reloadTerminalConfig()
        #expect(window.backgroundColor == Theme.tokens.chrome)

        // Theme changes from elsewhere (accent, accessibility) also re-apply the window chrome.
        window.backgroundColor = .red
        NotificationCenter.default.post(name: .corralThemeDidChange, object: nil)
        #expect(window.backgroundColor == Theme.tokens.chrome)
        NotificationCenter.default.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
        #expect(window.backgroundColor == Theme.tokens.chrome)
    }

    /// Attaching the content controller resizes the window to its tiny fitting size: with autosave
    /// already on, that frame replaced the user's and every later launch opened small.
    @Test func laterLaunchesRestoreTheSavedFrame() throws {
        let keys = ["NSSplitView Subview Frames \(MainWindowController.splitAutosaveName)",
                    "NSWindow Frame \(MainWindowController.frameAutosaveName)"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }
        let f = Fixture()
        defer { f.cleanup() }
        let first = try #require(MainWindowController(manager: f.manager).window)
        first.setFrame(NSRect(x: 40, y: 60, width: 1000, height: 700), display: false)
        first.saveFrame(usingName: MainWindowController.frameAutosaveName)
        let second = try #require(MainWindowController(manager: f.manager).window)
        #expect(second.frame.size == NSSize(width: 1000, height: 700))
    }

    @Test func firstLaunchSidebarWidthAndSystemAppearance() throws {
        // A window frame saved by another test (small) would leave no room for the default width.
        let keys = ["NSSplitView Subview Frames \(MainWindowController.splitAutosaveName)",
                    "NSWindow Frame \(MainWindowController.frameAutosaveName)"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }
        let f = Fixture()
        defer { f.cleanup() }
        f.factory.windowTheme = "system"
        let w = MainWindowController(manager: f.manager)
        let side = try #require(w.sidebarItem)
        #expect(!side.isCollapsed)
        #expect(w.sidebar.view.frame.width == MainWindowController.sidebarWidth.default)
        // "system" follows macOS: no forced window appearance, chrome from the pseudo palette.
        #expect(w.window?.appearance == nil)
        w.systemAppearanceChanged()
        #expect(w.window?.backgroundColor == Theme.tokens.chrome)
    }

    @Test func themeCrossfadeOnlyWhenTokensChange() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let w = MainWindowController(manager: f.manager)
        let layer = try #require(w.window?.contentView?.layer)
        let attention = try #require(w.attentionView.layer)
        // The content and the owned toolbar views (titlebar container, not inside the content view).
        let layers = w.themeFadeLayers
        #expect(layers.count == 5)
        #expect(layers.first === layer)
        #expect(layers.contains { $0 === attention })
        #expect(layers.contains { $0 === w.toolbarDelegate.searchButton.layer })
        #expect(w.crossfadeTheme(animated: true) { false } == false)
        for l in layers { #expect(l.animation(forKey: kCATransition) == nil, "dropped when nothing changed") }
        #expect(w.crossfadeTheme(animated: true) { true })
        let fade = try #require(layer.animation(forKey: kCATransition) as? CATransition)
        #expect(fade.type == .fade)
        #expect(fade.duration == 0.25)
        let toolbarFade = try #require(attention.animation(forKey: kCATransition) as? CATransition)
        #expect(toolbarFade.type == .fade)
        #expect(toolbarFade.duration == 0.25)
        for l in layers { #expect(l.animation(forKey: kCATransition) is CATransition) }
        for l in layers { l.removeAllAnimations() }
        #expect(w.crossfadeTheme(animated: false) { true })
        for l in layers { #expect(l.animation(forKey: kCATransition) == nil) }
    }

    @Test func sidebarToggleIsInstantWithCrossfade() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let w = MainWindowController(manager: f.manager)
        let item = try #require(w.sidebarItem)
        if item.isCollapsed { w.setSidebarCollapsed(false, fade: false) }
        w.window?.makeFirstResponder(w.sidebar.outline)
        w.setSidebarCollapsed(true, fade: true)
        #expect(item.isCollapsed)
        #expect(w.container.sidebarCollapsed)
        let fade = try #require(w.split.view.layer?.animation(forKey: kCATransition) as? CATransition)
        #expect(fade.type == .fade)
        #expect(fade.duration == Motion.fast)
        w.setSidebarCollapsed(true, fade: true) // no-op
        w.split.view.layer?.removeAllAnimations()
        w.focusSidebar(nil)
        #expect(!item.isCollapsed, "focusing the sidebar reveals it")
        #expect(!w.container.sidebarCollapsed)
        #expect(w.split.view.layer?.animation(forKey: kCATransition) == nil)

        // A divider drag (or autosave restore) keeps the card margin in step.
        w.container.sidebarCollapsed = true
        NotificationCenter.default.post(name: NSSplitView.didResizeSubviewsNotification, object: w.split.splitView)
        #expect(!w.container.sidebarCollapsed)
    }

    @Test func collapsedSidebarNeverKeepsTheKeyboard() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let w = MainWindowController(manager: f.manager)
        let window = try #require(w.window)
        let item = try #require(w.sidebarItem)
        func sidebarHasFocus() -> Bool { (window.firstResponder as? NSView)?.isDescendant(of: w.sidebar.view) == true }
        if item.isCollapsed { w.setSidebarCollapsed(false, fade: false) }

        // A closed session's preview: no live terminal to hand the keyboard to.
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        let closed = try #require(f.selected)
        f.manager.close(closed)
        w.sidebarShowClosed(closed)
        #expect(f.selected.flatMap { f.manager.live[$0] } == nil)
        window.makeFirstResponder(w.sidebar.outline)
        #expect(sidebarHasFocus())
        w.setSidebarCollapsed(true, fade: false)
        #expect(!sidebarHasFocus(), "arrows and Return must not switch sessions in a hidden outline")

        // Collapsed by dragging the divider: same hand-over.
        w.setSidebarCollapsed(false, fade: false)
        window.makeFirstResponder(w.sidebar.outline)
        #expect(sidebarHasFocus())
        item.isCollapsed = true
        NotificationCenter.default.post(name: NSSplitView.didResizeSubviewsNotification, object: w.split.splitView)
        #expect(w.container.sidebarCollapsed)
        #expect(!sidebarHasFocus())

        // Revealing the sidebar leaves the keyboard where it is; focusing it moves it there.
        w.setSidebarCollapsed(false, fade: false)
        #expect(!sidebarHasFocus())
        w.focusSidebar(nil)
        #expect(sidebarHasFocus())
    }

    @Test func attentionFollowsNeedsInputCount() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let w = MainWindowController(manager: f.manager)
        let a = w.attentionView
        #expect(a.count == 0)
        #expect(!a.isEnabled)
        #expect(a.capsule.opacity == 0)
        #expect(a.idleGlyph.opacity == 1)
        #expect(a.accessibilityValue() as? String == "None waiting")
        var ids: [UUID] = []
        for _ in 0..<3 {
            f.manager.newSession(agent: .claude, cwd: f.dir.path)
            ids.append(f.selected!)
        }
        f.effects.active = false
        needsInput(f, ids[0])
        needsInput(f, ids[1])
        #expect(a.count == 2)
        #expect(a.isEnabled)
        #expect(a.capsule.opacity == 1)
        #expect(a.idleGlyph.opacity == 0)
        #expect(a.displayedCount == "2")
        #expect(a.countText.string as? String == "2")
        #expect(a.accessibilityValue() as? String == "2 waiting")
        #expect(a.count == f.manager.activityCounts.needsInput)
        #expect(a.count == f.manager.needsInputCount, "same source as the Dock badge")

        // Status events rewrite the native title only when it changes.
        let window = try #require(w.window)
        var titleWrites = 0
        let observation = window.observe(\.title) { _, _ in titleWrites += 1 }
        defer { observation.invalidate() }
        f.manager.select(ids[2])
        let writesAfterSelect = titleWrites
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "UserPromptSubmit")), to: ids[2])
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "Stop")), to: ids[2])
        #expect(titleWrites == writesAfterSelect)
        window.title = "probe"
        #expect(titleWrites == writesAfterSelect + 1, "KVO sees writes")

        // Click = next needing input.
        f.manager.select(ids[2])
        a.performClick(nil)
        #expect(f.selected == ids[0] || f.selected == ids[1])

        // Background agents waiting count too.
        f.manager.applyBackground([BackgroundAgent(id: "j1", sessionId: "s", name: "Job", cwd: "/", state: "blocked", needs: "go")])
        #expect(a.count == f.manager.activityCounts.needsInput)

        f.manager.applyBackground([])
        for id in ids { f.manager.close(id) }
        #expect(a.count == 0)
        #expect(!a.isEnabled)
        #expect(a.capsule.opacity == 0)
        #expect(a.displayedCount == "1", "last count kept while the capsule fades out")
    }

    @Test func attentionCapsuleGeometry() {
        let a = AttentionToolbarView()
        #expect(a.intrinsicContentSize == AttentionToolbarView.size)
        #expect(AttentionToolbarView.label(for: 7) == "7")
        #expect(AttentionToolbarView.label(for: 99) == "99")
        #expect(AttentionToolbarView.label(for: 100) == "99+")
        a.applyCount(-3, animate: false)
        #expect(a.count == 0)
        a.applyCount(3, animate: false)
        let one = a.capsuleWidth
        a.applyCount(42, animate: false)
        let two = a.capsuleWidth
        a.applyCount(250, animate: false)
        #expect(a.countText.string as? String == "99+")
        let three = a.capsuleWidth
        #expect(one < two && two < three)
        #expect(three <= AttentionToolbarView.size.width, "fixed 56 pt slot")
        #expect(one.truncatingRemainder(dividingBy: 2) == 0)
        a.layout()
        #expect(a.capsule.bounds.height == AttentionToolbarView.capsuleHeight)
        #expect(a.capsule.position == CGPoint(x: 28, y: 12))
        #expect(a.capsule.cornerRadius == 11)
        #expect(a.fillGlyph.frame.minX == 7)
        #expect(a.countText.frame.minX > a.fillGlyph.frame.maxX)
        #expect(a.idleGlyph.frame.midX.rounded() == 28)
        for l in [a.capsule, a.fillGlyph, a.countText, a.idleGlyph] {
            #expect(l.actions?["opacity"] is NSNull)
            #expect(l.actions?["bounds"] is NSNull)
        }
        #expect(a.fillGlyph.contents != nil)
        #expect(a.idleGlyph.contents != nil)
    }

    @Test func attentionHoverAndPressTint() {
        let a = AttentionToolbarView()
        a.applyCount(2, animate: false)
        let base = a.capsuleFill
        #expect(base == Theme.tokens.status.needsInput.fill)
        a.setHovered(true)
        a.setHovered(true)
        #expect(a.hovered)
        #expect(a.capsuleFill != base)
        a.updateLayer()
        #expect(a.capsule.backgroundColor == a.capsuleFill.cgColor)
        a.isHighlighted = true
        let pressed = a.capsuleFill
        #expect(pressed != base)
        a.isHighlighted = false
        a.setHovered(false)
        #expect(a.capsuleFill == base)
        let event = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        a.mouseEntered(with: event)
        #expect(a.hovered)
        a.mouseExited(with: event)
        #expect(!a.hovered)
        a.updateTrackingAreas()
        a.updateTrackingAreas()
        #expect(a.trackingAreas.filter { $0.owner === a }.count == 1)
        NotificationCenter.default.post(name: .corralThemeDidChange, object: nil)
        a.viewDidChangeBackingProperties()
        #expect(a.countText.foregroundColor == Theme.tokens.status.needsInput.onFill.cgColor)
    }

    @Test func attentionAnimationsFollowM19() {
        withMotion(reduced: false) {
            let a = AttentionToolbarView()
            // 0 → n: capsule pop + fade in, outline glyph fades out.
            a.applyCount(3, animate: true)
            #expect(a.capsule.animation(forKey: "pop") is CASpringAnimation)
            #expect(a.capsule.animation(forKey: "fade") != nil)
            #expect(a.idleGlyph.animation(forKey: "fade") != nil)
            // n → m: text push from the top when rising; the capsule follows a wider count.
            a.applyCount(12, animate: true)
            let push = a.countText.animation(forKey: kCATransition) as? CATransition
            #expect(push?.type == .push)
            #expect(push?.subtype == .fromTop)
            #expect(a.capsule.animation(forKey: "width") != nil)
            a.applyCount(11, animate: true)
            #expect((a.countText.animation(forKey: kCATransition) as? CATransition)?.subtype == .fromBottom)
            // → 0: capsule fades (0.12), no pop.
            a.applyCount(0, animate: true)
            #expect(a.capsule.animation(forKey: "pop") == nil)
            #expect(a.capsule.animation(forKey: "fade")?.duration == Motion.fast)
            #expect(a.capsule.opacity == 0, "final model value set up front")
            // Snapping drops anything in flight.
            a.applyCount(5, animate: false)
            #expect(a.capsule.animationKeys() == nil)
            #expect(a.countText.animationKeys() == nil)
            // Paused (occluded / app hidden): in-flight one-shots go, updates snap. Never any loop.
            a.applyCount(6, animate: true)
            a.setLoopsPaused(true)
            #expect(a.loopsPaused)
            #expect(a.countText.animationKeys() == nil)
            a.setCount(7)
            #expect(a.count == 7)
            #expect(a.countText.animationKeys() == nil)
            a.setLoopsPaused(false)
            a.setCount(8) // not in a visible window: snaps
            #expect(a.countText.animationKeys() == nil)
            a.setCount(8)
        }
    }

    @Test func attentionSkipsNoOpMotion() {
        withMotion(reduced: false) {
            let a = AttentionToolbarView()
            a.applyCount(120, animate: false)
            // 120 → 130 shows "99+" both times: no push of identical text, no width change.
            a.applyCount(130, animate: true)
            #expect(a.count == 130)
            #expect(a.countText.animation(forKey: kCATransition) == nil)
            #expect(a.capsule.animation(forKey: "width") == nil)

            // Needs-input flap (12 → 0 → 1 while the fade-out runs): the visible capsule fades back to the
            // narrower count, no pop.
            // Presentation values need a committed layer tree: a window that is never ordered in.
            let host = NSWindow(contentRect: NSRect(origin: .zero, size: AttentionToolbarView.size), styleMask: [.borderless],
                                backing: .buffered, defer: false)
            host.contentView = a
            a.applyCount(0, animate: false)
            a.applyCount(12, animate: false)
            CATransaction.flush()
            a.applyCount(0, animate: true)
            CATransaction.flush()
            #expect((a.capsule.presentation()?.opacity ?? 0) > 0.05, "fade-out just started")
            a.applyCount(1, animate: true)
            #expect(a.capsule.animation(forKey: "pop") == nil)
            let fade = a.capsule.animation(forKey: "fade") as? CABasicAnimation
            #expect((fade?.fromValue as? Float ?? 0) > 0.05, "continues from the presented opacity")
            #expect(fade?.toValue as? Float == 1)
            #expect(a.capsule.animation(forKey: "width") is CASpringAnimation)
        }
    }

    @Test func attentionBubbleKnocksOutTheQuestionMark() throws {
        let on = Theme.tokens.status.needsInput.onFill
        let g = try #require(AttentionToolbarView.knockoutGlyph(AttentionToolbarView.fillSymbol, size: 12, weight: .medium,
                                                               color: on, scale: 2))
        #expect(AttentionToolbarView.knockoutGlyph(AttentionToolbarView.fillSymbol, size: 12, weight: .medium,
                                                   color: on, scale: 2)?.image === g.image, "cached")
        let w = g.image.width, h = g.image.height
        #expect(w == Int(ceil(g.size.width * 2)))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try #require(CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(g.image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // The middle of the bubble holds the "?": it must be a hole, so the capsule fill shows through.
        var holes = 0, total = 0
        for y in (h * 3 / 10)..<(h * 7 / 10) {
            for x in (w * 3 / 10)..<(w * 7 / 10) {
                total += 1
                if px[(y * w + x) * 4 + 3] < 51 { holes += 1 }
            }
        }
        #expect(Double(holes) / Double(total) > 0.1, "\(holes) of \(total) transparent")
        // Opaque pixels carry the onAmber tint.
        let target = RGB(on)
        let opaque = stride(from: 0, to: px.count, by: 4).first { px[$0 + 3] == 255 }
        let i = try #require(opaque)
        #expect(abs(Double(px[i]) / 255 - target.r) < 0.02)
        #expect(abs(Double(px[i + 1]) / 255 - target.g) < 0.02)
        #expect(abs(Double(px[i + 2]) / 255 - target.b) < 0.02)
        #expect(AttentionToolbarView.knockoutGlyph("no.such.symbol.corral", size: 12, weight: .medium, color: on, scale: 2) == nil)

        let a = AttentionToolbarView()
        #expect(a.fillGlyph.contents != nil)
        #expect((a.fillGlyph.contents as! CGImage).width == w)
    }

    @Test func attentionReduceMotionFadesOnly() {
        withMotion(reduced: true) {
            let a = AttentionToolbarView()
            a.applyCount(1, animate: true)
            #expect(a.capsule.animation(forKey: "pop") == nil)
            #expect(a.capsule.animation(forKey: "fade") != nil)
            a.applyCount(10, animate: true)
            #expect((a.countText.animation(forKey: kCATransition) as? CATransition)?.type == .fade)
            #expect(a.capsule.animation(forKey: "width") == nil)
        }
    }

    @Test func occlusionPausesLoops() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let w = MainWindowController(manager: f.manager)
        let window = try #require(w.window)
        #expect(w.loopsPaused == nil)
        // Not on screen: occluded, so loops pause in the sidebar and the toolbar.
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(w.loopsPaused == true)
        #expect(w.attentionView.loopsPaused)
        NotificationCenter.default.post(name: NSApplication.didHideNotification, object: NSApp)
        #expect(w.loopsPaused == true)
        w.setLoopsPaused(false)
        #expect(w.loopsPaused == false)
        #expect(!w.attentionView.loopsPaused)
        NotificationCenter.default.post(name: NSApplication.didUnhideNotification, object: NSApp)
        #expect(w.loopsPaused == true, "still occluded")
    }

    @Test func fullScreenEdgeToEdge() {
        let f = Fixture()
        defer { f.cleanup() }
        let w = MainWindowController(manager: f.manager)
        let n = Notification(name: NSWindow.willEnterFullScreenNotification)
        w.windowWillEnterFullScreen(n)
        w.windowDidExitFullScreen(n)
        w.windowWillEnterFullScreen(n)
        w.windowDidFailToEnterFullScreen(w.window!)
        #expect(w.window?.styleMask.contains(.fullScreen) == false)
    }

    @Test func toolbarItems() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let w = MainWindowController(manager: f.manager)
        w.setSidebarCollapsed(false, fade: false)
        let d = ToolbarDelegate(owner: w)
        let tb = NSToolbar(identifier: "t")
        let ids = d.toolbarDefaultItemIdentifiers(tb)
        #expect(ids == [ToolbarDelegate.sidebarToggleID, .flexibleSpace, ToolbarDelegate.newID,
                        ToolbarDelegate.attentionID, ToolbarDelegate.searchID])
        #expect(d.toolbarAllowedItemIdentifiers(tb) == ids)
        var items: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
        for id in ids + [ToolbarDelegate.trackingID] {
            items[id] = d.toolbar(tb, itemForItemIdentifier: id, willBeInsertedIntoToolbar: true)
        }
        #expect(items[ToolbarDelegate.sidebarToggleID]?.view === d.sidebarButton)
        #expect(items[ToolbarDelegate.newID]?.view === d.newButton)
        #expect(items[ToolbarDelegate.searchID]?.view === d.searchButton)
        #expect(items[ToolbarDelegate.attentionID]?.view === d.attention)
        #expect(items[ToolbarDelegate.trackingID] is NSTrackingSeparatorToolbarItem)
        for b in [d.sidebarButton, d.newButton, d.searchButton] {
            #expect(b.frame.size == NSSize(width: 28, height: 24))
            #expect(!b.isBordered)
        }
        #expect(d.sidebarButton.symbol == "sidebar.left")
        #expect(d.searchButton.symbol == "magnifyingglass")
        #expect(d.newButton.symbol == "plus")
        let newMask = d.newButton.sendAction(on: [.leftMouseDown]) // returns the mask in effect
        #expect(newMask == Int(NSEvent.EventTypeMask.leftMouseDown.rawValue), "+ opens on mouse-down like a pull-down")
        #expect(items[ToolbarDelegate.searchID]?.menuFormRepresentation?.action == #selector(MainWindowController.searchSessions(_:)))
        #expect(items[ToolbarDelegate.newID]?.menuFormRepresentation?.submenu?.items.count == d.newMenu.items.count)

        // Buttons reach the window controller directly.
        d.sidebarButton.performClick(nil)
        #expect(w.sidebarItem?.isCollapsed == true)
        d.sidebarButton.performClick(nil)
        #expect(w.sidebarItem?.isCollapsed == false)
        #expect(d.attention.target === w)
        #expect(d.searchButton.target === w)

        // The + menu: same entries as before, routed to the controller.
        #expect(d.newMenu.items.filter { !$0.isSeparatorItem }.map(\.title) == [
            "New Shell", "New Claude Session", "New OpenCode Session", "New PI Session",
            "New Session in Directory…", "New Folder",
        ])
        let before = f.manager.live.count
        let claude = try #require(d.newMenu.items.first { $0.action == #selector(MainWindowController.newClaude(_:)) })
        #expect(claude.target === w)
        d.newMenu.performActionForItem(at: d.newMenu.index(of: claude))
        #expect(f.manager.live.count == before + 1)

        // Without an owner there is no split view to track.
        let bare = ToolbarDelegate()
        #expect(!(bare.toolbar(tb, itemForItemIdentifier: ToolbarDelegate.trackingID, willBeInsertedIntoToolbar: true) is NSTrackingSeparatorToolbarItem))
        #expect(bare.toolbar(tb, itemForItemIdentifier: .init("unknown"), willBeInsertedIntoToolbar: true) != nil)
    }

    @Test func toolbarHintsReadTheMenu() {
        let d = ToolbarDelegate()
        withMainMenu {
            d.refreshHints()
            #expect(d.searchButton.toolTip == "Search all sessions (⌘K)")
            #expect(d.attention.toolTip == "Next needing input (⌘I)")
            #expect(d.sidebarButton.toolTip == "Toggle sidebar (⌃⌘S)")
            let claude = d.newMenu.items.first { $0.action == #selector(MainWindowController.newClaude(_:)) }
            #expect(claude?.keyEquivalent == "c")
            #expect(claude?.keyEquivalentModifierMask == [.command, .control])
            #expect(ToolbarDelegate.menuItem(for: #selector(MainWindowController.nextAttention(_:)), in: NSApp.mainMenu)?.keyEquivalent == "i")
        }
        // No menu (tests, early launch): plain labels, no shortcuts.
        let saved = NSApplication.shared.mainMenu
        NSApplication.shared.mainMenu = nil
        defer { NSApplication.shared.mainMenu = saved }
        d.refreshHints()
        #expect(d.searchButton.toolTip == "Search all sessions")
        #expect(d.newMenu.items.allSatisfy { $0.keyEquivalent.isEmpty })
        #expect(ToolbarDelegate.menuItem(for: #selector(MainWindowController.newShell(_:)), in: nil) == nil)
    }

    /// Opt-in visual check (CORRAL_SNAPSHOTS=<dir>): toolbar controls in every attention state, dark and light.
    @Test(.enabled(if: SnapshotTests.dir != nil)) func toolbarGallery() throws {
        let out = URL(fileURLWithPath: SnapshotTests.dir!)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        Motion.enabled = false
        defer { Motion.enabled = true }
        let palettes: [(String, UInt32, UInt32)] = [("dark", 0x1E1E2E, 0xCDD6F4), ("light", 0xFDF6E3, 0x657B83)]
        for (name, bg, fg) in palettes {
            Theme.update(background: RGB(hex: bg).color, foreground: RGB(hex: fg).color, windowTheme: nil)
            let t = Theme.tokens
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 48), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.appearance = t.chromeAppearance
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 48))
            root.wantsLayer = true
            root.layer?.backgroundColor = t.chrome.cgColor
            window.contentView = root
            let d = ToolbarDelegate()
            let counts = [0, 3, 12, 120]
            let attention = counts.map { n -> AttentionToolbarView in
                let a = AttentionToolbarView()
                a.applyCount(n, animate: false)
                return a
            }
            attention[2].setHovered(true)
            d.searchButton.setHovered(true)
            let stack = NSStackView(views: [d.sidebarButton, d.newButton] + attention + [d.searchButton])
            stack.spacing = 6
            stack.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
                stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            ])
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            SnapshotTests.render(root, to: out.appendingPathComponent("toolbar-\(name).png"))
        }
    }
}
