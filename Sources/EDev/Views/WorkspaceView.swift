import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceView: View {
    @EnvironmentObject private var workspace: WorkspaceStore

    var body: some View {
        HStack(spacing: 0) {
            if workspace.isSidebarVisible {
                WorkspaceSidebar()
                Divider()
            }
            VStack(spacing: 0) {
                WorkspaceToolbar()
                SessionTabStrip()
                TerminalDeck()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct WorkspaceSidebar: View {
    @EnvironmentObject private var workspace: WorkspaceStore

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sidebarAction("New terminal", icon: "plus") {
                        workspace.createSession()
                    }
                    sidebarSection("OPEN SESSIONS") {
                        ForEach(workspace.sessions.filter { $0.workspaceID == nil }) { session in
                            SessionSidebarRow(session: session)
                        }
                    }
                    sidebarAction("Open workspace", icon: "folder.badge.plus") {
                        workspace.chooseWorkspace()
                    }
                    if !workspace.workspaces.isEmpty {
                        sidebarSection("WORKSPACES") {
                            ForEach(workspace.workspaces) { folder in
                                WorkspaceFolderRow(folder: folder)
                                ForEach(workspace.sessions.filter { $0.workspaceID == folder.id }) { session in
                                    SessionSidebarRow(session: session, isNested: true)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 16)
                .padding(.bottom, 14)
            }
        }
        .frame(width: 250)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    @ViewBuilder
    private func sidebarSection<Content: View>(_ title: String,
                                               @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
            content()
        }
    }

    private func sidebarAction(_ title: String,
                               icon: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}

private struct WorkspaceFolderRow: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    let folder: WorkspaceFolder

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text(folder.name)
                .lineLimit(1)
            Spacer()
            Button {
                workspace.createSession(in: folder)
            } label: {
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Open terminal in \(folder.name)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

private struct SessionSidebarRow: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    let session: SessionRecord
    var isNested = false

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(session.status == .running ? Color.green : .secondary)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .lineLimit(1)
                Text(URL(fileURLWithPath: session.workingDirectory).lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                workspace.close(session)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .help("Close \(session.title)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(session.id == workspace.selectedSessionID ? Color.accentColor.opacity(0.18) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.leading, isNested ? 12 : 0)
        .contentShape(Rectangle())
        .onTapGesture {
            workspace.selectedSessionID = session.id
        }
        .contextMenu {
            Button("Close") { workspace.close(session) }
        }
    }
}

private struct WorkspaceToolbar: View {
    @EnvironmentObject private var workspace: WorkspaceStore

    var body: some View {
        HStack(spacing: 10) {
            Text(workspace.splitSessionIDs.isEmpty ? "Workspace" : "Split workspace")
                .font(.headline)
            Spacer()
            if workspace.splitSessionIDs.isEmpty {
                Button(action: workspace.splitSelectedSession) {
                    Label("Split", systemImage: "rectangle.split.2x1")
                }
                .disabled(workspace.selectedSession == nil)
            } else {
                Button(action: workspace.closeSplit) {
                    Label("Single view", systemImage: "rectangle")
                }
            }
            Button(action: workspace.createSession) {
                Label("New", systemImage: "plus")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(.bar)
    }
}

private struct SessionTabStrip: View {
    @EnvironmentObject private var workspace: WorkspaceStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(workspace.sessions) { session in
                    SessionTab(session: session)
                }
            }
            .padding(8)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct TerminalDeck: View {
    @EnvironmentObject private var workspace: WorkspaceStore

    var body: some View {
        GeometryReader { proxy in
            let displayed = workspace.displayedSessions
            let splitFraction = workspace.splitFraction
            ZStack {
                ForEach(workspace.sessions) { session in
                    let index = displayed.firstIndex(of: session)
                    TerminalPane(session: session,
                                 isVisible: index != nil)
                        .frame(width: tileWidth(index: index,
                                                 count: displayed.count,
                                                 total: proxy.size.width,
                                                 fraction: splitFraction),
                               height: proxy.size.height)
                        .position(x: tileX(index: index,
                                            count: displayed.count,
                                            total: proxy.size.width,
                                            fraction: splitFraction),
                                  y: proxy.size.height / 2)
                        .opacity(index == nil ? 0 : 1)
                        .allowsHitTesting(index != nil)
                }
                if displayed.count == 2 {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: 5, height: proxy.size.height)
                        .position(x: proxy.size.width * splitFraction,
                                  y: proxy.size.height / 2)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            workspace.resizeSplit(to: value.location.x / proxy.size.width)
                        })
                        .help("Drag to resize panes")
                }
            }
        }
        .background(Color.black)
    }

    private func tileWidth(index: Int?, count: Int, total: CGFloat, fraction: CGFloat) -> CGFloat {
        guard index != nil, count == 2 else { return total }
        return index == 0 ? total * fraction : total * (1 - fraction)
    }

    private func tileX(index: Int?, count: Int, total: CGFloat, fraction: CGFloat) -> CGFloat {
        guard let index else { return total / 2 }
        guard count == 2 else { return total / 2 }
        return index == 0 ? total * fraction / 2 : total * (1 + fraction) / 2
    }
}

private struct TerminalPane: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    let session: SessionRecord
    let isVisible: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(session.status == .running ? Color.green : .secondary)
                    .frame(width: 8, height: 8)
                Text(session.title)
                    .font(.subheadline.weight(.medium))
                Text(session.workingDirectory)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button {
                    workspace.focusOnly(session)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .help("Show only this session")
                Button {
                    workspace.close(session)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close session")
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Color(nsColor: .controlBackgroundColor))

            TerminalHostView(session: session, isVisible: isVisible)
                .onTapGesture { workspace.selectedSessionID = session.id }
        }
        .overlay(alignment: .trailing) {
            if workspace.splitSessionIDs.count == 2,
               workspace.splitSessionIDs.first == session.id {
                Divider().frame(width: 1)
            }
        }
    }
}

private struct SessionTab: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    let session: SessionRecord

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(session.status == .running ? Color.green : .secondary)
                .frame(width: 6, height: 6)
            Text(session.title)
                .lineLimit(1)
            Button {
                workspace.close(session)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(session.id == workspace.selectedSessionID ? Color.accentColor.opacity(0.22) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture { workspace.selectedSessionID = session.id }
        .onDrag { NSItemProvider(object: session.id.uuidString as NSString) }
        .onDrop(of: [.text], delegate: SessionTabDropDelegate(destination: session,
                                                               workspace: workspace))
    }
}

private struct SessionTabDropDelegate: DropDelegate {
    let destination: SessionRecord
    let workspace: WorkspaceStore

    func dropEntered(info: DropInfo) {
        guard let provider = info.itemProviders(for: [.text]).first else { return }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let idString = object as? String, let id = UUID(uuidString: idString) else { return }
            DispatchQueue.main.async {
                workspace.move(id, before: destination.id)
            }
        }
    }

    func performDrop(info: DropInfo) -> Bool { true }
}
