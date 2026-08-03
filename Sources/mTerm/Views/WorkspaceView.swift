import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: 0) {
            if workspace.isSidebarVisible {
                WorkspaceSidebar()
                    .frame(width: CGFloat(settings.sidebarWidth))
                SidebarResizeHandle()
            }
            TerminalDeck()
        }
        .background(MTermTheme.deck)
    }
}

private struct SidebarResizeHandle: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var dragStartWidth: Double?

    var body: some View {
        ZStack {
            Color.clear
            Rectangle()
                .fill(MTermTheme.sidebarBorder)
                .frame(width: 1)
        }
        .frame(width: 7)
        .contentShape(Rectangle())
        .onHover { inside in
            (inside ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let start = dragStartWidth ?? settings.sidebarWidth
                    dragStartWidth = start
                    settings.sidebarWidth = start + Double(value.translation.width)
                }
                .onEnded { _ in
                    dragStartWidth = nil
                }
        )
        .help("Drag to resize sidebar")
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
    @EnvironmentObject private var settings: AppSettings
    @State private var collapsedFolders: Set<WorkspaceFolder.ID> = []
    @State private var folderDropTarget: FolderDropTarget?
    @State private var sessionDropTarget: SessionDropTarget?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sidebarAction("New terminal", icon: "plus") {
                        workspace.createSession(asNewPane:
                            settings.opensNewTerminalsInSplit
                                || NSEvent.modifierFlags.contains(.command))
                    }
                    sidebarSection("OPEN SESSIONS") {
                        ForEach(workspace.sessions.filter { $0.workspaceID == nil }) { session in
                            SessionSidebarRow(session: session, dropTarget: $sessionDropTarget)
                        }
                    }
                    sidebarSection("WORKSPACES", accessory: {
                        SidebarIconButton(
                            systemName: "plus",
                            help: "Add a workspace folder"
                        ) {
                            workspace.chooseWorkspace()
                        }
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
                                    SessionSidebarRow(session: session,
                                                      isNested: true,
                                                      dropTarget: $sessionDropTarget)
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
                    .font(.system(
                        size: CGFloat(max(9, settings.sidebarFontSize - 2)),
                        weight: .bold))
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
                    .font(.system(
                        size: CGFloat(settings.sidebarFontSize),
                        weight: .semibold))
                    .foregroundStyle(MTermTheme.accent)
                Text(title)
                    .font(.system(
                        size: CGFloat(settings.sidebarFontSize),
                        weight: .bold))
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
    @EnvironmentObject private var settings: AppSettings
    let folder: WorkspaceFolder
    var hasChildren = false
    var isExpanded = true
    var count = 0
    var onToggle: () -> Void = {}
    @Binding var dropTarget: FolderDropTarget?
    @State private var rowHeight: CGFloat = 34
    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var isConfirmingRemoval = false
    @State private var nameDraft = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: hasChildren ? "chevron.right" : "folder")
                .font(.system(
                    size: CGFloat(max(9, settings.sidebarFontSize - 2)),
                    weight: .semibold))
                .foregroundStyle(MTermTheme.dim2)
                .rotationEffect(.degrees(hasChildren && isExpanded ? 90 : 0))
                .frame(width: 12)
            Text(folder.name)
                .font(.system(
                    size: CGFloat(settings.sidebarFontSize),
                    weight: .semibold))
                .foregroundStyle(MTermTheme.text)
                .lineLimit(1)
            Spacer(minLength: 6)
            if count > 0 {
                Text("\(count)")
                    .font(.system(
                        size: CGFloat(max(9, settings.sidebarFontSize - 2.5)),
                        weight: .semibold,
                        design: .monospaced))
                    .foregroundStyle(MTermTheme.accent)
                    .frame(minWidth: 18, minHeight: 18)
                    .padding(.horizontal, 4)
                    .background(Circle().fill(MTermTheme.accent.opacity(0.16)))
            }
            SidebarIconButton(
                systemName: "plus",
                help: "Open terminal in \(folder.name)"
            ) {
                workspace.createSession(in: folder, asNewPane:
                    settings.opensNewTerminalsInSplit
                        || NSEvent.modifierFlags.contains(.command))
            }
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
        .contextMenu {
            Button("New Terminal Here") {
                workspace.createSession(
                    in: folder,
                    asNewPane: settings.opensNewTerminalsInSplit)
            }
            Button("New Terminal Here in Split") {
                workspace.createSession(in: folder, asNewPane: true)
            }
            Divider()
            Button("Rename Display Name…") {
                nameDraft = folder.name
                isRenaming = true
            }
            Button("Open in Finder") {
                NSWorkspace.shared.open(URL(fileURLWithPath: folder.path))
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(folder.path, forType: .string)
            }
            Divider()
            Button("Remove Workspace", role: .destructive) {
                isConfirmingRemoval = true
            }
        }
        .alert("Rename Workspace", isPresented: $isRenaming) {
            TextField("Workspace name", text: $nameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                workspace.renameWorkspace(folder.id, to: nameDraft)
            }
        } message: {
            Text("Only the name shown in mTerm changes. The folder on disk is not renamed.")
        }
        .confirmationDialog(
            "Remove \(folder.name)?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                workspace.removeWorkspace(folder.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Closes \(count) terminal\(count == 1 ? "" : "s") and their running processes. The folder on disk is not deleted.")
        }
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

/// Which session row the cursor is over during a session drag, and whether the
/// dragged session would land after it (below) rather than before it (above).
struct SessionDropTarget: Equatable {
    let id: SessionRecord.ID
    let after: Bool
}

enum SessionSidebarClickAction: Equatable {
    case openActivePane
    case openNewPane
    case rename

    static func resolve(
        clickCount: Int,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Self {
        if clickCount >= 2 { return .rename }
        return modifierFlags.contains(.command) ? .openNewPane : .openActivePane
    }
}

private struct SessionSidebarRow: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings
    let session: SessionRecord
    var isNested = false
    @Binding var dropTarget: SessionDropTarget?
    @State private var rowHeight: CGFloat = 36
    @State private var isRenaming = false
    @State private var titleDraft = ""
    @FocusState private var isTitleFieldFocused: Bool

    private var isSelected: Bool { session.id == workspace.selectedSessionID }
    private var isVisibleInWorkview: Bool { workspace.grid.paneIDs.contains(session.id) }
    private var displayTitle: String { workspace.displayTitle(for: session) }

    var body: some View {
        HStack(spacing: 9) {
            SessionStatusIcon(status: session.status,
                              isClaude: workspace.claudeSessionIDs.contains(session.id),
                              isCodex: workspace.codexSessionIDs.contains(session.id))
            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    TextField("Terminal title", text: $titleDraft)
                        .textFieldStyle(.plain)
                        .font(.system(
                            size: CGFloat(settings.sidebarFontSize),
                            weight: .semibold))
                        .foregroundStyle(MTermTheme.text)
                        .focused($isTitleFieldFocused)
                        .onSubmit { commitRename() }
                        .onExitCommand { cancelRename() }
                } else {
                    Text(displayTitle)
                        .font(.system(
                            size: CGFloat(settings.sidebarFontSize),
                            weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? MTermTheme.text : MTermTheme.dim)
                        .lineLimit(1)
                }
                // Sessions nested under a workspace folder omit the directory
                // subtitle in the sidebar (the folder already names it); loose
                // "open sessions" still show it.
                if !isNested {
                    Text(URL(fileURLWithPath: session.workingDirectory).lastPathComponent)
                        .font(.system(
                            size: CGFloat(max(9, settings.sidebarFontSize - 2)),
                            design: .monospaced))
                        .foregroundStyle(MTermTheme.dim2)
                        .lineLimit(1)
                }
            }
            Spacer()
            if workspace.agentWorkingSessionIDs.contains(session.id) {
                WanderSpinner(size: 11, color: .white)
                    .frame(width: 16, height: 16)
                    .accessibilityLabel("Agent is working")
            }
            SidebarIconButton(
                systemName: "xmark",
                help: "Close \(displayTitle)",
                hoverColor: MTermTheme.danger
            ) {
                workspace.close(session)
            }
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
        .background(GeometryReader { g in
            Color.clear.onAppear { rowHeight = g.size.height }
        })
        .overlay(alignment: .top) { insertionLine(visible: isTarget(after: false)) }
        .overlay(alignment: .bottom) { insertionLine(visible: isTarget(after: true)) }
        .padding(.leading, isNested ? 12 : 0)
        .opacity(workspace.draggedSessionID == session.id ? 0.4 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isRenaming else { return }
            // A separate double-tap gesture makes SwiftUI defer every single
            // click until the system double-click interval expires. Resolve
            // both from the current AppKit event so opening a pane is immediate;
            // the second click of a double-click still enters rename mode.
            switch SessionSidebarClickAction.resolve(
                clickCount: NSApp.currentEvent?.clickCount ?? 1,
                modifierFlags: NSEvent.modifierFlags
            ) {
            case .openActivePane:
                workspace.openInActivePane(session.id)
            case .openNewPane:
                workspace.openInNewPane(session.id)
            case .rename:
                beginRenaming()
            }
        }
        .onDrag {
            workspace.beginDragging(session.id)
            return NSItemProvider(object: session.id.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: SessionReorderDropDelegate(
            targetID: session.id,
            rowHeight: rowHeight,
            dropTarget: $dropTarget,
            workspace: workspace))
        .contextMenu {
            Button("Open in Active Pane") {
                workspace.openInActivePane(session.id)
            }
            .disabled(isVisibleInWorkview)
            Button("Open in New Split") {
                workspace.openInNewPane(session.id)
            }
            .disabled(isVisibleInWorkview)
            Button("New Terminal Here in Split") {
                workspace.createSessionInSameDirectory(as: session.id)
            }
            Divider()
            Button("Rename…") {
                beginRenaming()
            }
            Button("Open Working Directory in Finder") {
                NSWorkspace.shared.open(URL(fileURLWithPath: session.workingDirectory))
            }
            Button("Copy Working Directory") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.workingDirectory, forType: .string)
            }
            Divider()
            Button("Close Terminal", role: .destructive) {
                workspace.close(session)
            }
        }
        .onChange(of: isTitleFieldFocused) { _, focused in
            if !focused, isRenaming {
                commitRename()
            }
        }
    }

    private func beginRenaming() {
        titleDraft = displayTitle
        isRenaming = true
        DispatchQueue.main.async {
            isTitleFieldFocused = true
        }
    }

    private func commitRename() {
        guard isRenaming else { return }
        workspace.renameSession(session.id, to: titleDraft)
        isRenaming = false
    }

    private func cancelRename() {
        isRenaming = false
        titleDraft = displayTitle
    }

    private func isTarget(after: Bool) -> Bool {
        dropTarget == SessionDropTarget(id: session.id, after: after)
    }

    private func insertionLine(visible: Bool) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(MTermTheme.accent)
            .frame(height: 2)
            .padding(.horizontal, 10)
            .opacity(visible ? 1 : 0)
    }
}

/// Reorders a session relative to another within the same sidebar section. Mirrors
/// `FolderReorderDropDelegate`; the same-section guard lives in
/// `WorkspaceStore.moveSession`, and `validateDrop` also checks it so no insertion
/// line shows for a cross-section drag.
private struct SessionReorderDropDelegate: DropDelegate {
    let targetID: SessionRecord.ID
    let rowHeight: CGFloat
    @Binding var dropTarget: SessionDropTarget?
    let workspace: WorkspaceStore

    func validateDrop(info: DropInfo) -> Bool {
        guard workspace.draggedPaneSessionID == nil,
              let dragged = workspace.draggedSessionID else { return false }
        return dragged != targetID && sameSection(dragged)
    }

    func dropEntered(info: DropInfo) { update(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: dropTarget == nil ? .cancel : .move)
    }

    func dropExited(info: DropInfo) { dropTarget = nil }

    func performDrop(info: DropInfo) -> Bool {
        defer { workspace.finishDragging(); dropTarget = nil }
        guard workspace.draggedPaneSessionID == nil,
              let dragged = workspace.draggedSessionID,
              let target = dropTarget else {
            return false
        }
        workspace.moveSession(dragged, relativeTo: target.id, insertAfter: target.after)
        return true
    }

    private func sameSection(_ dragged: SessionRecord.ID) -> Bool {
        workspace.session(for: dragged)?.workspaceID == workspace.session(for: targetID)?.workspaceID
    }

    private func update(_ info: DropInfo) {
        guard workspace.draggedPaneSessionID == nil,
              let dragged = workspace.draggedSessionID,
              dragged != targetID, sameSection(dragged) else {
            dropTarget = nil
            return
        }
        dropTarget = SessionDropTarget(id: targetID, after: info.location.y > rowHeight / 2)
    }
}

/// Compact sidebar actions share a visible hit target and brighten on hover so
/// dim plus/close glyphs still read as interactive controls.
private struct SidebarIconButton: View {
    let systemName: String
    let help: String
    var hoverColor: Color = MTermTheme.accent
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isHovering ? hoverColor : MTermTheme.dim2)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovering ? MTermTheme.rowHover : .clear))
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.borderless)
        .help(help)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.1), value: isHovering)
    }
}

/// The sidebar row's leading icon. Three distinct looks:
/// - default terminal: a graphite squircle with a green `>` and white underscore;
/// - Claude running: the orange squircle app-mark with a white Claude sunburst;
/// - Codex running: the white squircle app-mark with the black OpenAI knot.
private struct SessionStatusIcon: View {
    let status: SessionRecord.Status
    let isClaude: Bool
    let isCodex: Bool

    var body: some View {
        ZStack {
            if isClaude {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(MTermTheme.claude)
                    .frame(width: 17, height: 17)
                ClaudeLogo()
                    .fill(.white)
                    .frame(width: 11, height: 11)
            } else if isCodex {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(MTermTheme.codexBackground)
                    .frame(width: 17, height: 17)
                OpenAILogo()
                    .fill(MTermTheme.codexMark, style: FillStyle(eoFill: true))
                    .frame(width: 11, height: 11)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(MTermTheme.terminalIconBackground)
                        .frame(width: 17, height: 17)
                    TerminalPromptLogo()
                        .frame(width: 12, height: 12)
                }
                .opacity(status == .running ? 1 : 0.42)
            }
        }
        .frame(width: 18, height: 18)
    }
}

/// The familiar Terminal app prompt motif, redrawn in a 24×24 viewBox so it
/// stays crisp at the compact 17-point size used by sidebar rows and pane headers.
private struct TerminalPromptLogo: View {
    var body: some View {
        ZStack {
            TerminalChevronLogo()
                .fill(MTermTheme.terminalIconChevron)
            TerminalUnderscoreLogo()
                .fill(MTermTheme.terminalIconUnderscore)
        }
    }
}

struct TerminalChevronLogo: Shape {
    static let pathData = "M4 4 L7.5 4 L12.5 12 L7.5 20 L4 20 L9 12 Z"

    func path(in rect: CGRect) -> Path {
        absoluteSVGPath(Self.pathData, in: rect)
    }
}

struct TerminalUnderscoreLogo: Shape {
    static let pathData = "M12 17 L21 17 L21 20 L12 20 Z"

    func path(in rect: CGRect) -> Path {
        absoluteSVGPath(Self.pathData, in: rect)
    }
}

/// The real Claude mark, transcribed from `claude-color.svg` (viewBox 0 0 24 24).
/// The one SVG arc was converted to a cubic bézier so the path is only absolute
/// M/L/C/Z commands — parsed here and scaled to fit the frame (aspect-preserving,
/// centered). No bundled asset needed.
struct ClaudeLogo: Shape {
    // Absolute path, generated from the source SVG.
    static let pathData = "M4.709 15.955 L9.429 13.308 L9.509 13.078 L9.429 12.95 L9.2 12.95 L8.41 12.902 L5.712 12.829 L3.373 12.732 L1.107 12.61 L0.536 12.489 L0 11.784 L0.055 11.432 L0.535 11.111 L1.221 11.171 L2.741 11.274 L5.019 11.432 L6.671 11.529 L9.12 11.784 L9.509 11.784 L9.564 11.627 L9.43 11.529 L9.327 11.432 L6.969 9.836 L4.417 8.148 L3.081 7.176 L2.357 6.685 L1.993 6.223 L1.835 5.215 L2.491 4.493 L3.372 4.553 L3.597 4.614 L4.49 5.3 L6.398 6.776 L8.889 8.609 L9.254 8.913 L9.399 8.81 L9.418 8.737 L9.254 8.463 L7.899 6.017 L6.453 3.527 L5.809 2.495 L5.639 1.876 C5.574 1.638 5.539 1.393 5.535 1.147 L6.283 0.134 L6.696 0 L7.692 0.134 L8.112 0.498 L8.732 1.912 L9.734 4.141 L11.289 7.171 L11.745 8.069 L11.988 8.901 L12.079 9.156 L12.237 9.156 L12.237 9.01 L12.365 7.304 L12.602 5.209 L12.832 2.514 L12.912 1.754 L13.288 0.844 L14.035 0.352 L14.619 0.632 L15.099 1.317 L15.032 1.761 L14.746 3.612 L14.187 6.515 L13.823 8.457 L14.035 8.457 L14.278 8.215 L15.263 6.909 L16.915 4.845 L17.645 4.025 L18.495 3.121 L19.042 2.69 L20.075 2.69 L20.835 3.819 L20.495 4.985 L19.431 6.332 L18.55 7.474 L17.286 9.174 L16.496 10.534 L16.569 10.644 L16.757 10.624 L19.613 10.018 L21.156 9.738 L22.997 9.423 L23.83 9.811 L23.921 10.206 L23.593 11.013 L21.624 11.499 L19.315 11.961 L15.876 12.774 L15.834 12.804 L15.883 12.865 L17.432 13.011 L18.094 13.047 L19.716 13.047 L22.736 13.272 L23.526 13.794 L24 14.432 L23.921 14.917 L22.706 15.537 L21.066 15.148 L17.237 14.238 L15.925 13.909 L15.743 13.909 L15.743 14.019 L16.836 15.087 L18.842 16.897 L21.351 19.227 L21.478 19.805 L21.156 20.26 L20.816 20.211 L18.611 18.554 L17.76 17.807 L15.834 16.187 L15.706 16.187 L15.706 16.357 L16.15 17.006 L18.495 20.527 L18.617 21.607 L18.447 21.96 L17.839 22.173 L17.171 22.051 L15.797 20.126 L14.382 17.959 L13.239 16.016 L13.099 16.096 L12.425 23.35 L12.109 23.72 L11.38 24 L10.773 23.539 L10.451 22.792 L10.773 21.316 L11.162 19.392 L11.477 17.862 L11.763 15.962 L11.933 15.33 L11.921 15.288 L11.781 15.306 L10.347 17.273 L8.167 20.218 L6.441 22.063 L6.027 22.227 L5.31 21.857 L5.377 21.195 L5.778 20.606 L8.166 17.57 L9.606 15.688 L10.536 14.602 L10.53 14.444 L10.475 14.444 L4.132 18.56 L3.002 18.706 L2.515 18.25 L2.576 17.504 L2.807 17.261 L4.715 15.949 L4.709 15.955 Z"

    func path(in rect: CGRect) -> Path {
        absoluteSVGPath(Self.pathData, in: rect)
    }
}

/// The OpenAI mark from `openai.svg` (viewBox 0 0 24 24). Relative SVG
/// commands and arcs are normalized to absolute M/L/C/Z commands so it shares
/// the same lightweight path renderer as `ClaudeLogo`.
struct OpenAILogo: Shape {
    static let pathData = "M9.205 8.658 L9.205 6.398 C9.205 6.208 9.277 6.065 9.443 5.97 L13.986 3.354 C14.605 2.997 15.342 2.831 16.103 2.831 C18.957 2.831 20.765 5.043 20.765 7.397 C20.765 7.564 20.765 7.754 20.741 7.944 L16.031 5.185 C15.7699 5.0188 15.4361 5.0188 15.175 5.185 L9.205 8.658 Z M19.814 17.458 L19.814 12.06 C19.814 11.727 19.671 11.49 19.385 11.323 L13.415 7.85 L15.365 6.732 C15.5094 6.637 15.6966 6.637 15.841 6.732 L20.384 9.349 C21.693 10.109 22.573 11.727 22.573 13.297 C22.573 15.105 21.503 16.77 19.813 17.46 Z M7.802 12.703 L5.852 11.561 C5.685 11.466 5.613 11.323 5.613 11.133 L5.613 5.899 C5.613 3.354 7.563 1.427 10.204 1.427 C11.204 1.427 12.131 1.76 12.916 2.355 L8.23 5.067 C7.945 5.233 7.802 5.471 7.802 5.804 L7.802 12.702 Z M12 15.128 L9.205 13.558 L9.205 10.228 L12 8.658 L14.795 10.228 L14.795 13.558 L12 15.128 Z M13.796 22.358 C12.796 22.358 11.869 22.026 11.084 21.431 L15.77 18.719 C16.055 18.553 16.198 18.315 16.198 17.982 L16.198 11.084 L18.172 12.226 C18.339 12.321 18.41 12.464 18.41 12.654 L18.41 17.887 C18.41 20.432 16.436 22.359 13.796 22.359 Z M8.159 17.055 L3.615 14.438 C2.307 13.677 1.427 12.06 1.427 10.49 C1.4207 8.6652 2.5214 7.0187 4.21 6.327 L4.21 11.75 C4.21 12.083 4.353 12.321 4.638 12.488 L10.585 15.937 L8.635 17.055 C8.4906 17.1503 8.3034 17.1503 8.159 17.055 Z M7.897 20.955 C5.209 20.955 3.235 18.934 3.235 16.436 C3.235 16.246 3.259 16.056 3.282 15.866 L7.968 18.576 C8.254 18.743 8.539 18.743 8.824 18.576 L14.794 15.128 L14.794 17.388 C14.794 17.578 14.724 17.721 14.557 17.816 L10.014 20.432 C9.395 20.789 8.658 20.955 7.897 20.955 Z M13.796 23.785 C16.6215 23.7852 19.0571 21.7973 19.623 19.029 C22.287 18.339 24 15.84 24 13.296 C24 11.631 23.287 10.014 22.002 8.848 C22.121 8.348 22.192 7.849 22.192 7.35 C22.192 3.949 19.433 1.403 16.246 1.403 C15.604 1.403 14.986 1.498 14.366 1.713 C13.256 0.6204 11.7625 0.0056 10.205 0 C7.3792 -0.0001 4.9435 1.9883 4.378 4.757 C1.713 5.447 0 7.945 0 10.49 C0 12.156 0.713 13.773 1.998 14.938 C1.879 15.438 1.808 15.938 1.808 16.437 C1.808 19.838 4.567 22.383 7.754 22.383 C8.396 22.383 9.014 22.288 9.634 22.074 C10.7441 23.167 12.2381 23.7819 13.796 23.787 Z"

    func path(in rect: CGRect) -> Path {
        absoluteSVGPath(Self.pathData, in: rect)
    }
}

/// Render absolute SVG M/L/C/Z path data defined in a 24×24 viewBox.
private func absoluteSVGPath(_ pathData: String, in rect: CGRect) -> Path {
    // Leading command letters are glued to the first number (e.g. "M4.709");
    // split those apart before consuming the coordinate stream.
    var tokens: [Substring] = []
    for token in pathData.split(separator: " ") {
        if let first = token.first, first.isLetter {
            tokens.append(token.prefix(1))
            let rest = token.dropFirst()
            if !rest.isEmpty { tokens.append(rest) }
        } else {
            tokens.append(token)
        }
    }

    let scale = min(rect.width, rect.height) / 24
    let originX = rect.midX - 12 * scale
    let originY = rect.midY - 12 * scale
    func point(_ x: Substring, _ y: Substring) -> CGPoint {
        CGPoint(x: originX + CGFloat(Double(x) ?? 0) * scale,
                y: originY + CGFloat(Double(y) ?? 0) * scale)
    }

    var path = Path()
    var i = 0
    while i < tokens.count {
        let command = tokens[i].first
        i += 1
        switch command {
        case "M": path.move(to: point(tokens[i], tokens[i + 1])); i += 2
        case "L": path.addLine(to: point(tokens[i], tokens[i + 1])); i += 2
        case "C":
            path.addCurve(to: point(tokens[i + 4], tokens[i + 5]),
                          control1: point(tokens[i], tokens[i + 1]),
                          control2: point(tokens[i + 2], tokens[i + 3]))
            i += 6
        case "Z": path.closeSubpath()
        default: break
        }
    }
    return path
}

private struct TerminalDeck: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings

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
                workspace.createSession(asNewPane: settings.opensNewTerminalsInSplit)
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
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var terminalProcesses: TerminalProcessRegistry
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
                                 isFocused: session.id == workspace.selectedSessionID,
                                 fontName: settings.terminalFontName,
                                 fontSize: settings.terminalFontSize,
                                 ansiColors: settings.ansiColors,
                                 onForeground: {
                                     workspace.setForeground(session.id, command: $0)
                                 },
                                 onTitleChange: {
                                     workspace.setAgentTitle(session.id, title: $0)
                                 },
                                 onWorkingDirectoryChange: {
                                     workspace.setWorkingDirectory(session.id, report: $0)
                                 },
                                 onClaudeAttention: {
                                     workspace.reportClaudeAttention(session.id, kind: $0)
                                 },
                                 onCodexAttention: {
                                     workspace.reportCodexAttention(session.id)
                                 },
                                 onAgentInputSubmitted: {
                                     workspace.reportAgentInputSubmitted(session.id)
                                 },
                                 onAgentWorkInterrupted: {
                                     workspace.reportAgentWorkInterrupted(session.id)
                                 },
                                 onFileDrop: {
                                     workspace.selectedSessionID = session.id
                                 },
                                 onProcessStarted: {
                                     terminalProcesses.register(session.id, shellPID: $0)
                                 },
                                 onProcessTeardown: {
                                     terminalProcesses.terminate(session.id)
                                 })
                    .onTapGesture { workspace.selectedSessionID = session.id }
                    .padding(10)
            }
            // Header titles and AppKit-backed terminal views may both advertise
            // a wide intrinsic size. Keep the pane locked to the non-animated
            // rect assigned by TerminalDeck so a new split cannot overlap it.
            .frame(width: proxy.size.width, height: proxy.size.height)
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
                // Do not leave a SwiftUI drop destination above SwiftTerm during
                // external Finder drags. `allowsHitTesting(false)` only governs
                // normal pointer events; the registered drop destination can
                // still prevent AppKit from routing `.fileURL` to the terminal
                // NSView underneath. Mount this overlay only for our internal
                // session drag, which is the sole reason it exists.
                if workspace.draggedSessionID != nil {
                    ZStack {
                        Color.clear
                        if let dropZone {
                            TerminalDropPreview(
                                zone: dropZone,
                                size: proxy.size,
                                isPaneMove: workspace.draggedPaneSessionID != nil)
                        }
                    }
                    .contentShape(Rectangle())
                    .onDrop(of: [.text], delegate: TerminalPaneDropDelegate(
                        targetSessionID: session.id,
                        size: proxy.size,
                        dropZone: $dropZone,
                        workspace: workspace))
                }
            }
            .onChange(of: workspace.grid) { dropZone = nil }
            .onChange(of: workspace.draggedSessionID) {
                if workspace.draggedSessionID == nil { dropZone = nil }
            }
            .onHover { hovering in
                if hovering { workspace.hoveredSessionID = session.id }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Group {
                if workspace.isMaximized {
                    paneIdentity
                } else {
                    paneIdentity.onDrag {
                        workspace.beginDraggingPane(session.id)
                        return NSItemProvider(object: session.id.uuidString as NSString)
                    }
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            if let shortcutNumber = workspace.shortcutNumber(for: session.id) {
                PaneShortcutBadge(number: shortcutNumber)
            }
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

    private var paneIdentity: some View {
        HStack(spacing: 8) {
            SessionStatusIcon(
                status: session.status,
                isClaude: workspace.claudeSessionIDs.contains(session.id),
                isCodex: workspace.codexSessionIDs.contains(session.id))
            Text(workspace.displayTitle(for: session))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MTermTheme.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(URL(fileURLWithPath: session.workingDirectory).lastPathComponent)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(MTermTheme.dim2)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
        }
        .contentShape(Rectangle())
        .help(workspace.isMaximized ? "Restore the layout to move this pane" : "Drag to move this pane")
    }

    private var isFocused: Bool {
        session.id == workspace.selectedSessionID
    }

    // A focus accent only makes sense when more than one pane is on screen.
    private var showsFocusMarker: Bool {
        isFocused && workspace.grid.paneIDs.count > 1
    }
}

private struct PaneShortcutBadge: View {
    let number: Int

    var body: some View {
        Text("⌘\(number)")
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(MTermTheme.dim)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(MTermTheme.control)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(MTermTheme.controlBorder, lineWidth: 1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .help("Switch to this pane (⌘\(number))")
    }
}

private struct PaneHeaderButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    private var tint: Color {
        guard isHovering else { return MTermTheme.dim }
        return MTermTheme.accent
    }

    private var fill: Color {
        guard isHovering else { return .clear }
        return Color.white.opacity(0.09)
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
        .fixedSize(horizontal: true, vertical: false)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

private struct TerminalDropPreview: View {
    let zone: DropZone
    let size: CGSize
    let isPaneMove: Bool

    var body: some View {
        let rect = previewRect
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.38))
            RoundedRectangle(cornerRadius: 10).stroke(MTermTheme.accent, lineWidth: 2)
            badge(previewTitle)
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(false)
    }

    private var previewTitle: String {
        guard isPaneMove else { return zone == .center ? "Open here" : "Split" }
        switch zone {
        case .center: return "Swap"
        case .left: return "Move left"
        case .right: return "Move right"
        case .top: return "Move above"
        case .bottom: return "Move below"
        }
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
        let operation: DropOperation = workspace.draggedPaneSessionID == nil ? .copy : .move
        return DropProposal(operation: dropZone == nil ? .cancel : operation)
    }

    func dropExited(info: DropInfo) { dropZone = nil }

    func performDrop(info: DropInfo) -> Bool {
        defer { workspace.finishDragging() }
        guard let dragged = workspace.draggedSessionID, let zone = dropZone else {
            dropZone = nil
            return false
        }
        if workspace.draggedPaneSessionID == dragged {
            workspace.movePane(dragged, onPaneWith: targetSessionID, zone: zone)
        } else {
            workspace.place(dragged, onPaneWith: targetSessionID, zone: zone)
        }
        dropZone = nil
        return true
    }

    private func update(_ info: DropInfo) {
        guard let dragged = workspace.draggedSessionID else { dropZone = nil; return }
        // Dropping a pane's own session back onto that pane is a no-op in every
        // zone (guarded in PaneGrid.place), so never show a preview for it.
        guard dragged != targetSessionID else { dropZone = nil; return }
        let allowed = workspace.draggedPaneSessionID == dragged
            ? workspace.allowedZonesForMovingPane(dragged, onPaneWith: targetSessionID)
            : workspace.allowedZones(forPaneWith: targetSessionID)
        dropZone = PaneDropZoneResolver.resolve(
            point: info.location,
            size: size,
            allowed: allowed,
            // Pane moves must not inherit dead areas from edges that the
            // current grid capacity cannot accept. Sidebar drops retain their
            // existing edge-selection and center-fallback behavior.
            prioritizingAllowedEdges: workspace.draggedPaneSessionID == dragged)
    }
}
