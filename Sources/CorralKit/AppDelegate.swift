import AppKit
import CorralCore
import UserNotifications

public final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let makeTerminals: () -> TerminalFactory?
    private let makeEnvironment: () -> ManagerEnvironment
    private(set) var terminals: TerminalFactory!
    private(set) var manager: SessionManager!
    private(set) var main: MainWindowController!
    private(set) lazy var settings = SettingsWindowController(manager: manager, shortcuts: shortcuts, updater: updater)
    /// The user's shortcuts over the menu's built-in ones.
    let shortcuts: ShortcutStore
    /// Nil without an update feed (dev builds): no Check for Updates item, no Updates section.
    let updater: AppUpdater?
    /// Session › Import from claude-sessions is only offered when that tracker is installed.
    var trackerAvailable: () -> Bool = { TrackerCLI.defaultBinary != nil }
    /// Shows an alert and returns the button pressed (injectable for tests).
    var runAlert: (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }
    private var bench: BenchRunner?
    /// CORRAL_BENCH=<out.json>: run the benchmark against throwaway state, then quit.
    var benchOutput = ProcessInfo.processInfo.environment["CORRAL_BENCH"]
    var configureBench: (BenchRunner) -> Void = { _ in }
    var onBenchFinished: () -> Void = { NSApp.terminate(nil) }

    /// `makeTerminals` returns nil when the terminal engine can't start.
    public init(makeTerminals: @escaping () -> TerminalFactory?,
                environment: @escaping () -> ManagerEnvironment = { .app() },
                shortcutDefaults: UserDefaults = .standard,
                updater: AppUpdater? = nil) {
        self.makeTerminals = makeTerminals
        self.updater = updater
        self.makeEnvironment = environment
        self.shortcuts = ShortcutStore(defaults: shortcutDefaults)
        super.init()
        shortcuts.onChange = { [weak self] store in
            // Terminals pick up the moved keys' unbinds; nothing to reload when the set is unchanged.
            guard store.ghosttyUnbinds != GhosttyDefaults.unbinds else { return }
            GhosttyDefaults.unbinds = store.ghosttyUnbinds
            self?.manager?.reloadTerminalConfig()
        }
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        launch()
    }

    /// Tests launch without showing a window.
    func launch(showWindow: Bool = true, terminateOnFailure: Bool = true) {
        // The menu first: the terminal engine's config needs the unbinds of customized shortcuts.
        let menu = buildMenu()
        GhosttyDefaults.unbinds = shortcuts.ghosttyUnbinds
        guard let terminals = makeTerminals() else {
            let alert = NSAlert()
            alert.messageText = "libghostty failed to start"
            alert.informativeText = "Check the Ghostty config for errors (Console.app, process Corral)."
            _ = runAlert(alert)
            if terminateOnFailure { NSApp.terminate(nil) }
            return
        }
        self.terminals = terminals
        Motion.observeAccessibility()
        Theme.update(background: terminals.backgroundColor, foreground: terminals.foregroundColor,
                     windowTheme: terminals.windowTheme)
        manager = SessionManager(terminals: terminals, env: benchOutput == nil ? makeEnvironment() : BenchRunner.environment())
        main = MainWindowController(manager: manager)
        NSApp.mainMenu = menu
        if manager.env.notifications {
            UNUserNotificationCenter.current().delegate = self
            UNUserNotificationCenter.current().setNotificationCategories(Notifier.categories)
        }
        manager.start()
        if let benchOutput {
            // Invisible but on screen, so terminals render like in normal use; never takes focus.
            main.window?.alphaValue = 0
            main.window?.ignoresMouseEvents = true
            main.window?.orderFrontRegardless()
            let runner = BenchRunner(manager: manager, window: main, output: URL(fileURLWithPath: benchOutput))
            configureBench(runner)
            bench = runner
            runner.run { [weak self] in self?.onBenchFinished() }
            return
        }
        guard showWindow else { return }
        main.showWindow(nil)
        NSApp.activate()
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        main.showWindow(nil)
        return true
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard bench == nil else { return .terminateNow }
        let busy = manager.live.values.filter { $0.status.activity == .working || $0.status.activity == .needsInput }.count
        guard busy > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit Corral?"
        alert.informativeText = "\(busy) agent session\(busy == 1 ? " is" : "s are") busy. They are resumed when Corral starts again."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return runAlert(alert) == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    public func applicationWillTerminate(_ notification: Notification) {
        manager?.prepareForTermination()
    }

    // MARK: Notifications

    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        // Called on Notification Center's queue, not necessarily main.
        let info = response.notification.request.content.userInfo
        let id = (info["session"] as? String).flatMap(UUID.init)
        let prompt = info["prompt"] as? String
        let action = response.actionIdentifier
        DispatchQueue.main.async { [weak self] in
            guard let self, let manager = self.manager,
                  manager.respondToNotification(action: action, session: id, prompt: prompt) else { return }
            self.openNotification(session: id)
        }
        completionHandler()
    }

    /// A clicked notification brings Corral forward on its session (the test one just on the window).
    func openNotification(session id: UUID?) {
        guard let main, let manager else { return }
        main.showWindow(nil)
        NSApp.activate()
        if let id { manager.reveal(id) }
    }

    /// Corral in front: still a banner (Settings › Notifications decides whether one is posted at all).
    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    // MARK: Integrations

    @objc func installIntegrations(_ sender: Any?) {
        let paths = manager.env.integrationPaths
        manager.refreshIntegrations()
        let missing = Set(manager.missingIntegrations)
        let status = Integrations.Status(claude: !missing.contains(.claude), opencode: !missing.contains(.opencode),
                                         pi: !missing.contains(.pi))
        var plan: [String] = []
        if !status.claude { plan.append("• Claude Code: add hooks to \(RelativeTime.abbreviatePath(paths.claudeSettings.path)) (backup kept)") }
        if !status.opencode { plan.append("• OpenCode: plugin \(RelativeTime.abbreviatePath(paths.opencodePluginDir.appendingPathComponent("corral.js").path))") }
        if !status.pi { plan.append("• PI: extension \(RelativeTime.abbreviatePath(paths.piExtensionDir.appendingPathComponent("corral.ts").path))") }
        guard !plan.isEmpty else {
            let done = NSAlert()
            done.messageText = "All agent integrations are installed."
            _ = runAlert(done)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Install agent integrations?"
        alert.informativeText = plan.joined(separator: "\n")
            + "\n\nThey report working / needs input / done to Corral and do nothing outside Corral terminals."
            + " Running agents pick them up on their next start."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        guard runAlert(alert) == .alertFirstButtonReturn else { return }
        var errors: [String] = []
        do { if !status.claude { _ = try Integrations.installClaude(settingsURL: paths.claudeSettings) } } catch { errors.append("Claude: \(error.localizedDescription)") }
        do { if !status.opencode { try Integrations.installOpenCode(pluginDir: paths.opencodePluginDir) } } catch { errors.append("OpenCode: \(error.localizedDescription)") }
        do { if !status.pi { try Integrations.installPi(extensionDir: paths.piExtensionDir) } } catch { errors.append("PI: \(error.localizedDescription)") }
        manager.refreshIntegrations()
        if !errors.isEmpty {
            let e = NSAlert()
            e.messageText = "Some integrations failed"
            e.informativeText = errors.joined(separator: "\n")
            _ = runAlert(e)
        }
    }

    @objc func openGhosttyConfig(_ sender: Any?) {
        let path = terminals.configPath
        if !path.isEmpty { manager.env.openURL(URL(fileURLWithPath: path)) }
    }

    @objc func reloadGhosttyConfig(_ sender: Any?) { manager.reloadTerminalConfig() }

    // MARK: Menu

    func buildMenu() -> NSMenu {
        let bar = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) {
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            items.forEach { m.addItem($0) }
            top.submenu = m
            bar.addItem(top)
        }
        func arrow(_ key: Int) -> String { String(Character(UnicodeScalar(UInt16(key))!)) }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command], tag: Int = 0) -> NSMenuItem {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
            mi.keyEquivalentModifierMask = mods
            mi.tag = tag
            return mi
        }

        var appItems = [item("About Corral", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))]
        if updater != nil { appItems.append(item("Check for Updates…", #selector(checkForUpdates(_:)))) }
        menu("Corral", appItems + [
            .separator(),
            item("Settings…", #selector(showSettings(_:)), ","),
            .separator(),
            item("Open Ghostty Config", #selector(openGhosttyConfig(_:)), ",", [.command, .option]),
            item("Reload Ghostty Config", #selector(reloadGhosttyConfig(_:)), ",", [.command, .shift]),
            .separator(),
            item("Hide Corral", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            .separator(),
            item("Quit Corral", #selector(NSApplication.terminate(_:)), "q"),
        ])
        menu("Session", [
            item("New Shell", #selector(MainWindowController.newShell(_:)), "t"),
            item("New Claude Session", #selector(MainWindowController.newClaude(_:)), "c", [.command, .control]),
            item("New OpenCode Session", #selector(MainWindowController.newOpenCode(_:)), "o", [.command, .control]),
            item("New PI Session", #selector(MainWindowController.newPi(_:)), "p", [.command, .control]),
            item("New Session in Directory…", #selector(MainWindowController.newInDirectory(_:)), "t", [.command, .option]),
            item("New Folder", #selector(MainWindowController.newFolder(_:)), "n", [.command, .shift]),
            .separator(),
            item("Rename Session…", #selector(MainWindowController.renameSession(_:)), "r", [.command, .shift]),
            item("Close Session", #selector(MainWindowController.closeSession(_:)), "w"),
            item("Reopen Closed Session", #selector(MainWindowController.reopenClosed(_:)), "t", [.command, .shift]),
            .separator(),
            // Always in the menu (a custom shortcut for it survives), shown only with the tracker installed.
            item("Import from claude-sessions…", #selector(importFromTracker(_:))),
        ])
        if !trackerAvailable(), let session = bar.items.last?.submenu {
            session.items.suffix(2).forEach { $0.isHidden = true }
        }
        menu("Edit", [
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSResponder.selectAll(_:)), "a"),
            .separator(),
            item("Find in Scrollback…", #selector(MainWindowController.findInTerminal(_:)), "f"),
            item("Clear Screen", #selector(MainWindowController.clearTerminal(_:)), "k", [.command, .shift]),
        ])
        var goItems: [NSMenuItem] = [
            item("Search All Sessions…", #selector(MainWindowController.searchSessions(_:)), "k"),
            item("Next Session Needing Input", #selector(MainWindowController.nextAttention(_:)), "i"),
            .separator(),
            item("Next Session", #selector(MainWindowController.nextSession(_:)), "]", [.command, .shift]),
            item("Previous Session", #selector(MainWindowController.previousSession(_:)), "[", [.command, .shift]),
            item("Focus Sidebar", #selector(MainWindowController.focusSidebar(_:)), "e", [.command, .shift]),
            .separator(),
            // On the card first; ↑ / ↓ go on to the previous / next session in the sidebar.
            item("Focus Up", #selector(MainWindowController.focusUp(_:)), arrow(NSUpArrowFunctionKey), [.command, .option]),
            item("Focus Down", #selector(MainWindowController.focusDown(_:)), arrow(NSDownArrowFunctionKey), [.command, .option]),
            item("Focus Left", #selector(MainWindowController.focusLeft(_:)), arrow(NSLeftArrowFunctionKey), [.command, .option]),
            item("Focus Right", #selector(MainWindowController.focusRight(_:)), arrow(NSRightArrowFunctionKey), [.command, .option]),
            .separator(),
        ]
        for n in 1...9 {
            goItems.append(item(n == 9 ? "Last Session" : "Session \(n)", #selector(MainWindowController.selectSessionByNumber(_:)), "\(n)", tag: n))
        }
        menu("Go", goItems)
        menu("View", [
            item("Split Right", #selector(MainWindowController.splitRight(_:)), "d"),
            item("Split Down", #selector(MainWindowController.splitDown(_:)), "d", [.command, .shift]),
            item("Next Pane", #selector(MainWindowController.nextPane(_:)), "]"),
            item("Previous Pane", #selector(MainWindowController.previousPane(_:)), "["),
            .separator(),
            item("Toggle Sidebar", #selector(MainWindowController.toggleSidebarAction(_:)), "s", [.command, .control]),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        let windowMenu = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let wm = NSMenu(title: "Window")
        wm.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        wm.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        wm.addItem(item("Show Main Window", #selector(showMain(_:)), "1", [.command, .option]))
        windowMenu.submenu = wm
        bar.addItem(windowMenu)
        NSApp.windowsMenu = wm
        menu("Help", [item("Keyboard Shortcuts", #selector(MainWindowController.showShortcuts(_:)), "/")])
        NSApp.helpMenu = bar.items.last?.submenu
        shortcuts.register(bar)
        return bar
    }

    @objc func showMain(_ sender: Any?) { main.showWindow(nil) }

    @objc func checkForUpdates(_ sender: Any?) { updater?.checkForUpdates() }

    /// Takes over sessions from the Ghostty restore tracker (`claude-sessions`).
    @objc func importFromTracker(_ sender: Any?) {
        guard let binary = manager.env.trackerBinary else {
            let a = NSAlert()
            a.messageText = "claude-sessions not found"
            a.informativeText = "Expected ~/.local/bin/claude-sessions."
            _ = runAlert(a)
            return
        }
        TrackerCLI.list(binary: binary) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                let a = NSAlert()
                a.messageText = "Couldn't read claude-sessions"
                a.informativeText = error.localizedDescription
                _ = self.runAlert(a)
            case .success(let rows):
                let plan = TrackerImport.plan(rows, known: self.manager.knownAgentSessionIds)
                let a = NSAlert()
                a.messageText = plan.isEmpty ? "Nothing to take over yet" : "Take over \(plan.actions.count) session\(plan.actions.count == 1 ? "" : "s") from Ghostty?"
                a.informativeText = TrackerImport.summary(plan)
                if plan.isEmpty {
                    _ = self.runAlert(a)
                    return
                }
                a.addButton(withTitle: "Take Over")
                a.addButton(withTitle: "Cancel")
                guard self.runAlert(a) == .alertFirstButtonReturn else { return }
                let ids = self.manager.importTracked(plan)
                TrackerCLI.forget(binary: binary, ids: ids) { result in
                    if case .failure(let error) = result {
                        let f = NSAlert()
                        f.messageText = "Imported, but claude-sessions still lists them"
                        f.informativeText = "Run `claude-sessions forget \(ids.joined(separator: " "))` so Ghostty won't reopen them.\n\n\(error.localizedDescription)"
                        _ = self.runAlert(f)
                    }
                }
            }
        }
    }
    @objc func showSettings(_ sender: Any?) { settings.present() }

    /// Settings › Shortcuts (Customize… in the ⌘/ sheet).
    @objc func customizeShortcuts(_ sender: Any?) {
        main?.shortcutsPopover?.performClose(nil)
        settings.present(pane: .shortcuts)
    }
}
