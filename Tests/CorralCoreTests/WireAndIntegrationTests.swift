import Foundation
import Testing
@testable import CorralCore

struct WireTests {
    @Test func decodeClaudeHook() throws {
        let surface = UUID()
        let payload: [String: Any] = [
            "session_id": "abc", "cwd": "/repo", "hook_event_name": "Notification",
            "notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash",
        ]
        let line = try #require(HookWire.encode(surface: surface.uuidString, agent: "claude", event: "", payload: payload))
        let msg = try #require(HookWire.decode(line: line.dropLast()))
        #expect(msg.surface == surface)
        #expect(msg.event.agent == .claude)
        #expect(msg.event.event == "Notification")
        #expect(msg.event.sessionId == "abc")
        #expect(msg.event.notificationType == "permission_prompt")
    }

    @Test func permissionRequestUsesToolName() throws {
        let line = try #require(HookWire.encode(surface: UUID().uuidString, agent: "claude", event: "PermissionRequest",
                                                payload: ["tool_name": "Bash"]))
        let msg = try #require(HookWire.decode(line: line))
        #expect(msg.event.message == "Permission: Bash")
    }

    @Test func permissionDetailsSayWhatTheToolWants() throws {
        func detail(_ tool: String, _ input: [String: Any]?) -> String { HookWire.permissionDetail(tool: tool, input: input) }
        #expect(detail("Bash", ["command": "git push\n  origin   main", "description": "Push"]) == "Bash: git push origin main")
        #expect(detail("Edit", ["file_path": "/repo/Sources/Model.swift"]) == "Edit: Model.swift")
        #expect(detail("NotebookEdit", ["notebook_path": "/n/a.ipynb"]) == "NotebookEdit: a.ipynb")
        #expect(detail("WebFetch", ["url": "https://docs.example.com/x?y"]) == "WebFetch: docs.example.com")
        #expect(detail("WebFetch", ["url": "not a url"]) == "WebFetch: not a url")
        #expect(detail("mcp__slack__post_message", ["query": "hi"]) == "slack post message: hi")
        #expect(detail("AskUserQuestion", ["questions": [["question": "Which   approach?", "header": "Approach"]]]) == "Which approach?")
        #expect(detail("AskUserQuestion", ["questions": [["header": "Approach"]]]) == "Approach")
        #expect(detail("AskUserQuestion", nil) == "Has a question")
        #expect(detail("ExitPlanMode", ["plan": "..."]) == "Plan ready for review")
        #expect(detail("Task", ["subagent_type": "x"]) == "Permission: Task")
        #expect(detail("Bash", ["command": "   "]) == "Permission: Bash")
        let long = detail("Bash", ["command": String(repeating: "a", count: 400)])
        #expect(long.count == 6 + 200 && long.hasSuffix("…"))

        let line = try #require(HookWire.encode(surface: UUID().uuidString, agent: "claude", event: "PermissionRequest",
                                                payload: ["tool_name": "AskUserQuestion",
                                                          "tool_input": ["questions": [["question": "Ship it?"]]]]))
        let msg = try #require(HookWire.decode(line: line))
        #expect(msg.event.tool == "AskUserQuestion" && msg.event.message == "Ship it?")
        let compact = try #require(HookWire.encode(surface: UUID().uuidString, agent: "claude", event: "PreCompact",
                                                   payload: ["trigger": "auto"]))
        #expect(HookWire.decode(line: compact)?.event.trigger == "auto")
    }

    @Test func rejectsGarbage() {
        #expect(HookWire.decode(line: Data("nope".utf8)) == nil)
        #expect(HookWire.decode(line: Data(#"{"surface":"x","agent":"claude","event":"Stop"}"#.utf8)) == nil)
        #expect(HookWire.decode(line: Data(#"{"surface":"\#(UUID().uuidString)","agent":"vim","event":"Stop"}"#.utf8)) == nil)
    }

    @Test func socketRoundTrip() async throws {
        let path = NSTemporaryDirectory() + "c-\(UInt32.random(in: 0...UInt32.max)).sock"
        let surface = UUID()
        try await confirmation { received in
            let server = EventServer(path: path) { msg in
                if msg.surface == surface && msg.event.event == "Stop" { received() }
            }
            try server.start()
            defer { server.stop() }
            let line = try #require(HookWire.encode(surface: surface.uuidString, agent: "claude", event: "Stop", payload: nil))
            #expect(EventClient.send(line, to: path))
            // Delivery hops to the main queue.
            for _ in 0..<50 {
                try await Task.sleep(for: .milliseconds(20))
                await MainActor.run {}
            }
        }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func clientFailsQuietlyWithoutServer() {
        #expect(!EventClient.send(Data("x\n".utf8), to: NSTemporaryDirectory() + "missing-\(UUID().uuidString.prefix(8)).sock"))
    }
}

struct IntegrationTests {
    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func claudeHooksMergeKeepsExistingAndIsIdempotent() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = dir.appendingPathComponent("settings.json")
        let existing = #"""
        {"model":"opus","hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/usr/bin/python3 $HOME/.local/bin/claude-sessions hook","timeout":5}]}]}}
        """#
        try Data(existing.utf8).write(to: settings)

        let backup = try Integrations.installClaude(settingsURL: settings)
        #expect(backup != nil)
        let paths = Integrations.Paths(claudeSettings: settings, opencodePluginDir: dir.appendingPathComponent("oc"),
                                       piExtensionDir: dir.appendingPathComponent("pi"))
        #expect(Integrations.status(paths: paths).claude)

        let obj = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        #expect(obj["model"] as? String == "opus")
        let hooks = try #require(obj["hooks"] as? [String: Any])
        let start = try #require(hooks["SessionStart"] as? [[String: Any]])
        #expect(start.count == 2)
        let post = try #require(hooks["PostToolUse"] as? [[String: Any]])
        #expect(post.first?["matcher"] as? String == "*")

        _ = try Integrations.installClaude(settingsURL: settings)
        let again = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        #expect(((again["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]])?.count == 2)
    }

    @Test func pluginFiles() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = Integrations.Paths(claudeSettings: dir.appendingPathComponent("s.json"),
                                       opencodePluginDir: dir.appendingPathComponent("oc"),
                                       piExtensionDir: dir.appendingPathComponent("pi"))
        #expect(!Integrations.status(paths: paths).opencode)
        try Integrations.installOpenCode(pluginDir: paths.opencodePluginDir)
        try Integrations.installPi(extensionDir: paths.piExtensionDir)
        let s = Integrations.status(paths: paths)
        #expect(s.opencode && s.pi && !s.claude)
        let js = try String(contentsOf: paths.opencodePluginDir.appendingPathComponent("corral.js"), encoding: .utf8)
        #expect(js.contains("CORRAL_SURFACE_ID"))
    }

    @Test func hookCommandIsNoOpOutsideCorral() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", Integrations.claudeCommand("Stop")]
        var env = ProcessInfo.processInfo.environment
        env["CORRAL_HOOK"] = nil
        p.environment = env
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }

    @Test func backgroundAgentParsing() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("0af64f1b"), withIntermediateDirectories: true)
        try Data(#"{"state":"blocked","needs":"trigger reindex job"}"#.utf8)
            .write(to: dir.appendingPathComponent("0af64f1b/state.json"))
        let json = #"""
        [{"id":"0af64f1b","cwd":"/repo","kind":"background","sessionId":"0af64f1b-cbae","name":"Library issues","state":"working"},
         {"id":"aaaa","cwd":"/x","kind":"interactive","sessionId":"aaaa-1","name":"tab","state":"working"}]
        """#
        let agents = BackgroundAgents.parse(Data(json.utf8), jobsDir: dir)
        #expect(agents.count == 1)
        #expect(agents[0].activity == .needsInput)
        #expect(agents[0].needs == "trigger reindex job")
        #expect(agents[0].attachCommand == "claude attach 0af64f1b")
    }
}

struct ToolPresenceTests {
    @Test func agentsCountAsSetUpWhenTheirConfigFolderExists() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("corral-tools-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = Integrations.Paths(claudeSettings: home.appendingPathComponent(".claude/settings.json"),
                                       opencodePluginDir: home.appendingPathComponent(".config/opencode/plugins"),
                                       piExtensionDir: home.appendingPathComponent(".pi/agent/extensions"))
        #expect(Integrations.toolPresent(.shell, paths: paths))
        for agent in [AgentKind.claude, .opencode, .pi] { #expect(!Integrations.toolPresent(agent, paths: paths)) }
        for dir in [".claude", ".config/opencode", ".pi/agent"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        for agent in AgentKind.allCases { #expect(Integrations.toolPresent(agent, paths: paths)) }
        let s = Integrations.Status(claude: true, opencode: false, pi: true)
        #expect(s.installed(.shell) && s.installed(.claude) && !s.installed(.opencode) && s.installed(.pi) && !s.allInstalled)
    }
}
