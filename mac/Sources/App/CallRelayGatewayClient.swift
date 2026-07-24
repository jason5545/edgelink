import EdgeLinkKit
import Foundation

final class CallRelayCloudflareBridge: @unchecked Sendable {
    var onPlaybackStats: ((CallRelayGatewayPlaybackStats) -> Void)?

    private let queue = DispatchQueue(label: "EdgeLink.CallRelayCloudflareBridge")
    private let player: PhoneRelayDownlinkPlayer
    private var activeSessionId: String?
    private var receivedPackets = 0

    init(downlinkPlayer: PhoneRelayDownlinkPlayer) {
        player = downlinkPlayer
    }

    func start(sessionId: String) {
        queue.async {
            if self.activeSessionId != sessionId {
                self.player.stop(reason: "replace_session")
                self.receivedPackets = 0
            }
            self.activeSessionId = sessionId
            DiagnosticsLog.info("callrelay.mac.cloudflare_start sessionId=\(sessionId)")
        }
    }

    func handle(_ body: PhoneRelayMediaBody) {
        queue.async {
            guard body.direction == "android_to_mac",
                  body.kind == "rtp",
                  body.sessionId == self.activeSessionId,
                  let dataBase64 = body.dataBase64,
                  let packet = Data(base64Encoded: dataBase64) else {
                return
            }
            self.receivedPackets += 1
            if self.receivedPackets == 1 || self.receivedPackets % 100 == 0 {
                DiagnosticsLog.info(
                    "callrelay.mac.cloudflare_rtp_in sessionId=\(body.sessionId) " +
                        "count=\(self.receivedPackets) bytes=\(packet.count)"
                )
            }
            if let stats = self.player.writeRTPPacket(packet) {
                self.onPlaybackStats?(stats)
            }
        }
    }

    func stop(reason: String) {
        queue.async {
            if let sessionId = self.activeSessionId {
                DiagnosticsLog.info(
                    "callrelay.mac.cloudflare_stop sessionId=\(sessionId) reason=\(reason) " +
                        "packets=\(self.receivedPackets)"
                )
            }
            self.activeSessionId = nil
            self.receivedPackets = 0
            self.player.stop(reason: reason)
        }
    }
}
