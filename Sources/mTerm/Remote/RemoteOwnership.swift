import Foundation

/// Decides who sets each session's PTY size. The Mac pane size applies until a
/// remote client performs a real action on the session (open, input, explicit
/// claim); the size then follows that client until a Mac user interacts with
/// the pane. Passive events (reconnect attach, viewport reports) never move
/// ownership: Orca #15539 shows a resumed client re-stealing a terminal the
/// desktop had just taken back.
struct RemoteOwnership {
    enum Driver: Equatable {
        case mac
        case client(UUID, RemoteGrid)
    }

    enum Effect: Equatable {
        case none
        /// Pin the session's terminal to this grid (claim or owner refit).
        case pin(RemoteGrid)
        /// Return the session to its Mac pane size.
        case release
    }

    private(set) var drivers: [UUID: Driver] = [:]
    /// Latest terminal-area grid each client reported for each session, used
    /// when a client claims by typing.
    private var viewports: [UUID: [UUID: RemoteGrid]] = [:]

    func driver(of session: UUID) -> Driver {
        drivers[session] ?? .mac
    }

    mutating func open(client: UUID, session: UUID, grid: RemoteGrid) -> Effect {
        viewports[client, default: [:]][session] = grid
        return claim(client: client, session: session, grid: grid)
    }

    /// Reconnect/resume subscription and viewport reports: refit only when
    /// this client already drives the session.
    mutating func report(client: UUID, session: UUID, grid: RemoteGrid) -> Effect {
        viewports[client, default: [:]][session] = grid
        guard case .client(let owner, let current) = driver(of: session),
              owner == client, current != grid else { return .none }
        drivers[session] = .client(client, grid)
        return .pin(grid)
    }

    /// Input or an explicit take-over tap. Without a reported grid there is
    /// nothing to fit to, so ownership stays where it is.
    mutating func act(client: UUID, session: UUID) -> Effect {
        guard let grid = viewports[client]?[session] else { return .none }
        return claim(client: client, session: session, grid: grid)
    }

    mutating func macInteraction(session: UUID) -> Effect {
        guard driver(of: session) != .mac else { return .none }
        drivers[session] = nil
        return .release
    }

    mutating func remove(session: UUID) {
        drivers[session] = nil
        for client in viewports.keys {
            viewports[client]?[session] = nil
        }
    }

    private mutating func claim(client: UUID, session: UUID, grid: RemoteGrid) -> Effect {
        guard driver(of: session) != .client(client, grid) else { return .none }
        drivers[session] = .client(client, grid)
        return .pin(grid)
    }
}
