import Combine
import Foundation
import SwiftTerm

/// Connects paired remote clients to the live terminal sessions: publishes the
/// session catalog, streams PTY output, pins a session's grid while a client
/// drives it, and hands it back when the Mac user interacts with the pane.
@MainActor
final class RemoteControl: ObservableObject, RemoteServerDelegate {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var serverState: RemoteServer.State = .stopped
    @Published private(set) var connectedClientNames: [String] = []
    /// Sessions currently sized by a remote client, mapped to its name.
    @Published private(set) var remoteDrivers: [SessionRecord.ID: String] = [:]
    @Published private(set) var pairing: RemotePairing?

    private static let enabledKey = "mterm.remote.enabled"
    private static let portKey = "mterm.remote.port"

    private let defaults: UserDefaults
    private let keyStore: RemoteKeyStorage
    private let server = RemoteServer()
    private let attachments: RemoteAttachmentStore
    private var ownership = RemoteOwnership()
    private var terminals: [SessionRecord.ID: WeakTerminal] = [:]
    private var clients: [RemoteServer.ConnectionID: Client] = [:]
    private var clientNames: [UUID: String] = [:]
    private var pendingOutput: [SessionRecord.ID: Data] = [:]
    private var isFlushScheduled = false
    /// Pending screens for Mac-side grid changes, coalesced per session.
    private var gridScreenTasks: [SessionRecord.ID: DispatchWorkItem] = [:]
    /// Set while an ownership effect pins/unpins a view; that path sends its
    /// own screen, so the resulting grid change must not schedule another.
    private var applyingOwnershipFor: SessionRecord.ID?
    private var lastCatalog: (workspaces: [RemoteWorkspace], sessions: [RemoteSession])?
    private weak var workspace: WorkspaceStore?
    private var workspaceObservation: AnyCancellable?

    private struct WeakTerminal {
        weak var view: FileDroppableTerminalView?
    }

    private struct Client {
        var clientID: UUID?
        var name = ""
        var sessions: Set<SessionRecord.ID> = []
        /// Sessions whose output was dropped while the link was congested.
        var staleSessions: Set<SessionRecord.ID> = []
    }

    var port: UInt16 {
        let stored = defaults.integer(forKey: Self.portKey)
        return (1...Int(UInt16.max)).contains(stored) ? UInt16(stored) : RemoteProtocol.defaultPort
    }

    init(
        defaults: UserDefaults = .standard,
        keyStore: RemoteKeyStorage = RemoteKeyStore(),
        attachments: RemoteAttachmentStore = RemoteAttachmentStore()
    ) {
        self.defaults = defaults
        self.keyStore = keyStore
        self.attachments = attachments
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        server.delegate = self
    }

    func attach(to workspace: WorkspaceStore) {
        self.workspace = workspace
        workspaceObservation = workspace.objectWillChange
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.publishCatalogIfChanged() }
            }
        if isEnabled {
            startServer()
        }
    }

    // MARK: Settings

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled {
            startServer()
        } else {
            server.stop()
            pairing = nil
            releaseRemoteDrivers()
        }
    }

    /// Invalidates every paired client: they must paste the new link.
    func regenerateKey() {
        keyStore.save(RemotePairing.generateKey())
        // Old clients can never reconnect to refit or release their sessions.
        releaseRemoteDrivers()
        if isEnabled {
            startServer()
        }
    }

    private func releaseRemoteDrivers() {
        for (session, driver) in ownership.drivers {
            if case .client = driver {
                apply(ownership.macInteraction(session: session), to: session)
            }
        }
    }

    /// Recomputes host addresses (network changes) without touching the key.
    func refreshPairing() {
        guard isEnabled, let key = keyStore.load() else { return }
        pairing = RemotePairing(
            name: Host.current().localizedName ?? "Mac",
            hosts: RemoteHostAddresses.current(),
            port: port,
            key: key)
    }

    private func startServer() {
        let key: Data
        if let stored = keyStore.load(), stored.count == 32 {
            key = stored
        } else {
            key = RemotePairing.generateKey()
            keyStore.save(key)
        }
        server.start(port: port, key: key)
        refreshPairing()
        let attachments = attachments
        DispatchQueue.global(qos: .utility).async { attachments.removeExpired() }
    }

    /// Pane banner action: same as typing in the pane.
    func reclaim(_ session: SessionRecord.ID) {
        apply(ownership.macInteraction(session: session), to: session)
    }

    // MARK: Terminal registry

    func register(_ view: FileDroppableTerminalView, for session: SessionRecord.ID) {
        terminals[session] = WeakTerminal(view: view)
        view.onOutput = { [weak self] bytes in
            MainActor.assumeIsolated {
                self?.enqueueOutput(bytes, for: session)
            }
        }
        view.onLocalInteraction = { [weak self] in
            MainActor.assumeIsolated {
                self?.reclaim(session)
            }
        }
        view.onGridChange = { [weak self] in
            MainActor.assumeIsolated {
                self?.gridDidChange(session)
            }
        }
        if case .client(_, let grid) = ownership.driver(of: session) {
            view.pinnedGrid = grid
        }
        // A client that created this session is already subscribed; its first
        // screen can only be sent once the terminal view exists.
        if clients.values.contains(where: { $0.sessions.contains(session) }) {
            broadcastScreen(session)
        }
    }

    func unregister(_ view: FileDroppableTerminalView, for session: SessionRecord.ID) {
        guard terminals[session]?.view === view else { return }
        terminals[session] = nil
        pendingOutput[session] = nil
    }

    private func terminal(for session: SessionRecord.ID) -> FileDroppableTerminalView? {
        terminals[session]?.view
    }

    // MARK: Output

    private func enqueueOutput(_ bytes: ArraySlice<UInt8>, for session: SessionRecord.ID) {
        guard clients.values.contains(where: { $0.sessions.contains(session) }) else { return }
        pendingOutput[session, default: Data()].append(contentsOf: bytes)
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.flushAllOutput() }
        }
    }

    private func flushAllOutput() {
        isFlushScheduled = false
        for session in Array(pendingOutput.keys) {
            flushOutput(session)
        }
    }

    /// Sends buffered output before any screen for the same session so the
    /// stream stays in PTY order.
    private func flushOutput(_ session: SessionRecord.ID) {
        guard let data = pendingOutput.removeValue(forKey: session), !data.isEmpty else { return }
        for (id, client) in clients where client.sessions.contains(session) {
            if !server.sendOutput(session: session, data: data, to: id) {
                clients[id]?.staleSessions.insert(session)
            }
        }
    }

    // MARK: Ownership

    private func apply(_ effect: RemoteOwnership.Effect, to session: SessionRecord.ID) {
        let view = terminal(for: session)
        applyingOwnershipFor = session
        defer { applyingOwnershipFor = nil }
        switch effect {
        case .none:
            return
        case .pin(let grid):
            flushOutput(session)
            view?.pinnedGrid = grid
        case .release:
            flushOutput(session)
            view?.pinnedGrid = nil
        }
        updateRemoteDrivers()
        gridScreenTasks.removeValue(forKey: session)?.cancel()
        broadcastScreen(session)
    }

    /// The Mac's own layout (pane split, divider drag, window resize, font)
    /// changed the grid. Watchers need a screen at the new size; debounce so a
    /// drag sends one snapshot instead of one per frame.
    private func gridDidChange(_ session: SessionRecord.ID) {
        guard applyingOwnershipFor != session,
              clients.values.contains(where: { $0.sessions.contains(session) }) else { return }
        gridScreenTasks[session]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.gridScreenTasks[session] = nil
                self?.broadcastScreen(session)
            }
        }
        gridScreenTasks[session] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func updateRemoteDrivers() {
        var drivers: [SessionRecord.ID: String] = [:]
        for (session, driver) in ownership.drivers {
            if case .client(let clientID, _) = driver {
                drivers[session] = clientNames[clientID] ?? "remote device"
            }
        }
        if drivers != remoteDrivers {
            remoteDrivers = drivers
        }
    }

    private func broadcastScreen(_ session: SessionRecord.ID) {
        for (id, client) in clients where client.sessions.contains(session) {
            sendScreen(session, to: id)
        }
    }

    private func sendScreen(_ session: SessionRecord.ID, to id: RemoteServer.ConnectionID) {
        guard let view = terminal(for: session), let client = clients[id] else { return }
        flushOutput(session)
        let terminal = view.getTerminal()
        let driver: RemoteDriver
        switch ownership.driver(of: session) {
        case .mac:
            driver = .mac
        case .client(let clientID, _):
            driver = clientID == client.clientID ? .you : .otherClient
        }
        let screen = RemoteScreen(
            session: session,
            grid: RemoteGrid(columns: terminal.cols, rows: terminal.rows),
            driver: driver,
            data: RemoteScreenSnapshot.capture(
                terminal,
                isCursorHidden: view.isCursorHidden,
                normalCursor: view.normalCursorAtAlternateSwitch))
        clients[id]?.staleSessions.remove(session)
        server.send(.screen(screen), to: id)
    }

    // MARK: Catalog

    private func currentCatalog() -> (workspaces: [RemoteWorkspace], sessions: [RemoteSession]) {
        guard let workspace else { return ([], []) }
        let workspaces = workspace.workspaces.map { RemoteWorkspace(id: $0.id, name: $0.name) }
        let sessions = workspace.sessions.map { session -> RemoteSession in
            let agent: RemoteAgent?
            if workspace.claudeSessionIDs.contains(session.id) {
                agent = .claude
            } else if workspace.codexSessionIDs.contains(session.id) {
                agent = .codex
            } else if workspace.ompSessionIDs.contains(session.id) {
                agent = .omp
            } else {
                agent = nil
            }
            return RemoteSession(
                id: session.id,
                title: workspace.displayTitle(for: session),
                workspaceID: session.workspaceID,
                workingDirectory: session.workingDirectory,
                agent: agent,
                isWorking: workspace.agentWorkingSessionIDs.contains(session.id),
                isExited: session.status == .exited,
                isAwaitingInput: workspace.agentAwaitingSessionIDs.contains(session.id))
        }
        return (workspaces, sessions)
    }

    private func publishCatalogIfChanged() {
        let catalog = currentCatalog()
        if let lastCatalog,
           lastCatalog.workspaces == catalog.workspaces,
           lastCatalog.sessions == catalog.sessions {
            return
        }
        let removed = Set(lastCatalog?.sessions.map(\.id) ?? [])
            .subtracting(catalog.sessions.map(\.id))
        lastCatalog = catalog
        for session in removed {
            ownership.remove(session: session)
            pendingOutput[session] = nil
            for (id, client) in clients where client.sessions.contains(session) {
                clients[id]?.sessions.remove(session)
                server.send(.closed(session: session), to: id)
            }
        }
        if !removed.isEmpty {
            updateRemoteDrivers()
        }
        for (id, client) in clients where client.clientID != nil {
            server.send(.catalog(workspaces: catalog.workspaces, sessions: catalog.sessions), to: id)
        }
    }

    // MARK: RemoteServerDelegate

    func remoteServer(_ server: RemoteServer, didChangeState state: RemoteServer.State) {
        serverState = state
    }

    func remoteServer(_ server: RemoteServer, didConnect connection: RemoteServer.ConnectionID) {
        clients[connection] = Client()
    }

    func remoteServer(_ server: RemoteServer, didDisconnect connection: RemoteServer.ConnectionID) {
        clients[connection] = nil
        updateConnectedClientNames()
    }

    func remoteServer(_ server: RemoteServer, didDrain connection: RemoteServer.ConnectionID) {
        guard let stale = clients[connection]?.staleSessions else { return }
        for session in stale {
            sendScreen(session, to: connection)
        }
    }

    func remoteServer(
        _ server: RemoteServer,
        connection: RemoteServer.ConnectionID,
        didReceive message: RemoteClientMessage
    ) {
        guard let client = clients[connection] else { return }
        if case .hello(let name, let version, let clientID) = message {
            guard version == RemoteProtocol.version else {
                server.send(.error(
                    code: "version_mismatch",
                    message: "mTerm speaks remote protocol v\(RemoteProtocol.version); update the app."),
                    to: connection)
                server.disconnect(connection)
                return
            }
            clients[connection]?.clientID = clientID
            clients[connection]?.name = name
            clientNames[clientID] = name
            updateConnectedClientNames()
            updateRemoteDrivers()
            server.send(.welcome(name: Host.current().localizedName ?? "Mac", version: RemoteProtocol.version),
                        to: connection)
            let catalog = lastCatalog ?? currentCatalog()
            lastCatalog = catalog
            server.send(.catalog(workspaces: catalog.workspaces, sessions: catalog.sessions), to: connection)
            return
        }
        guard let clientID = client.clientID else {
            server.send(.error(code: "hello_required", message: "Send hello first"), to: connection)
            server.disconnect(connection)
            return
        }

        switch message {
        case .hello:
            break
        case .open(let session, let grid):
            guard subscribe(connection, to: session) else { return }
            let effect = ownership.open(client: clientID, session: session, grid: grid)
            applyAndEnsureScreen(effect, session: session, connection: connection)
        case .attach(let session, let grid):
            guard subscribe(connection, to: session) else { return }
            let effect = ownership.report(client: clientID, session: session, grid: grid)
            applyAndEnsureScreen(effect, session: session, connection: connection)
        case .close(let session):
            clients[connection]?.sessions.remove(session)
            clients[connection]?.staleSessions.remove(session)
        case .viewport(let session, let grid):
            apply(ownership.report(client: clientID, session: session, grid: grid), to: session)
        case .claim(let session):
            apply(ownership.act(client: clientID, session: session), to: session)
        case .create(let session, let workspaceID, let grid):
            guard let workspace,
                  workspace.createBackgroundSession(id: session, workspaceID: workspaceID) else {
                server.send(.error(code: "create_failed", message: "Could not create the terminal"),
                            to: connection)
                server.send(.closed(session: session), to: connection)
                return
            }
            // The claim is recorded before SwiftUI builds the terminal view, so
            // `register` pins the grid and the shell starts at the client's size.
            _ = ownership.open(client: clientID, session: session, grid: grid)
            clients[connection]?.sessions.insert(session)
            updateRemoteDrivers()
            publishCatalogIfChanged()
        case .input(let session, let data):
            guard let view = terminal(for: session) else { return }
            apply(ownership.act(client: clientID, session: session), to: session)
            view.process.send(data: ArraySlice([UInt8](data)))
        case .commands(let session):
            guard let record = currentCatalog().sessions.first(where: { $0.id == session }) else {
                server.send(.commands(session: session, commands: []), to: connection)
                return
            }
            // Listing OMP skills runs `omp`, which takes most of a second.
            Task { [weak self] in
                let commands = await RemoteCommandCatalog.load(
                    agent: record.agent, workingDirectory: record.workingDirectory)
                guard let self, self.clients[connection] != nil else { return }
                self.server.send(.commands(session: session, commands: commands), to: connection)
            }
        case .upload(_, let id, let name, let data):
            let store = attachments
            Task { [weak self] in
                let result = await Task.detached(priority: .userInitiated) {
                    Result { try store.save(data, named: name, id: id) }
                }.value
                guard let self, self.clients[connection] != nil else { return }
                switch result {
                case .success(let file):
                    self.server.send(.uploaded(id: id, path: file.path), to: connection)
                case .failure(let error):
                    self.server.send(.uploadFailed(id: id, message: error.localizedDescription), to: connection)
                }
            }
        }
    }

    private func subscribe(_ connection: RemoteServer.ConnectionID, to session: SessionRecord.ID) -> Bool {
        guard terminal(for: session) != nil else {
            server.send(.closed(session: session), to: connection)
            return false
        }
        clients[connection]?.sessions.insert(session)
        return true
    }

    /// A new subscriber always needs a screen, even when ownership is unchanged.
    private func applyAndEnsureScreen(
        _ effect: RemoteOwnership.Effect,
        session: SessionRecord.ID,
        connection: RemoteServer.ConnectionID
    ) {
        if effect == .none {
            sendScreen(session, to: connection)
        } else {
            apply(effect, to: session)
        }
    }

    private func updateConnectedClientNames() {
        let names = clients.values.compactMap { $0.clientID == nil ? nil : $0.name }.sorted()
        if names != connectedClientNames {
            connectedClientNames = names
        }
    }
}
