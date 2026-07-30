import Foundation
import XCTest
@testable import mTerm

final class TerminalFileDropTests: XCTestCase {
    func testShellInputForNoFilesIsEmpty() {
        XCTAssertEqual(TerminalFileDrop.shellInput(for: []), "")
    }

    func testShellInputEscapesSpacesAndSeparatesMultipleFiles() {
        let urls = [
            URL(fileURLWithPath: "/tmp/first file.txt"),
            URL(fileURLWithPath: "/tmp/second.txt"),
        ]

        XCTAssertEqual(
            TerminalFileDrop.shellInput(for: urls),
            "/tmp/first\\ file.txt /tmp/second.txt "
        )
    }

    func testShellInputEscapesOnlyShellSpecialCharacters() {
        let url = URL(fileURLWithPath: "/tmp/it's here.txt")

        XCTAssertEqual(
            TerminalFileDrop.shellInput(for: [url]),
            "/tmp/it\\'s\\ here.txt "
        )
    }

    func testShellInputLeavesSimplePathUnquoted() {
        let url = URL(fileURLWithPath: "/tmp/script.sh")

        XCTAssertEqual(
            TerminalFileDrop.shellInput(for: [url]),
            "/tmp/script.sh "
        )
    }

    func testShellInputEscapesExpansionAndGlobCharacters() {
        let url = URL(fileURLWithPath: "/tmp/$draft*.txt")

        XCTAssertEqual(
            TerminalFileDrop.shellInput(for: [url]),
            "/tmp/\\$draft\\*.txt "
        )
    }

    func testShellInputDoesNotExecuteDroppedFile() {
        let url = URL(fileURLWithPath: "/tmp/script.sh")

        XCTAssertFalse(TerminalFileDrop.shellInput(for: [url]).contains("\n"))
    }
}
