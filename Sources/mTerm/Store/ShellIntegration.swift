import Foundation

/// Event-driven detection of the foreground command in a pane, the way Warp /
/// VS Code / iTerm2 do it: injected zsh `preexec`/`precmd` hooks emit a custom
/// OSC 633 marker on every command start/finish, and mTerm listens for it through
/// SwiftTerm's `registerOscHandler`. No polling.
///
/// Marker payloads (the bytes after `OSC 633 ;`):
///   `run;<cmd>`  — a command started; `<cmd>` is the basename of its first word
///   `idle`       — back at the prompt (no command running)
///
/// Injection is zsh-only. For any other shell `childEnvironment` returns the base
/// environment unchanged, so those panes simply never report a command — there is
/// no fallback by design.
enum ShellIntegration {
    enum Event: Equatable {
        case run(command: String)
        case idle
    }

    /// The OSC code the hooks emit on. SwiftTerm consults registered handlers
    /// before its built-in OSC switch, and 633 is not used by any built-in.
    static let oscCode = 633

    // MARK: Marker parsing

    /// Map an OSC 633 payload to an event, or nil if it is not one of ours.
    /// Rejects payloads containing control characters (defensive against a program
    /// that happens to emit 633 with binary data).
    static func parse(_ payload: ArraySlice<UInt8>) -> Event? {
        guard payload.allSatisfy({ $0 >= 0x20 || $0 == 0x09 }) else { return nil }
        guard let text = String(bytes: payload, encoding: .utf8) else { return nil }
        let fields = text.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        switch fields.first {
        case "idle":
            return .idle
        case "run":
            guard fields.count >= 2 else { return nil }
            let cmd = fields[1].trimmingCharacters(in: .whitespaces)
            return cmd.isEmpty ? .idle : .run(command: cmd)
        default:
            return nil
        }
    }

    // MARK: Shell injection (zsh)

    /// The name mTerm's generated `.zshrc` guards on so the hooks install once.
    static let marker = "MTERM_SHELL_INTEGRATION"

    /// Build the base environment for a fresh mTerm pane. Besides identifying
    /// the terminal accurately, advertise capabilities that cannot be inferred
    /// from the generic `xterm-256color` terminfo entry. In particular, popular
    /// CLI renderers use `FORCE_HYPERLINK` to decide whether to emit OSC 8 links
    /// with a short visible label or fall back to printing the full URL.
    ///
    /// Preserve an explicit `FORCE_HYPERLINK=0` so users can opt out.
    static func terminalBaseEnvironment(
        inherited: [String: String],
        appVersion: String?
    ) -> [String: String] {
        var environment = inherited
        let version = appVersion.flatMap { $0.isEmpty ? nil : $0 } ?? "0.0.0"

        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "mTerm"
        environment["TERM_PROGRAM_VERSION"] = version
        environment["LC_TERMINAL"] = "mTerm"
        environment["LC_TERMINAL_VERSION"] = version
        if environment["FORCE_HYPERLINK"] == nil {
            environment["FORCE_HYPERLINK"] = "1"
        }

        // A pane is a fresh terminal, not a child of whatever launched mTerm.
        // Remove terminal/session identities that would otherwise make tools
        // believe they are still running in iTerm, Kitty, VTE, or Windows
        // Terminal, and remove Claude markers that trigger nested-session mode.
        for key in [
            "ITERM_SESSION_ID",
            "KITTY_WINDOW_ID",
            "VTE_VERSION",
            "WT_SESSION",
        ] {
            environment.removeValue(forKey: key)
        }
        for key in environment.keys
            where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") {
            environment.removeValue(forKey: key)
        }
        return environment
    }

    /// Directory holding the generated zsh startup files.
    static var integrationDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("mTerm/shell-integration", isDirectory: true)
    }

    /// Child environment (as `"KEY=VALUE"` strings) with `ZDOTDIR` redirected to
    /// mTerm's integration directory so the injected hooks load. Returns `base`
    /// untouched for non-zsh shells. Writes/refreshes the four zsh startup files
    /// idempotently.
    ///
    /// - Parameters:
    ///   - shell: the shell executable path (e.g. `/bin/zsh`).
    ///   - base: the base environment as a `[key: value]` map.
    static func childEnvironment(shell: String, base: [String: String]) -> [String] {
        func flatten(_ env: [String: String]) -> [String] {
            env.map { "\($0.key)=\($0.value)" }
        }

        guard URL(fileURLWithPath: shell).lastPathComponent == "zsh" else {
            return flatten(base)
        }
        guard writeIntegrationFiles() else { return flatten(base) }

        var env = base
        // The user's real ZDOTDIR (where their own dotfiles live), so our wrappers
        // can re-source them. Falls back to $HOME, zsh's default.
        env[marker] = "1"
        env["MTERM_USER_ZDOTDIR"] = base["ZDOTDIR"] ?? base["HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        env["ZDOTDIR"] = integrationDirectory.path
        if ClaudeIntegration.writeFiles() {
            env["MTERM_CLAUDE_SHIM_DIR"] = ClaudeIntegration.shimDirectory.path
        }
        if CodexIntegration.writeFiles() {
            env["MTERM_CODEX_SHIM_DIR"] = CodexIntegration.shimDirectory.path
        }
        return flatten(env)
    }

    /// Writes the four zsh startup files. Setting `ZDOTDIR` redirects *all* of
    /// them, so each must re-source the user's original. Returns false if the
    /// directory could not be created (caller then skips injection).
    @discardableResult
    static func writeIntegrationFiles() -> Bool {
        let dir = integrationDirectory
        do {
            try FileManager.default.createDirectory(at: dir,
                                                    withIntermediateDirectories: true)
        } catch {
            return false
        }
        let files: [String: String] = [
            ".zshenv": zshenv,
            ".zprofile": passthrough(userFile: ".zprofile", isFinal: false),
            ".zlogin": passthrough(userFile: ".zlogin", isFinal: true),
            ".zshrc": zshrc,
        ]
        for (name, contents) in files {
            let url = dir.appendingPathComponent(name)
            try? contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return true
    }

    // ZDOTDIR handling: setting ZDOTDIR redirects *all* zsh startup files to our
    // integration dir, so each generated file must re-source the matching user
    // file. Critically, ZDOTDIR must stay pointed at the integration dir *between*
    // files so zsh keeps finding the next generated file — we only point it at the
    // user dir while sourcing, then restore it. The last file to run leaves it at
    // the user dir so tools see the real value.

    /// `.zshenv` runs first for every zsh. Snapshot the integration dir, source
    /// the user's `.zshenv` (which may itself reassign ZDOTDIR — we then treat that
    /// as the real user dir), and restore ZDOTDIR to the integration dir.
    private static let zshenv = """
    # mTerm shell integration — do not edit (generated).
    MTERM_INT_ZDOTDIR="$ZDOTDIR"
    ZDOTDIR="${MTERM_USER_ZDOTDIR:-$HOME}"
    [ -f "$ZDOTDIR/.zshenv" ] && source "$ZDOTDIR/.zshenv"
    MTERM_USER_ZDOTDIR="$ZDOTDIR"
    ZDOTDIR="$MTERM_INT_ZDOTDIR"
    """

    /// `.zprofile` / `.zlogin`: source the user's version. `.zprofile` restores
    /// ZDOTDIR to the integration dir (more files follow); `.zlogin` is last on a
    /// login shell, so it leaves ZDOTDIR at the user dir.
    private static func passthrough(userFile: String, isFinal: Bool) -> String {
        let tail = isFinal ? "" : "\nZDOTDIR=\"$MTERM_INT_ZDOTDIR\""
        return """
        # mTerm shell integration — do not edit (generated).
        ZDOTDIR="${MTERM_USER_ZDOTDIR:-$HOME}"
        [ -f "$ZDOTDIR/\(userFile)" ] && source "$ZDOTDIR/\(userFile)"\(tail)
        """
    }

    /// `.zshrc` sources the user's `.zshrc` first (so powerlevel10k et al. init
    /// exactly as before), then installs the hooks. The hooks print nothing at
    /// load time, so p10k's instant prompt is unaffected. It leaves ZDOTDIR at the
    /// user dir (it is the last file to run for the interactive shells mTerm
    /// launches).
    private static let zshrc = """
    # mTerm shell integration — do not edit (generated).
    ZDOTDIR="${MTERM_USER_ZDOTDIR:-$HOME}"
    [ -f "$ZDOTDIR/.zshrc" ] && source "$ZDOTDIR/.zshrc"

    if [[ -n "$\(marker)" && -z "$_mterm_hooks_installed" ]]; then
      _mterm_hooks_installed=1
      autoload -Uz add-zsh-hook 2>/dev/null
      _mterm_preexec() { printf '\\e]\(oscCode);run;%s\\a' "${${1%% *}:t}" }
      _mterm_precmd()  { printf '\\e]\(oscCode);idle\\a' }
      add-zsh-hook preexec _mterm_preexec 2>/dev/null
      add-zsh-hook precmd  _mterm_precmd  2>/dev/null
    fi

    # Load agent notification shims without changing user/project settings.
    # Keep a user's function or alias precedence intact; ordinary executable
    # lookup reaches the matching shim.
    for _mterm_shim_dir in "$MTERM_CLAUDE_SHIM_DIR" "$MTERM_CODEX_SHIM_DIR"; do
      if [[ -n "$_mterm_shim_dir" && -d "$_mterm_shim_dir" ]]; then
        path=("$_mterm_shim_dir" ${path:#"$_mterm_shim_dir"})
      fi
    done
    unset _mterm_shim_dir
    export PATH
    """
}
