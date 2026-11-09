import Foundation

/// Taking over sessions tracked by `claude-sessions` (the Ghostty restore tool).
///
/// Only sessions that aren't running anywhere are resumed: a Claude process still alive in a
/// Ghostty tab can't move, and resuming its conversation a second time would give two writers.
/// Background jobs keep running and are attached. Everything imported is then forgotten by the
/// tracker, so Ghostty never reopens it as well.
public enum TrackerImport {
    public struct Row: Codable, Equatable, Sendable {
        public var sid: String
        public var status: String
        public var background: Bool
        public var cwd: String
        public var name: String
        public var skip: String?

        public init(sid: String, status: String, background: Bool, cwd: String, name: String, skip: String? = nil) {
            self.sid = sid
            self.status = status
            self.background = background
            self.cwd = cwd
            self.name = name
            self.skip = skip
        }

        /// Background jobs are addressed by the first 8 characters of the session id.
        public var jobId: String { String(sid.prefix(8)) }

        public var title: String { name == "-" || name.hasPrefix("code-") ? "" : name }
    }

    public enum Action: Equatable, Sendable {
        /// Not running anywhere: resume the conversation in a new Corral session.
        case resume(Row)
        /// Background job not running: restart it in the background, then attach.
        case resumeBackground(Row)
        /// Background job running: attach, the job keeps going.
        case attach(Row)
    }

    public struct Plan: Equatable, Sendable {
        public var actions: [Action] = []
        public var runningElsewhere: [Row] = []
        public var skipped: [(row: Row, reason: String)] = []

        public var isEmpty: Bool { actions.isEmpty }
        public var forgetIds: [String] {
            actions.map {
                switch $0 {
                case .resume(let r), .resumeBackground(let r), .attach(let r): return r.sid
                }
            }
        }

        public static func == (a: Plan, b: Plan) -> Bool {
            a.actions == b.actions && a.runningElsewhere == b.runningElsewhere
                && a.skipped.map(\.row) == b.skipped.map(\.row) && a.skipped.map(\.reason) == b.skipped.map(\.reason)
        }
    }

    public static func parse(_ data: Data) throws -> [Row] {
        try JSONDecoder().decode([Row].self, from: data)
    }

    /// `known` = agent session ids Corral already has (open or closed): those are left alone.
    public static func plan(_ rows: [Row], known: Set<String>) -> Plan {
        var plan = Plan()
        for row in rows {
            if known.contains(row.sid) {
                plan.skipped.append((row, "already in Corral"))
                continue
            }
            switch (row.status, row.background) {
            case ("restore", false): plan.actions.append(.resume(row))
            case ("restore", true): plan.actions.append(.resumeBackground(row))
            case ("running", true): plan.actions.append(.attach(row))
            case ("running", false): plan.runningElsewhere.append(row)
            default: plan.skipped.append((row, row.skip ?? row.status))
            }
        }
        return plan
    }

    /// Agent command for the new session's terminal for an action.
    public static func input(for action: Action) -> String {
        switch action {
        case .resume(let r):
            return AgentKind.claude.resumeCommand(sessionId: r.sid)!
        case .resumeBackground(let r):
            return "claude --bg --resume \(shellQuote(r.sid)) && claude attach \(shellQuote(r.jobId))"
        case .attach(let r):
            return "claude attach \(shellQuote(r.jobId))"
        }
    }

    /// Human summary for the confirmation dialog.
    public static func summary(_ plan: Plan) -> String {
        var lines: [String] = []
        let resume = plan.actions.filter { if case .attach = $0 { return false }; return true }.count
        let attach = plan.actions.count - resume
        if resume > 0 { lines.append("Resume \(resume) session\(resume == 1 ? "" : "s") in Corral.") }
        if attach > 0 { lines.append("Attach \(attach) running background job\(attach == 1 ? "" : "s").") }
        if !plan.actions.isEmpty { lines.append("They are removed from claude-sessions, so Ghostty won't reopen them.") }
        if !plan.runningElsewhere.isEmpty {
            lines.append("")
            lines.append("\(plan.runningElsewhere.count) still running in Ghostty, left alone. Quit Ghostty first to take them over:")
            lines += plan.runningElsewhere.prefix(8).map { "  • \($0.title.isEmpty ? String($0.sid.prefix(8)) : $0.title)" }
            if plan.runningElsewhere.count > 8 { lines.append("  • …and \(plan.runningElsewhere.count - 8) more") }
        }
        if !plan.skipped.isEmpty {
            lines.append("")
            lines.append("\(plan.skipped.count) skipped (\(Set(plan.skipped.map(\.reason)).sorted().joined(separator: ", "))).")
        }
        return lines.joined(separator: "\n")
    }
}

/// Runs the `claude-sessions` CLI off the main thread.
public enum TrackerCLI {
    public static var defaultBinary: String? {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude-sessions").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// `claude-sessions list --json`; completion on main.
    public static func list(binary: String, completion: @escaping (Result<[TrackerImport.Row], Error>) -> Void) {
        run(binary, ["list", "--json"]) { result in
            completion(result.flatMap { data in Result { try TrackerImport.parse(data) } })
        }
    }

    /// `claude-sessions forget <ids>`; completion on main.
    public static func forget(binary: String, ids: [String], completion: @escaping (Result<Void, Error>) -> Void) {
        guard !ids.isEmpty else { DispatchQueue.main.async { completion(.success(())) }; return }
        run(binary, ["forget"] + ids) { completion($0.map { _ in () }) }
    }

    static func run(_ binary: String, _ args: [String], completion: @escaping (Result<Data, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: binary)
            p.arguments = args
            p.standardInput = FileHandle.nullDevice
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            let result: Result<Data, Error>
            do {
                try p.run()
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: killer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit()
                killer.cancel()
                result = p.terminationStatus == 0 ? .success(data)
                    : .failure(Failure(message: errText.isEmpty ? "claude-sessions exited \(p.terminationStatus)" : errText))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
