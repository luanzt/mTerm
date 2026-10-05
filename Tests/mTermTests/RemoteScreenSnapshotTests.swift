import SwiftTerm
import XCTest
@testable import mTerm

/// A snapshot is correct when replaying it into a fresh emulator of the same
/// grid rebuilds every visible cell, the scrollback tail, the cursor, and the
/// input-affecting modes of the source terminal.
final class RemoteScreenSnapshotTests: XCTestCase {
    private final class SilentDelegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    private let delegate = SilentDelegate()

    private func makeTerminal(cols: Int, rows: Int) -> Terminal {
        Terminal(delegate: delegate, options: TerminalOptions(cols: cols, rows: rows, scrollback: 500))
    }

    private func replay(_ source: Terminal, cursorHidden: Bool = false) -> Terminal {
        let data = RemoteScreenSnapshot.capture(source, isCursorHidden: cursorHidden)
        let replica = makeTerminal(cols: source.cols, rows: source.rows)
        replica.feed(byteArray: [UInt8](data))
        return replica
    }

    private func lines(_ terminal: Terminal) -> [BufferLine] {
        var row = terminal.buffer.totalLinesTrimmed
        var result: [BufferLine] = []
        while let line = terminal.getScrollInvariantLine(row: row) {
            result.append(line)
            row += 1
        }
        return result
    }

    private func describe(_ line: BufferLine, in terminal: Terminal, cols: Int) -> [String] {
        (0..<min(cols, line.count)).map { column in
            let cell = line[column]
            let character = terminal.getCharacter(for: cell)
            let text = character == "\u{0}" ? " " : String(character)
            return "\(text)|\(cell.width)|\(cell.attribute)"
        }
    }

    private func assertSameLines(
        _ expected: [BufferLine], in source: Terminal,
        _ actual: [BufferLine], in replica: Terminal,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(expected.count, actual.count, "line count", file: file, line: line)
        for (index, (left, right)) in zip(expected, actual).enumerated() {
            XCTAssertEqual(
                describe(left, in: source, cols: source.cols),
                describe(right, in: replica, cols: replica.cols),
                "line \(index)", file: file, line: line)
            if index > 0 {
                XCTAssertEqual(left.isWrapped, right.isWrapped, "wrap flag line \(index)",
                               file: file, line: line)
            }
        }
    }

    func testReplayRebuildsScreenScrollbackCursorAndModes() {
        let source = makeTerminal(cols: 30, rows: 6)
        for index in 0..<20 {
            source.feed(text: "history \(index) \u{1B}[3\(index % 8)mcolored\u{1B}[0m\r\n")
        }
        source.feed(text: "\u{1B}[1;3;4mstyled\u{1B}[0m \u{1B}[38;5;208mx256\u{1B}[0m ")
        source.feed(text: "\u{1B}[38;2;10;20;30;48;2;200;100;50mtrue\u{1B}[0m\r\n")
        source.feed(text: "wide 漢字 ok\r\n")
        source.feed(text: String(repeating: "w", count: 45) + "\r\n")
        source.feed(text: "\u{1B}[2;5r\u{1B}[?1h\u{1B}[?2004h\u{1B}[3;7H\u{1B}[1;32m")

        let replica = replay(source, cursorHidden: true)

        assertSameLines(lines(source).suffix(26), in: source, lines(replica).suffix(26), in: replica)
        XCTAssertEqual(replica.buffer.x, source.buffer.x)
        XCTAssertEqual(replica.buffer.y, source.buffer.y)
        XCTAssertEqual(replica.buffer.scrollTop, 1)
        XCTAssertEqual(replica.buffer.scrollBottom, 4)
        XCTAssertTrue(replica.applicationCursor)
        XCTAssertTrue(replica.bracketedPasteMode)
        XCTAssertEqual(replica.currentAttribute, source.currentAttribute)
    }

    func testColumnShrinkDoesNotWrapStaleCellsIntoNextRows() {
        let source = makeTerminal(cols: 40, rows: 5)
        source.reflowOnResize = false
        for index in 0..<5 {
            source.feed(text: "row\(index) " + String(repeating: "#", count: 33))
            if index < 4 { source.feed(text: "\r\n") }
        }
        source.resize(cols: 20, rows: 5)

        let replica = replay(source)

        let screen = lines(replica).suffix(5)
        for (index, line) in screen.enumerated() {
            XCTAssertEqual(
                line.translateToString(trimRight: true),
                "row\(index) " + String(repeating: "#", count: 15),
                "row \(index) must hold only the visible 20 columns")
        }
    }

    func testAlternateScreenReplayKeepsHistoryAndAlternateContent() {
        let source = makeTerminal(cols: 24, rows: 4)
        for index in 0..<8 {
            source.feed(text: "shell line \(index)\r\n")
        }
        source.feed(text: "\u{1B}[?1049h\u{1B}[H\u{1B}[44mTUI\u{1B}[0m frame\r\nsecond row")

        let replica = replay(source)

        XCTAssertTrue(replica.isCurrentBufferAlternate)
        let sourceScreen = (0..<source.rows).compactMap { source.getLine(row: $0) }
        let replicaScreen = (0..<replica.rows).compactMap { replica.getLine(row: $0) }
        assertSameLines(sourceScreen, in: source, replicaScreen, in: replica)
        let history = String(decoding: replica.getBufferAsData(kind: .normal), as: UTF8.self)
        XCTAssertTrue(history.contains("shell line 7"))
    }

    func testLeavingAlternateScreenRestoresTheSameNormalCursor() {
        let source = makeTerminal(cols: 30, rows: 10)
        source.feed(text: "$ vim notes.txt\r\n")
        let cursorAtSwitch = (x: source.buffer.x, y: source.buffer.y)
        source.feed(text: "\u{1B}[?1049h\u{1B}[H~\r\n~\r\n\u{1B}[10;1H:wq")

        let data = RemoteScreenSnapshot.capture(source, isCursorHidden: false, normalCursor: cursorAtSwitch)
        let replica = makeTerminal(cols: source.cols, rows: source.rows)
        replica.feed(byteArray: [UInt8](data))
        source.feed(text: "\u{1B}[?1049l$ ")
        replica.feed(text: "\u{1B}[?1049l$ ")

        XCTAssertEqual(replica.buffer.y, source.buffer.y)
        XCTAssertEqual(replica.buffer.x, source.buffer.x)
    }
}
