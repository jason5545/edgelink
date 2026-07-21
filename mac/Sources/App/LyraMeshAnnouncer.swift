import EdgeLinkKit
import Foundation
import Network

final class LyraMeshAnnouncer {
    private enum State {
        case idle
        case physSynced
        case logiSynced
    }

    private let socket = LyraMeshSocket()
    private var host: String?
    private var port: UInt16 = 0
    private var state: State = .idle
    private var physConnId: UInt32 = 0
    private var logiConnId: UInt32 = 0
    private var peerNetId: UInt32 = 0
    private var announceTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "edgelink.lyra.announcer")
    private let deviceIdHexProvider: () -> String?
    private let displayNameProvider: () -> String

    init(
        deviceIdHexProvider: @escaping () -> String?,
        displayNameProvider: @escaping () -> String
    ) {
        self.deviceIdHexProvider = deviceIdHexProvider
        self.displayNameProvider = displayNameProvider
    }

    func start(host: String, port: UInt16) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.host == host, self.port == port, self.state != .idle {
                return
            }
            self.stopLocked()
            self.host = host
            self.port = port
            self.state = .idle
            self.socket.onFrame = { [weak self] frame, endpoint, reply in
                self?.handle(frame: frame, endpoint: endpoint, reply: reply)
            }
            self.socket.onRawDatagram = { datagram, endpoint in
                DiagnosticsLog.info(
                    "xiaomi.mishare.announcer_rx from=\(endpoint.debugDescription) bytes=\(datagram.count)"
                )
            }
            self.sendPhysSyncRequest()
            self.startAnnounceTimerLocked()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopLocked()
        }
    }

    private func stopLocked() {
        announceTimer?.cancel()
        announceTimer = nil
        socket.stop()
        state = .idle
        host = nil
        port = 0
        peerNetId = 0
    }

    private func sendPhysSyncRequest() {
        guard let deviceIdHex = deviceIdHexProvider(), let host else {
            return
        }
        physConnId = .random(in: 1...UInt32.max)
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let deviceInfo = LyraDeviceInfo(
            deviceId: deviceIdHex,
            deviceType: 14,
            uidHash: "61F2",
            displayName: displayNameProvider(),
            osVersion: "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)",
            connMediumTypes: 0x40082,
            romVersion: "5.1.208.10.fullCnRelease.0512164"
        )
        var request = Data()
        LyraProtoWriter.appendVarintField(
            1, value: UInt64(Date().timeIntervalSince1970 * 1000), to: &request
        )
        LyraProtoWriter.appendLengthDelimitedField(2, value: deviceInfo.serialized(), to: &request)
        let physConn = PhysConnFrame(
            field1: physConnId,
            field2: 1,
            payload: .syncDeviceInfoRequest(request)
        )
        let miFrame = MiConnectFrame(version: 0, logiConnFrames: [], physConnFrame: physConn)
        send(frame: LyraMeshPack.Frame(packType: 1, payload: miFrame.serialized()), label: "phys_sync")
    }

    private func sendLogiSyncInfo() {
        logiConnId = .random(in: 1...UInt32.max)
        var syncInfo = Data()
        LyraProtoWriter.appendVarintField(1, value: 15000, to: &syncInfo)
        LyraProtoWriter.appendVarintField(2, value: 48, to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(5, value: LyraMeshResponder.officialMacUidFeature, to: &syncInfo)
        LyraProtoWriter.appendLengthDelimitedField(6, value: LyraMeshResponder.officialMacSyncInfoSignature, to: &syncInfo)
        let inner = LogiConnInnerFrame(frameType: 5, payload: .syncInfo(syncInfo))
        let logiConn = LogiConnFrame(
            logiConnId: logiConnId,
            localNetId: 1,
            inner: inner.serialized()
        )
        let miFrame = MiConnectFrame(version: 0, logiConnFrames: [logiConn])
        send(frame: LyraMeshPack.Frame(packType: 2, payload: miFrame.serialized()), label: "logi_sync_info")
    }

    private func sendAnnounce() {
        guard let deviceIdHex = deviceIdHexProvider() else {
            return
        }
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let deviceInfo = LyraTrustedDeviceInfo.deviceInfoFrame(
            deviceName: displayNameProvider(),
            deviceType: 14,
            deviceId: deviceIdHex,
            uidHash: "61F2",
            hwModel: "",
            lyraVersion: "5.1.208.10.fullCnRelease.0512164",
            services: [
                LyraTrustedDeviceInfo.Service(name: "miLyraShare", package: "com.edgelink.mac"),
                LyraTrustedDeviceInfo.Service(name: "miShareBasic", package: "com.edgelink.mac"),
                LyraTrustedDeviceInfo.Service(name: "miLyraShareTransfer", package: "com.edgelink.mac")
            ],
            ipAddress: nil,
            osVersion: "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        )
        var payload = Data()
        payload.append(UInt8((peerNetId == 0 ? 1 : peerNetId) & 0xFF))
        payload.append(0)
        payload.append(0)
        let syncInner = LyraTrustedDeviceInfo.syncInner(deviceInfo: deviceInfo)
        var logiConn = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &logiConn)
        if peerNetId != 0 {
            LyraProtoWriter.appendVarintField(2, value: UInt64(peerNetId), to: &logiConn)
        }
        LyraProtoWriter.appendVarintField(3, value: UInt64(logiConnId), to: &logiConn)
        LyraProtoWriter.appendLengthDelimitedField(5, value: syncInner, to: &logiConn)
        payload.append(logiConn)
        send(frame: LyraMeshPack.Frame(packType: 5, payload: payload), label: "announce")
    }

    private func send(frame: LyraMeshPack.Frame, label: String) {
        guard let host, port != 0 else { return }
        do {
            try socket.send(frame: frame, to: host, port: port)
            DiagnosticsLog.info("xiaomi.mishare.announcer_tx label=\(label) to=\(host):\(port)")
        } catch {
            DiagnosticsLog.error("xiaomi.mishare.announcer_tx_failed", error)
        }
    }

    private func startAnnounceTimerLocked() {
        announceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 7, repeating: 7)
        timer.setEventHandler { [weak self] in
            guard let self, self.state == .logiSynced else { return }
            self.sendAnnounce()
        }
        announceTimer = timer
        timer.resume()
    }

    private func handle(frame: LyraMeshPack.Frame, endpoint: NWEndpoint, reply: LyraMeshSocket.ReplyHandler) {
        if frame.packType == 5 {
            DiagnosticsLog.info(
                "xiaomi.mishare.announcer_payload bytes=\(frame.payload.count) " +
                    "hex=\(frame.payload.prefix(48).map { String(format: "%02x", $0) }.joined())"
            )
            return
        }
        guard let miFrame = MiConnectFrame(parsing: frame.payload) else {
            return
        }
        if let physConn = miFrame.physConnFrame {
            switch physConn.payload {
            case .syncDeviceInfoResponse:
                DiagnosticsLog.info("xiaomi.mishare.announcer_phys_synced")
                state = .physSynced
                sendLogiSyncInfo()
            case let .keepAliveRequest(requestData):
                let tick = UInt64(LyraMeshSocket.tick())
                var responsePayload = Data()
                LyraProtoWriter.appendVarintField(1, value: tick, to: &responsePayload)
                LyraProtoWriter.appendVarintField(2, value: 2, to: &responsePayload)
                LyraProtoWriter.appendVarintField(3, value: tick, to: &responsePayload)
                let responsePhysConn = PhysConnFrame(field2: 5, payload: .keepAliveResponse(responsePayload))
                let miResponse = MiConnectFrame(version: 0, logiConnFrames: [], physConnFrame: responsePhysConn)
                try? reply(LyraMeshPack.Frame(packType: frame.packType, payload: miResponse.serialized()))
                _ = requestData
            default:
                break
            }
        }
        for logiConn in miFrame.logiConnFrames {
            guard let inner = LogiConnInnerFrame(parsing: logiConn.inner) else {
                continue
            }
            if case .syncInfo = inner.payload {
                peerNetId = logiConn.localNetId
                DiagnosticsLog.info(
                    "xiaomi.mishare.announcer_logi_synced peerNetId=\(logiConn.localNetId) logiConnId=\(logiConn.logiConnId)"
                )
                state = .logiSynced
                sendAnnounce()
            }
        }
    }
}
