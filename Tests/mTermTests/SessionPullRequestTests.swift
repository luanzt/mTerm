import XCTest
@testable import mTerm

final class SessionPullRequestTests: XCTestCase {
    func testDecodeMapsGitHubStates() throws {
        func decode(_ state: String, draft: Bool = false) -> SessionPullRequest.State? {
            let json = """
            {"number":3083,"state":"\(state)","isDraft":\(draft),"url":"https://github.com/o/r/pull/3083"}
            """
            return SessionPullRequest.decode(Data(json.utf8))?.state
        }
        XCTAssertEqual(decode("OPEN"), .open)
        XCTAssertEqual(decode("OPEN", draft: true), .draft)
        XCTAssertEqual(decode("MERGED"), .merged)
        XCTAssertEqual(decode("CLOSED"), .closed)
        XCTAssertNil(decode("UNKNOWN"))
    }

    func testFeatureBranchSkipsTrunkDefaultAndDetachedHeads() throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("mterm-pr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        let gitPath = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }!
        let git = URL(fileURLWithPath: gitPath)
        func run(_ arguments: String...) throws {
            let process = Process()
            process.executableURL = git
            process.arguments = ["-C", repo.path, "-c", "user.name=t", "-c", "user.email=t@t"] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, arguments.joined(separator: " "))
        }
        try run("init", "-q", "-b", "develop")
        try run("commit", "-q", "--allow-empty", "-m", "init")
        XCTAssertNil(PullRequestLookup.featureBranch(in: repo.path, git: git))

        try run("switch", "-q", "-c", "feature/boo-1588")
        XCTAssertEqual(PullRequestLookup.featureBranch(in: repo.path, git: git), "feature/boo-1588")

        // The remote's default branch counts as trunk whatever its name.
        try run("switch", "-q", "-c", "trunk")
        try run("update-ref", "refs/remotes/origin/trunk", "HEAD")
        try run("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk")
        XCTAssertNil(PullRequestLookup.featureBranch(in: repo.path, git: git))

        try run("switch", "-q", "--detach")
        XCTAssertNil(PullRequestLookup.featureBranch(in: repo.path, git: git))
    }

    @MainActor
    func testStoreKeepsBadgeWhenGitHubIsUnavailableAndDropsItWhenSessionMoves() async throws {
        let pullRequest = SessionPullRequest(
            number: 3083, state: .open, url: URL(string: "https://github.com/o/r/pull/3083")!)
        var outcomes: [String: PullRequestLookup.Outcome] = ["/repo": .found(pullRequest)]
        let store = SessionPullRequestStore { outcomes[$0] ?? .none }
        var session = SessionRecord.shell(workingDirectory: "/repo")

        store.sessionsChanged([session])
        try await waitUntil { store.pullRequests[session.id] == pullRequest }

        outcomes["/repo"] = .unavailable
        store.refresh([session.id])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.pullRequests[session.id], pullRequest, "Offline keeps the last badge")

        outcomes["/repo"] = .found(SessionPullRequest(number: 3083, state: .merged, url: pullRequest.url))
        store.refresh([session.id])
        try await waitUntil { store.pullRequests[session.id]?.state == .merged }

        session.workingDirectory = "/elsewhere"
        store.sessionsChanged([session])
        XCTAssertNil(store.pullRequests[session.id], "A directory change drops the old branch's PR")

        store.sessionsChanged([])
        XCTAssertTrue(store.pullRequests.isEmpty)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition())
    }
}
