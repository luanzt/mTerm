import XCTest
@testable import mTerm

final class ShellIntegrationTests: XCTestCase {
    private func payload(_ s: String) -> ArraySlice<UInt8> {
        ArraySlice(Array(s.utf8))
    }

    func testParseRunCommand() {
        XCTAssertEqual(ShellIntegration.parse(payload("run;claude")), .run(command: "claude"))
        XCTAssertEqual(ShellIntegration.parse(payload("run;git")), .run(command: "git"))
    }

    func testParseIdle() {
        XCTAssertEqual(ShellIntegration.parse(payload("idle")), .idle)
    }

    func testRunWithEmptyCommandIsIdle() {
        // preexec on an empty command line still fires; treat it as idle.
        XCTAssertEqual(ShellIntegration.parse(payload("run;")), .idle)
    }

    func testParseRejectsUnknownAndControlChars() {
        XCTAssertNil(ShellIntegration.parse(payload("hello")))
        XCTAssertNil(ShellIntegration.parse(payload("A")))
        XCTAssertNil(ShellIntegration.parse(ArraySlice([0x72, 0x75, 0x6E, 0x3B, 0x07]))) // "run;\a"
    }

    func testTerminalBaseEnvironmentAdvertisesCapabilitiesAndOwnIdentity() {
        let environment = ShellIntegration.terminalBaseEnvironment(
            inherited: [
                "PATH": "/usr/bin",
                "TERM_PROGRAM": "iTerm.app",
                "ITERM_SESSION_ID": "old-session",
                "KITTY_WINDOW_ID": "42",
                "VTE_VERSION": "6000",
                "WT_SESSION": "old-windows-session",
                "CLAUDECODE": "1",
                "CLAUDE_CODE_SESSION_ID": "old-claude-session",
            ],
            appVersion: "1.2.3")

        XCTAssertEqual(environment["TERM"], "xterm-256color")
        XCTAssertEqual(environment["COLORTERM"], "truecolor")
        XCTAssertEqual(environment["TERM_PROGRAM"], "mTerm")
        XCTAssertEqual(environment["TERM_PROGRAM_VERSION"], "1.2.3")
        XCTAssertEqual(environment["LC_TERMINAL"], "mTerm")
        XCTAssertEqual(environment["LC_TERMINAL_VERSION"], "1.2.3")
        XCTAssertEqual(environment["FORCE_HYPERLINK"], "1")
        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertNil(environment["ITERM_SESSION_ID"])
        XCTAssertNil(environment["KITTY_WINDOW_ID"])
        XCTAssertNil(environment["VTE_VERSION"])
        XCTAssertNil(environment["WT_SESSION"])
        XCTAssertNil(environment["CLAUDECODE"])
        XCTAssertNil(environment["CLAUDE_CODE_SESSION_ID"])
    }

    func testTerminalBaseEnvironmentPreservesHyperlinkOptOut() {
        let environment = ShellIntegration.terminalBaseEnvironment(
            inherited: ["FORCE_HYPERLINK": "0"],
            appVersion: nil)

        XCTAssertEqual(environment["FORCE_HYPERLINK"], "0")
        XCTAssertEqual(environment["TERM_PROGRAM_VERSION"], "0.0.0")
    }

    func testChildEnvironmentInjectsForZsh() {
        let env = ShellIntegration.childEnvironment(
            shell: "/bin/zsh",
            base: ["HOME": "/Users/test", "PATH": "/usr/bin"])
        let map = dictionary(from: env)

        XCTAssertEqual(map["ZDOTDIR"], ShellIntegration.integrationDirectory.path)
        XCTAssertEqual(map["MTERM_USER_ZDOTDIR"], "/Users/test")
        XCTAssertEqual(map[ShellIntegration.marker], "1")
        XCTAssertEqual(map["MTERM_CLAUDE_SHIM_DIR"], ClaudeIntegration.shimDirectory.path)
        XCTAssertEqual(map["MTERM_CODEX_SHIM_DIR"], CodexIntegration.shimDirectory.path)
        XCTAssertEqual(map["PATH"], "/usr/bin")   // base preserved
    }

    func testChildEnvironmentPrefersExistingZdotdir() {
        let env = ShellIntegration.childEnvironment(
            shell: "/usr/local/bin/zsh",
            base: ["HOME": "/Users/test", "ZDOTDIR": "/Users/test/.config/zsh"])
        XCTAssertEqual(dictionary(from: env)["MTERM_USER_ZDOTDIR"], "/Users/test/.config/zsh")
    }

    func testChildEnvironmentDoesNotInjectForNonZsh() {
        for shell in ["/bin/bash", "/usr/bin/fish", "/bin/sh"] {
            let map = dictionary(from: ShellIntegration.childEnvironment(
                shell: shell, base: ["HOME": "/Users/test"]))
            XCTAssertNil(map["ZDOTDIR"], "\(shell) should not be injected")
            XCTAssertNil(map[ShellIntegration.marker])
        }
    }

    func testWritesFourStartupFilesThatSourceUserConfig() throws {
        XCTAssertTrue(ShellIntegration.writeIntegrationFiles())
        let dir = ShellIntegration.integrationDirectory
        for name in [".zshenv", ".zprofile", ".zlogin", ".zshrc"] {
            let url = dir.appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "missing \(name)")
        }
        let zshrc = try String(contentsOf: dir.appendingPathComponent(".zshrc"), encoding: .utf8)
        XCTAssertTrue(zshrc.contains("source"))                 // re-sources user config
        XCTAssertTrue(zshrc.contains("add-zsh-hook preexec"))   // installs hooks
        XCTAssertTrue(zshrc.contains("\(ShellIntegration.oscCode);run;"))
        XCTAssertTrue(zshrc.contains("MTERM_CLAUDE_SHIM_DIR"))
        XCTAssertTrue(zshrc.contains("MTERM_CODEX_SHIM_DIR"))
    }

    private func dictionary(from env: [String]) -> [String: String] {
        var map: [String: String] = [:]
        for entry in env {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            map[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        return map
    }
}
