import CryptoKit
import EdgeLinkKit
import Foundation

// The phone-side acceptance oracle: our clean-room model of the decision
// logic the real phone runs in conn/DeviceManager + DeviceGroupManager +
// DeviceKeyManager, reconstructed from jadx + live errors (2026-08):
//
//   - only device-initiated type-1 sync pushes route through
//     HandleSyncDevMsg, which runs CheckSharedCred/CheckCertCred; type-2
//     replies never stamp the conn trusted type.
//   - DeviceKeyManager resolves the f13 device key for auth reuse; missing
//     key → "key is null" (quick-conn dial) / "client not have device key"
//     (full-handshake fallback).
//   - AddOnlineDevice rejects conns whose trusted_type is 0 → the device
//     never lands in the online repo → TeleService: "No relay service".
//
// The exact trusted_type constants are placeholders (configurable) — what is
// wire-confirmed is the gate shape: push-path + creds ⇒ non-zero trusted
// type ⇒ online. Everything the oracle decides is recorded with reasons so
// tests assert *why* the phone would reject us, not just that it would.
public final class LyraDevRepoOracle {
    public enum CredKind: String, Sendable {
        case sharedCred
        case certCred
        case groupCred
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

    // trusted_type values stamped per passed check (constants not yet
    // wire-confirmed; the gate is non-zero, magnitudes are placeholders).
    public var sharedCredTrustedType: UInt32 = 1
    public var certCredTrustedType: UInt32 = 2

    public init() {}

    // MARK: - Sync message handling

    // A device-initiated type-1 push (the only path that stamps trusted
    // type). Returns the updated record.
    @discardableResult
    public func handleSyncPush(
        device: LyraTrustedDevice, groupInfo: Data?, connHadFullHandshake: Bool
    ) -> DeviceRecord {
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

        if let credBlock = device.credBlock {
            let certResult = checkCertCred(credBlock)
            checks.append(certResult)
            if certResult.passed {
                trustedType |= certCredTrustedType
            } else {
                reasons.append("CheckCertCred failed: \(certResult.detail)")
            }
        }

        if let groupInfo {
            let groupResult = checkGroupCred(groupInfo)
            checks.append(groupResult)
            if groupResult.passed {
                trustedType |= sharedCredTrustedType
            } else {
                reasons.append("IsDeviceCredExist failed: \(groupResult.detail)")
            }
        }

        if device.credBlock == nil, groupInfo == nil {
            reasons.append("no creds in push (f15/groupInfo absent)")
        }

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

    // A type-2 reply: stored (device info lands in DevRepo) but NEVER stamps
    // trusted type — the phone's reply path skips the cred checks.
    @discardableResult
    public func handleSyncReply(device: LyraTrustedDevice) -> DeviceRecord {
        if let key = device.deviceKey, key.count == 32 {
            deviceKeys[device.fullDeviceIdHex] = key
        }
        let existing = records[device.fullDeviceIdHex]
        let record = DeviceRecord(
            device: mergedDevice(new: device, existing: existing?.device),
            trustedType: existing?.trustedType ?? 0,
            online: existing?.online ?? false,
            checks: existing?.checks ?? [],
            rejectionReasons: existing?.rejectionReasons
                ?? ["sync reply path: cred checks not run"]
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

    // f15 cert-cred block: {f1:9, f3: entry, f5: entry} where each entry is
    // {f1:3, f4:{f1: nonce32, f2: cert, f3: ECDSA-SHA256 sig(nonce)}}.
    public func checkCertCred(_ block: Data) -> CredCheck {
        checkCertCredBlock(block, kind: .certCred)
    }

    private func checkCertCredBlock(_ block: Data, kind: CredKind) -> CredCheck {
        var verified = 0
        var entries = 0
        for fieldNumber in [3, 5] {
            guard let entry = LyraTrustedDeviceParser.lengthDelimited(fieldNumber, in: block)
            else { continue }
            entries += 1
            guard let cred = LyraTrustedDeviceParser.lengthDelimited(4, in: entry),
                  let nonce = LyraTrustedDeviceParser.lengthDelimited(1, in: cred),
                  let cert = LyraTrustedDeviceParser.lengthDelimited(2, in: cred),
                  let sigDer = LyraTrustedDeviceParser.lengthDelimited(3, in: cred)
            else {
                return CredCheck(kind: kind, passed: false, detail: "entry \(fieldNumber) malformed")
            }
            guard let pubKeyData = trustedCerts[cert],
                  let pubKey = try? P256.Signing.PublicKey(x963Representation: pubKeyData),
                  let signature = try? P256.Signing.ECDSASignature(derRepresentation: sigDer),
                  pubKey.isValidSignature(signature, for: nonce)
            else {
                return CredCheck(
                    kind: kind, passed: false,
                    detail: "entry \(fieldNumber) cert untrusted or sig invalid"
                )
            }
            verified += 1
        }
        guard entries > 0 else {
            return CredCheck(kind: kind, passed: false, detail: "no entries")
        }
        return CredCheck(
            kind: kind, passed: verified == entries,
            detail: "\(verified)/\(entries) entries verified"
        )
    }

    // TrustedGroupInfoFrame {f1:1, f3: credCarrier}. Two observed carrier
    // shapes: a pubKeyCred CredFeature ({f3|f2: {f1: nonce, f2: sig}} —
    // shared-cred style) and the f15 cert-cred block (what the Mac's
    // groupInfoFrame currently sends).
    public func checkGroupCred(_ groupInfo: Data) -> CredCheck {
        guard let carrier = LyraTrustedDeviceParser.lengthDelimited(3, in: groupInfo)
        else {
            return CredCheck(kind: .groupCred, passed: false, detail: "shape mismatch")
        }
        if let pubKeyCred = LyraTrustedDeviceParser.lengthDelimited(3, in: carrier)
            ?? LyraTrustedDeviceParser.lengthDelimited(2, in: carrier),
           let nonce = LyraTrustedDeviceParser.lengthDelimited(1, in: pubKeyCred),
           let sigDer = LyraTrustedDeviceParser.lengthDelimited(2, in: pubKeyCred),
           let signature = try? P256.Signing.ECDSASignature(derRepresentation: sigDer)
        {
            for identityData in trustedPeerIdentities {
                guard let identity = try? P256.Signing.PublicKey(x963Representation: identityData)
                else { continue }
                if identity.isValidSignature(signature, for: SHA256.hash(data: nonce))
                    || identity.isValidSignature(signature, for: nonce)
                {
                    return CredCheck(kind: .groupCred, passed: true, detail: "pubKeyCred verified")
                }
            }
            return CredCheck(kind: .groupCred, passed: false, detail: "no trusted identity matched")
        }
        return checkCertCredBlock(carrier, kind: .groupCred)
    }
}
