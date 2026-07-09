import Foundation

public struct VerificationCodeCandidate: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let code: String
    public let displayCode: String
    public let machineReadableCode: String?
    public let domain: String?
    public let embeddedDomain: String?
    public let sourceAddress: String?
    public let sourceMessageId: String?
    public let receivedAt: Int64

    public init(
        id: String,
        code: String,
        displayCode: String,
        machineReadableCode: String?,
        domain: String?,
        embeddedDomain: String?,
        sourceAddress: String?,
        sourceMessageId: String?,
        receivedAt: Int64
    ) {
        self.id = id
        self.code = code
        self.displayCode = displayCode
        self.machineReadableCode = machineReadableCode
        self.domain = domain
        self.embeddedDomain = embeddedDomain
        self.sourceAddress = sourceAddress
        self.sourceMessageId = sourceMessageId
        self.receivedAt = receivedAt
    }
}

public enum VerificationCodeExtractor {
    public static func extract(
        from text: String,
        sourceAddress: String? = nil,
        sourceMessageId: String? = nil,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970)
    ) -> VerificationCodeCandidate? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let machineReadable = extractMachineReadableCode(from: trimmed) {
            return makeCandidate(
                code: machineReadable.code,
                displayCode: machineReadable.displayCode,
                machineReadableCode: machineReadable.machineReadableCode,
                domain: machineReadable.domain,
                embeddedDomain: nil,
                sourceAddress: sourceAddress,
                sourceMessageId: sourceMessageId,
                timestamp: timestamp
            )
        }

        if let contextual = extractContextualCode(from: trimmed) {
            return makeCandidate(
                code: contextual.code,
                displayCode: contextual.displayCode,
                machineReadableCode: nil,
                domain: nil,
                embeddedDomain: nil,
                sourceAddress: sourceAddress,
                sourceMessageId: sourceMessageId,
                timestamp: timestamp
            )
        }

        return nil
    }

    private static func makeCandidate(
        code: String,
        displayCode: String,
        machineReadableCode: String?,
        domain: String?,
        embeddedDomain: String?,
        sourceAddress: String?,
        sourceMessageId: String?,
        timestamp: Int64
    ) -> VerificationCodeCandidate {
        let seed = [
            sourceMessageId ?? "",
            sourceAddress ?? "",
            code,
            String(timestamp)
        ].joined(separator: ":")
        return VerificationCodeCandidate(
            id: stableIdentifier(seed),
            code: code,
            displayCode: displayCode,
            machineReadableCode: machineReadableCode,
            domain: domain,
            embeddedDomain: embeddedDomain,
            sourceAddress: sourceAddress,
            sourceMessageId: sourceMessageId,
            receivedAt: timestamp
        )
    }

    private static func extractMachineReadableCode(from text: String) -> MachineReadableMatch? {
        let codePattern = #"([0-9](?:[0-9 -]{2,14}[0-9])|[A-Z0-9]{5,10})"#
        let pattern = #"(?im)(?:^|\s)@([A-Z0-9.-]+\.[A-Z]{2,})\s+#"# + codePattern + #"(?:\s|$)"#
        for match in matches(pattern: pattern, text: text) {
            guard
                match.numberOfRanges >= 3,
                let domainRange = Range(match.range(at: 1), in: text),
                let codeRange = Range(match.range(at: 2), in: text)
            else {
                continue
            }

            let rawCode = String(text[codeRange])
            guard let normalized = normalizeCode(rawCode) else {
                continue
            }
            let domain = String(text[domainRange]).lowercased()
            let lineRange = lineRange(containing: match.range(at: 1), in: text)
            let machineReadableCode = String(text[lineRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            return MachineReadableMatch(
                code: normalized,
                displayCode: displayCode(for: normalized, original: rawCode),
                machineReadableCode: machineReadableCode,
                domain: domain
            )
        }
        return nil
    }

    private static func extractContextualCode(from text: String) -> CodeMatch? {
        let codePattern = #"([0-9](?:[0-9 -]{2,14}[0-9])|[A-Z0-9]{5,10})"#
        let forward = #"(?i)(?:驗證碼|認證碼|動態密碼|簡訊碼|登入碼|安全碼|一次性密碼|校驗碼|verification(?:\s+code)?|security\s+code|one[-\s]?time(?:\s+code)?|passcode|otp|2fa|code|認証コード|確認コード|인증번호)[^\n\r]{0,36}?"# + codePattern
        if let match = firstValidCodeMatch(pattern: forward, text: text, codeGroup: 1, requireStrongContextForShortCode: false) {
            return match
        }

        let reverse = #"(?i)"# + codePattern + #"[^\n\r]{0,28}?(?:is\s+your|為您(?:的)?|是您(?:的)?|是你的|驗證碼|認證碼|動態密碼|verification(?:\s+code)?|security\s+code|one[-\s]?time(?:\s+code)?|passcode|otp|2fa|code)"#
        if let match = firstValidCodeMatch(pattern: reverse, text: text, codeGroup: 1, requireStrongContextForShortCode: false) {
            return match
        }

        guard containsVerificationKeyword(text) else {
            return nil
        }
        let anyCode = #"(?i)(?<![A-Z0-9])"# + codePattern + #"(?![A-Z0-9])"#
        return firstValidCodeMatch(pattern: anyCode, text: text, codeGroup: 1, requireStrongContextForShortCode: true)
    }

    private static func firstValidCodeMatch(
        pattern: String,
        text: String,
        codeGroup: Int,
        requireStrongContextForShortCode: Bool
    ) -> CodeMatch? {
        for match in matches(pattern: pattern, text: text) {
            guard
                match.numberOfRanges > codeGroup,
                let codeRange = Range(match.range(at: codeGroup), in: text)
            else {
                continue
            }

            let rawCode = String(text[codeRange])
            guard let normalized = normalizeCode(rawCode) else {
                continue
            }
            if requireStrongContextForShortCode && normalized.count <= 4 && !nearStrongKeyword(range: match.range, text: text) {
                continue
            }
            if looksLikeDateOrAmount(normalized, raw: rawCode) {
                continue
            }
            return CodeMatch(code: normalized, displayCode: displayCode(for: normalized, original: rawCode))
        }
        return nil
    }

    private static func normalizeCode(_ raw: String) -> String? {
        let normalized = raw
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .uppercased()
            .filter { $0.isASCII && ($0.isNumber || $0.isLetter) }
        guard !normalized.isEmpty else { return nil }

        let hasDigit = normalized.contains { $0.isNumber }
        let hasLetter = normalized.contains { $0.isLetter }
        if normalized.allSatisfy(\.isNumber) {
            return (4...8).contains(normalized.count) ? normalized : nil
        }
        if hasDigit && hasLetter && (5...10).contains(normalized.count) {
            return normalized
        }
        return nil
    }

    private static func displayCode(for normalized: String, original: String) -> String {
        let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizeCode(trimmed) == normalized, trimmed.contains(where: { $0 == " " || $0 == "-" }) {
            return trimmed.uppercased()
        }
        if normalized.count == 6, normalized.allSatisfy(\.isNumber) {
            let split = normalized.index(normalized.startIndex, offsetBy: 3)
            return "\(normalized[..<split]) \(normalized[split...])"
        }
        return normalized
    }

    private static func containsVerificationKeyword(_ text: String) -> Bool {
        let pattern = #"(?i)驗證碼|認證碼|動態密碼|簡訊碼|登入碼|安全碼|一次性密碼|校驗碼|verification|security\s+code|one[-\s]?time|passcode|otp|2fa|認証コード|確認コード|인증번호"#
        return matches(pattern: pattern, text: text).isEmpty == false
    }

    private static func nearStrongKeyword(range: NSRange, text: String) -> Bool {
        let nsText = text as NSString
        let lower = max(0, range.location - 24)
        let upper = min(nsText.length, range.location + range.length + 24)
        let nearby = nsText.substring(with: NSRange(location: lower, length: upper - lower))
        return containsVerificationKeyword(nearby)
    }

    private static func looksLikeDateOrAmount(_ normalized: String, raw: String) -> Bool {
        if normalized.count == 8, normalized.hasPrefix("19") || normalized.hasPrefix("20") {
            return true
        }
        if raw.contains(".") || raw.contains("/") {
            return true
        }
        return false
    }

    private static func lineRange(containing range: NSRange, in text: String) -> Range<String.Index> {
        let start = Range(range, in: text)?.lowerBound ?? text.startIndex
        return text.lineRange(for: start..<start)
    }

    private static func matches(pattern: String, text: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func stableIdentifier(_ seed: String) -> String {
        let value = seed.unicodeScalars.reduce(UInt64(14_695_981_039_346_656_037)) { partial, scalar in
            (partial ^ UInt64(scalar.value)) &* 1_099_511_628_211
        }
        return "otp:\(String(value, radix: 16))"
    }
}

private struct MachineReadableMatch {
    let code: String
    let displayCode: String
    let machineReadableCode: String
    let domain: String
}

private struct CodeMatch {
    let code: String
    let displayCode: String
}
