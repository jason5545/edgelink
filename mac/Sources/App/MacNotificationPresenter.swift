import CryptoKit
import EdgeLinkKit
import Foundation
import UserNotifications

final class MacNotificationPresenter: @unchecked Sendable {
    private let center: UNUserNotificationCenter?
    private let delegate = MacNotificationCenterDelegate()

    init() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier, !bundleIdentifier.isEmpty else {
            DiagnosticsLog.warn("notification.mac.remote_unavailable missing_bundle_identifier")
            center = nil
            return
        }
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = delegate
        center = notificationCenter
    }

    func show(_ body: NotificationPostBody) {
        guard let center else {
            DiagnosticsLog.warn("notification.mac.remote_unavailable id=\(body.id)")
            return
        }

        Task {
            let title = body.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = body.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty || !text.isEmpty else {
                DiagnosticsLog.warn("notification.mac.remote_empty id=\(body.id)")
                return
            }

            do {
                guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                    DiagnosticsLog.warn("notification.mac.permission_denied id=\(body.id)")
                    return
                }

                let content = UNMutableNotificationContent()
                content.title = title.isEmpty ? body.app : title
                content.subtitle = title.isEmpty ? "" : body.app
                content.body = text
                content.sound = .default
                content.threadIdentifier = "edgelink.remote.\(body.sourceDeviceId ?? "unknown")"
                content.userInfo = [
                    "edgelinkNotificationId": body.id,
                    "sourceDeviceId": body.sourceDeviceId ?? "",
                    "sourcePlatform": body.sourcePlatform ?? ""
                ]

                let request = UNNotificationRequest(
                    identifier: requestIdentifier(id: body.id, sourceDeviceId: body.sourceDeviceId),
                    content: content,
                    trigger: nil
                )
                try await center.add(request)
                DiagnosticsLog.info("notification.mac.remote_shown id=\(body.id) app=\(body.app)")
            } catch {
                DiagnosticsLog.error("notification.mac.remote_show_failed id=\(body.id)", error)
            }
        }
    }

    func remove(_ body: NotificationRemoveBody) {
        guard let center else {
            DiagnosticsLog.warn("notification.mac.remote_remove_unavailable id=\(body.id)")
            return
        }

        let identifier = requestIdentifier(id: body.id, sourceDeviceId: body.sourceDeviceId)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        DiagnosticsLog.info("notification.mac.remote_removed id=\(body.id)")
    }

    private func requestIdentifier(id: String, sourceDeviceId: String?) -> String {
        let raw = "\(sourceDeviceId ?? "remote"):\(id)"
        let digest = SHA256.hash(data: Data(raw.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "edgelink.remote.\(digest)"
    }
}

private final class MacNotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
