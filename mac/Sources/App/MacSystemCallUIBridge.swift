import AppKit
import EdgeLinkKit
import Foundation

@MainActor
final class MacSystemCallUIBridge {
    var onAnswerPhoneCall: (@MainActor @Sendable (String) -> Void)?
    var onHangUpPhoneCall: (@MainActor @Sendable (String) -> Void)?
    var onPlayDTMF: (@MainActor @Sendable (String, String) -> Void)?

    private let center = DistributedNotificationCenter.default()
    private var observers: [NSObjectProtocol] = []
    private var systemAnsweredCallIds = Set<String>()

    init() {
        observers.append(
            center.addObserver(forName: Self.answerName, object: nil, queue: .main) { [weak self] notification in
                guard let callId = notification.userInfo?["callId"] as? String, !callId.isEmpty else {
                    return
                }
                Task { @MainActor in
                    self?.systemAnsweredCallIds.insert(callId)
                    self?.onAnswerPhoneCall?(callId)
                }
            }
        )
        observers.append(
            center.addObserver(forName: Self.endName, object: nil, queue: .main) { [weak self] notification in
                guard let callId = notification.userInfo?["callId"] as? String, !callId.isEmpty else {
                    return
                }
                Task { @MainActor in
                    self?.systemAnsweredCallIds.remove(callId)
                    self?.onHangUpPhoneCall?(callId)
                }
            }
        )
        observers.append(
            center.addObserver(forName: Self.dtmfName, object: nil, queue: .main) { [weak self] notification in
                guard let callId = notification.userInfo?["callId"] as? String, !callId.isEmpty,
                      let digits = notification.userInfo?["digits"] as? String, !digits.isEmpty else {
                    return
                }
                Task { @MainActor in
                    self?.onPlayDTMF?(callId, digits)
                }
            }
        )
        observers.append(
            center.addObserver(forName: Self.reportFailedName, object: nil, queue: .main) { notification in
                let callId = notification.userInfo?["callId"] as? String ?? "unknown"
                let error = notification.userInfo?["error"] as? String ?? "unknown"
                DiagnosticsLog.warn("phone.mac.system_callui_report_failed callId=\(callId) error=\(error)")
            }
        )
    }

    deinit {
        for observer in observers {
            center.removeObserver(observer)
        }
    }

    static func startInstalledHelper(reason: String) {
        _ = launchHelperIfNeeded(reason: reason)
    }

    static func stopInstalledHelper(reason: String) {
        let runningHelpers = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == Self.helperBundleIdentifier
        }
        guard !runningHelpers.isEmpty else {
            DiagnosticsLog.info("phone.mac.system_callui_helper_stop_ignored reason=\(reason) not_running")
            return
        }
        DistributedNotificationCenter.default().postNotificationName(
            Self.endAllName,
            object: Self.commandObject,
            userInfo: ["reason": EndReason.remoteEnded.rawValue],
            deliverImmediately: true
        )
        for helper in runningHelpers {
            if helper.terminate() {
                DiagnosticsLog.info("phone.mac.system_callui_helper_terminate reason=\(reason) pid=\(helper.processIdentifier)")
            } else if helper.forceTerminate() {
                DiagnosticsLog.warn("phone.mac.system_callui_helper_force_terminate reason=\(reason) pid=\(helper.processIdentifier)")
            } else {
                DiagnosticsLog.warn("phone.mac.system_callui_helper_terminate_failed reason=\(reason) pid=\(helper.processIdentifier)")
            }
        }
        let deadline = Date().addingTimeInterval(Self.helperTerminationGraceSeconds)
        while Date() < deadline && runningHelpers.contains(where: { !$0.isTerminated }) {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        for helper in runningHelpers where !helper.isTerminated {
            if helper.forceTerminate() {
                DiagnosticsLog.warn("phone.mac.system_callui_helper_force_terminate_after_grace reason=\(reason) pid=\(helper.processIdentifier)")
            } else {
                DiagnosticsLog.warn("phone.mac.system_callui_helper_force_terminate_failed reason=\(reason) pid=\(helper.processIdentifier)")
            }
        }
    }

    func reportIncomingCall(_ status: PhoneCallStatusBody) {
        let payload = callPayload(status)
        postHelperCommand(Self.reportIncomingName, payload: payload)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            postHelperCommand(Self.reportIncomingName, payload: payload)
        }
        DiagnosticsLog.info("phone.mac.system_callui_report_incoming callId=\(status.callId)")
    }

    func endCall(_ status: PhoneCallStatusBody, reason: EndReason) {
        endCall(callId: status.callId, reason: reason)
    }

    func endCall(callId: String, reason: EndReason) {
        guard !callId.isEmpty else {
            return
        }
        systemAnsweredCallIds.remove(callId)
        postHelperCommand(Self.endCallName, payload: [
            "callId": callId,
            "reason": reason.rawValue
        ])
        DiagnosticsLog.info("phone.mac.system_callui_end callId=\(callId) reason=\(reason.rawValue)")
    }

    func endAll(reason: EndReason) {
        systemAnsweredCallIds.removeAll()
        postHelperCommand(Self.endAllName, payload: [
            "reason": reason.rawValue
        ])
        DiagnosticsLog.info("phone.mac.system_callui_end_all reason=\(reason.rawValue)")
    }

    func wasAnsweredBySystemUI(callId: String) -> Bool {
        systemAnsweredCallIds.contains(callId)
    }

    private func postHelperCommand(_ name: Notification.Name, payload: [String: Any]) {
        _ = Self.launchHelperIfNeeded(reason: "command_\(name.rawValue)")
        center.postNotificationName(
            name,
            object: Self.commandObject,
            userInfo: payload,
            deliverImmediately: true
        )
    }

    @discardableResult
    private static func launchHelperIfNeeded(reason: String) -> Bool {
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == Self.helperBundleIdentifier }) {
            DiagnosticsLog.info("phone.mac.system_callui_helper_running reason=\(reason)")
            return true
        }
        let helperURL = URL(fileURLWithPath: Self.installedHelperPath)
        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            DiagnosticsLog.warn("phone.mac.system_callui_helper_missing path=\(helperURL.path)")
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: helperURL, configuration: configuration) { _, error in
            if let error {
                DiagnosticsLog.error("phone.mac.system_callui_helper_launch_failed", error)
            } else {
                DiagnosticsLog.info("phone.mac.system_callui_helper_launched reason=\(reason)")
            }
        }
        return true
    }

    private func callPayload(_ status: PhoneCallStatusBody) -> [String: Any] {
        var payload: [String: Any] = [
            "callId": status.callId,
            "state": status.state,
            "canAnswer": status.canAnswer,
            "canHangUp": status.canHangUp,
            "isActive": status.isActive,
            "reason": status.reason,
            "ts": status.ts
        ]
        if let handle = status.handle?.trimmingCharacters(in: .whitespacesAndNewlines), !handle.isEmpty {
            payload["handle"] = handle
        }
        if let displayName = status.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !displayName.isEmpty {
            payload["displayName"] = displayName
        }
        if let direction = status.direction?.trimmingCharacters(in: .whitespacesAndNewlines), !direction.isEmpty {
            payload["direction"] = direction
        }
        return payload
    }

    enum EndReason: String {
        case failed
        case remoteEnded
        case unanswered
        case answeredElsewhere
        case declinedElsewhere
    }

    private static let helperBundleIdentifier = "com.edgelink.callui"
    private static let installedHelperPath = "/Applications/EdgeLinkCallUI.app"
    private static let commandObject = "com.edgelink.mac"
    private static let helperTerminationGraceSeconds: TimeInterval = 0.8

    private static let reportIncomingName = Notification.Name("com.edgelink.callui.command.reportIncoming")
    private static let endCallName = Notification.Name("com.edgelink.callui.command.endCall")
    private static let endAllName = Notification.Name("com.edgelink.callui.command.endAll")

    private static let answerName = Notification.Name("com.edgelink.callui.action.answer")
    private static let endName = Notification.Name("com.edgelink.callui.action.end")
    private static let dtmfName = Notification.Name("com.edgelink.callui.action.dtmf")
    private static let reportFailedName = Notification.Name("com.edgelink.callui.action.reportFailed")
}
