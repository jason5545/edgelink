import CallKit
import Foundation
import UIKit

@main
final class CallUIHelperAppDelegate: UIResponder, UIApplicationDelegate {
    private let provider = SystemCallProvider()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        provider.start()
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        provider.invalidate()
    }
}

private final class SystemCallProvider: NSObject, CXProviderDelegate {
    private let center = DistributedNotificationCenter.default()
    private let provider: CXProvider
    private var observers: [NSObjectProtocol] = []
    private var callUUIDsByCallId: [String: UUID] = [:]
    private var callIdsByUUID: [UUID: String] = [:]

    override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.supportedHandleTypes = [.phoneNumber, .generic]
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.includesCallsInRecents = false
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    func start() {
        observers.append(
            center.addObserver(forName: Self.reportIncomingName, object: nil, queue: .main) { [weak self] notification in
                self?.handleReportIncoming(notification)
            }
        )
        observers.append(
            center.addObserver(forName: Self.endCallName, object: nil, queue: .main) { [weak self] notification in
                self?.handleEndCall(notification)
            }
        )
        observers.append(
            center.addObserver(forName: Self.endAllName, object: nil, queue: .main) { [weak self] notification in
                self?.handleEndAll(notification)
            }
        )
    }

    func invalidate() {
        for observer in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
        provider.invalidate()
    }

    func providerDidReset(_ provider: CXProvider) {
        for (callId, _) in callUUIDsByCallId {
            postAction(Self.endActionName, payload: [
                "callId": callId,
                "reason": "provider_reset"
            ])
        }
        callUUIDsByCallId.removeAll()
        callIdsByUUID.removeAll()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard let callId = callIdsByUUID[action.callUUID] else {
            action.fail()
            return
        }
        postAction(Self.answerActionName, payload: ["callId": callId])
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard let callId = callIdsByUUID[action.callUUID] else {
            action.fail()
            return
        }
        postAction(Self.endActionName, payload: [
            "callId": callId,
            "reason": "system_end"
        ])
        callUUIDsByCallId.removeValue(forKey: callId)
        callIdsByUUID.removeValue(forKey: action.callUUID)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        guard let callId = callIdsByUUID[action.callUUID] else {
            action.fail()
            return
        }
        postAction(Self.dtmfActionName, payload: [
            "callId": callId,
            "digits": action.digits
        ])
        action.fulfill()
    }

    private func handleReportIncoming(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let callId = userInfo["callId"] as? String,
              !callId.isEmpty else {
            return
        }

        let uuid: UUID
        let isExistingCall: Bool
        if let existingUUID = callUUIDsByCallId[callId] {
            uuid = existingUUID
            isExistingCall = true
        } else {
            uuid = UUID()
            callUUIDsByCallId[callId] = uuid
            callIdsByUUID[uuid] = callId
            isExistingCall = false
        }

        let update = callUpdate(userInfo: userInfo)
        if isExistingCall {
            provider.reportCall(with: uuid, updated: update)
            return
        }

        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            if let error {
                self?.callUUIDsByCallId.removeValue(forKey: callId)
                self?.callIdsByUUID.removeValue(forKey: uuid)
                self?.postAction(Self.reportFailedName, payload: [
                    "callId": callId,
                    "error": error.localizedDescription
                ])
            }
        }
    }

    private func handleEndCall(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let callId = userInfo["callId"] as? String,
              let uuid = callUUIDsByCallId[callId] else {
            return
        }
        let reason = EndReason(rawValue: userInfo["reason"] as? String ?? "") ?? .remoteEnded
        provider.reportCall(with: uuid, endedAt: Date(), reason: reason.callKitReason)
        callUUIDsByCallId.removeValue(forKey: callId)
        callIdsByUUID.removeValue(forKey: uuid)
    }

    private func handleEndAll(_ notification: Notification) {
        let reason = EndReason(rawValue: notification.userInfo?["reason"] as? String ?? "") ?? .remoteEnded
        let calls = Array(callUUIDsByCallId)
        for (_, uuid) in calls {
            provider.reportCall(with: uuid, endedAt: Date(), reason: reason.callKitReason)
        }
        callUUIDsByCallId.removeAll()
        callIdsByUUID.removeAll()
    }

    private func callUpdate(userInfo: [AnyHashable: Any]) -> CXCallUpdate {
        let handleValue = (userInfo["handle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (userInfo["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = displayName?.isEmpty == false ? displayName : handleValue
        let caller = fallback?.isEmpty == false ? fallback! : "未知號碼"

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(
            type: Self.isPhoneNumberLike(handleValue ?? caller) ? .phoneNumber : .generic,
            value: handleValue?.isEmpty == false ? handleValue! : caller
        )
        update.localizedCallerName = displayName?.isEmpty == false ? displayName : nil
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = true
        update.hasVideo = false
        return update
    }

    private func postAction(_ name: Notification.Name, payload: [String: Any]) {
        center.postNotificationName(
            name,
            object: Self.actionObject,
            userInfo: payload,
            deliverImmediately: true
        )
    }

    private static func isPhoneNumberLike(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        let accepted = CharacterSet(charactersIn: "+0123456789*#(),; -")
        return trimmed.unicodeScalars.allSatisfy { accepted.contains($0) }
    }

    private enum EndReason: String {
        case failed
        case remoteEnded
        case unanswered
        case answeredElsewhere
        case declinedElsewhere

        var callKitReason: CXCallEndedReason {
            switch self {
            case .failed:
                return .failed
            case .remoteEnded:
                return .remoteEnded
            case .unanswered:
                return .unanswered
            case .answeredElsewhere:
                return .answeredElsewhere
            case .declinedElsewhere:
                return .declinedElsewhere
            }
        }
    }

    private static let actionObject = "com.edgelink.callui"

    private static let reportIncomingName = Notification.Name("com.edgelink.callui.command.reportIncoming")
    private static let endCallName = Notification.Name("com.edgelink.callui.command.endCall")
    private static let endAllName = Notification.Name("com.edgelink.callui.command.endAll")

    private static let answerActionName = Notification.Name("com.edgelink.callui.action.answer")
    private static let endActionName = Notification.Name("com.edgelink.callui.action.end")
    private static let dtmfActionName = Notification.Name("com.edgelink.callui.action.dtmf")
    private static let reportFailedName = Notification.Name("com.edgelink.callui.action.reportFailed")
}
