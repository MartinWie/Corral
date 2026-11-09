import AppKit
@testable import CorralCore
import Testing
@testable import CorralKit

/// What other Macs need: ssh without the ghostty CLI, no ~/.claude for people without Claude.
@MainActor
@Suite(.serialized)
struct DistributionTests {
    @Test func sshFeaturesAreTurnedOffKeepingTheRest() throws {
        // Bits: cursor, sudo, title, ssh-env, ssh-terminfo, path.
        let defaults: UInt32 = 0b100101
        #expect(GhosttyDefaults.shellFeaturesLine(defaults) == nil)
        #expect(GhosttyDefaults.shellFeaturesLine(nil) == nil)
        #expect(GhosttyDefaults.shellFeaturesLine(defaults | 1 << 3 | 1 << 4)
                == "shell-integration-features = cursor,no-sudo,title,no-ssh-env,no-ssh-terminfo,path")
        #expect(GhosttyDefaults.shellFeaturesLine(0b010011)
                == "shell-integration-features = cursor,sudo,no-title,no-ssh-env,no-ssh-terminfo,no-path")

        let saved = (GhosttyDefaults.userShellFeatures, GhosttyDefaults.unbinds)
        defer { (GhosttyDefaults.userShellFeatures, GhosttyDefaults.unbinds) = saved }
        GhosttyDefaults.unbinds = []
        GhosttyDefaults.userShellFeatures = defaults
        #expect(GhosttyDefaults.lateConfig == nil && GhosttyDefaults.defaultShellFeatures == defaults)
        // After includes (they could turn ssh-env on again), in its own file.
        GhosttyDefaults.userShellFeatures = defaults | 1 << 3
        GhosttyDefaults.unbinds = ["super+k"]
        #expect(!GhosttyDefaults.config.contains("shell-integration-features"))
        #expect(GhosttyDefaults.config.hasSuffix("keybind = super+k=unbind\n"))
        #expect(GhosttyDefaults.lateConfig?.hasSuffix("shell-integration-features = cursor,no-sudo,title,no-ssh-env,no-ssh-terminfo,path\n") == true)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("corral-late-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let late = try #require(GhosttyDefaults.writeLate(to: dir))
        #expect(try String(contentsOfFile: late, encoding: .utf8) == GhosttyDefaults.lateConfig)
        #expect(GhosttyDefaults.write(to: dir) != nil)
        #expect(GhosttyDefaults.writeLate(to: URL(fileURLWithPath: "/dev/null/x")) == nil)
    }

    /// `shellFeatureNames` must be Ghostty's `ShellIntegrationFeatures` fields, in order (the bits).
    @Test func shellFeatureNamesMatchGhosttysFields() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../vendor/ghostty/src/config/Config.zig")
        guard let text = try? String(contentsOf: source, encoding: .utf8),
              let start = text.range(of: "pub const ShellIntegrationFeatures = packed struct {"),
              let end = text.range(of: "};", range: start.upperBound..<text.endIndex) else { return }
        let fields = text[start.upperBound..<end.lowerBound].split(separator: "\n").compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let colon = t.firstIndex(of: ":"), !t.hasPrefix("//") else { return nil }
            return String(t[..<colon]).replacingOccurrences(of: "@\"", with: "").replacingOccurrences(of: "\"", with: "")
        }
        #expect(fields == GhosttyDefaults.shellFeatureNames)
    }

    @Test func theConfigToOpenIsPickedLikeGhosttyWithoutCreatingOne() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("corral-edit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(GhosttyDefaults.editableConfigPath(home: home, xdgConfig: nil) == "")
        #expect(!FileManager.default.fileExists(atPath: home.path))
        let support = home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty")
        let xdg = home.appendingPathComponent(".config/ghostty")
        for d in [support, xdg] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        func write(_ url: URL, _ text: String) throws { try text.write(to: url, atomically: true, encoding: .utf8) }
        // Only empty files: the first that exists (Application Support before XDG).
        try write(xdg.appendingPathComponent("config"), "")
        try write(support.appendingPathComponent("config"), "")
        #expect(GhosttyDefaults.editableConfigPath(home: home, xdgConfig: nil) == support.appendingPathComponent("config").path)
        // A non-empty one wins, wherever it is.
        try write(xdg.appendingPathComponent("config"), "font-size = 14\n")
        #expect(GhosttyDefaults.editableConfigPath(home: home, xdgConfig: nil) == xdg.appendingPathComponent("config").path)
        try write(support.appendingPathComponent("config.ghostty"), "theme = x\n")
        #expect(GhosttyDefaults.editableConfigPath(home: home, xdgConfig: nil) == support.appendingPathComponent("config.ghostty").path)
    }

    @Test func ghosttysDefaultFilesLoadOnlyWhenOneExists() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("corral-gh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(GhosttyDefaults.userConfigFiles(home: home, xdgConfig: nil).isEmpty)
        let support = home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try "font-size = 13\n".write(to: support.appendingPathComponent("config.ghostty"), atomically: true, encoding: .utf8)
        #expect(GhosttyDefaults.userConfigFiles(home: home, xdgConfig: nil) == [support.appendingPathComponent("config.ghostty").path])
        let xdg = home.appendingPathComponent("xdg")
        try FileManager.default.createDirectory(at: xdg.appendingPathComponent("ghostty"), withIntermediateDirectories: true)
        try "".write(to: xdg.appendingPathComponent("ghostty/config"), atomically: true, encoding: .utf8)
        #expect(GhosttyDefaults.userConfigFiles(home: home, xdgConfig: xdg.path).count == 2)
    }

    @Test func jobsFolderOnlyWhereClaudeIsSetUp() throws {
        let f = Fixture { env in
            env.jobsDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("corral-noclaude-\(UUID().uuidString)/.claude/jobs")
        }
        defer { f.cleanup() }
        f.manager.start()
        let claudeDir = f.env.jobsDir.deletingLastPathComponent()
        #expect(!FileManager.default.fileExists(atPath: claudeDir.path))
        // Claude installed later: the next activation sets the folder up.
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        f.manager.ensureWatchers()
        #expect(FileManager.default.fileExists(atPath: f.env.jobsDir.path))
        try? FileManager.default.removeItem(at: claudeDir.deletingLastPathComponent())
    }
}
