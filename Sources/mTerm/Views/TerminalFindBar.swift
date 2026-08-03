import AppKit
import SwiftTerm
import SwiftUI

/// Direction of a find step. A plain Return searches forward; Shift+Return
/// searches backward.
enum FindDirection: Equatable {
    case next
    case previous

    static func fromReturn(modifierFlags: NSEvent.ModifierFlags) -> FindDirection {
        modifierFlags.contains(.shift) ? .previous : .next
    }
}

/// Formats the match counter shown beside the find field.
enum FindMatchCounter {
    /// `nil` hides the label (empty term). `"No results"` when nothing matched.
    /// Otherwise `"index / total"`, where `index` is the 1-based current match.
    static func text(term: String, index: Int, total: Int) -> String? {
        guard !term.isEmpty else { return nil }
        guard total > 0 else { return "No results" }
        return "\(index) / \(total)"
    }
}

/// Bridges the SwiftUI find bar to one pane's SwiftTerm view. Holds a weak
/// reference so mTerm never retains the terminal view.
@MainActor
final class TerminalSearchController: ObservableObject {
    weak var terminalView: LocalProcessTerminalView?

    private let options = SearchOptions(caseSensitive: false)

    /// Runs a search step, then returns the current match position and total.
    func find(_ term: String, direction: FindDirection) -> (index: Int, total: Int) {
        guard let terminalView, !term.isEmpty else { return (0, 0) }
        switch direction {
        case .next:
            _ = terminalView.findNext(term, options: options)
        case .previous:
            _ = terminalView.findPrevious(term, options: options)
        }
        return terminalView.searchMatchSummary(term, options: options)
    }

    /// Removes the current search selection/highlight.
    func clear() {
        terminalView?.clearSearch()
    }
}

/// An Emerald-themed find bar overlaid on the top-right of a focused pane.
/// Enter → next match, Shift+Enter → previous, Esc/✕ → close.
struct TerminalFindBar: View {
    let controller: TerminalSearchController
    let onClose: () -> Void

    @State private var term = ""
    @State private var summary: (index: Int, total: Int) = (0, 0)
    @State private var focusToken = 0

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MTermTheme.dim2)
            FindSearchField(
                text: $term,
                focusToken: focusToken,
                onChange: { runSearch(direction: .next) },
                onNavigate: { runSearch(direction: $0) },
                onClose: onClose)
                .frame(width: 150, height: 20)
            if let counter = FindMatchCounter.text(
                term: term, index: summary.index, total: summary.total) {
                Text(counter)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(summary.total == 0 ? MTermTheme.dim2 : MTermTheme.dim)
                    .fixedSize()
            }
            findButton(icon: "chevron.up", help: "Previous match (⇧⏎)") {
                runSearch(direction: .previous)
            }
            findButton(icon: "chevron.down", help: "Next match (⏎)") {
                runSearch(direction: .next)
            }
            findButton(icon: "xmark", help: "Close (esc)", action: onClose)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(MTermTheme.control)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(MTermTheme.controlBorder, lineWidth: 1)))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .onAppear { focusToken += 1 }
    }

    private func runSearch(direction: FindDirection) {
        guard !term.isEmpty else {
            controller.clear()
            summary = (0, 0)
            return
        }
        summary = controller.find(term, direction: direction)
    }

    private func findButton(
        icon: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MTermTheme.dim)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A borderless, transparent text field whose coordinator maps Return →
/// next/previous and Esc → close, mirroring SwiftTerm's own find field. The
/// surrounding SwiftUI view draws the themed pill; this field is transparent.
private struct FindSearchField: NSViewRepresentable {
    @Binding var text: String
    var focusToken: Int
    var onChange: () -> Void
    var onNavigate: (FindDirection) -> Void
    var onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.textColor = NSColor(MTermTheme.text)
        field.placeholderString = "Find"
        field.delegate = context.coordinator
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.appliedFocusToken != focusToken {
            context.coordinator.appliedFocusToken = focusToken
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
                field.currentEditor()?.selectedRange =
                    NSRange(location: field.stringValue.count, length: 0)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FindSearchField
        var appliedFocusToken = 0

        init(_ parent: FindSearchField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
            parent.onChange()
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                parent.onNavigate(FindDirection.fromReturn(modifierFlags: flags))
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onClose()
                return true
            default:
                return false
            }
        }
    }
}
