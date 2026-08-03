import Darwin
import Foundation

/// Tracks the shell that belongs to each terminal session and owns process
/// cleanup independently of SwiftUI view teardown.
@MainActor
final class TerminalProcessRegistry: ObservableObject {
    private var terminalSessionIDs: [SessionRecord.ID: pid_t] = [:]

    func register(_ sessionID: SessionRecord.ID, shellPID: pid_t) {
        guard shellPID > 1 else { return }
        let terminalSessionID = getsid(shellPID)
        guard terminalSessionID > 1,
              terminalSessionID != getsid(getpid()) else { return }
        terminalSessionIDs[sessionID] = terminalSessionID
    }

    func terminate(_ sessionID: SessionRecord.ID, force: Bool = false) {
        guard let terminalSessionID = terminalSessionIDs.removeValue(forKey: sessionID) else {
            return
        }
        ProcessTreeTerminator.terminateTerminalSession(
            sessionID: terminalSessionID,
            force: force)
    }

    func terminateAll(force: Bool = false) {
        let sessionIDs = Set(terminalSessionIDs.values)
        terminalSessionIDs.removeAll()
        for terminalSessionID in sessionIDs {
            ProcessTreeTerminator.terminateTerminalSession(
                sessionID: terminalSessionID,
                force: force)
        }
    }
}

/// Terminates every process that still belongs to a PTY shell's Unix session.
/// Job-control process groups may change while commands run, while the session
/// ID remains tied to the originating terminal until a process explicitly
/// daemonizes into a new session.
enum ProcessTreeTerminator {
    private static let escalationDelay: DispatchTimeInterval = .milliseconds(500)

    static func terminateTerminalSession(rootPID: pid_t, force: Bool = false) {
        guard rootPID > 1 else { return }
        let terminalSessionID = getsid(rootPID)
        terminateTerminalSession(sessionID: terminalSessionID, force: force)
    }

    static func terminateTerminalSession(sessionID terminalSessionID: pid_t,
                                         force: Bool = false) {
        guard terminalSessionID > 1,
              terminalSessionID != getsid(getpid()) else { return }

        signalProcesses(in: terminalSessionID, signal: SIGTERM)

        if force {
            signalProcesses(in: terminalSessionID, signal: SIGKILL)
        } else {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + escalationDelay) {
                signalProcesses(in: terminalSessionID, signal: SIGKILL)
            }
        }
    }

    private static func signalProcesses(in terminalSessionID: pid_t, signal: Int32) {
        let pids = allProcessIDs().filter {
            $0 > 1 && $0 != getpid() && getsid($0) == terminalSessionID
        }

        // Signal process groups first so commands that are forking during
        // teardown cannot escape the snapshot as easily, then signal each PID
        // as a fallback for unusual group layouts.
        let appProcessGroup = getpgrp()
        let groups = Set(pids.map(getpgid).filter { $0 > 1 && $0 != appProcessGroup })
        for group in groups {
            _ = kill(-group, signal)
        }
        for pid in pids {
            _ = kill(pid, signal)
        }
    }

    private static func allProcessIDs() -> [pid_t] {
        let estimatedCount = max(Int(proc_listallpids(nil, 0)), 0)
        guard estimatedCount > 0 else { return [] }

        // Leave headroom for processes created between the sizing and data
        // calls. A truncated snapshot is still safe and the escalation takes a
        // fresh snapshot 500 ms later.
        var pids = [pid_t](repeating: 0, count: estimatedCount + 64)
        let byteCount = Int32(pids.count * MemoryLayout<pid_t>.stride)
        let actualCount = proc_listallpids(&pids, byteCount)
        guard actualCount > 0 else { return [] }
        return Array(pids.prefix(min(Int(actualCount), pids.count)))
    }
}
