import Foundation

@MainActor
final class WorkspaceSnapshotStore {
    nonisolated static var defaultFileURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return applicationSupport
            .appendingPathComponent("mTerm", isDirectory: true)
            .appendingPathComponent("workspace-v1.json", isDirectory: false)
    }

    private let fileURL: URL
    private let debounceInterval: TimeInterval
    private var pendingWrite: Task<Void, Never>?

    init(
        fileURL: URL = WorkspaceSnapshotStore.defaultFileURL,
        debounceInterval: TimeInterval = 0.25
    ) {
        self.fileURL = fileURL
        self.debounceInterval = max(debounceInterval, 0)
    }

    var containsStoredSnapshot: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    func load() -> WorkspaceSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
    }

    /// Builds the snapshot lazily inside the debounced task so a burst of
    /// mutations (e.g. a divider-drag stream) only pays the snapshot cost once,
    /// when the write actually happens — not on every intermediate frame.
    func schedule(_ makeSnapshot: @escaping @MainActor () -> WorkspaceSnapshot?) {
        pendingWrite?.cancel()
        let delay = UInt64(debounceInterval * 1_000_000_000)
        pendingWrite = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            pendingWrite = nil
            guard let snapshot = makeSnapshot() else { return }
            write(snapshot)
        }
    }

    func flush(_ snapshot: WorkspaceSnapshot) {
        pendingWrite?.cancel()
        pendingWrite = nil
        write(snapshot)
    }

    private func write(_ snapshot: WorkspaceSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Persistence must never prevent the terminal UI or app quit path
            // from continuing. Atomic writes leave the prior file intact.
        }
    }
}
