import EdgeLinkKit
import Foundation
import CryptoKit
import Photos
import SQLite3

private let photoSyncSQLITETRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1)!, to: sqlite3_destructor_type.self)

final class MacPhotoSyncService: @unchecked Sendable {
    struct IncomingTransfer {
        let id: String
        let name: String
        let mime: String
        let expectedBytes: Int64
        let dateTakenMs: Int64
        let isVideo: Bool
        let fileURL: URL
        var handle: FileHandle?
        var nextSeq: Int
        var receivedBytes: Int64
    }

    private let databaseURL: URL
    private let inboxDirectory: URL
    private let queue = DispatchQueue(label: "com.edgelink.photo-sync")
    private var activeTransfers: [String: IncomingTransfer] = [:]
    private let onImportDone: @Sendable ([String], [String]) -> Void
    private let onStatus: @Sendable (String) -> Void

    init?(
        directory: URL,
        onImportDone: @escaping @Sendable ([String], [String]) -> Void,
        onStatus: @escaping @Sendable (String) -> Void
    ) {
        self.onImportDone = onImportDone
        self.onStatus = onStatus
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            inboxDirectory = directory.appendingPathComponent("inbox", isDirectory: true)
            try FileManager.default.createDirectory(at: inboxDirectory, withIntermediateDirectories: true)
        } catch {
            DiagnosticsLog.error("photo.mac.store.mkdir_failed", error)
            return nil
        }
        databaseURL = directory.appendingPathComponent("photo-sync.db")
        do {
            try ensureSchema()
        } catch {
            DiagnosticsLog.error("photo.mac.store.schema_failed", error)
            return nil
        }
    }

    func filterWanted(_ items: [PhotoManifestItemBody]) -> [String] {
        guard !items.isEmpty else { return [] }
        let synced = queue.sync { () -> Set<String> in
            runRead { database in
                var ids = Set<String>()
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, "SELECT item_id FROM synced_photos", -1, &statement, nil) == SQLITE_OK,
                      let stmt = statement else {
                    return ids
                }
                defer { sqlite3_finalize(stmt) }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let cString = sqlite3_column_text(stmt, 0) {
                        ids.insert(String(cString: cString))
                    }
                }
                return ids
            } ?? []
        }
        return items.filter { !synced.contains($0.id) }.map { $0.id }
    }

    func resetTransfers(reason: String) {
        queue.sync {
            for (_, transfer) in activeTransfers {
                try? transfer.handle?.close()
                try? FileManager.default.removeItem(at: transfer.fileURL)
            }
            if !activeTransfers.isEmpty {
                DiagnosticsLog.info("photo.mac.transfers_reset count=\(activeTransfers.count) reason=\(reason)")
            }
            activeTransfers.removeAll()
        }
    }

    func handleBegin(_ body: PhotoBeginBody) {
        queue.sync {
            if var existing = activeTransfers[body.id] {
                try? existing.handle?.close()
                try? FileManager.default.removeItem(at: existing.fileURL)
                activeTransfers.removeValue(forKey: body.id)
            }
            let safeName = body.name.replacingOccurrences(of: "/", with: "_")
            let fileURL = inboxDirectory.appendingPathComponent("\(body.id)-\(safeName)")
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            let handle = try? FileHandle(forWritingTo: fileURL)
            activeTransfers[body.id] = IncomingTransfer(
                id: body.id,
                name: body.name,
                mime: body.mime,
                expectedBytes: body.bytes,
                dateTakenMs: body.dateTakenMs,
                isVideo: body.isVideo,
                fileURL: fileURL,
                handle: handle,
                nextSeq: 0,
                receivedBytes: 0
            )
        }
    }

    func handleChunk(_ body: PhotoChunkBody) {
        let completed = queue.sync { () -> (transfer: IncomingTransfer, hash: String?)? in
            guard var transfer = activeTransfers[body.id] else {
                DiagnosticsLog.warn("photo.mac.chunk_unknown id=\(body.id) seq=\(body.seq)")
                return nil
            }
            guard body.seq == transfer.nextSeq else {
                DiagnosticsLog.warn("photo.mac.chunk_out_of_order id=\(body.id) seq=\(body.seq) expected=\(transfer.nextSeq)")
                try? transfer.handle?.close()
                try? FileManager.default.removeItem(at: transfer.fileURL)
                activeTransfers.removeValue(forKey: body.id)
                onImportDone([], [body.id])
                return nil
            }
            if let data = Data(base64Encoded: body.payloadBase64), !data.isEmpty {
                do {
                    try transfer.handle?.write(contentsOf: data)
                    transfer.receivedBytes += Int64(data.count)
                } catch {
                    DiagnosticsLog.error("photo.mac.chunk_write_failed id=\(body.id)", error)
                    try? transfer.handle?.close()
                    try? FileManager.default.removeItem(at: transfer.fileURL)
                    activeTransfers.removeValue(forKey: body.id)
                    onImportDone([], [body.id])
                    return nil
                }
            }
            transfer.nextSeq += 1
            guard body.fin else {
                activeTransfers[body.id] = transfer
                return nil
            }
            try? transfer.handle?.close()
            activeTransfers.removeValue(forKey: body.id)
            return (transfer, body.hash)
        }
        guard let completed else { return }
        Task.detached { [weak self] in
            await self?.importCompleted(transfer: completed.transfer, expectedHash: completed.hash)
        }
    }

    private func importCompleted(transfer: IncomingTransfer, expectedHash: String?) async {
        let fileURL = transfer.fileURL
        defer { try? FileManager.default.removeItem(at: fileURL) }
        guard let actualHash = Self.streamedSHA256Hex(fileURL: fileURL) else {
            DiagnosticsLog.warn("photo.mac.readback_failed id=\(transfer.id)")
            onImportDone([], [transfer.id])
            return
        }
        if let expected = expectedHash, actualHash != expected {
            DiagnosticsLog.warn("photo.mac.hash_mismatch id=\(transfer.id)")
            onImportDone([], [transfer.id])
            return
        }
        let imported = await importToPhotos(transfer: transfer)
        if imported {
            recordSynced(id: transfer.id, hash: expectedHash ?? actualHash, name: transfer.name)
            DiagnosticsLog.info("photo.mac.imported id=\(transfer.id) name=\(transfer.name) bytes=\(transfer.receivedBytes)")
            onStatus("已匯入 \(transfer.name)")
            onImportDone([transfer.id], [])
        } else {
            onStatus("匯入失敗 \(transfer.name)")
            onImportDone([], [transfer.id])
        }
    }

    private static func streamedSHA256Hex(fileURL: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try? handle.read(upToCount: 1024 * 1024)
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func importToPhotos(transfer: IncomingTransfer) async -> Bool {
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard authorization == .authorized || authorization == .limited else {
            DiagnosticsLog.warn("photo.mac.photos_unauthorized status=\(authorization.rawValue)")
            return false
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = transfer.name
                request.addResource(
                    with: transfer.isVideo ? .video : .photo,
                    fileURL: transfer.fileURL,
                    options: options
                )
                request.creationDate = Date(timeIntervalSince1970: TimeInterval(transfer.dateTakenMs) / 1_000.0)
            }
            return true
        } catch {
            DiagnosticsLog.error("photo.mac.photos_import_failed id=\(transfer.id)", error)
            return false
        }
    }

    private func recordSynced(id: String, hash: String, name: String) {
        queue.sync {
            runWrite { database in
                let sql = "INSERT OR REPLACE INTO synced_photos (item_id, sha256, name, imported_at) VALUES (?, ?, ?, ?)"
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                      let stmt = statement else {
                    return
                }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, id, -1, photoSyncSQLITETRANSIENT)
                sqlite3_bind_text(stmt, 2, hash, -1, photoSyncSQLITETRANSIENT)
                sqlite3_bind_text(stmt, 3, name, -1, photoSyncSQLITETRANSIENT)
                sqlite3_bind_int64(stmt, 4, sqlite_int64(Date().timeIntervalSince1970))
                _ = sqlite3_step(stmt)
            }
        }
    }

    private func ensureSchema() throws {
        try runWriteThrowing { database in
            let sql = """
            CREATE TABLE IF NOT EXISTS synced_photos (
                item_id TEXT PRIMARY KEY,
                sha256 TEXT NOT NULL,
                name TEXT NOT NULL,
                imported_at INTEGER NOT NULL
            )
            """
            var error: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(database, sql, nil, nil, &error) != SQLITE_OK {
                let message = error.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(error)
                throw NSError(domain: "MacPhotoSyncService", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
    }

    private func runRead<T>(_ work: (OpaquePointer) -> T) -> T? {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let db = database else {
            return nil
        }
        defer { sqlite3_close(db) }
        return work(db)
    }

    private func runWrite(_ work: (OpaquePointer) -> Void) {
        try? runWriteThrowing(work)
    }

    private func runWriteThrowing(_ work: (OpaquePointer) throws -> Void) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let db = database else {
            throw NSError(domain: "MacPhotoSyncService", code: 2, userInfo: [NSLocalizedDescriptionKey: "open_failed"])
        }
        defer { sqlite3_close(db) }
        try work(db)
    }
}
