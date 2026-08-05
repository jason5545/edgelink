import CryptoKit
import EdgeLinkKit
import Foundation

// The phone-side acceptance oracle: our clean-room model of the decision
// logic the real phone runs in conn/DeviceManager + DeviceGroupManager +
// DeviceKeyManager, reconstructed from jadx + live errors + binary analysis
// (2026-08):
//
//   - BOTH the device-initiated type-1 push (HandleSyncDevMsg) and the
//     type-2 reply (HandleReplyDevMsg) run the cred checks — the group cred
//     carrier is tdi.f15 (TrustedGroupInfoFrame bitmask + per-slot
//     CredFeature), never sync.f3 (that oneof sibling makes the phone delete
//     the whole dev frame on parse).
//   - CheckCertCred compares the account uid only (cert CN lyra.<uid> vs the
//     local account uid); the shared slot failing ("537 not shared account")
//     is benign for same-account devices.
//   - DeviceKeyManager resolves the f13 device key for auth reuse; missing
//     key → "key is null" (quick-conn dial) / "client not have device key"
//     (full-handshake fallback).
//   - AddOnlineDevice rejects conns whose trusted_type is 0 → the device
//     never lands in the online repo → TeleService: "No relay service".
//
// Everything the oracle decides is recorded with reasons so tests assert
// *why* the phone would reject us, not just that it would.
public final class LyraDevRepoOracle {
    public enum CredKind: String, Sendable {
        case accountCertCred
        case sharedCertCred
        case pubKeyCred
    }

    public struct CredCheck: Sendable, Equatable {
        public var kind: CredKind
        public var passed: Bool
        public var detail: String
    }

    public struct DeviceRecord: Sendable {
        public var device: LyraTrustedDevice
        public var trustedType: UInt32
        public var online: Bool
        public var checks: [CredCheck]
        public var rejectionReasons: [String]
    }

    // Devices that completed registration, keyed by full device id.
    public private(set) var records: [String: DeviceRecord] = [:]
    // DeviceKeyManager: f13 keys seen in pushes, keyed by full device id.
    public private(set) var deviceKeys: [String: Data] = [:]
    // Registered peer identity pubkeys (paired devices) — the pubKeyCred
    // signature must verify against one of these.
    public var trustedPeerIdentities: [Data] = []
    // Registered cert trust anchors: cert DER → its P-256 public key, so the
    // f15 {nonce, cert, sig(nonce)} entries can be verified without X.509.
    public var trustedCerts: [Data: Data] = [:]

    // trusted_type stamped when the account cert cred verifies (the phone's
    // GetDeviceInfo prints trusted type 1 for same-account devices).
    public var accountCredTrustedType: UInt32 = 1

    public init() {}

    // MARK: - Sync message handling

    // Shared cred-check core for the push and reply paths — both run
    // CheckExchangeGroupInfo over tdi.f15 (TrustedGroupInfoFrame) on the
    // real phone. Returns (trustedType, checks, reasons).
    private func runCredChecks(
        device: LyraTrustedDevice, groupInfo: Data?
    ) -> (UInt32, [CredCheck], [String]) {
        var checks: [CredCheck] = []
        var reasons: [String] = []
        var trustedType: UInt32 = 0

        if let key = device.deviceKey {
            if key.count == 32 {
                deviceKeys[device.fullDeviceIdHex] = key
            } else {
                reasons.append("device key malformed (\(key.count) bytes)")
            }
        } else {
            reasons.append("client not have device key")
        }

        // tdi.f15 = TrustedGroupInfoFrame{f1 bitmask, f3 account cred,
        // f5 shared cred}. Each slot is a CredFeature{f1:3, f4:CertCredFrame
        // {nonce, cert, sig(nonce)}}; the account slot passing stamps
        // trusted_type 1. The shared slot failing is benign (the real phone
        // logs "537 not shared account" for same-account devices too), so it
        // is recorded as a check but never a rejection reason.
        if let groupInfo {
            let account = checkCertCredSlot(3, in: groupInfo, kind: .accountCertCred)
            checks.append(account)
            if account.passed {
                trustedType |= accountCredTrustedType
            } else {
                reasons.append("CheckCertCred failed: \(account.detail)")
            }
            let shared = checkCertCredSlot(5, in: groupInfo, kind: .sharedCertCred)
            if shared.detail != "slot absent" {
                checks.append(shared)
            }
        } else {
            reasons.append("no group cred (tdi.f15 absent)")
        }
        return (trustedType, checks, reasons)
    }

    // A device-initiated type-1 push. Returns the updated record.
    @discardableResult
    public func handleSyncPush(
        device: LyraTrustedDevice, groupInfo: Data?, connHadFullHandshake: Bool
    ) -> DeviceRecord {
        var (trustedType, checks, reasons) = runCredChecks(device: device, groupInfo: groupInfo)
        let online = trustedType != 0 && deviceKeys[device.fullDeviceIdHex] != nil
        if !online {
            if trustedType == 0 {
                reasons.append("AddOnlineDevice err trusted_type 0")
            }
            if deviceKeys[device.fullDeviceIdHex] == nil {
                reasons.append("DeviceKeyManager: key is null")
            }
        }
        let merged = mergedDevice(new: device, existing: records[device.fullDeviceIdHex]?.device)
        let record = DeviceRecord(
            device: merged,
            trustedType: trustedType,
            online: online,
            checks: checks,
            rejectionReasons: reasons
        )
        records[device.fullDeviceIdHex] = record
        return record
    }

    // A mesh announce (type-1 frame on the announce conn): the device info
    // parses into DevRepo and AddOnlineDevice runs, but the conn's trusted
    // type is whatever a prior sync push stamped — the announce path itself
    // never runs cred checks, so a fresh device gets "err trusted_type 0".
    @discardableResult
    public func handleAnnounce(device: LyraTrustedDevice) -> DeviceRecord {
        if let key = device.deviceKey, key.count == 32 {
            deviceKeys[device.fullDeviceIdHex] = key
        }
        let existing = records[device.fullDeviceIdHex]
        let merged = mergedDevice(new: device, existing: existing?.device)
        let trustedType = existing?.trustedType ?? 0
        var reasons: [String] = []
        if device.deviceKey == nil {
            reasons.append("client not have device key")
        }
        let online = trustedType != 0 && deviceKeys[device.fullDeviceIdHex] != nil
        if trustedType == 0 {
            reasons.append("AddOnlineDevice err trusted_type 0")
        }
        let record = DeviceRecord(
            device: merged,
            trustedType: trustedType,
            online: online,
            checks: existing?.checks ?? [],
            rejectionReasons: reasons
        )
        records[device.fullDeviceIdHex] = record
        return record
    }

    // DevRepo entries accumulate: a later frame that omits fields (services,
    // keys) does not wipe what earlier frames established.
    private func mergedDevice(new: LyraTrustedDevice, existing: LyraTrustedDevice?) -> LyraTrustedDevice {
        guard let existing else { return new }
        var merged = new
        var seen = Set(merged.services.map(\.name))
        for service in existing.services where !seen.contains(service.name) {
            merged.services.append(service)
            seen.insert(service.name)
        }
        if merged.deviceKey == nil {
            merged.deviceKey = existing.deviceKey
        }
        if merged.credBlock == nil {
            merged.credBlock = existing.credBlock
        }
        return merged
    }

    // A type-2 reply: HandleReplyDevMsg runs the SAME cred checks on tdi.f15
    // and stamps trusted type (0731 ground truth: the real Mac registered
    // online with trusted_type 1 through the reply path alone).
    @discardableResult
    public func handleSyncReply(device: LyraTrustedDevice, groupInfo: Data? = nil) -> DeviceRecord {
        let existing = records[device.fullDeviceIdHex]
        let group = groupInfo ?? existing?.device.credBlock
        var (trustedType, checks, reasons) = runCredChecks(
            device: device, groupInfo: group
        )
        if trustedType == 0 {
            trustedType = existing?.trustedType ?? 0
            checks = existing?.checks ?? checks
        }
        let online = trustedType != 0 && deviceKeys[device.fullDeviceIdHex] != nil
        let record = DeviceRecord(
            device: mergedDevice(new: device, existing: existing?.device),
            trustedType: trustedType,
            online: online,
            checks: checks,
            rejectionReasons: online ? [] : reasons
        )
        records[device.fullDeviceIdHex] = record
        return record
    }

    // MARK: - DeviceKeyManager

    // Resolves the auth-reuse key for a dial from the given device, mirroring
    // the phone's DeviceKeyManager. nil ⇒ the phone logs "key is null" and
    // the quick-conn dial dies.
    public func resolveDeviceKey(for fullDeviceIdHex: String) -> SymmetricKey? {
        guard let key = deviceKeys[fullDeviceIdHex], key.count == 32 else { return nil }
        return SymmetricKey(data: key)
    }

    // MARK: - Online repo (what TeleService queries)

    public func onlineDevices() -> [DeviceRecord] {
        records.values.filter(\.online)
    }

    // TeleService's gate before dialing relayCall: an online device that
    // advertises the relayCall service. nil ⇒ "No relay service".
    public func relayServiceDevice() -> DeviceRecord? {
        onlineDevices().first { $0.device.hasService("relayCall") }
    }

    // MARK: - Cred checks

    // One slot of the TrustedGroupInfoFrame: CredFeature{f1:3, f4:
    // CertCredFrame{f1: nonce32, f2: cert, f3: ECDSA-SHA256 sig(nonce)}}.
    // The cert must be a registered trust anchor and the sig must verify
    // under the cert's own key — mirroring CheckCertCred (uid comparison is
    // implicit: tests register certs for the account they stand for).
    public func checkCertCredSlot(
        _ slot: Int, in groupInfo: Data, kind: CredKind
    ) -> CredCheck {
        guard let entry = LyraTrustedDeviceParser.lengthDelimited(slot, in: groupInfo)
        else {
            return CredCheck(kind: kind, passed: false, detail: "slot absent")
        }
        guard let cred = LyraTrustedDeviceParser.lengthDelimited(4, in: entry),
              let nonce = LyraTrustedDeviceParser.lengthDelimited(1, in: cred),
              let cert = LyraTrustedDeviceParser.lengthDelimited(2, in: cred),
              let sigDer = LyraTrustedDeviceParser.lengthDelimited(3, in: cred)
        else {
            return CredCheck(kind: kind, passed: false, detail: "slot \(slot) malformed")
        }
        guard let pubKeyData = trustedCerts[cert],
              let pubKey = try? P256.Signing.PublicKey(x963Representation: pubKeyData),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: sigDer),
              pubKey.isValidSignature(signature, for: nonce)
        else {
            return CredCheck(
                kind: kind, passed: false,
                detail: "slot \(slot) cert untrusted or sig invalid"
            )
        }
        return CredCheck(kind: kind, passed: true, detail: "slot \(slot) verified")
    }

    // Whole-block check (all present slots must verify) — kept for tests that
    // assert on the full TGI block.
    public func checkCertCred(_ block: Data) -> CredCheck {
        let account = checkCertCredSlot(3, in: block, kind: .accountCertCred)
        let shared = checkCertCredSlot(5, in: block, kind: .sharedCertCred)
        let present = [account, shared].filter { $0.detail != "slot absent" }
        guard !present.isEmpty else {
            return CredCheck(kind: .accountCertCred, passed: false, detail: "no entries")
        }
        let failed = present.first { !$0.passed }
        return CredCheck(
            kind: .accountCertCred,
            passed: failed == nil,
            detail: failed?.detail ?? "\(present.count) slot(s) verified"
        )
    }
}
