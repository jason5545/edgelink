import Foundation
import LocalAuthentication

final class BiometricAuthManager: @unchecked Sendable {
    static let shared = BiometricAuthManager()

    enum BiometricAuthError: Error, Equatable {
        case unavailable(String)
        case alreadyAuthenticating
        case cancelled
        case failed(String)
    }

    private let lock = NSLock()
    private var context = LAContext()
    private var authenticating = false

    private(set) var lastErrorCode: Int?

    private init() {}

    var biometryType: LABiometryType {
        var error: NSError?
        let ctx = LAContext()
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .none
        }
        return ctx.biometryType
    }

    var isAuthenticating: Bool {
        lock.lock()
        defer { lock.unlock() }
        return authenticating
    }

    var canEvaluate: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    var biometricLabel: String {
        switch biometryType {
        case .touchID:
            return "Touch ID"
        case .faceID:
            return "Face ID"
        case .opticID:
            return "Optic ID"
        default:
            return "密碼"
        }
    }

    func evaluate(reason: String) async throws {
        lock.lock()
        if authenticating {
            lock.unlock()
            throw BiometricAuthError.alreadyAuthenticating
        }
        authenticating = true
        let ctx = context
        lock.unlock()
        defer {
            lock.lock()
            authenticating = false
            lock.unlock()
        }

        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            lastErrorCode = error?.code
            throw BiometricAuthError.unavailable(error?.localizedDescription ?? "Biometric authentication not available")
        }

        do {
            let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            if !ok {
                throw BiometricAuthError.failed("Authentication failed")
            }
        } catch let laError as LAError {
            lastErrorCode = laError.code.rawValue
            switch laError.code {
            case .userCancel, .systemCancel, .appCancel:
                throw BiometricAuthError.cancelled
            default:
                throw BiometricAuthError.failed(laError.localizedDescription)
            }
        }
    }

    func invalidate() {
        lock.lock()
        context.invalidate()
        context = LAContext()
        authenticating = false
        lock.unlock()
    }
}
