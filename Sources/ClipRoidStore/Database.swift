import Foundation
import SQLite3
import os.log

/// SQLITE_TRANSIENT tells SQLite to copy the bound bytes immediately. Without it, SQLite keeps the
/// pointer and reads it at step() time, by which point a Swift temporary is long gone. The constant
/// is a macro in C and does not import, so it has to be spelled out.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum DatabaseError: LocalizedError, Equatable {
    case openFailed(String)
    case prepareFailed(sql: String, message: String)
    case stepFailed(sql: String, message: String)
    case notOpen

    public var errorDescription: String? {
        switch self {
        case .openFailed(let m): "Could not open the clip database: \(m)"
        case .prepareFailed(_, let m): "Could not prepare a database statement: \(m)"
        case .stepFailed(_, let m): "A database operation failed: \(m)"
        case .notOpen: "The clip database is not open."
        }
    }
}

/// A value bindable to a statement parameter.
public enum SQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case text(String)
    case blob(Data)
    case double(Double)

    public static func int(_ v: Int) -> SQLValue { .int(Int64(v)) }
    public static func bool(_ v: Bool) -> SQLValue { .int(v ? 1 : 0) }
    /// Timestamps are stored as INTEGER milliseconds since epoch, not ISO-8601 text: no formatter
    /// allocation per row, and range scans are plain integer comparisons.
    public static func date(_ v: Date) -> SQLValue { .int(Int64(v.timeIntervalSince1970 * 1000)) }
    public static func optional(_ v: String?) -> SQLValue { v.map { .text($0) } ?? .null }
    public static func optional(_ v: Date?) -> SQLValue { v.map { .date($0) } ?? .null }
}

/// One row of results, addressed by column index.
public struct Row: Sendable {
    private let values: [SQLValue]
    init(_ values: [SQLValue]) { self.values = values }

    public func int64(_ i: Int) -> Int64 { if case .int(let v) = values[i] { return v }; return 0 }
    public func int(_ i: Int) -> Int { Int(int64(i)) }
    public func bool(_ i: Int) -> Bool { int64(i) != 0 }
    public func string(_ i: Int) -> String? { if case .text(let v) = values[i] { return v }; return nil }
    public func data(_ i: Int) -> Data? { if case .blob(let v) = values[i] { return v }; return nil }
    public func date(_ i: Int) -> Date? {
        if case .int(let v) = values[i] { return Date(timeIntervalSince1970: Double(v) / 1000) }
        return nil
    }
    public func isNull(_ i: Int) -> Bool { values[i] == .null }
}

/// Owns the one sqlite3 handle. The handle is an `OpaquePointer`, which is not `Sendable`, so it
/// never leaves this actor — that constraint is what makes the whole store safe in Swift 6 mode
/// without any `@unchecked` escape hatch.
///
/// Modelled on ~/projects/Mail-Export/Sources/MailExport/Database/DatabaseManager.swift, with a
/// prepared-statement cache added: Mail-Export re-prepares on every call, which is fine for a batch
/// exporter and wasteful on a capture hot path that runs every time the user copies anything.
public actor Database {
    private var db: OpaquePointer?
    private var statementCache: [String: OpaquePointer] = [:]
    private let path: String
    private let logger = Logger(subsystem: "dev.philtronic.ClipRoid", category: "Database")

    public init(path: String) {
        self.path = path
    }

    public func open() throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, handle != nil else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw DatabaseError.openFailed(message)
        }
        db = handle

        // WAL so a long read (the timeline query) never blocks a write (a capture landing).
        try execute("PRAGMA journal_mode = WAL;")
        // NORMAL trades an fsync per commit for a small crash window. For a clipboard history that
        // is the right trade: losing the last clip on power loss is not worth an fsync per copy.
        try execute("PRAGMA synchronous = NORMAL;")
        try execute("PRAGMA foreign_keys = ON;")
        try execute("PRAGMA cache_size = -8000;")
        try execute("PRAGMA busy_timeout = 5000;")
        logger.info("Opened clip database")
    }

    public func close() {
        for (_, stmt) in statementCache { sqlite3_finalize(stmt) }
        statementCache.removeAll()
        if let db { sqlite3_close(db) }
        db = nil
    }

    // MARK: - Statement handling

    private func prepared(_ sql: String) throws -> OpaquePointer {
        guard let db else { throw DatabaseError.notOpen }
        if let cached = statementCache[sql] {
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
            return cached
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DatabaseError.prepareFailed(sql: sql, message: String(cString: sqlite3_errmsg(db)))
        }
        statementCache[sql] = stmt
        return stmt
    }

    private func bind(_ stmt: OpaquePointer, _ values: [SQLValue]) {
        for (offset, value) in values.enumerated() {
            let i = Int32(offset + 1)
            switch value {
            case .null: sqlite3_bind_null(stmt, i)
            case .int(let v): sqlite3_bind_int64(stmt, i, v)
            case .double(let v): sqlite3_bind_double(stmt, i, v)
            case .text(let v): sqlite3_bind_text(stmt, i, v, -1, SQLITE_TRANSIENT)
            case .blob(let v):
                if v.isEmpty {
                    sqlite3_bind_zeroblob(stmt, i, 0)
                } else {
                    _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, i, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT) }
                }
            }
        }
    }

    /// Multi-statement DDL. Not cached — schema work runs once.
    public func execute(_ sql: String) throws {
        guard let db else { throw DatabaseError.notOpen }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(error)
            throw DatabaseError.stepFailed(sql: sql, message: message)
        }
    }

    /// A statement returning no rows.
    @discardableResult
    public func run(_ sql: String, _ values: [SQLValue] = []) throws -> Int64 {
        guard let db else { throw DatabaseError.notOpen }
        let stmt = try prepared(sql)
        bind(stmt, values)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw DatabaseError.stepFailed(sql: sql, message: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_reset(stmt)
        return sqlite3_last_insert_rowid(db)
    }

    public func query(_ sql: String, _ values: [SQLValue] = []) throws -> [Row] {
        guard let db else { throw DatabaseError.notOpen }
        let stmt = try prepared(sql)
        bind(stmt, values)
        var rows: [Row] = []
        let columns = Int(sqlite3_column_count(stmt))
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw DatabaseError.stepFailed(sql: sql, message: String(cString: sqlite3_errmsg(db)))
            }
            var values: [SQLValue] = []
            values.reserveCapacity(columns)
            for c in 0..<Int32(columns) {
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: values.append(.int(sqlite3_column_int64(stmt, c)))
                case SQLITE_FLOAT: values.append(.double(sqlite3_column_double(stmt, c)))
                case SQLITE_TEXT:
                    values.append(.text(String(cString: sqlite3_column_text(stmt, c))))
                case SQLITE_BLOB:
                    if let bytes = sqlite3_column_blob(stmt, c) {
                        values.append(.blob(Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, c)))))
                    } else {
                        values.append(.blob(Data()))
                    }
                default: values.append(.null)
                }
            }
            rows.append(Row(values))
        }
        sqlite3_reset(stmt)
        return rows
    }

    /// One logical capture touches `clips`, `clip_tags`, `clip_categories` and fires FTS triggers.
    /// Five autocommits is five WAL frames and five lock cycles; this makes it one.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    // MARK: - Schema version

    public func userVersion() throws -> Int {
        try query("PRAGMA user_version;").first.map { $0.int(0) } ?? 0
    }

    public func setUserVersion(_ version: Int) throws {
        // PRAGMA does not accept bound parameters, hence interpolation. The value is an Int we
        // control, never user input.
        try execute("PRAGMA user_version = \(version);")
    }

    /// Crash recovery (spec §10). `quick_check` rather than `integrity_check`: it catches the
    /// damage that actually happens and does not walk the whole file.
    public func quickCheck() throws -> Bool {
        try query("PRAGMA quick_check;").first?.string(0) == "ok"
    }

    /// Pre-migration snapshot. Works on a live WAL database and needs no sqlite3_backup_* plumbing.
    public func backup(to url: URL) throws {
        let escaped = url.path.replacingOccurrences(of: "'", with: "''")
        try execute("VACUUM INTO '\(escaped)';")
    }
}
