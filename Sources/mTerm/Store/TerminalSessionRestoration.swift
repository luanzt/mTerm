import Foundation

enum AgentRestorationPhase: Equatable {
    case pending
    case launched
    case acknowledged
    case failed
}

enum TerminalSessionRestoration {
    static func command(for descriptor: AgentResumeDescriptor) -> String? {
        switch descriptor {
        case .claude(let sessionID):
            return "claude --resume \(shellQuote(sessionID.uuidString.lowercased()))"
        case .codex(.threadID(let threadID)):
            return "codex resume \(shellQuote(threadID.uuidString.lowercased()))"
        case .codex(.name(let name)):
            guard isValidName(name) else { return nil }
            return "codex resume \(shellQuote(name))"
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func isValidName(_ value: String) -> Bool {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return !value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
    }
}
