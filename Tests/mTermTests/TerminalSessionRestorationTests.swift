import XCTest
@testable import mTerm

final class TerminalSessionRestorationTests: XCTestCase {
    func testBuildsExactClaudeResumeCommandFromLowercaseUUID() {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

        XCTAssertEqual(
            TerminalSessionRestoration.command(for: .claude(sessionID: id)),
            "claude --resume 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'")
    }

    func testBuildsExactCodexResumeCommandFromThreadUUID() {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

        XCTAssertEqual(
            TerminalSessionRestoration.command(
                for: .codex(locator: .threadID(id))),
            "codex resume '11111111-2222-3333-4444-555555555555'")
    }

    func testShellQuotesCodexNameWithoutExpandingMetacharacters() {
        XCTAssertEqual(
            TerminalSessionRestoration.command(
                for: .codex(locator: .name("Client's $API; `rm -rf`"))),
            "codex resume 'Client'\"'\"'s $API; `rm -rf`'")
    }

    func testRejectsEmptyAndControlCharacterCodexNames() {
        for name in ["", "   ", "bad\nname", "bad\tname", "bad\u{0000}name"] {
            XCTAssertNil(TerminalSessionRestoration.command(
                for: .codex(locator: .name(name))))
        }
    }
}
