import AppKit
import SwiftUI

/// Settings › Remote: enables the iPad server and shares the pairing link.
struct RemoteSettingsView: View {
    @EnvironmentObject private var remote: RemoteControl
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("iPad Remote")
                .font(.headline)

            Toggle("Allow paired devices to control terminals", isOn: Binding(
                get: { remote.isEnabled },
                set: { remote.setEnabled($0) }))

            Text("A paired iPad renders its own terminal. While it drives a session, that session's size follows the iPad; typing or clicking in the pane on this Mac takes it back.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if remote.isEnabled {
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                    GridRow {
                        Text("Status")
                        Text(statusText)
                            .foregroundStyle(statusIsError ? Color.red : Color.secondary)
                    }
                    GridRow {
                        Text("Connected")
                        Text(remote.connectedClientNames.isEmpty
                             ? "No devices"
                             : remote.connectedClientNames.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Pairing")
                    .font(.headline)
                    .padding(.top, 4)

                Text("Copy the link, then paste it in mTerm on the iPad (Universal Clipboard works). Anyone with this link can control your terminals.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button(didCopy ? "Copied" : "Copy Pairing Link") {
                        remote.refreshPairing()
                        guard let link = remote.pairing?.url.absoluteString else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link, forType: .string)
                        didCopy = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { didCopy = false }
                    }
                    .disabled(remote.pairing == nil)

                    Button("Reset Key…", role: .destructive) {
                        let alert = NSAlert()
                        alert.messageText = "Reset the pairing key?"
                        alert.informativeText = "Every paired device is disconnected and must paste a new link."
                        alert.addButton(withTitle: "Reset")
                        alert.addButton(withTitle: "Cancel")
                        if alert.runModal() == .alertFirstButtonReturn {
                            remote.regenerateKey()
                        }
                    }
                }

                if let hosts = remote.pairing?.hosts, !hosts.isEmpty {
                    Text("Reachable at \(hosts.joined(separator: ", ")) · port \(String(remote.port))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Spacer()
        }
        .padding(8)
        .onAppear { remote.refreshPairing() }
    }

    private var statusText: String {
        switch remote.serverState {
        case .stopped: "Stopped"
        case .starting: "Starting…"
        case .ready(let port): "Listening on port \(port)"
        case .failed(let message): "Failed: \(message)"
        }
    }

    private var statusIsError: Bool {
        if case .failed = remote.serverState { return true }
        return false
    }
}

/// Shown over a pane whose size currently follows a remote device.
struct RemoteDriverBanner: View {
    let deviceName: String
    let reclaim: () -> Void

    var body: some View {
        Button(action: reclaim) {
            HStack(spacing: 8) {
                Image(systemName: "ipad.landscape")
                Text("Sized for \(deviceName) — click to take back")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(MTermTheme.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(MTermTheme.header.opacity(0.94)))
            .overlay(Capsule().stroke(MTermTheme.accent.opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
