import EdgeLinkKit
import Foundation

final class MacVerificationCodeBridge {
    func warmObservers() {
        let result = ELWarmPrivateOneTimeCodeObservers()
        DiagnosticsLog.info("verification.mac.private_warm result=\(Self.compactDescription(result))")
    }

    func deliver(_ candidate: VerificationCodeCandidate) {
        let result = ELDeliverVerificationCodeToPrivateAutoFill(payload(for: candidate))
        DiagnosticsLog.info("verification.mac.private_deliver id=\(candidate.id) result=\(Self.compactDescription(result))")
    }

    private func payload(for candidate: VerificationCodeCandidate) -> [String: Any] {
        var payload: [String: Any] = [
            "code": candidate.code,
            "displayCode": candidate.displayCode,
            "guid": candidate.sourceMessageId ?? candidate.id,
            "handle": candidate.sourceAddress ?? "EdgeLink",
            "timestamp": NSNumber(value: candidate.receivedAt)
        ]
        if let machineReadableCode = candidate.machineReadableCode {
            payload["machineReadableCode"] = machineReadableCode
        }
        if let domain = candidate.domain {
            payload["domain"] = domain
        }
        if let embeddedDomain = candidate.embeddedDomain {
            payload["embeddedDomain"] = embeddedDomain
        }
        return payload
    }

    private static func compactDescription(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else {
            return String(describing: value)
        }
        return string
    }
}
