import Foundation
import Testing
@testable import CorralCore

struct SearchIndexTests {
    struct Fixture {
        let dir: URL
        let index: SearchIndex
        let roots: SearchIndex.Roots
    }

    func fixture() throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let index = SearchIndex(path: dir.appendingPathComponent("index.sqlite").path)
        try index.open()
        let roots = SearchIndex.Roots(claudeProjects: dir.appendingPathComponent("projects"),
                                      opencodeDB: dir.appendingPathComponent("opencode/opencode.db"),
                                      piSessions: dir.appendingPathComponent("pi"))
        return Fixture(dir: dir, index: index, roots: roots)
    }

    func refresh(_ f: Fixture, _ sources: Set<SearchIndex.Source> = [.claude, .opencode, .pi]) async {
        await withCheckedContinuation { c in f.index.refresh(sources, roots: f.roots) { c.resume() } }
    }

    func search(_ f: Fixture, _ q: String) throws -> [SearchHit] {
        f.index.queue.sync {}  // let pending writes land first
        return try f.index.readQueue.sync { try f.index.searchSync(q) }
    }

    func line(_ obj: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self) + "\n"
    }

    func writeClaude(_ f: Fixture, sid: String, lines: [String]) throws -> URL {
        let proj = f.roots.claudeProjects.appendingPathComponent("-repo")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let file = proj.appendingPathComponent("\(sid).jsonl")
        try Data(lines.joined().utf8).write(to: file)
        return file
    }

    var claudeLines: [String] {
        [
            line(["type": "custom-title", "customTitle": "Fix thumb sizes", "sessionId": "s1"]),
            line(["type": "user", "cwd": "/repo", "timestamp": "2026-11-01T10:00:00.000Z", "isMeta": false,
                  "message": ["role": "user", "content": "Why are thumb sizes missing for HEIC uploads?"]]),
            line(["type": "user", "isMeta": true, "timestamp": "2026-11-01T10:00:01.000Z",
                  "message": ["role": "user", "content": "<system-reminder>secretreminderword</system-reminder>"]]),
            line(["type": "assistant", "timestamp": "2026-11-01T10:00:05.000Z",
                  "message": ["role": "assistant", "content": [
                      ["type": "thinking", "thinking": "hiddenthoughtword"],
                      ["type": "text", "text": "The resolver chain skips the Varnish fallback."],
                      ["type": "tool_use", "name": "Bash", "input": ["command": "rg -n thumbsize src/"]],
                  ]]]),
            line(["type": "user", "toolUseResult": ["stdout": "x"], "timestamp": "2026-11-01T10:00:06.000Z",
                  "message": ["role": "user", "content": [["type": "tool_result", "content": "toolresultword"]]]]),
        ]
    }

    @Test func indexesClaudeTranscript() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        _ = try writeClaude(f, sid: "s1", lines: claudeLines)
        await refresh(f, [.claude])

        let hits = try search(f, "thumb heic")
        #expect(hits.count == 1)
        #expect(hits[0].key == "claude:s1")
        #expect(hits[0].title == "Fix thumb sizes")
        #expect(hits[0].cwd == "/repo")
        #expect(hits[0].agent == .claude)
        #expect(hits[0].snippets.first?.text.contains("\u{1}") == true)

        #expect(try search(f, "varnish").count == 1)
        #expect(try search(f, "thumbsize").count == 1, "Bash commands are indexed")
        #expect(try search(f, "secretreminderword").isEmpty, "meta lines skipped")
        #expect(try search(f, "hiddenthoughtword").isEmpty, "thinking skipped")
        #expect(try search(f, "toolresultword").isEmpty, "tool results skipped")
    }

    @Test func incrementalAppendAndRewrite() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let file = try writeClaude(f, sid: "s2", lines: Array(claudeLines.prefix(2)))
        await refresh(f, [.claude])
        #expect(try search(f, "varnish").isEmpty)

        // Append a complete line plus a partial one: only the complete line is indexed.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(claudeLines[3].utf8))
        try handle.write(contentsOf: Data(#"{"type":"user","message":{"content":"partialword"#.utf8))
        try handle.close()
        await refresh(f, [.claude])
        #expect(try search(f, "varnish").count == 1)
        #expect(try search(f, "partialword").isEmpty)

        // Rewritten (shorter) file is re-indexed from scratch, without duplicates.
        try FileManager.default.removeItem(at: file)
        _ = try writeClaude(f, sid: "s2", lines: [line(["type": "user", "message": ["content": "brandnewcontent"]])])
        await refresh(f, [.claude])
        #expect(try search(f, "varnish").isEmpty)
        #expect(try search(f, "brandnewcontent").count == 1)
    }

    @Test func emptyQueryListsRecent() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        _ = try writeClaude(f, sid: "s1", lines: claudeLines)
        await refresh(f, [.claude])
        let recent = try search(f, "  ")
        #expect(recent.map(\.key) == ["claude:s1"])
    }

    @Test func scrollbackAndCustomTitle() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let id = UUID()
        f.index.addScrollback(session: id, title: "gradle build", cwd: "/repo",
                              text: "$ ./gradlew test\nBUILD FAILED in 3m\n", created: Date(), closed: Date())
        f.index.setCustomTitle(key: "corral:\(id.uuidString)", title: "Library flaky test")
        let hits = try search(f, "failed")
        #expect(hits.count == 1)
        #expect(hits[0].corralSessionId == id)
        #expect(try search(f, "flaky").count == 1)
        #expect(try search(f, "flaky")[0].title == "Library flaky test")
    }

    func agentNames(_ index: SearchIndex, _ keys: Set<String>) async -> [String: String]? {
        index.queue.sync {}
        return await withCheckedContinuation { c in index.agentNames(keys: keys) { c.resume(returning: $0) } }
    }

    /// The agent's own name (Claude's /rename) is kept apart from Corral's rename and follows new renames.
    @Test func agentNamesComeFromTranscripts() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let file = try writeClaude(f, sid: "s1", lines: claudeLines)
        // Claude writes `agent-name` on its own (from the AI title): not a rename.
        _ = try writeClaude(f, sid: "s2", lines: [claudeLines[1], line(["type": "agent-name", "agentName": "Thumbs", "sessionId": "s2"])])
        await refresh(f, [.claude])
        f.index.setCustomTitle(key: "claude:s1", title: "Library thumbs")
        // Unnamed conversations read "", unindexed ones are left out.
        #expect(await agentNames(f.index, ["claude:s1", "claude:s2", "claude:none"]) == ["claude:s1": "Fix thumb sizes", "claude:s2": ""])
        let h = try FileHandle(forWritingTo: file)
        try h.seekToEnd()
        try h.write(contentsOf: Data(line(["type": "custom-title", "customTitle": "HEIC thumbs", "sessionId": "s1"]).utf8))
        try h.close()
        await refresh(f, [.claude])
        #expect(await agentNames(f.index, ["claude:s1"]) == ["claude:s1": "HEIC thumbs"])
    }

    /// Indexes from before agent names gain the column, filled from the transcripts they already read.
    @Test func olderIndexBackfillsAgentNames() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let claude = dir.appendingPathComponent("c.jsonl"), pi = dir.appendingPathComponent("p.jsonl")
        try Data((claudeLines + [line(["type": "custom-title", "customTitle": "HEIC thumbs", "sessionId": "s1"]),
                                 line(["type": "agent-name", "agentName": "Later auto name", "sessionId": "s1"])]).joined().utf8)
            .write(to: claude)
        try Data([line(["type": "session_info", "name": "Garden beds"])].joined().utf8).write(to: pi)
        let path = dir.appendingPathComponent("index.sqlite").path
        try SQLiteDB(path: path).exec("""
        CREATE TABLE sessions(key TEXT PRIMARY KEY, agent TEXT, session_id TEXT, cwd TEXT,
            title_custom TEXT, title_ai TEXT, first_prompt TEXT, created REAL, updated REAL);
        CREATE TABLE sources(path TEXT PRIMARY KEY, session_key TEXT, offset INTEGER, inode INTEGER);
        INSERT INTO sessions(key, agent, session_id) VALUES ('claude:s1', 'claude', 's1'), ('pi:\(pi.path)', 'pi', '\(pi.path)'),
            ('claude:s3', 'claude', 's3');
        INSERT INTO sources(path, session_key, offset, inode) VALUES ('\(claude.path)', 'claude:s1', 1, 1),
            ('\(pi.path)', 'pi:\(pi.path)', 1, 1), ('/gone.jsonl', 'claude:s3', 1, 1);
        """)
        let index = SearchIndex(path: path)
        try index.open()
        #expect(await agentNames(index, ["claude:s1", "pi:\(pi.path)", "claude:s3"])
            == ["claude:s1": "HEIC thumbs", "pi:\(pi.path)": "Garden beds", "claude:s3": ""])
        // Done once: the flag is gone, a reopen doesn't scan again.
        var pending = false
        try index.queue.sync { try #require(index.db).prepare("SELECT 1 FROM meta WHERE k = 'agent_names'").rows { _ in pending = true } }
        #expect(!pending)
    }

    @Test func lastNameReadsAcrossChunks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("c.jsonl")
        try Data((claudeLines + [line(["type": "custom-title", "customTitle": "HEIC thumbs", "sessionId": "s1"])]).joined().utf8)
            .write(to: file)
        let marker = Data("\"type\":\"custom-title\"".utf8)
        #expect(TranscriptIndexer.lastName(in: file, marker: marker, field: "customTitle", chunkSize: 7) == "HEIC thumbs")
        #expect(TranscriptIndexer.lastName(in: dir.appendingPathComponent("none"), marker: marker, field: "customTitle", chunkSize: 7) == nil)
    }

    @Test func indexesOpenCodeDatabase() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        try FileManager.default.createDirectory(at: f.roots.opencodeDB.deletingLastPathComponent(), withIntermediateDirectories: true)
        let oc = try SQLiteDB(path: f.roots.opencodeDB.path)
        try oc.exec("""
        CREATE TABLE session(id TEXT PRIMARY KEY, project_id TEXT, parent_id TEXT, slug TEXT, directory TEXT, title TEXT,
            version TEXT, time_created INTEGER, time_updated INTEGER);
        CREATE TABLE message(id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
        CREATE TABLE part(id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
        INSERT INTO session VALUES ('ses_1','p',NULL,'s','/oc','Kafka consumer lag','1',1000,2000);
        INSERT INTO session VALUES ('ses_child','p','ses_1','s','/oc','child','1',1000,2000);
        INSERT INTO message VALUES ('m1','ses_1',1000,1000,'{"role":"user"}');
        INSERT INTO message VALUES ('m2','ses_1',1001,1001,'{"role":"assistant"}');
        INSERT INTO part VALUES ('p1','m1','ses_1',1000,1000,'{"type":"text","text":"why is consumer lag growing"}');
        INSERT INTO part VALUES ('p2','m2','ses_1',1001,1001,'{"type":"text","text":"rebalance storm detected"}');
        INSERT INTO part VALUES ('p3','m2','ses_1',1002,1002,'{"type":"tool","tool":"bash"}');
        """)
        await refresh(f, [.opencode])
        let hits = try search(f, "rebalance")
        #expect(hits.count == 1)
        #expect(hits[0].sessionId == "ses_1")
        #expect(hits[0].agent == .opencode)
        #expect(hits[0].title == "Kafka consumer lag")
        #expect(try search(f, "child").isEmpty)

        // Updated session is re-indexed (watermark), not duplicated.
        try oc.exec("""
        INSERT INTO part VALUES ('p4','m2','ses_1',1003,1003,'{"type":"text","text":"fixed by raising max poll interval"}');
        UPDATE session SET time_updated = 3000 WHERE id = 'ses_1';
        """)
        await refresh(f, [.opencode])
        #expect(try search(f, "interval").count == 1)
        #expect(try search(f, "rebalance")[0].snippets.count == 1)
    }

    @Test func indexesPiSessions() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let dir = f.roots.piSessions.appendingPathComponent("--repo--")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("2026_abc.jsonl")
        let text = line(["type": "session", "id": "abc", "cwd": "/repo", "timestamp": "2026-11-01T10:00:00Z"])
            + line(["type": "message", "timestamp": "2026-11-01T10:00:01Z",
                    "message": ["role": "user", "content": [["type": "text", "text": "refactor the websocket client"]]]])
            + line(["type": "message", "message": ["role": "assistant", "content": "Done, extracted reconnect logic"]])
        try Data(text.utf8).write(to: file)
        await refresh(f, [.pi])
        let hits = try search(f, "websocket")
        #expect(hits.count == 1)
        #expect(hits[0].agent == .pi)
        #expect(URL(fileURLWithPath: hits[0].sessionId).resolvingSymlinksInPath() == file.resolvingSymlinksInPath())
        #expect(hits[0].title == "refactor the websocket client")
        #expect(try search(f, "reconnect").count == 1)
    }

    @Test func ftsQueryEscaping() {
        #expect(SearchIndex.ftsQuery("foo bar") == #""foo"* "bar"*"#)
        #expect(SearchIndex.ftsQuery(#"a"b"#) == #""a""b"*"#)
        #expect(SearchIndex.ftsQuery("  ") == "")
    }

    @Test func hostileQueriesDoNotThrow() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        _ = try writeClaude(f, sid: "s1", lines: claudeLines)
        await refresh(f, [.claude])
        for q in ["AND", "OR NOT", "\"", "*", "col:val", "(", "NEAR(a b)", "thumb*"] {
            _ = try search(f, q)
        }
    }
}

struct SnippetTests {
    /// Markdown and HTML noise goes; a link keeps the part the query is in; the match leads.
    @Test func readableSnippetsLeadWithTheMatch() {
        let terms = ["https://example.atlassian.net/browse/APP-91714"]
        let md = "Some long intro text that goes on and on before the link we want to see appears here. "
            + "![JIRA](https://img.shields.io/badge/JIRA-APP--91714-blue?logo=jira) moves to "
            + "[APP-91714](https://example.atlassian.net/browse/APP-91714) **now** and `then`"
        let s = SearchIndex.snippet(md, terms: terms)
        #expect(!s.contains("shields.io") && !s.contains("](") && !s.contains("**") && !s.contains("`"))
        #expect(s.contains("\u{1}https://example.atlassian.net/browse/APP-91714\u{2}"))
        // At most `radius` characters (plus "…") before the match.
        let lead = s.components(separatedBy: "\u{1}")[0]
        #expect(lead.count <= 26)
        // A label that holds the match stays the label.
        #expect(SearchIndex.snippet("see [Kafka lag](https://x/y) here", terms: ["kafka"]).contains("\u{1}Kafka\u{2} lag here"))
        #expect(SearchIndex.readable("<tr><td>CellData</td></tr>  a\n\nb", terms: []) == "CellData a b")
        // A match only inside a removed image keeps the raw text.
        #expect(SearchIndex.snippet("![x](https://img/badge-qq7)", terms: ["badge"]).contains("\u{1}badge\u{2}"))
    }

    /// A short title match never swallows the messages; code stays as typed; cuts keep whole characters.
    @Test func titlesCodeAndCharacterBoundaries() {
        func s(_ role: String, _ t: String) -> SearchSnippet { SearchSnippet(role: role, text: t, date: nil) }
        let out = SearchIndex.distinct([s("title", "\u{1}Kafka\u{2}"), s("user", "why does the \u{1}kafka\u{2} consumer lag"),
                                        s("command", "restart \u{1}kafka\u{2} broker 3")], limit: 3)
        #expect(out.map(\.role) == ["user", "command"])
        #expect(SearchIndex.distinct([s("title", "\u{1}Kafka\u{2}")], limit: 3).count == 1)
        for code in ["List<String> foo", "Vec<Option<T>>", "if a<b && c>d then", "snake__case__name"] {
            #expect(SearchIndex.readable(code, terms: []) == code, "\(code)")
        }
        #expect(SearchIndex.readable("**bold** and `code` and <b>tag</b>", terms: []) == "bold and code and tag")
        #expect(SearchIndex.snippet("cd <dir> && ls **/*.md", terms: ["ls"], code: true).contains("<dir> && \u{1}ls\u{2} **/*.md"))
        // A cut never splits an emoji or leaves a stray combining mark.
        let emoji = String(repeating: "👍🏽", count: 40) + " match " + String(repeating: "é", count: 200)
        let out2 = SearchIndex.snippet(emoji, terms: ["match"])
        #expect(!out2.contains("\u{FFFD}"))
        #expect(out2.unicodeScalars.first { $0.properties.generalCategory == .nonspacingMark } == nil
                || out2.hasPrefix("…👍") || out2.hasPrefix("👍"))
    }

    @Test func distinctDropsRepeatedPassages() {
        func s(_ t: String) -> SearchSnippet { SearchSnippet(role: "user", text: t, date: nil) }
        let out = SearchIndex.distinct([s("…what about \u{1}X\u{2}"), s("what about \u{1}x\u{2}…"), s("other \u{1}X\u{2} text"),
                                        s("about \u{1}X\u{2}"), s("third"), s("fourth")], limit: 3)
        // "about X" is much shorter than "what about X": a different passage, not a repeat.
        #expect(out.map(\.text) == ["…what about \u{1}X\u{2}", "other \u{1}X\u{2} text", "about \u{1}X\u{2}"])
    }

    @Test func windowAroundFirstMatchWithMarkers() {
        let text = String(repeating: "padding words here ", count: 20) + "The Kafka consumer lag grew; kafka again." + String(repeating: " tail", count: 50)
        let s = SearchIndex.snippet(text, terms: ["kafka", "lag"])
        #expect(s.hasPrefix("…"))
        #expect(s.hasSuffix("…"))
        #expect(s.contains("\u{1}Kafka\u{2} consumer \u{1}lag\u{2}"))
        #expect(s.contains("\u{1}kafka\u{2} again"))
    }

    @Test func wordPrefixOnlyAndNoMatch() {
        #expect(!SearchIndex.snippet("unkafka", terms: ["kafka"]).contains("\u{1}"))
        #expect(SearchIndex.snippet("Zürich office", terms: ["zurich"]).contains("\u{1}Zürich\u{2}"))
        #expect(SearchIndex.snippet("short", terms: ["none"]) == "short")
        #expect(SearchIndex.snippet("", terms: ["x"]) == "")
        #expect(SearchIndex.terms(#"  "a" b* "#) == ["a", "b"])
    }
}

struct StreamingIndexTests {
    @Test func linesSpanningChunksAreIndexedOnce() async throws {
        let t = SearchIndexTests()
        let f = try t.fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        f.index.chunkSize = 64  // force many chunk boundaries inside lines
        let lines = (0..<40).map { i in
            t.line(["type": "user", "timestamp": "2026-11-01T10:00:00Z", "message": ["content": "chunkword\(i) " + String(repeating: "x", count: i * 7)]])
        }
        _ = try t.writeClaude(f, sid: "big", lines: lines)
        await t.refresh(f, [.claude])
        #expect(try t.search(f, "chunkword39").count == 1)
        #expect(try t.search(f, "chunkword0").first?.snippets.count == 1)
    }
}

struct SearchFillTests {
    @Test func manyShortDocsDoNotCrowdOutOtherSessions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = SearchIndex(path: dir.appendingPathComponent("i.sqlite").path)
        try index.open()
        try index.queue.sync {
            let db = index.db!
            try db.transaction {
                // 3 heavy sessions with 1,000 short docs each: they win bm25.
                for h in 0..<3 {
                    for _ in 0..<1000 { try SearchIndex.insertDoc(db: db, key: "claude:heavy\(h)", role: "command", ts: 1, text: "git status") }
                    try SearchIndex.upsertSession(db: db, key: "claude:heavy\(h)", agent: .claude, sessionId: "heavy\(h)", cwd: "/", custom: nil, ai: nil, firstPrompt: nil, created: 1, updated: 1)
                }
                // 50 sessions with one long doc mentioning git once.
                for l in 0..<50 {
                    let text = (0..<300).map { "word\($0)" }.joined(separator: " ") + " git " + (0..<300).map { "tail\($0)" }.joined(separator: " ")
                    try SearchIndex.insertDoc(db: db, key: "claude:long\(l)", role: "assistant", ts: 1, text: text)
                    try SearchIndex.upsertSession(db: db, key: "claude:long\(l)", agent: .claude, sessionId: "long\(l)", cwd: "/", custom: nil, ai: nil, firstPrompt: nil, created: 1, updated: 1)
                }
            }
        }
        let hits = try index.readQueue.sync { try index.searchSync("git", limit: 80) }
        #expect(hits.count == 53)
        #expect(hits.prefix(3).allSatisfy { $0.sessionId.hasPrefix("heavy") })
        // 1,000 identical matches: one line plus the count, not three copies of the same text.
        #expect(hits.first?.snippets.count == 1)
        #expect(hits.first?.matchCount == 1000)
        #expect(hits.last?.snippets.first?.text.contains("\u{1}git\u{2}") == true)
        let few = try index.readQueue.sync { try index.searchSync("git", limit: 5) }
        #expect(few.count == 5)
    }
}

struct SearchDetailTests {
    @Test func detailListsEveryMatchChronologicallyWithContext() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = SearchIndex(path: dir.appendingPathComponent("i.sqlite").path)
        try index.open()
        let key = "claude:s1"
        try index.queue.sync {
            let db = index.db!
            try db.transaction {
                try SearchIndex.upsertSession(db: db, key: key, agent: .claude, sessionId: "s1", cwd: "/w", custom: nil, ai: "Backfill",
                                              firstPrompt: "start the backfill", created: 100, updated: 900)
                try SearchIndex.insertDoc(db: db, key: key, role: "assistant", ts: 300, text: "Second: the backfill job is running " + String(repeating: "and on ", count: 30))
                try SearchIndex.insertDoc(db: db, key: key, role: "user", ts: 200, text: "First: start the backfill please")
                try SearchIndex.insertDoc(db: db, key: key, role: "command", ts: 400, text: "kubectl get jobs")
                for i in 0..<5 { try SearchIndex.insertDoc(db: db, key: key, role: "assistant", ts: 500 + Double(i), text: "backfill \(i)") }
            }
        }
        let d = try index.readQueue.sync { try index.detailSync(key: key, query: "backfill", limit: 4) }
        #expect(d.total == 7)
        #expect(d.matches.count == 4)
        #expect(d.matches.map(\.role) == ["user", "assistant", "assistant", "assistant"])
        #expect(d.matches[0].text.contains("\u{1}backfill\u{2}"))
        // Wide context: far more than a list line.
        #expect(d.matches[1].text.count > 160)
        #expect(d.created == Date(timeIntervalSince1970: 100) && d.updated == Date(timeIntervalSince1970: 900))

        // No query: the latest messages (no commands), oldest first.
        let latest = try index.readQueue.sync { try index.detailSync(key: key, query: "") }
        #expect(latest.matches.first?.date == Date(timeIntervalSince1970: 200))
        #expect(!latest.matches.contains { $0.role == "command" })
        #expect(try index.readQueue.sync { try index.detailSync(key: "claude:none", query: "backfill") }.total == 0)

        let viaQueue = await withCheckedContinuation { c in index.detail(key: key, query: "backfill") { c.resume(returning: $0) } }
        #expect(viaQueue.total == 7)
    }
}

struct SearchProseFirstTests {
    /// Commands are short and win bm25; the row's line should still be what was said about it.
    @Test func promptsAndAnswersLeadCommands() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = SearchIndex(path: dir.appendingPathComponent("i.sqlite").path)
        try index.open()
        try index.queue.sync {
            let db = index.db!
            try db.transaction {
                try SearchIndex.upsertSession(db: db, key: "claude:p", agent: .claude, sessionId: "p", cwd: "/", custom: nil, ai: nil,
                                              firstPrompt: nil, created: 100, updated: 900)
                for i in 0..<5 { try SearchIndex.insertDoc(db: db, key: "claude:p", role: "command", ts: Double(i), text: "rg celldata \(i)") }
                try SearchIndex.insertDoc(db: db, key: "claude:p", role: "user", ts: 10,
                                          text: "why does the celldata backfill skip June files? " + String(repeating: "context ", count: 60))
            }
        }
        let hit = try #require(try index.readQueue.sync { try index.searchSync("celldata") }.first)
        #expect(hit.snippets.first?.role == "user")
        #expect(hit.matchCount == 6)
        #expect(hit.created == Date(timeIntervalSince1970: 100))
    }
}
