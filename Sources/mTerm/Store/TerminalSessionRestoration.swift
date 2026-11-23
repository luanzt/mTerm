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
            // End option parsing before an arbitrary user-defined name so a
            // value such as "--last" cannot silently select a different thread.
            return "codex resume -- \(shellQuote(name))"
        case .omp(let sessionFile):
            // A missing file would make OMP open its picker or start fresh
            // instead of the conversation this pane had.
            guard isValidName(sessionFile),
                  FileManager.default.fileExists(atPath: sessionFile) else { return nil }
            return "omp --resume \(shellQuote(sessionFile))"
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

final class TerminalRestoreCommandCoordinator {
    private let intent: AgentResumeDescriptor?
    private var didConsumeFirstIdle = false

    init(intent: AgentResumeDescriptor?) {
        self.intent = intent
    }

    func takeCommandOnFirstShellIdle() -> [UInt8]? {
        guard !didConsumeFirstIdle else { return nil }
        didConsumeFirstIdle = true
        guard let intent,
              let command = TerminalSessionRestoration.command(for: intent) else {
            return nil
        }
        return Array(command.utf8) + [0x0D]
    }
}
