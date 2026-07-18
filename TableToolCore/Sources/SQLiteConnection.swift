import Foundation
import SQLite3

enum SQLiteFailure: Error, LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case let .message(message) = self { message } else { nil }
    }
}

final class SQLiteConnection {
    let handle: OpaquePointer
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open SQLite workspace."
            if let db { sqlite3_close(db) }
            throw SQLiteFailure.message(message)
        }
        handle = db
        sqlite3_create_function_v2(
            handle,
            "regexp",
            2,
            SQLITE_UTF8 | SQLITE_DETERMINISTIC,
            nil,
            { context, count, values in
                guard count == 2, let values,
                      let patternBytes = sqlite3_value_text(values[0]),
                      let valueBytes = sqlite3_value_text(values[1]) else {
                    sqlite3_result_int(context, 0)
                    return
                }
                let patternLength = Int(sqlite3_value_bytes(values[0]))
                let valueLength = Int(sqlite3_value_bytes(values[1]))
                let pattern = String(decoding: UnsafeBufferPointer(start: patternBytes, count: patternLength), as: UTF8.self)
                let value = String(decoding: UnsafeBufferPointer(start: valueBytes, count: valueLength), as: UTF8.self)
                do {
                    let expression = try NSRegularExpression(pattern: pattern)
                    let range = NSRange(value.startIndex..<value.endIndex, in: value)
                    sqlite3_result_int(context, expression.firstMatch(in: value, range: range) == nil ? 0 : 1)
                } catch {
                    sqlite3_result_error(context, "Invalid regular expression", -1)
                }
            },
            nil,
            nil,
            nil
        )
        try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA temp_store=FILE; PRAGMA cache_size=-16384; PRAGMA foreign_keys=ON;")
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String) throws {
        let isRollback = sql.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased().hasPrefix("ROLLBACK")
        if !isRollback { installCancellationProgressHandler() }
        defer { if !isRollback { sqlite3_progress_handler(handle, 0, nil, nil) } }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(error)
            if sqlite3_errcode(handle) == SQLITE_INTERRUPT, currentTaskIsCancelled { throw CancellationError() }
            throw SQLiteFailure.message(message)
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteFailure.message(String(cString: sqlite3_errmsg(handle)))
        }
        return statement
    }

    func stepDone(_ statement: OpaquePointer) throws {
        installCancellationProgressHandler()
        defer { sqlite3_progress_handler(handle, 0, nil, nil) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            if sqlite3_errcode(handle) == SQLITE_INTERRUPT, currentTaskIsCancelled { throw CancellationError() }
            throw SQLiteFailure.message(String(cString: sqlite3_errmsg(handle)))
        }
    }

    func bind(_ value: Int64, at index: Int32, to statement: OpaquePointer) {
        sqlite3_bind_int64(statement, index, value)
    }

    func bind(_ value: Double?, at index: Int32, to statement: OpaquePointer) {
        if let value { sqlite3_bind_double(statement, index, value) } else { sqlite3_bind_null(statement, index) }
    }

    func bind(_ value: String?, at index: Int32, to statement: OpaquePointer) {
        if let value {
            let utf8 = value.utf8CString
            _ = utf8.withUnsafeBufferPointer { bytes in
                sqlite3_bind_text(statement, index, bytes.baseAddress, Int32(bytes.count - 1), Self.transient)
            }
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    func bind(_ value: Data, at index: Int32, to statement: OpaquePointer) {
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), Self.transient)
        }
    }

    private var currentTaskIsCancelled: Bool {
        withUnsafeCurrentTask { task in task?.isCancelled == true }
    }

    private func installCancellationProgressHandler() {
        sqlite3_progress_handler(handle, 10_000, { _ in
            withUnsafeCurrentTask { task in task?.isCancelled == true } ? 1 : 0
        }, nil)
    }
}
