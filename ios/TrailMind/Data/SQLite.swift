import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A thin wrapper over the system SQLite (also used to read MBTiles packs). Not thread-safe: use one per queue.
final class SQLiteDB {
    enum Value { case null, int(Int64), double(Double), text(String), blob(Data) }

    struct SQLError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private(set) var handle: OpaquePointer?

    init(path: String, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        if sqlite3_open_v2(path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close(handle)
            throw SQLError(message: message)
        }
    }

    deinit { sqlite3_close(handle) }

    func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "SQL error"
            sqlite3_free(error)
            throw SQLError(message: message)
        }
    }

    final class Statement {
        fileprivate var stmt: OpaquePointer?
        init(_ stmt: OpaquePointer?) { self.stmt = stmt }
        deinit { sqlite3_finalize(stmt) }

        func bind(_ values: [Value]) {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            for (i, v) in values.enumerated() {
                let idx = Int32(i + 1)
                switch v {
                case .null: sqlite3_bind_null(stmt, idx)
                case .int(let x): sqlite3_bind_int64(stmt, idx, x)
                case .double(let x): sqlite3_bind_double(stmt, idx, x)
                case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
                case .blob(let d): _ = d.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(d.count), SQLITE_TRANSIENT) }
                }
            }
        }

        func step() -> Bool { sqlite3_step(stmt) == SQLITE_ROW }
        func isNull(_ col: Int32) -> Bool { sqlite3_column_type(stmt, col) == SQLITE_NULL }
        func int(_ col: Int32) -> Int64 { sqlite3_column_int64(stmt, col) }
        func double(_ col: Int32) -> Double { sqlite3_column_double(stmt, col) }
        func optDouble(_ col: Int32) -> Double? { isNull(col) ? nil : double(col) }
        func optInt(_ col: Int32) -> Int64? { isNull(col) ? nil : int(col) }
        func text(_ col: Int32) -> String { sqlite3_column_text(stmt, col).map { String(cString: $0) } ?? "" }
        func optText(_ col: Int32) -> String? { isNull(col) ? nil : text(col) }
        func blob(_ col: Int32) -> Data? {
            guard let p = sqlite3_column_blob(stmt, col) else { return nil }
            return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, col)))
        }
        /// Column index by name, for SELECT * readers.
        func column(_ name: String) -> Int32 {
            for i in 0..<sqlite3_column_count(stmt) where String(cString: sqlite3_column_name(stmt, i)) == name { return i }
            return -1
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) != SQLITE_OK {
            throw SQLError(message: String(cString: sqlite3_errmsg(handle)))
        }
        return Statement(stmt)
    }

    /// Runs a statement that returns no rows; returns the number of rows changed.
    @discardableResult
    func run(_ sql: String, _ values: [Value] = []) throws -> Int {
        let s = try prepare(sql)
        s.bind(values)
        let rc = sqlite3_step(s.stmt)
        if rc != SQLITE_DONE && rc != SQLITE_ROW { throw SQLError(message: String(cString: sqlite3_errmsg(handle))) }
        return Int(sqlite3_changes(handle))
    }

    func query<T>(_ sql: String, _ values: [Value] = [], _ map: (Statement) -> T) throws -> [T] {
        let s = try prepare(sql)
        s.bind(values)
        var out: [T] = []
        while s.step() { out.append(map(s)) }
        return out
    }

    var lastInsertId: Int64 { sqlite3_last_insert_rowid(handle) }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    var userVersion: Int {
        get { (try? query("PRAGMA user_version") { Int($0.int(0)) })?.first ?? 0 }
        set { try? exec("PRAGMA user_version = \(newValue)") }
    }
}
