import Foundation

/// What a Claude conversation cost and where it wasted effort, read from its transcript
/// (`corral stats`, behind Settings › Agents › Measure sessions).
public struct SessionStats: Equatable, Sendable {
    /// Prompts the user (or an orchestrator) sent.
    public var turns = 0
    /// Model answers (one per API response).
    public var responses = 0
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite = 0
    public var toolCalls = 0
    public var toolErrors = 0
    public var tools: [String: Int] = [:]
    public var compactions = 0
    public var subagents = 0
    /// Of `tokens`: what subagents used (their own transcripts).
    public var subagentTokens = 0
    public var seconds: Double = 0
    public var models: [String] = []
    public var flags: [String] = []

    public var tokens: Int { input + output + cacheRead + cacheWrite }

    public var json: [String: Any] {
        ["turns": turns, "responses": responses, "tokens": tokens, "input": input, "output": output,
         "cache_read": cacheRead, "cache_write": cacheWrite, "tool_calls": toolCalls, "tool_errors": toolErrors,
         "tools": tools, "compactions": compactions, "subagents": subagents, "subagent_tokens": subagentTokens, "seconds": Int(seconds),
         "models": models, "flags": flags]
    }
}

public enum SessionAnalysis {
    /// A call repeated this often with the same input is flagged, and a file read this often.
    static let repeats = 3
    static let rereads = 4
    static let largeModels = ["opus", "fable"]

    /// Line kinds worth parsing; the rest (API request logs, attachments: most of a transcript's bytes) is skipped unparsed.
    private static let kinds = ["assistant", "user", "system"].map { Data("\"type\":\"\($0)\"".utf8) }

    /// Feeds each line of the file to `take`, one chunk in memory at a time.
    private static func lines(of path: String, _ take: (Data) -> Void) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        var rest = Data()
        var more = true
        while more {
            autoreleasepool {
                guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else { more = false; return }
                rest.append(chunk)
                while let end = rest.firstIndex(of: 0x0A) {
                    let line = rest[rest.startIndex..<end]
                    if kinds.contains(where: { line.range(of: $0) != nil }) { take(Data(line)) }
                    rest = Data(rest[rest.index(after: end)...])
                }
            }
        }
        if !rest.isEmpty { take(rest) }
        return true
    }

    private static func add(_ usage: [String: [String: Any]], to stats: inout SessionStats) -> Int {
        var sum = 0
        for u in usage.values {
            let parts = ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"].map { u[$0] as? Int ?? 0 }
            stats.input += parts[0]
            stats.output += parts[1]
            stats.cacheRead += parts[2]
            stats.cacheWrite += parts[3]
            sum += parts.reduce(0, +)
        }
        return sum
    }

    /// A prompt someone typed, not what Claude Code files as a user message itself (task notices,
    /// command output, interruptions). Newer transcripts say so (`origin.kind`).
    static func isPrompt(_ obj: [String: Any], text: String?) -> Bool {
        if let origin = obj["origin"] as? [String: Any] { return origin["kind"] as? String == "human" }
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !text.hasPrefix("<") && !text.hasPrefix("[Request interrupted")
    }

    public static func analyze(path: String) -> SessionStats? {
        var stats = SessionStats()
        // Claude writes one line per content block, each repeating the response's usage: count a response once.
        var usage: [String: [String: Any]] = [:]
        // Repeats count within one stretch of work (a turn, or up to a compaction): after either,
        // doing something again is no waste. The worst stretch is what gets flagged.
        var calls: [String: Int] = [:], reads: [String: Int] = [:]
        var worstCalls: [String: Int] = [:], worstReads: [String: Int] = [:]
        func endStretch() {
            worstCalls.merge(calls) { max($0, $1) }
            worstReads.merge(reads) { max($0, $1) }
            calls = [:]
            reads = [:]
        }
        var first: Date?, last: Date?
        var worked: Double = 0
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let found = lines(of: path) { line in
            autoreleasepool {
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
                if let stamp = (obj["timestamp"] as? String).flatMap(dates.date(from:)) {
                    if first == nil { first = stamp }
                    last = stamp
                }
                let type = obj["type"] as? String
                if type == "system" {
                    switch obj["subtype"] as? String {
                    case "compact_boundary":
                        stats.compactions += 1
                        endStretch()
                    case "turn_duration": worked += (obj["durationMs"] as? Double ?? 0) / 1000
                    default: break
                    }
                    return
                }
                guard let message = obj["message"] as? [String: Any] else { return }
                let blocks = message["content"] as? [[String: Any]] ?? []
                if type == "assistant" {
                    if let id = message["id"] as? String, let u = message["usage"] as? [String: Any] { usage[id] = u }
                    if let model = message["model"] as? String, !model.hasPrefix("<"), !stats.models.contains(model) {
                        stats.models.append(model)
                    }
                    for block in blocks where block["type"] as? String == "tool_use" {
                        let name = block["name"] as? String ?? "?"
                        let input = block["input"] as? [String: Any] ?? [:]
                        stats.toolCalls += 1
                        stats.tools[name, default: 0] += 1
                        if name == "Task" || name == "Agent" { stats.subagents += 1 }
                        // Reads are counted per file (whatever range was asked for).
                        if name == "Read", let file = input["file_path"] as? String { reads[file, default: 0] += 1; continue }
                        let detail = HookWire.permissionDetail(tool: name, input: input)
                        let key = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]))
                            .map { "\(detail)\u{0}\($0.hashValue)" } ?? detail
                        calls[key, default: 0] += 1
                    }
                } else if type == "user", obj["isSidechain"] as? Bool != true, obj["isMeta"] as? Bool != true,
                          obj["isCompactSummary"] as? Bool != true {
                    stats.toolErrors += blocks.filter { $0["type"] as? String == "tool_result" && $0["is_error"] as? Bool == true }.count
                    let text = message["content"] as? String
                        ?? blocks.first { $0["type"] as? String == "text" }.flatMap { $0["text"] as? String }
                    if text != nil, isPrompt(obj, text: text) {
                        stats.turns += 1
                        endStretch()
                    }
                }
            }
        }
        guard found else { return nil }
        endStretch()
        stats.responses = usage.count
        _ = add(usage, to: &stats)

        // Subagents write their own transcripts next to the session's: their tokens are part of its cost.
        let folder = URL(fileURLWithPath: path).deletingPathExtension().appendingPathComponent("subagents")
        for file in (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.sorted() ?? [] where file.hasSuffix(".jsonl") {
            var theirs: [String: [String: Any]] = [:]
            _ = lines(of: folder.appendingPathComponent(file).path) { line in
                autoreleasepool {
                    guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let message = obj["message"] as? [String: Any], let id = message["id"] as? String,
                          let u = message["usage"] as? [String: Any] else { return }
                    theirs[id] = u
                }
            }
            stats.subagentTokens += add(theirs, to: &stats)
        }
        // Time spent working, where the transcript says so; else first line to last.
        if worked > 0 { stats.seconds = worked } else if let first, let last { stats.seconds = last.timeIntervalSince(first) }
        stats.flags = flags(stats, calls: worstCalls, reads: worstReads)
        return stats
    }

    static func flags(_ s: SessionStats, calls: [String: Int], reads: [String: Int]) -> [String] {
        var out: [String] = []
        if s.toolErrors >= 3, s.toolErrors * 5 >= s.toolCalls {
            out.append("\(s.toolErrors) of \(s.toolCalls) tool calls failed")
        }
        for (key, n) in calls.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }).prefix(3) where n >= repeats {
            out.append("Same call \(n) times: \(key.split(separator: "\u{0}").first.map(String.init) ?? key)")
        }
        for (file, n) in reads.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }).prefix(3) where n >= rereads {
            out.append("Read \(file.pathLeaf) \(n) times")
        }
        if s.compactions > 0 {
            out.append("Context compacted \(s.compactions) time\(s.compactions == 1 ? "" : "s"): earlier work had to be summarized")
        }
        let prompt = s.input + s.cacheRead + s.cacheWrite
        if s.responses >= 10, prompt > 0, s.cacheRead * 2 < prompt {
            out.append("Prompt cache reused for only \(s.cacheRead * 100 / prompt)% of the input: long pauses between steps")
        }
        if s.responses > 0, s.toolCalls <= 3, s.output < 2_000,
           s.models.contains(where: { m in largeModels.contains { m.contains($0) } }) {
            out.append("Small job on a large model: a lower tier would do")
        }
        return out
    }

    /// "184k tokens (in 2k, out 9k, cache read 160k, cache write 13k), 3 turns, 41 tool calls (2 failed), 12 min"
    public static func summary(_ s: [String: Any]) -> String {
        func n(_ key: String) -> Int { s[key] as? Int ?? 0 }
        func k(_ v: Int) -> String { v >= 10_000 ? "\(v / 1000)k" : v >= 1000 ? String(format: "%.1fk", Double(v) / 1000) : "\(v)" }
        var parts = ["\(k(n("tokens"))) tokens (in \(k(n("input"))), out \(k(n("output"))), cache read \(k(n("cache_read"))), cache write \(k(n("cache_write"))))",
                     "\(n("turns")) turn\(n("turns") == 1 ? "" : "s")",
                     "\(n("tool_calls")) tool call\(n("tool_calls") == 1 ? "" : "s")" + (n("tool_errors") > 0 ? " (\(n("tool_errors")) failed)" : "")]
        if n("subagent_tokens") > 0 { parts.append("\(k(n("subagent_tokens"))) of the tokens in subagents") }
        let seconds = n("seconds")
        if seconds > 0 { parts.append((seconds >= 120 ? "\(seconds / 60) min" : "\(seconds) s") + " working") }
        return parts.joined(separator: ", ")
    }
}
