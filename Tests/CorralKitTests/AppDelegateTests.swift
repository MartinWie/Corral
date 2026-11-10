import AppKit
@testable import CorralCore
import Testing
@testable import CorralKit

@MainActor
struct AppDelegateTests {
    @Test func menuHasCorralShortcuts() {
        _ = NSApplication.shared  // buildMenu registers the Window and Help menus with NSApp
        let d = AppDelegate(makeTerminals: { FakeFactory() })
        let menu = d.buildMenu()
        let all = menu.items.flatMap { $0.submenu?.items ?? [] }
        func key(_ title: String) -> String? { all.first { $0.title == title }?.keyEquivalent }
        #expect(key("Search All Sessions…") == "k")
        #expect(key("Clear Screen") == "k")
        #expect(key("Next Session Needing Input") == "i")
        #expect(key("Settings…") == ",")
        #expect(key("New Claude Session") == "c")
        #expect(all.filter { $0.title.hasPrefix("Session ") }.count == 8)
        #expect(key("Last Session") == "9")
        // The Corral menu stays short: setup lives in Settings.
        let corral = menu.items.first?.submenu?.items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(corral == ["About Corral", "Settings…", "Open Ghostty Config", "Reload Ghostty Config",
                           "Hide Corral", "Hide Others", "Quit Corral"])
        // Import from claude-sessions is shown only when that tracker is installed (always in the menu,
        // so a custom shortcut for it survives a launch without the tracker).
        d.trackerAvailable = { false }
        let hidden = d.buildMenu().items[1].submenu?.items.suffix(2) ?? []
        #expect(hidden.last?.title == "Import from claude-sessions…" && hidden.allSatisfy(\.isHidden))
        d.trackerAvailable = { true }
        #expect(d.buildMenu().items[1].submenu?.items.suffix(2).allSatisfy { !$0.isHidden } == true)
    }

    /// A second copy (e.g. opened from the DMG) hands over to the running Corral instead of sharing its state.
    @Test func secondInstanceBringsTheFirstForwardAndQuits() {
        let d = AppDelegate(makeTerminals: { FakeFactory() })
        var activated = false, quits = 0
        d.otherInstance = { { activated = true } }
        d.quit = { quits += 1 }
        d.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        #expect(activated && quits == 1 && d.manager == nil)
        #expect(d.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
    }

    @Test func installIntegrationsAndTerminationPrompts() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let env = f.env
        let d = AppDelegate(makeTerminals: { f.factory }, environment: { env })
        var alerts: [String] = []
        var answer: NSApplication.ModalResponse = .alertFirstButtonReturn
        d.runAlert = { alerts.append($0.messageText); return answer }
        d.launch(showWindow: false)
        defer { d.manager.prepareForTermination() }

        d.installIntegrations(nil)
        #expect(Integrations.status(paths: env.integrationPaths).allInstalled)
        #expect(d.manager.integrations.allInstalled)
        d.installIntegrations(nil)
        #expect(alerts.last == "All agent integrations are installed.")

        #expect(d.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        d.manager.newSession(agent: .claude, cwd: f.dir.path)
        d.manager.apply(.hook(HookEvent(agent: .claude, event: "UserPromptSubmit")), to: d.manager.workspace.selected!)
        answer = .alertSecondButtonReturn
        #expect(d.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        answer = .alertFirstButtonReturn
        #expect(d.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        d.openGhosttyConfig(nil)
        d.reloadGhosttyConfig(nil)
    }

    @Test func missingTerminalEngineIsReported() {
        let d = AppDelegate(makeTerminals: { nil })
        var shown = 0
        d.runAlert = { _ in shown += 1; return .alertFirstButtonReturn }
        d.launch(showWindow: false, terminateOnFailure: false)
        #expect(shown == 1)
    }
}
