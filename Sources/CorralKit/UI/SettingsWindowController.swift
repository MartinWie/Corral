import AppKit
import CorralCore

/// The Settings pages, in nav order.
enum SettingsPane: String, CaseIterable {
    case general, notifications, agents, shortcuts, terminal

    var title: String {
        switch self {
        case .general: return "General"
        case .notifications: return "Notifications"
        case .agents: return "Agents"
        case .shortcuts: return "Shortcuts"
        case .terminal: return "Terminal"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .notifications: return "bell.badge"
        case .agents: return "sparkles"
        case .shortcuts: return "keyboard"
        case .terminal: return "terminal"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "How Corral behaves while your agents work."
        case .notifications: return "What Corral tells you about while you're elsewhere. Click a notification to go to its session."
        case .agents: return "Where new sessions start, which folder they join, and the hooks that report their status."
        case .shortcuts: return ShortcutSettingsView.introText
        case .terminal: return "Corral's terminals run on Ghostty and use your Ghostty config."
        }
    }
}

/// Settings (⌘,): a nav column on chrome and the selected page on a card, like the main window.
/// General (keep awake, search index), Notifications (which events, sounds), Agents (start directory, sidebar folder, status hooks per agent
/// kind), Shortcuts (customize every menu command), Terminal (Ghostty config, login shell).
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let manager: SessionManager
    let shortcuts: ShortcutStore?
    let root = SettingsRootView()
    let nav = SettingsNavView(panes: SettingsPane.allCases)
    let card = CardView()
    private(set) var pages: [SettingsPane: SettingsPage] = [:]
    private(set) var pane: SettingsPane = .general

    // General
    let keepAwakeSwitch = NSSwitch()
    private(set) var keepAwakeRow: SettingsRow!
    private(set) var searchRow: SettingsRow!
    let rebuildButton = NSButton(title: "Rebuild Now", target: nil, action: nil)
    let importButton = NSButton(title: "Import…", target: nil, action: #selector(AppDelegate.importFromTracker(_:)))
    let updater: AppUpdater?
    let autoUpdateSwitch = NSSwitch()
    let checkNowButton = NSButton(title: "Check Now", target: nil, action: nil)
    private(set) var updatesRow: SettingsRow?
    /// Info.plist the version row reads (tests inject one).
    var appInfo: () -> [String: Any] = { Bundle.main.infoDictionary ?? [:] }

    // Agents
    var pathLabels: [AgentKind: NSTextField] = [:]
    var folderPopups: [AgentKind: NSPopUpButton] = [:]
    /// Clears the agent's start directory; hidden while none is set.
    var clearButtons: [AgentKind: GhostButton] = [:]
    var chooseButtons: [AgentKind: NSButton] = [:]
    private(set) var tiles: [AgentKind: SettingsTileView] = [:]
    /// Install button (hooks missing) and "Status hooks on" (installed), per agent with an integration.
    private(set) var installButtons: [AgentKind: NSButton] = [:]
    private(set) var installedLabels: [AgentKind: NSView] = [:]
    private(set) var agentHeaders: [AgentKind: SettingsRow] = [:]
    private var folderIds: [UUID?] = []
    /// Folder list the popup menus were built from; menus are rebuilt only when it changes.
    private var folderSignature: [String]?

    // Notifications
    private(set) var notifications: NotificationsPane!

    // Shortcuts
    private(set) var shortcutsView: ShortcutSettingsView?

    // Terminal
    private(set) var configRow: SettingsRow!
    private(set) var overridesRow: SettingsRow!
    private(set) var reloadRow: SettingsRow!
    let configButton = NSButton(title: "Open", target: nil, action: nil)
    let overridesButton = NSButton(title: "Open", target: nil, action: nil)
    let reloadButton = NSButton(title: "Reload", target: nil, action: nil)
    let shellLabel = NSTextField(labelWithString: "")
    /// Ghostty's main config file (the terminal engine reports it); "" when there is none.
    var ghosttyConfigPath: () -> String
    var overridesURL = GhosttyDefaults.overridesURL

    /// Frame autosave name. The first present restores the saved frame (or centers), later ones keep it.
    var frameName = "CorralSettingsWindow"
    private(set) var positioned = false

    static let size = NSSize(width: 860, height: 620)
    static let minSize = NSSize(width: 720, height: 480)
    static let navWidth: CGFloat = 200
    static let cardInset: CGFloat = 10
    static let titleColumn: CGFloat = 110
    static let popupWidth: CGFloat = 200
    static let notSet = "Not set"
    static let looseTitle = "Next to selection"
    static let agentsFootnote = "A folder's own default directory wins over these. With no default at all, a new session "
        + "starts in the selected session's directory, then in your home folder."
    static let terminalFootnote = "Fonts, colors, themes and keybinds come from your Ghostty config. Corral's window "
        + "takes its colors from the terminal background."

    private static let smallFont = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
    private static let placeholderFont = NSFont.systemFont(ofSize: 12, weight: .regular)
    private static let menuImages = menuSymbols(["folder", "arrow.turn.down.right"])
    private static let folderImage = menuImages[0]
    private static let looseImage = menuImages[1]

    /// Template symbols, so the popup and its menu tint them for their own state (highlighted items invert).
    /// Each is centered on one shared canvas, so item titles start at the same x whatever the glyph's width.
    static func menuSymbols(_ names: [String]) -> [NSImage?] {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        let symbols = names.map { NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(config) }
        let canvas = NSSize(width: ceil(symbols.compactMap { $0?.size.width }.max() ?? 14),
                            height: ceil(symbols.compactMap { $0?.size.height }.max() ?? 12))
        return symbols.map { symbol in
            guard let symbol else { return nil }
            let image = NSImage(size: canvas, flipped: false) { rect in
                let s = symbol.size
                symbol.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
                return true
            }
            image.isTemplate = true
            return image
        }
    }

    init(manager: SessionManager, shortcuts: ShortcutStore? = nil, updater: AppUpdater? = nil) {
        self.manager = manager
        self.shortcuts = shortcuts
        self.updater = updater
        // Looked up without creating anything (libghostty's open path creates an empty file).
        ghosttyConfigPath = { GhosttyDefaults.editableConfigPath() }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.title = "Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.contentMinSize = Self.minSize
        window.contentView = root
        super.init(window: window)
        window.delegate = self
        build()
        manager.observe { [weak self] change in
            guard let self else { return }
            switch change {
            case .structure: self.refresh()
            case .integrations: self.refreshIntegrations()
            case .settings:
                self.refreshKeepAwake()
                self.notifications.refresh()
            case .status, .background:
                if self.window?.isVisible == true { self.refreshKeepAwake() }
            default: break
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: .corralThemeDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(shortcutsChanged),
                                               name: .corralShortcutsChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Captions that name a shortcut read the menu again.
    @objc private func shortcutsChanged() {
        MainActor.assumeIsolated {
            searchRow?.caption = Self.searchCaption()
            refreshTerminal()
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: Layout

    private func build() {
        for v in [nav, card] as [NSView] { root.addSubview(v) }
        nav.onSelect = { [weak self] in self?.show($0, animated: true) }
        NSLayoutConstraint.activate([
            nav.topAnchor.constraint(equalTo: root.topAnchor, constant: 52),
            nav.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            nav.widthAnchor.constraint(equalToConstant: Self.navWidth - 24),
            nav.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -12),
            // Below the titlebar (like the main window's card below its toolbar): a scroll view under a
            // transparent titlebar gets macOS's titlebar edge blur.
            card.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 2),
            card.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.navWidth),
            card.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.cardInset),
            card.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.cardInset),
        ])
        pages[.general] = buildGeneral()
        notifications = NotificationsPane(manager: manager)
        pages[.notifications] = notifications.page
        pages[.agents] = buildAgents()
        if let shortcuts { pages[.shortcuts] = buildShortcuts(shortcuts) }
        pages[.terminal] = buildTerminal()
        for (p, page) in pages {
            card.addSubview(page)
            NSLayoutConstraint.activate([
                page.topAnchor.constraint(equalTo: card.topAnchor, constant: 1),
                page.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -1),
                page.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 1),
                page.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -1),
            ])
            page.isHidden = p != .general
        }
        for item in nav.items where pages[item.pane] == nil { item.isHidden = true }
        nav.select(.general)
        refresh()
        applyTheme(animated: false)
    }

    /// Small push button; `target` nil sends `action` up the responder chain.
    private func button(_ b: NSButton, _ action: Selector, target: AnyObject? = nil, chain: Bool = false) {
        b.target = chain ? nil : (target ?? self)
        b.action = action
        b.controlSize = .small
        b.font = Self.smallFont
        b.bezelStyle = .push
        b.setContentHuggingPriority(.required, for: .horizontal)
        b.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func buildGeneral() -> SettingsPage {
        let page = SettingsPage(title: SettingsPane.general.title, subtitle: SettingsPane.general.subtitle)
        keepAwakeSwitch.target = self
        keepAwakeSwitch.action = #selector(keepAwakeChanged(_:))
        keepAwakeSwitch.controlSize = .small
        keepAwakeSwitch.setAccessibilityLabel("Keep Mac awake while agents work")
        keepAwakeRow = SettingsRow(title: "Keep Mac awake while agents work", caption: "", accessory: keepAwakeSwitch)
        page.addSection("Power", SettingsList([keepAwakeRow]))

        button(rebuildButton, #selector(rebuildIndex(_:)))
        searchRow = SettingsRow(title: "Search index", caption: Self.searchCaption(), accessory: rebuildButton)
        page.addSection("Search", SettingsList([searchRow]))

        if manager.env.trackerBinary != nil {
            button(importButton, #selector(AppDelegate.importFromTracker(_:)), chain: true)
            let tracker = SettingsRow(title: "Take over from claude-sessions",
                                      caption: "Sessions the Ghostty restore tracker would reopen move into Corral.",
                                      accessory: importButton)
            page.addSection("Sessions", SettingsList([tracker]))
        }

        if updater != nil {
            autoUpdateSwitch.target = self
            autoUpdateSwitch.action = #selector(autoUpdateChanged(_:))
            autoUpdateSwitch.controlSize = .small
            autoUpdateSwitch.setAccessibilityLabel("Check for updates automatically")
            let auto = SettingsRow(title: "Check for updates automatically", caption: "", accessory: autoUpdateSwitch)
            updatesRow = auto
            button(checkNowButton, #selector(checkForUpdatesNow(_:)))
            let version = SettingsRow(title: "Corral " + UpdateText.version(appInfo()), accessory: checkNowButton)
            page.addSection("Updates", SettingsList([auto, version]))
        }
        return page
    }

    private func buildAgents() -> SettingsPage {
        let page = SettingsPage(title: SettingsPane.agents.title, subtitle: SettingsPane.agents.subtitle)
        for (i, agent) in AgentKind.allCases.enumerated() {
            let tile = SettingsTileView(agent: agent, size: 28)
            tile.surface = .card
            tiles[agent] = tile
            var accessory: NSView?
            if agent != .shell {
                let install = NSButton(title: "Install Hooks", target: nil, action: nil)
                button(install, #selector(installIntegration(_:)))
                install.tag = i
                install.setAccessibilityLabel("Install \(agent.displayName) status hooks")
                installButtons[agent] = install
                let check = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil) ?? NSImage())
                check.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
                let label = NSTextField(labelWithString: "Status hooks on")
                label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
                let installed = NSStackView(views: [check, label])
                installed.spacing = 5
                installed.setAccessibilityElement(true)
                installed.setAccessibilityLabel("\(agent.displayName) status hooks installed")
                installedLabels[agent] = installed
                let holder = NSStackView(views: [install, installed])
                holder.orientation = .horizontal
                accessory = holder
            }
            let header = SettingsRow(title: agent.displayName, caption: integrationCaption(agent), leading: tile, accessory: accessory)
            header.titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            agentHeaders[agent] = header

            let path = NSTextField(labelWithString: "")
            path.font = Fonts.pageMono
            path.lineBreakMode = .byTruncatingHead
            path.cell?.usesSingleLineMode = true
            path.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            path.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
            // Outline variant: GhostButton tints with one palette color, which would fill the .fill variant's x.
            let clear = GhostButton(symbol: "xmark.circle", size: 12, frame: NSRect(x: 0, y: 0, width: 16, height: 16),
                                    target: self, action: #selector(clearDirectory(_:)))
            clear.surface = .card
            clear.tag = i
            clear.toolTip = "Clear"
            clear.setAccessibilityLabel("Clear \(agent.displayName) start directory")
            let choose = NSButton(title: "Choose…", target: nil, action: nil)
            button(choose, #selector(chooseDirectory(_:)))
            choose.tag = i
            choose.setAccessibilityLabel("Choose \(agent.displayName) start directory")
            let pathGroup = NSStackView(views: [path, clear, choose])
            pathGroup.orientation = .horizontal
            pathGroup.spacing = 6
            pathGroup.setCustomSpacing(10, after: clear)
            NSLayoutConstraint.activate([clear.widthAnchor.constraint(equalToConstant: 16), clear.heightAnchor.constraint(equalToConstant: 16)])
            let start = SettingsRow(title: "Starts in", accessory: pathGroup, titleWidth: Self.titleColumn)

            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.tag = i
            popup.target = self
            popup.action = #selector(folderChanged(_:))
            popup.controlSize = .small
            popup.font = Self.smallFont
            (popup.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingTail
            popup.toolTip = "Sidebar folder for new \(agent.displayName) sessions"
            popup.setAccessibilityLabel("Sidebar folder for new \(agent.displayName) sessions")
            popup.widthAnchor.constraint(equalToConstant: Self.popupWidth).isActive = true
            let folder = SettingsRow(title: "Sidebar folder", accessory: popup, titleWidth: Self.titleColumn)

            pathLabels[agent] = path
            folderPopups[agent] = popup
            clearButtons[agent] = clear
            chooseButtons[agent] = choose
            let list = SettingsList([header, start, folder])
            list.setAccessibilityElement(true)
            list.setAccessibilityRole(.group)
            list.setAccessibilityLabel(agent.displayName)
            page.addSection(nil, list, footnote: i == AgentKind.allCases.count - 1 ? Self.agentsFootnote : nil)
        }
        return page
    }

    static func searchCaption() -> String {
        "Claude Code, OpenCode and PI transcripts, searched with "
            + (KeyHint.string(for: #selector(MainWindowController.searchSessions(_:))) ?? "Search All Sessions")
            + ". It keeps itself up to date; rebuild if results look stale."
    }

    func integrationCaption(_ agent: AgentKind) -> String {
        let paths = manager.env.integrationPaths
        switch agent {
        case .shell:
            return "Your login shell, \(URL(fileURLWithPath: manager.env.loginShell).lastPathComponent). Status comes from the terminal."
        case .claude:
            return "Hooks in \(RelativeTime.abbreviatePath(paths.claudeSettings.path)) report working, needs input and done "
                + "(the file is backed up first)."
        case .opencode:
            return "A plugin in \(RelativeTime.abbreviatePath(paths.opencodePluginDir.path)) reports its status."
        case .pi:
            return "An extension in \(RelativeTime.abbreviatePath(paths.piExtensionDir.path)) reports its status."
        }
    }

    private func buildShortcuts(_ store: ShortcutStore) -> SettingsPage {
        let view = ShortcutSettingsView(store: store)
        shortcutsView = view
        let page = SettingsPage(title: SettingsPane.shortcuts.title, subtitle: SettingsPane.shortcuts.subtitle,
                                accessory: view.restoreButton)
        page.add(view, after: 0)
        return page
    }

    private func buildTerminal() -> SettingsPage {
        let page = SettingsPage(title: SettingsPane.terminal.title, subtitle: SettingsPane.terminal.subtitle)
        button(configButton, #selector(openConfig(_:)))
        button(overridesButton, #selector(openOverrides(_:)))
        button(reloadButton, #selector(reloadConfig(_:)))
        configRow = SettingsRow(title: "Ghostty config", caption: "", accessory: configButton)
        overridesRow = SettingsRow(title: "Corral overrides", caption: "", accessory: overridesButton)
        reloadRow = SettingsRow(title: "Reload config", caption: "", accessory: reloadButton)
        page.addSection("Ghostty", SettingsList([configRow, overridesRow, reloadRow]), footnote: Self.terminalFootnote)
        shellLabel.font = Fonts.pageMono
        shellLabel.isSelectable = true
        let zsh = URL(fileURLWithPath: manager.env.loginShell).lastPathComponent == "zsh"
        let shell = SettingsRow(title: "Login shell",
                                caption: zsh ? "Agents start directly, with no command typed at a prompt."
                                    : "Agent commands are typed into the shell's first prompt (direct start needs zsh).",
                                accessory: shellLabel)
        page.addSection("Shell", SettingsList([shell]))
        return page
    }

    // MARK: Pages

    /// Switches to `pane`: the new page fades in and settles a few points up.
    func show(_ new: SettingsPane, animated: Bool) {
        guard let next = pages[new] else { return }
        if pane == .shortcuts, new != .shortcuts { shortcutsView?.endRecording() }
        let old = pages[pane]
        pane = new
        nav.select(new)
        guard old !== next else { return }
        old?.isHidden = true
        next.isHidden = false
        window?.makeFirstResponder(nil)
        if new == .terminal { refreshTerminal() }
        if new == .notifications { notifications.refreshPermission() }
        if animated, Motion.shouldAnimate(next), let layer = next.layer {
            layer.add(Motion.basic("opacity", from: 0, to: 1, duration: Motion.base), forKey: "in")
            if Motion.full {
                layer.add(Motion.spring("transform.translation.y", from: next.isFlipped ? -8 : 8, to: 0, duration: 0.3), forKey: "settle")
            }
        }
    }

    // MARK: Presenting and state

    func present(pane: SettingsPane? = nil) {
        // Hooks may have been added or removed outside Corral.
        manager.refreshIntegrations()
        refresh()
        refreshTerminal()
        notifications.refreshPermission()
        applyTheme(animated: false)
        if let pane { show(pane, animated: false) }
        placeWindow()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(nil)
    }

    /// Once per launch: the saved frame, else centered. Later presents leave the window where it is.
    func placeWindow() {
        guard let window, !positioned else { return }
        positioned = true
        // `force`: without it AppKit ignores saved frames of windows it thinks can't take them.
        if !window.setFrameUsingName(frameName, force: true) { window.center() }
        window.setFrameAutosaveName(frameName)
    }

    func windowWillClose(_ notification: Notification) { shortcutsView?.endRecording() }

    /// Back from System Settings: notifications may have been allowed or turned off there.
    func windowDidBecomeKey(_ notification: Notification) {
        if pane == .notifications { notifications.refreshPermission() }
    }

    /// Runs on every `.structure` emit, also while the window is closed: menus are rebuilt only when the folder
    /// list changed, so session-only changes (create, close, move) build no menus.
    func refresh() {
        let ws = manager.workspace
        // Folders in sidebar order; nesting shows as menu indentation.
        var entries: [(title: String, id: UUID?, depth: Int)] = [(Self.looseTitle, nil, 0)]
        func walk(_ items: [TreeItem], depth: Int) {
            for item in items {
                if case .folder(let id, let children) = item {
                    entries.append((ws.folders[id]?.name ?? "Folder", id, depth))
                    walk(children, depth: depth + 1)
                }
            }
        }
        walk(ws.tree, depth: 0)
        let signature = entries.map { "\($0.id?.uuidString ?? "-")|\($0.depth)|\($0.title)" }
        let rebuild = signature != folderSignature
        folderSignature = signature
        folderIds = entries.map(\.id)
        let r = Theme.ramp(.card)
        for agent in AgentKind.allCases {
            let d = ws.defaults(for: agent)
            if let path = pathLabels[agent] {
                let text = d.directory.map(RelativeTime.abbreviatePath) ?? Self.notSet
                if path.stringValue != text { path.stringValue = text }
                let font = d.directory == nil ? Self.placeholderFont : Fonts.pageMono
                if path.font != font { path.font = font }
                if path.toolTip != d.directory { path.toolTip = d.directory }
                let color = Self.pathColor(set: d.directory != nil, r)
                if path.textColor != color { path.textColor = color }
            }
            if let clear = clearButtons[agent], clear.isHidden != (d.directory == nil) { clear.isHidden = d.directory == nil }
            guard let popup = folderPopups[agent] else { continue }
            if rebuild {
                // Items are added directly: addItem(withTitle:) would merge folders that share a name.
                let menu = NSMenu()
                for e in entries {
                    let item = NSMenuItem(title: e.title, action: nil, keyEquivalent: "")
                    item.indentationLevel = e.depth
                    item.image = e.id == nil ? Self.looseImage : Self.folderImage
                    menu.addItem(item)
                }
                popup.menu = menu
            }
            let index = folderIds.firstIndex { $0 == d.folder } ?? 0
            if popup.indexOfSelectedItem != index { popup.selectItem(at: index) }
        }
        refreshIntegrations()
        refreshKeepAwake()
        refreshUpdates()
    }

    func refreshUpdates() {
        guard let updater else { return }
        let state: NSControl.StateValue = updater.automaticallyChecks ? .on : .off
        if autoUpdateSwitch.state != state { autoUpdateSwitch.state = state }
        updatesRow?.caption = UpdateText.caption(lastCheck: updater.lastCheck)
    }

    /// Paths in `secondary`; "Not set" in `tertiary`: it is the row's only "no directory" signal, so it keeps
    /// ≥ 3:1 (quaternary is decoration only, §2.3) and stays quieter than a path through its font and tone.
    static func pathColor(set: Bool, _ r: Ramp) -> NSColor { set ? r.secondary : r.tertiary }

    func refreshIntegrations() {
        let status = manager.integrations
        for agent in AgentKind.allCases where agent != .shell {
            let on = status.installed(agent)
            let present = manager.env.agentPresent(agent, manager.env.integrationPaths)
            installButtons[agent]?.isHidden = on || !present
            installedLabels[agent]?.isHidden = !on
            agentHeaders[agent]?.caption = present || on ? integrationCaption(agent)
                : "Not set up on this Mac yet. Start \(agent.displayName) once, then install its hooks here."
        }
    }

    static let keepAwakeCaption = "Only while a session or background job is working, never while it waits for you. "
        + "The display can still sleep, and closing the lid still sleeps the Mac."

    /// The switch, and while it holds the Mac awake, how many agents are working.
    func refreshKeepAwake() {
        let on = manager.workspace.settings.keepAwake
        let state: NSControl.StateValue = on ? .on : .off
        if keepAwakeSwitch.state != state { keepAwakeSwitch.state = state }
        var caption = Self.keepAwakeCaption
        if on, manager.isKeepingAwake {
            let n = manager.workingAgents
            caption = "Awake now: \(n) agent\(n == 1 ? " is" : "s are") working. " + caption
        }
        keepAwakeRow?.caption = caption
    }

    /// Config paths can appear or go away while the window is closed: read when the page shows.
    func refreshTerminal() {
        let config = ghosttyConfigPath()
        let exists = !config.isEmpty && FileManager.default.fileExists(atPath: config)
        configRow?.caption = exists ? RelativeTime.abbreviatePath(config) : "None yet: Ghostty's defaults apply."
        configButton.title = exists ? "Open" : "Create"
        let overrides = FileManager.default.fileExists(atPath: overridesURL.path)
        overridesRow?.caption = RelativeTime.abbreviatePath(overridesURL.path)
            + (overrides ? ": loaded last, in Corral only." : " (not created): settings here apply only in Corral.")
        overridesButton.title = overrides ? "Open" : "Create"
        let hint = KeyHint.string(for: #selector(AppDelegate.reloadGhosttyConfig(_:))).map { " (\($0))" } ?? ""
        reloadRow?.caption = "Applies config changes to every open terminal\(hint)."
        shellLabel.stringValue = RelativeTime.abbreviatePath(manager.env.loginShell)
    }

    // MARK: Theme

    @objc private func themeChanged() { MainActor.assumeIsolated { applyTheme(animated: true) } }

    /// Recolors the window from `Theme.tokens`. Animated: one crossfade snapshot (M31), added before recoloring.
    func applyTheme(animated: Bool) {
        let t = Theme.tokens, r = t.ramp(.card)
        if animated, Motion.shouldAnimate(root), let layer = root.layer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.25
            fade.timingFunction = Motion.std
            layer.add(fade, forKey: "theme")
        }
        window?.backgroundColor = t.chrome
        window?.appearance = t.chromeAppearance
        card.appearance = t.cardAppearance
        for page in pages.values { page.applyColors() }
        for (agent, path) in pathLabels {
            path.textColor = Self.pathColor(set: manager.workspace.defaults(for: agent).directory != nil, r)
        }
        for v in installedLabels.values {
            for sub in (v as? NSStackView)?.arrangedSubviews ?? [] {
                (sub as? NSTextField)?.textColor = t.status.done.fill
                (sub as? NSImageView)?.contentTintColor = t.status.done.fill
            }
        }
        for row in allRows { row.applyColors() }
        shellLabel.textColor = r.secondary
        notifications.applyTheme()
        shortcutsView?.applyTheme()
        root.needsDisplay = true
        card.needsDisplay = true
        for item in nav.items { item.refresh() }
        for tile in tiles.values { tile.needsDisplay = true }
    }

    private var allRows: [SettingsRow] {
        pages.values.flatMap { $0.lists.flatMap { $0.rows.compactMap { $0 as? SettingsRow } } }
    }

    // MARK: Actions

    private func agent(_ sender: NSControl) -> AgentKind { AgentKind.allCases[sender.tag] }

    @objc func keepAwakeChanged(_ sender: NSSwitch) {
        manager.setKeepAwake(sender.state == .on)
    }

    @objc func autoUpdateChanged(_ sender: NSSwitch) {
        updater?.automaticallyChecks = sender.state == .on
        refreshUpdates()
    }

    @objc func checkForUpdatesNow(_ sender: Any?) { updater?.checkForUpdates() }

    @objc func rebuildIndex(_ sender: Any?) {
        manager.refreshIndex([.claude, .opencode, .pi])
        rebuildButton.title = "Rebuilding…"
        rebuildButton.isEnabled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.rebuildButton.title = "Rebuild Now"
            self?.rebuildButton.isEnabled = true
        }
    }

    @objc func installIntegration(_ sender: NSButton) {
        let kind = agent(sender)
        let paths = manager.env.integrationPaths
        do {
            switch kind {
            case .shell: return
            case .claude: _ = try Integrations.installClaude(settingsURL: paths.claudeSettings)
            case .opencode: try Integrations.installOpenCode(pluginDir: paths.opencodePluginDir)
            case .pi: try Integrations.installPi(extensionDir: paths.piExtensionDir)
            }
        } catch {
            manager.env.alert("Couldn't install the \(kind.displayName) hooks", error.localizedDescription)
        }
        manager.refreshIntegrations()
    }

    @objc func openConfig(_ sender: Any?) {
        var path = ghosttyConfigPath()
        if path.isEmpty {
            path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/ghostty/config").path
        }
        openCreating(URL(fileURLWithPath: path), header: "# Ghostty config: https://ghostty.org/docs/config\n")
    }

    @objc func openOverrides(_ sender: Any?) {
        openCreating(overridesURL, header: "# Ghostty settings for Corral only, loaded after your Ghostty config.\n"
            + "# Same format as Ghostty's config: https://ghostty.org/docs/config\n")
    }

    /// Opens `url` in the default editor, creating it (and its folder) with `header` first if needed.
    private func openCreating(_ url: URL, header: String) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            do {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try header.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                manager.env.alert("Couldn't create \(RelativeTime.abbreviatePath(url.path))", error.localizedDescription)
                return
            }
        }
        manager.env.openURL(url)
        refreshTerminal()
    }

    @objc func reloadConfig(_ sender: Any?) { manager.reloadTerminalConfig() }

    @objc func chooseDirectory(_ sender: NSButton) {
        let kind = agent(sender)
        Presenter.chooseDirectory(start: manager.workspace.defaults(for: kind).directory, prompt: "Use as Default",
                                  message: "Directory new \(kind.displayName) sessions start in", window: window) { [weak self] url in
            guard let self, let url else { return }
            var d = self.manager.workspace.defaults(for: kind)
            d.directory = url.path
            self.manager.setAgentDefaults(d, for: kind)
        }
    }

    @objc func clearDirectory(_ sender: NSButton) {
        let kind = agent(sender)
        var d = manager.workspace.defaults(for: kind)
        d.directory = nil
        manager.setAgentDefaults(d, for: kind)
    }

    @objc func folderChanged(_ sender: NSPopUpButton) {
        let kind = agent(sender)
        var d = manager.workspace.defaults(for: kind)
        let i = sender.indexOfSelectedItem
        d.folder = i >= 0 && i < folderIds.count ? folderIds[i] : nil
        manager.setAgentDefaults(d, for: kind)
    }
}
