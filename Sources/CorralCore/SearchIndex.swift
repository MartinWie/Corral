import Foundation

public struct SearchSnippet: Equatable, Sendable {
    public var role: String
    /// Matched terms are wrapped in \u{1} ... \u{2}.
    public var text: String
    public var date: Date?
}

/// One session in depth, for the search preview: when it ran and every matching message in order.
public struct SearchDetail: Equatable, Sendable {
    public var created: Date?
    public var updated: Date?
    /// All matching messages (`matches` holds the first `limit` of them, chronologically).
    public var total: Int
    public var matches: [SearchSnippet]

    public init(created: Date? = nil, updated: Date? = nil, total: Int = 0, matches: [SearchSnippet] = []) {
        self.created = created
        self.updated = updated
        self.total = total
        self.matches = matches
    }
}

public struct SearchHit: Equatable, Sendable {
    public var key: String
    public var agent: AgentKind
    /// Agent session id (Claude/OpenCode), session file (PI) or Corral session UUID (shell scrollback).
    public var sessionId: String
    public var cwd: String
    public var title: String
    public var updated: Date?
    public var snippets: [SearchSnippet]
    /// Messages in the session that match the query (0 for the recent list).
    public var matchCount: Int = 0
    /// When the session started (its first indexed message).
    public var created: Date?

    public var corralSessionId: UUID? {
        key.hasPrefix("corral:") ? UUID(uuidString: sessionId) : nil
    }
}

/// SQLite FTS5 index over agent transcripts and closed shell scrollback.
/// All work happens on a private serial queue; callbacks arrive on the main queue.
public final class SearchIndex {
    public let path: String
    /// Writer queue (indexing). Searches use their own connection and queue so they never
    /// wait behind a long index run; WAL lets the reader see committed batches.
    let queue = DispatchQueue(label: "corral.index", qos: .utility)
    let readQueue = DispatchQueue(label: "corral.search", qos: .userInitiated)
    var db: SQLiteDB?
    var readDB: SQLiteDB?
    public private(set) var lastError: String?
    /// Read size for streaming transcripts (tests shrink it to exercise chunk boundaries).
    var chunkSize = 4 << 20
    public var onIndexed: (() -> Void)?

    public init(path: String = CorralPaths.index.path) {
        self.path = path
    }

    /// Opens (and migrates) the index. Synchronous so callers know whether search works.
    public func open() throws {
        try queue.sync {
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let db = try SQLiteDB(path: path)
            try db.exec("""
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=NORMAL;
            CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT);
            CREATE TABLE IF NOT EXISTS sources(path TEXT PRIMARY KEY, session_key TEXT, offset INTEGER, inode INTEGER);
            CREATE TABLE IF NOT EXISTS sessions(
                key TEXT PRIMARY KEY, agent TEXT, session_id TEXT, cwd TEXT,
                title_custom TEXT, title_ai TEXT, first_prompt TEXT,
                created REAL, updated REAL);
            CREATE TABLE IF NOT EXISTS doc_map(id INTEGER PRIMARY KEY, session_key TEXT NOT NULL, role TEXT, ts REAL);
            CREATE INDEX IF NOT EXISTS doc_map_session ON doc_map(session_key, role);
            CREATE VIRTUAL TABLE IF NOT EXISTS docs USING fts5(text, tokenize='unicode61 remove_diacritics 2');
            """)
            self.db = db
        }
        try readQueue.sync {
            readDB = try SQLiteDB(path: path)
            try readDB?.exec("PRAGMA query_only = ON;")
        }
    }

    // MARK: Indexing

    public struct Roots: Sendable {
        public var claudeProjects: URL
        public var opencodeDB: URL
        public var piSessions: URL

        public init(claudeProjects: URL, opencodeDB: URL, piSessions: URL) {
            self.claudeProjects = claudeProjects
            self.opencodeDB = opencodeDB
            self.piSessions = piSessions
        }

        public static var standard: Roots {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let claudeDir = ShellEnvironment.value("CLAUDE_CONFIG_DIR")
                .map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".claude")
            let xdgData = ShellEnvironment.value("XDG_DATA_HOME")
                .map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".local/share")
            return Roots(
                claudeProjects: claudeDir.appendingPathComponent("projects"),
                opencodeDB: xdgData.appendingPathComponent("opencode/opencode.db"),
                piSessions: home.appendingPathComponent(".pi/agent/sessions"))
        }
    }

    public enum Source: Sendable { case claude, opencode, pi }

    /// Incrementally indexes the given sources (all by default).
    public func refresh(_ sources: Set<Source> = [.claude, .opencode, .pi], roots: Roots = .standard,
                        completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            do {
                if sources.contains(.claude) { try TranscriptIndexer.indexClaude(db: db, root: roots.claudeProjects, chunkSize: self.chunkSize) }
                if sources.contains(.opencode) { try TranscriptIndexer.indexOpenCode(db: db, dbURL: roots.opencodeDB) }
                if sources.contains(.pi) { try TranscriptIndexer.indexPi(db: db, root: roots.piSessions, chunkSize: self.chunkSize) }
                self.lastError = nil
            } catch {
                self.lastError = "\(error)"
                NSLog("Corral index: \(error)")
            }
            DispatchQueue.main.async {
                completion?()
                self.onIndexed?()
            }
        }
    }

    /// Stores the final scrollback of a closed shell session so it stays searchable.
    public func addScrollback(session: UUID, title: String, cwd: String, text: String, created: Date, closed: Date) {
        queue.async { [weak self] in
            guard let db = self?.db else { return }
            let key = "corral:\(session.uuidString)"
            do {
                try db.transaction {
                    try Self.deleteDocs(db: db, key: key)
                    try Self.upsertSession(db: db, key: key, agent: .shell, sessionId: session.uuidString, cwd: cwd,
                                           custom: title, ai: nil, firstPrompt: nil,
                                           created: created.timeIntervalSince1970, updated: closed.timeIntervalSince1970)
                    try Self.insertDoc(db: db, key: key, role: "title", ts: closed.timeIntervalSince1970, text: title)
                    for chunk in Self.chunks(of: text, size: 4000) {
                        try Self.insertDoc(db: db, key: key, role: "terminal", ts: closed.timeIntervalSince1970, text: chunk)
                    }
                }
            } catch {
                NSLog("Corral index scrollback: \(error)")
            }
        }
    }

    /// Records a user-chosen name for an agent session so it is searchable by that name.
    public func setCustomTitle(key: String, title: String?) {
        queue.async { [weak self] in
            guard let db = self?.db else { return }
            try? db.transaction {
                try db.prepare("UPDATE sessions SET title_custom = ? WHERE key = ?").bind(title, key).run()
                try db.prepare("DELETE FROM docs WHERE rowid IN (SELECT id FROM doc_map WHERE session_key = ? AND role = 'name')").bind(key).run()
                try db.prepare("DELETE FROM doc_map WHERE session_key = ? AND role = 'name'").bind(key).run()
                if let title, !title.isEmpty {
                    try Self.insertDoc(db: db, key: key, role: "name", ts: Date().timeIntervalSince1970, text: title)
                }
            }
        }
    }

    public func removeSession(key: String) {
        queue.async { [weak self] in
            guard let db = self?.db else { return }
            try? db.transaction {
                try Self.deleteDocs(db: db, key: key)
                try db.prepare("DELETE FROM sessions WHERE key = ?").bind(key).run()
            }
        }
    }

    // MARK: Search

    /// Full-text search. Empty query lists the most recent sessions.
    public func search(_ query: String, limit: Int = 60, completion: @escaping ([SearchHit]) -> Void) {
        readQueue.async { [weak self] in
            var hits: [SearchHit] = []
            if let self { hits = (try? self.searchSync(query, limit: limit)) ?? [] }
            DispatchQueue.main.async { completion(hits) }
        }
    }

    /// Call on `readQueue`.
    public func searchSync(_ query: String, limit: Int = 60) throws -> [SearchHit] {
        guard let db = readDB else { return [] }
        let match = Self.ftsQuery(query)
        if match.isEmpty { return try recent(db: db, limit: limit) }

        // Phase 1: walk matches best-first; the first `limit` sessions keep their 2 best prose docs and 2 best others and
        // count their matching messages. No fixed row cap: a few sessions with many short matching
        // docs must not crowd out the rest. bm25 ordering has already found every match, so walking
        // the rest for the counts is cheap (a second MATCH to count would not be).
        var order: [String] = []
        var picked: [String: [Int64]] = [:]
        var counts: [String: Int] = [:]
        var proseIds = Set<Int64>()
        try db.cached("""
        SELECT m.session_key, docs.rowid, m.role FROM docs JOIN doc_map m ON m.id = docs.rowid
        WHERE docs MATCH ? ORDER BY bm25(docs)
        """).bind(match).scan({ row in
            guard let key = row.string(0) else { return true }
            if picked[key] == nil {
                guard order.count < limit else { return true }
                order.append(key)
                picked[key] = []
            }
            let role = row.string(2) ?? ""
            let prose = role == "user" || role == "assistant"
            let kept = picked[key]!.filter { proseIds.contains($0) == prose }.count
            if kept < 2 {
                picked[key]!.append(row.int(1))
                if prose { proseIds.insert(row.int(1)) }
            }
            if role != "title" && role != "name" { counts[key, default: 0] += 1 }
            return true
        })
        // Phase 2: fetch the picked docs by rowid (no second MATCH) and cut snippets here.
        var snippets: [Int64: SearchSnippet] = [:]
        let ids = picked.values.flatMap { $0 }
        if !ids.isEmpty {
            let terms = Self.terms(query)
            let list = ids.map(String.init).joined(separator: ",")
            try db.prepare("""
            SELECT docs.rowid, m.role, m.ts, docs.text FROM docs JOIN doc_map m ON m.id = docs.rowid
            WHERE docs.rowid IN (\(list))
            """).rows { row in
                let ts = row.double(2)
                let role = row.string(1) ?? ""
                snippets[row.int(0)] = SearchSnippet(role: role,
                                                     text: Self.snippet(row.string(3) ?? "", terms: terms, code: Self.isCode(role)),
                                                     date: ts > 0 ? Date(timeIntervalSince1970: ts) : nil)
            }
        }
        var grouped: [String: [SearchSnippet]] = [:]
        for (key, rowids) in picked {
            // Prompts and answers before commands and output: they say what the session was about.
            let ordered = rowids.filter(proseIds.contains) + rowids.filter { !proseIds.contains($0) }
            grouped[key] = Self.distinct(ordered.compactMap { snippets[$0] }, limit: 3)
        }
        let meta = try sessionMeta(db: db, keys: order)
        return order.compactMap { key in
            guard var hit = meta[key] else { return nil }
            hit.snippets = grouped[key] ?? []
            hit.matchCount = counts[key] ?? hit.snippets.count
            return hit
        }
    }

    /// Snippets minus repeats: the same passage (one URL pasted into three prompts) shows once.
    /// Title/name docs only when nothing else matched (the row shows the title already); a short
    /// passage counts as a repeat only when it is nearly as long as the one containing it.
    static func distinct(_ snippets: [SearchSnippet], limit: Int) -> [SearchSnippet] {
        func plain(_ s: String) -> String {
            s.filter { $0 != "\u{1}" && $0 != "\u{2}" && $0 != "…" }.lowercased()
                .trimmingCharacters(in: .whitespaces)
        }
        func repeats(_ a: String, _ b: String) -> Bool {
            let (short, long) = a.count <= b.count ? (a, b) : (b, a)
            return short == long || (long.contains(short) && Double(short.count) >= 0.8 * Double(long.count))
        }
        let messages = snippets.filter { $0.role != "title" && $0.role != "name" }
        var out: [SearchSnippet] = []
        var seen: [String] = []
        for s in messages.isEmpty ? snippets : messages {
            let p = plain(s.text)
            if seen.contains(where: { repeats($0, p) }) { continue }
            seen.append(p)
            out.append(s)
            if out.count == limit { break }
        }
        return out
    }

    /// Commands and terminal output are code: never "cleaned" (`List<String>`, `snake__case`).
    static func isCode(_ role: String) -> Bool { role == "command" || role == "terminal" }

    // MARK: Preview

    /// One session's details and its matching messages with wide context; completion on main.
    public func detail(key: String, query: String, limit: Int = 40, completion: @escaping (SearchDetail) -> Void) {
        readQueue.async { [weak self] in
            let d = (try? self?.detailSync(key: key, query: query, limit: limit)) ?? nil
            DispatchQueue.main.async { completion(d ?? SearchDetail()) }
        }
    }

    /// Call on `readQueue`. Without a query: the latest messages, so the preview still shows what
    /// the session was about.
    public func detailSync(key: String, query: String, limit: Int = 40) throws -> SearchDetail {
        guard let db = readDB else { return SearchDetail() }
        var d = SearchDetail()
        try db.prepare("SELECT created, updated FROM sessions WHERE key = ?").bind(key).rows { row in
            let c = row.double(0), u = row.double(1)
            d.created = c > 0 ? Date(timeIntervalSince1970: c) : nil
            d.updated = u > 0 ? Date(timeIntervalSince1970: u) : nil
        }
        let match = Self.ftsQuery(query)
        let terms = Self.terms(query)
        // Which docs to show, in order (scrollback chunks share one timestamp: id breaks the tie).
        var picks: [(id: Int64, role: String, ts: Double)] = []
        if match.isEmpty {
            try db.prepare("""
            SELECT m.id, m.role, m.ts FROM doc_map m
            WHERE m.session_key = ? AND m.role IN ('user', 'assistant', 'terminal') ORDER BY m.ts DESC, m.id DESC LIMIT ?
            """).bind(key, min(limit, 12)).rows { picks.append(($0.int(0), $0.string(1) ?? "", $0.double(2))) }
            picks.reverse()
            d.total = picks.count
        } else {
            // One MATCH: every matching message's id/role/time gives the total; text only for the first
            // `limit`. Title/name docs are left out (the preview shows the title), as in the list's count.
            try db.prepare("""
            SELECT docs.rowid, m.role, m.ts FROM docs JOIN doc_map m ON m.id = docs.rowid
            WHERE docs MATCH ? AND m.session_key = ? AND m.role NOT IN ('title', 'name') ORDER BY m.ts, m.id
            """).bind(match, key).rows { picks.append(($0.int(0), $0.string(1) ?? "", $0.double(2))) }
            d.total = picks.count
            picks = Array(picks.prefix(limit))
        }
        guard !picks.isEmpty else { return d }
        var texts: [Int64: String] = [:]
        try db.prepare("SELECT rowid, text FROM docs WHERE rowid IN (\(picks.map { String($0.id) }.joined(separator: ",")))")
            .rows { texts[$0.int(0)] = $0.string(1) ?? "" }
        for p in picks {
            d.matches.append(SearchSnippet(role: p.role,
                                           text: Self.snippet(texts[p.id] ?? "", terms: terms, radius: match.isEmpty ? 0 : 200,
                                                              length: 560, code: Self.isCode(p.role)),
                                           date: p.ts > 0 ? Date(timeIntervalSince1970: p.ts) : nil))
        }
        return d
    }

    private func recent(db: SQLiteDB, limit: Int) throws -> [SearchHit] {
        var hits: [SearchHit] = []
        try db.prepare("SELECT key, agent, session_id, cwd, title_custom, title_ai, first_prompt, updated, created FROM sessions ORDER BY updated DESC LIMIT ?")
            .bind(limit).rows { hits.append(Self.hit(from: $0)) }
        return hits
    }

    private func sessionMeta(db: SQLiteDB, keys: [String]) throws -> [String: SearchHit] {
        guard !keys.isEmpty else { return [:] }
        var out: [String: SearchHit] = [:]
        let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ",")
        try db.prepare("SELECT key, agent, session_id, cwd, title_custom, title_ai, first_prompt, updated, created FROM sessions WHERE key IN (\(placeholders))")
            .bindAll(keys).rows { row in
                let hit = Self.hit(from: row)
                out[hit.key] = hit
            }
        return out
    }

    static func hit(from row: SQLiteDB.Row) -> SearchHit {
        let title = [row.string(4), row.string(5), row.string(6)].compactMap { $0 }.first { !$0.isEmpty } ?? "Untitled"
        let updated = row.double(7), created = row.double(8)
        var hit = SearchHit(key: row.string(0) ?? "", agent: AgentKind(rawValue: row.string(1) ?? "") ?? .shell,
                            sessionId: row.string(2) ?? "", cwd: row.string(3) ?? "",
                            title: String(title.prefix(200)),
                            updated: updated > 0 ? Date(timeIntervalSince1970: updated) : nil, snippets: [])
        hit.created = created > 0 ? Date(timeIntervalSince1970: created) : nil
        return hit
    }

    static func terms(_ query: String) -> [String] {
        query.split(whereSeparator: { $0.isWhitespace }).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"*")) }
            .filter { !$0.isEmpty }
    }

    /// A readable window around the first term match: markdown and HTML noise removed, the match
    /// near the start (just `radius` characters of lead-in), terms wrapped in \u{1}…\u{2}.
    static func snippet(_ text: String, terms: [String], radius: Int = 24, length: Int = 160, code: Bool = false) -> String {
        let raw = text as NSString
        guard raw.length > 0 else { return "" }
        // Clean only a region around the first match: transcript messages can be huge.
        let found = firstMatchLocation(raw, terms: terms)
        let at = found ?? 0
        let region = raw.rangeOfComposedCharacterSequences(for: NSRange(location: max(0, at - 300),
                                                                        length: min(raw.length - max(0, at - 300), 300 + length * 2 + 200)))
        let regionText = raw.substring(with: region)
        // Code (commands, terminal output) stays as typed; prose loses its markup. Markup is rare per
        // region: plain text skips the cleanup, and only the short result is collapsed.
        var cleaned = regionText
        if !code, regionText.contains(where: { $0 == "[" || $0 == "<" || $0 == "`" || $0 == "*" || $0 == "_" }) {
            cleaned = readable(regionText, terms: terms)
            // The match was in something cleaning removed (an image URL): keep the raw text.
            if found != nil, firstMatchLocation(cleaned as NSString, terms: terms) == nil { cleaned = regionText }
        }
        var out = collapse(window(cleaned, terms: terms, radius: radius, length: length))
        if region.location > 0, !out.hasPrefix("…") { out = "…" + out }
        if NSMaxRange(region) < raw.length, !out.hasSuffix("…") { out += "…" }
        return out
    }

    private static let opts: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// Earliest word-start match of any term.
    static func firstMatchLocation(_ ns: NSString, terms: [String]) -> Int? {
        var first: Int?
        let scan = NSRange(location: 0, length: min(ns.length, 200_000))
        for term in terms {
            var search = scan
            while search.length > 0 {
                let r = ns.range(of: term, options: opts, range: search)
                if r.location == NSNotFound || (first.map { r.location >= $0 } ?? false) { break }
                let wordStart = r.location == 0 || UnicodeScalar(ns.character(at: r.location - 1)).map {
                    !CharacterSet.alphanumerics.contains($0)
                } ?? true
                if wordStart { first = r.location; break }
                let next = r.location + max(r.length, 1)
                search = NSRange(location: next, length: NSMaxRange(scan) - next)
            }
        }
        return first
    }

    private static let image = try! NSRegularExpression(pattern: #"!\[[^\]\n]*\]\([^)\s]*\)"#)
    private static let link = try! NSRegularExpression(pattern: #"\[([^\]\n]+)\]\(([^)\s]+)\)"#)
    /// HTML elements and hyphenated custom elements only: `List<String>` or `a<b && c>d` stay.
    /// Proper attribute syntax only, so `<b && c>` stays.
    private static let tag = try! NSRegularExpression(
        pattern: #"</?(?:[a-z]+-[\w-]+|a|b|i|u|p|br|hr|em|strong|code|pre|div|span|img|table|thead|tbody|tr|td|th|ul|ol|li|h[1-6]|details|summary|sub|sup)(?:\s+[a-z_:][-\w:.]*(?:\s*=\s*(?:"[^"\n]*"|'[^'\n]*'|[^\s"'=<>`]+))?)*\s*/?>"#,
        options: .caseInsensitive)
    /// Paired emphasis and inline code: `**bold**`, `__bold__`, `` `code` `` (never `x**2` or `snake__case`).
    private static let emphasis = try! NSRegularExpression(pattern: #"\*\*(?=\S)(.+?)(?<=\S)\*\*|(?<!\w)__(?=\S)(.+?)(?<=\S)__(?!\w)|`+([^`\n]+)`+"#)

    /// Text as a person reads it: image badges and HTML tags gone, `[text](url)` reduced to the part
    /// the query is in (else the text), no emphasis marks, single spaces.
    static func readable(_ text: String, terms: [String]) -> String {
        var s = image.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
        let ns = s as NSString
        var out = ""
        var cursor = 0
        for m in link.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let label = ns.substring(with: m.range(at: 1)), url = ns.substring(with: m.range(at: 2))
            let inURL = terms.contains { url.range(of: $0, options: opts) != nil }
            let inLabel = terms.contains { label.range(of: $0, options: opts) != nil }
            out += inURL && !inLabel ? url : label
            cursor = NSMaxRange(m.range)
        }
        out += ns.substring(from: cursor)
        s = tag.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: (out as NSString).length), withTemplate: " ")
        s = emphasis.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "$1$2$3")
        return collapse(s)
    }

    /// Runs of whitespace (newlines included) as one space, trimmed. One pass, no regex: it runs on
    /// every snippet of every result.
    static func collapse(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(text.unicodeScalars.count)
        var pendingSpace = false
        for u in text.unicodeScalars {
            if isSpace(u.value) {
                pendingSpace = !out.isEmpty
            } else {
                if pendingSpace { out.append(" ") }
                pendingSpace = false
                out.append(u)
            }
        }
        return String(out)
    }

    @inline(__always) private static func isSpace(_ v: UInt32) -> Bool {
        switch v {
        case 0x20, 0x09...0x0D, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: return true
        default: return false
        }
    }

    /// The window around the first term match, terms wrapped in \u{1}…\u{2} (word-prefix,
    /// case/diacritic-insensitive, like the FTS query).
    static func window(_ text: String, terms: [String], radius: Int, length: Int) -> String {
        let ns = text as NSString
        func isWordStart(_ loc: Int) -> Bool {
            guard loc > 0 else { return true }
            guard let scalar = UnicodeScalar(ns.character(at: loc - 1)) else { return true }
            return !CharacterSet.alphanumerics.contains(scalar)
        }
        func matches(in range: NSRange) -> [NSRange] {
            var out: [NSRange] = []
            for term in terms {
                var search = range
                while search.length > 0 {
                    let r = ns.range(of: term, options: opts, range: search)
                    if r.location == NSNotFound { break }
                    if isWordStart(r.location) { out.append(r) }
                    let next = r.location + max(r.length, 1)
                    search = NSRange(location: next, length: NSMaxRange(range) - next)
                }
            }
            return out.sorted { $0.location < $1.location }
        }
        let start = max(0, (firstMatchLocation(ns, terms: terms) ?? 0) - radius)
        // Whole characters only (no split emoji or orphaned combining marks).
        let window = ns.length == 0 ? NSRange(location: 0, length: 0)
            : ns.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: min(length, ns.length - start)))
        var out = window.location > 0 ? "…" : ""
        var cursor = window.location
        for m in matches(in: window) where m.location >= cursor && NSMaxRange(m) <= NSMaxRange(window) {
            out += ns.substring(with: NSRange(location: cursor, length: m.location - cursor))
            out += "\u{1}" + ns.substring(with: m) + "\u{2}"
            cursor = NSMaxRange(m)
        }
        out += ns.substring(with: NSRange(location: cursor, length: NSMaxRange(window) - cursor))
        if NSMaxRange(window) < ns.length { out += "…" }
        return out.replacingOccurrences(of: "\n", with: " ")
    }

    /// Every whitespace-separated term must match, as a prefix. Quotes keep FTS syntax out.
    public static func ftsQuery(_ input: String) -> String {
        input.split(whereSeparator: { $0.isWhitespace })
            .map { term -> String in
                let cleaned = term.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(cleaned)\"*"
            }
            .joined(separator: " ")
    }

    // MARK: Shared write helpers (index queue only)

    static func insertDoc(db: SQLiteDB, key: String, role: String, ts: Double, text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try db.cached("INSERT INTO doc_map(session_key, role, ts) VALUES (?, ?, ?)").bind(key, role, ts).run()
        let id = db.lastInsertRowID
        try db.cached("INSERT INTO docs(rowid, text) VALUES (?, ?)").bind(id, String(trimmed.prefix(200_000))).run()
    }

    static func deleteDocs(db: SQLiteDB, key: String) throws {
        try db.cached("DELETE FROM docs WHERE rowid IN (SELECT id FROM doc_map WHERE session_key = ?)").bind(key).run()
        try db.cached("DELETE FROM doc_map WHERE session_key = ?").bind(key).run()
    }

    static func upsertSession(db: SQLiteDB, key: String, agent: AgentKind, sessionId: String, cwd: String?,
                              custom: String?, ai: String?, firstPrompt: String?,
                              created: Double?, updated: Double?) throws {
        try db.cached("""
        INSERT INTO sessions(key, agent, session_id, cwd, title_custom, title_ai, first_prompt, created, updated)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(key) DO UPDATE SET
            cwd = COALESCE(sessions.cwd, excluded.cwd),
            title_custom = COALESCE(excluded.title_custom, sessions.title_custom),
            title_ai = COALESCE(excluded.title_ai, sessions.title_ai),
            first_prompt = COALESCE(sessions.first_prompt, excluded.first_prompt),
            created = MIN(COALESCE(sessions.created, excluded.created), COALESCE(excluded.created, sessions.created)),
            updated = MAX(COALESCE(sessions.updated, 0), COALESCE(excluded.updated, 0))
        """).bind(key, agent.rawValue, sessionId, cwd, custom, ai, firstPrompt.map { String($0.prefix(200)) }, created, updated).run()
    }

    static func chunks(of text: String, size: Int) -> [String] {
        var out: [String] = []
        var current = ""
        var currentBytes = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let n = line.utf8.count + 1
            if currentBytes + n > size, !current.isEmpty {
                out.append(current)
                current = ""
                currentBytes = 0
            }
            current += line
            current += "\n"
            currentBytes += n
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(current) }
        return out
    }
}
