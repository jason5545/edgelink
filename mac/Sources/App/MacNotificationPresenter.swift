import CryptoKit
import EdgeLinkKit
import Foundation
import Intents
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
                        title: String(localized: "複製"),
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

                let iconPNGData = body.iconPngBase64.flatMap(Self.validIconPNGData)
                if body.iconPngBase64 != nil && iconPNGData == nil {
                    DiagnosticsLog.warn("notification.mac.remote_icon_invalid id=\(body.id)")
                }
                var finalContent: UNNotificationContent = content
                if let iconPNGData {
                    do {
                        finalContent = try await Self.communicationContent(
                            base: content,
                            body: body,
                            iconPNGData: iconPNGData
                        )
                    } catch {
                        DiagnosticsLog.warn("notification.mac.remote_intent_failed id=\(body.id): \(error)")
                    }
                }
                let request = UNNotificationRequest(
                    identifier: requestIdentifier(id: body.id, sourceDeviceId: body.sourceDeviceId),
                    content: finalContent,
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
                content.title = String(localized: "驗證碼 \(candidate.displayCode)")
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

    private static func communicationContent(
        base: UNMutableNotificationContent,
        body: NotificationPostBody,
        iconPNGData: Data
    ) async throws -> UNNotificationContent {
        let handleValue = body.bundle ?? body.app
        let sender = INPerson(
            personHandle: INPersonHandle(value: handleValue, type: .unknown),
            nameComponents: nil,
            displayName: body.app,
            image: INImage(imageData: iconPNGData),
            contactIdentifier: nil,
            customIdentifier: "edgelink.app.\(handleValue)"
        )
        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: base.body,
            speakableGroupName: nil,
            conversationIdentifier: "\(base.threadIdentifier).\(handleValue)",
            serviceName: nil,
            sender: sender,
            attachments: nil
        )
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        try? await interaction.donate()
        return try base.updating(from: intent)
    }

    private static func validIconPNGData(pngBase64: String) -> Data? {
        guard
            let pngData = Data(base64Encoded: pngBase64),
            pngData.count <= maximumIconPngBytes,
            pngData.starts(with: pngSignature)
        else {
            return nil
        }
        return pngData
    }

    private static let maximumIconPngBytes = 32 * 1024
    private static let pngSignature = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])

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
