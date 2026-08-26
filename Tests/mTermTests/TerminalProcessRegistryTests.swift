import Darwin
import XCTest
@testable import mTerm

@MainActor
final class TerminalProcessRegistryTests: XCTestCase {
    func testTerminateEscalatesAndKillsARealTerminalProcessTree() throws {
        let terminal = Process()
        terminal.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        terminal.arguments = [
            "-q", "/dev/null", "/bin/sh", "-c",
            "trap '' TERM; while :; do sleep 1; done",
        ]
        terminal.standardOutput = FileHandle.nullDevice
        terminal.standardError = FileHandle.nullDevice
        try terminal.run()

        defer {
            if terminal.isRunning {
                terminal.terminate()
            }
        }

        let shellPID = try waitForChild(of: terminal.processIdentifier)
        let childPID = try waitForChild(of: shellPID)
        XCTAssertEqual(getsid(shellPID), shellPID)
        XCTAssertEqual(getsid(childPID), shellPID)

        let registry = TerminalProcessRegistry()
        let sessionID = UUID()
        registry.register(sessionID, shellPID: shellPID)
        registry.terminate(sessionID)

        XCTAssertTrue(waitUntilProcessExits(shellPID, timeout: 2))
        XCTAssertTrue(waitUntilProcessExits(childPID, timeout: 2))
    }

    func testTerminateAllForceKillsEveryRegisteredTerminalProcessTree() throws {
        let first = try launchTerminalProcessTree()
        let second = try launchTerminalProcessTree()
        defer {
            for terminal in [first.process, second.process] where terminal.isRunning {
                terminal.terminate()
            }
        }
        let registry = TerminalProcessRegistry()
        registry.register(UUID(), shellPID: first.shellPID)
        registry.register(UUID(), shellPID: second.shellPID)

        registry.terminateAll(force: true)

        for pid in [first.shellPID, first.childPID, second.shellPID, second.childPID] {
            XCTAssertTrue(waitUntilProcessExits(pid, timeout: 2), "PID \(pid) survived quit cleanup")
        }
    }

    private func launchTerminalProcessTree() throws -> (
        process: Process,
        shellPID: pid_t,
        childPID: pid_t
    ) {
        let terminal = Process()
        terminal.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        terminal.arguments = [
            "-q", "/dev/null", "/bin/sh", "-c",
            "trap '' TERM; while :; do sleep 1; done",
        ]
        terminal.standardOutput = FileHandle.nullDevice
        terminal.standardError = FileHandle.nullDevice
        try terminal.run()
        let shellPID = try waitForChild(of: terminal.processIdentifier)
        let childPID = try waitForChild(of: shellPID)
        return (terminal, shellPID, childPID)
    }

    private func waitForChild(of parentPID: pid_t,
                              timeout: TimeInterval = 2) throws -> pid_t {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            var children = [pid_t](repeating: 0, count: 32)
            let bytes = Int32(children.count * MemoryLayout<pid_t>.stride)
            let count = proc_listchildpids(parentPID, &children, bytes)
            if count > 0, let child = children.prefix(Int(count)).first(where: { $0 > 1 }) {
                return child
            }
            usleep(10_000)
        } while Date() < deadline
        throw ProcessTestError.childDidNotStart(parentPID)
    }

    private func waitUntilProcessExits(_ pid: pid_t,
                                       timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if kill(pid, 0) == -1 && errno == ESRCH {
                return true
            }
            usleep(10_000)
        } while Date() < deadline
        return false
    }
}

private enum ProcessTestError: Error {
    case childDidNotStart(pid_t)
}
