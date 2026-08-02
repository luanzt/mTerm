import Foundation

/// Validates agent-provided OSC 0/2 terminal titles before they reach mTerm's
/// UI. The title is display-only: `SessionRecord.title` remains the stable
/// "Terminal N" fallback restored when the pane returns to its shell prompt.
enum AgentSessionTitle {
    static let maximumLength = 80

    private static let genericTitles: Set<String> = [
        "claude",
        "claude code",
        "codex",
        "openai codex",
    ]

    /// Claude prefixes its generic terminal title with the current spinner
    /// frame (for example, `✳ Claude Code`). Treat every symbol-only prefix as
    /// decoration so a paused frame cannot become the session's display title.
    private static func isDecoratedGenericTitle(_ title: String) -> Bool {
        let lowercased = title.lowercased()
        if genericTitles.contains(lowercased) { return true }

        return genericTitles.contains { genericTitle in
            guard lowercased.hasSuffix(genericTitle) else { return false }
            let prefix = lowercased.dropLast(genericTitle.count)
            return !prefix.isEmpty && prefix.allSatisfy {
                $0.isWhitespace || (!$0.isLetter && !$0.isNumber)
            }
        }
    }

    static func normalize(_ rawTitle: String) -> String? {
        guard !rawTitle.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) else {
            return nil
        }

        let collapsed = rawTitle
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty,
              CodexThreadTitleResolver.threadID(from: collapsed) == nil,
              !isDecoratedGenericTitle(collapsed) else {
            return nil
        }

        return String(collapsed.prefix(maximumLength))
    }
}
