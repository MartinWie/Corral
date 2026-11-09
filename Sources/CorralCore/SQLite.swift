import Foundation
import SQLite3

/// Minimal SQLite wrapper. Not thread-safe: use from one queue.
public final class SQLiteDB {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    let handle: OpaquePointer

    public init(path: String, readOnly: Bool = false) throws {
        var db: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        let rc = sqlite3_open_v2(path, &db, flags | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let db { sqlite3_close(db) }
            throw Failure(description: "\(path): \(msg)")
        }
        handle = db
        sqlite3_busy_timeout(db, 3000)
    }

    deinit { sqlite3_close(handle) }

    public func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw Failure(description: msg)
        }
    }

    public func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw Failure(description: "\(String(cString: sqlite3_errmsg(handle))) in: \(sql)")
        }
        return Statement(stmt, db: handle)
    }

    private var cache: [String: Statement] = [:]

    /// Prepared once and reused; for hot statements in indexing loops.
    public func cached(_ sql: String) throws -> Statement {
        if let s = cache[sql] { return s }
        let s = try prepare(sql)
        cache[sql] = s
        return s
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    public func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    public final class Statement {
        let stmt: OpaquePointer
        let db: OpaquePointer
        init(_ stmt: OpaquePointer, db: OpaquePointer) { self.stmt = stmt; self.db = db }
        deinit { sqlite3_finalize(stmt) }

        private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        @discardableResult
        public func bind(_ values: Any?...) -> Statement { bindAll(values) }

        @discardableResult
        public func bindAll(_ values: [Any?]) -> Statement {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            for (i, v) in values.enumerated() {
                let idx = Int32(i + 1)
                switch v {
                case nil: sqlite3_bind_null(stmt, idx)
                case let s as String: sqlite3_bind_text(stmt, idx, s, -1, Self.transient)
                case let n as Int: sqlite3_bind_int64(stmt, idx, Int64(n))
                case let n as Int64: sqlite3_bind_int64(stmt, idx, n)
                case let d as Double: sqlite3_bind_double(stmt, idx, d)
                case let b as Bool: sqlite3_bind_int64(stmt, idx, b ? 1 : 0)
                default: sqlite3_bind_text(stmt, idx, "\(v!)", -1, Self.transient)
                }
            }
            return self
        }

        public func run() throws {
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
                throw Failure(description: String(cString: sqlite3_errmsg(db)))
            }
            sqlite3_reset(stmt)
        }

        /// Iterates result rows.
        public func rows(_ body: (Row) throws -> Void) throws {
            try scan({ row in
                try body(row)
                return true
            })
        }

        /// Iterates result rows while `body` returns true (early exit).
        public func scan(_ body: (Row) throws -> Bool) throws {
            defer { sqlite3_reset(stmt) }
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { return }
                guard rc == SQLITE_ROW else { throw Failure(description: String(cString: sqlite3_errmsg(db))) }
                if try !body(Row(stmt: stmt)) { return }
            }
        }
    }

    public struct Row {
        let stmt: OpaquePointer
        public func string(_ i: Int32) -> String? {
            guard let p = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: p)
        }
        public func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        public func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        public func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    }
}
