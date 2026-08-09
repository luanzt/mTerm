import XCTest
@testable import mTerm

final class AgentSessionTitleTests: XCTestCase {
    func testNormalizesWhitespaceAndLimitsLength() {
        XCTAssertEqual(
            AgentSessionTitle.normalize("  Fix   authentication flow  "),
            "Fix authentication flow")
        XCTAssertEqual(
            AgentSessionTitle.normalize(
                String(repeating: "a", count: AgentSessionTitle.maximumLength + 20)
            )?.count,
            AgentSessionTitle.maximumLength)
    }

    func testRejectsGenericEmptyAndControlCharacterTitles() {
        for title in [
            "",
            "   ",
            "Claude Code",
            "✳ Claude Code",
            "* Claude Code",
            "codex",
            "⠋ OpenAI Codex",
            "OpenAI Codex",
            "019f9217-1cc5-72a2-8569-8f19f2d4f3b8",
            "Fix auth\nsteal another row",
            "Fix auth\u{0007}",
        ] {
            XCTAssertNil(AgentSessionTitle.normalize(title))
        }
    }

    func testPreservesUnicodeConversationTitles() {
        XCTAssertEqual(
            AgentSessionTitle.normalize("Éditer le résumé 🚀"),
            "Éditer le résumé 🚀")
    }

    func testStripsClaudeSpinnerDecorationFromConversationTitle() {
        for title in [
            "* Fix authentication flow",
            "· Fix authentication flow",
            "✳ Fix authentication flow",
        ] {
            XCTAssertEqual(
                AgentSessionTitle.normalize(
                    title,
                    strippingLeadingDecoration: true),
                "Fix authentication flow")
        }
    }
}
