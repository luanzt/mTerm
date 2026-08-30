import XCTest
@testable import mTerm

final class OMPIntegrationTests: XCTestCase {
    func testParsesOfficialTerminalTitleRunStates() {
        let workingFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        for frame in workingFrames {
            XCTAssertEqual(
                OMPIntegration.parseTerminalTitle("π \(frame) Fix authentication flow"),
                .init(isWorking: true, conversationTitle: "Fix authentication flow"))
        }

        for title in [
            "π > Fix authentication flow",
            "π ! Fix authentication flow",
            "π: Fix authentication flow",
        ] {
            XCTAssertEqual(
                OMPIntegration.parseTerminalTitle(title),
                .init(isWorking: false, conversationTitle: "Fix authentication flow"))
        }
    }

    func testAllowsRunStateWithoutConversationTitle() {
        XCTAssertEqual(
            OMPIntegration.parseTerminalTitle("π ⠋"),
            .init(isWorking: true, conversationTitle: nil))
        XCTAssertEqual(
            OMPIntegration.parseTerminalTitle("π >"),
            .init(isWorking: false, conversationTitle: nil))
        XCTAssertEqual(
            OMPIntegration.parseTerminalTitle("π"),
            .init(isWorking: false, conversationTitle: nil))
    }

    func testRejectsTitlesOutsideOMPProtocol() {
        for title in [
            "",
            "pi > Fix authentication flow",
            "π ? Fix authentication flow",
            "Notes about π > syntax",
            "π ⠋Fix authentication flow",
        ] {
            XCTAssertNil(OMPIntegration.parseTerminalTitle(title))
        }
    }
}
