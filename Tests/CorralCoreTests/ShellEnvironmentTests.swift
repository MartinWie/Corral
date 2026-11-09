import Foundation
import Testing
@testable import CorralCore

/// The login shell's PATH and config variables for an app opened from Finder. Never touches the
/// process-wide `ShellEnvironment.shell` (other suites read it in parallel).
struct ShellEnvironmentTests {
    func tempHome(_ files: [String: String]) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("corral-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        for (name, text) in files { try text.write(to: home.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        return home
    }

    func processes(matching pattern: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", pattern]
        let out = Pipe()
        p.standardOutput = out
        try? p.run()
        p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    @Test func parseKeepsOnlyTheVariablesCorralUses() {
        let raw = "PATH=/opt/homebrew/bin:/usr/bin\0SECRET=x\0CLAUDE_CONFIG_DIR=/Users/me/.claude-alt\0XDG_DATA_HOME=/d\0junk\0"
        #expect(ShellEnvironment.parse(Data(raw.utf8)) == [
            "PATH": "/opt/homebrew/bin:/usr/bin", "CLAUDE_CONFIG_DIR": "/Users/me/.claude-alt", "XDG_DATA_HOME": "/d",
        ])
        #expect(ShellEnvironment.parse(Data()).isEmpty)
    }

    @Test func corralsOwnValuesWinExceptPath() {
        let shell = ["PATH": "/shell/bin:/usr/bin", "CLAUDE_CONFIG_DIR": "/shell/claude", "XDG_DATA_HOME": ""]
        let process = ["PATH": "/usr/bin:/bin", "CLAUDE_CONFIG_DIR": "/mine", "HOME": "/h"]
        #expect(ShellEnvironment.value("PATH", process: process, shell: shell) == "/shell/bin:/usr/bin")
        #expect(ShellEnvironment.value("CLAUDE_CONFIG_DIR", process: process, shell: shell) == "/mine")
        #expect(ShellEnvironment.value("CLAUDE_CONFIG_DIR", process: [:], shell: shell) == "/shell/claude")
        #expect(ShellEnvironment.value("XDG_DATA_HOME", process: [:], shell: shell) == nil)
        #expect(ShellEnvironment.value("PATH", process: process, shell: [:]) == "/usr/bin:/bin")
        let child = ShellEnvironment.childEnvironment(process: process, shell: shell)
        #expect(child["PATH"] == "/shell/bin:/usr/bin" && child["CLAUDE_CONFIG_DIR"] == "/mine" && child["HOME"] == "/h")
        // The CLI's own folder leads (node sits next to an npm shim), once.
        let first = ShellEnvironment.childEnvironment(first: "/usr/bin", process: process, shell: shell)
        #expect(first["PATH"] == "/usr/bin:/shell/bin")
        #expect(ShellEnvironment.childEnvironment(first: "/opt/node/bin", process: [:], shell: [:])["PATH"] == "/opt/node/bin")
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh", "/bin/bash", "/bin/ksh"])
    func probeReadsTheLoginShellsExports(shell: String) throws {
        let rc = "export CLAUDE_CONFIG_DIR=\"$HOME/.claude-alt\"\nexport PATH=\"$HOME/bin:$PATH\"\nset -- clobbered\necho noise\n"
        let home = try tempHome([".profile": rc, ".zshrc": rc, ".bash_profile": rc])
        defer { try? FileManager.default.removeItem(at: home) }
        // ZDOTDIR / HOME keep the machine's own rc files out.
        let env = ["HOME": home.path, "ZDOTDIR": home.path, "PATH": "/usr/bin:/bin", "ENV": ""]
        let values = try #require(ShellEnvironment.probe(shell: shell, timeout: 10, environment: env))
        #expect(values["CLAUDE_CONFIG_DIR"] == home.path + "/.claude-alt")
        #expect(values["PATH"]?.hasPrefix(home.path + "/bin:") == true)
    }

    @Test func theShellGetsNoneOfCorralsOpenFiles() throws {
        let fd = open("/dev/null", O_RDONLY)  // no O_CLOEXEC: a child would inherit it
        defer { close(fd) }
        #expect(fd > 2)
        let home = try tempHome([".profile": "[ -e /dev/fd/\(fd) ] && export CLAUDE_CONFIG_DIR=leaked\nexport XDG_DATA_HOME=ran\n"])
        defer { try? FileManager.default.removeItem(at: home) }
        let values = try #require(ShellEnvironment.probe(shell: "/bin/sh", timeout: 10, environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"]))
        #expect(values["XDG_DATA_HOME"] == "ran" && values["CLAUDE_CONFIG_DIR"] == nil)
    }

    @Test func backgroundJobsOfTheRcFilesGoWithTheShell() throws {
        let marker = "32.\(Int.random(in: 100_000...999_999))"
        let home = try tempHome([".profile": "sleep \(marker) &\nexport XDG_DATA_HOME=ran\n"])
        defer { try? FileManager.default.removeItem(at: home) }
        let values = ShellEnvironment.probe(shell: "/bin/sh", timeout: 10, environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
        #expect(values?["XDG_DATA_HOME"] == "ran")
        #expect(processes(matching: "sleep \(marker)").isEmpty)
    }

    @Test func aFailedFirstProbeIsRememberedSoLaterLaunchesDontWait() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("corral-env-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = dir.appendingPathComponent("shell-environment.json")
        #expect(ShellEnvironment.resolve(shell: "/usr/bin/nu", cache: cache, wait: 5).isEmpty)
        #expect(ShellEnvironment.load(cache) == [:])
    }

    @Test func shellsItCantDriveGiveNothing() {
        #expect(ShellEnvironment.probe(shell: "/usr/bin/nu", timeout: 1) == nil)
        #expect(ShellEnvironment.probe(shell: "/nonexistent/zsh", timeout: 1) == nil)
    }

    @Test func aHangingRcFileGivesUpInTimeAndLeavesNothingBehind() throws {
        let marker = "31.\(Int.random(in: 100_000...999_999))"
        let home = try tempHome([".profile": "sleep \(marker)\n"])
        defer { try? FileManager.default.removeItem(at: home) }
        let start = Date()
        #expect(ShellEnvironment.probe(shell: "/bin/sh", timeout: 0.5, environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"]) == nil)
        #expect(Date().timeIntervalSince(start) < 5)
        // The rc file's children went with the shell's process group.
        #expect(processes(matching: "sleep \(marker)").isEmpty)
    }

    @Test func resolveUsesTheCacheAndRefreshesItForNextTime() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("corral-env-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = try tempHome([".profile": "export CLAUDE_CONFIG_DIR=/fresh\n"])
        defer { try? FileManager.default.removeItem(at: home) }
        let env = ["HOME": home.path, "PATH": "/usr/bin:/bin", "ENV": ""]
        let cache = dir.appendingPathComponent("shell-environment.json")
        ShellEnvironment.save(["PATH": "/cached/bin"], to: cache)
        // This launch: the cache, at once. The next: what the shell says now.
        #expect(ShellEnvironment.resolve(shell: "/bin/sh", cache: cache, environment: env) == ["PATH": "/cached/bin"])
        for _ in 0..<100 where ShellEnvironment.load(cache)?["CLAUDE_CONFIG_DIR"] == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(ShellEnvironment.load(cache)?["CLAUDE_CONFIG_DIR"] == "/fresh")
        // A shell it can't probe keeps the cache.
        #expect(ShellEnvironment.resolve(shell: "/usr/bin/nu", cache: cache) == ShellEnvironment.load(cache))
        #expect(ShellEnvironment.load(dir.appendingPathComponent("missing.json")) == nil)
    }

    @Test func firstLaunchWaitsBrieflyAndASlowShellStillFillsTheCache() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("corral-env-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = try tempHome([".profile": "export CLAUDE_CONFIG_DIR=/quick\n"])
        defer { try? FileManager.default.removeItem(at: home) }
        let env = ["HOME": home.path, "PATH": "/usr/bin:/bin", "ENV": ""]
        // Quick: its values this launch.
        let quick = dir.appendingPathComponent("quick.json")
        #expect(ShellEnvironment.resolve(shell: "/bin/sh", cache: quick, wait: 10, environment: env)["CLAUDE_CONFIG_DIR"] == "/quick")
        #expect(ShellEnvironment.load(quick)?["CLAUDE_CONFIG_DIR"] == "/quick")
        // Slow to start: nothing this launch (no long wait), the cache for the next one.
        let script = dir.appendingPathComponent("sh")
        try "#!/bin/sh\nsleep 0.8\nexec /bin/sh \"$@\"\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let slow = dir.appendingPathComponent("slow.json")
        let start = Date()
        #expect(ShellEnvironment.resolve(shell: script.path, cache: slow, wait: 0.1, cap: 10, environment: env).isEmpty)
        #expect(Date().timeIntervalSince(start) < 0.7)
        for _ in 0..<100 where ShellEnvironment.load(slow) == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(ShellEnvironment.load(slow)?["CLAUDE_CONFIG_DIR"] == "/quick")
    }

    @Test func claudeIsFoundOnTheShellPathOrWhereInstallersPutIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("corral-bin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func install(_ dir: String) throws -> String {
            let d = root.appendingPathComponent(dir)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            let bin = d.appendingPathComponent("claude")
            try "#!/bin/sh\n".write(to: bin, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
            return bin.path
        }
        let fallback = root.appendingPathComponent("home/.volta/bin").path
        #expect(BackgroundAgents.claudeBinary(path: "/nowhere", fallbacks: [fallback]) == nil)
        let volta = try install("home/.volta/bin")
        #expect(BackgroundAgents.claudeBinary(path: "/nowhere", fallbacks: [fallback]) == volta)
        // The shell's PATH comes first.
        let nvm = try install("nvm/v22/bin")
        #expect(BackgroundAgents.claudeBinary(path: "\(root.path)/nvm/v22/bin:/usr/bin", fallbacks: [fallback]) == nvm)
        // Relative entries and a folder named claude don't count.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dirs/claude"), withIntermediateDirectories: true)
        #expect(BackgroundAgents.claudeBinary(path: "nvm/v22/bin::\(root.path)/dirs", fallbacks: [fallback]) == volta)
        #expect(BackgroundAgents.fallbackDirs(home: "/h").contains("/h/.local/bin"))
    }
}
