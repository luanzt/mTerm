import Foundation

/// Codex TUI has a built-in notification channel for completed turns, approval
/// requests, and interactive prompts. mTerm forces that channel to OSC 9 only for
/// Codex processes launched inside its panes, then consumes the OSC on the owning
/// PTY instead of asking Codex to launch a separate desktop notifier.
enum CodexIntegration {
    static let oscCode = 9

    struct TerminalTitleUpdate: Equatable {
        let isWorking: Bool
        let conversationTitle: String?
    }

    /// Codex's `run-state` title item comes from the TUI's internal task state,
    /// making it more reliable than inferring work from Return key presses. The
    /// `app-name` prefix scopes this protocol to mTerm's per-invocation title.
    static func parseTerminalTitle(_ rawTitle: String) -> TerminalTitleUpdate? {
        guard !rawTitle.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) else { return nil }

        let prefix = "codex | "
        guard rawTitle.hasPrefix(prefix) else { return nil }
        let remainder = rawTitle.dropFirst(prefix.count)
        let separator = " | "
        let state: Substring
        let conversationTitle: String?
        if let separatorRange = remainder.range(of: separator) {
            state = remainder[..<separatorRange.lowerBound]
            let title = remainder[separatorRange.upperBound...]
                .trimmingCharacters(in: .whitespaces)
            conversationTitle = title.isEmpty ? nil : title
        } else {
            state = remainder
            conversationTitle = nil
        }

        let isWorking: Bool
        switch state {
        case "Starting", "Working", "Thinking", "Waiting":
            isWorking = true
        case "Ready":
            isWorking = false
        default:
            return nil
        }
        return TerminalTitleUpdate(
            isWorking: isWorking,
            conversationTitle: conversationTitle)
    }

    /// Codex's OSC 9 payload is its human-readable notification message. mTerm
    /// intentionally does not copy that text into Notification Center because it
    /// can contain assistant output, commands, or paths. Requiring the foreground
    /// command here establishes that the payload came from a running Codex TUI.
    static func shouldReportAttention(
        _ payload: ArraySlice<UInt8>,
        foregroundCommand: String?
    ) -> Bool {
        guard foregroundCommand == "codex" else { return false }
        guard !payload.isEmpty, payload.count <= 4_096 else { return false }
        guard payload.allSatisfy({ $0 >= 0x20 || $0 == 0x09 }) else { return false }
        guard let text = String(bytes: payload, encoding: .utf8) else { return false }
        return !text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    static var rootDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("mTerm/codex-notifications", isDirectory: true)
    }

    static var shimDirectory: URL {
        rootDirectory.appendingPathComponent("shim", isDirectory: true)
    }

    /// Add per-invocation TUI overrides without touching `~/.codex/config.toml`.
    /// User-supplied `-c` flags remain later in argv and can explicitly override
    /// these defaults.
    @discardableResult
    static func writeFiles() -> Bool {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: shimDirectory, withIntermediateDirectories: true)
            let shimURL = shimDirectory.appendingPathComponent("codex")
            try codexShim.write(to: shimURL, atomically: true, encoding: .utf8)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shimURL.path)
            return true
        } catch {
            return false
        }
    }

    /// `notification_condition=always` makes delivery deterministic even when a
    /// terminal doesn't implement focus-reporting escape sequences. The stable
    /// `run-state` item reports Codex's internal lifecycle without an animated
    /// title; `app-name` scopes parsing and `thread-title` preserves identity.
    private static let codexShim = """
    #!/bin/zsh
    shim_dir="${0:A:h}"
    path=(${path:#${shim_dir}})
    real_codex="$(command -v codex)"
    if [[ -z "$real_codex" || "$real_codex" == "$0" ]]; then
      print -u2 "mTerm: could not find the Codex CLI executable"
      exit 127
    fi
    exec "$real_codex" \\
      -c 'tui.notifications=true' \\
      -c 'tui.notification_method="osc9"' \\
      -c 'tui.notification_condition="always"' \\
      -c 'tui.terminal_title=["app-name","run-state","thread-title"]' \\
      "$@"
    """ + "\n"
}
