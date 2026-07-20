import EdgeLinkKit
import Foundation
import Network

final class LyraMeshResponder {
    private let socket: LyraMeshSocket
    private let deviceIdHexProvider: () -> String?
    private let displayNameProvider: () -> String

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
        guard let miFrame = MiConnectFrame(parsing: frame.payload),
              let physConn = miFrame.physConnFrame,
              case let .syncDeviceInfoRequest(requestData) = physConn.payload,
              let request = PhysConnSyncDeviceInfoRequest(parsing: requestData)
        else {
            return
        }

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

        let deviceInfo = LyraDeviceInfo(
            deviceId: deviceIdHex,
            deviceType: 14,
            uidHash: "61F2",
            displayName: displayNameProvider(),
            osVersion: "macOS",
            connMediumTypes: 128,
            romVersion: "1.0.0.edgelink"
        )
        var networkInfo = Data()
        LyraProtoWriter.appendVarintField(1, value: 256, to: &networkInfo)
        LyraProtoWriter.appendVarintField(2, value: 56, to: &networkInfo)
        LyraProtoWriter.appendVarintField(3, value: 1, to: &networkInfo)

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
            let responseDatagram = LyraMeshDatagram.encode(
                tick: LyraMeshSocket.tick(),
                payload: (try? LyraMeshPack.encode(responseFrame)) ?? Data()
            )
            DiagnosticsLog.info(
                "xiaomi.mishare.mesh_sync_response to=\(endpoint.debugDescription) " +
                    "physConnId=\(physConn.field1) hex=\(responseDatagram.map { String(format: "%02x", $0) }.joined())"
            )
        } catch {
            DiagnosticsLog.error("xiaomi.mishare.mesh_sync_response_failed", error)
        }
    }
}
