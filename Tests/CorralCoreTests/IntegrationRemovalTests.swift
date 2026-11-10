import Foundation
import Testing
@testable import CorralCore

/// Removing the status hooks takes out only Corral's parts and keeps a backup of Claude's settings.
struct IntegrationRemovalTests {
    func dir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("corral-rm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func claudeKeepsEverythingButCorralsHooks() throws {
        let d = try dir()
        defer { try? FileManager.default.removeItem(at: d) }
        let settings = d.appendingPathComponent("settings.json")
        // The user's own Stop hook, one in a group Corral shares, and an unrelated setting.
        let mine = ["type": "command", "command": "say done"]
        let user: [String: Any] = ["model": "opus", "hooks": ["Stop": [["hooks": [mine]]]]]
        try JSONSerialization.data(withJSONObject: user).write(to: settings)
        _ = try Integrations.installClaude(settingsURL: settings)
        #expect(Integrations.status(paths: .init(claudeSettings: settings, opencodePluginDir: d, piExtensionDir: d)).claude)

        let backup = try #require(try Integrations.uninstallClaude(settingsURL: settings))
        #expect(FileManager.default.fileExists(atPath: backup.path))
        let after = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        #expect(after["model"] as? String == "opus")
        let hooks = try #require(after["hooks"] as? [String: Any])
        #expect(Array(hooks.keys) == ["Stop"])
        let stop = try #require(hooks["Stop"] as? [[String: Any]])
        #expect((stop.first?["hooks"] as? [[String: String]]) == [mine])
        #expect(!Integrations.status(paths: .init(claudeSettings: settings, opencodePluginDir: d, piExtensionDir: d)).claude)
        // Nothing left to remove: no rewrite, no backup.
        #expect(try Integrations.uninstallClaude(settingsURL: settings) == nil)
        // Only Corral's hooks: the hooks key goes entirely.
        try Data("{}".utf8).write(to: settings)
        _ = try Integrations.installClaude(settingsURL: settings)
        _ = try Integrations.uninstallClaude(settingsURL: settings)
        let bare = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        #expect(bare.isEmpty)
    }

    @Test func claudeRefusesSettingsItDoesntUnderstand() throws {
        let d = try dir()
        defer { try? FileManager.default.removeItem(at: d) }
        let settings = d.appendingPathComponent("settings.json")
        try Data(#"{"hooks": [1, 2]}"#.utf8).write(to: settings)
        #expect(throws: Integrations.InstallError.self) { try Integrations.uninstallClaude(settingsURL: settings) }
        #expect(try String(contentsOf: settings, encoding: .utf8) == #"{"hooks": [1, 2]}"#)
    }

    @Test func pluginsAreRemovedOnlyWhenTheyAreCorrals() throws {
        let d = try dir()
        defer { try? FileManager.default.removeItem(at: d) }
        let oc = d.appendingPathComponent("plugins"), pi = d.appendingPathComponent("extensions")
        try Integrations.installOpenCode(pluginDir: oc)
        try Integrations.installPi(extensionDir: pi)
        try Integrations.uninstallOpenCode(pluginDir: oc)
        try Integrations.uninstallPi(extensionDir: pi)
        #expect(!FileManager.default.fileExists(atPath: oc.appendingPathComponent("corral.js").path))
        #expect(!FileManager.default.fileExists(atPath: pi.appendingPathComponent("corral.ts").path))
        // Already gone: fine. Someone else's corral.js: left alone.
        try Integrations.uninstallOpenCode(pluginDir: oc)
        try Data("export const Mine = 1\n".utf8).write(to: oc.appendingPathComponent("corral.js"))
        #expect(throws: Integrations.InstallError.self) { try Integrations.uninstallOpenCode(pluginDir: oc) }
        #expect(FileManager.default.fileExists(atPath: oc.appendingPathComponent("corral.js").path))
    }

    @Test func removedHooksSurviveASaveAndOldFilesDecode() throws {
        var ws = Workspace()
        ws.settings.hooksRemoved = [.claude]
        let d = try dir()
        defer { try? FileManager.default.removeItem(at: d) }
        let store = WorkspaceStore(url: d.appendingPathComponent("state.json"))
        try store.save(ws)
        #expect(store.load().settings.hooksRemoved == [.claude])
        try Data(#"{"settings": {"keepAwake": true}}"#.utf8).write(to: store.url)
        #expect(store.load().settings.hooksRemoved.isEmpty && store.load().settings.keepAwake)
    }
}
