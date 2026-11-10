import AppKit
@testable import CorralCore
import Testing
@testable import CorralKit

/// The Settings window's pages: nav, keep awake, agent hooks, terminal config, and keep-awake itself.
@MainActor
@Suite(.serialized)
struct SettingsPagesTests {
    func store() -> (ShortcutStore, String) {
        let suite = "corral-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let s = ShortcutStore(defaults: defaults)
        _ = NSApplication.shared
        let app = AppDelegate(makeTerminals: { FakeFactory() }, shortcutDefaults: defaults)
        app.trackerAvailable = { false }
        s.register(app.buildMenu())
        return (s, suite)
    }

    @Test func windowIsANavColumnAndACard() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let (store, suite) = store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let w = SettingsWindowController(manager: f.manager, shortcuts: store)
        let window = try #require(w.window)
        #expect(window.styleMask == [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        #expect(window.titlebarAppearsTransparent && window.titleVisibility == .hidden)
        #expect(window.title == "Settings")
        #expect(window.contentMinSize == SettingsWindowController.minSize)
        #expect(window.contentView === w.root)
        window.contentView?.layoutSubtreeIfNeeded()
        // Nav on the left below the traffic lights, the card filling the rest with a 10 pt margin.
        #expect(w.card.frame.minX == SettingsWindowController.navWidth)
        #expect(w.card.frame.maxX == window.contentView!.bounds.maxX - SettingsWindowController.cardInset)
        #expect(w.nav.items.map(\.pane) == SettingsPane.allCases)
        #expect(w.nav.items.allSatisfy { !$0.isHidden })
        #expect(w.pages.count == 5 && w.pane == .general)
        #expect(w.pages[.general]?.isHidden == false)
        #expect(w.pages.filter { !$0.value.isHidden }.count == 1)
        #expect(w.nav.items.first?.selected == true && w.nav.items.first?.accessibilityValue() as? String == "selected")
        for pane in SettingsPane.allCases {
            #expect(!pane.title.isEmpty && !pane.subtitle.isEmpty && NSImage(systemSymbolName: pane.symbol, accessibilityDescription: nil) != nil)
        }
        // Without a shortcut store there is no Shortcuts page.
        let plain = SettingsWindowController(manager: f.manager)
        #expect(plain.pages[.shortcuts] == nil)
        #expect(plain.nav.items.first { $0.pane == .shortcuts }?.isHidden == true)
        plain.show(.shortcuts, animated: true)
        #expect(plain.pane == .general)
    }

    @Test func navSwitchesPagesAndEndsShortcutRecording() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let (store, suite) = store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let w = SettingsWindowController(manager: f.manager, shortcuts: store)
        for item in w.nav.items {
            item.mouseDown(with: NSEvent())
            #expect(w.pane == item.pane)
            #expect(w.pages[item.pane]?.isHidden == false)
            #expect(w.pages.filter { !$0.value.isHidden }.count == 1)
            #expect(item.selected && w.nav.items.filter(\.selected).count == 1)
        }
        _ = w.nav.items[2].accessibilityPerformPress()
        #expect(w.pane == .agents)
        let view = try #require(w.shortcutsView)
        #expect(w.pages[.shortcuts]?.header.arrangedSubviews.last === view.restoreButton)
        w.show(.shortcuts, animated: false)
        let row = try #require(view.rows.first)
        row.recorder.beginRecording()
        w.show(.general, animated: true)
        #expect(!row.recorder.isRecording)
        w.show(.shortcuts, animated: false)
        row.recorder.beginRecording()
        w.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        #expect(!row.recorder.isRecording)
        // Hover and theme refresh the nav rows.
        let item = w.nav.items[2]
        item.mouseEntered(with: NSEvent())
        item.mouseExited(with: NSEvent())
        item.updateTrackingAreas()
        item.updateLayer()
        // Animated switch (an invisible window counts as on screen here).
        Motion.assumeVisible = true
        defer { Motion.assumeVisible = false }
        w.show(.terminal, animated: true)
        #expect(w.pages[.terminal]?.layer?.animation(forKey: "in") != nil)
        w.show(.terminal, animated: true)
        #expect(w.pane == .terminal)
    }

    @Test func keepAwakeSwitchFollowsTheSettingAndSaysWhenItHolds() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let w = SettingsWindowController(manager: f.manager)
        #expect(w.keepAwakeSwitch.state == .off)
        #expect(w.keepAwakeRow.caption == SettingsWindowController.keepAwakeCaption)
        #expect(!w.keepDisplaySwitch.isEnabled)
        w.keepAwakeSwitch.state = .on
        w.keepAwakeChanged(w.keepAwakeSwitch)
        #expect(f.manager.workspace.settings.keepAwake)
        #expect(w.keepDisplaySwitch.isEnabled && w.keepDisplaySwitch.state == .off)
        w.keepDisplaySwitch.state = .on
        w.keepDisplayChanged(w.keepDisplaySwitch)
        #expect(f.manager.workspace.settings.keepDisplayOn)
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        let id = try #require(f.selected)
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "UserPromptSubmit")), to: id)
        w.refreshKeepAwake()
        #expect(w.keepAwakeRow.caption.hasPrefix("Awake now: 1 agent is working."))
        f.manager.setKeepAwake(false)
        #expect(w.keepAwakeSwitch.state == .off)
        #expect(w.keepAwakeRow.caption == SettingsWindowController.keepAwakeCaption)
    }

    @Test func agentsPageInstallsHooksPerAgent() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let w = SettingsWindowController(manager: f.manager)
        #expect(w.installButtons[.shell] == nil && w.installedLabels[.shell] == nil)
        for agent in [AgentKind.claude, .opencode, .pi] {
            #expect(w.installButtons[agent]?.isHidden == false)
            #expect(w.installedLabels[agent]?.isHidden == true)
        }
        #expect(w.integrationCaption(.claude).contains("report working, needs input and done"))
        #expect(w.integrationCaption(.shell).hasPrefix("Your login shell"))
        #expect(w.integrationCaption(.opencode).contains("plugin") && w.integrationCaption(.pi).contains("extension"))
        w.installIntegration(try #require(w.installButtons[.opencode]))
        #expect(f.manager.integrations.opencode && !f.manager.integrations.claude)
        #expect(w.installButtons[.opencode]?.isHidden == true && w.installedLabels[.opencode]?.isHidden == false)
        #expect(w.installButtons[.claude]?.isHidden == false)
        w.installIntegration(try #require(w.installButtons[.claude]))
        w.installIntegration(try #require(w.installButtons[.pi]))
        #expect(f.manager.integrations.allInstalled)
        // A write that fails is reported.
        let g = Fixture { $0.integrationPaths.piExtensionDir = URL(fileURLWithPath: "/dev/null/ext") }
        defer { g.cleanup() }
        let w2 = SettingsWindowController(manager: g.manager)
        w2.installIntegration(try #require(w2.installButtons[.pi]))
        #expect(g.effects.alerts.last == "Couldn't install the PI hooks")
        let shell = NSButton()
        shell.tag = AgentKind.allCases.firstIndex(of: .shell)!
        w.installIntegration(shell)
    }

    @Test func generalPageRebuildsTheIndexAndOffersTheTrackerOnlyWhenInstalled() throws {
        let f = Fixture { $0.trackerBinary = nil }
        defer { f.cleanup() }
        let w = SettingsWindowController(manager: f.manager)
        #expect(w.pages[.general]?.lists.count == 2)
        w.rebuildIndex(nil)
        #expect(w.rebuildButton.title == "Rebuilding…" && !w.rebuildButton.isEnabled)
        let g = Fixture { $0.trackerBinary = "/usr/bin/true" }
        defer { g.cleanup() }
        let t = SettingsWindowController(manager: g.manager)
        #expect(t.pages[.general]?.lists.count == 3)
        #expect(t.importButton.action == #selector(AppDelegate.importFromTracker(_:)) && t.importButton.target == nil)
    }

    @Test func terminalPageOpensOrCreatesConfigFiles() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let w = SettingsWindowController(manager: f.manager)
        let config = f.dir.appendingPathComponent("ghostty/config")
        w.ghosttyConfigPath = { config.path }
        w.overridesURL = f.dir.appendingPathComponent("corral/ghostty")
        w.refreshTerminal()
        #expect(w.configButton.title == "Create" && w.configRow.caption.hasPrefix("None yet"))
        #expect(w.overridesButton.title == "Create" && w.overridesRow.caption.contains("not created"))
        #expect(w.shellLabel.stringValue == RelativeTime.abbreviatePath(f.manager.env.loginShell))
        w.openConfig(nil)
        #expect(FileManager.default.fileExists(atPath: config.path))
        #expect(f.effects.opened.last == config)
        #expect(w.configButton.title == "Open" && w.configRow.caption == RelativeTime.abbreviatePath(config.path))
        w.openOverrides(nil)
        #expect(try String(contentsOf: w.overridesURL, encoding: .utf8).contains("Corral only"))
        #expect(w.overridesButton.title == "Open" && w.overridesRow.caption.contains("loaded last"))
        w.openOverrides(nil)
        #expect(f.effects.opened.count == 3)
        let reloads = f.factory.reloads
        w.reloadConfig(nil)
        #expect(f.factory.reloads == reloads + 1)
        // Can't create: reported, nothing opened.
        let blocked = f.dir.appendingPathComponent("blocked")
        try "file".write(to: blocked, atomically: true, encoding: .utf8)
        w.overridesURL = blocked.appendingPathComponent("ghostty")
        w.openOverrides(nil)
        #expect(f.effects.alerts.last?.hasPrefix("Couldn't create") == true && f.effects.opened.count == 3)
        w.ghosttyConfigPath = { "" }
        w.refreshTerminal()
        #expect(w.configButton.title == "Create")
    }

    @Test func themeChangeRecolorsPagesAndLists() throws {
        let f = Fixture()
        defer {
            f.cleanup()
            Theme.update(background: nil, foreground: nil, windowTheme: nil)
        }
        f.manager.setAgentDefaults(AgentDefaults(directory: f.dir.path), for: .claude)
        let w = SettingsWindowController(manager: f.manager)
        let window = try #require(w.window)
        for (bg, fg, appearance) in [(SettingsTests.light.bg, SettingsTests.light.fg, NSAppearance.Name.aqua),
                                     (SettingsTests.dark.bg, SettingsTests.dark.fg, NSAppearance.Name.darkAqua)] {
            Theme.update(background: bg, foreground: fg, windowTheme: nil)
            let t = Theme.tokens, r = t.ramp(.card)
            #expect(window.backgroundColor == t.chrome)
            #expect(window.appearance?.name == appearance)
            #expect(w.card.appearance === t.cardAppearance)
            #expect(w.pathLabels[.claude]?.textColor == r.secondary)
            #expect(w.pathLabels[.pi]?.textColor == r.tertiary)
            let page = try #require(w.pages[.agents])
            #expect(page.titleLabel.textColor == r.primary && page.subtitleLabel.textColor == r.secondary)
            #expect(page.footnotes.count == 1 && page.footnotes.allSatisfy { $0.textColor == r.tertiary })
            window.contentView?.layoutSubtreeIfNeeded()
            let list = try #require(page.lists.first)
            for v in [w.root, list, w.tiles[.claude]!] as [NSView] { SettingsTests.draw(v) }
            #expect(w.root.layer?.backgroundColor == t.chrome.cgColor)
            #expect(list.layer?.backgroundColor == r.sunken.cgColor)
            #expect(list.layer?.borderColor == r.hairline.cgColor)
            #expect(list.layer?.cornerRadius == 10)
            #expect(list.separators.count == 2)
            #expect(w.tiles[.claude]?.layer?.backgroundColor == SettingsTileView.fill(r).cgColor)
            #expect(w.tiles[.claude]?.glyph.contents != nil)
            let row = try #require(list.rows.first as? SettingsRow)
            #expect(row.titleLabel.textColor == r.primary && row.captionLabel.textColor == r.secondary)
            let general = try #require(w.pages[.general])
            #expect(general.sectionLabels.map(\.1) == ["Power", "Search"] || general.sectionLabels.map(\.1) == ["Power", "Search", "Sessions"])
        }
        NotificationCenter.default.post(name: .corralThemeDidChange, object: nil)
        // "system" follows macOS: no forced appearance on the window.
        Theme.update(background: SettingsTests.dark.bg, foreground: SettingsTests.dark.fg, windowTheme: "system")
        #expect(window.appearance == nil)
    }

    @Test func rowsWrapTheirCaptionsAndGrow() throws {
        let row = SettingsRow(title: "Keep Mac awake", caption: String(repeating: "A long caption. ", count: 20),
                              accessory: NSSwitch())
        let list = SettingsList([row])
        list.frame = NSRect(x: 0, y: 0, width: 420, height: 100)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 400))
        host.addSubview(list)
        list.widthAnchor.constraint(equalToConstant: 420).isActive = true
        host.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        #expect(row.frame.height > SettingsRow.minHeight)
        #expect(row.captionLabel.frame.height > 20)
        row.caption = ""
        #expect(row.captionLabel.isHidden)
        let plain = SettingsRow(title: "No accessory")
        #expect(plain.accessory == nil && plain.captionLabel.isHidden)
        list.surface = .chrome
        #expect(list.separators.isEmpty)
    }

    // MARK: Keep awake (manager)

    /// "Keep the display on too" takes the display kind; switching it while held swaps the assertion.
    @Test func keepDisplayOnSwapsTheAssertion() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let m = f.manager!
        m.newSession(agent: .claude, cwd: f.dir.path)
        let claude = try #require(f.selected)
        m.setKeepAwake(true)
        m.apply(.hook(HookEvent(agent: .claude, event: "UserPromptSubmit")), to: claude)
        #expect(f.effects.awakeDisplay == [false])
        m.setKeepDisplayOn(true)
        m.setKeepDisplayOn(true)
        #expect(f.effects.awakeReleased == [1] && f.effects.awakeDisplay == [false, true] && m.isKeepingAwake)
        m.setKeepDisplayOn(false)
        #expect(f.effects.awakeReleased == [1, 2] && f.effects.awakeDisplay == [false, true, false])
        // Nothing working: the setting alone takes nothing.
        m.apply(.hook(HookEvent(agent: .claude, event: "Stop")), to: claude)
        m.setKeepDisplayOn(true)
        #expect(!m.isKeepingAwake && f.effects.awakeReleased == [1, 2, 3] && f.effects.awakeDisplay.count == 3)
    }

    @Test func keepAwakeHoldsOnlyWhileAnAgentWorks() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let m = f.manager!
        m.newSession(agent: .claude, cwd: f.dir.path)
        let claude = try #require(f.selected)
        m.newSession(agent: .shell, cwd: f.dir.path)
        let shell = try #require(f.selected)
        // Off: an agent working takes nothing.
        m.apply(.hook(HookEvent(agent: .claude, event: "UserPromptSubmit")), to: claude)
        #expect(f.effects.awake.isEmpty && !m.isKeepingAwake)
        m.setKeepAwake(true)
        m.setKeepAwake(true)
        #expect(f.effects.awake == ["Corral: agents are working"] && m.isKeepingAwake && m.workingAgents == 1)
        // Waiting for permission doesn't count.
        m.apply(.hook(HookEvent(agent: .claude, event: "PermissionRequest", message: "Bash: ls")), to: claude)
        #expect(!m.isKeepingAwake && f.effects.awakeReleased == [1])
        // A plain shell running a command doesn't either.
        m.apply(.userSubmitted, to: shell)
        #expect(!m.isKeepingAwake)
        // A background job working does.
        m.applyBackground([BackgroundAgent(id: "j1", sessionId: "j1-s", name: "job", cwd: f.dir.path, state: "working")])
        #expect(m.isKeepingAwake && f.effects.awake.count == 2)
        m.applyBackground([])
        #expect(!m.isKeepingAwake)
        // Working again, then the session closes.
        m.apply(.hook(HookEvent(agent: .claude, event: "UserPromptSubmit")), to: claude)
        #expect(m.isKeepingAwake)
        m.close(claude)
        #expect(!m.isKeepingAwake)
        // Turning the setting off releases at once; quitting too.
        m.newSession(agent: .claude, cwd: f.dir.path)
        let again = try #require(f.selected)
        m.apply(.hook(HookEvent(agent: .claude, event: "UserPromptSubmit")), to: again)
        #expect(m.isKeepingAwake)
        m.setKeepAwake(false)
        #expect(!m.isKeepingAwake)
        m.setKeepAwake(true)
        #expect(m.isKeepingAwake)
        m.prepareForTermination()
        #expect(!m.isKeepingAwake)
        #expect(f.effects.awake.count == f.effects.awakeReleased.count)
    }

    @Test func keepAwakeLapsesWithoutActivityAndCountsOnlyHookedWork() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let m = f.manager!
        m.setKeepAwake(true)
        // An agent the terminal guesses is working (no hooks) doesn't keep the Mac up.
        m.newSession(agent: .claude, cwd: f.dir.path)
        let guessed = try #require(f.selected)
        m.apply(.foregroundProcess(.claude), to: guessed)
        m.apply(.userSubmitted, to: guessed)
        #expect(m.live[guessed]?.status.activity == .working && !m.isKeepingAwake && m.workingAgents == 0)
        // A hooked one does; the assertion is taken with the lapse timeout.
        m.newSession(agent: .claude, cwd: f.dir.path)
        let hooked = try #require(f.selected)
        m.apply(.hook(HookEvent(agent: .claude, event: "UserPromptSubmit")), to: hooked)
        #expect(m.isKeepingAwake && f.effects.awake.count == 1)
        // Activity pushes the timeout out, at most once a minute.
        m.apply(.hook(HookEvent(agent: .claude, event: "PostToolUse")), to: hooked)
        #expect(f.effects.awakeRearmed.isEmpty)
        f.effects.uptime += SessionManager.keepAwakeRearm + 1
        m.apply(.hook(HookEvent(agent: .claude, event: "PostToolUse")), to: hooked)
        #expect(f.effects.awakeRearmed == [1])
        // Lapsed meanwhile (a long quiet stretch): the next sign of work takes a new one.
        f.effects.awakeLapsed.insert(1)
        f.effects.uptime += SessionManager.keepAwakeRearm + 1
        m.apply(.hook(HookEvent(agent: .claude, event: "PostToolUse")), to: hooked)
        #expect(f.effects.awake.count == 2 && m.isKeepingAwake)
        // An attached background job and its session count once.
        let job = BackgroundAgent(id: "j9", sessionId: "j9-s", name: "job", cwd: f.dir.path, state: "working")
        m.applyBackground([job])
        let attachedCount = m.workingAgents
        #expect(attachedCount == 2)  // the hooked session + the (not attached) job
        m.prepareForTermination()
    }

    @Test func failedAssertionIsRetriedOnlyAfterAWhile() throws {
        var tries = 0
        let f = Fixture { $0.power = PowerAssertion(acquire: { _, _, _ in tries += 1; return nil }, rearm: { _, _ in false }, release: { _ in }) }
        defer { f.cleanup() }
        let m = f.manager!
        m.setKeepAwake(true)
        m.newSession(agent: .claude, cwd: f.dir.path)
        let id = try #require(f.selected)
        m.apply(.hook(HookEvent(agent: .claude, event: "UserPromptSubmit")), to: id)
        m.apply(.hook(HookEvent(agent: .claude, event: "PostToolUse")), to: id)
        #expect(tries == 1 && !m.isKeepingAwake)
        f.effects.uptime += SessionManager.keepAwakeRearm + 1
        m.apply(.hook(HookEvent(agent: .claude, event: "PostToolUse")), to: id)
        #expect(tries == 2)
    }

    @Test func agentsNotSetUpHereGetNoInstallButtonOrBanner() throws {
        let f = Fixture { $0.agentPresent = { agent, _ in agent == .claude } }
        defer { f.cleanup() }
        #expect(f.manager.missingIntegrations == [.claude])
        let w = SettingsWindowController(manager: f.manager)
        #expect(w.installButtons[.claude]?.isHidden == false)
        #expect(w.installButtons[.pi]?.isHidden == true && w.installedLabels[.pi]?.isHidden == true)
        #expect(w.agentHeaders[.pi]?.caption.hasPrefix("Not set up on this Mac") == true)
        #expect(w.agentHeaders[.claude]?.caption.contains("backed up") == true)
        _ = try Integrations.installClaude(settingsURL: f.env.integrationPaths.claudeSettings)
        f.manager.refreshIntegrations()
        #expect(f.manager.missingIntegrations.isEmpty)
        #expect(w.installedLabels[.claude]?.isHidden == false)
    }

    @Test func liveCaptionsFollowStatusAndShortcuts() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let (store, suite) = store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let saved = NSApplication.shared.mainMenu
        defer { NSApplication.shared.mainMenu = saved }
        let menu = AppDelegate(makeTerminals: { FakeFactory() }).buildMenu()
        store.register(menu)
        NSApplication.shared.mainMenu = menu
        let w = SettingsWindowController(manager: f.manager, shortcuts: store)
        #expect(w.searchRow.caption.contains("⌘K"))
        store.set(KeyCombo(key: "g", mods: [.command, .shift]), for: NSStringFromSelector(#selector(MainWindowController.searchSessions(_:))))
        #expect(w.searchRow.caption.contains("⇧⌘G"))
        // While the window is up, status changes update the keep-awake line.
        let window = try #require(w.window)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        f.manager.setKeepAwake(true)
        #expect(w.keepAwakeSwitch.state == .on)
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "UserPromptSubmit")), to: try #require(f.selected))
        #expect(w.keepAwakeRow.caption.hasPrefix("Awake now: 1 agent is working."))
    }

    @Test func keepAwakeIsSavedWithTheWorkspace() throws {
        let f = Fixture()
        defer { f.cleanup() }
        f.manager.setKeepAwake(true)
        f.manager.saveNow(wait: true)
        let loaded = f.env.store.load()
        #expect(loaded.settings.keepAwake)
        // Older state files without settings load with the default.
        let old = try JSONDecoder().decode(Workspace.self, from: Data("{\"version\":1}".utf8))
        #expect(old.settings == AppSettings())
        let partial = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(!partial.keepAwake && !partial.keepDisplayOn)
        #expect(AppSettings(keepAwake: true) != AppSettings())
    }

    @Test func systemPowerAssertionTakesRearmsAndReleases() throws {
        for display in [false, true] {
            let id = try #require(PowerAssertion.system.acquire("Corral test assertion", display, 30))
            #expect(PowerAssertion.system.rearm(id, 30))
            PowerAssertion.system.release(id)
            #expect(!PowerAssertion.system.rearm(id, 30))
        }
    }
}
