import AppKit
import EdgeLinkKit
import Foundation
import SQLite3

actor MacNotificationDatabaseSource {
    private let databaseURL: URL
    private var lastDeliveredDate: Double?
    private var emittedIds = Set<String>()

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        databaseURL = homeDirectory
            .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")
    }

    func resetBaseline() {
        do {
            lastDeliveredDate = try maxDeliveredDate()
            emittedIds.removeAll(keepingCapacity: true)
            DiagnosticsLog.info("notification.mac.db.baseline deliveredDate=\(lastDeliveredDate ?? 0)")
        } catch {
            DiagnosticsLog.error("notification.mac.db.baseline_failed", error)
        }
    }

    func poll(sourceDeviceId: String) -> [NotificationPostBody] {
        do {
            if lastDeliveredDate == nil {
                lastDeliveredDate = try maxDeliveredDate()
                DiagnosticsLog.info("notification.mac.db.initial_baseline deliveredDate=\(lastDeliveredDate ?? 0)")
                return []
            }

            let rows = try fetchRows(after: lastDeliveredDate ?? 0)
            var bodies: [NotificationPostBody] = []
            for row in rows {
                lastDeliveredDate = max(lastDeliveredDate ?? 0, row.deliveredDate)
                guard !emittedIds.contains(row.id) else {
                    continue
                }
                guard row.bundleIdentifier != Bundle.main.bundleIdentifier else {
                    continue
                }
                guard let body = makeBody(row: row, sourceDeviceId: sourceDeviceId) else {
                    continue
                }
                emittedIds.insert(row.id)
                bodies.append(body)
            }
            return bodies
        } catch {
            DiagnosticsLog.error("notification.mac.db.poll_failed", error)
            return []
        }
    }

    private func makeBody(row: NotificationRow, sourceDeviceId: String) -> NotificationPostBody? {
        guard
            let plist = try? PropertyListSerialization.propertyList(from: row.data, options: [], format: nil),
            let root = plist as? [String: Any],
            let request = root["req"] as? [String: Any]
        else {
            DiagnosticsLog.warn("notification.mac.db.invalid_blob id=\(row.id)")
            return nil
        }

        let title = stringValue(request["titl"])
        let text = stringValue(request["body"])
        let subtitle = stringValue(request["subt"])
        guard !title.isEmpty || !text.isEmpty else {
            return nil
        }

        let bundleIdentifier = row.bundleIdentifier ?? stringValue(root["app"]).ifEmpty(nil)
        return NotificationPostBody(
            id: "mac:\(row.id)",
            sourceDeviceId: sourceDeviceId,
            sourcePlatform: "macos",
            app: displayName(bundleIdentifier: bundleIdentifier),
            bundle: bundleIdentifier,
            title: title,
            text: text,
            subtitle: subtitle.ifEmpty(nil),
            ts: Int64(row.deliveredDate + 978_307_200)
        )
    }

    private func maxDeliveredDate() throws -> Double {
        try withDatabase { database in
            let sql = "select coalesce(max(delivered_date), 0) from record where delivered_date is not null"
            let statement = try prepare(database: database, sql: sql)
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return 0
            }
            return sqlite3_column_double(statement, 0)
        }
    }

    private func fetchRows(after deliveredDate: Double) throws -> [NotificationRow] {
        try withDatabase { database in
            let sql = """
            select lower(hex(r.uuid)), r.delivered_date, r.data, a.identifier
            from record r
            left join app a on r.app_id = a.app_id
            where r.delivered_date is not null and r.presented = 1 and r.delivered_date > ?
            order by r.delivered_date asc
            limit 50
            """
            let statement = try prepare(database: database, sql: sql)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, deliveredDate)

            var rows: [NotificationRow] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard
                    let idPointer = sqlite3_column_text(statement, 0),
                    let dataPointer = sqlite3_column_blob(statement, 2)
                else {
                    continue
                }
                let id = String(cString: idPointer)
                let deliveredDate = sqlite3_column_double(statement, 1)
                let data = Data(bytes: dataPointer, count: Int(sqlite3_column_bytes(statement, 2)))
                let bundleIdentifier = sqlite3_column_text(statement, 3).map { String(cString: $0) }
                rows.append(
                    NotificationRow(
                        id: id,
                        deliveredDate: deliveredDate,
                        data: data,
                        bundleIdentifier: bundleIdentifier
                    )
                )
            }
            return rows
        }
    }

    private func withDatabase<T>(_ work: (OpaquePointer) throws -> T) throws -> T {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(databaseURL.path, &database, flags, nil)
        guard status == SQLITE_OK, let database else {
            defer { sqlite3_close(database) }
            throw MacNotificationDatabaseError.open(status)
        }
        defer { sqlite3_close(database) }
        return try work(database)
    }

    private func prepare(database: OpaquePointer, sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            throw MacNotificationDatabaseError.prepare(status)
        }
        return statement
    }

    private func displayName(bundleIdentifier: String?) -> String {
        guard
            let bundleIdentifier,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else {
            return bundleIdentifier ?? "Mac"
        }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func stringValue(_ value: Any?) -> String {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private struct NotificationRow {
    let id: String
    let deliveredDate: Double
    let data: Data
    let bundleIdentifier: String?
}

private enum MacNotificationDatabaseError: Error {
    case open(Int32)
    case prepare(Int32)
}

private extension String {
    func ifEmpty(_ fallback: String?) -> String? {
        isEmpty ? fallback : self
    }
}
