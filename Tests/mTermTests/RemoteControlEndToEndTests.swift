import AppKit
import Network
import XCTest
@testable import mTerm

/// Drives the real host stack over loopback: TLS-PSK WebSocket listener,
/// catalog, ownership, grid pinning, and a live shell PTY.
@MainActor
final class RemoteControlEndToEndTests: XCTestCase {
    private final class MemoryKeyStore: RemoteKeyStorage {
        var key: Data?
        func load() -> Data? { key }
        func save(_ key: Data) -> Bool {
            self.key = key
            return true
        }
    }

    /// Minimal client speaking the shared protocol. Used only on the main
    /// queue, where its NWConnection delivers callbacks.
    private final class TestClient: @unchecked Sendable {
        let connection: NWConnection
        var messages: [RemoteServerMessage] = []
        var onMessage: () -> Void = {}

        init(port: UInt16, key: Data) {
            connection = NWConnection(
                to: RemoteProtocol.endpoint(host: "127.0.0.1", port: port),
                using: RemoteProtocol.parameters(key: key))
        }

        func start() {
            connection.start(queue: .main)
            receive()
        }

        func send(_ message: RemoteClientMessage) {
            let (data, opcode): (Data, NWProtocolWebSocket.Opcode) = switch message.encoded() {
            case .text(let data): (data, .text)
            case .binary(let data): (data, .binary)
            }
            let context = NWConnection.ContentContext(
                identifier: "test",
                metadata: [NWProtocolWebSocket.Metadata(opcode: opcode)])
            connection.send(content: data, contentContext: context, isComplete: true,
                            completion: .idempotent)
        }

        private func receive() {
            connection.receiveMessage { [weak self] content, context, _, error in
                guard let self, error == nil else { return }
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata
                let frame: RemoteFrame? = switch metadata?.opcode {
                case .text: .text(content ?? Data())
                case .binary: .binary(content ?? Data())
                default: nil
                }
                if let frame, let message = RemoteServerMessage(frame: frame) {
                    self.messages.append(message)
                    self.onMessage()
                }
                self.receive()
            }
        }
    }

    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "mterm.remote.e2e.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 10,
        _ condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(condition(), "timed out waiting for \(description)")
    }

    private func screens(_ client: TestClient) -> [RemoteScreen] {
        client.messages.compactMap {
            if case .screen(let screen) = $0 { return screen }
            return nil
        }
    }

    private func outputText(_ client: TestClient) -> String {
        client.messages.reduce(into: "") { text, message in
            if case .output(_, let data) = message {
                text += String(decoding: data, as: UTF8.self)
            }
        }
    }

    func testClientOpenResizesPTYAndMacInteractionHandsItBack() throws {
        let port = UInt16.random(in: 40_000...60_000)
        defaults.set(Int(port), forKey: "mterm.remote.port")
        let keyStore = MemoryKeyStore()
        let workspace = WorkspaceStore(defaults: defaults)
        let session = try XCTUnwrap(workspace.sessions.first)
        let control = RemoteControl(defaults: defaults, keyStore: keyStore)
        control.attach(to: workspace)

        let view = FileDroppableTerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 500))
        view.startProcess(executable: "/bin/sh", args: [], environment: ["TERM=xterm-256color", "PS1=$ "])
        defer { view.terminate() }
        control.register(view, for: session.id)
        let macGrid = RemoteGrid(columns: view.getTerminal().cols, rows: view.getTerminal().rows)

        control.setEnabled(true)
        waitUntil("listener ready") { control.serverState == .ready(port: port) }
        let key = try XCTUnwrap(keyStore.key)

        let client = TestClient(port: port, key: key)
        client.start()
        client.send(.hello(name: "Test iPad", version: RemoteProtocol.version, clientID: UUID()))
        waitUntil("catalog") {
            client.messages.contains {
                if case .catalog(_, let sessions) = $0 { return sessions.contains { $0.id == session.id } }
                return false
            }
        }

        let iPadGrid = RemoteGrid(columns: 50, rows: 20)
        client.send(.open(session: session.id, grid: iPadGrid))
        waitUntil("screen at iPad grid") { screens(client).last?.grid == iPadGrid }
        XCTAssertEqual(screens(client).last?.driver, .you)
        XCTAssertEqual(view.getTerminal().cols, 50)
        XCTAssertEqual(view.getTerminal().rows, 20)
        XCTAssertEqual(control.remoteDrivers[session.id], "Test iPad")

        client.send(.input(session: session.id, data: Data("stty size\n".utf8)))
        waitUntil("PTY reports iPad size") { outputText(client).contains("20 50") }

        control.reclaim(session.id)
        waitUntil("screen handed back to Mac") { screens(client).last?.driver == .mac }
        XCTAssertEqual(screens(client).last?.grid, macGrid)
        XCTAssertNil(control.remoteDrivers[session.id])

        // A passive resubscribe must not take the session back.
        let screenCount = screens(client).count
        client.send(.attach(session: session.id, grid: iPadGrid))
        waitUntil("attach screen") { screens(client).count == screenCount + 1 }
        XCTAssertEqual(screens(client).last?.driver, .mac)
        XCTAssertEqual(view.getTerminal().cols, macGrid.columns)

        // Typing does.
        client.send(.input(session: session.id, data: Data("stty size\n".utf8)))
        waitUntil("input reclaims for the client") { screens(client).last?.driver == .you }
        XCTAssertEqual(view.getTerminal().cols, 50)

        client.connection.cancel()
        control.setEnabled(false)
    }

    func testClientWithWrongKeyNeverReachesTheHost() throws {
        let port = UInt16.random(in: 40_000...60_000)
        defaults.set(Int(port), forKey: "mterm.remote.port")
        let control = RemoteControl(defaults: defaults, keyStore: MemoryKeyStore())
        control.attach(to: WorkspaceStore(defaults: defaults))
        control.setEnabled(true)
        waitUntil("listener ready") { control.serverState == .ready(port: port) }

        let intruder = TestClient(port: port, key: RemotePairing.generateKey())
        intruder.start()
        intruder.send(.hello(name: "Intruder", version: RemoteProtocol.version, clientID: UUID()))
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))

        XCTAssertTrue(intruder.messages.isEmpty)
        XCTAssertTrue(control.connectedClientNames.isEmpty)
        intruder.connection.cancel()
        control.setEnabled(false)
    }

    /// A port already held by another socket must surface as a failure with
    /// the reason, not leave Settings at "Starting…".
    func testBusyPortIsReportedInsteadOfStartingForever() throws {
        let port = UInt16.random(in: 40_000...49_000)
        defaults.set(Int(port), forKey: "mterm.remote.port")

        func address(_ port: UInt16) -> sockaddr_in {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            return address
        }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)

        // A loopback peer, then an outgoing connection to it whose local port
        // is the remote-control port.
        let peer = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(peer) }
        var peerAddress = address(0)
        XCTAssertEqual(withUnsafeMutablePointer(to: &peerAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(peer, $0, size) == 0 && listen(peer, 1) == 0
                    && getsockname(peer, $0, &size) == 0
            }
        }, true)
        let outgoing = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(outgoing) }
        var local = address(port)
        XCTAssertEqual(withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(outgoing, $0, size) }
        }, 0)
        XCTAssertEqual(withUnsafePointer(to: &peerAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(outgoing, $0, size) }
        }, 0)

        let control = RemoteControl(defaults: defaults, keyStore: MemoryKeyStore())
        control.attach(to: WorkspaceStore(defaults: defaults))
        control.setEnabled(true)
        waitUntil("failure reported") {
            if case .failed = control.serverState { return true }
            return false
        }
        control.setEnabled(false)
    }

    /// Ports in the ephemeral range can be taken by any app's outgoing
    /// connection at launch, which blocks the listener (EADDRINUSE).
    func testDefaultPortIsOutsideTheEphemeralRange() {
        func sysctlInt(_ name: String) -> Int {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            XCTAssertEqual(sysctlbyname(name, &value, &size, nil, 0), 0)
            return Int(value)
        }
        let ephemeral = sysctlInt("net.inet.ip.portrange.first")...sysctlInt("net.inet.ip.portrange.last")
        XCTAssertFalse(ephemeral.contains(Int(RemoteProtocol.defaultPort)))
    }

    func testMacSideResizeSendsScreenAndDisablingReleasesPins() throws {
        let port = UInt16.random(in: 40_000...60_000)
        defaults.set(Int(port), forKey: "mterm.remote.port")
        let keyStore = MemoryKeyStore()
        let workspace = WorkspaceStore(defaults: defaults)
        let session = try XCTUnwrap(workspace.sessions.first)
        let control = RemoteControl(defaults: defaults, keyStore: keyStore)
        control.attach(to: workspace)
        let view = FileDroppableTerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 500))
        control.register(view, for: session.id)
        control.setEnabled(true)
        waitUntil("listener ready") { control.serverState == .ready(port: port) }

        let client = TestClient(port: port, key: try XCTUnwrap(keyStore.key))
        client.start()
        client.send(.hello(name: "Test iPad", version: RemoteProtocol.version, clientID: UUID()))
        let iPadGrid = RemoteGrid(columns: 50, rows: 20)
        client.send(.attach(session: session.id, grid: iPadGrid))
        waitUntil("passive screen") { screens(client).last?.driver == .mac }

        // The Mac pane shrinks while the Mac drives (split, divider drag…).
        view.setFrameSize(NSSize(width: 450, height: 300))
        let shrunk = RemoteGrid(columns: view.getTerminal().cols, rows: view.getTerminal().rows)
        waitUntil("screen at the new Mac grid") { screens(client).last?.grid == shrunk }
        XCTAssertEqual(screens(client).last?.driver, .mac)

        client.send(.open(session: session.id, grid: iPadGrid))
        waitUntil("client drives") { screens(client).last?.driver == .you }
        control.setEnabled(false)

        XCTAssertNil(view.pinnedGrid)
        XCTAssertEqual(view.getTerminal().cols, shrunk.columns)
        XCTAssertTrue(control.remoteDrivers.isEmpty)
    }

    func testClientCreatedTerminalStartsAtClientGridWithoutTouchingPaneGrid() throws {
        let port = UInt16.random(in: 40_000...49_000)
        defaults.set(Int(port), forKey: "mterm.remote.port")
        let keyStore = MemoryKeyStore()
        let workspace = WorkspaceStore(defaults: defaults)
        let gridBefore = workspace.grid
        let control = RemoteControl(defaults: defaults, keyStore: keyStore)
        control.attach(to: workspace)
        control.setEnabled(true)
        waitUntil("listener ready") { control.serverState == .ready(port: port) }

        let client = TestClient(port: port, key: try XCTUnwrap(keyStore.key))
        client.start()
        client.send(.hello(name: "Test iPad", version: RemoteProtocol.version, clientID: UUID()))
        waitUntil("welcome") { !client.messages.isEmpty }

        let created = UUID()
        let grid = RemoteGrid(columns: 60, rows: 18)
        client.send(.create(session: created, workspaceID: nil, grid: grid))
        waitUntil("catalog with created session") {
            client.messages.contains {
                if case .catalog(_, let sessions) = $0 { return sessions.contains { $0.id == created } }
                return false
            }
        }
        XCTAssertEqual(workspace.grid, gridBefore, "a remote terminal must not change the Mac panes")
        XCTAssertEqual(control.remoteDrivers[created], "Test iPad")

        // What TerminalHostView does once SwiftUI renders the new session.
        let view = FileDroppableTerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 500))
        control.register(view, for: created)
        XCTAssertEqual(view.getTerminal().cols, 60)
        XCTAssertEqual(view.getTerminal().rows, 18)
        view.startProcess(executable: "/bin/sh", args: [], environment: ["TERM=xterm-256color", "PS1=$ "])
        defer { view.terminate() }
        waitUntil("screen for created session") {
            screens(client).contains { $0.session == created && $0.grid == grid && $0.driver == .you }
        }

        client.send(.input(session: created, data: Data("stty size\n".utf8)))
        waitUntil("shell started at client size") { outputText(client).contains("18 60") }

        let unknownWorkspace = UUID()
        client.send(.create(session: UUID(), workspaceID: unknownWorkspace, grid: grid))
        waitUntil("unknown workspace rejected") {
            client.messages.contains { if case .error(let code, _) = $0 { return code == "create_failed" }; return false }
        }

        client.connection.cancel()
        control.setEnabled(false)
    }
}
