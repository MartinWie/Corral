import Foundation
import Testing
@testable import CorralCore

struct WorkspaceTests {
    func session(_ ws: inout Workspace, in folder: UUID? = nil, at index: Int? = nil) -> UUID {
        let r = SessionRecord(cwd: "/tmp")
        ws.addSession(r, in: folder, at: index)
        return r.id
    }

    @Test func addAndOrder() {
        var ws = Workspace()
        let a = session(&ws)
        let f = Folder(name: "F")
        ws.addFolder(f)
        let b = session(&ws, in: f.id)
        let c = session(&ws, at: 0)
        #expect(ws.openSessionsInOrder == [c, a, b])
        #expect(ws.parent(of: b) == .some(f.id))
        #expect(ws.parent(of: a) == .some(nil))
        #expect(ws.parent(of: UUID()) == nil)
    }

    @Test func moveWithinParentAdjustsIndex() {
        var ws = Workspace()
        let a = session(&ws), b = session(&ws), c = session(&ws)
        // NSOutlineView reports the index before removal: dropping a after c means index 3.
        do { let ok = ws.move(a, to: nil, at: 3); #expect(ok) }
        #expect(ws.openSessionsInOrder == [b, c, a])
        do { let ok = ws.move(a, to: nil, at: 0); #expect(ok) }
        #expect(ws.openSessionsInOrder == [a, b, c])
    }

    @Test func moveIntoFolderAndOut() {
        var ws = Workspace()
        let a = session(&ws)
        let f = Folder(name: "F")
        ws.addFolder(f)
        do { let ok = ws.move(a, to: f.id, at: nil); #expect(ok) }
        #expect(ws.children(of: f.id).map(\.id) == [a])
        do { let ok = ws.move(a, to: nil, at: 0); #expect(ok) }
        #expect(ws.children(of: f.id).isEmpty)
        #expect(ws.tree.first?.id == a)
    }

    @Test func folderCannotMoveIntoItself() {
        var ws = Workspace()
        let outer = Folder(name: "outer"), inner = Folder(name: "inner")
        ws.addFolder(outer)
        ws.addFolder(inner, in: outer.id)
        do { let ok = ws.move(outer.id, to: inner.id, at: nil); #expect(!ok) }
        do { let ok = ws.move(outer.id, to: outer.id, at: nil); #expect(!ok) }
        do { let ok = ws.move(inner.id, to: nil, at: nil); #expect(ok) }
    }

    @Test func closeAndReopenReturnsToFolder() {
        var ws = Workspace()
        let f = Folder(name: "F")
        ws.addFolder(f)
        let a = session(&ws, in: f.id)
        ws.selected = a
        ws.close(a)
        #expect(ws.openSessionsInOrder.isEmpty)
        #expect(ws.closedSessions.map(\.id) == [a])
        #expect(ws.sessions[a]?.lastFolder == f.id)
        #expect(ws.selected == nil)
        ws.reopen(a)
        #expect(ws.children(of: f.id).map(\.id) == [a])
        #expect(ws.sessions[a]?.closedAt == nil)
    }

    @Test func closedOrderIsNewestFirstAndSurvivesRoundTrip() throws {
        var ws = Workspace()
        let a = session(&ws), b = session(&ws), c = session(&ws)
        let t = Date(timeIntervalSince1970: 1_000_000)
        ws.close(a, at: t)
        ws.close(b, at: t.addingTimeInterval(10))
        ws.close(c, at: t.addingTimeInterval(20))
        ws.close(c, at: t.addingTimeInterval(30))
        #expect(ws.closedSessions.map(\.id) == [c, b, a])
        #expect(ws.closedCount == 3)
        #expect(ws.recentlyClosed(limit: 2).map(\.id) == [c, b])
        let decoded = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(ws))
        #expect(decoded.closedSessions.map(\.id) == [c, b, a])
        ws.reopen(b)
        ws.forget(a)
        #expect(ws.closedSessions.map(\.id) == [c])
        #expect(ws.closedCount == 1)
        // A record that is neither in the tree nor closed (e.g. a crash mid-move) is closed by repair.
        let orphan = SessionRecord(cwd: "/tmp")
        ws.sessions[orphan.id] = orphan
        ws.repair()
        #expect(Set(ws.closedSessions.map(\.id)) == [c, orphan.id])
    }

    @Test func reopenFallsBackToRootWhenFolderGone() {
        var ws = Workspace()
        let f = Folder(name: "F")
        ws.addFolder(f)
        let a = session(&ws, in: f.id)
        ws.close(a)
        ws.deleteFolder(f.id)
        ws.reopen(a)
        #expect(ws.tree.map(\.id) == [a])
    }

    @Test func deleteFolderKeepsChildrenInPlace() {
        var ws = Workspace()
        let x = session(&ws)
        let f = Folder(name: "F")
        ws.addFolder(f)
        let a = session(&ws, in: f.id), b = session(&ws, in: f.id)
        let y = session(&ws)
        ws.deleteFolder(f.id)
        #expect(ws.tree.map(\.id) == [x, a, b, y])
        #expect(ws.folders[f.id] == nil)
    }

    @Test func folderDirectoryInherits() {
        var ws = Workspace()
        let outer = Folder(name: "o", directory: "/repo")
        let inner = Folder(name: "i")
        ws.addFolder(outer)
        ws.addFolder(inner, in: outer.id)
        #expect(ws.directory(forFolder: inner.id) == "/repo")
        #expect(ws.directory(forFolder: nil) == nil)
    }

    @Test func repairClosesOrphans() {
        var ws = Workspace()
        let orphan = SessionRecord(cwd: "/tmp")
        ws.sessions[orphan.id] = orphan
        ws.tree.append(.session(UUID()))
        ws.repair()
        #expect(ws.sessions[orphan.id]?.closedAt != nil)
        #expect(ws.tree.isEmpty)
    }

    @Test func persistenceRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WorkspaceStore(url: dir.appendingPathComponent("state.json"))
        var ws = Workspace()
        let f = Folder(name: "F", directory: "/x")
        ws.addFolder(f)
        var r = SessionRecord(cwd: "/tmp", agent: .claude, title: "t", agentSessionId: "abc")
        r.customName = "mine"
        ws.addSession(r, in: f.id)
        ws.selected = r.id
        try store.save(ws)
        let loaded = store.load()
        #expect(loaded.tree == ws.tree)
        #expect(loaded.sessions[r.id]?.customName == "mine")
        #expect(loaded.sessions[r.id]?.restoreInput == "claude --resume abc")
        #expect(loaded.folders[f.id]?.directory == "/x")
        #expect(loaded.selected == r.id)
    }

    /// Claude's /rename: the first sync only records the conversation's name (the user's stays); a
    /// rename after that beats the user's own.
    @Test func agentNameFollowsTheLatestRename() {
        var ws = Workspace()
        var named = SessionRecord(cwd: "/repo", agent: .claude, title: "Thumbs", agentSessionId: "s1")
        named.customName = "Mine"
        var older = SessionRecord(cwd: "/repo", agent: .claude, title: "Thumbs", agentSessionId: "s2")
        older.customName = "Also mine"
        ws.addSession(named)
        ws.addSession(older)
        let baseline = ws.setAgentName("", for: named.id), firstSeen = ws.setAgentName("Old name", for: older.id)
        #expect(baseline && firstSeen)
        #expect(ws.sessions[named.id]?.displayTitle == "Mine" && ws.sessions[older.id]?.displayTitle == "Also mine")
        let renamed = ws.setAgentName("Thumb sizes", for: named.id)
        #expect(renamed && ws.sessions[named.id]?.customName == nil && ws.sessions[named.id]?.displayTitle == "Thumb sizes")
        // Claude writes the name again every turn: no change.
        ws.sessions[named.id]?.customName = "Mine again"
        let again = ws.setAgentName("Thumb sizes", for: named.id), unknown = ws.setAgentName("Other", for: UUID())
        #expect(!again && !unknown && ws.sessions[named.id]?.displayTitle == "Mine again")
    }

    @Test func corruptStateIsKeptAside() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        try Data("{nope".utf8).write(to: url)
        let ws = WorkspaceStore(url: url).load()
        #expect(ws.tree.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.contains { $0.hasPrefix("state.corrupt-") })
    }

    @Test func resumeCommands() {
        #expect(AgentKind.claude.resumeCommand(sessionId: "abc-1") == "claude --resume abc-1")
        #expect(AgentKind.opencode.resumeCommand(sessionId: "ses_X") == "opencode -s ses_X")
        #expect(AgentKind.pi.resumeCommand(sessionId: "/a b/c.jsonl") == "pi --session '/a b/c.jsonl'")
        #expect(shellQuote("it's") == "'it'\\''s'")
        var r = SessionRecord(cwd: "/", agent: .claude, agentSessionId: "s")
        r.bgJobId = "job1"
        #expect(r.restoreInput == "claude attach job1 || ! claude --bg --resume s || claude attach job1")
        r.agentRunning = false
        #expect(r.restoreInput == nil)
        #expect(r.reopenInput == "claude attach job1 || ! claude --bg --resume s || claude attach job1")
        r.agentSessionId = nil
        #expect(r.reopenInput == "claude attach job1")
    }
}
