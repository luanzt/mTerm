import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceView: View {
    @EnvironmentObject private var workspace: WorkspaceStore

    var body: some View {
        HStack(spacing: 0) {
            if workspace.isSidebarVisible {
                WorkspaceSidebar()
                Rectangle()
                    .fill(MTermTheme.sidebarBorder)
                    .frame(width: 1)
            }
            TerminalDeck()
        }
        .background(MTermTheme.deck)
    }
}

/// Toggles the sidebar. Lives in the window titlebar (see `MTermApp`), pinned to
/// the trailing edge. ⌘B (View ▸ Toggle Sidebar) does the same thing.
struct SidebarToggleButton: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @State private var hovering = false

    var body: some View {
        Button {
            workspace.toggleSidebar()
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(hovering ? MTermTheme.text : MTermTheme.dim)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(hovering ? MTermTheme.rowHover : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Toggle sidebar (⌘B)")
    }
}

private struct WorkspaceSidebar: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @State private var collapsedFolders: Set<WorkspaceFolder.ID> = []
    @State private var folderDropTarget: FolderDropTarget?

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
                    sidebarSection("WORKSPACES", accessory: {
                        Button {
                            workspace.chooseWorkspace()
                        } label: {
                            Image(systemName: "plus")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(MTermTheme.dim)
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.borderless)
                        .help("Add a workspace folder")
                    }) {
                        ForEach(workspace.workspaces) { folder in
                            let children = workspace.sessions.filter { $0.workspaceID == folder.id }
                            let isExpanded = !collapsedFolders.contains(folder.id)
                            WorkspaceFolderRow(folder: folder,
                                               hasChildren: !children.isEmpty,
                                               isExpanded: isExpanded,
                                               count: children.count,
                                               onToggle: { toggle(folder) },
                                               dropTarget: $folderDropTarget)
                            if isExpanded {
                                ForEach(children) { session in
                                    SessionSidebarRow(session: session, isNested: true)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 14)
            }
        }
        .frame(width: 250)
        .background(MTermTheme.sidebar)
    }

    private func toggle(_ folder: WorkspaceFolder) {
        if collapsedFolders.contains(folder.id) {
            collapsedFolders.remove(folder.id)
        } else {
            collapsedFolders.insert(folder.id)
        }
    }

    @ViewBuilder
    private func sidebarSection<Content: View, Accessory: View>(
        _ title: String,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 0) {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .tracking(1)
                    .foregroundStyle(MTermTheme.dim2)
                Spacer()
                accessory()
            }
            .padding(.horizontal, 10)
            content()
        }
    }

    private func sidebarAction(_ title: String,
                               icon: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action, label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MTermTheme.accent)
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(MTermTheme.text)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(MTermTheme.control)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(MTermTheme.controlBorder, lineWidth: 1))
            )
        })
        .buttonStyle(.plain)
    }
}

/// Which folder row the cursor is over during a folder drag, and whether the
/// dragged folder would land after it (below) rather than before it (above).
struct FolderDropTarget: Equatable {
    let id: WorkspaceFolder.ID
    let after: Bool
}

private struct WorkspaceFolderRow: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    let folder: WorkspaceFolder
    var hasChildren = false
    var isExpanded = true
    var count = 0
    var onToggle: () -> Void = {}
    @Binding var dropTarget: FolderDropTarget?
    @State private var rowHeight: CGFloat = 34
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: hasChildren ? "chevron.right" : "folder")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MTermTheme.dim2)
                .rotationEffect(.degrees(hasChildren && isExpanded ? 90 : 0))
                .frame(width: 12)
            Text(folder.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(MTermTheme.text)
                .lineLimit(1)
            Spacer(minLength: 6)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(MTermTheme.accent)
                    .frame(minWidth: 18, minHeight: 18)
                    .padding(.horizontal, 4)
                    .background(Circle().fill(MTermTheme.accent.opacity(0.16)))
            }
            Button {
                workspace.createSession(in: folder)
            } label: {
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MTermTheme.dim)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Open terminal in \(folder.name)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(GeometryReader { g in
            Color.clear.onAppear { rowHeight = g.size.height }
        })
        .background(isHovering ? MTermTheme.rowHover : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onHover { isHovering = $0 }
        .opacity(workspace.draggedWorkspaceID == folder.id ? 0.4 : 1)
        .overlay(alignment: .top) { insertionLine(visible: isTarget(after: false)) }
        .overlay(alignment: .bottom) { insertionLine(visible: isTarget(after: true)) }
        .contentShape(Rectangle())
        .onTapGesture {
            if hasChildren { withAnimation(.easeInOut(duration: 0.15)) { onToggle() } }
        }
        .onDrag {
            workspace.beginDraggingWorkspace(folder.id)
            return NSItemProvider(object: folder.id.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: FolderReorderDropDelegate(
            targetID: folder.id,
            rowHeight: rowHeight,
            dropTarget: $dropTarget,
            workspace: workspace))
    }

    private func isTarget(after: Bool) -> Bool {
        dropTarget == FolderDropTarget(id: folder.id, after: after)
    }

    private func insertionLine(visible: Bool) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(MTermTheme.accent)
            .frame(height: 2)
            .padding(.horizontal, 10)
            .opacity(visible ? 1 : 0)
    }
}

private struct FolderReorderDropDelegate: DropDelegate {
    let targetID: WorkspaceFolder.ID
    let rowHeight: CGFloat
    @Binding var dropTarget: FolderDropTarget?
    let workspace: WorkspaceStore

    func validateDrop(info: DropInfo) -> Bool {
        guard let dragged = workspace.draggedWorkspaceID else { return false }
        return dragged != targetID
    }

    func dropEntered(info: DropInfo) { update(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: dropTarget == nil ? .cancel : .move)
    }

    func dropExited(info: DropInfo) { dropTarget = nil }

    func performDrop(info: DropInfo) -> Bool {
        defer { workspace.finishDragging(); dropTarget = nil }
        guard let dragged = workspace.draggedWorkspaceID, let target = dropTarget else {
            return false
        }
        workspace.moveWorkspace(dragged, relativeTo: target.id, insertAfter: target.after)
        return true
    }

    private func update(_ info: DropInfo) {
        guard let dragged = workspace.draggedWorkspaceID, dragged != targetID else {
            dropTarget = nil
            return
        }
        dropTarget = FolderDropTarget(id: targetID, after: info.location.y > rowHeight / 2)
    }
}

private struct SessionSidebarRow: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    let session: SessionRecord
    var isNested = false

    private var isSelected: Bool { session.id == workspace.selectedSessionID }

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(session.status == .running ? MTermTheme.accent : MTermTheme.dim2)
                .frame(width: 7, height: 7)
                .shadow(color: session.status == .running ? MTermTheme.accent.opacity(0.7) : .clear,
                        radius: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? MTermTheme.text : MTermTheme.dim)
                    .lineLimit(1)
                // Sessions nested under a workspace folder omit the directory
                // subtitle in the sidebar (the folder already names it); loose
                // "open sessions" still show it.
                if !isNested {
                    Text(URL(fileURLWithPath: session.workingDirectory).lastPathComponent)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(MTermTheme.dim2)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button {
                workspace.close(session)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(MTermTheme.dim2)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .help("Close \(session.title)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isSelected ? MTermTheme.rowSelected : .clear)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(MTermTheme.accent)
                .frame(width: 2)
                .padding(.vertical, 4)
                .opacity(isSelected ? 1 : 0)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.leading, isNested ? 12 : 0)
        .contentShape(Rectangle())
        .onTapGesture {
            workspace.openInActivePane(session.id)
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

    /// Breathing room between panes (and around the deck edge). Panes are inset
    /// by half of this on every side so adjacent panes are separated by a full
    /// gutter while the outer edge keeps a half-gutter margin.
    private let gutter: CGFloat = 12

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
                if workspace.grid.isEmpty {
                    emptyState
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            // Pin to top-leading: panes are placed with `.offset`, which does not
            // contribute to the ZStack's intrinsic size, so without an explicit
            // alignment this frame would center the (narrow) content block and
            // shift every pane right. Top-leading keeps offsets measured from x0.
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .coordinateSpace(name: "deck")
        }
        .background(MTermTheme.deck)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "terminal")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(MTermTheme.dim2)
            Text("No terminals open")
                .font(.headline)
                .foregroundStyle(MTermTheme.dim)
            Button {
                workspace.createSession()
            } label: {
                Label("New terminal", systemImage: "plus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(hex: 0x08120D))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10).fill(MTermTheme.accent))
            }
            .buttonStyle(.plain)
        }
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
        // Inset every pane so panes float on the deck with a gutter between them
        // instead of tiling edge-to-edge. Grid math above is unchanged — the
        // gutter is purely visual and the resize handles sit on the full-tile
        // boundaries (see column/row dividers).
        for (id, rect) in result {
            result[id] = rect.insetBy(dx: gutter / 2, dy: gutter / 2)
        }
        // Tripwire: the grid self-heals duplicates/empty columns on every
        // mutation, so a pane that is duplicated, orphaned, or missing a frame at
        // render time means a code path bypassed that. Log it (rare) to catch the
        // trigger; the layout still renders because paneFrames covers every slot.
        let ids = workspace.grid.paneIDs
        let sessionIDs = Set(workspace.sessions.map(\.id))
        let duplicated = ids.count != Set(ids).count
        let orphaned = ids.contains { !sessionIDs.contains($0) }
        let missingFrame = ids.contains { result[$0] == nil }
        if duplicated || orphaned || missingFrame {
            let cols = workspace.grid.columns
                .map { "[\($0.panes.count)p]" }.joined(separator: " ")
            FileHandle.standardError.write(Data(
                "MTERM_GRID_ANOMALY cols=\(cols) dup=\(duplicated) orphan=\(orphaned) missingFrame=\(missingFrame) gridPanes=\(ids.count) unique=\(Set(ids).count) sessions=\(sessionIDs.count)\n".utf8))
        }
        return result
    }

    @ViewBuilder
    private func columnDividers(in size: CGSize) -> some View {
        let columns = workspace.grid.columns
        ForEach(0..<max(columns.count - 1, 0), id: \.self) { i in
            let x = cumulativeWidth(upTo: i + 1, in: size)
            ResizeHandle(orientation: .vertical, inset: gutter / 2)
                .frame(width: gutter, height: size.height)
                .offset(x: x - gutter / 2)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("deck")).onChanged { value in
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
                ResizeHandle(orientation: .horizontal, inset: gutter / 2)
                    .frame(width: w, height: gutter)
                    .offset(x: x, y: y - gutter / 2)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("deck")).onChanged { value in
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

/// A transparent drag strip that sits in the gutter between two panes. It shows
/// a thin accent line only while hovered, and swaps in the resize cursor, so the
/// deck reads as clean spacing until the user reaches for a divider.
private struct ResizeHandle: View {
    enum Orientation { case vertical, horizontal }
    let orientation: Orientation
    let inset: CGFloat
    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.clear
            RoundedRectangle(cornerRadius: 1)
                .fill(MTermTheme.accent)
                .opacity(hovering ? 0.85 : 0)
                .frame(width: orientation == .vertical ? 2 : nil,
                       height: orientation == .horizontal ? 2 : nil)
                .padding(orientation == .vertical ? .vertical : .horizontal, inset)
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside {
                (orientation == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

private struct TerminalPane: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    let session: SessionRecord
    let isVisible: Bool
    @State private var dropZone: DropZone?

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                // 2px accent bar marks the focused pane (transparent otherwise).
                Rectangle()
                    .fill(showsFocusMarker ? MTermTheme.accent : Color.clear)
                    .frame(height: 2)
                header
                TerminalHostView(session: session,
                                 isVisible: isVisible,
                                 isFocused: session.id == workspace.selectedSessionID)
                    .onTapGesture { workspace.selectedSessionID = session.id }
                    .padding(10)
            }
            .background(MTermTheme.terminal)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(showsFocusMarker ? MTermTheme.accent : MTermTheme.border, lineWidth: 1)
            )
            .shadow(color: showsFocusMarker ? MTermTheme.glow : Color.black.opacity(0.45),
                    radius: showsFocusMarker ? 5 : 2,
                    y: showsFocusMarker ? 3 : 1)
            .opacity(isFocused ? 1 : MTermTheme.inactivePaneOpacity)
            .overlay {
                ZStack {
                    Color.clear
                    if let dropZone {
                        TerminalDropPreview(zone: dropZone, size: proxy.size)
                    }
                }
                .contentShape(Rectangle())
                // Only intercept mouse events while a session is being dragged;
                // otherwise let clicks fall through so the terminal can focus.
                .allowsHitTesting(workspace.draggedSessionID != nil)
                .onDrop(of: [.text], delegate: TerminalPaneDropDelegate(
                    targetSessionID: session.id,
                    size: proxy.size,
                    dropZone: $dropZone,
                    workspace: workspace))
                .onChange(of: workspace.grid) { dropZone = nil }
                .onChange(of: workspace.draggedSessionID) {
                    if workspace.draggedSessionID == nil { dropZone = nil }
                }
            }
            .onHover { hovering in
                if hovering { workspace.hoveredSessionID = session.id }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .shadow(color: dotColor == MTermTheme.accent ? MTermTheme.accent.opacity(0.8) : .clear,
                        radius: 4)
            Text(session.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MTermTheme.text)
                .lineLimit(1)
                .fixedSize()
            Text(URL(fileURLWithPath: session.workingDirectory).lastPathComponent)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(MTermTheme.dim2)
                .lineLimit(1)
            Spacer(minLength: 6)
            PaneHeaderButton(icon: workspace.isMaximized
                                ? "arrow.down.right.and.arrow.up.left"
                                : "arrow.up.left.and.arrow.down.right",
                             help: workspace.isMaximized
                                ? "Restore previous layout"
                                : "Maximize this pane") {
                workspace.toggleMaximize(session.id)
            }
            PaneHeaderButton(icon: "minus",
                             help: "Hide this pane (keep the session)") {
                workspace.hide(session)
            }
            PaneHeaderButton(icon: "xmark",
                             help: "Close session",
                             danger: true) {
                workspace.close(session)
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, 8)
        .frame(height: 34)
        .background(showsFocusMarker ? MTermTheme.headerActive : Color.clear)
        .background(MTermTheme.header)
        .overlay(alignment: .bottom) {
            Rectangle().fill(MTermTheme.border).frame(height: 1)
        }
    }

    private var dotColor: Color {
        if session.status != .running { return MTermTheme.danger }
        return isFocused ? MTermTheme.accent : MTermTheme.dim
    }

    private var isFocused: Bool {
        session.id == workspace.selectedSessionID
    }

    // A focus accent only makes sense when more than one pane is on screen.
    private var showsFocusMarker: Bool {
        isFocused && workspace.grid.paneIDs.count > 1
    }
}

private struct PaneHeaderButton: View {
    let icon: String
    let help: String
    var danger = false
    let action: () -> Void
    @State private var isHovering = false

    private var tint: Color {
        guard isHovering else { return MTermTheme.dim }
        return danger ? MTermTheme.danger : MTermTheme.accent
    }

    private var fill: Color {
        guard isHovering else { return .clear }
        return danger ? MTermTheme.danger.opacity(0.16) : Color.white.opacity(0.09)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(fill)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.borderless)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

private struct TerminalDropPreview: View {
    let zone: DropZone
    let size: CGSize

    var body: some View {
        let rect = previewRect
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.38))
            RoundedRectangle(cornerRadius: 10).stroke(MTermTheme.accent, lineWidth: 2)
            badge(zone == .center ? "Open here" : "Split")
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(false)
    }

    private var previewRect: CGRect {
        let inset: CGFloat = 6, gap: CGFloat = 3
        switch zone {
        case .left:
            return CGRect(x: inset, y: inset,
                          width: max(0, size.width / 2 - inset - gap),
                          height: max(0, size.height - inset * 2))
        case .right:
            return CGRect(x: size.width / 2 + gap, y: inset,
                          width: max(0, size.width / 2 - inset - gap),
                          height: max(0, size.height - inset * 2))
        case .top:
            return CGRect(x: inset, y: inset,
                          width: max(0, size.width - inset * 2),
                          height: max(0, size.height / 2 - inset - gap))
        case .bottom:
            return CGRect(x: inset, y: size.height / 2 + gap,
                          width: max(0, size.width - inset * 2),
                          height: max(0, size.height / 2 - inset - gap))
        case .center:
            return CGRect(x: inset, y: inset,
                          width: max(0, size.width - inset * 2),
                          height: max(0, size.height - inset * 2))
        }
    }

    private func badge(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color(hex: 0x08120D))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(MTermTheme.accent)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
    }
}

private struct TerminalPaneDropDelegate: DropDelegate {
    let targetSessionID: SessionRecord.ID
    let size: CGSize
    @Binding var dropZone: DropZone?
    let workspace: WorkspaceStore

    func dropEntered(info: DropInfo) { update(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: dropZone == nil ? .cancel : .copy)
    }

    func dropExited(info: DropInfo) { dropZone = nil }

    func performDrop(info: DropInfo) -> Bool {
        defer { workspace.finishDragging() }
        guard let dragged = workspace.draggedSessionID, let zone = dropZone else {
            dropZone = nil
            return false
        }
        workspace.place(dragged, onPaneWith: targetSessionID, zone: zone)
        dropZone = nil
        return true
    }

    private func update(_ info: DropInfo) {
        guard let dragged = workspace.draggedSessionID else { dropZone = nil; return }
        // Dropping a pane's own session back onto that pane is a no-op in every
        // zone (guarded in PaneGrid.place), so never show a preview for it.
        guard dragged != targetSessionID else { dropZone = nil; return }
        dropZone = filtered(info, workspace.allowedZones(forPaneWith: targetSessionID))
    }

    private func filtered(_ info: DropInfo, _ allowed: Set<DropZone>) -> DropZone? {
        let z = zone(for: info.location)
        if allowed.contains(z) { return z }
        return allowed.contains(.center) ? .center : nil
    }

    private func zone(for point: CGPoint) -> DropZone {
        guard size.width > 0, size.height > 0 else { return .center }
        let x = point.x / size.width, y = point.y / size.height
        let candidates: [(DropZone, CGFloat)] = [(.left, x), (.right, 1 - x), (.top, y), (.bottom, 1 - y)]
        if let nearest = candidates.min(by: { $0.1 < $1.1 }), nearest.1 < 0.25 {
            return nearest.0
        }
        return .center
    }
}

