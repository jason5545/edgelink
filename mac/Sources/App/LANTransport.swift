import Foundation
import Network

final class LANTransport: @unchecked Sendable {
    static let serviceType = "_edgelink._tcp"
    static let reachabilityProbePort: UInt16 = 7_103

    private static let probeRequest = Data("EDGELINK-LAN-PROBE/1\n".utf8)
    private static let probeResponse = Data("EDGELINK-LAN-OK/1\n".utf8)

    private let queue = DispatchQueue(label: "EdgeLink.LANTransport")
    private let stateLock = NSLock()
    private var listener: NWListener?
    private var probeReady = false

    var isReachabilityProbeReady: Bool {
        stateLock.withLock { probeReady }
    }

    func startReachabilityProbe() {
        let shouldStart = stateLock.withLock { () -> Bool in
            guard listener == nil else {
                return false
            }
            return true
        }
        guard shouldStart else {
            return
        }

        do {
            guard let port = NWEndpoint.Port(rawValue: Self.reachabilityProbePort) else {
                DiagnosticsLog.warn("lan.mac.probe_start_failed invalid_port")
                return
            }
            let nextListener = try NWListener(using: .tcp, on: port)
            stateLock.withLock {
                listener = nextListener
                probeReady = false
            }
            nextListener.stateUpdateHandler = { [weak self, weak nextListener] state in
                guard let self, let nextListener else {
                    return
                }
                switch state {
                case .ready:
                    self.stateLock.withLock {
                        self.probeReady = true
                    }
                    DiagnosticsLog.info("lan.mac.probe_ready port=\(Self.reachabilityProbePort)")
                case .failed(let error):
                    self.stateLock.withLock {
                        self.probeReady = false
                        if self.listener === nextListener {
                            self.listener = nil
                        }
                    }
                    DiagnosticsLog.error("lan.mac.probe_failed port=\(Self.reachabilityProbePort)", error)
                    nextListener.cancel()
                case .cancelled:
                    self.stateLock.withLock {
                        self.probeReady = false
                        if self.listener === nextListener {
                            self.listener = nil
                        }
                    }
                default:
                    break
                }
            }
            nextListener.newConnectionHandler = { [weak self] connection in
                self?.acceptProbe(connection)
            }
            nextListener.start(queue: queue)
        } catch {
            stateLock.withLock {
                listener = nil
                probeReady = false
            }
            DiagnosticsLog.error("lan.mac.probe_start_failed port=\(Self.reachabilityProbePort)", error)
        }
    }

    func stopReachabilityProbe() {
        let activeListener = stateLock.withLock { () -> NWListener? in
            let activeListener = listener
            listener = nil
            probeReady = false
            return activeListener
        }
        activeListener?.cancel()
    }

    private func acceptProbe(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak connection] state in
            guard let connection else {
                return
            }
            switch state {
            case .ready:
                connection.receive(
                    minimumIncompleteLength: Self.probeRequest.count,
                    maximumLength: Self.probeRequest.count
                ) { data, _, _, _ in
                    guard data == Self.probeRequest else {
                        connection.cancel()
                        return
                    }
                    connection.send(
                        content: Self.probeResponse,
                        contentContext: .defaultMessage,
                        isComplete: true,
                        completion: .contentProcessed { _ in
                            connection.cancel()
                        }
                    )
                }
            case .failed, .cancelled:
                connection.stateUpdateHandler = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
    }
}
