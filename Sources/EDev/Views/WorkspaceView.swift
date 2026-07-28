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
            workspace.openSingle(session.id)
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

private struct TerminalDeck: View {
    @EnvironmentObject private var workspace: WorkspaceStore

    var body: some View {
        GeometryReader { proxy in
            let frames = paneFrames(in: proxy.size)
            ZStack(alignment: .topLeading) {
                ForEach(workspace.sessions) { session in
                    let rect = frames[session.id]
                    TerminalPane(session: session, isVisible: rect != nil)
                        .frame(width: (rect ?? offscreen(proxy.size)).width,
                               height: (rect ?? offscreen(proxy.size)).height)
                        .offset(x: (rect ?? offscreen(proxy.size)).minX,
                                y: (rect ?? offscreen(proxy.size)).minY)
                        .opacity(rect == nil ? 0 : 1)
                        .allowsHitTesting(rect != nil)
                }
                columnDividers(in: proxy.size)
                rowDividers(in: proxy.size)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(Color.black)
    }

    // Rect off-screen cho session không nằm trong grid (giữ process sống).
    private func offscreen(_ size: CGSize) -> CGRect {
        CGRect(x: -size.width - 10, y: 0, width: max(size.width, 1), height: max(size.height, 1))
    }

    private func paneFrames(in size: CGSize) -> [SessionRecord.ID: CGRect] {
        var result: [SessionRecord.ID: CGRect] = [:]
        var x: CGFloat = 0
        for column in workspace.grid.columns {
            let w = column.widthFraction * size.width
            if column.panes.count == 1 {
                result[column.panes[0]] = CGRect(x: x, y: 0, width: w, height: size.height)
            } else if column.panes.count == 2 {
                let topH = column.rowFraction * size.height
                result[column.panes[0]] = CGRect(x: x, y: 0, width: w, height: topH)
                result[column.panes[1]] = CGRect(x: x, y: topH, width: w, height: size.height - topH)
            }
            x += w
        }
        return result
    }

    @ViewBuilder
    private func columnDividers(in size: CGSize) -> some View {
        let columns = workspace.grid.columns
        ForEach(0..<max(columns.count - 1, 0), id: \.self) { i in
            let x = cumulativeWidth(upTo: i + 1, in: size)
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 5, height: size.height)
                .offset(x: x - 2.5)
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let pairStart = cumulativeWidth(upTo: i, in: size)
                    let pairWidth = (columns[i].widthFraction + columns[i + 1].widthFraction) * size.width
                    guard pairWidth > 0 else { return }
                    workspace.resizeColumn(pairLeadingIndex: i,
                                           leadingFraction: (value.location.x - pairStart) / pairWidth)
                })
        }
    }

    @ViewBuilder
    private func rowDividers(in size: CGSize) -> some View {
        let columns = workspace.grid.columns
        ForEach(Array(columns.enumerated()), id: \.offset) { i, column in
            if column.panes.count == 2 {
                let x = cumulativeWidth(upTo: i, in: size)
                let w = column.widthFraction * size.width
                let y = column.rowFraction * size.height
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: w, height: 5)
                    .offset(x: x, y: y - 2.5)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        guard size.height > 0 else { return }
                        workspace.resizeRow(columnIndex: i, topFraction: value.location.y / size.height)
                    })
            }
        }
    }

    private func cumulativeWidth(upTo index: Int, in size: CGSize) -> CGFloat {
        workspace.grid.columns.prefix(index).reduce(0) { $0 + $1.widthFraction * size.width }
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
                        workspace.openSingle(session.id)
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
            .onChange(of: workspace.grid) {
                dropPosition = nil
            }
            .onChange(of: workspace.draggedSessionID) {
                if workspace.draggedSessionID == nil {
                    dropPosition = nil
                }
            }
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

