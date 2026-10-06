import XCTest
@testable import mTerm

final class RemoteCommandCatalogTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteCommandCatalogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, to relativePath: String) throws {
        let file = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: Frontmatter

    func testFrontmatterReadsQuotedFoldedAndContinuedValues() {
        let text = """
            ---
            name: "pr-review"
            description: >-
              Review a pull request
              against the rubric.
            allowed-tools:
              - Read
            note: plain value
              continued here
            ---
            # Body
            """
        let fields = RemoteCommandCatalog.frontmatter(text)
        XCTAssertEqual(fields["name"], "pr-review")
        XCTAssertEqual(fields["description"], "Review a pull request against the rubric.")
        XCTAssertEqual(fields["note"], "plain value continued here")
    }

    func testFrontmatterRequiresLeadingFence() {
        XCTAssertEqual(RemoteCommandCatalog.frontmatter("name: x\n---\n"), [:])
    }

    // MARK: OMP

    func testOMPMenuComesFromTheRPCResponseAmongEventsAndShellNoise() {
        let commands = [
            #"{"name":"fast","description":"Toggle fast mode","input":{"hint":"[on|ultra|off|status]"},"source":"builtin"}"#,
            #"{"name":"skill:writing-plans","description":"Plan\n  multi-step work","source":"skill"}"#,
            #"{"name":"codex:review","description":"Review with Codex","source":"file"}"#,
            #"{"name":"autoresearch","source":"extension"}"#,
        ].joined(separator: ",")
        let output = [
            "Last login: Mon",
            #"{"type":"ready"}"#,
            #"{"type":"response","id":"other","data":{"commands":[{"name":"stale","source":"builtin"}]}}"#,
            #"{"type":"available_commands_update"}"#,
            #"{"type":"response","command":"get_available_commands","id":"mterm-commands","data":{"commands":["#
                + commands + "]}}",
        ].joined(separator: "\n")
        XCTAssertEqual(RemoteCommandCatalog.ompCommands(fromRPC: Data(output.utf8)), [
            RemoteCommand(name: "fast", description: "Toggle fast mode", kind: .command, source: "Built-in",
                          hint: "[on|ultra|off|status]"),
            RemoteCommand(name: "skill:writing-plans", description: "Plan multi-step work", kind: .skill,
                          source: "Skill"),
            RemoteCommand(name: "codex:review", description: "Review with Codex", kind: .command, source: "Command"),
            RemoteCommand(name: "autoresearch", description: "", kind: .command, source: "Extension"),
        ])
    }

    func testOMPOutputWithoutTheResponseYieldsNothing() {
        XCTAssertEqual(RemoteCommandCatalog.ompCommands(fromRPC: Data("command not found: omp".utf8)), [])
    }

    // MARK: Claude Code

    func testClaudeScansProjectUserAndEnabledPluginsNearestFirst() throws {
        let home = root.appendingPathComponent("home", isDirectory: true)
        let repo = home.appendingPathComponent("code/repo", isDirectory: true)
        let workingDirectory = repo.appendingPathComponent("app", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        try write("---\nname: fix-bug\ndescription: Project fix\n---\n", to: "home/code/repo/.claude/skills/fix-bug/SKILL.md")
        try write("---\ndescription: User fix\n---\n", to: "home/.claude/skills/fix-bug/SKILL.md")
        try write("---\ndescription: Debug systematically\n---\n", to: "home/.claude/skills/debugging/SKILL.md")
        try write("# Ship the release\n\nSteps…", to: "home/.claude/commands/release/ship.md")
        try write("---\nname: brainstorming\ndescription: Explore ideas\n---\n",
                  to: "plugins/superpowers/skills/brainstorming/SKILL.md")
        try write("---\ndescription: Commit staged work\n---\n", to: "plugins/commit-commands/commands/commit.md")
        try write("---\ndescription: Hidden\n---\n", to: "plugins/off/skills/off/SKILL.md")
        let plugins = root.appendingPathComponent("plugins").path
        try write("""
            {"version":2,"plugins":{
              "superpowers@official":[{"scope":"user","installPath":"\(plugins)/superpowers"}],
              "commit-commands@official":[{"scope":"user","installPath":"\(plugins)/commit-commands"}],
              "off@official":[{"scope":"user","installPath":"\(plugins)/off"}]
            }}
            """, to: "home/.claude/plugins/installed_plugins.json")
        try write(#"{"enabledPlugins":{"superpowers@official":true,"off@official":true,"commit-commands@official":false}}"#,
                  to: "home/.claude/settings.json")
        // Project settings override the user's choices.
        try write(#"{"enabledPlugins":{"off@official":false,"commit-commands@official":true}}"#,
                  to: "home/code/repo/.claude/settings.json")

        let entries = RemoteCommandCatalog.claudeEntries(workingDirectory: workingDirectory, home: home)
        XCTAssertEqual(entries, [
            RemoteCommand(name: "fix-bug", description: "Project fix", kind: .skill, source: "Project"),
            RemoteCommand(name: "debugging", description: "Debug systematically", kind: .skill, source: "User"),
            RemoteCommand(name: "release:ship", description: "Ship the release", kind: .command, source: "User"),
            RemoteCommand(name: "commit-commands:commit", description: "Commit staged work", kind: .command,
                          source: "commit-commands"),
            RemoteCommand(name: "superpowers:brainstorming", description: "Explore ideas", kind: .skill,
                          source: "superpowers"),
        ])
    }

    func testClaudeInHomeFolderReadsOnlyUserFolder() throws {
        let home = root.appendingPathComponent("home", isDirectory: true)
        try write("---\ndescription: Mine\n---\n", to: "home/.claude/skills/mine/SKILL.md")
        let entries = RemoteCommandCatalog.claudeEntries(workingDirectory: home, home: home)
        XCTAssertEqual(entries.map(\.name), ["mine"])
        XCTAssertEqual(entries.first?.source, "User")
    }
}
