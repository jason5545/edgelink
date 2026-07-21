import Darwin
import EdgeLinkKit
import Foundation

private let xiaomiLyraDNSServiceRegisterRecordReply: DNSServiceRegisterRecordReply = { _, _, _, errorCode, _ in
    if errorCode != kDNSServiceErr_NoError {
        DiagnosticsLog.warn("xiaomi.mishare.lyra_mdns_register_async_failed code=\(errorCode)")
    }
}

enum XiaomiLyraMDNSPublisherError: LocalizedError {
    case noActiveIPv4Interface
    case createConnectionFailed(Int32)
    case registerServiceFailed(interface: String, code: Int32)
    case registerRecordFailed(record: String, interface: String, code: Int32)
    case recordEncodingFailed(Error)

    var errorDescription: String? {
        switch self {
        case .noActiveIPv4Interface:
            return "找不到可用的 IPv4 網路介面"
        case let .createConnectionFailed(code):
            return "mDNS connection 建立失敗 code=\(code)"
        case let .registerServiceFailed(interface, code):
            return "mDNS service 註冊失敗 interface=\(interface) code=\(code)"
        case let .registerRecordFailed(record, interface, code):
            return "mDNS record 註冊失敗 record=\(record) interface=\(interface) code=\(code)"
        case let .recordEncodingFailed(error):
            return "mDNS record 編碼失敗 \(error)"
        }
    }
}

final class XiaomiLyraMDNSPublisher {
    private struct NetworkInterface: Equatable {
        let name: String
        let index: UInt32
        let ipv4Address: [UInt8]
        var ipv6LinkLocal: String?

        var ipv4Description: String {
            ipv4Address.map(String.init).joined(separator: ".")
        }
    }

    let serviceName: String
    let hostName: String
    let serviceFQDN: String
    let instanceFQDN: String
    let hostFQDN: String

    private let appDataBase64: String
    private let registerType: String
    private let registerDomain: String
    private var serviceRefs: [DNSServiceRef] = []
    private var addressServiceRef: DNSServiceRef?
    private var recordRefs: [DNSRecordRef] = []
    private var registeredInterfaces: [NetworkInterface] = []

    init(deviceIdHex: String, appDataBase64: String) {
        serviceName = deviceIdHex
        hostName = "\(deviceIdHex).local"
        serviceFQDN = "\(XiaomiMiShareDiscovery.serviceType)\(XiaomiMiShareDiscovery.serviceDomain)"
        instanceFQDN = "\(deviceIdHex).\(XiaomiMiShareDiscovery.serviceType)\(XiaomiMiShareDiscovery.serviceDomain)"
        hostFQDN = "\(deviceIdHex).\(XiaomiMiShareDiscovery.serviceDomain)"
        registerType = Self.trimTrailingDot(XiaomiMiShareDiscovery.serviceType)
        registerDomain = Self.trimTrailingDot(XiaomiMiShareDiscovery.serviceDomain)
        self.appDataBase64 = appDataBase64
    }

    deinit {
        stop()
    }

    func start() throws {
        stop()

        let interfaces = Self.activeIPv4Interfaces()
        guard !interfaces.isEmpty else {
            throw XiaomiLyraMDNSPublisherError.noActiveIPv4Interface
        }

        do {
            try registerService(on: interfaces)
            try registerAddressRecords(on: interfaces)
        } catch {
            stop()
            throw error
        }

        registeredInterfaces = interfaces
        let interfaceSummary = interfaces
            .map { "\($0.name)#\($0.index)=\($0.ipv4Description)" }
            .joined(separator: ",")
        DiagnosticsLog.info(
            "xiaomi.mishare.lyra_mdns_published instance=\(instanceFQDN) host=\(hostFQDN) " +
                "interfaces=\(interfaceSummary) appDataChars=\(appDataBase64.utf8.count)"
        )
    }

    func stop() {
        for serviceRef in serviceRefs {
            DNSServiceRefDeallocate(serviceRef)
        }
        serviceRefs.removeAll()
        if let addressServiceRef {
            DNSServiceRefDeallocate(addressServiceRef)
        }
        addressServiceRef = nil
        recordRefs.removeAll()
        if !registeredInterfaces.isEmpty {
            DiagnosticsLog.info(
                "xiaomi.mishare.lyra_mdns_stopped instance=\(instanceFQDN) " +
                    "interfaces=\(registeredInterfaces.map(\.name).joined(separator: ","))"
            )
        }
        registeredInterfaces.removeAll()
    }

    private func registerService(on interfaces: [NetworkInterface]) throws {
        let port = UInt16(5353).bigEndian

        for networkInterface in interfaces {
            let txt = try encodedRecord("TXT") {
                try XiaomiLyraMDNSRecordEncoder.txtRecord(entries: txtEntries(for: networkInterface))
            }
            var serviceRef: DNSServiceRef?
            let result = txt.withUnsafeBytes { rawBuffer -> DNSServiceErrorType in
                DNSServiceRegister(
                    &serviceRef,
                    0,
                    networkInterface.index,
                    serviceName,
                    registerType,
                    registerDomain,
                    hostName,
                    port,
                    UInt16(txt.count),
                    rawBuffer.baseAddress,
                    nil,
                    nil
                )
            }
            guard result == kDNSServiceErr_NoError, let serviceRef else {
                DiagnosticsLog.warn(
                    "xiaomi.mishare.lyra_mdns_service_register_failed name=\(serviceName) " +
                        "type=\(registerType) domain=\(registerDomain) host=\(hostName) " +
                        "interface=\(networkInterface.name)#\(networkInterface.index) code=\(result)"
                )
                throw XiaomiLyraMDNSPublisherError.registerServiceFailed(
                    interface: networkInterface.name,
                    code: Int32(result)
                )
            }
            serviceRefs.append(serviceRef)
        }
    }

    private func txtEntries(for networkInterface: NetworkInterface) -> [(String, String)] {
        let debugInfo =
            "{msg:hello, ifname:\(networkInterface.name), " +
            "v4:\(networkInterface.ipv4Description), v6:\(networkInterface.ipv6LinkLocal ?? "")}"
        return [
            ("AppData", appDataBase64),
            ("DebugInfo", debugInfo),
            ("MediumType", "256"),
            ("CH", "56")
        ]
    }

    private func registerAddressRecords(on interfaces: [NetworkInterface]) throws {
        var ref: DNSServiceRef?
        let createResult = DNSServiceCreateConnection(&ref)
        guard createResult == kDNSServiceErr_NoError, let ref else {
            throw XiaomiLyraMDNSPublisherError.createConnectionFailed(Int32(createResult))
        }

        addressServiceRef = ref

        for networkInterface in interfaces {
            try registerRecord(
                name: hostFQDN,
                label: "A",
                type: UInt16(kDNSServiceType_A),
                flags: DNSServiceFlags(kDNSServiceFlagsUnique),
                data: Data(networkInterface.ipv4Address),
                interfaceName: networkInterface.name,
                interfaceIndex: networkInterface.index
            )
        }
    }

    private func encodedRecord(_ label: String, build: () throws -> Data) throws -> Data {
        do {
            return try build()
        } catch {
            DiagnosticsLog.error("xiaomi.mishare.lyra_mdns_record_encode_failed label=\(label)", error)
            throw XiaomiLyraMDNSPublisherError.recordEncodingFailed(error)
        }
    }

    private func registerRecord(
        name: String,
        label: String,
        type: UInt16,
        flags: DNSServiceFlags,
        data: Data,
        interfaceName: String,
        interfaceIndex: UInt32
    ) throws {
        guard let addressServiceRef else {
            throw XiaomiLyraMDNSPublisherError.createConnectionFailed(Int32(kDNSServiceErr_BadReference))
        }

        var recordRef: DNSRecordRef?
        let result = data.withUnsafeBytes { rawBuffer -> DNSServiceErrorType in
            DNSServiceRegisterRecord(
                addressServiceRef,
                &recordRef,
                flags,
                interfaceIndex,
                name,
                type,
                UInt16(kDNSServiceClass_IN),
                UInt16(data.count),
                rawBuffer.baseAddress,
                0,
                xiaomiLyraDNSServiceRegisterRecordReply,
                nil
            )
        }

        guard result == kDNSServiceErr_NoError, let recordRef else {
            DiagnosticsLog.warn(
                "xiaomi.mishare.lyra_mdns_register_failed label=\(label) name=\(name) " +
                    "interface=\(interfaceName)#\(interfaceIndex) code=\(result)"
            )
            throw XiaomiLyraMDNSPublisherError.registerRecordFailed(
                record: label,
                interface: interfaceName,
                code: Int32(result)
            )
        }
        recordRefs.append(recordRef)
    }

    private static func activeIPv4Interfaces() -> [NetworkInterface] {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else {
            return []
        }
        defer { freeifaddrs(firstAddress) }

        var interfaces: [NetworkInterface] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let pointer = cursor {
            defer { cursor = pointer.pointee.ifa_next }

            let entry = pointer.pointee
            guard let address = entry.ifa_addr,
                  Int32(address.pointee.sa_family) == AF_INET
            else {
                continue
            }

            let flags = Int32(entry.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_RUNNING) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  (flags & IFF_BROADCAST) != 0
            else {
                continue
            }

            let name = String(cString: entry.ifa_name)
            let index = if_nametoindex(entry.ifa_name)
            guard !isLikelyVirtualInterface(name),
                  index != 0
            else {
                continue
            }

            let sockaddr = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee
            }
            var ipv4Raw = sockaddr.sin_addr.s_addr
            let ipv4 = withUnsafeBytes(of: &ipv4Raw) { Array($0) }
            let networkInterface = NetworkInterface(name: name, index: index, ipv4Address: ipv4)
            if !interfaces.contains(networkInterface) {
                interfaces.append(networkInterface)
            }
        }

        var linkLocalV6: [String: String] = [:]
        cursor = firstAddress
        while let pointer = cursor {
            defer { cursor = pointer.pointee.ifa_next }

            let entry = pointer.pointee
            guard let address = entry.ifa_addr,
                  Int32(address.pointee.sa_family) == AF_INET6
            else {
                continue
            }

            let name = String(cString: entry.ifa_name)
            guard interfaces.contains(where: { $0.name == name }),
                  linkLocalV6[name] == nil
            else {
                continue
            }

            let sockaddr6 = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                $0.pointee
            }
            var bytes = sockaddr6.sin6_addr
            let isLinkLocal = withUnsafeBytes(of: &bytes) { raw in
                raw[0] == 0xFE && (raw[1] & 0xC0) == 0x80
            }
            guard isLinkLocal else {
                continue
            }

            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            var address6 = sockaddr6.sin6_addr
            guard inet_ntop(AF_INET6, &address6, &text, socklen_t(INET6_ADDRSTRLEN)) != nil else {
                continue
            }
            linkLocalV6[name] = String(cString: text) + "%" + name
        }

        interfaces = interfaces.map { networkInterface in
            var copy = networkInterface
            copy.ipv6LinkLocal = linkLocalV6[networkInterface.name]
            return copy
        }

        return interfaces.sorted { lhs, rhs in
            interfacePriority(lhs.name) < interfacePriority(rhs.name)
        }
    }

    private static func isLikelyVirtualInterface(_ name: String) -> Bool {
        let excludedPrefixes = [
            "lo", "utun", "awdl", "llw", "gif", "stf", "bridge", "vmnet", "vmenet", "anpi"
        ]
        return excludedPrefixes.contains { name.hasPrefix($0) }
    }

    private static func interfacePriority(_ name: String) -> Int {
        switch name {
        case "en0":
            return 0
        case "en1":
            return 1
        default:
            return 10
        }
    }

    private static func trimTrailingDot(_ value: String) -> String {
        var result = value
        while result.hasSuffix(".") {
            result.removeLast()
        }
        return result
    }
}
