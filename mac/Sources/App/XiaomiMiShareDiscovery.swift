import CryptoKit
import EdgeLinkKit
import Foundation

struct XiaomiMiShareDiscoveredPeer: Equatable, Identifiable {
    var id: String { deviceIdHex ?? serviceName }

    let serviceName: String
    let deviceIdHex: String?
    let displayName: String?
    let hostName: String?
    let port: Int
    let mediumType: String?
    let channel: String?
    let debugInfo: String?
    let appDataBase64: String?
    let seenAt: Date

    var displayLabel: String {
        displayName ?? deviceIdHex ?? serviceName
    }
}

struct XiaomiMiShareDiscoverySnapshot: Equatable {
    let isBrowsing: Bool
    let isPublishing: Bool
    let publishedServiceName: String?
    let publishedDeviceIdHex: String?
    let publishedDisplayName: String?
    let peers: [XiaomiMiShareDiscoveredPeer]
    let lastError: String?
}

final class XiaomiMiShareDiscovery: NSObject {
    static let serviceType = "_lyra-mdns._udp."
    static let serviceDomain = "local."

    var onSnapshotChanged: ((XiaomiMiShareDiscoverySnapshot) -> Void)?

    private let browser = NetServiceBrowser()
    private let meshSocket = LyraMeshSocket()
    private var meshResponder: LyraMeshResponder?
    private var meshAnnouncer: LyraMeshAnnouncer?
    private var lyraPublisher: XiaomiLyraMDNSPublisher?
    private var discoveredServices: [String: NetService] = [:]
    private var peersByServiceName: [String: XiaomiMiShareDiscoveredPeer] = [:]
    private var isBrowsing = false
    private var isPublishing = false
    private var publishedDeviceIdHex: String?
    private var publishedDisplayName: String?
    private var lastError: String?

    override init() {
        super.init()
        browser.delegate = self
    }

    func start(identitySeed: String, displayName: String) {
        stop(emitsSnapshot: false)

        let deviceIdHex = Self.deviceIdHex(identitySeed: identitySeed)
        publishedDeviceIdHex = deviceIdHex
        publishedDisplayName = Self.sanitizedDisplayName(displayName)
        lastError = nil

        browser.searchForServices(ofType: Self.serviceType, inDomain: Self.serviceDomain)
        isBrowsing = true
        DiagnosticsLog.info("xiaomi.mishare.discovery_browser_started type=\(Self.serviceType)")

        startMeshSocket()
        emitSnapshot()
    }

    func stop() {
        stop(emitsSnapshot: true)
    }

    private func stop(emitsSnapshot: Bool) {
        browser.stop()
        lyraPublisher?.stop()
        meshSocket.stop()
        for service in discoveredServices.values {
            service.delegate = nil
            service.stop()
        }
        lyraPublisher = nil
        discoveredServices.removeAll()
        peersByServiceName.removeAll()
        isBrowsing = false
        isPublishing = false
        if emitsSnapshot {
            emitSnapshot()
        }
    }

    private func startMeshSocket() {
        meshSocket.onRawDatagram = { datagram, endpoint in
            DiagnosticsLog.info(
                "xiaomi.mishare.mesh_rx endpoint=\(endpoint.debugDescription) bytes=\(datagram.count) " +
                    "hex=\(datagram.prefix(512).map { String(format: "%02x", $0) }.joined())"
            )
        }
        let responder = LyraMeshResponder(
            socket: meshSocket,
            deviceIdHexProvider: { [weak self] in self?.publishedDeviceIdHex },
            displayNameProvider: { [weak self] in self?.publishedDisplayName ?? "EdgeLink Mac" }
        )
        responder.attach()
        meshResponder = responder
        meshSocket.onStateChanged = { [weak self] state in
            DiagnosticsLog.info("xiaomi.mishare.mesh_socket_state state=\(String(describing: state))")
            guard let self, case .ready = state else { return }
            DispatchQueue.main.async {
                guard let deviceIdHex = self.publishedDeviceIdHex else { return }
                self.publish(deviceIdHex: deviceIdHex, displayName: self.publishedDisplayName ?? "EdgeLink Mac")
            }
        }
        do {
            try meshSocket.start(preferredPort: Self.preferredMeshPort())
        } catch {
            DiagnosticsLog.error("xiaomi.mishare.mesh_socket_start_failed", error)
        }
    }

    private static func preferredMeshPort() -> UInt16? {
        let key = "xiaomiMiShareMeshPort"
        if let saved = UserDefaults.standard.object(forKey: key) as? Int, saved > 0 {
            return UInt16(saved)
        }
        let port = Int.random(in: 40000...60000)
        UserDefaults.standard.set(port, forKey: key)
        return UInt16(port)
    }

    private func publish(deviceIdHex: String, displayName: String) {
        do {
            let appData = try XiaomiMiShareDiscoveryAppData.buildBase64(
                deviceIdHex: deviceIdHex,
                displayName: displayName,
                accountIdHex: "61F2",
                meshPort: meshSocket.boundPort
            )
            let publisher = XiaomiLyraMDNSPublisher(deviceIdHex: deviceIdHex, appDataBase64: appData)
            try publisher.start()
            lyraPublisher = publisher
            isPublishing = true
            DiagnosticsLog.info(
                "xiaomi.mishare.discovery_published deviceId=\(deviceIdHex) displayName=\(displayName) " +
                    "mode=dnssd_records host=\(publisher.hostFQDN) appDataChars=\(appData.utf8.count)"
            )
        } catch {
            isPublishing = false
            lastError = "Lyra mDNS 廣播失敗"
            DiagnosticsLog.error("xiaomi.mishare.discovery_publish_payload_failed deviceId=\(deviceIdHex)", error)
        }
    }

    private static func deviceIdHex(identitySeed: String) -> String {
        let digest = SHA256.hash(data: Data("edgelink.mishare.\(identitySeed)".utf8))
        return digest.prefix(4).map { String(format: "%02X", $0) }.joined()
    }

    private static func sanitizedDisplayName(_ displayName: String) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "EdgeLink Mac"
        }
        let bytes = Array(trimmed.utf8)
        guard bytes.count > 80 else {
            return trimmed
        }
        var result = ""
        for scalar in trimmed.unicodeScalars {
            let candidate = result + String(scalar)
            if candidate.utf8.count > 80 {
                break
            }
            result = candidate
        }
        return result.isEmpty ? "EdgeLink Mac" : result
    }

    private func handleResolvedService(_ service: NetService) {
        guard service.name != publishedDeviceIdHex else {
            return
        }
        guard let txtData = service.txtRecordData() else {
            DiagnosticsLog.warn("xiaomi.mishare.discovery_resolved_without_txt service=\(service.name)")
            return
        }
        let txt = NetService.dictionary(fromTXTRecord: txtData)
        let appDataBase64 = Self.txtString("AppData", in: txt)
        let payload = appDataBase64.flatMap(XiaomiMiShareDiscoveryAppData.init(base64Encoded:))
        if payload?.deviceIdHex == publishedDeviceIdHex {
            return
        }

        let peer = XiaomiMiShareDiscoveredPeer(
            serviceName: service.name,
            deviceIdHex: payload?.deviceIdHex,
            displayName: payload?.displayName,
            hostName: service.hostName,
            port: service.port,
            mediumType: Self.txtString("MediumType", in: txt),
            channel: Self.txtString("CH", in: txt),
            debugInfo: Self.txtString("DebugInfo", in: txt),
            appDataBase64: appDataBase64,
            seenAt: Date()
        )
        peersByServiceName[service.name] = peer
        DiagnosticsLog.info(
            "xiaomi.mishare.discovery_peer service=\(service.name) deviceId=\(peer.deviceIdHex ?? "unknown") " +
                "name=\(peer.displayName ?? "unknown") host=\(peer.hostName ?? "unknown") port=\(peer.port) " +
                "medium=\(peer.mediumType ?? "unknown") ch=\(peer.channel ?? "unknown")"
        )
        startAnnouncerIfPhonePeer(service: service, payload: payload, debugInfo: peer.debugInfo)
        emitSnapshot()
    }

    private func startAnnouncerIfPhonePeer(
        service: NetService,
        payload: XiaomiMiShareDiscoveryAppData?,
        debugInfo: String?
    ) {
        guard payload?.deviceType == XiaomiMiShareDiscoveryAppData.deviceTypePhone,
              let meshPort = payload?.meshPort, meshPort != 0,
              let host = Self.parseDebugInfoIPv4(debugInfo)
        else {
            return
        }
        if meshAnnouncer == nil {
            meshAnnouncer = LyraMeshAnnouncer(
                deviceIdHexProvider: { [weak self] in self?.publishedDeviceIdHex },
                displayNameProvider: { [weak self] in self?.publishedDisplayName ?? "EdgeLink Mac" }
            )
        }
        DiagnosticsLog.info("xiaomi.mishare.announcer_start host=\(host) port=\(meshPort)")
        meshAnnouncer?.start(host: host, port: meshPort)
    }

    private static func parseDebugInfoIPv4(_ debugInfo: String?) -> String? {
        guard let debugInfo else { return nil }
        for part in debugInfo.split(separator: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("v4:") {
                let value = String(trimmed.dropFirst(3))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    private static func txtString(_ key: String, in record: [String: Data]) -> String? {
        record[key].flatMap { String(data: $0, encoding: .utf8) }
    }

    private func emitSnapshot() {
        let peers = peersByServiceName.values.sorted { lhs, rhs in
            lhs.displayLabel.localizedStandardCompare(rhs.displayLabel) == .orderedAscending
        }
        onSnapshotChanged?(
            XiaomiMiShareDiscoverySnapshot(
                isBrowsing: isBrowsing,
                isPublishing: isPublishing,
                publishedServiceName: lyraPublisher?.serviceName,
                publishedDeviceIdHex: publishedDeviceIdHex,
                publishedDisplayName: publishedDisplayName,
                peers: peers,
                lastError: lastError
            )
        )
    }
}

extension XiaomiMiShareDiscovery: NetServiceBrowserDelegate {
    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        isBrowsing = true
        lastError = nil
        emitSnapshot()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        isBrowsing = false
        lastError = "Bonjour 搜尋失敗 \(errorDict)"
        DiagnosticsLog.warn("xiaomi.mishare.discovery_browser_failed error=\(errorDict)")
        emitSnapshot()
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        guard service.name != publishedDeviceIdHex else {
            return
        }
        discoveredServices[service.name] = service
        service.delegate = self
        service.resolve(withTimeout: 5)
        DiagnosticsLog.info("xiaomi.mishare.discovery_found service=\(service.name) moreComing=\(moreComing)")
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        discoveredServices.removeValue(forKey: service.name)
        peersByServiceName.removeValue(forKey: service.name)
        DiagnosticsLog.info("xiaomi.mishare.discovery_removed service=\(service.name) moreComing=\(moreComing)")
        emitSnapshot()
    }
}

extension XiaomiMiShareDiscovery: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        handleResolvedService(sender)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        DiagnosticsLog.warn("xiaomi.mishare.discovery_resolve_failed service=\(sender.name) error=\(errorDict)")
        emitSnapshot()
    }

    func netServiceDidStop(_ sender: NetService) {
        emitSnapshot()
    }
}
