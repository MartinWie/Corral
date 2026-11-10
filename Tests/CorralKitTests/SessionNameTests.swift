import AppKit
@testable import CorralCore
import Testing
@testable import CorralKit

/// A session keeps its agent's name: the shell around an agent (and its directory titles) never
/// renames it, open or closed. Background-job sessions are named after their job.
@MainActor
struct SessionNameTests {
    @Test func onlyAgentTitlesNameAnAgentSession() {
        let claude = SessionRecord(cwd: "/x", agent: .claude)
        #expect(claude.takesTerminalTitle(fromAgent: true))
        #expect(!claude.takesTerminalTitle(fromAgent: false))
        let shell = SessionRecord(cwd: "/x")
        #expect(shell.takesTerminalTitle(fromAgent: false))
        #expect(shell.takesTerminalTitle(fromAgent: true))
        // A decorated title is an agent's even before the agent is detected.
        var s = LiveStatus()
        StatusReducer.reduce(&s, .terminalTitle("✳ Fix login"), focused: false)
        #expect(s.titleFromAgent)
        StatusReducer.reduce(&s, .terminalTitle("~/Documents/Code"), focused: false)
        #expect(!s.titleFromAgent)
    }

    @Test func agentNameSurvivesTheFollowUpShellAndClosing() {
        let f = Fixture()
        defer { f.cleanup() }
        let m = f.manager!
        m.newSession(agent: .claude, cwd: f.dir.path)
        let id = f.selected!
        let t = f.terminal(id)!
        m.launchReady(id)
        _ = m.perform(.setTitle("✳ Library Sync"), terminal: t)
        let w = MainWindowController(manager: m)
        func shown() -> String { w.sidebar.displayTitle(m.workspace.sessions[id]!, m.status(id) ?? LiveStatus()) }
        #expect(shown() == "Library Sync")

        // The agent exits; the follow-up shell titles its prompt with the directory.
        m.handleHook(HookWire.Message(surface: id, event: HookEvent(agent: .claude, event: AgentLaunch.exitEvent, exitCode: 0)))
        _ = m.perform(.setTitle("~/Documents/Code"), terminal: t)
        #expect(shown() == "Library Sync")
        #expect(w.window?.title == "Library Sync")

        m.close(id)
        #expect(m.workspace.sessions[id]?.displayTitle == "Library Sync")
    }

    @Test func plainShellsStillFollowTheirTitle() {
        let f = Fixture()
        defer { f.cleanup() }
        let m = f.manager!
        m.newSession(agent: .shell, cwd: f.dir.path)
        let id = f.selected!
        _ = m.perform(.setTitle("~/Documents/Code"), terminal: f.terminal(id)!)
        #expect(m.workspace.sessions[id]?.displayTitle == "~/Documents/Code")
    }

    /// A shell title from just before an agent starts (the command line) never names the session.
    @Test func shellTitleBeforeAnAgentStartsDoesNotNameIt() {
        let f = Fixture()
        defer { f.cleanup() }
        let m = f.manager!
        m.newSession(agent: .shell, cwd: f.dir.path)
        let id = f.selected!
        let t = f.terminal(id)!
        _ = m.perform(.setTitle("~/Documents/Code"), terminal: t)
        _ = m.perform(.setTitle("claude -p summarize log"), terminal: t)
        m.handleHook(HookWire.Message(surface: id, event: HookEvent(agent: .claude, event: "SessionStart")))
        #expect(m.workspace.sessions[id]?.displayTitle == f.dir.path.pathLeaf)
        // The agent's own title does.
        _ = m.perform(.setTitle("✳ Summarize log"), terminal: t)
        #expect(m.workspace.sessions[id]?.displayTitle == "Summarize log")
    }

    /// A resume that found no conversation ("No conversation found with session ID") leaves nothing
    /// to reopen: closed, it is gone; older such entries go at launch.
    @Test func sessionsWithoutAConversationDoNotLandInClosed() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let m = f.manager!
        f.transcripts("real")
        m.newSession(agent: .claude, cwd: f.dir.path, agentSessionId: "ghost")
        let ghost = f.selected!
        m.newSession(agent: .claude, cwd: f.dir.path, agentSessionId: "real")
        let real = f.selected!
        m.newSession(agent: .pi, cwd: f.dir.path, agentSessionId: "/nonexistent/session.jsonl")
        let pi = f.selected!
        m.newSession(agent: .opencode, cwd: f.dir.path, agentSessionId: "ses_x")
        let oc = f.selected!
        for id in [ghost, real, pi, oc] { m.close(id) }
        #expect(m.workspace.sessions[ghost] == nil && m.workspace.sessions[pi] == nil)
        #expect(Set(m.workspace.closedSessions.map(\.id)) == [real, oc])
        // From older state: pruned at launch once its transcript is gone.
        m.saveNow(wait: true)
        try FileManager.default.removeItem(at: f.env.roots.claudeProjects.appendingPathComponent("-test-project/real.jsonl"))
        f.makeManager()
        #expect(f.manager.workspace.closedSessions.map(\.id) == [oc])
    }

    /// Only a definite "no transcript" forgets: an unreadable projects folder (e.g. CLAUDE_CONFIG_DIR
    /// set only in the shell) and background jobs (reopen attaches) keep their records.
    @Test func uncertainTranscriptsKeepTheSession() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let m = f.manager!
        #expect(!FileManager.default.fileExists(atPath: f.env.roots.claudeProjects.path))
        m.newSession(agent: .claude, cwd: f.dir.path, agentSessionId: "unknown-root")
        let a = f.selected!
        m.close(a)
        #expect(m.workspace.closedSessions.map(\.id) == [a])
        f.transcripts("other")
        m.attach(BackgroundAgent(id: "job9", sessionId: "job9", name: "Job", cwd: f.dir.path, state: "working"))
        let job = f.selected!
        m.close(job)
        #expect(Set(m.workspace.closedSessions.map(\.id)) == [a, job] || m.workspace.sessions[a] == nil)
        #expect(m.workspace.sessions[job]?.closedAt != nil)
        #expect(m.missingTranscript(m.workspace.sessions[job]!) == false)
        #expect(m.missingTranscript(m.workspace.sessions[job]!, claude: .some(nil)) == false)
    }

    /// Only sessions that ran an agent land in Closed; plain terminals are gone when closed.
    @Test func plainTerminalsDoNotLandInClosed() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let m = f.manager!
        m.newSession(agent: .shell, cwd: f.dir.path)
        let shell = f.selected!
        m.newSession(agent: .claude, cwd: f.dir.path)
        let agent = f.selected!
        m.close(shell)
        m.close(agent)
        #expect(m.workspace.sessions[shell] == nil)
        #expect(m.workspace.closedSessions.map(\.id) == [agent])
        // Closed plain terminals from older state are dropped at launch.
        var ws = m.workspace
        let old = SessionRecord(cwd: f.dir.path)
        ws.addSession(old, in: nil)
        ws.close(old.id)
        try f.env.store.save(ws)
        f.makeManager()
        #expect(f.manager.workspace.sessions[old.id] == nil)
        #expect(f.manager.workspace.closedSessions.map(\.id) == [agent])
    }

    @Test func backgroundSessionsAreNamedAfterTheirJob() {
        let f = Fixture()
        defer { f.cleanup() }
        let m = f.manager!
        let job = BackgroundAgent(id: "870d9a06", sessionId: "s", name: "New mutual funds", cwd: f.dir.path, state: "done")
        f.transcripts("s")
        m.attach(job)
        let attached = f.selected!
        #expect(m.workspace.sessions[attached]?.displayTitle == "New mutual funds")
        // While attached, Claude's own title applies; the shell's after it ends doesn't.
        _ = m.perform(.setTitle("✳ New mutual funds"), terminal: f.terminal(attached)!)
        m.handleHook(HookWire.Message(surface: attached, event: HookEvent(agent: .claude, event: AgentLaunch.exitEvent, exitCode: 0)))
        _ = m.perform(.setTitle("~/Documents/Code"), terminal: f.terminal(attached)!)
        m.close(attached)
        #expect(m.workspace.sessions[attached]?.displayTitle == "New mutual funds")
    }

    /// Claude's /rename lands in the transcript; the index refresh carries it to the session's name, over
    /// Claude's terminal title. The latest rename wins, Corral's or Claude's; another conversation drops it.
    @Test func claudeRenameNamesTheSession() async throws {
        let f = Fixture(start: true)
        defer { f.cleanup() }
        let m = f.manager!
        m.newSession(agent: .claude, cwd: f.dir.path)
        let id = try #require(f.selected)
        let sid = try #require(m.workspace.sessions[id]?.agentSessionId)
        _ = m.perform(.setTitle("✳ Thumbnail cache"), terminal: f.terminal(id)!)
        let sidebar = SidebarViewController(manager: m)
        func shown() -> String { sidebar.displayTitle(m.workspace.sessions[id]!, m.status(id) ?? LiveStatus()) }
        f.transcripts(sid)
        let file = f.env.roots.claudeProjects.appendingPathComponent("-test-project/\(sid).jsonl")
        func sync() async {
            await withCheckedContinuation { c in m.index.refresh([.claude], roots: f.env.roots) { c.resume() } }
            await withCheckedContinuation { c in m.syncAgentNames { c.resume() } }
        }
        func rename(_ name: String, wait: Bool = true) async throws {
            var line = try JSONSerialization.data(withJSONObject: ["type": "custom-title", "customTitle": name, "sessionId": sid])
            line.append(0x0A)
            let h = try FileHandle(forWritingTo: file)
            try h.seekToEnd()
            try h.write(contentsOf: line)
            try h.close()
            if wait { await sync() } else { m.index.refresh([.claude], roots: f.env.roots) }
        }
        #expect(shown() == "Thumbnail cache")
        // Named in Corral first; the conversation has no name yet.
        m.rename(id, to: "Mine")
        await sync()
        #expect(shown() == "Mine")
        // Every index refresh syncs the names on its own.
        try await rename("Thumb sizes", wait: false)
        await waitUntil { shown() == "Thumb sizes" }
        #expect(shown() == "Thumb sizes")
        m.rename(id, to: "Mine again")
        try await rename("Thumb sizes")
        #expect(shown() == "Mine again")
        try await rename("HEIC thumbs")
        #expect(shown() == "HEIC thumbs" && m.workspace.sessions[id]?.displayTitle == "HEIC thumbs")
        m.apply(.hook(HookEvent(agent: .claude, event: "SessionStart", sessionId: "other")), to: id)
        #expect(m.workspace.sessions[id]?.agentSessionId == "other" && m.workspace.sessions[id]?.agentName == nil)
    }

    /// Closed background sessions get their job's name from the job list; a name the user gave stays.
    @Test func lostBackgroundTitlesAreRepairedFromTheJob() throws {
        let f = Fixture()
        defer { f.cleanup() }
        var ws = Workspace()
        var lost = SessionRecord(cwd: f.dir.path, agent: .claude, title: "~/Documents/Code")
        lost.bgJobId = "870d9a06"
        var mine = SessionRecord(cwd: f.dir.path, agent: .claude, title: "~/Documents/Code")
        mine.bgJobId = "870d9a06"
        mine.customName = "Mine"
        var nameless = SessionRecord(cwd: f.dir.path, agent: .claude, title: "~/Documents/Code")
        nameless.bgJobId = "abc12345"
        for r in [lost, mine, nameless] {
            ws.addSession(r, in: nil)
            ws.close(r.id)
        }
        try f.env.store.save(ws)
        f.makeManager()
        let m = f.manager!
        m.applyBackground([BackgroundAgent(id: "870d9a06", sessionId: "s", name: "New mutual funds", cwd: "/", state: "done"),
                           BackgroundAgent(id: "abc12345", sessionId: "n", name: "abc12345", cwd: "/", state: "done")])
        #expect(m.workspace.sessions[lost.id]?.displayTitle == "New mutual funds")
        #expect(m.workspace.sessions[mine.id]?.displayTitle == "Mine")
        // A job without a real name (the CLI falls back to its id) doesn't overwrite anything.
        #expect(m.workspace.sessions[nameless.id]?.displayTitle == "~/Documents/Code")
    }
}
