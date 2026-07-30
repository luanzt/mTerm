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

    func testBracketedPasteMarksDroppedPathAsPaste() {
        let url = URL(fileURLWithPath: "/tmp/screenshot.png")

        let chunks = TerminalFileDrop.terminalInputChunks(
            for: [url],
            bracketedPaste: true
        )

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(
            String(decoding: chunks[0], as: UTF8.self),
            "\u{1B}[200~/tmp/screenshot.png \u{1B}[201~"
        )
    }

    func testBracketedPasteEmitsOneEventPerDroppedImage() {
        let urls = [
            URL(fileURLWithPath: "/tmp/one.png"),
            URL(fileURLWithPath: "/tmp/two.jpg"),
        ]

        let chunks = TerminalFileDrop.terminalInputChunks(
            for: urls,
            bracketedPaste: true
        )

        XCTAssertEqual(chunks.count, 2)
    }

    func testPlainTerminalReceivesDroppedPathsAsOneChunk() {
        let urls = [
            URL(fileURLWithPath: "/tmp/one.png"),
            URL(fileURLWithPath: "/tmp/two.jpg"),
        ]

        let chunks = TerminalFileDrop.terminalInputChunks(
            for: urls,
            bracketedPaste: false
        )

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(
            String(decoding: chunks[0], as: UTF8.self),
            "/tmp/one.png /tmp/two.jpg "
        )
    }
}
