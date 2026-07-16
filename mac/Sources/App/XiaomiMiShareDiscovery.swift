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
    private var publishedService: NetService?
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

        publish(deviceIdHex: deviceIdHex, displayName: publishedDisplayName ?? "EdgeLink Mac")
        emitSnapshot()
    }

    func stop() {
        stop(emitsSnapshot: true)
    }

    private func stop(emitsSnapshot: Bool) {
        browser.stop()
        publishedService?.stop()
        publishedService?.delegate = nil
        for service in discoveredServices.values {
            service.delegate = nil
            service.stop()
        }
        publishedService = nil
        discoveredServices.removeAll()
        peersByServiceName.removeAll()
        isBrowsing = false
        isPublishing = false
        if emitsSnapshot {
            emitSnapshot()
        }
    }

    private func publish(deviceIdHex: String, displayName: String) {
        do {
            let appData = try XiaomiMiShareDiscoveryAppData.buildBase64(
                deviceIdHex: deviceIdHex,
                displayName: displayName
            )
            let service = NetService(
                domain: Self.serviceDomain,
                type: Self.serviceType,
                name: deviceIdHex,
                port: 5353
            )
            service.delegate = self
            let txt = Self.publisherTXTRecord(appData: appData)
            service.setTXTRecord(NetService.data(fromTXTRecord: txt))
            publishedService = service
            service.publish()
            DiagnosticsLog.info(
                "xiaomi.mishare.discovery_publish_requested deviceId=\(deviceIdHex) displayName=\(displayName)"
            )
        } catch {
            lastError = "AppData 組合失敗"
            DiagnosticsLog.error("xiaomi.mishare.discovery_publish_payload_failed deviceId=\(deviceIdHex)", error)
        }
    }

    private static func publisherTXTRecord(appData: String) -> [String: Data] {
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let localIPv4 = MiLinkPhoneRelayProbe.preferredLocalIPv4Address()
        let debugInfo: String
        if let localIPv4 {
            debugInfo = "{msg:hello, ifname:en0, v4:\(localIPv4)}"
        } else {
            debugInfo = "{msg:hello, ifname:en0}"
        }
        return [
            "AppData": Data(appData.utf8),
            "MediumType": Data("256".utf8),
            "CH": Data("56".utf8),
            "DebugInfo": Data(debugInfo.utf8),
            "TS": Data(timestamp.utf8)
        ]
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
        guard service.name != publishedService?.name else {
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
        emitSnapshot()
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
                publishedServiceName: publishedService?.name,
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
        guard service.name != publishedService?.name else {
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
    func netServiceDidPublish(_ sender: NetService) {
        guard let publishedService, sender === publishedService else {
            return
        }
        isPublishing = true
        lastError = nil
        DiagnosticsLog.info(
            "xiaomi.mishare.discovery_published service=\(sender.name) deviceId=\(publishedDeviceIdHex ?? "unknown")"
        )
        emitSnapshot()
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        guard let publishedService, sender === publishedService else {
            return
        }
        isPublishing = false
        lastError = "Bonjour 廣播失敗 \(errorDict)"
        DiagnosticsLog.warn("xiaomi.mishare.discovery_publish_failed service=\(sender.name) error=\(errorDict)")
        emitSnapshot()
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        handleResolvedService(sender)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        DiagnosticsLog.warn("xiaomi.mishare.discovery_resolve_failed service=\(sender.name) error=\(errorDict)")
        emitSnapshot()
    }

    func netServiceDidStop(_ sender: NetService) {
        if let publishedService, sender === publishedService {
            isPublishing = false
        }
        emitSnapshot()
    }
}
