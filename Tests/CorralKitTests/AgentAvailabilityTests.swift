import AppKit
@testable import CorralCore
import Testing
@testable import CorralKit

/// Only installed agents are offered (menus, empty window, folder menus); Settings greys the rest out.
@MainActor
@Suite(.serialized)
struct AgentAvailabilityTests {
    final class Present { var agents: Set<AgentKind> = [.claude] }

    func fixture(_ present: Present) -> Fixture {
        Fixture {
            $0.agentPresent = { agent, _ in present.agents.contains(agent) }
            $0.agentInstalled = { agent, _ in present.agents.contains(agent) }
        }
    }

    @Test func installedFollowsCommandOnPathOrConfigFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("corral-inst-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let paths = Integrations.Paths(claudeSettings: dir.appendingPathComponent("claude/settings.json"),
                                       opencodePluginDir: dir.appendingPathComponent("opencode/plugins"),
                                       piExtensionDir: dir.appendingPathComponent("pi/agent/extensions"))
        func installed(_ agent: AgentKind, _ path: String?, fallbacks: [String] = []) -> Bool {
            Integrations.installed(agent, paths: paths, path: path, fallbacks: fallbacks)
        }
        #expect(!installed(.opencode, bin.path))
        // A plain file isn't a command; an executable one is, on PATH or in a fallback folder.
        let opencode = bin.appendingPathComponent("opencode")
        try Data().write(to: opencode)
        #expect(!installed(.opencode, bin.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: opencode.path)
        #expect(installed(.opencode, "/nowhere:\(bin.path)"))
        #expect(!installed(.opencode, "relative/bin"))
        #expect(installed(.opencode, nil, fallbacks: [bin.path]))
        // A folder named like the command doesn't count.
        try FileManager.default.createDirectory(at: bin.appendingPathComponent("pi"), withIntermediateDirectories: true)
        #expect(!installed(.pi, bin.path))
        // No command, but its config folder: set up here.
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("claude"), withIntermediateDirectories: true)
        #expect(installed(.claude, nil))
        #expect(installed(.shell, nil))
    }

    @Test func managerTracksInstalledAgentsAndSaysWhenTheyChange() {
        let present = Present()
        let f = fixture(present)
        defer { f.cleanup() }
        #expect(f.manager.installedAgents == [.shell, .claude])
        var changes = 0
        f.manager.observe { if case .integrations = $0 { changes += 1 } }
        f.manager.refreshInstalledAgents()
        #expect(changes == 0)
        present.agents = [.claude, .pi]
        f.manager.refreshInstalledAgents()
        #expect(f.manager.installedAgents == [.shell, .claude, .pi] && changes == 1)
        #expect(f.manager.missingIntegrations == [.claude, .pi])
    }

    @Test func menusOfferOnlyInstalledAgents() throws {
        let present = Present()
        let f = fixture(present)
        defer { f.cleanup() }
        let env = f.env
        let app = AppDelegate(makeTerminals: { f.factory }, environment: { env })
        app.launch(showWindow: false)
        defer { app.manager.prepareForTermination() }
        let menu = try #require(app.mainMenu)
        let items = menu.items.flatMap { $0.submenu?.items ?? [] }
        func hidden(_ agent: AgentKind) -> Bool? { items.first { $0.action == agent.newSessionAction }?.isHidden }
        #expect(hidden(.shell) == false && hidden(.claude) == false)
        #expect(hidden(.opencode) == true && hidden(.pi) == true)
        // Hidden items' shortcuts don't start the agent either.
        let main = try #require(app.main)
        let pi = try #require(items.first { $0.action == AgentKind.pi.newSessionAction })
        let claude = try #require(items.first { $0.action == AgentKind.claude.newSessionAction })
        #expect(!main.validateMenuItem(pi) && main.validateMenuItem(claude))

        // The toolbar's + menu.
        let toolbar = ToolbarDelegate(owner: main)
        toolbar.showInstalledAgents()
        let plus = toolbar.newMenu.items.filter { AgentKind.startedBy($0.action) != nil }
        #expect(plus.filter { !$0.isHidden }.compactMap { AgentKind.startedBy($0.action) } == [.shell, .claude])

        // The empty window: shell and Claude Code, one row.
        main.container.placeholder.showAgents(app.manager.installedAgents)
        #expect(main.container.placeholder.shownTiles.map(\.title) == ["New Shell", "Claude Code"])
        #expect(main.container.placeholder.tileGrid.numberOfRows == 1)
        func tilesInGrid() -> [String] {
            main.container.placeholder.tiles.filter { $0.superview != nil }.map(\.title)
        }

        // Installed while Corral ran: everything follows.
        present.agents = [.claude, .opencode, .pi]
        app.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        #expect(hidden(.opencode) == false && hidden(.pi) == false)
        #expect(main.container.placeholder.shownTiles.count == 4 && main.container.placeholder.tileGrid.numberOfRows == 2)
        #expect(tilesInGrid().count == 4)
        present.agents = [.claude, .opencode]
        app.manager.refreshInstalledAgents()
        // Three tiles: the odd last one spans both columns.
        let grid = main.container.placeholder.tileGrid
        #expect(grid.numberOfRows == 2 && grid.cell(atColumnIndex: 0, rowIndex: 1).xPlacement == .center)
        #expect(main.container.placeholder.shownTiles.map(\.title) == ["New Shell", "Claude Code", "OpenCode"])
        // The gone agent's tile leaves the grid (removeRow alone would leave it there, clickable).
        #expect(tilesInGrid() == ["New Shell", "Claude Code", "OpenCode"])
    }

    @Test func directoryDialogOffersOnlyInstalledAgents() {
        let present = Present()
        let f = fixture(present)
        defer { f.cleanup() }
        let w = MainWindowController(manager: f.manager)
        let saved = Presenter.openPanel
        defer { Presenter.openPanel = saved }
        var titles: [String] = []
        Presenter.openPanel = { panel, _, done in
            titles = (panel.accessoryView as? NSPopUpButton)?.itemTitles ?? []
            done(f.dir)
        }
        w.newInDirectory(nil)
        #expect(titles == ["Shell", "Claude Code"])
    }

    @Test func folderMenuOffersOnlyInstalledAgents() {
        let present = Present()
        present.agents = [.opencode]
        let f = fixture(present)
        defer { f.cleanup() }
        let s = SidebarViewController(manager: f.manager)
        _ = s.view
        let folder = f.manager.newFolder(name: "F")
        let menu = NSMenu()
        s.populate(menu, for: s.node(.folder(folder)))
        #expect(!menu.items.map(\.title).contains("New Claude Session Here"))
        let sub = menu.items.first { $0.title == "Default Folder for New" }?.submenu?.items.map(\.title)
        #expect(sub == ["Shells", "OpenCode Sessions"])
        // A default folder set before the agent went away can still be unchecked.
        f.manager.setAgentDefaults(AgentDefaults(folder: folder), for: .pi)
        s.populate(menu, for: s.node(.folder(folder)))
        let again = menu.items.first { $0.title == "Default Folder for New" }?.submenu?.items
        #expect(again?.map(\.title) == ["Shells", "OpenCode Sessions", "PI Sessions"] && again?.last?.state == .on)
    }

    @Test func settingsGreyOutAgentsThatArentInstalled() {
        let present = Present()
        let f = fixture(present)
        defer { f.cleanup() }
        let suite = "corral-avail-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let app = AppDelegate(makeTerminals: { FakeFactory() }, shortcutDefaults: UserDefaults(suiteName: suite)!)
        app.shortcuts.register(app.buildMenu())
        let w = SettingsWindowController(manager: f.manager, shortcuts: app.shortcuts)
        w.refresh()
        #expect(w.agentLists[.claude]?.alphaValue == 1 && w.chooseButtons[.claude]?.isEnabled == true)
        #expect(w.agentLists[.pi]?.alphaValue == SettingsWindowController.unavailableAlpha)
        #expect(w.chooseButtons[.pi]?.isEnabled == false && w.folderPopups[.pi]?.isEnabled == false)
        #expect(w.agentHeaders[.pi]?.caption == SettingsWindowController.notInstalled)
        #expect(w.shortcutsView?.unavailable == [NSStringFromSelector(AgentKind.opencode.newSessionAction),
                                                 NSStringFromSelector(AgentKind.pi.newSessionAction)])
        present.agents = [.claude, .pi]
        f.manager.refreshIntegrations()
        #expect(w.agentLists[.pi]?.alphaValue == 1 && w.chooseButtons[.pi]?.isEnabled == true)
        #expect(w.shortcutsView?.unavailable == [NSStringFromSelector(AgentKind.opencode.newSessionAction)])
    }

    /// Settings › Agents › Remove: asks, takes the hooks out, and the sidebar stops offering them.
    @Test func removingHooksAsksAndStopsTheBanner() throws {
        let present = Present()
        present.agents = [.claude, .opencode]
        let f = fixture(present)
        defer { f.cleanup() }
        let paths = f.env.integrationPaths
        _ = try Integrations.installClaude(settingsURL: paths.claudeSettings)
        f.manager.refreshIntegrations()
        let w = SettingsWindowController(manager: f.manager)
        w.refresh()
        #expect(w.installedLabels[.claude]?.isHidden == false && w.removeButtons[.claude] != nil)
        let saved = Presenter.alert
        defer { Presenter.alert = saved }
        var asked: [String] = []
        var answer = NSApplication.ModalResponse.alertSecondButtonReturn
        Presenter.alert = { alert, _, done in asked.append(alert.messageText); done(answer) }
        let remove = try #require(w.removeButtons[.claude])
        w.removeIntegration(remove)
        #expect(asked == ["Remove the Claude Code status hooks?"] && f.manager.integrations.claude)
        answer = .alertFirstButtonReturn
        w.removeIntegration(remove)
        #expect(!f.manager.integrations.claude && f.manager.workspace.settings.hooksRemoved == [.claude])
        // The banner offers only OpenCode now; Settings can still install Claude's again.
        #expect(f.manager.missingIntegrations == [.opencode])
        #expect(w.installButtons[.claude]?.isHidden == false && w.installedLabels[.claude]?.isHidden == true)
        let install = try #require(w.installButtons[.claude])
        w.installIntegration(install)
        #expect(f.manager.integrations.claude && f.manager.workspace.settings.hooksRemoved.isEmpty)
        #expect(SettingsWindowController.removeText(.claude).contains("backed up"))
    }

    @Test func installPromptNamesTheAgentsWithoutPaths() {
        #expect(AppDelegate.integrationText([.opencode]).hasPrefix("Corral adds status hooks to OpenCode, so"))
        #expect(!AppDelegate.integrationText([.opencode]).contains("backed up"))
        let all = AppDelegate.integrationText([.claude, .opencode, .pi])
        #expect(all.contains("to Claude Code, OpenCode and PI, so") && all.contains("backed up first"))
        #expect(!all.contains("/") && !all.contains("~"))
    }

    final class ClosingWindow: NSWindow {
        var closes = 0, cancels = 0
        var parentForTest: NSWindow?
        override func performClose(_ sender: Any?) { closes += 1 }
        override func cancelOperation(_ sender: Any?) { cancels += 1 }
        override var sheetParent: NSWindow? { parentForTest }
    }

    /// ⌘W closes the window in front (Settings, About), never the session behind it.
    @Test func commandWClosesTheWindowInFront() {
        let f = Fixture()
        defer { f.cleanup() }
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        let id = f.manager.workspace.selected!
        let about = ClosingWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        let main = MainWindowController(manager: f.manager)
        main.keyWindow = { about }
        main.closeSession(nil)
        #expect(about.closes == 1 && f.manager.workspace.sessions[id]?.closedAt == nil)

        let app = AppDelegate(makeTerminals: { FakeFactory() })
        app.keyWindow = { about }
        app.closeFrontWindow(nil)
        #expect(about.closes == 2)
        // A panel without a close button (search) is cancelled, not the session behind it.
        let panel = ClosingWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        main.keyWindow = { panel }
        main.closeSession(nil)
        #expect(panel.cancels == 1 && panel.closes == 0 && f.manager.workspace.sessions[id]?.closedAt == nil)
        // A sheet in front: nothing closes (closing it directly would skip endSheet).
        let sheet = ClosingWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        sheet.parentForTest = main.window
        main.keyWindow = { sheet }
        main.closeSession(nil)
        #expect(sheet.closes == 0 && sheet.cancels == 0 && f.manager.workspace.sessions[id]?.closedAt == nil)
        // Main window in front: the session closes as before.
        main.keyWindow = { main.window }
        main.closeSession(nil)
        #expect(f.manager.workspace.sessions[id]?.closedAt != nil || f.manager.workspace.sessions[id] == nil)
    }
}
