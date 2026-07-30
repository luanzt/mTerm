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
              !genericTitles.contains(collapsed.lowercased()) else {
            return nil
        }

        return String(collapsed.prefix(maximumLength))
    }
}
