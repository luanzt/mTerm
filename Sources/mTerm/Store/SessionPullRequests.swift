import Combine
import Foundation

/// The GitHub pull request opened from the branch a session's working
/// directory has checked out, shown beside the session in the sidebar.
struct SessionPullRequest: Equatable {
    enum State: Equatable {
        case open, draft, merged, closed
    }

    let number: Int
    let state: State
    let url: URL

    /// Decodes `gh pr view --json number,state,isDraft,url`.
    static func decode(_ data: Data) -> SessionPullRequest? {
        struct Payload: Decodable {
            let number: Int
            let state: String
            let isDraft: Bool
            let url: String
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let url = URL(string: payload.url) else { return nil }
        let state: State
        switch payload.state {
        case "OPEN": state = payload.isDraft ? .draft : .open
        case "MERGED": state = .merged
        case "CLOSED": state = .closed
        default: return nil
        }
        return SessionPullRequest(number: payload.number, state: state, url: url)
    }
}

/// Looks up the pull request for a directory's checked-out branch through the
/// user's `gh` CLI. Without `gh` (or its login) the lookup is simply
/// unavailable, so the sidebar shows nothing rather than an error.
enum PullRequestLookup {
    enum Outcome: Equatable {
        case found(SessionPullRequest)
        /// The branch has no pull request, or is not a feature branch.
        case none
        /// `gh` is missing or failed (offline, logged out); keep what is shown.
        case unavailable
    }

    /// Trunk branches collect release pull requests (develop → main) that no
    /// session opened, so they never show one.
    static let trunkBranches: Set<String> = ["main", "master", "develop"]

    private static let toolFolders = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin").path,
    ]

    static func pullRequest(in directory: String) async -> Outcome {
        await Task.detached(priority: .utility) { lookup(in: directory) }.value
    }

    static func lookup(in directory: String) -> Outcome {
        // A GUI app's PATH lacks Homebrew; find gh first so a Mac without the
        // developer tools never reaches /usr/bin/git's install prompt.
        guard let gh = executable(named: "gh") else { return .unavailable }
        let git = executable(named: "git") ?? URL(fileURLWithPath: "/usr/bin/git")
        guard featureBranch(in: directory, git: git) != nil else { return .none }
        let result = run(gh, ["pr", "view", "--json", "number,state,isDraft,url"], in: directory)
        if result.status == 0 {
            return SessionPullRequest.decode(result.output).map(Outcome.found) ?? .unavailable
        }
        let error = String(decoding: result.error, as: UTF8.self)
        return error.contains("no pull requests found") ? .none : .unavailable
    }

    /// The checked-out branch, unless HEAD is detached or on a trunk branch.
    static func featureBranch(in directory: String, git: URL) -> String? {
        let head = run(git, ["symbolic-ref", "--quiet", "--short", "HEAD"], in: directory)
        guard head.status == 0 else { return nil }
        let branch = String(decoding: head.output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty, !trunkBranches.contains(branch) else { return nil }
        let remoteHead = run(git, ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"],
                             in: directory)
        let defaultBranch = String(decoding: remoteHead.output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return defaultBranch == "origin/\(branch)" ? nil : branch
    }

    private static func executable(named name: String) -> URL? {
        toolFolders.lazy
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func run(
        _ executable: URL,
        _ arguments: [String],
        in directory: String
    ) -> (status: Int32, output: Data, error: Data) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (toolFolders + [environment["PATH"] ?? "/usr/bin:/bin"])
            .joined(separator: ":")
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, Data(), Data())
        }
        // Terminating closes both pipes, which ends the reads below.
        let timeout = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
        var errorData = Data()
        let errorRead = DispatchWorkItem {
            errorData = error.fileHandleForReading.readDataToEndOfFile()
        }
        DispatchQueue.global().async(execute: errorRead)
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        errorRead.wait()
        process.waitUntilExit()
        timeout.cancel()
        return (process.terminationStatus, outputData, errorData)
    }
}

/// Keeps each session's pull request current. Lookups run per working
/// directory when a session appears or changes directory, when it is selected,
/// when its agent finishes a turn (the turn may have just opened the PR), and
/// on a slow timer so a merge shows up without any interaction.
@MainActor
final class SessionPullRequestStore: ObservableObject {
    @Published private(set) var pullRequests: [SessionRecord.ID: SessionPullRequest] = [:]

    private static let periodicInterval: TimeInterval = 180
    /// Selecting rows in quick succession must not respawn gh for each click.
    private static let selectionInterval: TimeInterval = 30

    private var directories: [SessionRecord.ID: String] = [:]
    private var inFlight: Set<String> = []
    private var lastChecked: [String: Date] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var timer: Timer?
    private let lookup: (String) async -> PullRequestLookup.Outcome

    init(lookup: @escaping (String) async -> PullRequestLookup.Outcome = PullRequestLookup.pullRequest(in:)) {
        self.lookup = lookup
    }

    func attach(to workspace: WorkspaceStore) {
        workspace.$sessions
            .sink { [weak self] sessions in self?.sessionsChanged(sessions) }
            .store(in: &cancellables)
        workspace.$selectedSessionID
            .compactMap { $0 }
            .sink { [weak self] id in self?.refresh([id], minimumAge: Self.selectionInterval) }
            .store(in: &cancellables)
        workspace.$agentWorkingSessionIDs
            .scan((Set<SessionRecord.ID>(), Set<SessionRecord.ID>())) { ($0.1, $1) }
            .map { previous, current in previous.subtracting(current) }
            .filter { !$0.isEmpty }
            .sink { [weak self] finished in self?.refresh(finished) }
            .store(in: &cancellables)
        timer = Timer.scheduledTimer(withTimeInterval: Self.periodicInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refresh(Set(self.directories.keys))
            }
        }
    }

    func sessionsChanged(_ sessions: [SessionRecord]) {
        let current = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.workingDirectory) })
        let moved = current.filter { directories[$0.key] != $0.value }.map(\.key)
        directories = current
        for id in pullRequests.keys where current[id] == nil || moved.contains(id) {
            pullRequests[id] = nil
        }
        refresh(Set(moved))
    }

    func refresh<S: Sequence>(_ ids: S, minimumAge: TimeInterval = 0) where S.Element == SessionRecord.ID {
        let now = Date()
        for directory in Set(ids.compactMap { directories[$0] }) {
            guard !inFlight.contains(directory) else { continue }
            if minimumAge > 0, let checked = lastChecked[directory],
               now.timeIntervalSince(checked) < minimumAge {
                continue
            }
            inFlight.insert(directory)
            lastChecked[directory] = now
            Task {
                let outcome = await lookup(directory)
                apply(outcome, to: directory)
            }
        }
    }

    private func apply(_ outcome: PullRequestLookup.Outcome, to directory: String) {
        inFlight.remove(directory)
        for (id, sessionDirectory) in directories where sessionDirectory == directory {
            switch outcome {
            case .found(let pullRequest):
                if pullRequests[id] != pullRequest { pullRequests[id] = pullRequest }
            case .none:
                if pullRequests[id] != nil { pullRequests[id] = nil }
            case .unavailable:
                break
            }
        }
    }
}
