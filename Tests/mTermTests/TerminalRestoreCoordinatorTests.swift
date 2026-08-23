import XCTest
@testable import mTerm

final class TerminalRestoreCoordinatorTests: XCTestCase {
    func testNoIntentEmitsNoTerminalInput() {
        let coordinator = TerminalRestoreCommandCoordinator(intent: nil)

        XCTAssertNil(coordinator.takeCommandOnFirstShellIdle())
        XCTAssertNil(coordinator.takeCommandOnFirstShellIdle())
    }

    func testValidIntentEmitsCommandAndCarriageReturnExactlyOnce() {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let coordinator = TerminalRestoreCommandCoordinator(
            intent: .claude(sessionID: id))

        let first = coordinator.takeCommandOnFirstShellIdle()
        let second = coordinator.takeCommandOnFirstShellIdle()

        XCTAssertEqual(
            first,
            Array("claude --resume 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'".utf8)
                + [0x0D])
        XCTAssertNil(second)
    }

    func testInvalidIntentIsConsumedInsteadOfRetried() {
        let coordinator = TerminalRestoreCommandCoordinator(
            intent: .codex(locator: .name("bad\nname")))

        XCTAssertNil(coordinator.takeCommandOnFirstShellIdle())
        XCTAssertNil(coordinator.takeCommandOnFirstShellIdle())
    }

    func testNewTerminalCoordinatorGetsIndependentOneShotLifetime() {
        let descriptor = AgentResumeDescriptor.codex(locator: .name("Client API"))
        let first = TerminalRestoreCommandCoordinator(intent: descriptor)
        let second = TerminalRestoreCommandCoordinator(intent: descriptor)

        XCTAssertEqual(
            first.takeCommandOnFirstShellIdle(),
            Array("codex resume -- 'Client API'".utf8) + [0x0D])
        XCTAssertNil(first.takeCommandOnFirstShellIdle())
        XCTAssertNotNil(second.takeCommandOnFirstShellIdle())
    }
}
