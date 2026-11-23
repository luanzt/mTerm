import Darwin
import Foundation

/// OMP reports its interactive lifecycle through OSC 0 terminal titles. The
/// leading `π` scopes the protocol; the separator carries run state (a spinner
/// while working, `>` on the user's turn, `!` while an ask or approval prompt
/// waits on the user) and the remaining text is OMP's persisted session title.
enum OMPIntegration {
    struct TerminalTitleUpdate: Equatable {
        let isWorking: Bool
        var isAwaitingUser = false
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
            isAwaitingUser: separator == "!",
            conversationTitle: normalizedTitle(remainder.dropFirst(remainder.isEmpty ? 0 : 1)))
    }

    private static func normalizedTitle(_ title: Substring) -> String? {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

/// Finds the session file a pane's OMP process is writing. OMP publishes no
/// session identity to the terminal, but holds its `<sessions>/…/<id>.jsonl`
/// transcript open for appending for as long as that conversation is active,
/// including after `/resume` or `/new` switch it.
enum OMPSessionLocator {
    /// The session file held by the PTY's foreground process group leader.
    static func sessionFile(foregroundOf ptyFD: Int32) -> String? {
        guard ptyFD >= 0 else { return nil }
        let group = tcgetpgrp(ptyFD)
        return group > 1 ? sessionFile(openedBy: group) : nil
    }

    static func sessionFile(openedBy pid: pid_t) -> String? {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let byteCount = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard byteCount > 0 else { return nil }
        // Headroom for descriptors opened between the sizing and data calls.
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(byteCount) / stride + 16)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors,
                                  Int32(descriptors.count * stride))
        guard filled > 0 else { return nil }

        var candidates: [String] = []
        for descriptor in descriptors.prefix(Int(filled) / stride)
        where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO,
                                 &info, size) == size,
                  // FWRITE: a session being recorded, not a file merely read.
                  info.pfi.fi_openflags & 0x2 != 0 else { continue }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            if isSessionFile(path) {
                candidates.append(path)
            }
        }
        // Subagent transcripts nest below the main session's directory.
        return candidates.min { $0.count < $1.count }
    }

    static func isSessionFile(_ path: String) -> Bool {
        path.hasPrefix("/") && path.hasSuffix(".jsonl") && path.contains("/sessions/")
    }
}
