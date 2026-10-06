import Foundation

/// Files a remote client attaches to prompts. Agents only read files on the
/// Mac, so each upload is saved here and the prompt carries its path, the way
/// Orca stores mobile clipboard images as host temp files.
struct RemoteAttachmentStore: Sendable {
    static let retention: TimeInterval = 7 * 24 * 60 * 60

    let root: URL

    init(root: URL = RemoteAttachmentStore.defaultRoot) {
        self.root = root
    }

    /// `~/Library/Caches/mTerm/RemoteAttachments`: no spaces, so prompts can
    /// carry the path unquoted.
    static var defaultRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mTerm/RemoteAttachments", isDirectory: true)
    }

    /// One folder per upload keeps the client's file name without clashes.
    func save(_ data: Data, named name: String, id: UUID) throws -> URL {
        let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(Self.safeName(name))
        try data.write(to: file, options: .atomic)
        return file
    }

    /// Drops uploads older than `retention`; a prompt that still names one is
    /// long submitted by then.
    func removeExpired(now: Date = Date()) {
        let manager = FileManager.default
        let folders = (try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for folder in folders {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) > Self.retention {
                try? manager.removeItem(at: folder)
            }
        }
    }

    /// A file name that is safe on disk and needs no quoting in a prompt:
    /// ASCII letters, digits, `.`, `_`, `-`; no path components, no leading
    /// dot, at most 100 characters with the extension kept.
    static func safeName(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        var result = ""
        for scalar in base.folding(options: .diacriticInsensitive, locale: nil).unicodeScalars {
            let allowed = scalar.isASCII
                && (CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "_" || scalar == "-")
            let character: Character = allowed ? Character(scalar) : "-"
            if character == "-", result.last == "-" { continue }
            result.append(character)
        }
        result = String(result.drop { $0 == "." || $0 == "-" })
        while result.last == "-" { result.removeLast() }
        if result.isEmpty { return "attachment" }
        guard result.count > 100 else { return result }
        let ext = (result as NSString).pathExtension
        let suffix = ext.isEmpty || ext.count > 10 ? "" : "." + ext
        return String(result.prefix(100 - suffix.count)) + suffix
    }
}
