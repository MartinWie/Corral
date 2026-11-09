import Foundation
@testable import CorralCore
import Testing

/// Locates and runs the built C `corral-hook`.
enum HookBinary {
    static var path: URL? {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = ["out/Products/Release", "out/Products/Debug", "release", "debug"]
            .map { root.appendingPathComponent(".build/\($0)/corral-hook") }
            .filter { FileManager.default.isExecutableFile(atPath: $0.path) }
        return candidates.max { (mtime($0) ?? .distantPast) < (mtime($1) ?? .distantPast) }
    }

    static func mtime(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    @discardableResult
    static func run(_ bin: URL, args: [String], env: [String: String], stdin: Data?) throws -> Int32 {
        let p = Process()
        p.executableURL = bin
        p.arguments = args
        // Coverage builds would otherwise drop default.profraw into the working directory.
        p.environment = env.merging(["LLVM_PROFILE_FILE": "/dev/null"]) { a, _ in a }
        let input = Pipe()
        let output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        try p.run()
        if let stdin { input.fileHandleForWriting.write(stdin) }
        try input.fileHandleForWriting.close()
        p.waitUntilExit()
        #expect(output.fileHandleForReading.readDataToEndOfFile().isEmpty, "hooks must print nothing")
        return p.terminationStatus
    }
}

@Suite(.serialized)
struct HookBinaryTests {
    func withServer(_ body: (String, () async -> [HookWire.Message]) async throws -> Void) async throws {
        let path = NSTemporaryDirectory() + "hk-\(UInt32.random(in: 0...UInt32.max)).sock"
        let box = Box()
        let server = EventServer(path: path) { box.messages.append($0) }
        try server.start()
        defer { server.stop() }
        try await body(path) {
            for _ in 0..<100 where box.messages.isEmpty {
                try? await Task.sleep(for: .milliseconds(10))
                await MainActor.run {}
            }
            return box.messages
        }
    }

    final class Box: @unchecked Sendable { var messages: [HookWire.Message] = [] }

    /// The direct-launch script's exit report, end to end: zsh → real corral-hook → socket → decoder.
    @Test func launchScriptReportsAgentExit() async throws {
        let hook = try #require(HookBinary.path)
        let surface = UUID()
        try await withServer { socket, received in
            // Stand-in shell: runs the inner script without rc files, and the follow-up `-l` just ends the run.
            let shell = NSTemporaryDirectory() + "corral-stub-zsh-\(UUID().uuidString)"
            try "#!/bin/sh\n[ \"$1\" = -lic ] && exec /bin/zsh -f -c \"$2\"\nexit 0\n"
                .write(toFile: shell, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell)
            defer { try? FileManager.default.removeItem(atPath: shell) }
            let script = AgentLaunch.outerScript(input: "(exit 7)", shell: shell, agent: .opencode)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-f", "-c", script]
            p.environment = ["CORRAL_SURFACE_ID": surface.uuidString, "CORRAL_SOCKET": socket, "CORRAL_HOOK": hook.path,
                             "LLVM_PROFILE_FILE": "/dev/null", "PATH": "/usr/bin:/bin"]
            let out = Pipe()
            p.standardOutput = out
            try p.run()
            p.waitUntilExit()
            #expect(p.terminationStatus == 0)
            #expect(out.fileHandleForReading.readDataToEndOfFile().isEmpty, "the report prints nothing")
            let m = try #require(await received().first)
            #expect(m.surface == surface)
            #expect(m.event.agent == .opencode)
            #expect(m.event.event == AgentLaunch.exitEvent)
            #expect(m.event.exitCode == 7)
        }
    }

    @Test func forwardsPayloadWithEventName() async throws {
        let hook = try #require(HookBinary.path)
        let surface = UUID()
        try await withServer { socket, received in
            let payload = #"{"session_id":"abc","cwd":"/repo","notification_type":"permission_prompt","message":"line1\nline2 \"q\""}"#
            let status = try HookBinary.run(hook, args: ["claude", "Notification"],
                                            env: ["CORRAL_SURFACE_ID": surface.uuidString, "CORRAL_SOCKET": socket],
                                            stdin: Data(payload.utf8))
            #expect(status == 0)
            let msgs = await received()
            let m = try #require(msgs.first)
            #expect(m.surface == surface)
            #expect(m.event.event == "Notification")
            #expect(m.event.sessionId == "abc")
            #expect(m.event.notificationType == "permission_prompt")
            #expect(m.event.message == "line1\nline2 \"q\"")
        }
    }

    @Test func oversizedOrInvalidPayloadStillReportsEvent() async throws {
        let hook = try #require(HookBinary.path)
        let surface = UUID()
        try await withServer { socket, received in
            let huge = Data(("{\"tool_response\":\"" + String(repeating: "x", count: 1_200_000) + "\"}").utf8)
            try HookBinary.run(hook, args: ["claude", "PostToolUse"],
                               env: ["CORRAL_SURFACE_ID": surface.uuidString, "CORRAL_SOCKET": socket], stdin: huge)
            try HookBinary.run(hook, args: ["claude", "Stop"],
                               env: ["CORRAL_SURFACE_ID": surface.uuidString, "CORRAL_SOCKET": socket], stdin: Data("not json".utf8))
            var msgs: [HookWire.Message] = []
            for _ in 0..<100 where msgs.count < 2 {
                msgs = await received()
                try? await Task.sleep(for: .milliseconds(10))
            }
            #expect(msgs.map(\.event.event) == ["PostToolUse", "Stop"])
            #expect(msgs.allSatisfy { $0.event.sessionId == nil })
        }
    }

    @Test func scrubsNestedEnvironmentOnSessionStart() throws {
        let hook = try #require(HookBinary.path)
        let envFile = FileManager.default.temporaryDirectory.appendingPathComponent("envfile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: envFile) }
        try HookBinary.run(hook, args: ["claude", "SessionStart"],
                           env: ["CORRAL_SURFACE_ID": UUID().uuidString, "CORRAL_SOCKET": "/nonexistent.sock",
                                 "CLAUDE_ENV_FILE": envFile.path], stdin: Data("{}".utf8))
        #expect(try String(contentsOf: envFile, encoding: .utf8) == "unset CORRAL_SURFACE_ID CORRAL_HOOK CORRAL_SOCKET\n")
    }

    @Test func noOpOutsideCorralOrWithoutArgs() throws {
        let hook = try #require(HookBinary.path)
        #expect(try HookBinary.run(hook, args: ["claude", "Stop"], env: [:], stdin: Data("{}".utf8)) == 0)
        #expect(try HookBinary.run(hook, args: [], env: ["CORRAL_SURFACE_ID": "x"], stdin: nil) == 0)
        // Default socket under $HOME (absent here) and an over-long socket path are ignored quietly.
        #expect(try HookBinary.run(hook, args: ["pi"], env: ["CORRAL_SURFACE_ID": "x", "HOME": "/nonexistent"], stdin: nil) == 0)
        #expect(try HookBinary.run(hook, args: ["pi"], env: ["CORRAL_SURFACE_ID": "x",
                                                             "CORRAL_SOCKET": String(repeating: "/a", count: 100)], stdin: nil) == 0)
    }
}

@Suite(.serialized)
struct HookBinaryEdgeTests {
    let base = HookBinaryTests()

    @Test func prettyPrintedCRLFPayloadStaysOneLine() async throws {
        let hook = try #require(HookBinary.path)
        let surface = UUID()
        try await base.withServer { socket, received in
            let payload = "{\r\n  \"session_id\": \"abc\",\r\n  \"message\": \"a\\nb\"\r\n}\r\n"
            try HookBinary.run(hook, args: ["claude", "Notification"],
                               env: ["CORRAL_SURFACE_ID": surface.uuidString, "CORRAL_SOCKET": socket, "LLVM_PROFILE_FILE": "/dev/null"],
                               stdin: Data(payload.utf8))
            let m = try #require(await received().first)
            #expect(m.event.sessionId == "abc")
            #expect(m.event.message == "a\nb")
        }
    }

    @Test func brokenPayloadIsSentAsNull() async throws {
        let hook = try #require(HookBinary.path)
        let surface = UUID()
        try await base.withServer { socket, received in
            try HookBinary.run(hook, args: ["claude", "Stop"],
                               env: ["CORRAL_SURFACE_ID": surface.uuidString, "CORRAL_SOCKET": socket, "LLVM_PROFILE_FILE": "/dev/null"],
                               stdin: Data("{ \"a\": 1 } trailing".utf8))
            let m = try #require(await received().first)
            #expect(m.event.event == "Stop")
            #expect(m.event.sessionId == nil)
        }
    }

    @Test func stuckAppNeverStallsTheAgent() throws {
        let hook = try #require(HookBinary.path)
        // A listener that accepts but never reads, like a stopped app.
        let path = NSTemporaryDirectory() + "stuck-\(UInt32.random(in: 0...UInt32.max)).sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd); unlink(path) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            let bytes = Array(path.utf8)
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        listen(fd, 8)
        let big = Data(("{\"tool_response\":\"" + String(repeating: "y", count: 200_000) + "\"}").utf8)
        let t0 = Date()
        try HookBinary.run(hook, args: ["claude", "PostToolUse"],
                           env: ["CORRAL_SURFACE_ID": UUID().uuidString, "CORRAL_SOCKET": path, "LLVM_PROFILE_FILE": "/dev/null"], stdin: big)
        #expect(Date().timeIntervalSince(t0) < 1.0)
    }
}
