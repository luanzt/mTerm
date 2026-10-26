import AppKit

/// Opens a workspace folder in LiteCode. LiteCode maps an opened folder to its
/// workspace tab, activating an existing one rather than adding a duplicate,
/// so a plain document open is the whole protocol.
@MainActor
enum LiteCodeIntegration {
    static let bundleIdentifier = "dev.luan.litecode"

    /// The running copy first, so a second installed copy (such as a local
    /// build) never starts a parallel instance; otherwise Launch Services' pick.
    static var applicationURL: URL? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    static func open(_ workspace: WorkspaceFolder) {
        guard let applicationURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: workspace.path, isDirectory: true)],
            withApplicationAt: applicationURL,
            configuration: configuration
        ) { _, error in
            guard let error else { return }
            Task { @MainActor in
                NSAlert(error: error).runModal()
            }
        }
    }
}
