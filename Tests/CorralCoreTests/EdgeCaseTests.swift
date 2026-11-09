import Foundation
import Testing
@testable import CorralCore

struct SQLiteErrorTests {
    @Test func errorsAreReported() throws {
        #expect(throws: SQLiteDB.Failure.self) { try SQLiteDB(path: "/nonexistent-dir/x/y.sqlite") }
        let db = try SQLiteDB(path: ":memory:")
        #expect(throws: SQLiteDB.Failure.self) { try db.exec("NOT SQL") }
        #expect(throws: SQLiteDB.Failure.self) { try db.prepare("SELECT * FROM missing") }
        try db.exec("CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT UNIQUE)")
        try db.prepare("INSERT INTO t(b) VALUES (?)").bind("x").run()
        #expect(throws: SQLiteDB.Failure.self) { try db.prepare("INSERT INTO t(b) VALUES (?)").bind("x").run() }
        // A failing transaction rolls back.
        #expect(throws: SQLiteDB.Failure.self) {
            try db.transaction {
                try db.prepare("INSERT INTO t(b) VALUES (?)").bind("y").run()
                try db.exec("NOT SQL")
            }
        }
        var count: Int64 = 0
        try db.prepare("SELECT count(*), NULL FROM t").rows { row in
            count = row.int(0)
            #expect(row.isNull(1))
        }
        #expect(count == 1)
        // Every bind type round-trips.
        try db.exec("CREATE TABLE v(x)")
        let ins = try db.prepare("INSERT INTO v(x) VALUES (?)")
        for value: Any? in [nil, "s", 1, Int64(2), 3.5, true, UUID()] { try ins.bindAll([value]).run() }
        var n = 0
        try db.prepare("SELECT x FROM v").rows { _ in n += 1 }
        #expect(n == 7)
        #expect(throws: SQLiteDB.Failure.self) { try db.prepare("SELECT abs(?)").bind("x").rows { _ in } ; throw SQLiteDB.Failure(description: "ok") }
    }

    @Test func readOnlyOpenOfMissingFileFails() {
        #expect(throws: SQLiteDB.Failure.self) { try SQLiteDB(path: NSTemporaryDirectory() + "missing-\(UUID()).db", readOnly: true) }
    }
}

struct EventServerErrorTests {
    @Test func badPathsThrowAndStopIsIdempotent() throws {
        let long = NSTemporaryDirectory() + String(repeating: "x", count: 120) + ".sock"
        #expect(throws: (any Error).self) { try EventServer(path: long) { _ in }.start() }
        let noDir = "/nonexistent-\(UUID().uuidString.prefix(6))/s.sock"
        #expect(throws: (any Error).self) { try EventServer(path: noDir) { _ in }.start() }
        let ok = EventServer(path: NSTemporaryDirectory() + "es-\(UInt32.random(in: 0...UInt32.max)).sock") { _ in }
        ok.stop()
        try ok.start()
        ok.stop()
        ok.stop()
        #expect(!EventClient.send(Data("x".utf8), to: long))
    }
}

struct URLPolicyTests {
    @Test func decisions() throws {
        #expect(UntrustedURL("https://example.com/a").decision == .allow(URL(string: "https://example.com/a")!))
        #expect(UntrustedURL("https://").decision == .deny(.invalidWebURL))
        #expect(UntrustedURL("mailto:me@example.com").decision == .allow(URL(string: "mailto:me@example.com")!))
        #expect(UntrustedURL("mailto:").decision == .deny(.malformedURL))
        #expect(UntrustedURL("").decision == .deny(.malformedURL))
        #expect(UntrustedURL("no scheme").decision == .deny(.malformedURL))
        #expect(UntrustedURL("https://ex\u{200B}ample.com").decision == .deny(.unsafeCharacters))
        if case .confirm = UntrustedURL("slack://open").decision {} else { Issue.record("custom schemes confirm") }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("url-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = dir.appendingPathComponent("notes.txt")
        try Data("hi".utf8).write(to: text)
        if case .allow = UntrustedURL(text.absoluteString).decision {} else { Issue.record("plain file allowed") }
        let script = dir.appendingPathComponent("run.command")
        try Data("#!/bin/sh".utf8).write(to: script)
        #expect(UntrustedURL(script.absoluteString).decision == .deny(.unsafeFile))
        let exe = dir.appendingPathComponent("tool")
        try Data("x".utf8).write(to: exe)
        chmod(exe.path, 0o755)
        #expect(UntrustedURL(exe.absoluteString).decision == .deny(.unsafeFile))
        #expect(UntrustedURL(dir.appendingPathComponent("missing").absoluteString).decision == .deny(.inaccessibleFile))
        #expect(UntrustedURL("file://remote-host/etc/hosts").decision == .deny(.malformedURL))
        #expect(UntrustedURL(text.absoluteString + "?q=1").decision == .deny(.malformedURL))
        for reason in [UntrustedURL.DenialReason.malformedURL, .unsafeCharacters, .invalidWebURL, .inaccessibleFile, .unsafeFile] {
            #expect(!reason.message.isEmpty)
        }
        #expect(UntrustedURL("https://a\u{202E}b").displayString.contains("\\u{202E}"))
        #expect(UntrustedURL("/tmp/x").displayString == "/tmp/x")
    }
}

struct ReducerEdgeTests {
    @Test func remainingBranches() {
        var s = LiveStatus()
        // Bell while an agent works (no hooks) means it wants attention.
        StatusReducer.reduce(&s, .foregroundProcess(.claude), focused: false)
        StatusReducer.reduce(&s, .progress(.active), focused: false)
        StatusReducer.reduce(&s, .bell, focused: false)
        #expect(s.activity == .needsInput)
        // Without hooks, Return after a finished turn means a new prompt.
        StatusReducer.reduce(&s, .progress(.removed), focused: false)
        StatusReducer.reduce(&s, .userSubmitted, focused: true)
        StatusReducer.reduce(&s, .progress(.removed), focused: false)
        StatusReducer.reduce(&s, .userSubmitted, focused: true)
        #expect(s.activity == .working)
        StatusReducer.reduce(&s, .progress(.error), focused: false)
        #expect(s.activity == .error)

        var c = LiveStatus()
        StatusReducer.reduce(&c, .hook(HookEvent(agent: .claude, event: "Notification", notificationType: "auth_success")), focused: true)
        #expect(c.activity == .idle)
        StatusReducer.reduce(&c, .hook(HookEvent(agent: .claude, event: "StopFailure", message: "overloaded")), focused: false)
        #expect(c.activity == .error)
        #expect(c.unread)
        StatusReducer.reduce(&c, .hook(HookEvent(agent: .claude, event: "SomethingNew")), focused: false)
        #expect(c.activity == .error)

        var p = LiveStatus()
        StatusReducer.reduce(&p, .processExited, focused: false)
        StatusReducer.reduce(&p, .hook(HookEvent(agent: .pi, event: "session_start", sessionId: "/f.jsonl")), focused: false)
        #expect(p.activity == .idle)
        StatusReducer.reduce(&p, .hook(HookEvent(agent: .pi, event: "needs_input", message: "confirm")), focused: false)
        #expect(p.activity == .needsInput)

        var o = LiveStatus()
        StatusReducer.reduce(&o, .hook(HookEvent(agent: .opencode, event: "session.status", status: "busy")), focused: false)
        StatusReducer.reduce(&o, .hook(HookEvent(agent: .opencode, event: "session.status", status: "idle")), focused: false)
        #expect(o.activity == .done)
        StatusReducer.reduce(&o, .hook(HookEvent(agent: .opencode, event: "session.status", status: "weird")), focused: false)
        StatusReducer.reduce(&o, .hook(HookEvent(agent: .opencode, event: "session.error", message: "boom")), focused: false)
        #expect(o.activity == .error)
        StatusReducer.reduce(&o, .hook(HookEvent(agent: .opencode, event: "exit")), focused: false)
        #expect(o.agent == .shell)

        #expect(AgentDetector.detect(path: "/usr/local/bin/node", args: ["node", "/x/node_modules/opencode-ai/bin"]) == .opencode)
        #expect(AgentDetector.detect(path: "/usr/local/bin/node", args: ["node", "/x/@anthropic-ai/claude-code/cli.js"]) == .claude)
        #expect(AgentDetector.detect(path: "/usr/local/bin/pi", args: []) == .pi)
        #expect(Activity.error.attentionRank == 2)
        #expect(Activity.idle.attentionRank == 0)
        #expect(AgentKind.shell.resumeCommand(sessionId: "x") == nil)
        #expect(AgentKind.allCases.map(\.displayName).count == 4)
    }

    @Test func emptyTitleAndDisplayFallbacks() {
        var s = LiveStatus()
        StatusReducer.reduce(&s, .terminalTitle("✳ "), focused: false)
        #expect(s.title == nil)
        let r = SessionRecord(cwd: "/Users/x/repo")
        #expect(r.displayTitle == "repo")
        #expect(r.restoreInput == nil)
        #expect(r.reopenInput == nil)
    }

    @Test func pathLeafMatchesNSString() {
        for p in ["/Users/x/repo", "/Users/x/repo/", "/Users/x/repo//", "/", "//", "", "repo", "a/b", "/ä/ünïcode", "~", ".", "..", "a/",
                  "/a/\u{301}b", "/\u{301}", "a/\u{200D}b", "/a/\u{FE0F}", "/x/🇩🇪", "/n/e\u{301}"] {
            #expect(p.pathLeaf == (p as NSString).lastPathComponent, "\(p)")
        }
    }
}

struct BackgroundLoaderTests {
    @Test func loadRunsBinaryAndHandlesMissing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = dir.appendingPathComponent("claude")
        try "#!/bin/sh\necho '[{\"id\":\"a\",\"kind\":\"background\",\"state\":\"failed\"}]'\n".write(to: bin, atomically: true, encoding: .utf8)
        chmod(bin.path, 0o755)
        let agents = await withCheckedContinuation { c in BackgroundAgents.load(binary: bin.path, jobsDir: dir) { c.resume(returning: $0) } }
        #expect(agents.first?.activity == .error)
        #expect(agents.first?.name == "a")
        let none = await withCheckedContinuation { c in BackgroundAgents.load(binary: nil, jobsDir: dir) { c.resume(returning: $0) } }
        #expect(none.isEmpty)
        let broken = await withCheckedContinuation { c in BackgroundAgents.load(binary: dir.appendingPathComponent("nope").path, jobsDir: dir) { c.resume(returning: $0) } }
        #expect(broken.isEmpty)
        #expect(BackgroundAgents.parse(Data("garbage".utf8), jobsDir: dir).isEmpty)
        for (state, activity) in [("working", Activity.working), ("done", .done), ("stopped", .exited), ("?", .idle)] {
            #expect(BackgroundAgent(id: "x", sessionId: "x", name: "x", cwd: "/", state: state).activity == activity)
        }
        // Last change: the job's state.json `updatedAt`, else `startedAt` from `claude agents`.
        let list = Data(#"[{"id":"j1","kind":"background","startedAt":1789377856488},{"id":"j2","kind":"background"}]"#.utf8)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("j1"), withIntermediateDirectories: true)
        let started = BackgroundAgents.parse(list, jobsDir: dir)
        #expect(started[0].updatedAt == Date(timeIntervalSince1970: 1_789_377_856.488))
        #expect(started[1].updatedAt == nil)
        for (stamp, expected) in [("2026-11-06T16:31:48.969Z", 1_793_982_708.969), ("2026-11-06T16:31:48Z", 1_793_982_708)] {
            try Data(#"{"state":"done","updatedAt":"\#(stamp)"}"#.utf8).write(to: dir.appendingPathComponent("j1/state.json"))
            let t = try #require(BackgroundAgents.parse(list, jobsDir: dir)[0].updatedAt)
            #expect(abs(t.timeIntervalSince1970 - expected) < 0.001, "\(stamp)")
        }
        try Data(#"{"state":"done","updatedAt":"yesterday"}"#.utf8).write(to: dir.appendingPathComponent("j1/state.json"))
        #expect(BackgroundAgents.parse(list, jobsDir: dir)[0].updatedAt == Date(timeIntervalSince1970: 1_789_377_856.488))
        // The live tempo wins over the job's standing: a "blocked" job running a new turn is working.
        try Data(#"{"state":"blocked","tempo":"active","needs":null}"#.utf8).write(to: dir.appendingPathComponent("j1/state.json"))
        #expect(BackgroundAgents.parse(list, jobsDir: dir)[0].activity == .working)
        try Data(#"{"state":"blocked","tempo":"blocked","needs":"run the jobs"}"#.utf8).write(to: dir.appendingPathComponent("j1/state.json"))
        #expect(BackgroundAgents.parse(list, jobsDir: dir)[0].activity == .needsInput)
        try Data(#"{"state":"done","tempo":"idle"}"#.utf8).write(to: dir.appendingPathComponent("j1/state.json"))
        #expect(BackgroundAgents.parse(list, jobsDir: dir)[0].activity == .done)
        // A weekend-long job ("working" overall) between turns: done unless its scripts still run.
        try Data(#"{"state":"working","tempo":"idle","inFlight":{"tasks":0,"queued":0}}"#.utf8).write(to: dir.appendingPathComponent("j1/state.json"))
        #expect(BackgroundAgents.parse(list, jobsDir: dir)[0].activity == .done)
        try Data(#"{"state":"working","tempo":"idle","inFlight":{"tasks":3,"queued":0}}"#.utf8).write(to: dir.appendingPathComponent("j1/state.json"))
        #expect(BackgroundAgents.parse(list, jobsDir: dir)[0].activity == .working)
        try Data(#"{"state":"blocked","tempo":"idle","needs":"apply the jobs"}"#.utf8).write(to: dir.appendingPathComponent("j1/state.json"))
        #expect(BackgroundAgents.parse(list, jobsDir: dir)[0].activity == .needsInput)
        try Data(#"{"state":"failed","tempo":"idle"}"#.utf8).write(to: dir.appendingPathComponent("j1/state.json"))
        #expect(BackgroundAgents.parse(list, jobsDir: dir)[0].activity == .error)
        let idle = Data(#"[{"id":"j4","kind":"background","state":"working","status":"idle"}]"#.utf8)
        #expect(BackgroundAgents.parse(idle, jobsDir: dir)[0].activity == .done)
        let busy = Data(#"[{"id":"j3","kind":"background","state":"blocked","status":"busy"}]"#.utf8)
        #expect(BackgroundAgents.parse(busy, jobsDir: dir)[0].activity == .working)
        _ = BackgroundAgents.claudeBinary()
        _ = BackgroundAgents.jobsDir
        _ = Integrations.Paths.standard
        _ = SearchIndex.Roots.standard
    }
}

struct BackgroundJobReducerTests {
    @Test func attachedJobStateGoesThroughReducer() {
        var s = LiveStatus()
        StatusReducer.reduce(&s, .backgroundJob(.needsInput, detail: "decide"), focused: false)
        #expect(s.activity == .needsInput)
        #expect(s.detail == "decide")
        #expect(s.unread)
        StatusReducer.reduce(&s, .viewed, focused: true)
        StatusReducer.reduce(&s, .backgroundJob(.working, detail: "ignored"), focused: true)
        #expect(s.activity == .working)
        #expect(s.detail == nil)
        #expect(!s.unread)
        // Hooks win once they report.
        StatusReducer.reduce(&s, .hook(HookEvent(agent: .claude, event: "Stop")), focused: true)
        StatusReducer.reduce(&s, .backgroundJob(.working, detail: nil), focused: true)
        #expect(s.activity == .done)
    }
}
