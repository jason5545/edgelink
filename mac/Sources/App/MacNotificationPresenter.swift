import CryptoKit
import EdgeLinkKit
import Foundation
import UserNotifications

final class MacNotificationPresenter: @unchecked Sendable {
    fileprivate static let verificationCodeCategoryIdentifier = "edgelink.verification-code"
    fileprivate static let copyVerificationCodeActionIdentifier = "edgelink.copy-verification-code"

    private let center: UNUserNotificationCenter?
    private let delegate = MacNotificationCenterDelegate()
    var onCopyVerificationCode: (@Sendable (String) -> Void)? {
        get { delegate.onCopyVerificationCode }
        set { delegate.onCopyVerificationCode = newValue }
    }

    init() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier, !bundleIdentifier.isEmpty else {
            DiagnosticsLog.warn("notification.mac.remote_unavailable missing_bundle_identifier")
            center = nil
            return
        }
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = delegate
        notificationCenter.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.verificationCodeCategoryIdentifier,
                actions: [
                    UNNotificationAction(
                        identifier: Self.copyVerificationCodeActionIdentifier,
                        title: "複製",
                        options: []
                    )
                ],
                intentIdentifiers: [],
                options: []
            )
        ])
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
                    "edgelinkDoNotForward": true,
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

    func showVerificationCode(_ candidate: VerificationCodeCandidate, message: SmsMessageBody) {
        guard let center else {
            DiagnosticsLog.warn("verification.mac.notification_unavailable id=\(candidate.id)")
            return
        }

        Task {
            do {
                guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                    DiagnosticsLog.warn("verification.mac.notification_permission_denied id=\(candidate.id)")
                    return
                }

                let content = UNMutableNotificationContent()
                content.title = "驗證碼 \(candidate.displayCode)"
                content.subtitle = message.address
                content.body = Self.verificationNotificationBody(candidate: candidate, message: message)
                content.sound = .default
                content.interruptionLevel = .timeSensitive
                content.categoryIdentifier = Self.verificationCodeCategoryIdentifier
                content.threadIdentifier = "edgelink.verification.\(message.sourceDeviceId ?? "unknown")"
                content.userInfo = [
                    "edgelinkDoNotForward": true,
                    "edgelinkVerificationCode": candidate.code,
                    "edgelinkVerificationId": candidate.id,
                    "sourceDeviceId": message.sourceDeviceId ?? "",
                    "sourcePlatform": message.sourcePlatform ?? ""
                ]

                let request = UNNotificationRequest(
                    identifier: requestIdentifier(id: candidate.id, sourceDeviceId: message.sourceDeviceId),
                    content: content,
                    trigger: nil
                )
                try await center.add(request)
                DiagnosticsLog.info("verification.mac.notification_shown id=\(candidate.id)")
            } catch {
                DiagnosticsLog.error("verification.mac.notification_show_failed id=\(candidate.id)", error)
            }
        }
    }

    private func requestIdentifier(id: String, sourceDeviceId: String?) -> String {
        let raw = "\(sourceDeviceId ?? "remote"):\(id)"
        let digest = SHA256.hash(data: Data(raw.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "edgelink.remote.\(digest)"
    }

    private static func verificationNotificationBody(candidate: VerificationCodeCandidate, message: SmsMessageBody) -> String {
        var body = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let machineReadableCode = candidate.machineReadableCode, !body.contains(machineReadableCode) {
            body += "\n\(machineReadableCode)"
        } else if let domain = candidate.domain {
            let machineReadableCode = "@\(domain) #\(candidate.code)"
            if !body.contains(machineReadableCode) {
                body += "\n\(machineReadableCode)"
            }
        }
        return body
    }
}

private final class MacNotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate {
    var onCopyVerificationCode: (@Sendable (String) -> Void)?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == MacNotificationPresenter.copyVerificationCodeActionIdentifier,
              let code = response.notification.request.content.userInfo["edgelinkVerificationCode"] as? String,
              !code.isEmpty
        else {
            return
        }
        onCopyVerificationCode?(code)
    }
}
