import CryptoKit
import EdgeLinkKit
import Foundation
import Network

final class LoopbackEndpoint: ByteChannel, @unchecked Sendable {
    private let incoming: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let peer: () -> LoopbackEndpoint?

    init(peer: @escaping () -> LoopbackEndpoint?) {
        var continuation: AsyncStream<Data>.Continuation!
        incoming = AsyncStream { continuation = $0 }
        self.continuation = continuation
        self.peer = peer
    }

    func send(_ bytes: Data) async throws {
        guard let peer = peer() else {
            throw LoopbackChannelError.closed
        }
        peer.deliver(bytes)
    }

    func receive() async throws -> Data? {
        for await data in incoming {
            return data
        }
        return nil
    }

    func close() {
        continuation.finish()
    }

    fileprivate func deliver(_ data: Data) {
        continuation.yield(data)
    }
}

enum LoopbackChannelError: Error {
    case closed
}

final class LoopbackChannelPair {
    let hostSide: LoopbackEndpoint
    let clientSide: LoopbackEndpoint

    init() {
        var host: LoopbackEndpoint!
        var client: LoopbackEndpoint!
        host = LoopbackEndpoint { client }
        client = LoopbackEndpoint { host }
        hostSide = host
        clientSide = client
    }
}

func makeRelayTestIdentity(deviceId: String, name: String) -> LocalIdentity {
    LocalIdentity(
        deviceId: deviceId,
        name: name,
        signingKey: Curve25519.Signing.PrivateKey()
    )
}

final class TCPEchoServer: @unchecked Sendable {
    private var listener: NWListener?

    func start() throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters)
        self.listener = listener

        listener.newConnectionHandler = { connection in
            connection.start(queue: .global(qos: .userInitiated))
            Self.echo(on: connection)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var boundPort: UInt16?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                boundPort = listener.port?.rawValue
                semaphore.signal()
            case .failed, .cancelled:
                semaphore.signal()
            default:
                break
            }
        }
        listener.start(queue: .global(qos: .userInitiated))

        guard semaphore.wait(timeout: .now() + 5) == .success, let boundPort else {
            listener.cancel()
            throw TCPEchoServerError.startFailed
        }
        return boundPort
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private static func echo(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                connection.send(content: data, completion: .contentProcessed { _ in
                    echo(on: connection)
                })
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            echo(on: connection)
        }
    }
}

enum TCPEchoServerError: Error {
    case startFailed
}
