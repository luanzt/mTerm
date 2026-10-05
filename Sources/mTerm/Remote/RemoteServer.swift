import Foundation
import Network

@MainActor
protocol RemoteServerDelegate: AnyObject {
    func remoteServer(_ server: RemoteServer, didChangeState state: RemoteServer.State)
    func remoteServer(_ server: RemoteServer, didConnect connection: RemoteServer.ConnectionID)
    func remoteServer(
        _ server: RemoteServer,
        connection: RemoteServer.ConnectionID,
        didReceive message: RemoteClientMessage)
    func remoteServer(_ server: RemoteServer, didDisconnect connection: RemoteServer.ConnectionID)
    /// A congested connection drained; output dropped meanwhile must be
    /// replaced by fresh screens.
    func remoteServer(_ server: RemoteServer, didDrain connection: RemoteServer.ConnectionID)
}

/// WebSocket-over-TLS-PSK listener for paired clients. Network callbacks run
/// on the main queue so message order matches the order PTY output and
/// keyboard input happen in the app.
@MainActor
final class RemoteServer {
    typealias ConnectionID = UUID

    enum State: Equatable {
        case stopped
        case starting
        case ready(port: UInt16)
        case failed(String)
    }

    /// Output is dropped (and later replaced by a screen) above this many
    /// unsent bytes, so a slow link cannot grow memory without bound.
    static let congestionLimit = 8 * 1024 * 1024
    static let drainedLimit = 1024 * 1024

    weak var delegate: RemoteServerDelegate?
    private(set) var state: State = .stopped {
        didSet { delegate?.remoteServer(self, didChangeState: state) }
    }

    private var listener: NWListener?
    private var peers: [ConnectionID: Peer] = [:]

    private final class Peer {
        let connection: NWConnection
        var pendingBytes = 0
        var isCongested = false

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    func start(port: UInt16, key: Data) {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            state = .failed("Invalid port \(port)")
            return
        }
        let listener: NWListener
        do {
            listener = try NWListener(using: RemoteProtocol.parameters(key: key), on: nwPort)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        self.listener = listener
        state = .starting
        listener.stateUpdateHandler = { [weak self, weak listener] newState in
            MainActor.assumeIsolated {
                guard let self, let listener, self.listener === listener else { return }
                switch newState {
                case .ready:
                    self.state = .ready(port: listener.port?.rawValue ?? port)
                case .failed(let error):
                    self.state = .failed(error.localizedDescription)
                    self.stop(keepingState: true)
                case .waiting(let error):
                    // Network.framework keeps retrying (e.g. the port is
                    // busy); report why instead of showing "Starting…".
                    self.state = .failed(error.localizedDescription)
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                self?.accept(connection)
            }
        }
        listener.start(queue: .main)
    }

    func stop() {
        stop(keepingState: false)
    }

    private func stop(keepingState: Bool) {
        listener?.cancel()
        listener = nil
        for id in Array(peers.keys) {
            disconnect(id)
        }
        if !keepingState {
            state = .stopped
        }
    }

    func disconnect(_ id: ConnectionID) {
        guard let peer = peers.removeValue(forKey: id) else { return }
        peer.connection.cancel()
        delegate?.remoteServer(self, didDisconnect: id)
    }

    /// Control messages and screens are never dropped.
    func send(_ message: RemoteServerMessage, to id: ConnectionID) {
        guard let peer = peers[id] else { return }
        transmit(message.encoded(), to: peer, id: id)
    }

    /// Returns false when the connection is congested and the bytes were
    /// dropped; the caller must resend a screen after `didDrain`.
    @discardableResult
    func sendOutput(session: UUID, data: Data, to id: ConnectionID) -> Bool {
        guard let peer = peers[id], !peer.isCongested else { return false }
        transmit(RemoteServerMessage.output(session: session, data: data).encoded(), to: peer, id: id)
        if peer.pendingBytes > Self.congestionLimit {
            peer.isCongested = true
        }
        return true
    }

    private func accept(_ connection: NWConnection) {
        let id = ConnectionID()
        let peer = Peer(connection: connection)
        peers[id] = peer
        connection.stateUpdateHandler = { [weak self] newState in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch newState {
                case .ready:
                    self.delegate?.remoteServer(self, didConnect: id)
                    self.receive(on: connection, id: id)
                case .failed, .cancelled:
                    self.disconnect(id)
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func receive(on connection: NWConnection, id: ConnectionID) {
        connection.receiveMessage { [weak self] content, context, _, error in
            MainActor.assumeIsolated {
                guard let self, self.peers[id] != nil else { return }
                if error != nil {
                    self.disconnect(id)
                    return
                }
                // No message and no error means the peer closed TCP without a
                // WebSocket close frame; re-arming would spin on the main queue.
                guard let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata else {
                    self.disconnect(id)
                    return
                }
                let data = content ?? Data()
                switch metadata.opcode {
                case .text:
                    self.deliver(.text(data), from: id)
                case .binary:
                    self.deliver(.binary(data), from: id)
                case .close:
                    self.disconnect(id)
                    return
                default:
                    break
                }
                guard self.peers[id] != nil else { return }
                self.receive(on: connection, id: id)
            }
        }
    }

    private func deliver(_ frame: RemoteFrame, from id: ConnectionID) {
        guard let message = RemoteClientMessage(frame: frame) else {
            send(.error(code: "bad_message", message: "Unrecognized message"), to: id)
            return
        }
        delegate?.remoteServer(self, connection: id, didReceive: message)
    }

    private func transmit(_ frame: RemoteFrame, to peer: Peer, id: ConnectionID) {
        let data: Data
        let opcode: NWProtocolWebSocket.Opcode
        switch frame {
        case .text(let payload):
            data = payload
            opcode = .text
        case .binary(let payload):
            data = payload
            opcode = .binary
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(identifier: "mterm", metadata: [metadata])
        peer.pendingBytes += data.count
        let size = data.count
        peer.connection.send(
            content: data,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { [weak self] error in
                MainActor.assumeIsolated {
                    guard let self, let peer = self.peers[id] else { return }
                    peer.pendingBytes -= size
                    if error != nil {
                        self.disconnect(id)
                        return
                    }
                    if peer.isCongested, peer.pendingBytes < Self.drainedLimit {
                        peer.isCongested = false
                        self.delegate?.remoteServer(self, didDrain: id)
                    }
                }
            })
    }
}
