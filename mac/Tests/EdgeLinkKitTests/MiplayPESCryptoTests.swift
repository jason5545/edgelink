import EdgeLinkKit
import Foundation
import XCTest

final class MiplayPESCryptoTests: XCTestCase {
    private static func data(_ hex: String) -> Data {
        var out = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    func testAES128BlockKnownAnswer() {
        let key = Self.data("000102030405060708090a0b0c0d0e0f")
        let plaintext = Self.data("00112233445566778899aabbccddeeff")
        let ciphertext = Self.data("69c4e0d86a7b0430d8cdb78070b4c55a")
        let aes = AES128(key: key)
        XCTAssertNotNil(aes)
        XCTAssertEqual(Data(aes!.encryptBlock([UInt8](plaintext))), ciphertext)
        XCTAssertEqual(Data(aes!.decryptBlock([UInt8](ciphertext))), plaintext)
    }

    func testCBCRoundTripWithTail() {
        let iv = Self.data("3eb2a9c42e329a0d48d134b2eaac12a1")
        var plaintext = Data((0..<64).map { UInt8($0 ^ 0xA5) })
        plaintext.append(contentsOf: [1, 2, 3, 4, 5, 6, 7])
        let encrypted = MiplayPESCrypto.encrypt(plaintext, iv: iv)
        XCTAssertNotEqual(encrypted, plaintext)
        XCTAssertEqual(encrypted.suffix(7), plaintext.suffix(7))
        XCTAssertEqual(MiplayPESCrypto.decrypt(encrypted, iv: iv), plaintext)
    }

    func testDecryptsOfficialCapturePES() {
        let iv = Self.data("3eb2a9c42e329a0d48d134b2eaac12a1")
        let ciphertext = Self.data(
            "b10a3cda0284410aa1e4a7f17bf642d536ace4994404097ae8d95c8089dde2bf" +
            "c19cf12123464ae7cf9383124601a9a2012484645a4773e59ffd29fa370e7029"
        )
        let expectedPlaintext = Self.data(
            "0000000140010c01ffff016000000300b00000030000030096ac0900000001" +
            "420101016000000300b00000030000030096a00260800a41c4c4e5aee4c92ea6a0"
        )
        XCTAssertEqual(MiplayPESCrypto.decrypt(ciphertext, iv: iv), expectedPlaintext)
    }

    func testExtractIVFromOfficialPESHeader() {
        let pes = Self.data(
            "000001e0000084811621000100018e3eb2a9c42e329a0d48d134b2eaac12a1" +
            "b10a3cda0284410aa1e4a7f17bf642d5"
        )
        let iv = MiplayPESCrypto.extractPrivateDataIV(fromPES: pes)
        XCTAssertEqual(iv, Self.data("3eb2a9c42e329a0d48d134b2eaac12a1"))
    }

    func testExtractIVRejectsHeaderWithoutPrivateData() {
        let pes = Self.data("000001e000088480052100010001000000014001")
        XCTAssertNil(MiplayPESCrypto.extractPrivateDataIV(fromPES: pes))
        XCTAssertNil(MiplayPESCrypto.extractPrivateDataIV(fromPES: Data([1, 2, 3])))
    }

    func testKeyAnnouncementDetection() {
        let announcement = Self.data("8648ce3d03010703420004") + Data(repeating: 0x11, count: 64)
        XCTAssertTrue(MiplayPESCrypto.isKeyAnnouncementPayload(announcement))
        let hevc = Self.data("0000000140010c01ffff0160")
        XCTAssertFalse(MiplayPESCrypto.isKeyAnnouncementPayload(hevc))
        XCTAssertFalse(MiplayPESCrypto.isKeyAnnouncementPayload(Data()))
    }
}
