import Foundation

/// Resolves Codex's automatic conversation title from its local metadata store.
///
/// Codex's `thread-title` terminal-title item emits the manually assigned thread
/// name, but falls back to the thread UUID while an unnamed chat is active. The
/// automatic title shown by Codex's session picker lives in the `threads` table,
/// so mTerm reads only that row's `name`/`title` metadata. It never opens or
/// parses the rollout transcript.
enum CodexThreadTitleResolver {
    static var defaultCodexHome: URL {
        if let configured = ProcessInfo.processInfo.environment["CODEX_HOME"],
           !configured.isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath,
                       isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    static func threadID(from terminalTitle: String) -> UUID? {
        let trimmed = terminalTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 36 else { return nil }
        return UUID(uuidString: trimmed)
    }

    static func title(
        for threadID: UUID,
        codexHome: URL = defaultCodexHome
    ) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: readTitle(
                    for: threadID,
                    codexHome: codexHome))
            }
        }
    }

    static func threadID(
        forExactName name: String,
        workingDirectory: String,
        codexHome: URL = defaultCodexHome
    ) async -> UUID? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: readThreadID(
                    forExactName: name,
                    workingDirectory: workingDirectory,
                    codexHome: codexHome))
            }
        }
    }

    /// Synchronous core kept internal for focused resolver tests. Call `title`
    /// from app code so sqlite work never blocks the main actor.
    static func readTitle(
        for threadID: UUID,
        codexHome: URL,
        sqliteExecutable: URL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    ) -> String? {
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: sqliteExecutable.path),
              let candidates = try? manager.contentsOfDirectory(
                at: codexHome,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else {
            return nil
        }

        let databases = candidates
            .filter {
                $0.lastPathComponent.hasPrefix("state_")
                    && $0.pathExtension == "sqlite"
            }
            .sorted {
                let lhs = (try? $0.resourceValues(
                    forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhs = (try? $1.resourceValues(
                    forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhs > rhs
            }

        let id = threadID.uuidString.lowercased()
        let query = """
        SELECT COALESCE(NULLIF(TRIM(name), ''), NULLIF(TRIM(title), '')) AS title
        FROM threads
        WHERE id = '\(id)'
        LIMIT 1;
        """

        for database in databases {
            let process = Process()
            let output = Pipe()
            process.executableURL = sqliteExecutable
            process.arguments = ["-readonly", "-json", database.path, query]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                continue
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let title = rows.first?["title"] as? String,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            return title
        }

        return nil
    }

    /// Resolves a named thread without interpolating user-controlled text into
    /// SQL. The sqlite process returns metadata rows; Swift applies the exact
    /// name/CWD match and accepts only one distinct, valid UUID.
    static func readThreadID(
        forExactName name: String,
        workingDirectory: String,
        codexHome: URL,
        sqliteExecutable: URL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    ) -> UUID? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: sqliteExecutable.path),
              let candidates = try? manager.contentsOfDirectory(
                at: codexHome,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]) else {
            return nil
        }

        // Unlike readTitle, the outcome here depends only on global uniqueness
        // (exactly one distinct matching UUID across all databases), so scan
        // order is irrelevant and recency sorting would be pure overhead.
        let databases = candidates
            .filter {
                $0.lastPathComponent.hasPrefix("state_")
                    && $0.pathExtension == "sqlite"
            }
        let expectedDirectory = URL(fileURLWithPath: workingDirectory)
            .standardizedFileURL.path
        let query = "SELECT id, name, cwd FROM threads WHERE name IS NOT NULL;"
        var matches = Set<UUID>()

        for database in databases {
            let process = Process()
            let output = Pipe()
            process.executableURL = sqliteExecutable
            process.arguments = ["-readonly", "-json", database.path, query]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                continue
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                continue
            }

            for row in rows {
                guard let rowName = row["name"] as? String,
                      rowName == name,
                      let rowDirectory = row["cwd"] as? String,
                      URL(fileURLWithPath: rowDirectory).standardizedFileURL.path
                        == expectedDirectory,
                      let idText = row["id"] as? String,
                      let id = UUID(uuidString: idText) else {
                    continue
                }
                matches.insert(id)
                if matches.count > 1 { return nil }
            }
        }

        return matches.count == 1 ? matches.first : nil
    }
}
