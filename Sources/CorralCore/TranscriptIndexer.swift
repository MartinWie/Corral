import Foundation

/// Reads agent transcripts into the search index. Append-only JSONL files are read
/// incrementally from the last indexed offset; rewritten files are re-indexed.
enum TranscriptIndexer {

    // MARK: Claude Code (~/.claude/projects/<project>/<session>.jsonl)

    static func indexClaude(db: SQLiteDB, root: URL, chunkSize: Int = 4 << 20) throws {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for project in projects {
            guard let files = try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: nil) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                let sid = file.deletingPathExtension().lastPathComponent
                try autoreleasepool {
                    try indexJSONL(db: db, file: file, key: "claude:\(sid)", chunkSize: chunkSize) { lines, state in
                        try parseClaude(db: db, lines: lines, key: "claude:\(sid)", sessionId: sid, state: &state)
                    }
                }
            }
        }
    }

    struct ParseState {
        var cwd: String?
        var custom: String?
        /// A rename inside the agent (Claude's `custom-title`; not `agent-name`, which Claude also
        /// writes on its own from the AI title).
        var renamed: String?
        var ai: String?
        var firstPrompt: String?
        var created: Double?
        var updated: Double?
    }

    private static let claudeMarkers: [Data] = [
        "\"type\":\"user\"", "\"type\":\"assistant\"", "\"type\":\"custom-title\"",
        "\"type\":\"ai-title\"", "\"type\":\"agent-name\"",
    ].map { Data($0.utf8) }
    private static let toolResultMarker = Data("\"toolUseResult\"".utf8)

    static func parseClaude(db: SQLiteDB, lines: [Data], key: String, sessionId: String, state: inout ParseState) throws {
        for line in lines {
            // Cheap byte checks first: transcripts are mostly tool output we don't index.
            guard claudeMarkers.contains(where: { line.range(of: $0) != nil }),
                  line.range(of: toolResultMarker) == nil,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            switch type {
            case "custom-title":
                state.custom = (obj["customTitle"] as? String) ?? state.custom
                state.renamed = state.custom
                continue
            case "agent-name": state.custom = state.custom ?? (obj["agentName"] as? String); continue
            case "ai-title": state.ai = (obj["aiTitle"] as? String) ?? state.ai; continue
            default: break
            }
            if obj["isSidechain"] as? Bool == true || obj["isMeta"] as? Bool == true { continue }
            if state.cwd == nil { state.cwd = obj["cwd"] as? String }
            let ts = (obj["timestamp"] as? String).flatMap(parseISO) ?? 0
            if ts > 0 {
                state.created = min(state.created ?? ts, ts)
                state.updated = max(state.updated ?? ts, ts)
            }
            guard let message = obj["message"] as? [String: Any] else { continue }
            if type == "user" {
                let text = claudeUserText(message["content"])
                guard let text, !text.isEmpty else { continue }
                if state.firstPrompt == nil { state.firstPrompt = firstLine(text) }
                try SearchIndex.insertDoc(db: db, key: key, role: "user", ts: ts, text: text)
            } else if type == "assistant", let blocks = message["content"] as? [[String: Any]] {
                for block in blocks {
                    switch block["type"] as? String {
                    case "text":
                        if let t = block["text"] as? String {
                            try SearchIndex.insertDoc(db: db, key: key, role: "assistant", ts: ts, text: t)
                        }
                    case "tool_use":
                        if block["name"] as? String == "Bash",
                           let input = block["input"] as? [String: Any], let cmd = input["command"] as? String {
                            try SearchIndex.insertDoc(db: db, key: key, role: "command", ts: ts, text: cmd)
                        }
                    default: break
                    }
                }
            }
        }
    }

    static func claudeUserText(_ content: Any?) -> String? {
        var parts: [String] = []
        if let s = content as? String {
            parts.append(s)
        } else if let blocks = content as? [[String: Any]] {
            for b in blocks where b["type"] as? String == "text" {
                if let t = b["text"] as? String { parts.append(t) }
            }
        }
        let text = parts.filter { !isClaudeSystemText($0) }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    static func isClaudeSystemText(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("<system-reminder>") || t.hasPrefix("<local-command-") || t.hasPrefix("<command-")
            || t.hasPrefix("<task-notification>") || t.hasPrefix("[Request interrupted")
    }

    // MARK: PI (~/.pi/agent/sessions/<cwd>/<ts>_<id>.jsonl)

    static func indexPi(db: SQLiteDB, root: URL, chunkSize: Int = 4 << 20) throws {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                let key = "pi:\(file.path)"
                try indexJSONL(db: db, file: file, key: key, chunkSize: chunkSize) { lines, state in
                    try parsePi(db: db, lines: lines, key: key, state: &state)
                }
            }
        }
    }

    static func parsePi(db: SQLiteDB, lines: [Data], key: String, state: inout ParseState) throws {
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            let ts = timestamp(obj["timestamp"]) ?? 0
            if ts > 0 {
                state.created = min(state.created ?? ts, ts)
                state.updated = max(state.updated ?? ts, ts)
            }
            switch type {
            case "session":
                state.cwd = state.cwd ?? obj["cwd"] as? String
            case "session_info":
                if let name = obj["name"] as? String, !name.isEmpty { state.custom = name; state.renamed = name }
            case "message":
                guard let msg = obj["message"] as? [String: Any], let role = msg["role"] as? String,
                      role == "user" || role == "assistant" else { continue }
                var text = msg["content"] as? String ?? ""
                if let blocks = msg["content"] as? [[String: Any]] {
                    text = blocks.filter { $0["type"] as? String == "text" }
                        .compactMap { $0["text"] as? String }.joined(separator: "\n")
                }
                guard !text.isEmpty else { continue }
                if role == "user", state.firstPrompt == nil { state.firstPrompt = firstLine(text) }
                try SearchIndex.insertDoc(db: db, key: key, role: role, ts: ts, text: text)
            default:
                continue
            }
        }
    }

    // MARK: Shared JSONL plumbing

    /// Reads new complete lines of `file` since the stored offset and hands them to `parse`.
    static func indexJSONL(db: SQLiteDB, file: URL, key: String, chunkSize: Int,
                           parse: ([Data], inout ParseState) throws -> Void) throws {
        var st = stat()
        guard stat(file.path, &st) == 0 else { return }
        let size = Int64(st.st_size)
        let inode = Int64(st.st_ino)

        var offset: Int64 = 0
        var knownInode: Int64 = -1
        try db.cached("SELECT offset, inode FROM sources WHERE path = ?").bind(file.path).rows { row in
            offset = row.int(0)
            knownInode = row.int(1)
        }
        let rewritten = knownInode != -1 && (knownInode != inode || size < offset)
        if rewritten { offset = 0 }
        guard size > offset else { return }

        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))

        var state = ParseState()
        let isAgent = key.hasPrefix("claude:") ? AgentKind.claude : .pi
        let sessionId = key.hasPrefix("claude:") ? String(key.dropFirst("claude:".count)) : file.path
        var consumed: Int64 = 0
        try db.transaction {
            if rewritten || offset == 0 { try SearchIndex.deleteDocs(db: db, key: key) }
            // Stream in chunks so a large transcript never sits in memory whole.
            var carry = Data()
            var done = false
            while !done {
                // Read buffers and JSONSerialization objects are autoreleased: drain per chunk,
                // or a first full index holds every transcript in memory until it ends.
                try autoreleasepool {
                    guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { done = true; return }
                    // Only the new chunk can hold a new last newline; never rescan the carry.
                    let before = carry.count
                    carry.append(chunk)
                    guard let nl = chunk.lastIndex(of: 0x0A) else { return }
                    let lastNewline = carry.startIndex + before + (nl - chunk.startIndex)
                    let complete = carry[carry.startIndex...lastNewline]
                    try parse(complete.split(separator: 0x0A), &state)
                    consumed += Int64(complete.count)
                    carry = Data(carry[(lastNewline + 1)...])
                }
            }
            guard consumed > 0 else { return }
            try SearchIndex.upsertSession(db: db, key: key, agent: isAgent, sessionId: sessionId, cwd: state.cwd,
                                          custom: state.custom, agentName: state.renamed, ai: state.ai,
                                          firstPrompt: state.firstPrompt,
                                          created: state.created, updated: state.updated)
            try db.cached("INSERT INTO sources(path, session_key, offset, inode) VALUES (?, ?, ?, ?) ON CONFLICT(path) DO UPDATE SET offset = excluded.offset, inode = excluded.inode")
                .bind(file.path, key, offset + consumed, inode).run()
        }
    }


    // MARK: Agent names from before `title_agent`

    private static let claudeRenameMarker = Data("\"type\":\"custom-title\"".utf8)
    private static let piNameMarker = Data("\"type\":\"session_info\"".utf8)

    /// Fills `title_agent` for transcripts indexed before the column existed. Only rename lines are
    /// parsed; the rest is a byte scan, so this costs far less than indexing them again.
    static func backfillAgentNames(db: SQLiteDB, chunkSize: Int = 4 << 20) throws {
        var files: [(path: String, key: String)] = []
        try db.prepare("SELECT path, session_key FROM sources WHERE session_key LIKE 'claude:%' OR session_key LIKE 'pi:%'")
            .rows { if let p = $0.string(0), let k = $0.string(1) { files.append((p, k)) } }
        for file in files {
            try autoreleasepool {
                let claude = file.key.hasPrefix("claude:")
                guard let name = lastName(in: URL(fileURLWithPath: file.path), marker: claude ? claudeRenameMarker : piNameMarker,
                                          field: claude ? "customTitle" : "name", chunkSize: chunkSize) else { return }
                try db.cached("UPDATE sessions SET title_agent = ? WHERE key = ? AND title_agent IS NULL").bind(name, file.key).run()
            }
        }
    }

    /// The last non-empty `field` of the lines holding `marker`.
    static func lastName(in file: URL, marker: Data, field: String, chunkSize: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var name: String?
        var carry = Data()
        func scan(_ line: Data) {
            guard line.range(of: marker) != nil,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let value = obj[field] as? String, !value.isEmpty else { return }
            name = value
        }
        while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
            autoreleasepool {
                carry.append(chunk)
                guard let nl = carry.lastIndex(of: 0x0A) else { return }
                carry[carry.startIndex..<nl].split(separator: 0x0A).forEach(scan)
                carry = Data(carry[(nl + 1)...])
            }
        }
        scan(carry)
        return name
    }

    // MARK: OpenCode (SQLite at ~/.local/share/opencode/opencode.db)

    static func indexOpenCode(db: SQLiteDB, dbURL: URL) throws {
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return }
        let oc: SQLiteDB
        do { oc = try SQLiteDB(path: dbURL.path, readOnly: true) } catch { return }

        var watermark: Int64 = 0
        try db.cached("SELECT v FROM meta WHERE k = 'opencode.watermark'").rows { watermark = Int64($0.string(0) ?? "0") ?? 0 }

        struct Sess { var id, dir, title: String; var created, updated: Int64 }
        var sessions: [Sess] = []
        try oc.prepare("""
        SELECT id, directory, title, time_created, time_updated FROM session
        WHERE parent_id IS NULL AND time_updated > ? ORDER BY time_updated
        """).bind(watermark).rows {
            sessions.append(Sess(id: $0.string(0) ?? "", dir: $0.string(1) ?? "", title: $0.string(2) ?? "",
                                 created: $0.int(3), updated: $0.int(4)))
        }
        guard !sessions.isEmpty else { return }

        let parts = try oc.prepare("""
        SELECT json_extract(p.data, '$.text'), json_extract(m.data, '$.role'), p.time_created
        FROM part p JOIN message m ON m.id = p.message_id
        WHERE p.session_id = ? AND json_extract(p.data, '$.type') = 'text'
          AND COALESCE(json_extract(p.data, '$.synthetic'), 0) = 0
        ORDER BY p.time_created
        """)
        // Batches keep each write transaction short so searches stay responsive during the first run.
        for batch in stride(from: 0, to: sessions.count, by: 50).map({ Array(sessions[$0..<min($0 + 50, sessions.count)]) }) {
            try db.transaction {
                for s in batch { try autoreleasepool {
                    let key = "opencode:\(s.id)"
                    try SearchIndex.deleteDocs(db: db, key: key)
                    var firstPrompt: String?
                    let title = s.title.hasPrefix("New session - ") ? nil : s.title
                    if let title { try SearchIndex.insertDoc(db: db, key: key, role: "title", ts: Double(s.updated) / 1000, text: title) }
                    try parts.bind(s.id).rows { row in
                        guard let text = row.string(0) else { return }
                        let role = row.string(1) ?? "assistant"
                        if role == "user", firstPrompt == nil { firstPrompt = firstLine(text) }
                        try SearchIndex.insertDoc(db: db, key: key, role: role, ts: Double(row.int(2)) / 1000, text: text)
                    }
                    try SearchIndex.upsertSession(db: db, key: key, agent: .opencode, sessionId: s.id, cwd: s.dir,
                                                  custom: nil, ai: title, firstPrompt: firstPrompt,
                                                  created: Double(s.created) / 1000, updated: Double(s.updated) / 1000)
                } }
                try db.cached("INSERT INTO meta(k, v) VALUES ('opencode.watermark', ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v")
                    .bind(String(batch.last!.updated)).run()
            }
        }
    }

    // MARK: Helpers

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoFormatterNoFraction = ISO8601DateFormatter()

    static func parseISO(_ s: String) -> Double? {
        (isoFormatter.date(from: s) ?? isoFormatterNoFraction.date(from: s))?.timeIntervalSince1970
    }

    static func timestamp(_ v: Any?) -> Double? {
        if let s = v as? String { return parseISO(s) }
        if let n = v as? Double { return n > 1e12 ? n / 1000 : n }
        if let n = v as? Int { return Double(n) > 1e12 ? Double(n) / 1000 : Double(n) }
        return nil
    }

    static func firstLine(_ s: String) -> String {
        let line = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
        return String(line.trimmingCharacters(in: .whitespaces).prefix(160))
    }
}
