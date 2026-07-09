import XCTest
@testable import EdgeLinkKit

final class VerificationCodeTests: XCTestCase {
    func testExtractsChineseVerificationCode() {
        let candidate = VerificationCodeExtractor.extract(
            from: "您的登入驗證碼為 123456，請勿提供給他人。",
            sourceAddress: "+886900000000",
            sourceMessageId: "sms-1",
            timestamp: 100
        )

        XCTAssertEqual(candidate?.code, "123456")
        XCTAssertEqual(candidate?.displayCode, "123 456")
        XCTAssertEqual(candidate?.sourceAddress, "+886900000000")
        XCTAssertEqual(candidate?.sourceMessageId, "sms-1")
    }

    func testExtractsChunghwaTelecomSmsCode() {
        let candidate = VerificationCodeExtractor.extract(
            from: "您的中華電信簡訊認證碼為 6585 。請勿代收簡訊以防詐騙。",
            sourceAddress: "123281",
            sourceMessageId: "sms-cht",
            timestamp: 100
        )

        XCTAssertEqual(candidate?.code, "6585")
        XCTAssertEqual(candidate?.displayCode, "6585")
        XCTAssertEqual(candidate?.sourceAddress, "123281")
    }

    func testExtractsGoogleNumericCodeFromGPrefix() {
        let candidate = VerificationCodeExtractor.extract(
            from: "您的 Google 驗證碼為 G-348378，請勿透露給任何人。",
            timestamp: 100
        )

        XCTAssertEqual(candidate?.code, "348378")
        XCTAssertEqual(candidate?.displayCode, "348 378")
    }

    func testExtractsEnglishReverseCode() {
        let candidate = VerificationCodeExtractor.extract(
            from: "493-201 is your Example security code.",
            timestamp: 100
        )

        XCTAssertEqual(candidate?.code, "493201")
        XCTAssertEqual(candidate?.displayCode, "493-201")
    }

    func testExtractsDomainBoundCode() {
        let candidate = VerificationCodeExtractor.extract(
            from: "123456 is your Example code.\n@example.com #123456",
            timestamp: 100
        )

        XCTAssertEqual(candidate?.code, "123456")
        XCTAssertEqual(candidate?.domain, "example.com")
        XCTAssertEqual(candidate?.machineReadableCode, "@example.com #123456")
    }

    func testExtractsAlphanumericCodeWithKeyword() {
        let candidate = VerificationCodeExtractor.extract(
            from: "Your one-time code is AB12CD.",
            timestamp: 100
        )

        XCTAssertEqual(candidate?.code, "AB12CD")
    }

    func testExtractsNumericPartFromTaiwanBank3DSecureChallenge() {
        let candidate = VerificationCodeExtractor.extract(
            from: "【玉山銀行】您本次網路交易金額為新臺幣 12,345 元，驗證碼 XNTC-299768，請勿告知他人。",
            timestamp: 100
        )

        XCTAssertEqual(candidate?.code, "299768")
        XCTAssertEqual(candidate?.displayCode, "299 768")
    }

    func testIgnoresPlainPhoneNumberWithoutContext() {
        let candidate = VerificationCodeExtractor.extract(
            from: "Missed call from 0912345678",
            timestamp: 100
        )

        XCTAssertNil(candidate)
    }

    func testIgnoresEightDigitDate() {
        let candidate = VerificationCodeExtractor.extract(
            from: "Your verification record date is 20260709.",
            timestamp: 100
        )

        XCTAssertNil(candidate)
    }
}
