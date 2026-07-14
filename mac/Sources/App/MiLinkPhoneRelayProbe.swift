import Foundation
import Network

final class MiLinkPhoneRelayProbe {
    var onStatusChanged: ((String) -> Void)?

    private let queue = DispatchQueue(label: "EdgeLink.MiLinkPhoneRelayProbe")
    private var tcpListener: NWListener?
    private var udpListener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var port: UInt16 = 7102

    func start(port: UInt16 = 7102) throws {
        stop()
        self.port = port
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw MiLinkPhoneRelayProbeError.invalidPort(port)
        }

        let tcpParameters = NWParameters.tcp
        tcpParameters.allowLocalEndpointReuse = true
        let udpParameters = NWParameters.udp
        udpParameters.allowLocalEndpointReuse = true

        let tcp = try NWListener(using: tcpParameters, on: endpointPort)
        let udp = try NWListener(using: udpParameters, on: endpointPort)
        tcpListener = tcp
        udpListener = udp

        configureTCPListener(tcp)
        configureUDPListener(udp)

        DiagnosticsLog.info("phonerelay.mac.probe_start port=\(port)")
        onStatusChanged?("PHONERELAY TCP/UDP \(port)")
        tcp.start(queue: queue)
        udp.start(queue: queue)
    }

    func stop() {
        let hadActiveProbe = tcpListener != nil || udpListener != nil || !connections.isEmpty
        let activePort = port
        tcpListener?.cancel()
        udpListener?.cancel()
        tcpListener = nil
        udpListener = nil
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
        if hadActiveProbe {
            DiagnosticsLog.info("phonerelay.mac.probe_stop port=\(activePort)")
            onStatusChanged?("")
        }
    }

    private func configureTCPListener(_ listener: NWListener) {
        listener.stateUpdateHandler = { [weak self] state in
            self?.handleListenerState("tcp", state)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.acceptTCPConnection(connection)
        }
    }

    private func configureUDPListener(_ listener: NWListener) {
        listener.stateUpdateHandler = { [weak self] state in
            self?.handleListenerState("udp", state)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.acceptUDPConnection(connection)
        }
    }

    private func handleListenerState(_ proto: String, _ state: NWListener.State) {
        switch state {
        case .ready:
            DiagnosticsLog.info("phonerelay.mac.probe_listener_ready proto=\(proto) port=\(port)")
        case .failed(let error):
            DiagnosticsLog.warn("phonerelay.mac.probe_listener_failed proto=\(proto) error=\(error)")
            onStatusChanged?("PHONERELAY \(proto) failed")
        case .cancelled:
            DiagnosticsLog.info("phonerelay.mac.probe_listener_cancelled proto=\(proto)")
        default:
            break
        }
    }

    private func acceptTCPConnection(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection
        DiagnosticsLog.info("phonerelay.mac.probe_connection proto=tcp id=\(id.uuidString) remote=\(connection.endpoint)")
        connection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState("tcp", id: id, endpoint: connection.endpoint, state: state)
        }
        connection.start(queue: queue)
        receiveTCP(connection, id: id)
    }

    private func acceptUDPConnection(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection
        DiagnosticsLog.info("phonerelay.mac.probe_connection proto=udp id=\(id.uuidString) remote=\(connection.endpoint)")
        connection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState("udp", id: id, endpoint: connection.endpoint, state: state)
        }
        connection.start(queue: queue)
        receiveUDP(connection, id: id)
    }

    private func handleConnectionState(
        _ proto: String,
        id: UUID,
        endpoint: NWEndpoint,
        state: NWConnection.State
    ) {
        switch state {
        case .ready:
            DiagnosticsLog.info("phonerelay.mac.probe_connection_ready proto=\(proto) id=\(id.uuidString) remote=\(endpoint)")
        case .failed(let error):
            DiagnosticsLog.warn("phonerelay.mac.probe_connection_failed proto=\(proto) id=\(id.uuidString) error=\(error)")
            connections[id] = nil
        case .cancelled:
            DiagnosticsLog.info("phonerelay.mac.probe_connection_cancelled proto=\(proto) id=\(id.uuidString)")
            connections[id] = nil
        default:
            break
        }
    }

    private func receiveTCP(_ connection: NWConnection, id: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }
            if let data, !data.isEmpty {
                self.logPacket(proto: "tcp", id: id, data: data, complete: isComplete)
            }
            if let error {
                DiagnosticsLog.warn("phonerelay.mac.probe_receive_failed proto=tcp id=\(id.uuidString) error=\(error)")
                self.connections[id] = nil
                return
            }
            if isComplete {
                DiagnosticsLog.info("phonerelay.mac.probe_receive_complete proto=tcp id=\(id.uuidString)")
                self.connections[id] = nil
                return
            }
            self.receiveTCP(connection, id: id)
        }
    }

    private func receiveUDP(_ connection: NWConnection, id: UUID) {
        connection.receiveMessage { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }
            if let data, !data.isEmpty {
                self.logPacket(proto: "udp", id: id, data: data, complete: isComplete)
            }
            if let error {
                DiagnosticsLog.warn("phonerelay.mac.probe_receive_failed proto=udp id=\(id.uuidString) error=\(error)")
                self.connections[id] = nil
                return
            }
            self.receiveUDP(connection, id: id)
        }
    }

    private func logPacket(proto: String, id: UUID, data: Data, complete: Bool) {
        DiagnosticsLog.info(
            "phonerelay.mac.probe_packet proto=\(proto) id=\(id.uuidString) " +
                "bytes=\(data.count) complete=\(complete) fp=\(DiagnosticsLog.fingerprint(data)) " +
                "prefix=\(hexPrefix(data))"
        )
    }

    private func hexPrefix(_ data: Data) -> String {
        data.prefix(32).map { String(format: "%02x", $0) }.joined()
    }
}

private enum MiLinkPhoneRelayProbeError: Error {
    case invalidPort(UInt16)
}
