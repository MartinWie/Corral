import AppKit
import Carbon
@testable import CorralCore
import Testing
@testable import CorralKit

@MainActor
struct SessionManagerTests {
    @Test func newSessionSpawnsTerminalWithEnvAndInput() {
        let f = Fixture()
        defer { f.cleanup() }
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        let id = try! #require(f.selected)
        let t = try! #require(f.terminal(id))
        #expect(t.launch.agentInput == "claude")
        #expect(t.launch.cwd == f.dir.path)
        #expect(t.launch.env["CORRAL_SOCKET"] == f.env.socketPath)
        #expect(t.launch.env["CORRAL_HOOK"] == "/bin/true")
        #expect(f.manager.workspace.sessions[id]?.agent == .claude)
    }

    @Test func missingDirectoryFallsBackToHome() {
        let f = Fixture()
        defer { f.cleanup() }
        f.manager.newSession(agent: .shell, cwd: "/definitely/not/here")
        #expect(f.terminal(f.selected)?.launch.cwd == NSHomeDirectory())
    }

    @Test func newSessionGoesNextToSelectionInSameFolder() {
        let f = Fixture()
        defer { f.cleanup() }
        let folder = f.manager.newFolder(name: "F")
        f.manager.newSession(agent: .shell, cwd: f.dir.path, folder: .some(folder))
        let first = f.selected!
        f.manager.newSession(agent: .shell, cwd: f.dir.path, folder: .some(folder))
        let second = f.selected!
        f.manager.select(first)
        f.manager.newSession(agent: .shell)
        #expect(f.manager.workspace.children(of: folder).map(\.id) == [first, f.selected!, second])
    }

    /// An agent session without a resumable transcript keeps its final screen searchable.
    @Test func closeIndexesAgentScrollbackAndSelectsNeighbor() async throws {
        let f = Fixture(start: true)
        defer { f.cleanup() }
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        let a = f.selected!
        f.terminal(a)?.text = "$ ./gradlew test\nBUILD FAILED uniquewordxyz\n"
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        let b = f.selected!
        f.manager.select(a)
        f.manager.close(a)
        #expect(f.terminal(a)?.destroyed == true)
        #expect(f.manager.live[a] == nil)
        #expect(f.selected == b)
        #expect(f.manager.workspace.closedSessions.map(\.id) == [a])
        f.manager.index.queue.sync {}
        let hits = try f.manager.index.readQueue.sync { try f.manager.index.searchSync("uniquewordxyz") }
        #expect(hits.first?.corralSessionId == a)
    }

    @Test func closingLastSessionClearsSelection() {
        let f = Fixture()
        defer { f.cleanup() }
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        f.manager.close(f.selected!)
        #expect(f.selected == nil)
    }

    @Test func requestCloseConfirmsWhenBusy() {
        let f = Fixture()
        defer { f.cleanup() }
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        let id = f.selected!
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "UserPromptSubmit")), to: id)
        f.ui.confirmAnswer = false
        f.manager.requestClose(id)
        #expect(f.ui.confirms.count == 1)
        #expect(f.manager.live[id] != nil)
        f.ui.confirmAnswer = true
        f.manager.requestClose(id)
        #expect(f.manager.live[id] == nil)
    }

    @Test func requestCloseIdleClosesDirectlyAndRunningProcessAsks() {
        let f = Fixture()
        defer { f.cleanup() }
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        let a = f.selected!
        f.manager.requestClose(a)
        #expect(f.ui.confirms.isEmpty)
        #expect(f.manager.live[a] == nil)
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        let b = f.selected!
        f.terminal(b)?.needsConfirmQuit = true
        f.manager.requestClose(b)
        #expect(f.ui.confirms.count == 1)
        f.manager.requestClose(UUID())
    }

    @Test func reopenResumesAgentInItsDirectory() {
        let f = Fixture()
        defer { f.cleanup() }
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        let id = f.selected!
        let sub = f.dir.appendingPathComponent("sub")
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "SessionStart", sessionId: "sid-1", cwd: f.dir.path, source: "startup")), to: id)
        f.manager.apply(.pwd(sub.path), to: id)
        f.transcripts("sid-1")
        f.manager.close(id)
        f.manager.reopen(id)
        let t = try! #require(f.terminal(id))
        #expect(t.launch.agentInput == "claude --resume sid-1")
        #expect(t.launch.cwd == f.dir.path)
        #expect(f.manager.status(id)?.agent == .claude)
        // Reopening something already open just selects it.
        f.manager.reopen(id)
        #expect(f.selected == id)
    }

    @Test func reopenLastClosedRespectsWindow() {
        let f = Fixture()
        defer { f.cleanup() }
        #expect(!f.manager.reopenLastClosed())
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        let id = f.selected!
        f.manager.close(id)
        #expect(!f.manager.reopenLastClosed(within: -1))
        #expect(f.manager.reopenLastClosed(within: 600))
        #expect(f.manager.live[id] != nil)
    }

    @Test func forgetAndForgetAll() {
        let f = Fixture()
        defer { f.cleanup() }
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        let a = f.selected!
        f.manager.forget(a)
        #expect(f.manager.workspace.sessions[a] != nil, "open sessions can't be forgotten")
        f.manager.close(a)
        f.manager.forget(a)
        #expect(f.manager.workspace.sessions[a] == nil)
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        f.manager.close(f.selected!)
        f.manager.forgetAllClosed()
        #expect(f.manager.workspace.closedSessions.isEmpty)
    }

    @Test func openSearchHitFocusesReopensOrResumes() {
        let f = Fixture()
        defer { f.cleanup() }
        f.manager.newSession(agent: .opencode, cwd: f.dir.path, agentSessionId: "ses_1")
        let open = f.selected!
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        let hit = SearchHit(key: "opencode:ses_1", agent: .opencode, sessionId: "ses_1", cwd: f.dir.path, title: "t", updated: nil, snippets: [])
        f.manager.open(hit: hit)
        #expect(f.selected == open)

        f.manager.close(open)
        f.manager.open(hit: hit)
        #expect(f.manager.live[open] != nil)

        let fresh = SearchHit(key: "claude:new", agent: .claude, sessionId: "new", cwd: f.dir.path, title: "Old work", updated: nil, snippets: [])
        f.manager.open(hit: fresh)
        let created = f.selected!
        #expect(f.terminal(created)?.launch.agentInput == "claude --resume new")
        #expect(f.manager.workspace.sessions[created]?.agentCwd == f.dir.path)

        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        let shell = f.selected!
        f.manager.close(shell)
        let scroll = SearchHit(key: "corral:\(shell.uuidString)", agent: .shell, sessionId: shell.uuidString, cwd: "", title: "", updated: nil, snippets: [])
        f.manager.open(hit: scroll)
        #expect(f.manager.live[shell] != nil)
        f.manager.open(hit: scroll)
        #expect(f.selected == shell)
    }

    @Test func renameFoldersAndSessions() {
        let f = Fixture(start: true)
        defer { f.cleanup() }
        let folder = f.manager.newFolder()
        f.manager.rename(folder, to: "  ")
        #expect(f.manager.workspace.folders[folder]?.name == "Folder")
        f.manager.rename(folder, to: "Infra")
        #expect(f.manager.workspace.folders[folder]?.name == "Infra")
        f.manager.newSession(agent: .claude, cwd: f.dir.path, agentSessionId: "x")
        let s = f.selected!
        f.manager.rename(s, to: "Review")
        #expect(f.manager.workspace.sessions[s]?.displayTitle == "Review")
        f.manager.rename(s, to: "")
        #expect(f.manager.workspace.sessions[s]?.customName == nil)
    }

    @Test func folderOperations() {
        let f = Fixture()
        defer { f.cleanup() }
        let folder = f.manager.newFolder(name: "F", directory: "/x")
        f.manager.setFolderDirectory(folder, "/y")
        #expect(f.manager.workspace.folders[folder]?.directory == "/y")
        f.manager.setExpanded(folder, false)
        #expect(f.manager.workspace.folders[folder]?.expanded == false)
        f.manager.setExpanded(UUID(), true)
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        let s = f.selected!
        #expect(f.manager.move(s, to: folder, at: nil))
        #expect(!f.manager.move(folder, to: folder, at: nil))
        f.manager.deleteFolder(folder)
        #expect(f.manager.workspace.folders[folder] == nil)
        #expect(f.manager.workspace.tree.map(\.id).contains(s))
    }

    @Test func agentDefaultsDrivePlacement() {
        let f = Fixture()
        defer { f.cleanup() }
        let agents = f.manager.newFolder(name: "Agents")
        f.manager.setAgentDefaults(AgentDefaults(directory: f.dir.path, folder: agents), for: .claude)
        f.manager.newSession(agent: .claude)
        #expect(f.manager.workspace.children(of: agents).map(\.id) == [f.selected!])
        #expect(f.terminal(f.selected)?.launch.cwd == f.dir.path)
    }

    @Test func moveSelectedWithinParent() {
        let f = Fixture()
        defer { f.cleanup() }
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        let a = f.selected!
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        let b = f.selected!
        f.manager.moveSelected(by: -1)
        #expect(f.manager.workspace.openSessionsInOrder == [b, a])
        f.manager.moveSelected(by: 1)
        #expect(f.manager.workspace.openSessionsInOrder == [a, b])
        f.manager.moveSelected(by: 5)
        #expect(f.manager.workspace.openSessionsInOrder == [a, b])
    }

    @Test func navigation() {
        let f = Fixture()
        defer { f.cleanup() }
        f.manager.selectIndex(0)
        f.manager.selectRelative(1)
        var ids: [UUID] = []
        for _ in 0..<3 {
            f.manager.newSession(agent: .shell, cwd: f.dir.path)
            ids.append(f.selected!)
        }
        f.manager.selectIndex(0)
        #expect(f.selected == ids[0])
        f.manager.selectIndex(99)
        #expect(f.selected == ids[2])
        f.manager.selectRelative(1)
        #expect(f.selected == ids[0])
        f.manager.selectRelative(-1)
        #expect(f.selected == ids[2])
        f.manager.select(ids[1], focus: false)
        #expect(!f.manager.selectionWantsFocus)
    }

    @Test func numberShortcutsFollowVisibleRows() {
        let f = Fixture()
        defer { f.cleanup() }
        let folder = f.manager.newFolder(name: "F")
        f.manager.newSession(agent: .shell, cwd: f.dir.path, folder: .some(folder))
        let hidden = f.selected!
        f.manager.newSession(agent: .shell, cwd: f.dir.path, folder: .some(nil))
        let a = f.selected!
        f.manager.newSession(agent: .shell, cwd: f.dir.path, folder: .some(nil))
        let b = f.selected!
        f.manager.selectIndex(0)
        #expect(f.selected == hidden)
        f.manager.setExpanded(folder, false)
        f.manager.selectIndex(0)
        #expect(f.selected == a, "collapsed folders don't count")
        f.manager.selectIndex(Int.max)
        #expect(f.selected == b)
        // Next/previous still cycle through everything.
        f.manager.selectRelative(1)
        #expect(f.selected == hidden)
        let w = MainWindowController(manager: f.manager)
        let nine = NSMenuItem()
        nine.tag = 9
        w.selectSessionByNumber(nine)
        #expect(f.selected == b)
    }

    @Test func nextAttentionPrefersNeedsInput() {
        let f = Fixture()
        defer { f.cleanup() }
        f.manager.selectNextAttention()
        var ids: [UUID] = []
        for _ in 0..<3 {
            f.manager.newSession(agent: .claude, cwd: f.dir.path)
            ids.append(f.selected!)
        }
        f.effects.active = false
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "UserPromptSubmit")), to: ids[0])
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "Stop")), to: ids[0])
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "PermissionRequest")), to: ids[1])
        f.manager.select(ids[2])
        f.manager.selectNextAttention()
        #expect(f.selected == ids[1])
        #expect(f.manager.needsInputCount == 1)
        #expect(f.effects.badges.last == "1")
    }

    @Test func statusSyncsIntoRecord() {
        let f = Fixture()
        defer { f.cleanup() }
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        let id = f.selected!
        f.manager.apply(.terminalTitle("✳ Fix login"), to: id)
        f.manager.apply(.hook(HookEvent(agent: .opencode, event: "session.updated", sessionId: "ses_9", cwd: f.dir.path)), to: id)
        var r = f.manager.workspace.sessions[id]!
        #expect(r.autoTitle == "Fix login")
        #expect(r.agent == .opencode)
        #expect(r.agentSessionId == "ses_9")
        #expect(r.agentRunning)
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "SessionStart", sessionId: "c1", source: "startup")), to: id)
        r = f.manager.workspace.sessions[id]!
        #expect(r.agent == .claude)
        #expect(r.agentSessionId == "c1")
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "SessionEnd", sessionId: "c1")), to: id)
        #expect(f.manager.workspace.sessions[id]?.agentRunning == false)
        f.manager.apply(.viewed, to: UUID())
    }

    @Test func keyHandling() {
        let f = Fixture()
        defer { f.cleanup() }
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        let id = f.selected!
        let t = f.terminal(id)!
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "PermissionRequest")), to: id)
        t.onKeyDown?(keyEvent(UInt16(kVK_ANSI_2), chars: "2", modifiers: .command))
        #expect(f.manager.status(id)?.activity == .needsInput, "shortcuts are not answers")
        t.onKeyDown?(keyEvent(UInt16(kVK_ANSI_1), chars: "1"))
        #expect(f.manager.status(id)?.activity == .working)
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "PermissionRequest")), to: id)
        t.onKeyDown?(keyEvent(UInt16(kVK_Escape), chars: "\u{1b}"))
        #expect(f.manager.status(id)?.activity == .idle)
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "PermissionRequest")), to: id)
        t.onKeyDown?(keyEvent(UInt16(kVK_Return), chars: "\r"))
        #expect(f.manager.status(id)?.activity == .working)
        t.onKeyDown?(keyEvent(UInt16(kVK_ANSI_A), chars: "a"))
        t.onFocus?()
    }

    @Test func foregroundDetectionUsesTerminalPid() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        let id = f.selected!
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "SessionStart", sessionId: "a", source: "startup")), to: id)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 3"]
        try p.run()
        defer { p.terminate() }
        f.terminal(id)?.foregroundPid = p.processIdentifier
        f.manager.detectForeground(id)
        #expect(f.manager.status(id)?.agent == .shell)
        f.terminal(id)?.foregroundPid = 0
        f.manager.detectForeground(id)
        f.manager.detectForeground(UUID())
    }

    @Test func hooksArriveOverTheSocket() async throws {
        let f = Fixture(start: true)
        defer { f.cleanup() }
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        let id = f.selected!
        let line = try #require(HookWire.encode(surface: id.uuidString, agent: "claude", event: "PermissionRequest",
                                                payload: ["tool_name": "Bash", "session_id": "s1"]))
        #expect(EventClient.send(line, to: f.env.socketPath))
        await waitUntil { f.manager.status(id)?.activity == .needsInput }
        #expect(f.manager.status(id)?.detail == "Permission: Bash")
        let start = try #require(HookWire.encode(surface: id.uuidString, agent: "claude", event: "SessionStart",
                                                 payload: ["session_id": "s1", "source": "resume"]))
        EventClient.send(start, to: f.env.socketPath)
        await waitUntil { f.manager.status(id)?.activity == .idle }
        #expect(f.manager.status(id)?.activity == .idle)
    }

    @Test func restoreAfterRelaunch() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        let id = f.selected!
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "SessionStart", sessionId: "keep", cwd: f.dir.path, source: "startup")), to: id)
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        f.manager.prepareForTermination()

        f.makeManager()
        f.manager.start()
        #expect(f.manager.live.count == 2)
        #expect(f.terminal(id)?.launch.agentInput == "claude --resume keep")
        #expect(f.manager.status(id)?.agentSessionId == "keep")
        // After termination signals are ignored.
        f.manager.prepareForTermination()
        f.manager.apply(.bell, to: id)
    }

    @Test func watchersCoverExistingRootsAndPickUpNewOnes() {
        let f = Fixture(start: true)
        defer { f.cleanup() }
        #expect(f.manager.watchedPaths == [f.env.jobsDir.path])
        try? FileManager.default.createDirectory(at: f.env.roots.piSessions, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: f.env.roots.claudeProjects, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: f.env.roots.opencodeDB.deletingLastPathComponent(), withIntermediateDirectories: true)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(f.manager.watchedPaths.count == 4)
    }

    @Test func backgroundAgentsLoadAttachAndTrackState() async throws {
        let bin = FileManager.default.temporaryDirectory.appendingPathComponent("fake-claude-\(UUID().uuidString)")
        let json = #"[{"id":"job1","kind":"background","sessionId":"s-job1","name":"Library issues","cwd":"/tmp","state":"working"}]"#
        try "#!/bin/sh\necho '\(json)'\n".write(to: bin, atomically: true, encoding: .utf8)
        chmod(bin.path, 0o755)
        defer { try? FileManager.default.removeItem(at: bin) }
        let f = Fixture { $0.claudeBinary = bin.path }
        defer { f.cleanup() }
        try FileManager.default.createDirectory(at: f.env.jobsDir.appendingPathComponent("job1"), withIntermediateDirectories: true)
        let state = f.env.jobsDir.appendingPathComponent("job1/state.json")
        try Data(#"{"state":"blocked","needs":"decide"}"#.utf8).write(to: state)

        await withCheckedContinuation { c in f.manager.reloadBackground { c.resume() } }
        #expect(f.manager.background.first?.activity == .needsInput)
        #expect(f.manager.unattachedBackground.count == 1)
        #expect(f.manager.needsInputCount == 1)

        // A second reload while one is in flight coalesces.
        f.manager.reloadBackground()
        await withCheckedContinuation { c in f.manager.reloadBackground { c.resume() } }

        f.manager.attach(f.manager.background[0])
        let attached = f.selected!
        #expect(f.terminal(attached)?.launch.agentInput == "claude attach job1")
        #expect(f.manager.unattachedBackground.isEmpty)
        f.manager.attach(f.manager.background[0])
        #expect(f.selected == attached)

        try Data(#"{"state":"done"}"#.utf8).write(to: state)
        f.effects.active = false
        f.manager.backgroundChanged([state.path])
        #expect(f.manager.status(attached)?.activity == .done)
        #expect(f.manager.status(attached)?.unread == true)

        // Unknown paths trigger a full reload.
        f.manager.backgroundChanged([f.env.jobsDir.appendingPathComponent("job2/state.json").path])
        await waitUntil { true }

        // Attention jump falls back to background agents when no session needs input.
        try Data(#"{"state":"blocked"}"#.utf8).write(to: state)
        f.manager.close(attached)
        await withCheckedContinuation { c in f.manager.reloadBackground { c.resume() } }
        f.manager.selectNextAttention()
        #expect(f.manager.workspace.sessions[f.selected!]?.bgJobId == "job1")
    }

    @Test func integrationsRefresh() throws {
        let f = Fixture()
        defer { f.cleanup() }
        #expect(!f.manager.integrations.opencode)
        try Integrations.installOpenCode(pluginDir: f.env.integrationPaths.opencodePluginDir)
        f.manager.refreshIntegrations()
        #expect(f.manager.integrations.opencode)
    }

    @Test func notificationRules() {
        func kind(_ b: Activity, _ a: Activity, agent: AgentKind = .claude, need: Need = .input) -> NotificationKind? {
            var before = LiveStatus(), after = LiveStatus()
            before.activity = b
            after.activity = a
            after.agent = agent
            after.need = need
            return SessionManager.notificationKind(before: before, after: after)
        }
        #expect(kind(.working, .needsInput, need: .permission) == .permission)
        #expect(kind(.working, .needsInput) == .question)
        #expect(kind(.needsInput, .needsInput, need: .permission) == nil)
        #expect(kind(.working, .done) == .finished)
        var compacting = LiveStatus(), restored = LiveStatus()
        compacting.activity = .working
        compacting.compactFrom = .done
        restored.activity = .done
        restored.agent = .claude
        #expect(SessionManager.notificationKind(before: compacting, after: restored) == nil)
        #expect(kind(.idle, .done) == nil)
        #expect(kind(.working, .error) == .failed)
        #expect(kind(.error, .error) == nil)
        #expect(kind(.working, .idle) == nil)
        // A plain shell gets done / error only from a long command, whatever it showed before.
        #expect(kind(.idle, .done, agent: .shell) == .command)
        #expect(kind(.done, .error, agent: .shell) == .command)
        #expect(kind(.done, .done, agent: .shell) == nil)
    }

    @Test func notesNameTheSessionAndWhatHappened() {
        let id = UUID()
        var record = SessionRecord(cwd: "/tmp/repo", agent: .claude)
        record.customName = "Fix the parser"
        var s = LiveStatus()
        s.agent = .claude
        s.activity = .needsInput
        s.detail = "Bash: git push"
        let note = SessionManager.note(.permission, session: id, record: record, status: s, sound: true)
        #expect(note == CorralNote(id: id.uuidString, title: "Fix the parser", subtitle: "Claude Code needs permission",
                                   body: "Bash: git push", sound: true, session: id))
        s.detail = nil
        #expect(SessionManager.note(.question, session: id, record: record, status: s, sound: false).subtitle == "Claude Code needs your input")
        #expect(SessionManager.note(.finished, session: id, record: record, status: s, sound: false).body == "/tmp/repo")
        s.detail = "Bash: export TOKEN=secret"
        #expect(SessionManager.note(.permission, session: id, record: record, status: s, sound: false, details: false).body == "/tmp/repo")
        #expect(SessionManager.note(.failed, session: id, record: record, status: s, sound: false).subtitle == "Claude Code failed")
        s.agent = .shell
        s.activity = .error
        #expect(SessionManager.note(.command, session: id, record: record, status: s, sound: false).subtitle == "Command failed")
        s.activity = .done
        #expect(SessionManager.note(.command, session: id, record: record, status: s, sound: false).subtitle == "Command finished")
    }

    @Test func isTerminalRecognizesSessionViews() {
        let f = Fixture()
        defer { f.cleanup() }
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        #expect(f.manager.isTerminal(f.terminal(f.selected)?.view))
        #expect(!f.manager.isTerminal(NSView()))
        #expect(!f.manager.isTerminal(nil))
    }
}

@MainActor
struct TerminalActionTests {
    @Test func everyActionIsHandled() {
        let f = Fixture()
        defer { f.cleanup() }
        let m = f.manager!
        #expect(m.perform(.newSession, terminal: nil))
        let id = f.selected!
        let t = f.terminal(id)!
        var seen: [TerminalAction] = []
        m.onTerminalAction = { _, a in seen.append(a) }

        #expect(m.perform(.setTitle("✳ Build"), terminal: t))
        #expect(m.status(id)?.title == "Build")
        #expect(m.perform(.pwd(f.dir.path), terminal: t))
        #expect(m.perform(.desktopNotification(title: "x", body: "y"), terminal: t))
        #expect(m.perform(.bell, terminal: t))
        #expect(m.perform(.progress(.active), terminal: t))
        #expect(m.perform(.commandFinished(exitCode: 0, seconds: 1), terminal: t))
        #expect(!m.perform(.childExited, terminal: t))
        #expect(m.status(id)?.activity == .exited)
        #expect(m.perform(.toggleFullscreen, terminal: t))
        #expect(m.perform(.commandPalette, terminal: t))
        #expect(f.ui.fullscreens == 1 && f.ui.searches == 1)
        #expect(m.perform(.startSearch("x"), terminal: t))
        #expect(m.perform(.searchTotal(3), terminal: t))
        #expect(m.perform(.searchSelected(1), terminal: t))
        #expect(m.perform(.endSearch, terminal: t))
        #expect(f.ui.finds.count == 4)
        #expect(m.perform(.openConfig, terminal: t))
        #expect(f.effects.opened.last?.path == f.factory.configPath)
        #expect(m.perform(.reloadConfig, terminal: t))
        #expect(f.factory.reloads == 1)
        #expect(!m.perform(.undoClose, terminal: t))
        #expect(m.perform(.quit, terminal: t))
        #expect(f.effects.terminated == 1)
        #expect(m.perform(.newSession, terminal: t))
        #expect(m.perform(.gotoSession(1), terminal: t))
        #expect(m.perform(.gotoSession(-1), terminal: t))
        #expect(m.perform(.gotoSession(-2), terminal: t))
        #expect(m.perform(.gotoSession(-3), terminal: t))
        #expect(m.perform(.moveSession(1), terminal: t))
        #expect(m.perform(.closeSession, terminal: t))
        #expect(seen.count > 10)

        // Surface-less actions that need a terminal fall back.
        for a: TerminalAction in [.closeSession, .setTitle("x"), .pwd("/"), .bell, .progress(.active),
                                  .commandFinished(exitCode: nil, seconds: 0), .desktopNotification(title: "", body: ""),
                                  .startSearch(nil)] {
            #expect(!m.perform(a, terminal: nil))
        }
    }

    @Test func closeRequestedFromTerminal() {
        let f = Fixture()
        defer { f.cleanup() }
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        let id = f.selected!
        let t = f.terminal(id)!
        f.manager.closeRequested(t, processAlive: true)
        #expect(f.manager.live[id] == nil, "idle shell closes without asking")
        f.manager.closeRequested(t, processAlive: false)
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        let t2 = f.terminal(f.selected)!
        f.manager.closeRequested(t2, processAlive: false)
        #expect(t2.destroyed)
    }

    @Test func untrustedLinksFollowGhosttyPolicy() throws {
        let f = Fixture()
        defer { f.cleanup() }
        f.manager.openURL("https://example.com", kind: .osc8)
        #expect(f.effects.opened.last?.host == "example.com")
        f.manager.openURL("/tmp", kind: .text)
        #expect(f.effects.opened.last?.isFileURL == true)
        f.ui.confirmAnswer = true
        f.manager.openURL("vscode://file/x", kind: .osc8)
        #expect(f.ui.confirms.last == "Open this link?")
        #expect(f.effects.opened.last?.scheme == "vscode")
        let app = f.dir.appendingPathComponent("Evil.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        f.manager.openURL(app.absoluteString, kind: .osc8)
        #expect(f.effects.alerts.last == "Link blocked")
        f.manager.openURL("https://exa\u{202E}mple.com", kind: .unknown)
        #expect(f.effects.alerts.count == 2)
    }
}
