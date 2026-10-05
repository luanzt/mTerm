import Foundation
import SwiftTerm

/// Serializes a SwiftTerm terminal into bytes that rebuild the same screen in
/// a freshly reset emulator of the same grid (the remote client's `screen`
/// frame). Uses only SwiftTerm's public API.
///
/// Invariants the replay relies on:
/// - Rows are written at most `cols` cells wide. After a column shrink the
///   stored rows can still hold cells past the right edge; replaying those
///   would wrap stale tails into the next row (Orca #22586).
/// - Soft-wrapped rows are written without a line break so the client keeps
///   them as one logical line.
/// - The attribute is reset before every line break so scrolling never fills
///   new rows with a leftover background color.
enum RemoteScreenSnapshot {
    static let maxScrollbackLines = 3_000

    private static let defaultAttribute = CharData.Null.attribute

    /// `normalCursor` is the normal-screen cursor saved when the alternate
    /// screen was entered; `?1049h` must save the same position on the client
    /// so the program's `?1049l` returns both emulators to the same row.
    static func capture(
        _ terminal: Terminal,
        isCursorHidden: Bool,
        normalCursor: (x: Int, y: Int)? = nil,
        maxScrollbackLines: Int = Self.maxScrollbackLines
    ) -> Data {
        var writer = Writer(terminal: terminal)
        if terminal.isCurrentBufferAlternate {
            writer.writePlainNormalBuffer(maxScrollbackLines: maxScrollbackLines)
            if let normalCursor {
                let row = min(max(normalCursor.y, 0), terminal.rows - 1)
                let column = min(max(normalCursor.x, 0), terminal.cols - 1)
                writer.output += "\u{1B}[\(row + 1);\(column + 1)H"
            }
            // Saves that cursor and switches to the cleared alternate screen.
            writer.output += "\u{1B}[?1049h\u{1B}[H"
            let lines = (0..<terminal.rows).compactMap { terminal.getLine(row: $0) }
            writer.writeLines(lines)
        } else {
            writer.writeLines(normalBufferLines(terminal, maxScrollbackLines: maxScrollbackLines))
        }
        writer.writeState(isCursorHidden: isCursorHidden)
        return Data(writer.output.utf8)
    }

    /// Scrollback tail plus the screen, oldest first. The screen is always the
    /// last `rows` lines of the buffer.
    private static func normalBufferLines(
        _ terminal: Terminal,
        maxScrollbackLines: Int
    ) -> [BufferLine] {
        let first = terminal.buffer.totalLinesTrimmed
        var end = first
        while terminal.getScrollInvariantLine(row: end) != nil {
            end += 1
        }
        let start = max(first, end - terminal.rows - maxScrollbackLines)
        return (start..<end).compactMap { terminal.getScrollInvariantLine(row: $0) }
    }

    private struct Writer {
        let terminal: Terminal
        var output = ""
        /// Attribute most recently emitted; nil means the SGR default.
        private var current: Attribute?

        init(terminal: Terminal) {
            self.terminal = terminal
        }

        /// The normal buffer is not publicly reachable with attributes while
        /// the alternate screen is active; its text keeps history scrollable.
        mutating func writePlainNormalBuffer(maxScrollbackLines: Int) {
            let text = String(decoding: terminal.getBufferAsData(kind: .normal), as: UTF8.self)
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.last?.isEmpty == true {
                lines.removeLast()
            }
            let tail = lines.suffix(maxScrollbackLines + terminal.rows)
            output += tail
                .map { String($0.prefix(terminal.cols)) }
                .joined(separator: "\r\n")
        }

        mutating func writeLines(_ lines: [BufferLine]) {
            let cols = terminal.cols
            for (index, line) in lines.enumerated() {
                let filled = writeCells(of: line, cols: cols)
                guard index < lines.count - 1 else { break }
                let continues = lines[index + 1].isWrapped && filled == cols
                if !continues {
                    resetAttribute()
                    output += "\r\n"
                }
            }
            resetAttribute()
        }

        /// Returns the number of columns written.
        private mutating func writeCells(of line: BufferLine, cols: Int) -> Int {
            let limit = min(line.count, cols)
            var last = limit - 1
            while last >= 0 && !line.hasContent(index: last) {
                last -= 1
            }
            var column = 0
            while column <= last {
                let cell = line[column]
                let width = Int(cell.width)
                if width == 0 {
                    // Trailing half of a wide glyph; the glyph covered it.
                    column += 1
                    continue
                }
                setAttribute(cell.attribute)
                if width > 1 && column + width > cols {
                    // A wide glyph cut by the right edge cannot be replayed.
                    output += " "
                    column += 1
                    continue
                }
                let character = terminal.getCharacter(for: cell)
                output.append(character == "\u{0}" ? " " : character)
                column += width
            }
            return column
        }

        mutating func writeState(isCursorHidden: Bool) {
            let buffer = terminal.buffer
            if buffer.scrollTop != 0 || buffer.scrollBottom != terminal.rows - 1 {
                output += "\u{1B}[\(buffer.scrollTop + 1);\(buffer.scrollBottom + 1)r"
            }
            let row = min(max(buffer.y, 0), terminal.rows - 1)
            let column = min(max(buffer.x, 0), terminal.cols - 1)
            output += "\u{1B}[\(row + 1);\(column + 1)H"
            setAttribute(terminal.currentAttribute)
            if terminal.applicationCursor {
                output += "\u{1B}[?1h"
            }
            if terminal.bracketedPasteMode {
                output += "\u{1B}[?2004h"
            }
            if isCursorHidden {
                output += "\u{1B}[?25l"
            }
            let keyboardFlags = terminal.keyboardEnhancementFlags.rawValue
            if keyboardFlags != 0 {
                // Push (not set) so the application's eventual pop restores
                // the legacy encoding on the client as well.
                output += "\u{1B}[>\(keyboardFlags)u"
            }
        }

        private mutating func resetAttribute() {
            guard current != nil else { return }
            output += "\u{1B}[0m"
            current = nil
        }

        private mutating func setAttribute(_ attribute: Attribute) {
            if attribute == RemoteScreenSnapshot.defaultAttribute {
                resetAttribute()
                return
            }
            guard attribute != current else { return }
            output += "\u{1B}[\(Self.sgr(attribute))m"
            current = attribute
        }

        static func sgr(_ attribute: Attribute) -> String {
            var parameters = ["0"]
            let style = attribute.style
            if style.contains(.bold) { parameters.append("1") }
            if style.contains(.dim) { parameters.append("2") }
            if style.contains(.italic) { parameters.append("3") }
            if style.contains(.underline) {
                switch attribute.underlineStyle {
                case .none, .single: parameters.append("4")
                case .double: parameters.append("4:2")
                case .curly: parameters.append("4:3")
                case .dotted: parameters.append("4:4")
                case .dashed: parameters.append("4:5")
                }
            }
            if style.contains(.blink) { parameters.append("5") }
            if style.contains(.inverse) { parameters.append("7") }
            if style.contains(.invisible) { parameters.append("8") }
            if style.contains(.crossedOut) { parameters.append("9") }
            parameters.append(contentsOf: color(attribute.fg, base: 30, brightBase: 90, extended: 38))
            parameters.append(contentsOf: color(attribute.bg, base: 40, brightBase: 100, extended: 48))
            if let underline = attribute.underlineColor {
                parameters.append(contentsOf: color(underline, base: nil, brightBase: nil, extended: 58))
            }
            return parameters.joined(separator: ";")
        }

        private static func color(
            _ color: Attribute.Color,
            base: Int?,
            brightBase: Int?,
            extended: Int
        ) -> [String] {
            switch color {
            case .ansi256(let code):
                if let base, code < 8 {
                    return [String(base + Int(code))]
                }
                if let brightBase, code < 16 {
                    return [String(brightBase + Int(code) - 8)]
                }
                return [String(extended), "5", String(code)]
            case .trueColor(let red, let green, let blue):
                return [String(extended), "2", String(red), String(green), String(blue)]
            case .defaultColor, .defaultInvertedColor:
                return []
            }
        }
    }
}
