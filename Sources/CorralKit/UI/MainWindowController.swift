import AppKit
import CorralCore

/// Split view whose divider is a 1 pt gap: the chrome drawn by the split view's layer shows through.
final class CorralSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 1 }
    override var dividerColor: NSColor { .clear }
    override func drawDivider(in rect: NSRect) {}
}

/// Main window: sidebar (sessions) + terminal card on one themed chrome surface (§3.1).
/// Menu and toolbar actions land here.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSPopoverDelegate, SessionUI, SidebarDelegate {
    let manager: SessionManager
    let split = NSSplitViewController()
    let sidebar: SidebarViewController
    let container: TerminalContainerViewController
    lazy var searchPanel = SearchPanelController(manager: manager)
    private(set) lazy var toolbarDelegate = ToolbarDelegate(owner: self)
    var attentionView: AttentionToolbarView { toolbarDelegate.attention }
    var sidebarItem: NSSplitViewItem? { split.splitViewItems.first }
    /// nil until the first occlusion/hide notification, so that one always reaches the sidebar.
    private(set) var loopsPaused: Bool?
    private var appearanceObservation: NSKeyValueObservation?

    static let sidebarWidth = (min: CGFloat(220), default: CGFloat(260), max: CGFloat(420))
    static let splitAutosaveName = "CorralSplit"
    static let frameAutosaveName = "CorralMain"

    init(manager: SessionManager) {
        self.manager = manager
        sidebar = SidebarViewController(manager: manager)
        container = TerminalContainerViewController(manager: manager)
        Theme.update(background: manager.terminals.backgroundColor, foreground: manager.terminals.foregroundColor,
                     windowTheme: manager.terminals.windowTheme)
        let t = Theme.tokens
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Corral"
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unifiedCompact // not .unified: keeps terminal rows
        window.backgroundColor = t.chrome
        window.appearance = t.chromeAppearance // per window; never NSApp (GhosttyRuntime reads it)
        // Read now, autosave only at the end: with autosave on, assigning the content controller below
        // saves its tiny fitting frame over the user's.
        let savedFrame = UserDefaults.standard.string(forKey: "NSWindow Frame \(Self.frameAutosaveName)")
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self

        // Custom split view before the controller's view loads.
        let splitView = CorralSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        split.splitView = splitView
        let sideItem = NSSplitViewItem(viewController: sidebar) // not sidebarWithViewController: no glass
        sideItem.canCollapse = true
        sideItem.minimumThickness = Self.sidebarWidth.min
        sideItem.maximumThickness = Self.sidebarWidth.max
        sideItem.holdingPriority = NSLayoutConstraint.Priority(260)
        sideItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        sideItem.titlebarSeparatorStyle = .none
        let mainItem = NSSplitViewItem(viewController: container)
        mainItem.titlebarSeparatorStyle = .none
        split.addSplitViewItem(sideItem)
        split.addSplitViewItem(mainItem)
        let hasSavedSplit = UserDefaults.standard.object(forKey: "NSSplitView Subview Frames \(Self.splitAutosaveName)") != nil
        splitView.autosaveName = Self.splitAutosaveName
        window.contentViewController = split
        window.minSize = NSSize(width: 720, height: 420) // after the content controller, which resets it
        split.view.wantsLayer = true // drawn chrome, so snapshots see it
        splitView.wantsLayer = true
        // contentViewController resizes the window to the content's fitting size (tiny): first launch
        // gets the default size; later launches restore the saved frame.
        if let savedFrame {
            window.setFrame(from: savedFrame)
        } else {
            window.setContentSize(NSSize(width: 1280, height: 820))
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)
        if !hasSavedSplit {
            split.view.layoutSubtreeIfNeeded()
            splitView.setPosition(Self.sidebarWidth.default, ofDividerAt: 0)
        }
        container.sidebarCollapsed = sideItem.isCollapsed
        container.focusFallback = { [weak self] in
            guard let self, !self.container.sidebarCollapsed else { return nil }
            return self.sidebar.outline
        }

        let toolbar = NSToolbar(identifier: "main")
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.delegate = toolbarDelegate
        window.toolbar = toolbar
        toolbarDelegate.refreshHints()
        NotificationCenter.default.addObserver(self, selector: #selector(shortcutsChanged),
                                               name: .corralShortcutsChanged, object: nil)

        sidebar.delegate = self
        manager.ui = self
        manager.observe { [weak self] change in
            guard let self else { return }
            switch change {
            case .selection:
                self.container.showSelected(focus: self.manager.selectionWantsFocus)
                self.updateTitle()
            case .structure:
                self.container.showSelected(focus: self.manager.isTerminal(self.window?.firstResponder))
                self.updateTitle()
                self.refreshAttention()
            case .status(let id):
                if id == self.manager.workspace.selected {
                    self.updateTitle()
                    self.container.sessionStatusChanged(id)
                }
                self.refreshAttention()
            case .background:
                self.container.refreshBackground(self.manager.background)
                self.refreshAttention()
            case .appearance:
                self.terminalAppearanceChanged()
            case .integrations, .settings, .reveal:
                break
            case .panes(let id):
                self.container.panesChanged(id)
            }
        }
        applyChrome()
        attentionView.setCount(manager.needsInputCount, animated: false)
        observeSystem()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Native title and subtitle; written only when they change (status events are frequent and each
    /// write can relayout the titlebar).
    private func updateTitle() {
        guard let window else { return }
        let title: String, subtitle: String
        if let sel = manager.workspace.selected, let r = manager.workspace.sessions[sel] {
            let s = manager.status(sel) ?? LiveStatus()
            title = sidebar.displayTitle(r, s)
            subtitle = RelativeTime.abbreviatePath(s.cwd ?? r.cwd)
        } else {
            title = "Corral"
            subtitle = ""
        }
        if window.title != title { window.title = title }
        if window.subtitle != subtitle { window.subtitle = subtitle }
    }

    /// Toolbar attention count: the same number that feeds the Dock badge.
    func refreshAttention() {
        attentionView.setCount(manager.needsInputCount)
    }

    // MARK: Theme

    private func observeSystem() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(themeDidChange), name: .corralThemeDidChange, object: nil)
        nc.addObserver(self, selector: #selector(systemColorsChanged), name: NSColor.systemColorsDidChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(occlusionChanged), name: NSWindow.didChangeOcclusionStateNotification, object: window)
        nc.addObserver(self, selector: #selector(occlusionChanged), name: NSApplication.didHideNotification, object: nil)
        nc.addObserver(self, selector: #selector(occlusionChanged), name: NSApplication.didUnhideNotification, object: nil)
        nc.addObserver(self, selector: #selector(splitResized), name: NSSplitView.didResizeSubviewsNotification, object: split.splitView)
        // "system" window-theme follows macOS light/dark.
        appearanceObservation = NSApp?.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.systemAppearanceChanged() }
        }
    }

    /// Window chrome from the current tokens: background, per-window appearance, split layer, card.
    func applyChrome() {
        guard let window else { return }
        let t = Theme.tokens
        window.backgroundColor = t.chrome
        if window.appearance?.name != t.chromeAppearance?.name { window.appearance = t.chromeAppearance }
        Motion.quiet {
            split.view.layer?.backgroundColor = t.chrome.cgColor
            if split.splitView !== split.view { split.splitView.layer?.backgroundColor = t.chrome.cgColor }
        }
        container.applyBackground()
    }

    /// Ghostty config reload / CONFIG_CHANGE: new terminal colors or window-theme.
    func terminalAppearanceChanged() {
        let terminals = manager.terminals
        let changed = crossfadeTheme(animated: themeAnimates) {
            Theme.update(background: terminals.backgroundColor, foreground: terminals.foregroundColor,
                         windowTheme: terminals.windowTheme)
        }
        // A change already re-applied the chrome via .corralThemeDidChange.
        if !changed { applyChrome() }
    }

    private var themeAnimates: Bool {
        guard let content = window?.contentView else { return false }
        return Motion.shouldAnimate(content)
    }

    /// Layers the M31 fade covers: the window content and the owned toolbar views, which live in the
    /// titlebar container (a sibling of the content view). The native title and traffic lights snap.
    var themeFadeLayers: [CALayer] {
        let d = toolbarDelegate
        let views: [NSView?] = [window?.contentView, d.sidebarButton, d.newButton, d.attention, d.searchButton]
        return views.compactMap { $0?.layer }
    }

    /// M31: one-shot fade, added before the new tokens are applied; dropped when nothing changed.
    /// Returns whether the tokens changed.
    @discardableResult
    func crossfadeTheme(animated: Bool, _ change: () -> Bool) -> Bool {
        let layers = animated ? themeFadeLayers : []
        for layer in layers {
            let t = CATransition()
            t.type = .fade
            t.duration = 0.25
            t.timingFunction = Motion.std
            layer.add(t, forKey: kCATransition)
        }
        let changed = change()
        // Transitions are stored under kCATransition whatever key they were added with.
        if !changed { for layer in layers { layer.removeAnimation(forKey: kCATransition) } }
        return changed
    }

    @objc private func themeDidChange(_ n: Notification) { MainActor.assumeIsolated { applyChrome() } }

    @objc private func systemColorsChanged(_ n: Notification) {
        MainActor.assumeIsolated { _ = crossfadeTheme(animated: themeAnimates) { Theme.recompute() } }
    }

    /// KVO on `NSApp.effectiveAppearance`: only the "system" window-theme depends on it.
    func systemAppearanceChanged() {
        crossfadeTheme(animated: themeAnimates) { Theme.recompute() }
    }

    // MARK: Occlusion

    @objc private func occlusionChanged(_ n: Notification) {
        MainActor.assumeIsolated {
            let hidden = n.name == NSApplication.didHideNotification || (NSApp?.isHidden ?? false)
            setLoopsPaused(hidden || window?.occlusionState.contains(.visible) != true)
        }
    }

    /// Removes (paused) or re-adds the status loops in the sidebar; the toolbar only drops one-shots.
    func setLoopsPaused(_ paused: Bool) {
        guard loopsPaused != paused else { return }
        loopsPaused = paused
        sidebar.setLoopsPaused(paused)
        attentionView.setLoopsPaused(paused)
    }

    // MARK: Sidebar

    @objc private func splitResized(_ n: Notification) {
        // Keeps the card margin in step when the divider is dragged closed or restored from autosave.
        MainActor.assumeIsolated {
            guard let item = sidebarItem, container.sidebarCollapsed != item.isCollapsed else { return }
            container.sidebarCollapsed = item.isCollapsed
            if item.isCollapsed { moveFocusOutOfSidebar() }
        }
    }

    /// A collapsed sidebar must not keep the keyboard: arrows and Return would switch sessions unseen.
    /// The terminal takes it; without one (closed or background preview, empty state) the content does,
    /// which leaves the window itself as first responder.
    private func moveFocusOutOfSidebar() {
        guard let window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: sidebar.view)
        else { return }
        container.focusTerminal()
        if let r = window.firstResponder as? NSView, r.isDescendant(of: sidebar.view) {
            window.makeFirstResponder(container.view)
        }
    }

    /// M21: instant collapse (exactly one terminal resize) under a 0.12 s crossfade of the split view.
    func setSidebarCollapsed(_ collapsed: Bool, fade: Bool) {
        guard let item = sidebarItem, item.isCollapsed != collapsed else { return }
        if collapsed { moveFocusOutOfSidebar() }
        CATransaction.begin()
        if fade, let layer = split.view.layer {
            let t = CATransition()
            t.type = .fade
            t.duration = Motion.fast
            t.timingFunction = Motion.std
            layer.add(t, forKey: kCATransition)
        }
        item.isCollapsed = collapsed // no animator(): no per-frame SIGWINCH
        container.sidebarCollapsed = collapsed
        split.view.layoutSubtreeIfNeeded()
        CATransaction.commit()
    }

    // MARK: SessionUI

    func confirm(title: String, message: String, button: String, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        Presenter.alert(alert, window) { completion($0 == .alertFirstButtonReturn) }
    }

    func showSessionSearch() { searchPanel.present(over: window) }
    func toggleFullscreen() { window?.toggleFullScreen(nil) }
    var isWindowKey: Bool { window?.isKeyWindow ?? false }

    func cardBoxes(_ owner: UUID) -> [UUID: PaneBox]? { container.cardBoxes(owner) }
    func findAction(_ action: TerminalAction, terminal: TerminalSurface) { container.findAction(action, terminal: terminal) }

    func focus(terminal: TerminalSurface?) {
        if let terminal { window?.makeFirstResponder(terminal.view) }
    }

    // MARK: SidebarDelegate

    func sidebarShowClosed(_ id: UUID) {
        guard let r = manager.workspace.sessions[id] else { return }
        container.showClosed(r)
        window?.title = r.displayTitle
        window?.subtitle = "Closed"
    }

    func sidebarShowBackground(_ agent: BackgroundAgent) {
        container.showBackground(agent)
        window?.title = agent.name
        window?.subtitle = "Background agent"
    }

    func sidebarFocusTerminal() { container.focusTerminal() }

    // MARK: Window

    func windowDidBecomeKey(_ notification: Notification) {
        // Everything on the shown card is seen again (and leaves Notification Center).
        manager.markSelectedViewed()
        toolbarDelegate.refreshHints() // the main menu is built after the window
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closing the window hides it; sessions keep running. Quit with Cmd+Q.
        sender.orderOut(nil)
        return false
    }

    /// Full screen: the card goes edge to edge (margins, radius, border, shadow 0), instantly.
    func windowWillEnterFullScreen(_ notification: Notification) { container.setFullScreen(true) }
    func windowDidExitFullScreen(_ notification: Notification) { container.setFullScreen(false) }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { container.setFullScreen(false) }

    // MARK: Actions (menu, toolbar, sidebar bar)

    private var targetFolder: UUID?? {
        sidebar.selectedFolder.map { .some($0) }
    }

    @objc func newShell(_ sender: Any?) { manager.newSession(agent: .shell, folder: targetFolder) }
    @objc func newClaude(_ sender: Any?) { manager.newSession(agent: .claude, folder: targetFolder) }
    @objc func newOpenCode(_ sender: Any?) { manager.newSession(agent: .opencode, folder: targetFolder) }
    @objc func newPi(_ sender: Any?) { manager.newSession(agent: .pi, folder: targetFolder) }

    @objc func newInDirectory(_ sender: Any?) {
        let agentPicker = NSPopUpButton()
        for a in AgentKind.allCases { agentPicker.addItem(withTitle: a.displayName) }
        Presenter.chooseDirectory(start: manager.currentDirectory ?? NSHomeDirectory(), prompt: "Open Here",
                                  accessory: agentPicker, window: window) { [weak self] url in
            guard let url, let self else { return }
            let agent = AgentKind.allCases[max(0, agentPicker.indexOfSelectedItem)]
            self.manager.newSession(agent: agent, cwd: url.path, folder: self.targetFolder)
        }
    }

    @objc func newFolder(_ sender: Any?) {
        let id = manager.newFolder(in: sidebar.selectedFolder)
        sidebar.promptRename(id)
    }

    /// ⌘W closes the focused split pane, else the session.
    @objc func closeSession(_ sender: Any?) {
        if let responder = window?.firstResponder as? NSView, let pane = manager.pane(containing: responder) {
            manager.requestClosePane(pane.id)
            return
        }
        if let sel = manager.workspace.selected { manager.requestClose(sel) }
    }

    // MARK: Split panes

    @objc func splitRight(_ sender: Any?) { splitSelected(.right) }
    @objc func splitDown(_ sender: Any?) { splitSelected(.down) }
    @objc func nextPane(_ sender: Any?) { if let sel = manager.workspace.selected { manager.focusPane(in: sel, offset: 1) } }
    @objc func previousPane(_ sender: Any?) { if let sel = manager.workspace.selected { manager.focusPane(in: sel, offset: -1) } }

    @objc func focusUp(_ sender: Any?) { moveFocus(.toward(.up)) }
    @objc func focusDown(_ sender: Any?) { moveFocus(.toward(.down)) }
    @objc func focusLeft(_ sender: Any?) { moveFocus(.toward(.left)) }
    @objc func focusRight(_ sender: Any?) { moveFocus(.toward(.right)) }

    /// ⌥⌘ arrows from wherever the keyboard is: a pane, a session's terminal, or the sidebar (which
    /// then keeps the keyboard while the selection moves).
    private func moveFocus(_ target: SplitFocus) {
        guard let sel = manager.workspace.selected else { return }
        let responder = window?.firstResponder as? NSView
        let from = responder.flatMap { manager.pane(containing: $0)?.id }
        let inSidebar = responder.map { $0.isDescendant(of: sidebar.view) } ?? false
        manager.moveFocus(target, in: sel, from: from, focusTerminal: !inSidebar)
    }

    private func splitSelected(_ direction: SplitDirection) {
        // Only the terminal on screen splits (not behind a Closed / background preview).
        guard let sel = manager.workspace.selected, manager.live[sel] != nil, container.shownSession == sel else { return }
        let from = (window?.firstResponder as? NSView).flatMap { manager.pane(containing: $0)?.id }
        manager.split(sel, from: from, direction: direction)
    }

    @objc func reopenClosed(_ sender: Any?) { manager.reopenLastClosed() }

    @objc func renameSession(_ sender: Any?) {
        if let sel = manager.workspace.selected { sidebar.promptRename(sel) }
    }

    @objc func searchSessions(_ sender: Any?) { showSessionSearch() }

    /// The keyboard-shortcuts sheet (⌘/ or the keyboard icon in the sidebar); toggles.
    @objc func showShortcuts(_ sender: Any?) {
        if let p = shortcutsPopover, p.isShown {
            p.performClose(nil)
            return
        }
        // A transient popover closes on mouse-down outside it, before the button's click lands: a
        // click on the button right after that close is the toggle, not a reopen.
        if ProcessInfo.processInfo.systemUptime - shortcutsClosedAt < 0.3 { return }
        let p = ShortcutsView.popover(menu: NSApp.mainMenu)
        p.delegate = self
        shortcutsPopover = p
        // Popover edges follow the anchor view's flipping: "above" is minY in a flipped view.
        let button = sidebar.bottomBar.shortcutsButton
        if !container.sidebarCollapsed, button.window != nil {
            Presenter.popover(p, button.bounds, button, button.isFlipped ? .minY : .maxY)
        } else if let content = window?.contentView {
            let y = content.isFlipped ? content.bounds.maxY - 24 : 24
            Presenter.popover(p, NSRect(x: 24, y: y, width: 1, height: 1), content, content.isFlipped ? .minY : .maxY)
        }
    }

    /// Customized shortcuts: every hint that reads the menu reads it again.
    @objc func shortcutsChanged() {
        MainActor.assumeIsolated {
            toolbarDelegate.refreshHints()
            container.placeholder.refreshHints()
            sidebar.shortcutsChanged()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === shortcutsPopover else { return }
        shortcutsClosedAt = ProcessInfo.processInfo.systemUptime
        shortcutsPopover = nil
    }

    private(set) var shortcutsPopover: NSPopover?
    private var shortcutsClosedAt: TimeInterval = 0
    @objc func nextAttention(_ sender: Any?) { manager.selectNextAttention() }
    @objc func nextSession(_ sender: Any?) { manager.selectRelative(1) }
    @objc func previousSession(_ sender: Any?) { manager.selectRelative(-1) }

    /// Cmd+1…8 pick a visible session; Cmd+9 is the last one (browser/Ghostty convention).
    @objc func selectSessionByNumber(_ sender: NSMenuItem) {
        manager.selectIndex(sender.tag >= 9 ? Int.max : sender.tag - 1)
    }

    @objc func focusSidebar(_ sender: Any?) {
        if sidebarItem?.isCollapsed == true { setSidebarCollapsed(false, fade: false) }
        sidebar.focus()
    }

    @objc func toggleSidebarAction(_ sender: Any?) {
        guard let item = sidebarItem else { return }
        setSidebarCollapsed(!item.isCollapsed, fade: Motion.full && Motion.shouldAnimate(split.view))
    }

    /// Ghostty's Cmd+K moves here: Cmd+K is session search in Corral.
    @objc func clearTerminal(_ sender: Any?) {
        if let sel = manager.workspace.selected { manager.focusedTerminal(sel)?.perform(binding: "clear_screen") }
    }

    @objc func findInTerminal(_ sender: Any?) {
        if let sel = manager.workspace.selected { manager.focusedTerminal(sel)?.perform(binding: "start_search") }
    }
}

/// Toolbar: sidebar toggle (navigational, so it sits before the native title), flexible space, then
/// new-session menu, attention and search. Every item is a borderless custom view (GhostButton /
/// AttentionToolbarView), so macOS 26 draws no glass capsules on the themed titlebar.
/// No sidebar tracking separator by default: without a sidebar-behavior split item (glass on 26) AppKit
/// lays the title out in front of it, so it cannot track the divider and would move the + with every
/// title change. `trackingID` still builds one if it is ever added back.
final class ToolbarDelegate: NSObject, NSToolbarDelegate {
    static let sidebarToggleID = NSToolbarItem.Identifier("sidebarToggle")
    static let trackingID = NSToolbarItem.Identifier("sidebarTracking")
    static let newID = NSToolbarItem.Identifier("new")
    static let attentionID = NSToolbarItem.Identifier("attention")
    static let searchID = NSToolbarItem.Identifier("search")
    static let buttonFrame = NSRect(x: 0, y: 0, width: 28, height: 24)

    weak var owner: MainWindowController?
    let sidebarButton: GhostButton
    let newButton: GhostButton
    let searchButton: GhostButton
    let attention: AttentionToolbarView
    let newMenu = NSMenu(title: "New")

    init(owner: MainWindowController? = nil) {
        self.owner = owner
        sidebarButton = GhostButton(symbol: "sidebar.left", size: 13, frame: Self.buttonFrame, target: owner,
                                    action: #selector(MainWindowController.toggleSidebarAction(_:)))
        newButton = GhostButton(symbol: "plus", size: 13, frame: Self.buttonFrame)
        searchButton = GhostButton(symbol: "magnifyingglass", size: 13, frame: Self.buttonFrame, target: owner,
                                   action: #selector(MainWindowController.searchSessions(_:)))
        attention = AttentionToolbarView(target: owner, action: #selector(MainWindowController.nextAttention(_:)))
        super.init()
        newButton.target = self
        newButton.action = #selector(showNewMenu(_:))
        // Pull-down feel: the menu opens on mouse-down. The button stays pressed while it is open; the cell's
        // tracking ends with the menu, which consumes the mouse-up.
        newButton.sendAction(on: [.leftMouseDown])
        for b in [sidebarButton, newButton, searchButton] { b.refusesFirstResponder = true }
        sidebarButton.setAccessibilityLabel("Toggle Sidebar")
        newButton.setAccessibilityLabel("New Session")
        searchButton.setAccessibilityLabel("Search All Sessions")
        let entries: [(String, Selector)?] = [
            ("New Shell", #selector(MainWindowController.newShell(_:))),
            ("New Claude Session", #selector(MainWindowController.newClaude(_:))),
            ("New OpenCode Session", #selector(MainWindowController.newOpenCode(_:))),
            ("New PI Session", #selector(MainWindowController.newPi(_:))),
            nil,
            ("New Session in Directory…", #selector(MainWindowController.newInDirectory(_:))),
            ("New Folder", #selector(MainWindowController.newFolder(_:))),
        ]
        for e in entries {
            guard let (title, action) = e else {
                newMenu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = owner
            newMenu.addItem(item)
        }
        refreshHints()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebarToggleID, .flexibleSpace, Self.newID, Self.attentionID, Self.searchID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case Self.sidebarToggleID:
            let item = makeItem(id, sidebarButton, label: "Sidebar", action: #selector(MainWindowController.toggleSidebarAction(_:)))
            item.isNavigational = true
            return item
        case Self.trackingID:
            guard let split = owner?.split.splitView else { return NSToolbarItem(itemIdentifier: id) }
            return NSTrackingSeparatorToolbarItem(identifier: id, splitView: split, dividerIndex: 0)
        case Self.newID:
            let item = makeItem(id, newButton, label: "New", action: nil)
            let form = NSMenuItem(title: "New", action: nil, keyEquivalent: "")
            form.submenu = newMenu.copy() as? NSMenu
            item.menuFormRepresentation = form
            return item
        case Self.attentionID:
            let item = makeItem(id, attention, label: "Next Needing Input", action: #selector(MainWindowController.nextAttention(_:)))
            item.visibilityPriority = .high
            return item
        case Self.searchID:
            let item = makeItem(id, searchButton, label: "Search", action: #selector(MainWindowController.searchSessions(_:)))
            item.visibilityPriority = .high
            return item
        default:
            return NSToolbarItem(itemIdentifier: id)
        }
    }

    private func makeItem(_ id: NSToolbarItem.Identifier, _ view: NSView, label: String, action: Selector?) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.view = view
        item.label = label
        item.paletteLabel = label
        item.isBordered = false
        if let action {
            let form = NSMenuItem(title: label, action: action, keyEquivalent: "")
            form.target = owner
            item.menuFormRepresentation = form
        }
        return item
    }

    /// The + button opens the new-session menu right below itself.
    @objc func showNewMenu(_ sender: NSView) {
        refreshHints()
        let y = sender.isFlipped ? sender.bounds.maxY + 4 : -4
        newMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: sender)
    }

    /// Tooltips and menu shortcuts come from the real main menu (never hardcoded); nil without one.
    func refreshHints() {
        func hint(_ text: String, _ action: Selector) -> String {
            KeyHint.string(for: action).map { "\(text) (\($0))" } ?? text
        }
        sidebarButton.toolTip = hint("Toggle sidebar", #selector(MainWindowController.toggleSidebarAction(_:)))
        newButton.toolTip = "New session"
        searchButton.toolTip = hint("Search all sessions", #selector(MainWindowController.searchSessions(_:)))
        attention.toolTip = hint("Next needing input", #selector(MainWindowController.nextAttention(_:)))
        for item in newMenu.items {
            guard let action = item.action else { continue }
            let source = Self.menuItem(for: action, in: NSApp?.mainMenu)
            item.keyEquivalent = source?.keyEquivalent ?? ""
            item.keyEquivalentModifierMask = source?.keyEquivalentModifierMask ?? []
        }
    }

    static func menuItem(for action: Selector, in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        for item in menu.items {
            if item.action == action { return item }
            if let hit = menuItem(for: action, in: item.submenu) { return hit }
        }
        return nil
    }
}
