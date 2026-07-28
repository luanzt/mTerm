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
            TerminalDeck()
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
        .onDrag {
            workspace.beginDragging(session.id)
            return NSItemProvider(object: session.id.uuidString as NSString)
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
            let splitAxis = workspace.splitAxis
            ZStack {
                ForEach(workspace.sessions) { session in
                    let index = displayed.firstIndex(of: session)
                    TerminalPane(session: session,
                                 isVisible: index != nil)
                        .frame(width: tileWidth(index: index,
                                                 count: displayed.count,
                                                 total: proxy.size.width,
                                                 fraction: splitFraction,
                                                 axis: splitAxis),
                               height: tileHeight(index: index,
                                                  count: displayed.count,
                                                  total: proxy.size.height,
                                                  fraction: splitFraction,
                                                  axis: splitAxis))
                        .position(x: tileX(index: index,
                                            count: displayed.count,
                                            total: proxy.size.width,
                                            fraction: splitFraction,
                                            axis: splitAxis),
                                  y: tileY(index: index,
                                           count: displayed.count,
                                           total: proxy.size.height,
                                           fraction: splitFraction,
                                           axis: splitAxis))
                        .opacity(index == nil ? 0 : 1)
                        .allowsHitTesting(index != nil)
                }
                if displayed.count == 2 {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: splitAxis == .horizontal ? 5 : proxy.size.width,
                               height: splitAxis == .horizontal ? proxy.size.height : 5)
                        .position(x: splitAxis == .horizontal ? proxy.size.width * splitFraction : proxy.size.width / 2,
                                  y: splitAxis == .horizontal ? proxy.size.height / 2 : proxy.size.height * splitFraction)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            let value = splitAxis == .horizontal
                                ? value.location.x / proxy.size.width
                                : value.location.y / proxy.size.height
                            workspace.resizeSplit(to: value)
                        })
                        .help("Drag to resize panes")
                }
            }
        }
        .background(Color.black)
    }

    private func tileWidth(index: Int?, count: Int, total: CGFloat, fraction: CGFloat, axis: SplitAxis) -> CGFloat {
        guard index != nil, count > 1 else { return total }
        guard axis == .horizontal else { return total }
        guard count == 2 else { return total / CGFloat(count) }
        return index == 0 ? total * fraction : total * (1 - fraction)
    }

    private func tileHeight(index: Int?, count: Int, total: CGFloat, fraction: CGFloat, axis: SplitAxis) -> CGFloat {
        guard index != nil, count > 1 else { return total }
        guard axis == .vertical else { return total }
        guard count == 2 else { return total / CGFloat(count) }
        return index == 0 ? total * fraction : total * (1 - fraction)
    }

    private func tileX(index: Int?, count: Int, total: CGFloat, fraction: CGFloat, axis: SplitAxis) -> CGFloat {
        guard let index else { return total / 2 }
        guard count > 1 else { return total / 2 }
        guard axis == .horizontal else { return total / 2 }
        guard count == 2 else { return (CGFloat(index) + 0.5) * total / CGFloat(count) }
        return index == 0 ? total * fraction / 2 : total * (1 + fraction) / 2
    }

    private func tileY(index: Int?, count: Int, total: CGFloat, fraction: CGFloat, axis: SplitAxis) -> CGFloat {
        guard let index else { return total / 2 }
        guard count > 1 else { return total / 2 }
        guard axis == .vertical else { return total / 2 }
        guard count == 2 else { return (CGFloat(index) + 0.5) * total / CGFloat(count) }
        return index == 0 ? total * fraction / 2 : total * (1 + fraction) / 2
    }
}

private struct TerminalPane: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    let session: SessionRecord
    let isVisible: Bool
    @State private var dropPosition: TerminalDropPosition?

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(session.status == .running ? Color.green : .secondary)
                        .frame(width: 8, height: 8)
                    Text(session.title)
                        .font(.subheadline.weight(.medium))
                    Text(URL(fileURLWithPath: session.workingDirectory).lastPathComponent)
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
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
            }
            .overlay {
                ZStack {
                    Color.clear
                    if let dropPosition {
                        TerminalDropPreview(position: dropPosition, size: proxy.size)
                    }
                }
                .contentShape(Rectangle())
            .onDrop(of: [.text], delegate: TerminalPaneDropDelegate(
                targetSessionID: session.id,
                size: proxy.size,
                dropPosition: $dropPosition,
                workspace: workspace))
            .onChange(of: workspace.splitSessionIDs) {
                dropPosition = nil
            }
            .onChange(of: workspace.draggedSessionID) {
                if workspace.draggedSessionID == nil {
                    dropPosition = nil
                }
            }
        }
        }
        .overlay(alignment: .trailing) {
            if workspace.splitSessionIDs.count == 2,
               workspace.splitSessionIDs.first == session.id {
                Divider().frame(width: 1)
            }
        }
    }
}

private struct TerminalDropPreview: View {
    let position: TerminalDropPosition
    let size: CGSize

    var body: some View {
        let rect = previewRect
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 10)
                .fill(.black.opacity(0.38))
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange, lineWidth: 2)

            if position == .center {
                actionBadge("Open here", emphasized: true)
            } else {
                VStack(spacing: 22) {
                    actionBadge("Open in split", emphasized: false)
                    actionBadge("Add split", emphasized: true)
                }
            }
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(false)
    }

    private var previewRect: CGRect {
        let inset: CGFloat = 6
        let gap: CGFloat = 3
        switch position {
        case .left:
            return CGRect(x: inset,
                          y: inset,
                          width: max(0, size.width / 2 - inset - gap),
                          height: max(0, size.height - inset * 2))
        case .right:
            return CGRect(x: size.width / 2 + gap,
                          y: inset,
                          width: max(0, size.width / 2 - inset - gap),
                          height: max(0, size.height - inset * 2))
        case .top:
            return CGRect(x: inset,
                          y: inset,
                          width: max(0, size.width - inset * 2),
                          height: max(0, size.height / 2 - inset - gap))
        case .bottom:
            return CGRect(x: inset,
                          y: size.height / 2 + gap,
                          width: max(0, size.width - inset * 2),
                          height: max(0, size.height / 2 - inset - gap))
        case .center:
            return CGRect(x: inset,
                          y: inset,
                          width: max(0, size.width - inset * 2),
                          height: max(0, size.height - inset * 2))
        }
    }

    private func actionBadge(_ title: String, emphasized: Bool) -> some View {
        Text(title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(emphasized ? .white : .primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(emphasized ? Color.orange : Color.black.opacity(0.68))
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
    }
}

private struct TerminalPaneDropDelegate: DropDelegate {
    let targetSessionID: SessionRecord.ID
    let size: CGSize
    @Binding var dropPosition: TerminalDropPosition?
    let workspace: WorkspaceStore

    func dropEntered(info: DropInfo) {
        guard workspace.draggedSessionID != targetSessionID else {
            dropPosition = nil
            return
        }
        dropPosition = position(for: info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard workspace.draggedSessionID != targetSessionID else {
            dropPosition = nil
            return DropProposal(operation: .cancel)
        }
        dropPosition = position(for: info.location)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        dropPosition = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        guard info.hasItemsConforming(to: [.text]),
              let sessionID = workspace.draggedSessionID,
              sessionID != targetSessionID,
              let position = dropPosition else {
            dropPosition = nil
            workspace.finishDragging()
            return false
        }
        workspace.place(sessionID, relativeTo: targetSessionID, at: position)
        dropPosition = nil
        workspace.finishDragging()
        return true
    }

    private func position(for point: CGPoint) -> TerminalDropPosition {
        guard size.width > 0, size.height > 0 else { return .center }
        let x = point.x / size.width
        let y = point.y / size.height
        let candidates: [(TerminalDropPosition, CGFloat)] = [
            (.left, x),
            (.right, 1 - x),
            (.top, y),
            (.bottom, 1 - y),
        ]
        if let nearest = candidates.min(by: { $0.1 < $1.1 }), nearest.1 < 0.25 {
            return nearest.0
        }
        return .center
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
