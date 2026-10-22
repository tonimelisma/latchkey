import Foundation
import SQLite3

/// Small helpers over the system SQLite, for reading Notes' and Messages' databases.
enum SQLite {
    struct Failure: Error { var message: String }

    /// Opens a database read-only, never creating or changing it (plan D2).
    static func openReadOnly(_ url: URL) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let uri = "file:\(url.path(percentEncoded: true))?mode=ro"
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw Failure(message: "can't open \(url.path)")
        }
        sqlite3_busy_timeout(handle, 2_000)
        return handle
    }

    enum Value {
        case null, int(Int64), double(Double), text(String), blob(Data)

        var int: Int64? {
            switch self {
            case .int(let i): i
            case .double(let d): Int64(d)
            default: nil
            }
        }
        var double: Double? {
            switch self {
            case .double(let d): d
            case .int(let i): Double(i)
            default: nil
            }
        }
        var text: String? { if case .text(let s) = self { s } else { nil } }
        var blob: Data? { if case .blob(let b) = self { b } else { nil } }
    }

    static func close(_ db: OpaquePointer) { sqlite3_close(db) }

    static func rows(_ db: OpaquePointer, _ sql: String, bind: [Value] = []) throws -> [[Value]] {
        var out: [[Value]] = []
        try forEachRow(db, sql, bind: bind) {
            out.append($0)
            return true
        }
        return out
    }

    /// Like `forEachRow`, but hands over the statement so hot loops read columns without copies.
    static func forEachRaw(
        _ db: OpaquePointer, _ sql: String, bind: [Value] = [], _ body: (OpaquePointer) throws -> Bool
    ) throws {
        let stmt = try prepare(db, sql, bind: bind)
        defer { sqlite3_finalize(stmt) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw Failure(message: String(cString: sqlite3_errmsg(db))) }
            if try !body(stmt) { break }
        }
    }

    static func int(_ stmt: OpaquePointer, _ c: Int32) -> Int64 { sqlite3_column_int64(stmt, c) }

    static func text(_ stmt: OpaquePointer, _ c: Int32) -> String? {
        sqlite3_column_text(stmt, c).map { String(cString: $0) }
    }

    /// The column's bytes, valid only until the next step.
    static func blob(_ stmt: OpaquePointer, _ c: Int32) -> UnsafeRawBufferPointer? {
        guard let p = sqlite3_column_blob(stmt, c) else { return nil }
        return UnsafeRawBufferPointer(start: p, count: Int(sqlite3_column_bytes(stmt, c)))
    }

    private static func prepare(_ db: OpaquePointer, _ sql: String, bind: [Value]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw Failure(message: String(cString: sqlite3_errmsg(db)))
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, v) in bind.enumerated() {
            let n = Int32(i + 1)
            switch v {
            case .text(let s): sqlite3_bind_text(stmt, n, s, -1, transient)
            case .int(let x): sqlite3_bind_int64(stmt, n, x)
            case .double(let x): sqlite3_bind_double(stmt, n, x)
            case .blob(let b):
                _ = b.withUnsafeBytes { sqlite3_bind_blob(stmt, n, $0.baseAddress, Int32(b.count), transient) }
            case .null: sqlite3_bind_null(stmt, n)
            }
        }
        return stmt
    }

    /// Calls `body` with each row until it returns false.
    static func forEachRow(
        _ db: OpaquePointer, _ sql: String, bind: [Value] = [], _ body: ([Value]) throws -> Bool
    ) throws {
        let stmt = try prepare(db, sql, bind: bind)
        defer { sqlite3_finalize(stmt) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw Failure(message: String(cString: sqlite3_errmsg(db))) }
            let row: [Value] = (0..<sqlite3_column_count(stmt)).map { c in
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: .int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: .double(sqlite3_column_double(stmt, c))
                case SQLITE_TEXT: .text(String(cString: sqlite3_column_text(stmt, c)))
                case SQLITE_BLOB:
                    .blob(
                        sqlite3_column_bytes(stmt, c) > 0
                            ? Data(bytes: sqlite3_column_blob(stmt, c), count: Int(sqlite3_column_bytes(stmt, c)))
                            : Data())
                default: .null
                }
            }
            if try !body(row) { break }
        }
    }
}
