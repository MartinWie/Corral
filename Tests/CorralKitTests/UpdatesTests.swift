import AppKit
import Testing
@testable import CorralKit

final class FakeUpdater: AppUpdater {
    var automaticallyChecks = true
    var lastCheck: Date?
    var checks = 0
    func checkForUpdates() { checks += 1 }
}

@MainActor
struct UpdatesTests {
    @Test func menuOffersCheckForUpdatesOnlyWithAnUpdater() throws {
        let plain = AppDelegate(makeTerminals: { FakeFactory() }).buildMenu()
        #expect(plain.items[0].submenu?.items.contains { $0.title == "Check for Updates…" } == false)

        let updater = FakeUpdater()
        let app = AppDelegate(makeTerminals: { FakeFactory() }, updater: updater)
        let items = try #require(app.buildMenu().items[0].submenu?.items)
        #expect(items.map(\.title).prefix(2) == ["About Corral", "Check for Updates…"])
        app.checkForUpdates(nil)
        #expect(updater.checks == 1)
    }

    @Test func generalPageHasUpdatesOnlyWithAnUpdater() {
        let f = Fixture()
        defer { f.cleanup() }
        #expect(SettingsWindowController(manager: f.manager).updatesRow == nil)

        let updater = FakeUpdater()
        let w = SettingsWindowController(manager: f.manager, updater: updater)
        w.refresh()
        #expect(w.autoUpdateSwitch.state == .on)
        #expect(w.updatesRow?.caption == "Once a day, from GitHub. Last checked: never.")

        w.autoUpdateSwitch.state = .off
        w.autoUpdateChanged(w.autoUpdateSwitch)
        #expect(!updater.automaticallyChecks)
        updater.lastCheck = Date().addingTimeInterval(-3 * 3600)
        w.refresh()
        #expect(w.autoUpdateSwitch.state == .off)
        #expect(w.updatesRow?.caption == "Once a day, from GitHub. Last checked: 3h ago.")

        w.checkForUpdatesNow(nil)
        #expect(updater.checks == 1)
    }

    @Test func versionText() {
        #expect(UpdateText.version(["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "12"]) == "0.1.0 (12)")
        #expect(UpdateText.version(["CFBundleShortVersionString": "0.1.0"]) == "0.1.0")
        #expect(UpdateText.version([:]) == "?")
    }
}
