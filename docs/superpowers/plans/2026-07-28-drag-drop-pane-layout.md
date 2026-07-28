# Drag-and-Drop Pane Layout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Kéo một session từ sidebar vào terminal deck để bố trí thành lưới tối đa 3 cột × 2 pane, với preview realtime cho biết vị trí sẽ đặt xuống.

**Architecture:** Toàn bộ logic tiling nằm trong một value-type thuần `PaneGrid` (unit-test được, không phụ thuộc UI/MainActor). `WorkspaceStore` giữ một `PaneGrid` và expose `place`/`allowedZones`/resize. `TerminalDeck` render mỗi session-host tại rect tính từ grid (giữ pattern ZStack + absolute-position hiện có để terminal process không bị huỷ khi layout đổi). Drop delegate map vị trí con trỏ → `DropZone`, lọc qua `allowedZones`, vẽ preview.

**Tech Stack:** Swift 5.10, SwiftUI, AppKit, SwiftPM, XCTest, SwiftTerm.

## Global Constraints

- Tối đa **3 cột**; mỗi cột tối đa **2 pane** (trên/dưới); tối đa **6 pane**.
- Drop zones: center = Open here (thay session); left/right = thêm cột full-height (chỉ khi cột < 3); top/bottom = chia cột thành 2 (chỉ khi cột đó có đúng 1 pane).
- Mỗi lần drop thêm tối đa 1 pane. Zone không hợp lệ → không preview, không thả.
- **Move semantics:** một session chỉ hiện ở 1 pane; drop = gỡ khỏi vị trí cũ rồi chèn vị trí mới; cột rỗng thì xoá.
- Drop session lên chính pane của nó (center) → no-op.
- **Không persist** sessions lẫn grid: tắt app xoá hết, mở lại fresh 1 session (single-view). `workspaces` (thư mục đã mở) vẫn persist.
- Không sửa: `TerminalHostView`, `SessionRecord`, `WorkspaceFolder`, drag-source ở sidebar (`SessionSidebarRow.onDrag` + `beginDragging`/`finishDragging`).
- Resize fraction luôn clamp `[0.2, 0.8]`.
- Test/build: `swift test`, `swift build`, chạy thử `swift run EDev`.

---

## File Structure

- Create `Sources/EDev/Models/PaneGrid.swift` — value-type `DropZone`, `GridColumn`, `PaneGrid` + toàn bộ logic tiling thuần.
- Create `Tests/EDevTests/PaneGridTests.swift` — unit test cho `PaneGrid`.
- Modify `Sources/EDev/Store/WorkspaceStore.swift` — dùng `PaneGrid`; bỏ split API cũ + session persistence.
- Modify `Sources/EDev/Views/WorkspaceView.swift` — rewrite `TerminalDeck`/`TerminalPane`/drop; bỏ code dead (`WorkspaceToolbar`, `SessionTabStrip`, `SessionTab`, `SessionTabDropDelegate`).
- Modify `Tests/EDevTests/WorkspaceStoreTests.swift` — thay test split cũ bằng test API mới.

---

## Task 1: PaneGrid value type + logic thuần

**Files:**
- Create: `Sources/EDev/Models/PaneGrid.swift`
- Test: `Tests/EDevTests/PaneGridTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum DropZone: Equatable { case center, left, right, top, bottom }`
  - `struct GridColumn: Equatable { var panes: [UUID]; var widthFraction: CGFloat = 1; var rowFraction: CGFloat = 0.5 }`
  - `struct PaneGrid: Equatable` với:
    - `static let maxColumns = 3`
    - `static func single(_ id: UUID) -> PaneGrid`
    - `var isEmpty: Bool`
    - `var paneIDs: [UUID]`
    - `func location(of id: UUID) -> (column: Int, row: Int)?`
    - `func allowedZones(forPaneWith id: UUID) -> Set<DropZone>`
    - `mutating func place(_ dragged: UUID, onPaneWith target: UUID, zone: DropZone)`
    - `mutating func remove(_ id: UUID)`
    - `mutating func resizeColumn(pairLeadingIndex: Int, leadingFraction: CGFloat)`
    - `mutating func resizeRow(columnIndex: Int, topFraction: CGFloat)`

- [ ] **Step 1: Write the failing test file**

```swift
// Tests/EDevTests/PaneGridTests.swift
import XCTest
@testable import EDev

final class PaneGridTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    func testSingleHasOneColumnOnePane() {
        let g = PaneGrid.single(a)
        XCTAssertEqual(g.columns.count, 1)
        XCTAssertEqual(g.paneIDs, [a])
    }

    func testAllowedZonesForSinglePane() {
        let g = PaneGrid.single(a)
        XCTAssertEqual(g.allowedZones(forPaneWith: a),
                       [.center, .left, .right, .top, .bottom])
    }

    func testAllowedZonesNoColumnAddWhenThreeColumns() {
        var g = PaneGrid.single(a)
        g.place(b, onPaneWith: a, zone: .right)
        g.place(c, onPaneWith: b, zone: .right)
        XCTAssertEqual(g.columns.count, 3)
        let zones = g.allowedZones(forPaneWith: c)
        XCTAssertFalse(zones.contains(.left))
        XCTAssertFalse(zones.contains(.right))
        XCTAssertTrue(zones.contains(.top))
    }

    func testAllowedZonesNoRowSplitWhenColumnHasTwoPanes() {
        var g = PaneGrid.single(a)
        g.place(b, onPaneWith: a, zone: .bottom)
        let zones = g.allowedZones(forPaneWith: a)
        XCTAssertFalse(zones.contains(.top))
        XCTAssertFalse(zones.contains(.bottom))
        XCTAssertTrue(zones.contains(.right))
    }

    func testPlaceRightCreatesSecondColumnWithEqualWidths() {
        var g = PaneGrid.single(a)
        g.place(b, onPaneWith: a, zone: .right)
        XCTAssertEqual(g.columns.count, 2)
        XCTAssertEqual(g.columns[0].panes, [a])
        XCTAssertEqual(g.columns[1].panes, [b])
        XCTAssertEqual(g.columns[0].widthFraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(g.columns[1].widthFraction, 0.5, accuracy: 0.0001)
    }

    func testPlaceLeftInsertsBeforeTargetColumn() {
        var g = PaneGrid.single(a)
        g.place(b, onPaneWith: a, zone: .left)
        XCTAssertEqual(g.columns[0].panes, [b])
        XCTAssertEqual(g.columns[1].panes, [a])
    }

    func testPlaceRightBlockedWhenThreeColumns() {
        var g = PaneGrid.single(a)
        g.place(b, onPaneWith: a, zone: .right)
        g.place(c, onPaneWith: b, zone: .right)
        g.place(d, onPaneWith: c, zone: .right)
        XCTAssertEqual(g.columns.count, 3)
        XCTAssertFalse(g.paneIDs.contains(d))
    }

    func testPlaceBottomSplitsColumn() {
        var g = PaneGrid.single(a)
        g.place(b, onPaneWith: a, zone: .bottom)
        XCTAssertEqual(g.columns.count, 1)
        XCTAssertEqual(g.columns[0].panes, [a, b])
    }

    func testPlaceTopInsertsAbove() {
        var g = PaneGrid.single(a)
        g.place(b, onPaneWith: a, zone: .top)
        XCTAssertEqual(g.columns[0].panes, [b, a])
    }

    func testPlaceBottomBlockedWhenColumnFull() {
        var g = PaneGrid.single(a)
        g.place(b, onPaneWith: a, zone: .bottom)
        g.place(c, onPaneWith: a, zone: .bottom)
        XCTAssertEqual(g.columns[0].panes, [a, b])
        XCTAssertFalse(g.paneIDs.contains(c))
    }

    func testPlaceCenterReplacesSession() {
        var g = PaneGrid.single(a)
        g.place(b, onPaneWith: a, zone: .center)
        XCTAssertEqual(g.paneIDs, [b])
    }

    func testPlaceCenterOnItselfIsNoOp() {
        var g = PaneGrid.single(a)
        g.place(a, onPaneWith: a, zone: .center)
        XCTAssertEqual(g.paneIDs, [a])
    }

    func testMoveRemovesFromOldColumnAndDropsEmptyColumn() {
        var g = PaneGrid.single(a)
        g.place(b, onPaneWith: a, zone: .right)   // [a][b]
        g.place(b, onPaneWith: a, zone: .bottom)  // move b under a -> [a,b]
        XCTAssertEqual(g.columns.count, 1)
        XCTAssertEqual(g.columns[0].panes, [a, b])
    }

    func testRemoveDropsEmptyColumnAndNormalizes() {
        var g = PaneGrid.single(a)
        g.place(b, onPaneWith: a, zone: .right)
        g.remove(b)
        XCTAssertEqual(g.columns.count, 1)
        XCTAssertEqual(g.columns[0].widthFraction, 1, accuracy: 0.0001)
    }

    func testResizeColumnClampsAndPreservesPairTotal() {
        var g = PaneGrid.single(a)
        g.place(b, onPaneWith: a, zone: .right)   // 0.5 / 0.5
        g.resizeColumn(pairLeadingIndex: 0, leadingFraction: 0.99)
        XCTAssertEqual(g.columns[0].widthFraction, 0.8, accuracy: 0.0001)
        XCTAssertEqual(g.columns[1].widthFraction, 0.2, accuracy: 0.0001)
    }

    func testResizeRowClamps() {
        var g = PaneGrid.single(a)
        g.place(b, onPaneWith: a, zone: .bottom)
        g.resizeRow(columnIndex: 0, topFraction: 0.01)
        XCTAssertEqual(g.columns[0].rowFraction, 0.2, accuracy: 0.0001)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter PaneGridTests`
Expected: FAIL — `cannot find 'PaneGrid' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/EDev/Models/PaneGrid.swift
import CoreGraphics
import Foundation

enum DropZone: Equatable {
    case center, left, right, top, bottom
}

struct GridColumn: Equatable {
    var panes: [UUID]
    var widthFraction: CGFloat = 1
    var rowFraction: CGFloat = 0.5
}

struct PaneGrid: Equatable {
    var columns: [GridColumn]

    static let maxColumns = 3

    static func single(_ id: UUID) -> PaneGrid {
        PaneGrid(columns: [GridColumn(panes: [id])])
    }

    var isEmpty: Bool { columns.isEmpty }

    var paneIDs: [UUID] { columns.flatMap(\.panes) }

    func location(of id: UUID) -> (column: Int, row: Int)? {
        for (c, column) in columns.enumerated() {
            if let r = column.panes.firstIndex(of: id) { return (c, r) }
        }
        return nil
    }

    func allowedZones(forPaneWith id: UUID) -> Set<DropZone> {
        guard let loc = location(of: id) else { return [] }
        var zones: Set<DropZone> = [.center]
        if columns.count < Self.maxColumns {
            zones.insert(.left)
            zones.insert(.right)
        }
        if columns[loc.column].panes.count == 1 {
            zones.insert(.top)
            zones.insert(.bottom)
        }
        return zones
    }

    mutating func place(_ dragged: UUID, onPaneWith target: UUID, zone: DropZone) {
        guard location(of: target) != nil else { return }
        if dragged == target, zone == .center { return }
        guard allowedZones(forPaneWith: target).contains(zone) else { return }

        remove(dragged)                                   // move semantics
        guard let loc = location(of: target) else { return }

        switch zone {
        case .center:
            columns[loc.column].panes[loc.row] = dragged
        case .left:
            columns.insert(GridColumn(panes: [dragged]), at: loc.column)
            normalizeWidths()
        case .right:
            columns.insert(GridColumn(panes: [dragged]), at: loc.column + 1)
            normalizeWidths()
        case .top:
            columns[loc.column].panes.insert(dragged, at: 0)
        case .bottom:
            columns[loc.column].panes.append(dragged)
        }
    }

    mutating func remove(_ id: UUID) {
        guard let loc = location(of: id) else { return }
        columns[loc.column].panes.remove(at: loc.row)
        if columns[loc.column].panes.isEmpty {
            columns.remove(at: loc.column)
            normalizeWidths()
        }
    }

    mutating func resizeColumn(pairLeadingIndex index: Int, leadingFraction fraction: CGFloat) {
        guard columns.indices.contains(index), columns.indices.contains(index + 1) else { return }
        let pairTotal = columns[index].widthFraction + columns[index + 1].widthFraction
        let clamped = min(max(fraction, 0.2), 0.8)
        columns[index].widthFraction = pairTotal * clamped
        columns[index + 1].widthFraction = pairTotal * (1 - clamped)
    }

    mutating func resizeRow(columnIndex index: Int, topFraction fraction: CGFloat) {
        guard columns.indices.contains(index) else { return }
        columns[index].rowFraction = min(max(fraction, 0.2), 0.8)
    }

    private mutating func normalizeWidths() {
        guard !columns.isEmpty else { return }
        let equal = 1 / CGFloat(columns.count)
        for i in columns.indices { columns[i].widthFraction = equal }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter PaneGridTests`
Expected: PASS (16 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/EDev/Models/PaneGrid.swift Tests/EDevTests/PaneGridTests.swift
git commit -m "feat: add PaneGrid tiling value type with drop-zone logic"
```

---

## Task 2: Thêm grid API vào WorkspaceStore (additive)

Thêm state/API mới dùng `PaneGrid`, **giữ nguyên** split API cũ để view cũ vẫn compile (sẽ gỡ ở Task 5).

**Files:**
- Modify: `Sources/EDev/Store/WorkspaceStore.swift`
- Test: `Tests/EDevTests/WorkspaceStoreTests.swift` (thêm test mới, không sửa test cũ)

**Interfaces:**
- Consumes: `PaneGrid`, `DropZone`, `GridColumn` (Task 1).
- Produces trên `WorkspaceStore`:
  - `@Published private(set) var grid: PaneGrid`
  - `func session(for id: SessionRecord.ID) -> SessionRecord?`
  - `func openSingle(_ id: SessionRecord.ID)`
  - `func allowedZones(forPaneWith id: SessionRecord.ID) -> Set<DropZone>`
  - `func place(_ dragged: SessionRecord.ID, onPaneWith target: SessionRecord.ID, zone: DropZone)`
  - `func resizeColumn(pairLeadingIndex: Int, leadingFraction: CGFloat)`
  - `func resizeRow(columnIndex: Int, topFraction: CGFloat)`

- [ ] **Step 1: Write the failing tests** (append vào `WorkspaceStoreTests.swift`)

```swift
    func testStoreStartsWithSinglePaneGrid() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        XCTAssertEqual(store.grid.columns.count, 1)
        XCTAssertEqual(store.grid.paneIDs, [store.sessions[0].id])
    }

    func testPlaceRightAddsColumnAndSelectsDragged() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let first = store.sessions[0].id
        store.createSession()
        let second = store.sessions[1].id
        store.openSingle(first)
        store.place(second, onPaneWith: first, zone: .right)
        XCTAssertEqual(store.grid.columns.count, 2)
        XCTAssertEqual(store.selectedSessionID, second)
    }

    func testAllowedZonesReflectGrid() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let a = store.sessions[0].id
        XCTAssertEqual(store.allowedZones(forPaneWith: a),
                       [.center, .left, .right, .top, .bottom])
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter WorkspaceStoreTests`
Expected: FAIL — `value of type 'WorkspaceStore' has no member 'grid'`.

- [ ] **Step 3: Implement — add grid state + methods**

Trong `WorkspaceStore` thêm property (ngay dưới các `@Published` hiện có):

```swift
    @Published private(set) var grid: PaneGrid = PaneGrid(columns: [])
```

Trong `init(...)`, sau dòng `selectedSessionID = sessions.first?.id`, thêm:

```swift
        grid = selectedSessionID.map(PaneGrid.single) ?? PaneGrid(columns: [])
```

Thêm các method mới (đặt gần `place(_:relativeTo:at:)` cũ):

```swift
    func session(for id: SessionRecord.ID) -> SessionRecord? {
        sessions.first { $0.id == id }
    }

    func openSingle(_ id: SessionRecord.ID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        grid = PaneGrid.single(id)
        selectedSessionID = id
    }

    func allowedZones(forPaneWith id: SessionRecord.ID) -> Set<DropZone> {
        grid.allowedZones(forPaneWith: id)
    }

    func place(_ dragged: SessionRecord.ID,
               onPaneWith target: SessionRecord.ID,
               zone: DropZone) {
        guard sessions.contains(where: { $0.id == dragged }),
              sessions.contains(where: { $0.id == target }) else { return }
        grid.place(dragged, onPaneWith: target, zone: zone)
        if grid.paneIDs.contains(dragged) {
            selectedSessionID = dragged
        }
    }

    func resizeColumn(pairLeadingIndex index: Int, leadingFraction fraction: CGFloat) {
        grid.resizeColumn(pairLeadingIndex: index, leadingFraction: fraction)
    }

    func resizeRow(columnIndex index: Int, topFraction fraction: CGFloat) {
        grid.resizeRow(columnIndex: index, topFraction: fraction)
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter WorkspaceStoreTests`
Expected: PASS (cả test cũ lẫn 3 test mới).

- [ ] **Step 5: Verify build**

Run: `swift build`
Expected: build succeeds (view cũ chưa đổi, vẫn compile).

- [ ] **Step 6: Commit**

```bash
git add Sources/EDev/Store/WorkspaceStore.swift Tests/EDevTests/WorkspaceStoreTests.swift
git commit -m "feat: add grid-based layout API to WorkspaceStore"
```

---

## Task 3: Rewrite TerminalDeck rendering theo grid

Thay layout absolute-position dựa `splitSessionIDs`/`splitFraction`/`splitAxis` bằng rect tính từ `grid`. Giữ drop delegate CŨ tạm thời (rewrite ở Task 4). Gỡ code dead. Đổi nút focus → `openSingle`, tap sidebar → `openSingle`.

**Files:**
- Modify: `Sources/EDev/Views/WorkspaceView.swift`

**Interfaces:**
- Consumes: `store.grid`, `store.session(for:)`, `store.openSingle`, `store.resizeColumn`, `store.resizeRow` (Task 2). Drop vẫn dùng `TerminalPaneDropDelegate`/`TerminalDropPosition`/`place(_:relativeTo:at:)` cũ (chưa xoá).
- Produces: `TerminalDeck` render theo grid; helper `paneFrames(in:) -> [SessionRecord.ID: CGRect]`.

- [ ] **Step 1: Xoá code dead**

Xoá hẳn 4 struct không dùng: `WorkspaceToolbar`, `SessionTabStrip`, `SessionTab`, `SessionTabDropDelegate` (chúng tham chiếu split API cũ, gỡ để tránh vướng Task 5).

- [ ] **Step 2: Thay `TerminalDeck`**

Thay toàn bộ struct `TerminalDeck` bằng:

```swift
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
```

- [ ] **Step 3: Sửa `TerminalPane`**

Trong `TerminalPane`, đổi nút focus dùng API mới và tap chọn:

- Nút focus (`workspace.focusOnly(session)`) → `workspace.openSingle(session.id)`.
- Bỏ `.overlay(alignment: .trailing)` divider cũ (dựa `splitSessionIDs`) ở cuối struct — divider giờ do `TerminalDeck` vẽ.
- Giữ nguyên phần drop overlay hiện tại (delegate cũ) — sẽ rewrite ở Task 4.
- `.onChange(of: workspace.splitSessionIDs)` → đổi thành `.onChange(of: workspace.grid) { dropPosition = nil }` (PaneGrid là Equatable).

- [ ] **Step 4: Sửa tap ở sidebar**

Trong `SessionSidebarRow.onTapGesture`, đổi `workspace.selectedSessionID = session.id` → `workspace.openSingle(session.id)`.

- [ ] **Step 5: Build & chạy thử**

Run: `swift build`
Expected: build succeeds.

Run: `swift run EDev`
Kiểm tra bằng mắt: app mở single pane; kéo divider (nếu tạo được split bằng drop cũ) resize được; tap recent ở sidebar mở single-view. (Drop có thể còn hành vi cũ chưa đúng — sẽ sửa Task 4.)

- [ ] **Step 6: Commit**

```bash
git add Sources/EDev/Views/WorkspaceView.swift
git commit -m "feat: render terminal deck from PaneGrid with resizable dividers"
```

---

## Task 4: Rewrite drop preview + delegate theo DropZone

**Files:**
- Modify: `Sources/EDev/Views/WorkspaceView.swift`

**Interfaces:**
- Consumes: `store.allowedZones(forPaneWith:)`, `store.place(_:onPaneWith:zone:)`, `store.draggedSessionID`, `store.finishDragging()`.
- Produces: `TerminalPaneDropDelegate` (dựa `DropZone`), `TerminalDropPreview` (dựa `DropZone`); `@State private var dropZone: DropZone?` trong `TerminalPane`.

- [ ] **Step 1: Đổi state trong `TerminalPane`**

Đổi `@State private var dropPosition: TerminalDropPosition?` → `@State private var dropZone: DropZone?`. Cập nhật overlay:

```swift
            .overlay {
                ZStack {
                    Color.clear
                    if let dropZone {
                        TerminalDropPreview(zone: dropZone, size: proxy.size)
                    }
                }
                .contentShape(Rectangle())
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
```

- [ ] **Step 2: Thay `TerminalDropPreview`**

```swift
private struct TerminalDropPreview: View {
    let zone: DropZone
    let size: CGSize

    var body: some View {
        let rect = previewRect
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.38))
            RoundedRectangle(cornerRadius: 10).stroke(Color.orange, lineWidth: 2)
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
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color.orange)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
    }
}
```

- [ ] **Step 3: Thay `TerminalPaneDropDelegate`**

```swift
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
        let allowed = workspace.allowedZones(forPaneWith: targetSessionID)
        // Kéo chính pane của nó lên center = no-op: bỏ preview.
        if dragged == targetSessionID {
            dropZone = zone(for: info.location) == .center ? nil : filtered(info, allowed)
        } else {
            dropZone = filtered(info, allowed)
        }
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
```

- [ ] **Step 4: Build & chạy thử**

Run: `swift build`
Expected: build succeeds.

Run: `swift run EDev`
Kiểm tra bằng mắt: tạo 2-3 session; kéo từ sidebar vào deck:
- Đưa vào giữa pane → preview "Open here" phủ toàn pane; thả → thay session.
- Đưa sát mép phải khi <3 cột → preview nửa phải "Split"; thả → thêm cột.
- Đủ 3 cột → mép trái/phải không hiện preview (fallback center).
- Cột 1 pane, đưa sát mép dưới → preview nửa dưới; thả → chia trên/dưới.
- Cột đã 2 pane → mép trên/dưới không hiện preview.
- Kéo session đang hiển thị sang chỗ khác → biến mất chỗ cũ.

- [ ] **Step 5: Commit**

```bash
git add Sources/EDev/Views/WorkspaceView.swift
git commit -m "feat: drag-drop preview and placement using PaneGrid drop zones"
```

---

## Task 5: Gỡ split API cũ + bỏ session persistence

**Files:**
- Modify: `Sources/EDev/Store/WorkspaceStore.swift`
- Modify: `Sources/EDev/Models/SessionRecord.swift` (không đổi — chỉ kiểm tra không còn tham chiếu `TerminalDropPosition`)
- Test: `Tests/EDevTests/WorkspaceStoreTests.swift`

**Interfaces:**
- Consumes: grid API (Task 2).
- Produces: `WorkspaceStore` không còn `splitSessionIDs`/`splitFraction`/`splitAxis`/`splitSelectedSession`/`place(_:relativeTo:at:)`/`focusOnly`/`closeSplit`/`resizeSplit`; `displayedSessions` tính từ grid; init fresh, không persist sessions.

- [ ] **Step 1: Sửa test cũ về API mới** (trong `WorkspaceStoreTests.swift`)

Xoá `testSplitCreatesAdjacentSessionInTheSameWorkingDirectory` và `testSplitResizeIsClampedToUsableBounds`. Thêm thay thế:

```swift
    func testCloseRemovesPaneFromGrid() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let a = store.sessions[0].id
        store.createSession()
        let b = store.sessions[1].id
        store.openSingle(a)
        store.place(b, onPaneWith: a, zone: .right)
        XCTAssertEqual(store.grid.columns.count, 2)
        store.close(store.session(for: b)!)
        XCTAssertEqual(store.grid.columns.count, 1)
        XCTAssertFalse(store.grid.paneIDs.contains(b))
    }

    func testSessionsAreNotPersistedAcrossStoreInit() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store1 = WorkspaceStore(defaults: defaults)
        store1.createSession()
        store1.createSession()
        XCTAssertEqual(store1.sessions.count, 3)

        let store2 = WorkspaceStore(defaults: defaults)
        XCTAssertEqual(store2.sessions.count, 1)          // fresh
        XCTAssertEqual(store2.grid.columns.count, 1)
    }
```

`testCloseSelectsRemainingSession` giữ nguyên (vẫn đúng).

- [ ] **Step 2: Run để thấy fail đúng chỗ**

Run: `swift test --filter WorkspaceStoreTests`
Expected: compile FAIL (test cũ đã xoá, code còn API cũ) hoặc 2 test mới FAIL — xác nhận trước khi sửa store.

- [ ] **Step 3: Bỏ session persistence trong `init`**

Trong `init(...)` đổi:

```swift
        sessions = Self.decode([SessionRecord].self, from: defaults, key: sessionsKey)
            ?? [SessionRecord.shell()]
```

thành:

```swift
        sessions = [SessionRecord.shell()]
        defaults.removeObject(forKey: sessionsKey)   // dọn state cũ nếu có
```

Trong `persist()` bỏ dòng encode sessions, chỉ còn:

```swift
    private func persist() {
        Self.encode(workspaces, to: defaults, key: workspacesKey)
    }
```

- [ ] **Step 4: Xoá split API cũ**

Xoá các member: `splitSessionIDs`, `splitFraction`, `splitAxis`, `splitSelectedSession()`, `place(_:relativeTo:at:)`, `focusOnly(_:)`, `closeSplit()`, `resizeSplit(_:)`. Xoá `enum TerminalDropPosition` và `enum SplitAxis` nếu không còn ai dùng (grep xác nhận).

Đổi `displayedSessions` thành grid-based:

```swift
    var displayedSessions: [SessionRecord] {
        grid.paneIDs.compactMap { id in sessions.first { $0.id == id } }
    }
```

Sửa `close(_:)` để dọn grid + fallback:

```swift
    func close(_ session: SessionRecord) {
        guard let index = sessions.firstIndex(of: session) else { return }
        sessions.remove(at: index)
        grid.remove(session.id)
        if selectedSessionID == session.id {
            selectedSessionID = sessions.indices.contains(index)
                ? sessions[index].id : sessions.last?.id
        }
        if grid.isEmpty, let fallback = selectedSessionID {
            grid = PaneGrid.single(fallback)
        }
        persist()
    }
```

Sửa `createSession()` và `createSession(in:)` để mở session mới ở single-view: sau khi `sessions.append(session)`, thay `selectedSessionID = session.id` bằng `openSingle(session.id)`.

- [ ] **Step 5: Run tests**

Run: `swift test`
Expected: PASS toàn bộ (PaneGridTests + WorkspaceStoreTests).

- [ ] **Step 6: Build & chạy thử regression**

Run: `swift build && swift run EDev`
Kiểm tra: mở app fresh 1 session; tạo nhiều session; drag-drop tạo lưới tới 6 pane; đóng pane cập nhật lưới; tắt app mở lại → fresh 1 session.

- [ ] **Step 7: Commit**

```bash
git add Sources/EDev/Store/WorkspaceStore.swift Tests/EDevTests/WorkspaceStoreTests.swift
git commit -m "refactor: drop legacy split API and session persistence"
```

---

## Self-Review

**Spec coverage:**
- Layout model 3 cột × 2 pane → Task 1 (`maxColumns`, place top/bottom).
- Drop zones + luật cho phép → Task 1 `allowedZones`, Task 4 filter/preview.
- Move semantics → Task 1 `place`→`remove` first; test `testMoveRemoves...`.
- Drop lên chính nó → Task 1 `testPlaceCenterOnItselfIsNoOp` + Task 4 `update`.
- Resize divider → Task 1 resize + Task 3 dividers.
- Không persist sessions/grid, fresh on launch → Task 5 + `testSessionsAreNotPersisted...`.
- Giữ workspaces persist → Task 5 `persist()` chỉ encode workspaces.
- Không đụng `TerminalHostView`/`SessionRecord`/drag-source → không task nào sửa (chỉ đổi `onTapGesture` của sidebar row sang `openSingle`, `onDrag` giữ nguyên).

**Placeholder scan:** không có TBD/TODO; mọi step có code cụ thể.

**Type consistency:** `place(_:onPaneWith:zone:)`, `allowedZones(forPaneWith:)`, `resizeColumn(pairLeadingIndex:leadingFraction:)`, `resizeRow(columnIndex:topFraction:)`, `openSingle(_:)`, `session(for:)` — dùng nhất quán giữa Task 2/3/4/5. `DropZone` thay `TerminalDropPosition` xuyên suốt Task 4/5. `grid` là `PaneGrid` (Equatable) dùng trong `.onChange`.
