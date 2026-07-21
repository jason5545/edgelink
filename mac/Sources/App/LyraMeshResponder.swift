import CryptoKit
import EdgeLinkKit
import Foundation
import Network

final class LyraMeshResponder {
    private static let officialMacUidFeature = Data([
        0x0A, 0x08, 0x26, 0xFB, 0x1C, 0x8E, 0xAC, 0x7C, 0xFC, 0x1F, 0x12, 0x20,
        0x57, 0x65, 0xD7, 0xBF, 0xBD, 0xC3, 0xCA, 0x3C, 0x8B, 0x99, 0xF2, 0xA5,
        0x96, 0x08, 0xD3, 0x95, 0x8E, 0x2B, 0xC3, 0xEC, 0x1F, 0x64, 0x81, 0xEB,
        0x11, 0xB6, 0x56, 0x13, 0x08, 0x27, 0x21, 0xBF
    ])
    private static let officialMacSyncInfoSignature = Data([
        0x33, 0x85, 0xFB, 0xAA, 0x02, 0xFD, 0x4E, 0x2C, 0xE1, 0x95, 0x74, 0x3A,
        0xA8, 0xDD, 0x50, 0xDB, 0xC6, 0xB7, 0xA4, 0xEC, 0x36, 0x6F, 0x0B, 0xAA,
        0x98, 0xA7, 0x6C, 0xDA, 0x11, 0x7F, 0x94, 0x25, 0x9B, 0xD8, 0x32, 0xCE,
        0xB6, 0x73, 0x80, 0xB1, 0x3D, 0xFF, 0x13, 0x9A, 0xBE, 0x94, 0x55, 0x22,
        0x44, 0x88, 0xD4, 0x12, 0x70, 0x94, 0x1A, 0xB3, 0x3F, 0x9D, 0xCF, 0x5C,
        0x6D, 0xBA, 0xEF, 0x7A, 0x30, 0xB8, 0x8F, 0x28, 0x26, 0x16, 0x0E, 0xB4,
        0x61, 0xFA, 0x06, 0xB3, 0xB2, 0xB9, 0x4A, 0xB9, 0x6F, 0x8C, 0x7E, 0x9F,
        0x6A, 0x98, 0x05, 0x17, 0xF2, 0xA6, 0xE3, 0x3C, 0x8F, 0xE3, 0xE4, 0xC8,
        0xE2, 0x92, 0xF7, 0xB0, 0x02, 0x5D, 0x4A, 0x89, 0x37, 0xC3, 0x63, 0x9A,
        0xB9, 0xA6, 0xB1, 0x42, 0x7C, 0xC1, 0xFC, 0x65, 0xD3, 0xB2, 0x9C, 0x2F,
        0x3D, 0x5A, 0x76, 0xF6, 0xBC, 0xF0, 0x90, 0x20, 0x59, 0x1E, 0x47, 0xC5,
        0xDF, 0x82, 0xED, 0xC3, 0x9C, 0x9A, 0xBE, 0x30, 0xA1, 0x71, 0x60, 0x64
    ])

    private let socket: LyraMeshSocket
    private let deviceIdHexProvider: () -> String?
    private let displayNameProvider: () -> String
    private var keyAgreementKey: P256.KeyAgreement.PrivateKey?

    init(
        socket: LyraMeshSocket,
        deviceIdHexProvider: @escaping () -> String?,
        displayNameProvider: @escaping () -> String
    ) {
        self.socket = socket
        self.deviceIdHexProvider = deviceIdHexProvider
        self.displayNameProvider = displayNameProvider
    }

    func attach() {
        socket.onFrame = { [weak self] frame, endpoint, reply in
            self?.handle(frame: frame, endpoint: endpoint, reply: reply)
        }
    }

    private func handle(frame: LyraMeshPack.Frame, endpoint: NWEndpoint, reply: LyraMeshSocket.ReplyHandler) {
        guard let miFrame = MiConnectFrame(parsing: frame.payload) else {
            return
        }
        if let physConn = miFrame.physConnFrame,
           case let .syncDeviceInfoRequest(requestData) = physConn.payload,
           let request = PhysConnSyncDeviceInfoRequest(parsing: requestData) {
            handleSyncRequest(frame: frame, physConn: physConn, request: request, endpoint: endpoint, reply: reply)
            return
        }
        for logiConn in miFrame.logiConnFrames {
            handleLogiConn(frame: frame, logiConn: logiConn, endpoint: endpoint, reply: reply)
        }
    }

    private func handleLogiConn(
        frame: LyraMeshPack.Frame,
        logiConn: LogiConnFrame,
        endpoint: NWEndpoint,
        reply: LyraMeshSocket.ReplyHandler
    ) {
        guard let inner = LogiConnInnerFrame(parsing: logiConn.inner) else {
            return
        }
        switch inner.payload {
        case let .syncInfo(syncInfoData):
            handleLogiSyncInfo(
                syncInfoData: syncInfoData, frame: frame, logiConn: logiConn,
                endpoint: endpoint, reply: reply
            )
        case let .upgrade(upgradeData):
            handleLogiUpgrade(
                upgradeData: upgradeData, frame: frame, logiConn: logiConn,
                endpoint: endpoint, reply: reply
            )
        default:
            DiagnosticsLog.info(
                "xiaomi.mishare.mesh_logi_unhandled from=\(endpoint.debugDescription) " +
                    "logiConnId=\(logiConn.logiConnId) frameType=\(inner.frameType) " +
                    "innerBytes=\(logiConn.inner.count)"
            )
        }
    }

    private func handleLogiSyncInfo(
        syncInfoData: Data,
        frame: LyraMeshPack.Frame,
        logiConn: LogiConnFrame,
        endpoint: NWEndpoint,
        reply: LyraMeshSocket.ReplyHandler
    ) {

        let fields = (try? LyraProtoReader.readFields(from: syncInfoData)) ?? []
        var sessionId: UInt64 = 0
        var trustLevel: UInt64 = 0
        var capability: UInt64?
        var uidFeature = Data()
        var signature = Data()
        for field in fields {
            switch (field.number, field.wireType) {
            case (1, 0): sessionId = field.varintValue ?? 0
            case (2, 0): trustLevel = field.varintValue ?? 0
            case (3, 0): capability = field.varintValue
            case (5, 2): uidFeature = field.lengthDelimitedValue ?? Data()
            case (6, 2): signature = field.lengthDelimitedValue ?? Data()
            default: continue
            }
        }

        DiagnosticsLog.info(
            "xiaomi.mishare.mesh_logi_sync_info from=\(endpoint.debugDescription) " +
                "logiConnId=\(logiConn.logiConnId) remoteNetId=\(logiConn.remoteNetId) " +
                "session=\(sessionId) trust=\(trustLevel) uidFeatureBytes=\(uidFeature.count)"
        )

        var syncInfo = Data()
        LyraProtoWriter.appendVarintField(1, value: sessionId, to: &syncInfo)
        LyraProtoWriter.appendVarintField(2, value: trustLevel, to: &syncInfo)
        if let capability {
            LyraProtoWriter.appendVarintField(3, value: capability, to: &syncInfo)
        }
        if !uidFeature.isEmpty {
            LyraProtoWriter.appendLengthDelimitedField(5, value: uidFeature, to: &syncInfo)
        }
        if !signature.isEmpty {
            LyraProtoWriter.appendLengthDelimitedField(6, value: signature, to: &syncInfo)
        }

        let responseInner = LogiConnInnerFrame(frameType: 5, payload: .syncInfo(syncInfo))
        let responseLogiConn = LogiConnFrame(
            logiConnId: logiConn.logiConnId,
            localNetId: 1,
            remoteNetId: logiConn.remoteNetId,
            inner: responseInner.serialized()
        )
        let miResponse = MiConnectFrame(version: 0, logiConnFrames: [responseLogiConn])
        let responseFrame = LyraMeshPack.Frame(packType: frame.packType, payload: miResponse.serialized())

        do {
            try reply(responseFrame)
            let responsePayload = (try? LyraMeshPack.encode(responseFrame)) ?? Data()
            DiagnosticsLog.info(
                "xiaomi.mishare.mesh_logi_sync_info_response to=\(endpoint.debugDescription) " +
                    "logiConnId=\(logiConn.logiConnId) hex=\(responsePayload.map { String(format: "%02x", $0) }.joined())"
            )
        } catch {
            DiagnosticsLog.error("xiaomi.mishare.mesh_logi_sync_info_response_failed", error)
        }
    }

    private func handleSyncRequest(
        frame: LyraMeshPack.Frame,
        physConn: PhysConnFrame,
        request: PhysConnSyncDeviceInfoRequest,
        endpoint: NWEndpoint,
        reply: LyraMeshSocket.ReplyHandler
    ) {

        DiagnosticsLog.info(
            "xiaomi.mishare.mesh_sync_request from=\(endpoint.debugDescription) " +
                "physConnId=\(physConn.field1) role=\(physConn.field2) " +
                "device=\(request.deviceId ?? "unknown") type=\(request.deviceType ?? 0) " +
                "connMedium=0x\(String(request.connMediumTypes ?? 0, radix: 16))"
        )

        guard deviceIdHexProvider() != nil else {
            return
        }
        let deviceIdHex = deviceIdHexProvider()!

        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let osVersionString = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        let deviceInfo = LyraDeviceInfo(
            deviceId: deviceIdHex,
            deviceType: 14,
            uidHash: "61F2",
            displayName: displayNameProvider(),
            osVersion: osVersionString,
            connMediumTypes: 0x40082,
            romVersion: "5.1.174.10.6031221"
        )
        var networkInfo = Data()
        LyraProtoWriter.appendVarintField(1, value: 256, to: &networkInfo)
        LyraProtoWriter.appendLengthDelimitedField(5, value: Data(), to: &networkInfo)

        let response = PhysConnSyncDeviceInfoResponse(
            timestampMs: UInt64(Date().timeIntervalSince1970 * 1000),
            deviceInfo: deviceInfo,
            networkInfo: networkInfo
        )
        let responsePhysConn = PhysConnFrame(
            field1: physConn.field1,
            field2: 2,
            payload: .syncDeviceInfoResponse(response.serialized())
        )
        let miResponse = MiConnectFrame(version: 0, logiConnFrames: [], physConnFrame: responsePhysConn)
        let responseFrame = LyraMeshPack.Frame(packType: frame.packType, payload: miResponse.serialized())

        do {
            try reply(responseFrame)
            let responsePayload = (try? LyraMeshPack.encode(responseFrame)) ?? Data()
            DiagnosticsLog.info(
                "xiaomi.mishare.mesh_sync_response to=\(endpoint.debugDescription) " +
                    "physConnId=\(physConn.field1) hex=\(responsePayload.map { String(format: "%02x", $0) }.joined())"
            )
        } catch {
            DiagnosticsLog.error("xiaomi.mishare.mesh_sync_response_failed", error)
        }
    }
}
