import Foundation

/// The `/` menu a remote client offers for a session: the agent's built-in
/// commands, then every skill the agent loads for the session's working
/// directory. OMP lists its own skills (`omp skill list --json`, run in that
/// directory), so user, managed, plugin, and project sources match its TUI.
/// Claude Code has no listing command, so its skill and command folders are
/// scanned the way it loads them: project folders from the working directory
/// up, the user folder, then enabled plugins.
enum RemoteCommandCatalog {
    static func load(agent: RemoteAgent?, workingDirectory: String) async -> [RemoteCommand] {
        guard let agent else { return [] }
        let home = FileManager.default.homeDirectoryForCurrentUser
        var directory = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            directory = home
        }
        switch agent {
        case .omp:
            return builtins(for: .omp) + (await ompSkills(in: directory, home: home))
        case .claude:
            return builtins(for: .claude) + claudeEntries(workingDirectory: directory, home: home)
        case .codex:
            return builtins(for: .codex)
        }
    }

    // MARK: - Built-in commands

    /// Curated after Orca's `native-chat-slash-commands.ts`; the CLIs ship no
    /// machine-readable list of their built-ins.
    static func builtins(for agent: RemoteAgent) -> [RemoteCommand] {
        let pairs: [(String, String)]
        switch agent {
        case .claude:
            pairs = [
                ("clear", "Clear conversation history"),
                ("compact", "Summarize and compact the conversation"),
                ("init", "Initialize a CLAUDE.md"),
                ("review", "Review the current changes"),
                ("help", "Show available commands"),
            ]
        case .codex:
            pairs = [
                ("model", "Choose the model and reasoning effort"),
                ("ide", "Include IDE context"),
                ("permissions", "Choose what Codex is allowed to do"),
                ("keymap", "Remap TUI shortcuts"),
                ("vim", "Toggle Vim mode"),
                ("experimental", "Toggle experimental features"),
                ("approve", "Approve one auto-review retry"),
                ("memories", "Configure memory use"),
                ("skills", "Manage and use skills"),
                ("import", "Import setup from Claude Code"),
                ("hooks", "View lifecycle hooks"),
                ("review", "Review the current changes"),
                ("rename", "Rename the current thread"),
                ("new", "Start a new chat"),
                ("archive", "Archive this session and exit"),
                ("delete", "Delete this session and exit"),
                ("resume", "Resume a saved chat"),
                ("fork", "Fork the current chat"),
                ("app", "Continue in Codex Desktop"),
                ("init", "Create an AGENTS.md file"),
                ("compact", "Compact the conversation"),
                ("plan", "Switch to Plan mode"),
                ("goal", "Set or view the goal"),
                ("agent", "Switch the active agent thread"),
                ("side", "Start a side conversation"),
                ("copy", "Copy the last response as markdown"),
                ("raw", "Toggle raw scrollback mode"),
                ("diff", "Show the working diff"),
                ("mention", "Mention a file"),
                ("status", "Show session configuration and usage"),
                ("usage", "View account usage"),
                ("title", "Configure the terminal title"),
                ("statusline", "Configure the status line"),
                ("theme", "Choose a syntax highlighting theme"),
                ("pets", "Choose or hide the terminal pet"),
                ("mcp", "List configured MCP tools"),
                ("plugins", "Browse plugins"),
                ("logout", "Log out of Codex"),
                ("exit", "Exit Codex"),
                ("feedback", "Send logs to maintainers"),
                ("ps", "List background terminals"),
                ("stop", "Stop all background terminals"),
                ("clear", "Clear the terminal and start a new chat"),
                ("personality", "Choose a communication style"),
                ("subagents", "Switch the active agent thread"),
            ]
        case .omp:
            pairs = [
                ("model", "Open the model selector"),
                ("switch", "Open the temporary model selector"),
                ("plan", "Toggle plan mode"),
                ("compact", "Compact conversation context"),
                ("clear", "Clear context while keeping the session"),
                ("new", "Start a new session"),
                ("resume", "Resume a session; without arguments, choose one"),
                ("fork", "Fork from a previous message"),
                ("branch", "Rewind to a previous message"),
                ("tree", "Browse the session tree"),
                ("session", "Show session information and controls"),
                ("rename", "Rename the session"),
                ("context", "Show estimated context usage"),
                ("usage", "Show provider usage and limits"),
                ("fast", "Toggle priority service tier"),
                ("tools", "Show tools visible to the agent"),
                ("jobs", "Show background jobs"),
                ("git", "Open the Git viewer"),
                ("export", "Export the session to HTML"),
                ("settings", "Open settings"),
                ("extensions", "Open the extension dashboard"),
                ("hotkeys", "Show keyboard shortcuts"),
            ]
        }
        return pairs.map { RemoteCommand(name: $0.0, description: $0.1, kind: .command, source: "Built-in") }
    }

    // MARK: - OMP

    private static func ompSkills(in directory: URL, home: URL) async -> [RemoteCommand] {
        let arguments = ["skill", "list", "--json"]
        // A GUI app's PATH lacks the user's tool folders, and `omp` is a Bun
        // script (`#!/usr/bin/env bun`), so its folder must be on PATH too.
        let toolFolders = [
            home.appendingPathComponent(".bun/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (toolFolders + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        if let omp = toolFolders.lazy
            .map({ URL(fileURLWithPath: $0).appendingPathComponent("omp") })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }),
           let data = await run(omp, arguments, in: directory, environment: environment) {
            return ompSkills(fromJSON: data)
        }
        // Anywhere else, only the user's interactive shell knows where omp is.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let data = await run(
            URL(fileURLWithPath: shell),
            ["-l", "-i", "-c", "exec omp " + arguments.joined(separator: " ")],
            in: directory,
            environment: ProcessInfo.processInfo.environment) else { return [] }
        return ompSkills(fromJSON: data)
    }

    /// Parses `omp skill list --json`. Shell startup files may print around
    /// the JSON object, so only the outermost braces are decoded.
    static func ompSkills(fromJSON data: Data) -> [RemoteCommand] {
        struct Listing: Decodable {
            struct Skill: Decodable {
                let name: String
                let description: String?
                let source: String?
            }
            let skills: [Skill]
        }
        guard let start = data.firstIndex(of: UInt8(ascii: "{")),
              let end = data.lastIndex(of: UInt8(ascii: "}")), start < end,
              let listing = try? JSONDecoder().decode(Listing.self, from: data[start...end]) else { return [] }
        return listing.skills.map { skill in
            RemoteCommand(
                name: "skill:\(skill.name)",
                description: collapsed(skill.description ?? ""),
                kind: .skill,
                source: ompSourceLabel(skill.source ?? ""))
        }
    }

    /// `provider:level` (`native:user`, `claude:project`, `omp-managed:user`).
    private static func ompSourceLabel(_ source: String) -> String {
        let parts = source.split(separator: ":", maxSplits: 1).map(String.init)
        if parts.count == 2, parts[1] == "project" { return "Project" }
        switch parts.first ?? "" {
        case "native": return "User"
        case "omp-managed": return "Managed"
        case "claude": return "Claude"
        case "claude-plugins": return "Claude plugin"
        case "agents": return "Agents"
        case "codex": return "Codex"
        case "": return "User"
        case let provider: return provider
        }
    }

    private static func run(
        _ executable: URL,
        _ arguments: [String],
        in directory: URL,
        environment: [String: String]
    ) async -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.currentDirectoryURL = directory
                process.environment = environment
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                // Terminating closes stdout, which ends the read below.
                let timeout = DispatchWorkItem { process.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timeout.cancel()
                continuation.resume(returning: process.terminationStatus == 0 ? data : nil)
            }
        }
    }

    // MARK: - Claude Code

    static func claudeEntries(workingDirectory: URL, home: URL) -> [RemoteCommand] {
        let claudeHome = home.appendingPathComponent(".claude", isDirectory: true)
        let projects = projectDirectories(from: workingDirectory, home: home)
        var entries: [RemoteCommand] = []
        for project in projects {
            let folder = project.appendingPathComponent(".claude", isDirectory: true)
            entries += skills(in: folder.appendingPathComponent("skills"), prefix: "", source: "Project")
            entries += commands(in: folder.appendingPathComponent("commands"), prefix: "", source: "Project")
        }
        entries += skills(in: claudeHome.appendingPathComponent("skills"), prefix: "", source: "User")
        entries += commands(in: claudeHome.appendingPathComponent("commands"), prefix: "", source: "User")
        for plugin in enabledPlugins(claudeHome: claudeHome, projects: projects) {
            entries += skills(in: plugin.root.appendingPathComponent("skills"),
                              prefix: plugin.name + ":", source: plugin.name)
            entries += commands(in: plugin.root.appendingPathComponent("commands"),
                                prefix: plugin.name + ":", source: plugin.name)
        }
        // The nearest definition of a name wins.
        var seen: Set<String> = []
        return entries.filter { seen.insert($0.name).inserted }
    }

    /// The working directory and its parents, nearest first, stopping below
    /// the home folder, whose `.claude` is the user folder.
    private static func projectDirectories(from directory: URL, home: URL) -> [URL] {
        let homePath = home.standardizedFileURL.path
        var result: [URL] = []
        var current = directory.standardizedFileURL
        while current.path != homePath, current.path != "/" {
            result.append(current)
            current = current.deletingLastPathComponent()
        }
        return result
    }

    private static func skills(in folder: URL, prefix: String, source: String) -> [RemoteCommand] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return children
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { child in
                guard let text = head(of: child.appendingPathComponent("SKILL.md")) else { return nil }
                let fields = frontmatter(text)
                let name = fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? child.lastPathComponent
                return RemoteCommand(
                    name: prefix + name,
                    description: collapsed(fields["description"] ?? ""),
                    kind: .skill,
                    source: source)
            }
    }

    /// Markdown command files; a sub-folder becomes a `folder:` namespace.
    private static func commands(in folder: URL, prefix: String, source: String) -> [RemoteCommand] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        let root = folder.standardizedFileURL.path + "/"
        var result: [RemoteCommand] = []
        for case let file as URL in enumerator where file.pathExtension == "md" {
            guard let text = head(of: file) else { continue }
            let relative = String(file.standardizedFileURL.deletingPathExtension().path.dropFirst(root.count))
            let fields = frontmatter(text)
            result.append(RemoteCommand(
                name: prefix + relative.replacingOccurrences(of: "/", with: ":"),
                description: collapsed(fields["description"] ?? firstBodyLine(text)),
                kind: .command,
                source: source))
        }
        return result.sorted { $0.name < $1.name }
    }

    private struct Plugin {
        let name: String
        let root: URL
    }

    /// Plugins installed in `plugins/installed_plugins.json` and enabled by
    /// `enabledPlugins` in the user settings, overridden by project settings.
    private static func enabledPlugins(claudeHome: URL, projects: [URL]) -> [Plugin] {
        var enabled: [String: Bool] = [:]
        let settingsFiles = [claudeHome.appendingPathComponent("settings.json")]
            + projects.reversed().flatMap { project in
                ["settings.json", "settings.local.json"].map {
                    project.appendingPathComponent(".claude").appendingPathComponent($0)
                }
            }
        for file in settingsFiles {
            guard let object = jsonObject(at: file),
                  let plugins = object["enabledPlugins"] as? [String: Bool] else { continue }
            enabled.merge(plugins) { _, new in new }
        }

        guard let installed = jsonObject(at: claudeHome.appendingPathComponent("plugins/installed_plugins.json")),
              let plugins = installed["plugins"] as? [String: [[String: Any]]] else { return [] }
        let projectPaths = Set(projects.map(\.path))
        return plugins.keys.sorted().compactMap { key in
            guard enabled[key] == true,
                  let install = plugins[key]?.first(where: { entry in
                      (entry["projectPath"] as? String).map(projectPaths.contains) ?? true
                  }),
                  let path = install["installPath"] as? String else { return nil }
            let name = key.split(separator: "@", maxSplits: 1).first.map(String.init) ?? key
            return Plugin(name: name, root: URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    // MARK: - Parsing

    /// The leading part of a file: frontmatter and first lines are enough.
    private static func head(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16 * 1024) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func jsonObject(at file: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Top-level scalar keys of a `---` YAML frontmatter block. Folded and
    /// literal block scalars and plain continuation lines join with spaces,
    /// which is all a one-line menu description needs.
    static func frontmatter(_ text: String) -> [String: String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasSuffix("\r") ? $0.dropLast() : $0 }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var result: [String: String] = [:]
        var key: String?
        var parts: [String] = []
        func flush() {
            guard let key else { return }
            result[key] = unquoted(parts.joined(separator: " "))
        }
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            if let first = line.first, first != " ", first != "\t", first != "#",
               let colon = line.firstIndex(of: ":") {
                flush()
                key = line[..<colon].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                parts = value.isEmpty || ["|", ">", "|-", ">-", "|+", ">+"].contains(value) ? [] : [value]
            } else if key != nil, !trimmed.isEmpty {
                parts.append(trimmed)
            }
        }
        flush()
        return result
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" else {
            return value
        }
        let inner = String(value.dropFirst().dropLast())
        if first == "'" {
            return inner.replacingOccurrences(of: "''", with: "'")
        }
        return inner
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    /// First prose line after any frontmatter, for commands without a
    /// `description`.
    private static func firstBodyLine(_ text: String) -> String {
        var lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") {
            lines.removeSubrange(...close)
        }
        let line = lines.first { !$0.isEmpty } ?? ""
        return line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
    }

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
