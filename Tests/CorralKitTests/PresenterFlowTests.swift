import AppKit
@testable import CorralCore
import Testing
@testable import CorralKit

/// Sheet and open-panel flows, answered through Presenter (nothing is shown).
@MainActor
@Suite(.serialized)
struct PresenterFlowTests {
    func answer(_ response: NSApplication.ModalResponse, text: String? = nil) {
        Presenter.alert = { alert, _, done in
            if let text { (alert.accessoryView as? NSTextField)?.stringValue = text }
            done(response)
        }
    }

    func choose(_ url: URL?) {
        Presenter.openPanel = { _, _, done in done(url) }
    }

    @Test func newSessionInChosenDirectory() {
        let f = Fixture()
        defer { f.cleanup() }
        let w = MainWindowController(manager: f.manager)
        choose(nil)
        w.newInDirectory(nil)
        #expect(f.manager.live.isEmpty)
        choose(f.dir)
        w.newInDirectory(nil)
        #expect(f.terminal(f.selected)?.launch.cwd == f.dir.path)
        answer(.alertFirstButtonReturn, text: "Named folder")
        w.newFolder(nil)
        #expect(f.manager.workspace.folders.values.contains { $0.name == "Named folder" })
        w.renameSession(nil)
        #expect(f.manager.workspace.sessions[f.selected!]?.customName == "Named folder")
        var confirmed: Bool?
        answer(.alertSecondButtonReturn)
        w.confirm(title: "t", message: "m", button: "b") { confirmed = $0 }
        #expect(confirmed == false)
    }

    @Test func settingsChooseDirectory() {
        let f = Fixture()
        defer { f.cleanup() }
        let s = SettingsWindowController(manager: f.manager)
        let button = NSButton()
        button.tag = AgentKind.allCases.firstIndex(of: .pi)!
        choose(f.dir)
        s.chooseDirectory(button)
        #expect(f.manager.workspace.defaults(for: .pi).directory == f.dir.path)
        choose(nil)
        s.chooseDirectory(button)
        #expect(f.manager.workspace.defaults(for: .pi).directory == f.dir.path)
    }

    @Test func sidebarSheets() {
        let f = Fixture()
        defer { f.cleanup() }
        let s = SidebarViewController(manager: f.manager)
        _ = s.view
        let folder = f.manager.newFolder(name: "F")
        let item = NSMenuItem()
        item.representedObject = folder
        choose(f.dir)
        s.setFolderDirectory(item)
        #expect(f.manager.workspace.folders[folder]?.directory == f.dir.path)
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        f.manager.close(f.selected!)
        answer(.alertSecondButtonReturn)
        s.forgetAllClosed()
        #expect(!f.manager.workspace.closedSessions.isEmpty)
        answer(.alertFirstButtonReturn)
        s.forgetAllClosed()
        #expect(f.manager.workspace.closedSessions.isEmpty)
        answer(.alertSecondButtonReturn, text: "ignored")
        s.newFolderAtRoot()
        #expect(f.manager.workspace.folders.count == 1)
        answer(.alertFirstButtonReturn, text: "Second")
        s.newFolderAtRoot()
        #expect(f.manager.workspace.folders.count == 2)
    }

    @Test func benchModeRunsAndFinishes() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        f.factory.emitReady = true
        let d = AppDelegate(makeTerminals: { f.factory })
        let out = f.dir.appendingPathComponent("bench.json")
        d.benchOutput = out.path
        d.configureBench = { b in
            b.sessionCount = 2
            b.commandRounds = 1
            b.idleSeconds = 0.05
            b.readyTimeout = 0.2
            b.tabCheck = false  // needs a real shell
        }
        var finished = false
        d.onBenchFinished = { finished = true }
        d.launch()
        await waitUntil(timeout: 10) { finished }
        #expect(finished)
        #expect(FileManager.default.fileExists(atPath: out.path))
        #expect(d.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        d.main.window?.orderOut(nil)
        d.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    }
}
