// Wire protocol shared by the mTerm macOS host and the mterm-app iPad client.
//
// Keep this file byte-identical in both repositories:
//   mTerm:      Sources/mTerm/Remote/RemoteProtocol.swift
//   mterm-app:  Packages/MTermRemoteKit/Sources/MTermRemoteKit/RemoteProtocol.swift
// Bump `RemoteProtocol.version` for any incompatible wire change.
//
// Transport: WebSocket over TLS 1.2 PSK (Network.framework). The pre-shared
// key comes from the pairing link, so only paired clients complete the TLS
// handshake. Control messages are JSON text frames; terminal bytes travel in
// binary frames:
//
//   output (host → client):  0x01 | session UUID (16) | PTY bytes
//   screen (host → client):  0x02 | session UUID (16) | columns u16 BE |
//                            rows u16 BE | driver u8 | terminal bytes
//   input  (client → host):  0x10 | session UUID (16) | keyboard bytes
//   upload (client → host):  0x11 | session UUID (16) | upload UUID (16) |
//                            name length u16 BE | name UTF-8 | file bytes
//
// A `screen` frame replaces the client's emulator state: reset, resize to the
// carried grid, feed the bytes. Every geometry or driver change produces one,
// ordered with the output stream, so the client grid always equals the PTY.

import CryptoKit
import Foundation
import Network
import Security

public enum RemoteProtocol {
    /// v3: `commands` and `upload`, which a v2 Mac rejects as unrecognized,
    /// leaving the composer's menu empty and its uploads spinning.
    public static let version = 3
    /// Below macOS's ephemeral range (49152–65535): any app's outgoing
    /// connection can hold an ephemeral port and block the listener's bind.
    public static let defaultPort: UInt16 = 47_741
    public static let pairingScheme = "mterm"
    public static let columnRange = 20...1024
    public static let rowRange = 8...300
    /// Largest keyboard/paste payload accepted in one input frame.
    public static let maxInputBytes = 256 * 1024
    /// Largest file a client may attach to a prompt in one upload frame.
    public static let maxUploadBytes = 20 * 1024 * 1024
    /// Longest UTF-8 file name an upload frame carries.
    public static let maxUploadNameBytes = 255

    /// Client endpoint for `parameters(key:)`. The WebSocket client handshake
    /// needs a URL endpoint; a bare host/port endpoint aborts the connection.
    public static func endpoint(host: String, port: UInt16) -> NWEndpoint {
        let authority = host.contains(":") ? "[\(host)]" : host
        return .url(URL(string: "wss://\(authority):\(port)/")!)
    }

    /// TLS 1.2 PSK + WebSocket parameters for both the listener and the client.
    public static func parameters(key: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let derived = HMAC<SHA256>.authenticationCode(
            for: Data("mterm-remote-psk-v1".utf8),
            using: SymmetricKey(data: key))
        let psk = derived.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("mterm-remote".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(
            tls.securityProtocolOptions,
            psk as __DispatchData,
            identity as __DispatchData)
        if let suite = tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256)) {
            sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, suite)
        }
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10

        let parameters = NWParameters(tls: tls, tcp: tcp)
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        webSocket.maximumMessageSize = 32 * 1024 * 1024
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        return parameters
    }
}

// MARK: - Model

public struct RemoteGrid: Codable, Hashable, Sendable {
    public let columns: Int
    public let rows: Int

    /// Clamps to the protocol limits so every producer and validator agrees.
    public init(columns: Int, rows: Int) {
        self.columns = min(max(columns, RemoteProtocol.columnRange.lowerBound),
                           RemoteProtocol.columnRange.upperBound)
        self.rows = min(max(rows, RemoteProtocol.rowRange.lowerBound),
                        RemoteProtocol.rowRange.upperBound)
    }
}

public enum RemoteAgent: String, Codable, Sendable {
    case claude
    case codex
    case omp
}

public struct RemoteWorkspace: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

public struct RemoteSession: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    /// `nil` for terminals that do not belong to a workspace folder.
    public let workspaceID: UUID?
    public let workingDirectory: String
    public let agent: RemoteAgent?
    public let isWorking: Bool
    public let isExited: Bool
    /// The agent is waiting on the user: an OMP ask or approval prompt. Read
    /// as false when absent, so either side may predate it.
    public let isAwaitingInput: Bool

    public init(
        id: UUID,
        title: String,
        workspaceID: UUID?,
        workingDirectory: String,
        agent: RemoteAgent?,
        isWorking: Bool,
        isExited: Bool,
        isAwaitingInput: Bool = false
    ) {
        self.id = id
        self.title = title
        self.workspaceID = workspaceID
        self.workingDirectory = workingDirectory
        self.agent = agent
        self.isWorking = isWorking
        self.isExited = isExited
        self.isAwaitingInput = isAwaitingInput
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, workspaceID, workingDirectory, agent, isWorking, isExited, isAwaitingInput
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        workspaceID = try container.decodeIfPresent(UUID.self, forKey: .workspaceID)
        workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
        agent = try container.decodeIfPresent(RemoteAgent.self, forKey: .agent)
        isWorking = try container.decode(Bool.self, forKey: .isWorking)
        isExited = try container.decode(Bool.self, forKey: .isExited)
        isAwaitingInput = try container.decodeIfPresent(Bool.self, forKey: .isAwaitingInput) ?? false
    }
}

/// One entry of an agent's `/` menu: a built-in command or a skill found on
/// the Mac for the session's agent and working directory.
public struct RemoteCommand: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case command
        case skill
    }

    /// What follows the `/` when typed: `compact`, `skill:writing-plans`,
    /// `superpowers:brainstorming`.
    public let name: String
    public let description: String
    public let kind: Kind
    /// Where it was found, for display: "Built-in", "Project", "User", a plugin.
    public let source: String
    /// Its arguments, as the agent shows them: `[on|off|status]`. Optional on
    /// the wire, so either side may predate it.
    public let hint: String?

    public init(name: String, description: String, kind: Kind, source: String, hint: String? = nil) {
        self.name = name
        self.description = description
        self.kind = kind
        self.source = source
        self.hint = hint
    }
}

/// Who currently decides the PTY size of a session, from the receiving
/// client's point of view.
public enum RemoteDriver: UInt8, Sendable {
    case mac = 0
    case you = 1
    case otherClient = 2
}

public struct RemoteScreen: Equatable, Sendable {
    public let session: UUID
    public let grid: RemoteGrid
    public let driver: RemoteDriver
    public let data: Data

    public init(session: UUID, grid: RemoteGrid, driver: RemoteDriver, data: Data) {
        self.session = session
        self.grid = grid
        self.driver = driver
        self.data = data
    }
}

// MARK: - Messages

public enum RemoteFrame: Equatable, Sendable {
    case text(Data)
    case binary(Data)
}

public enum RemoteClientMessage: Equatable, Sendable {
    /// `clientID` is stable per install so a reconnecting client keeps the
    /// size claims it held before the connection dropped.
    case hello(name: String, version: Int, clientID: UUID)
    /// The user opened this session on the client: it claims the PTY size.
    case open(session: UUID, grid: RemoteGrid)
    /// Passive subscribe (reconnect, app resume). Streams the session without
    /// claiming it; the grid is applied only if this client already drives it.
    case attach(session: UUID, grid: RemoteGrid)
    /// Stop streaming this session. Does not release the size claim.
    case close(session: UUID)
    /// The client's terminal area changed size. Applied only while it drives.
    case viewport(session: UUID, grid: RemoteGrid)
    /// Explicit "take control" action.
    case claim(session: UUID)
    /// Start a new terminal in `workspaceID` (`nil` = no workspace) with the
    /// client-chosen `session` ID. The client opens it: the shell starts at
    /// `grid` and the session is driven by this client.
    case create(session: UUID, workspaceID: UUID?, grid: RemoteGrid)
    /// Keyboard bytes. Input is a real action: the host claims the session
    /// for this client before writing the bytes to the PTY.
    case input(session: UUID, data: Data)
    /// Ask for the session's `/` menu. The host answers with `commands`.
    case commands(session: UUID)
    /// A file to attach to the next prompt. The host stores it and answers
    /// `uploaded` with its path on the Mac, or `uploadFailed`.
    case upload(session: UUID, id: UUID, name: String, data: Data)

    public func encoded() -> RemoteFrame {
        switch self {
        case .hello(let name, let version, let clientID):
            return .text(ControlEnvelope(
                type: "hello", version: version, name: name, client: clientID).json())
        case .open(let session, let grid):
            return .text(ControlEnvelope(
                type: "open", session: session,
                columns: grid.columns, rows: grid.rows).json())
        case .attach(let session, let grid):
            return .text(ControlEnvelope(
                type: "attach", session: session,
                columns: grid.columns, rows: grid.rows).json())
        case .close(let session):
            return .text(ControlEnvelope(type: "close", session: session).json())
        case .viewport(let session, let grid):
            return .text(ControlEnvelope(
                type: "viewport", session: session,
                columns: grid.columns, rows: grid.rows).json())
        case .claim(let session):
            return .text(ControlEnvelope(type: "claim", session: session).json())
        case .create(let session, let workspaceID, let grid):
            return .text(ControlEnvelope(
                type: "create", session: session,
                columns: grid.columns, rows: grid.rows, workspace: workspaceID).json())
        case .input(let session, let data):
            return .binary(BinaryFrame.encode(kind: BinaryFrame.input, session: session, payload: data))
        case .commands(let session):
            return .text(ControlEnvelope(type: "commands", session: session).json())
        case .upload(let session, let id, let name, let data):
            let nameBytes = Array(name.utf8.prefix(RemoteProtocol.maxUploadNameBytes))
            var payload = Data(capacity: 18 + nameBytes.count + data.count)
            withUnsafeBytes(of: id.uuid) { payload.append(contentsOf: $0) }
            payload.append(UInt8(nameBytes.count >> 8))
            payload.append(UInt8(nameBytes.count & 0xFF))
            payload.append(contentsOf: nameBytes)
            payload.append(data)
            return .binary(BinaryFrame.encode(kind: BinaryFrame.upload, session: session, payload: payload))
        }
    }

    public init?(frame: RemoteFrame) {
        switch frame {
        case .binary(let data):
            guard let (kind, session, payload) = BinaryFrame.decode(data) else { return nil }
            switch kind {
            case BinaryFrame.input:
                guard payload.count <= RemoteProtocol.maxInputBytes else { return nil }
                self = .input(session: session, data: payload)
            case BinaryFrame.upload:
                let bytes = [UInt8](payload.prefix(18))
                guard bytes.count == 18 else { return nil }
                let nameLength = Int(bytes[16]) << 8 | Int(bytes[17])
                guard (1...RemoteProtocol.maxUploadNameBytes).contains(nameLength),
                      payload.count >= 18 + nameLength,
                      payload.count - 18 - nameLength <= RemoteProtocol.maxUploadBytes else { return nil }
                let id = UUID(uuid: (
                    bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                    bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
                let body = payload.dropFirst(18)
                self = .upload(
                    session: session,
                    id: id,
                    name: String(decoding: body.prefix(nameLength), as: UTF8.self),
                    data: Data(body.dropFirst(nameLength)))
            default:
                return nil
            }
        case .text(let data):
            guard let envelope = ControlEnvelope.decode(data) else { return nil }
            switch envelope.type {
            case "hello":
                guard let version = envelope.version, let clientID = envelope.client else { return nil }
                self = .hello(name: envelope.name ?? "", version: version, clientID: clientID)
            case "open":
                guard let session = envelope.session, let grid = envelope.grid else { return nil }
                self = .open(session: session, grid: grid)
            case "attach":
                guard let session = envelope.session, let grid = envelope.grid else { return nil }
                self = .attach(session: session, grid: grid)
            case "close":
                guard let session = envelope.session else { return nil }
                self = .close(session: session)
            case "viewport":
                guard let session = envelope.session, let grid = envelope.grid else { return nil }
                self = .viewport(session: session, grid: grid)
            case "claim":
                guard let session = envelope.session else { return nil }
                self = .claim(session: session)
            case "create":
                guard let session = envelope.session, let grid = envelope.grid else { return nil }
                self = .create(session: session, workspaceID: envelope.workspace, grid: grid)
            case "commands":
                guard let session = envelope.session else { return nil }
                self = .commands(session: session)
            default:
                return nil
            }
        }
    }
}

public enum RemoteServerMessage: Equatable, Sendable {
    case welcome(name: String, version: Int)
    case catalog(workspaces: [RemoteWorkspace], sessions: [RemoteSession])
    case screen(RemoteScreen)
    case output(session: UUID, data: Data)
    /// The session ended or was removed on the Mac.
    case closed(session: UUID)
    case error(code: String, message: String)
    /// Reply to the client's `commands`: built-ins first, then skills.
    case commands(session: UUID, commands: [RemoteCommand])
    /// The upload `id` is stored on the Mac at `path`.
    case uploaded(id: UUID, path: String)
    case uploadFailed(id: UUID, message: String)

    public func encoded() -> RemoteFrame {
        switch self {
        case .welcome(let name, let version):
            return .text(ControlEnvelope(type: "welcome", version: version, name: name).json())
        case .catalog(let workspaces, let sessions):
            return .text(ControlEnvelope(
                type: "catalog", workspaces: workspaces, sessions: sessions).json())
        case .screen(let screen):
            var payload = Data(capacity: screen.data.count + 5)
            payload.append(UInt8(screen.grid.columns >> 8))
            payload.append(UInt8(screen.grid.columns & 0xFF))
            payload.append(UInt8(screen.grid.rows >> 8))
            payload.append(UInt8(screen.grid.rows & 0xFF))
            payload.append(screen.driver.rawValue)
            payload.append(screen.data)
            return .binary(BinaryFrame.encode(
                kind: BinaryFrame.screen, session: screen.session, payload: payload))
        case .output(let session, let data):
            return .binary(BinaryFrame.encode(kind: BinaryFrame.output, session: session, payload: data))
        case .closed(let session):
            return .text(ControlEnvelope(type: "closed", session: session).json())
        case .error(let code, let message):
            return .text(ControlEnvelope(type: "error", code: code, message: message).json())
        case .commands(let session, let commands):
            return .text(ControlEnvelope(type: "commands", session: session, commands: commands).json())
        case .uploaded(let id, let path):
            return .text(ControlEnvelope(type: "uploaded", upload: id, path: path).json())
        case .uploadFailed(let id, let message):
            return .text(ControlEnvelope(type: "upload_failed", message: message, upload: id).json())
        }
    }

    public init?(frame: RemoteFrame) {
        switch frame {
        case .binary(let data):
            guard let (kind, session, payload) = BinaryFrame.decode(data) else { return nil }
            switch kind {
            case BinaryFrame.output:
                self = .output(session: session, data: payload)
            case BinaryFrame.screen:
                guard payload.count >= 5 else { return nil }
                let bytes = [UInt8](payload.prefix(5))
                guard let driver = RemoteDriver(rawValue: bytes[4]) else { return nil }
                let grid = RemoteGrid(
                    columns: Int(bytes[0]) << 8 | Int(bytes[1]),
                    rows: Int(bytes[2]) << 8 | Int(bytes[3]))
                self = .screen(RemoteScreen(
                    session: session, grid: grid, driver: driver,
                    data: Data(payload.dropFirst(5))))
            default:
                return nil
            }
        case .text(let data):
            guard let envelope = ControlEnvelope.decode(data) else { return nil }
            switch envelope.type {
            case "welcome":
                guard let version = envelope.version else { return nil }
                self = .welcome(name: envelope.name ?? "", version: version)
            case "catalog":
                self = .catalog(
                    workspaces: envelope.workspaces ?? [],
                    sessions: envelope.sessions ?? [])
            case "closed":
                guard let session = envelope.session else { return nil }
                self = .closed(session: session)
            case "error":
                self = .error(code: envelope.code ?? "unknown", message: envelope.message ?? "")
            case "commands":
                guard let session = envelope.session else { return nil }
                self = .commands(session: session, commands: envelope.commands ?? [])
            case "uploaded":
                guard let id = envelope.upload, let path = envelope.path else { return nil }
                self = .uploaded(id: id, path: path)
            case "upload_failed":
                guard let id = envelope.upload else { return nil }
                self = .uploadFailed(id: id, message: envelope.message ?? "")
            default:
                return nil
            }
        }
    }
}

private struct ControlEnvelope: Codable {
    var type: String
    var version: Int?
    var name: String?
    var client: UUID?
    var session: UUID?
    var columns: Int?
    var rows: Int?
    var workspace: UUID?
    var workspaces: [RemoteWorkspace]?
    var sessions: [RemoteSession]?
    var commands: [RemoteCommand]?
    var code: String?
    var message: String?
    var upload: UUID?
    var path: String?

    var grid: RemoteGrid? {
        guard let columns, let rows else { return nil }
        return RemoteGrid(columns: columns, rows: rows)
    }

    func json() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data(#"{"type":"invalid"}"#.utf8)
    }

    static func decode(_ data: Data) -> ControlEnvelope? {
        try? JSONDecoder().decode(ControlEnvelope.self, from: data)
    }
}

private enum BinaryFrame {
    static let output: UInt8 = 0x01
    static let screen: UInt8 = 0x02
    static let input: UInt8 = 0x10
    static let upload: UInt8 = 0x11

    static func encode(kind: UInt8, session: UUID, payload: Data) -> Data {
        var data = Data(capacity: 17 + payload.count)
        data.append(kind)
        withUnsafeBytes(of: session.uuid) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    static func decode(_ data: Data) -> (UInt8, UUID, Data)? {
        guard data.count >= 17 else { return nil }
        let bytes = [UInt8](data.prefix(17))
        let session = UUID(uuid: (
            bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8],
            bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15], bytes[16]))
        return (bytes[0], session, Data(data.dropFirst(17)))
    }
}

// MARK: - Pairing

/// Everything a client needs to reach and authenticate with one Mac. Shared
/// as `mterm://pair?…`; the key never leaves the link or the Keychain.
public struct RemotePairing: Codable, Equatable, Sendable {
    public let name: String
    /// Candidate addresses in preference order (Bonjour host name, LAN and
    /// Tailscale IPs). Clients try each until one connects.
    public let hosts: [String]
    public let port: UInt16
    public let key: Data

    public init(name: String, hosts: [String], port: UInt16, key: Data) {
        self.name = name
        self.hosts = hosts
        self.port = port
        self.key = key
    }

    public static func generateKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = RemoteProtocol.pairingScheme
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: String(RemoteProtocol.version)),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "hosts", value: hosts.joined(separator: ",")),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "key", value: Self.base64URL(key)),
        ]
        return components.url!
    }

    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == RemoteProtocol.pairingScheme,
              components.host == "pair" else { return nil }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            values[item.name] = item.value
        }
        guard values["v"] == String(RemoteProtocol.version),
              let name = values["name"],
              let hostList = values["hosts"],
              let portText = values["port"], let port = UInt16(portText), port > 0,
              let keyText = values["key"], let key = Self.data(base64URL: keyText),
              key.count == 32 else { return nil }
        let hosts = hostList.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        guard !hosts.isEmpty else { return nil }
        self.init(name: name, hosts: hosts, port: port, key: key)
    }

    /// Accepts a pasted link with surrounding whitespace or text.
    public init?(text: String) {
        guard let range = text.range(of: "\(RemoteProtocol.pairingScheme)://pair?") else { return nil }
        let link = text[range.lowerBound...].prefix { !$0.isWhitespace }
        guard let url = URL(string: String(link)) else { return nil }
        self.init(url: url)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func data(base64URL text: String) -> Data? {
        var base64 = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64)
    }
}
