import Foundation
import Testing
@testable import CorralCore

/// Cases from the first code review plus per-agent defaults.
struct ReducerRegressionTests {
    func claude(_ event: String, sid: String, source: String? = nil, cwd: String? = nil) -> Signal {
        .hook(HookEvent(agent: .claude, event: event, sessionId: sid, cwd: cwd, source: source))
    }

    @Test func nestedClaudeRunIsIgnored() {
        var s = LiveStatus()
        StatusReducer.reduce(&s, claude("SessionStart", sid: "outer", source: "startup", cwd: "/repo"), focused: false)
        StatusReducer.reduce(&s, claude("UserPromptSubmit", sid: "outer"), focused: false)
        // `claude -p` launched by the outer agent's Bash tool.
        StatusReducer.reduce(&s, claude("SessionStart", sid: "nested", source: "startup", cwd: "/tmp"), focused: false)
        StatusReducer.reduce(&s, claude("Stop", sid: "nested"), focused: false)
        StatusReducer.reduce(&s, claude("SessionEnd", sid: "nested"), focused: false)
        #expect(s.agentSessionId == "outer")
        #expect(s.agent == .claude)
        #expect(s.activity == .working)
        #expect(s.agentCwd == "/repo")
    }

    @Test func clearAndResumeSwitchSessions() {
        var s = LiveStatus()
        StatusReducer.reduce(&s, claude("SessionStart", sid: "a", source: "startup"), focused: false)
        StatusReducer.reduce(&s, claude("SessionStart", sid: "b", source: "clear"), focused: false)
        #expect(s.agentSessionId == "b")
        StatusReducer.reduce(&s, claude("SessionStart", sid: "c", source: "resume"), focused: false)
        #expect(s.agentSessionId == "c")
    }

    @Test func newClaudeAfterExitIsAccepted() {
        var s = LiveStatus()
        StatusReducer.reduce(&s, claude("SessionStart", sid: "a", source: "startup"), focused: false)
        StatusReducer.reduce(&s, claude("SessionEnd", sid: "a"), focused: false)
        StatusReducer.reduce(&s, claude("SessionStart", sid: "b", source: "startup"), focused: false)
        #expect(s.agentSessionId == "b")
        #expect(s.agent == .claude)
    }

    @Test func compactionKeepsWorking() {
        var s = LiveStatus()
        StatusReducer.reduce(&s, claude("SessionStart", sid: "a", source: "startup"), focused: false)
        StatusReducer.reduce(&s, claude("UserPromptSubmit", sid: "a"), focused: false)
        StatusReducer.reduce(&s, claude("SessionStart", sid: "a", source: "compact"), focused: false)
        #expect(s.activity == .working)
    }

    @Test func agentCwdSticksToSessionStart() {
        var s = LiveStatus()
        StatusReducer.reduce(&s, claude("SessionStart", sid: "a", source: "startup", cwd: "/repo"), focused: false)
        StatusReducer.reduce(&s, claude("PostToolUse", sid: "a", cwd: "/repo/sub"), focused: false)
        #expect(s.agentCwd == "/repo")
        #expect(s.cwd == "/repo/sub")
    }

    @Test func switchingAgentDropsOldSessionId() {
        var s = LiveStatus()
        StatusReducer.reduce(&s, claude("SessionStart", sid: "c1", source: "startup", cwd: "/repo"), focused: false)
        StatusReducer.reduce(&s, .hook(HookEvent(agent: .pi, event: "agent_start")), focused: false)
        #expect(s.agent == .pi)
        #expect(s.agentSessionId == nil)
    }

    @Test func hooksSeenResetsWhenAgentEnds() {
        var s = LiveStatus()
        StatusReducer.reduce(&s, claude("SessionStart", sid: "a", source: "startup"), focused: false)
        StatusReducer.reduce(&s, claude("SessionEnd", sid: "a"), focused: false)
        #expect(!s.hooksSeen)
        // OpenCode without its plugin: terminal heuristics work again.
        StatusReducer.reduce(&s, .foregroundProcess(.opencode), focused: false)
        StatusReducer.reduce(&s, .progress(.active), focused: false)
        #expect(s.activity == .working)
    }

    @Test func openCodeSessionSwitchAccepted() {
        var s = LiveStatus()
        StatusReducer.reduce(&s, .hook(HookEvent(agent: .opencode, event: "session.status", sessionId: "ses_a", status: "busy")), focused: false)
        StatusReducer.reduce(&s, .hook(HookEvent(agent: .opencode, event: "session.updated", sessionId: "ses_b")), focused: false)
        #expect(s.agentSessionId == "ses_b")
    }

    @Test func hookWireCarriesSource() throws {
        let line = try #require(HookWire.encode(surface: UUID().uuidString, agent: "claude", event: "SessionStart",
                                                payload: ["source": "compact", "session_id": "a"]))
        #expect(HookWire.decode(line: line)?.event.source == "compact")
    }

    @Test func chunksRespectSize() {
        let text = (0..<1000).map { "line \($0) with some text" }.joined(separator: "\n")
        let chunks = SearchIndex.chunks(of: text, size: 4000)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.utf8.count <= 4000 })
        #expect(chunks.joined().contains("line 999 with some text"))
    }
}

struct PlacementTests {
    @Test func defaultFolderAndDirectoryPerAgent() {
        var ws = Workspace()
        let agents = Folder(name: "Agents")
        ws.addFolder(agents)
        let project = Folder(name: "Project", directory: "/project")
        ws.addFolder(project)
        let shell = SessionRecord(cwd: "/elsewhere")
        ws.addSession(shell)
        ws.selected = shell.id
        ws.setDefaults(AgentDefaults(directory: "/code", folder: agents.id), for: .claude)

        let claude = ws.placement(for: .claude, folder: nil, cwd: nil, currentDirectory: "/elsewhere", home: "/home")
        #expect(claude.folder == agents.id)
        #expect(claude.directory == "/code")

        // Explicit folder with its own directory wins.
        let inProject = ws.placement(for: .claude, folder: .some(project.id), cwd: nil, currentDirectory: "/elsewhere", home: "/home")
        #expect(inProject.folder == project.id)
        #expect(inProject.directory == "/project")

        // No defaults for shells: next to the selection, in its directory.
        let sh = ws.placement(for: .shell, folder: nil, cwd: nil, currentDirectory: "/elsewhere", home: "/home")
        #expect(sh.folder == nil)
        #expect(sh.directory == "/elsewhere")

        // Explicit cwd (search result resume) wins over everything.
        let resumed = ws.placement(for: .claude, folder: nil, cwd: "/transcript", currentDirectory: nil, home: "/home")
        #expect(resumed.directory == "/transcript")
    }

    @Test func deletingDefaultFolderClearsIt() {
        var ws = Workspace()
        let f = Folder(name: "Agents")
        ws.addFolder(f)
        ws.setDefaults(AgentDefaults(folder: f.id), for: .opencode)
        ws.deleteFolder(f.id)
        #expect(ws.defaults(for: .opencode).isEmpty)
        #expect(ws.agentDefaults.isEmpty)
    }

    @Test func oldStateWithoutNewFieldsLoads() throws {
        let json = #"{"version":1,"tree":[],"sessions":[],"folders":[]}"#
        let ws = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
        #expect(ws.agentDefaults.isEmpty)
    }

    @Test func repairReopensClosedSessionsStillInTree() {
        var ws = Workspace()
        var r = SessionRecord(cwd: "/")
        r.closedAt = Date()
        ws.sessions[r.id] = r
        ws.tree = [.session(r.id)]
        ws.repair()
        #expect(ws.sessions[r.id]?.closedAt == nil)
    }

    @Test func resumeRunsInAgentDirectory() {
        var r = SessionRecord(cwd: "/moved/on", agent: .claude, agentSessionId: "s")
        r.agentCwd = "/repo"
        #expect(r.launchDirectory(resuming: true) == "/repo")
        #expect(r.launchDirectory(resuming: false) == "/moved/on")
    }
}

struct SettingsMergeSafetyTests {
    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func unreadableSettingsAreNotReplaced() throws {
        let dir = try tempDir()
        defer {
            chmod(dir.appendingPathComponent("settings.json").path, 0o600)
            try? FileManager.default.removeItem(at: dir)
        }
        let settings = dir.appendingPathComponent("settings.json")
        try Data(#"{"model":"opus"}"#.utf8).write(to: settings)
        chmod(settings.path, 0o000)
        #expect(throws: (any Error).self) { try Integrations.installClaude(settingsURL: settings) }
        chmod(settings.path, 0o600)
        #expect(try String(contentsOf: settings, encoding: .utf8) == #"{"model":"opus"}"#)
    }

    @Test func unexpectedHookShapeIsRefused() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = dir.appendingPathComponent("settings.json")
        let original = #"{"hooks":{"Stop":"oops"}}"#
        try Data(original.utf8).write(to: settings)
        #expect(throws: (any Error).self) { try Integrations.installClaude(settingsURL: settings) }
        #expect(try String(contentsOf: settings, encoding: .utf8) == original)
    }

    @Test func symlinkAndPermissionsPreserved() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("dotfiles-settings.json")
        try Data(#"{"env":{"TOKEN":"x"}}"#.utf8).write(to: real)
        chmod(real.path, 0o600)
        let link = dir.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let backup = try #require(try Integrations.installClaude(settingsURL: link))
        let attrs = try FileManager.default.attributesOfItem(atPath: link.path)
        _ = attrs
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == real.path)
        let perms = try FileManager.default.attributesOfItem(atPath: real.path)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o600)
        let backupPerms = try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber
        #expect(backupPerms?.int16Value == 0o600)
        let obj = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: real)) as? [String: Any])
        #expect((obj["env"] as? [String: Any])?["TOKEN"] as? String == "x")
        #expect(obj["hooks"] != nil)
    }

    @Test func missingFileIsCreated() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = dir.appendingPathComponent("sub/settings.json")
        let backup = try Integrations.installClaude(settingsURL: settings)
        #expect(backup == nil)
        #expect(FileManager.default.fileExists(atPath: settings.path))
    }
}
