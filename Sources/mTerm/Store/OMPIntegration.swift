import Foundation

/// OMP reports its interactive lifecycle through OSC 0 terminal titles. The
/// leading `π` scopes the protocol; the separator carries run state and the
/// remaining text is OMP's persisted session title.
enum OMPIntegration {
    struct TerminalTitleUpdate: Equatable {
        let isWorking: Bool
        let conversationTitle: String?
    }

    private static let workingSeparators: Set<Character> = [
        "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏",
    ]

    static func parseTerminalTitle(_ rawTitle: String) -> TerminalTitleUpdate? {
        if rawTitle == "π" {
            return TerminalTitleUpdate(isWorking: false, conversationTitle: nil)
        }
        if rawTitle == "π:" {
            return TerminalTitleUpdate(isWorking: false, conversationTitle: nil)
        }
        if rawTitle.hasPrefix("π: ") {
            return TerminalTitleUpdate(
                isWorking: false,
                conversationTitle: normalizedTitle(rawTitle.dropFirst(3)))
        }

        guard rawTitle.hasPrefix("π ") else { return nil }
        let stateAndTitle = rawTitle.dropFirst(2)
        guard let separator = stateAndTitle.first else { return nil }
        let isWorking = workingSeparators.contains(separator)
        guard isWorking || separator == ">" || separator == "!" else { return nil }

        let remainder = stateAndTitle.dropFirst()
        guard remainder.isEmpty || remainder.first == " " else { return nil }
        return TerminalTitleUpdate(
            isWorking: isWorking,
            conversationTitle: normalizedTitle(remainder.dropFirst(remainder.isEmpty ? 0 : 1)))
    }

    private static func normalizedTitle(_ title: Substring) -> String? {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
