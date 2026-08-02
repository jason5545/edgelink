import Foundation
import Security
import XCTest

final class KeychainSandboxTests: XCTestCase {
    func testPermanentRSAKeygenAndSign() {
        let label = "edgelink.test.rsa.\(UUID().uuidString)"
        let privateAttrs: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrLabel as String: "\(label).private"
        ]
        let publicAttrs: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrLabel as String: "\(label).public"
        ]
        let params: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: privateAttrs,
            kSecPublicKeyAttrs as String: publicAttrs
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(params as CFDictionary, &error) else {
            XCTFail("keygen failed: \(String(describing: error?.takeRetainedValue()))")
            return
        }
        var signError: Unmanaged<CFError>?
        let sig = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data("warmup".utf8) as CFData, &signError)
        XCTAssertNotNil(sig, "sign failed: \(String(describing: signError?.takeRetainedValue()))")
    }
}
