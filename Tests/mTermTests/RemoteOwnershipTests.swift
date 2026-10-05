import XCTest
@testable import mTerm

final class RemoteOwnershipTests: XCTestCase {
    private let session = UUID()
    private let iPad = UUID()
    private let otherClient = UUID()
    private let iPadGrid = RemoteGrid(columns: 120, rows: 40)

    func testOpeningClaimsAndMacInteractionReleases() {
        var ownership = RemoteOwnership()

        XCTAssertEqual(ownership.open(client: iPad, session: session, grid: iPadGrid), .pin(iPadGrid))
        XCTAssertEqual(ownership.driver(of: session), .client(iPad, iPadGrid))
        XCTAssertEqual(ownership.macInteraction(session: session), .release)
        XCTAssertEqual(ownership.driver(of: session), .mac)
        XCTAssertEqual(ownership.macInteraction(session: session), .none)
    }

    func testPassiveReportAfterMacTakeBackDoesNotReclaim() {
        var ownership = RemoteOwnership()
        _ = ownership.open(client: iPad, session: session, grid: iPadGrid)
        _ = ownership.macInteraction(session: session)

        let resumed = RemoteGrid(columns: 100, rows: 40)
        XCTAssertEqual(ownership.report(client: iPad, session: session, grid: resumed), .none)
        XCTAssertEqual(ownership.driver(of: session), .mac)
    }

    func testOwnerViewportChangeRefitsButIdenticalReportIsIgnored() {
        var ownership = RemoteOwnership()
        _ = ownership.open(client: iPad, session: session, grid: iPadGrid)

        XCTAssertEqual(ownership.report(client: iPad, session: session, grid: iPadGrid), .none)
        let rotated = RemoteGrid(columns: 90, rows: 55)
        XCTAssertEqual(ownership.report(client: iPad, session: session, grid: rotated), .pin(rotated))
    }

    func testTypingClaimsWithTheClientsLastReportedGrid() {
        var ownership = RemoteOwnership()
        _ = ownership.open(client: iPad, session: session, grid: iPadGrid)
        _ = ownership.macInteraction(session: session)
        let rotated = RemoteGrid(columns: 90, rows: 55)
        _ = ownership.report(client: iPad, session: session, grid: rotated)

        XCTAssertEqual(ownership.act(client: iPad, session: session), .pin(rotated))
        XCTAssertEqual(ownership.act(client: iPad, session: session), .none)
    }

    func testClientWithoutReportedGridCannotClaim() {
        var ownership = RemoteOwnership()
        XCTAssertEqual(ownership.act(client: iPad, session: session), .none)
        XCTAssertEqual(ownership.driver(of: session), .mac)
    }

    func testLastActingClientWins() {
        var ownership = RemoteOwnership()
        let otherGrid = RemoteGrid(columns: 80, rows: 30)
        _ = ownership.open(client: iPad, session: session, grid: iPadGrid)
        _ = ownership.open(client: otherClient, session: session, grid: otherGrid)

        XCTAssertEqual(ownership.report(client: iPad, session: session, grid: iPadGrid), .none)
        XCTAssertEqual(ownership.driver(of: session), .client(otherClient, otherGrid))
        XCTAssertEqual(ownership.act(client: iPad, session: session), .pin(iPadGrid))
    }

    func testRemovedSessionForgetsDriverAndViewports() {
        var ownership = RemoteOwnership()
        _ = ownership.open(client: iPad, session: session, grid: iPadGrid)
        ownership.remove(session: session)

        XCTAssertEqual(ownership.driver(of: session), .mac)
        XCTAssertEqual(ownership.act(client: iPad, session: session), .none)
    }
}
