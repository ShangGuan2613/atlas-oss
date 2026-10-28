import Foundation
import SQLite3

/// A bound value for a prepared statement.
public enum SQLiteValue {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public static func maybe(_ value: Int?) -> SQLiteValue {
        value.map { .integer(Int64($0)) } ?? .null
    }

    public static func maybe(_ value: Int64?) -> SQLiteValue {
        value.map { .integer($0) } ?? .null
    }

    public static func maybe(_ value: Double?) -> SQLiteValue {
        value.map { .real($0) } ?? .null
    }

    public static func maybe(_ value: String?) -> SQLiteValue {
        value.map { .text($0) } ?? .null
    }

    public static func maybe(_ value: Date?) -> SQLiteValue {
        value.map { .real($0.timeIntervalSince1970) } ?? .null
    }
}

/// Minimal, dependency-free wrapper over the sqlite3 C API.
///
/// Intentionally small: P0 only needs single-connection, synchronous access from
/// one process. Connection pooling / actor isolation is a P1 concern.
public final class SQLiteDatabase {
    private var handle: OpaquePointer?
    public let path: String

    public init(path: String) throws {
        self.path = path
        var candidate: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &candidate, flags, nil)
        guard rc == SQLITE_OK, let opened = candidate else {
            let message = candidate.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let candidate { sqlite3_close_v2(candidate) }
            throw AtlasError.database("open failed (\(rc)): \(message)")
        }
        self.handle = opened
        sqlite3_busy_timeout(opened, 5_000)
        sqlite3_extended_result_codes(opened, 1)

        // WAL keeps the library readable while a future UI writes thumbnails.
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA synchronous = NORMAL;")
        try execute("PRAGMA foreign_keys = ON;")
    }

    deinit {
        if let handle {
            sqlite3_close_v2(handle)
            self.handle = nil
        }
    }

    public func close() {
        if let handle {
            sqlite3_close_v2(handle)
            self.handle = nil
        }
    }

    private var openHandle: OpaquePointer {
        guard let handle else { fatalError("SQLiteDatabase used after close()") }
        return handle
    }

    // MARK: - Statements

    public func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let rc = sql.withCString { sqlite3_exec(openHandle, $0, nil, nil, &errorPointer) }
        guard rc == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(openHandle))
            if let errorPointer { sqlite3_free(errorPointer) }
            throw AtlasError.database("exec failed (\(rc)): \(message) [sql: \(sql.prefix(160))]")
        }
        if let errorPointer { sqlite3_free(errorPointer) }
    }

    public func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        let rc = sql.withCString { sqlite3_prepare_v2(openHandle, $0, -1, &statement, nil) }
        guard rc == SQLITE_OK, let statement else {
            let message = String(cString: sqlite3_errmsg(openHandle))
            throw AtlasError.database("prepare failed (\(rc)): \(message) [sql: \(sql.prefix(160))]")
        }
        return SQLiteStatement(handle: statement, database: openHandle)
    }

    public var lastInsertRowID: Int64 {
        sqlite3_last_insert_rowid(openHandle)
    }

    public var changes: Int32 {
        sqlite3_changes(openHandle)
    }

    // MARK: - Convenience

    /// Runs `body` inside BEGIN IMMEDIATE / COMMIT, rolling back on thrown errors.
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

    public func run(_ sql: String, _ bindings: [SQLiteValue] = []) throws {
        let statement = try prepare(sql)
        try statement.bind(bindings)
        _ = try statement.step()
    }

    public func scalarInt(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> Int64? {
        let statement = try prepare(sql)
        try statement.bind(bindings)
        guard try statement.step() else { return nil }
        return statement.int(0)
    }

    public func scalarText(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> String? {
        let statement = try prepare(sql)
        try statement.bind(bindings)
        guard try statement.step() else { return nil }
        return statement.text(0)
    }

    public var userVersion: Int32 {
        get {
            guard let value = try? scalarInt("PRAGMA user_version;") else { return 0 }
            return Int32(value)
        }
        set {
            try? execute("PRAGMA user_version = \(Int(newValue));")
        }
    }
}

/// A prepared statement. Finalizes itself on deinit.
public final class SQLiteStatement {
    private var handle: OpaquePointer?
    private let database: OpaquePointer

    init(handle: OpaquePointer, database: OpaquePointer) {
        self.handle = handle
        self.database = database
    }

    deinit {
        if let handle {
            sqlite3_finalize(handle)
            self.handle = nil
        }
    }

    private var openHandle: OpaquePointer {
        guard let handle else { fatalError("SQLiteStatement used after finalize") }
        return handle
    }

    private func message(_ rc: Int32, _ verb: String) -> AtlasError {
        .database("\(verb) failed (\(rc)): \(String(cString: sqlite3_errmsg(database)))")
    }

    public func bind(_ values: [SQLiteValue]) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .null:
                rc = sqlite3_bind_null(openHandle, index)
            case .integer(let number):
                rc = sqlite3_bind_int64(openHandle, index, number)
            case .real(let number):
                rc = sqlite3_bind_double(openHandle, index, number)
            case .text(let string):
                rc = string.withCString {
                    sqlite3_bind_text(openHandle, index, $0, -1, SQLiteDatabase.transientCopy)
                }
            case .blob(let data):
                rc = data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(openHandle, index, buffer.baseAddress, Int32(data.count), SQLiteDatabase.transientCopy)
                }
            }
            guard rc == SQLITE_OK else { throw message(rc, "bind #\(index)") }
        }
    }

    /// Returns true when a row is available.
    @discardableResult
    public func step() throws -> Bool {
        let rc = sqlite3_step(openHandle)
        switch rc {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw message(rc, "step")
        }
    }

    public func reset() {
        sqlite3_reset(openHandle)
        sqlite3_clear_bindings(openHandle)
    }

    public func isNull(_ index: Int32) -> Bool {
        sqlite3_column_type(openHandle, index) == SQLITE_NULL
    }

    public func text(_ index: Int32) -> String? {
        guard !isNull(index), let pointer = sqlite3_column_text(openHandle, index) else { return nil }
        return String(cString: pointer)
    }

    public func int(_ index: Int32) -> Int64? {
        guard !isNull(index) else { return nil }
        return sqlite3_column_int64(openHandle, index)
    }

    public func double(_ index: Int32) -> Double? {
        guard !isNull(index) else { return nil }
        return sqlite3_column_double(openHandle, index)
    }

    public func date(_ index: Int32) -> Date? {
        double(index).map { Date(timeIntervalSince1970: $0) }
    }

    public func blob(_ index: Int32) -> Data? {
        guard !isNull(index),
              let pointer = sqlite3_column_blob(openHandle, index) else { return nil }
        let count = Int(sqlite3_column_bytes(openHandle, index))
        guard count > 0 else { return Data() }
        return Data(bytes: pointer, count: count)
    }
}

extension SQLiteDatabase {
    /// SQLITE_TRANSIENT — tells sqlite to copy bound memory immediately.
    /// Exposed so `SQLiteStatement` can bind text/blob safely.
    static var transientCopy: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }
}
