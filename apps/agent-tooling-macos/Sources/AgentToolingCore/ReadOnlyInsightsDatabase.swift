import Foundation
import SQLite3

private let insightsSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct DatabaseConversation {
    var id: String
    var timestamp: Double
}

struct DatabaseRow {
    var kind: String
    var payload: String
    var timestamp: Double
    var turnID: String?

    func date(milliseconds: Bool) -> Date {
        Date(timeIntervalSince1970: milliseconds ? timestamp / 1_000 : timestamp)
    }
}

final class ReadOnlyInsightsDatabase {
    enum Error: Swift.Error {
        case missing
        case unsafePath
        case open
        case query
    }

    private var handle: OpaquePointer?

    init(url: URL, containedBy homeURL: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { throw Error.missing }
        let directValues = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        let resolvedHome = homeURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        guard directValues.isRegularFile == true,
            directValues.isSymbolicLink != true,
            directValues.fileSize.map({ $0 >= 0 && $0 <= 8 * 1_024 * 1_024 * 1_024 }) == true,
            isContained(resolvedURL, by: resolvedHome)
        else { throw Error.unsafePath }

        var database: OpaquePointer?
        guard
            sqlite3_open_v2(
                resolvedURL.path(percentEncoded: false),
                &database,
                SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
                nil
            ) == SQLITE_OK, let database
        else {
            if database != nil { sqlite3_close(database) }
            throw Error.open
        }
        handle = database
        guard sqlite3_busy_timeout(database, 1_000) == SQLITE_OK,
            sqlite3_exec(database, "PRAGMA query_only = ON", nil, nil, nil) == SQLITE_OK
        else {
            sqlite3_close(database)
            handle = nil
            throw Error.open
        }
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    func queryConversationIDs(sql: String, cutoff: Double, limit: Int) throws -> [DatabaseConversation] {
        guard let handle else { throw Error.open }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
            sqlite3_bind_double(statement, 1, cutoff) == SQLITE_OK,
            sqlite3_bind_int64(statement, 2, Int64(limit)) == SQLITE_OK
        else { throw Error.query }
        var result: [DatabaseConversation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = boundedText(statement, column: 0, maximumBytes: 8 * 1_024) else { continue }
            result.append(.init(id: id, timestamp: sqlite3_column_double(statement, 1)))
        }
        guard sqlite3_errcode(handle) == SQLITE_OK || sqlite3_errcode(handle) == SQLITE_DONE else { throw Error.query }
        return result
    }

    func queryRows(
        sql: String,
        conversationID: String,
        cutoff: Double,
        limit: Int,
        maximumTextBytes: Int
    ) throws -> [DatabaseRow?] {
        try queryRows(
            sql: sql,
            bindings: [.text(conversationID), .double(cutoff), .integer(limit)],
            maximumTextBytes: maximumTextBytes
        )
    }

    func queryRows(
        sql: String,
        repeatedConversationID: String,
        repeatedCutoff: Double,
        limit: Int,
        maximumTextBytes: Int
    ) throws -> [DatabaseRow?] {
        try queryRows(
            sql: sql,
            bindings: [
                .text(repeatedConversationID), .double(repeatedCutoff),
                .text(repeatedConversationID), .double(repeatedCutoff), .integer(limit),
            ],
            maximumTextBytes: maximumTextBytes
        )
    }

    private enum Binding {
        case text(String)
        case double(Double)
        case integer(Int)
    }

    private func queryRows(sql: String, bindings: [Binding], maximumTextBytes: Int) throws -> [DatabaseRow?] {
        guard let handle else { throw Error.open }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw Error.query }
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case .text(let value):
                result = sqlite3_bind_text(statement, index, value, -1, insightsSQLiteTransient)
            case .double(let value):
                result = sqlite3_bind_double(statement, index, value)
            case .integer(let value):
                result = sqlite3_bind_int64(statement, index, Int64(value))
            }
            guard result == SQLITE_OK else { throw Error.query }
        }

        var rows: [DatabaseRow?] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let kind = boundedText(statement, column: 0, maximumBytes: 256),
                let payload = boundedText(statement, column: 1, maximumBytes: maximumTextBytes)
            else {
                rows.append(nil)
                continue
            }
            let turnID =
                sqlite3_column_count(statement) > 3
                ? boundedText(statement, column: 3, maximumBytes: 8 * 1_024)
                : nil
            rows.append(
                DatabaseRow(
                    kind: kind,
                    payload: payload,
                    timestamp: sqlite3_column_double(statement, 2),
                    turnID: turnID
                )
            )
        }
        guard sqlite3_errcode(handle) == SQLITE_OK || sqlite3_errcode(handle) == SQLITE_DONE else { throw Error.query }
        return rows
    }

    private func boundedText(_ statement: OpaquePointer?, column: Int32, maximumBytes: Int) -> String? {
        let byteCount = Int(sqlite3_column_bytes(statement, column))
        guard byteCount >= 0, byteCount <= maximumBytes,
            let pointer = sqlite3_column_text(statement, column)
        else { return nil }
        return String(bytes: UnsafeBufferPointer(start: pointer, count: byteCount), encoding: .utf8)
    }
}
