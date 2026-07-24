import EdgeLinkKit
import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1)!, to: sqlite3_destructor_type.self)

final class ClipboardHistoryStore {
    private let databaseURL: URL
    private let queue = DispatchQueue(label: "com.edgelink.clipboard-history")

    init?(directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            DiagnosticsLog.error("clipboard.history.store.mkdir_failed", error)
            return nil
        }
        databaseURL = directory.appendingPathComponent("clipboard-history.db")
        do {
            try ensureSchema()
        } catch {
            DiagnosticsLog.error("clipboard.history.store.schema_failed", error)
            return nil
        }
    }

    func append(_ item: ClipboardHistoryItemBody, itemIndex: Int = 0) {
        queue.sync {
            runWrite { database in
                let sql = """
                INSERT OR REPLACE INTO clipboard_history
                (event_id, item_index, timestamp, clipboard_type, text_data, file_path,
                 thumbnail_base64, hash, source_device_id)
                VALUES (?, ?, ?, ?, ?, NULL, ?, ?, ?)
                """
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                      let stmt = statement else {
                    DiagnosticsLog.warn("clipboard.history.store.append_prepare_failed")
                    return
                }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, item.id, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 2, sqlite_int64(itemIndex))
                sqlite3_bind_int64(stmt, 3, sqlite_int64(item.ts))
                sqlite3_bind_int(stmt, 4, Int32(ClipboardKind(rawValue: item.kind)?.intValue ?? 0))
                if let text = item.text { sqlite3_bind_text(stmt, 5, text, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 5) }
                if let thumb = item.thumbnailBase64 { sqlite3_bind_text(stmt, 6, thumb, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 6) }
                sqlite3_bind_text(stmt, 7, item.hash, -1, SQLITE_TRANSIENT)
                if let source = item.sourceDeviceId { sqlite3_bind_text(stmt, 8, source, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 8) }
                _ = sqlite3_step(stmt)
            }
        }
    }

    func importRemote(_ items: [ClipboardHistoryItemBody]) -> Int {
        guard !items.isEmpty else { return 0 }
        return queue.sync { () -> Int in
            var inserted = 0
            runWrite { database in
                for item in items {
                    let sql = """
                    INSERT OR IGNORE INTO clipboard_history
                    (event_id, item_index, timestamp, clipboard_type, text_data, file_path,
                     thumbnail_base64, hash, source_device_id)
                    VALUES (?, ?, ?, ?, ?, NULL, ?, ?, ?)
                    """
                    var statement: OpaquePointer?
                    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                          let stmt = statement else {
                        continue
                    }
                    defer { sqlite3_finalize(stmt) }
                    sqlite3_bind_text(stmt, 1, item.id, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int64(stmt, 2, 0)
                    sqlite3_bind_int64(stmt, 3, sqlite_int64(item.ts))
                    sqlite3_bind_int(stmt, 4, Int32(ClipboardKind(rawValue: item.kind)?.intValue ?? 0))
                    if let text = item.text { sqlite3_bind_text(stmt, 5, text, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 5) }
                    if let thumb = item.thumbnailBase64 { sqlite3_bind_text(stmt, 6, thumb, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 6) }
                    sqlite3_bind_text(stmt, 7, item.hash, -1, SQLITE_TRANSIENT)
                    if let source = item.sourceDeviceId { sqlite3_bind_text(stmt, 8, source, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 8) }
                    if sqlite3_step(stmt) == SQLITE_DONE {
                        if sqlite3_changes(database) > 0 {
                            inserted += 1
                        }
                    }
                }
            }
            return inserted
        }
    }

    func recent(sinceTs: Int64? = nil, limit: Int = 50) -> [ClipboardHistoryItemBody] {
        queue.sync {
            runRead { database -> [ClipboardHistoryItemBody] in
                var sql = """
                SELECT event_id, timestamp, clipboard_type, text_data, thumbnail_base64,
                       hash, source_device_id
                FROM clipboard_history
                """
                if sinceTs != nil {
                    sql += " WHERE timestamp > ?"
                }
                sql += " ORDER BY timestamp DESC LIMIT ?"

                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                      let stmt = statement else {
                    return []
                }
                defer { sqlite3_finalize(stmt) }
                var bindIndex: Int32 = 1
                if let since = sinceTs {
                    sqlite3_bind_int64(stmt, bindIndex, sqlite_int64(since))
                    bindIndex += 1
                }
                sqlite3_bind_int(stmt, bindIndex, Int32(max(0, min(limit, 200))))

                var items: [ClipboardHistoryItemBody] = []
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = columnText(stmt, 0) ?? ""
                    let ts = sqlite3_column_int64(stmt, 1)
                    let kindInt = sqlite3_column_int(stmt, 2)
                    let kind = ClipboardKind(intValue: Int(kindInt))?.rawValue ?? ClipboardKind.text.rawValue
                    let text = columnText(stmt, 3)
                    let thumbnail = columnText(stmt, 4)
                    let hash = columnText(stmt, 5) ?? ""
                    let source = columnText(stmt, 6)
                    items.append(
                        ClipboardHistoryItemBody(
                            id: id,
                            kind: kind,
                            ts: ts,
                            hash: hash,
                            text: text,
                            thumbnailBase64: thumbnail,
                            sourceDeviceId: source
                        )
                    )
                }
                return items
            } ?? []
        }
    }

    func prune(maxCount: Int = 200) {
        queue.sync {
            runWrite { database in
                let sql = """
                DELETE FROM clipboard_history
                WHERE (event_id, item_index) IN (
                    SELECT event_id, item_index FROM clipboard_history
                    ORDER BY timestamp DESC
                    LIMIT -1 OFFSET ?
                )
                """
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                      let stmt = statement else {
                    return
                }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_int(stmt, 1, Int32(maxCount))
                _ = sqlite3_step(stmt)
            }
        }
    }

    func clear() {
        queue.sync {
            runWrite { database in
                _ = sqlite3_exec(database, "DELETE FROM clipboard_history;", nil, nil, nil)
            }
        }
    }

    var count: Int {
        queue.sync {
            runRead { database -> Int in
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM clipboard_history;", -1, &statement, nil) == SQLITE_OK,
                      let stmt = statement else {
                    return 0
                }
                defer { sqlite3_finalize(stmt) }
                if sqlite3_step(stmt) == SQLITE_ROW {
                    return Int(sqlite3_column_int64(stmt, 0))
                }
                return 0
            } ?? 0
        }
    }

    private func ensureSchema() throws {
        try runWriteThrowing { database in
            _ = sqlite3_exec(database, "PRAGMA journal_mode=WAL;", nil, nil, nil)
            let createTable = """
            CREATE TABLE IF NOT EXISTS clipboard_history (
                event_id TEXT NOT NULL,
                item_index INTEGER NOT NULL DEFAULT 0,
                timestamp INTEGER NOT NULL,
                clipboard_type INTEGER NOT NULL,
                text_data TEXT,
                file_path TEXT,
                thumbnail_base64 TEXT,
                hash TEXT NOT NULL,
                source_device_id TEXT,
                PRIMARY KEY (event_id, item_index)
            );
            """
            if sqlite3_exec(database, createTable, nil, nil, nil) != SQLITE_OK {
                throw ClipboardHistoryStoreError.schema
            }
            if sqlite3_exec(database, "CREATE INDEX IF NOT EXISTS idx_clip_hist_ts ON clipboard_history(timestamp DESC);", nil, nil, nil) != SQLITE_OK {
                throw ClipboardHistoryStoreError.schema
            }
        }
    }

    private func openConnection(flags: Int32) throws -> OpaquePointer {
        var database: OpaquePointer?
        let status = sqlite3_open_v2(databaseURL.path, &database, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let database else {
            sqlite3_close(database)
            throw ClipboardHistoryStoreError.open(status)
        }
        return database
    }

    private func runRead<T>(_ work: (OpaquePointer) -> T) -> T? {
        do {
            let database = try openConnection(flags: SQLITE_OPEN_READONLY)
            defer { sqlite3_close(database) }
            return work(database)
        } catch {
            DiagnosticsLog.error("clipboard.history.store.open_failed", error)
            return nil
        }
    }

    private func runWrite(_ work: (OpaquePointer) -> Void) {
        do {
            let database = try openConnection(flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
            defer { sqlite3_close(database) }
            work(database)
        } catch {
            DiagnosticsLog.error("clipboard.history.store.open_failed", error)
        }
    }

    private func runWriteThrowing(_ work: (OpaquePointer) throws -> Void) throws {
        let database = try openConnection(flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        defer { sqlite3_close(database) }
        try work(database)
    }

    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: pointer)
    }
}

private enum ClipboardHistoryStoreError: Error {
    case open(Int32)
    case schema
}