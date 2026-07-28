# Drag-and-Drop Pane Layout — Design

**Date:** 2026-07-28
**Status:** Approved (design), pending implementation plan

## Goal

Cho phép kéo (drag) một session từ sidebar vào vùng terminal deck và thả (drop)
để bố trí thành lưới nhiều pane, tương tự Claude Desktop. Khi drag, realtime
hiển thị bounding-box preview cho biết vị trí session sẽ được đặt xuống.

Đây là **viết lại** phần drag-drop hiện có (`TerminalPaneDropDelegate`,
`TerminalDropPreview`, `WorkspaceStore.place`, flat `splitSessionIDs`).

## Layout model (luật)

- Deck = một hàng các **cột** xếp ngang. Tối đa **3 cột**.
- Mỗi cột = **1 pane**, hoặc chia **trên/dưới thành 2 pane**. Tối đa 2 pane/cột.
- Tổng tối đa **6 pane** (3 trên + 3 dưới).
- Không có khái niệm "chia ngang toàn bộ đáy deck" — split trên/dưới luôn nằm
  **bên trong một cột**.

### Drop zones (5 vùng trên một pane đích)

| Zone | Hành động | Điều kiện cho phép |
|------|-----------|--------------------|
| Center | **Open here** — thay session của pane đó | Luôn cho phép |
| Left / Right | Chèn **cột mới full-height** bên trái/phải cột chứa pane đích | Số cột hiện tại `< 3` |
| Top / Bottom | Chia cột chứa pane đích thành 2, đặt session mới lên trên/xuống dưới | Cột đó đang có **đúng 1 pane** |

- Mỗi lần drop thêm **tối đa 1 pane**.
- Zone không hợp lệ → **không** vẽ preview và **không** cho thả ở vùng đó
  (fallback về center nếu con trỏ ở mép không hợp lệ).

### Move semantics

- Một session chỉ hiện ở **1 pane** tại một thời điểm.
- Khi drag một session đang hiển thị ở pane khác sang vị trí mới: gỡ khỏi vị trí
  cũ trước, rồi chèn vào vị trí mới. Nếu việc gỡ làm một cột rỗng → xoá cột đó.
- Drop một session lên chính pane đang chứa nó (center của chính nó) → no-op.

## Data model

Thay 3 field phẳng hiện tại (`splitSessionIDs`, `splitFraction`, `splitAxis`)
trong `WorkspaceStore` bằng một cấu trúc lồng:

```swift
struct PaneGrid: Codable, Equatable {
    var columns: [GridColumn]           // 1...3
}

struct GridColumn: Codable, Equatable {
    var panes: [SessionRecord.ID]       // 1 hoặc 2 (index 0 = trên, 1 = dưới)
    var widthFraction: CGFloat          // bề rộng tương đối, các cột cộng lại = 1
    var rowFraction: CGFloat            // chiều cao pane trên (mặc định 0.5)
}
```

`PaneGrid`/`GridColumn` là `Codable` để persist (xem "Persistence").

- `PaneGrid` là source-of-truth cho những gì deck đang hiển thị.
- `displayedSessions` = flatten `columns` → `panes` theo thứ tự.
- Grid luôn có ≥ 1 pane khi có session được chọn.
- Tap 1 session ở sidebar → `grid = single(session)` (1 cột, 1 pane) — mở
  single view (giống Claude: click recent = mở toàn màn).

### Drop zone enum

```swift
enum DropZone { case center, left, right, top, bottom }
```

Thay cho `TerminalDropPosition` cũ (giữ tên cũ cũng được, nhưng ngữ nghĩa
`splitAxis` không còn cần vì layout do grid quyết định).

## Store API (WorkspaceStore)

- `@Published private(set) var grid: PaneGrid`
- `func allowedZones(forPaneWith sessionID) -> Set<DropZone>` — tính theo luật
  (center luôn có; left/right khi `columns.count < 3`; top/bottom khi cột chứa
  pane có đúng 1 pane).
- `func place(_ dragged: SessionRecord.ID, onPaneWith target: SessionRecord.ID, zone: DropZone)`
  — gỡ `dragged` khỏi vị trí cũ (nếu có), rồi:
  - `.center`: thay pane target bằng `dragged`.
  - `.left/.right`: chèn `GridColumn(panes:[dragged])` trước/sau cột của target.
  - `.top/.bottom`: thêm `dragged` vào `panes` của cột target ở index 0/1.
  - Sau mỗi thao tác: chuẩn hoá lại `widthFraction` cho đều nếu số cột đổi.
- `func resizeColumn(_ index: Int, to fraction: CGFloat)` — clamp [0.2, 0.8].
- `func resizeRow(columnIndex: Int, to fraction: CGFloat)` — clamp [0.2, 0.8].
- Giữ `beginDragging` / `finishDragging` / `draggedSessionID` như hiện tại
  (NSEvent monitor để reset preview khi thả/Esc).

## Rendering (WorkspaceView / TerminalDeck)

Bỏ layout absolute-position + tile-math thủ công. Thay bằng cấu trúc tự nhiên:

```
HStack(spacing: 0) {
    ForEach(columns) { column in
        VStack(spacing: 0) {
            ForEach(column.panes) { pane in TerminalPane(...) }
        }
        .frame(width: column.widthFraction * totalWidth)
        // row divider giữa 2 pane nếu có
    }
    // column divider giữa các cột
}
```

- Divider giữa cột: `DragGesture` → `resizeColumn`.
- Divider giữa 2 hàng trong cột: `DragGesture` → `resizeRow`.
- Mỗi `TerminalPane` giữ header (title, focus, close) như hiện tại; ẩn các pane
  không nằm trong grid vẫn cần render off-screen để `TerminalHostView` không bị
  huỷ (giữ pattern hiện tại: render toàn bộ `sessions`, chỉ pane trong grid mới
  visible/hit-testable).

## Drop preview

Mỗi `TerminalPane` có `onDrop` với delegate riêng:

- `dropUpdated`: map vị trí con trỏ → `DropZone` gần nhất (ngưỡng 25% mép, else
  center). Lọc qua `allowedZones`; nếu zone không hợp lệ → dùng center. Set
  `@State dropZone` để vẽ preview.
- `TerminalDropPreview`: vẽ rect theo zone (nửa trái/phải/trên/dưới/toàn pane) +
  viền cam + badge ("Open here" ở center, "Split" ở mép). Chỉ vẽ khi zone hợp lệ.
- `performDrop`: gọi `store.place(dragged, onPaneWith: target, zone:)`, reset
  preview, `finishDragging`.
- Reset preview khi `grid` đổi hoặc `draggedSessionID == nil`.

## Không đụng tới

- `TerminalHostView` (SwiftTerm host).
- `SessionRecord`, `WorkspaceFolder`.
- Drag-source ở sidebar (`SessionSidebarRow.onDrag` + `beginDragging`).
- Persistence keys hiện có cho sessions/workspaces.

## Persistence

- Persist `grid` cùng cơ chế `UserDefaults` + `Codable` như `sessions`/`workspaces`
  (key mới, vd `edev.workspace.grid`), gọi trong `persist()` sau mỗi `place` /
  resize / tap.
- Khi khởi động: decode grid; **lọc bỏ** mọi `SessionRecord.ID` không còn tồn tại
  trong `sessions` (session đã bị đóng). Nếu sau khi lọc một cột rỗng → xoá cột;
  nếu grid rỗng → fallback về single-view của session đầu tiên.
- Chuẩn hoá lại `widthFraction` sau khi lọc để tổng = 1.

## Testing

Unit test `WorkspaceStore` (thuần logic, không UI):

- `allowedZones`: 1 cột/1 pane → đủ 5 zone; 3 cột → không có left/right; cột 2
  pane → không có top/bottom.
- `place` center → thay session đúng pane.
- `place` right khi 2 cột → thành 3 cột; khi 3 cột → no-op (bị chặn).
- `place` bottom khi cột 1 pane → cột thành 2 pane; khi cột đã 2 pane → no-op.
- Move: drag session từ cột A sang cột B → biến mất ở A; nếu A rỗng → xoá cột A.
- Drop lên chính nó → no-op.
- `resizeColumn` / `resizeRow` clamp đúng biên.
- Persistence: encode grid rồi khởi tạo store mới từ cùng `UserDefaults` →
  khôi phục đúng layout; nếu một session ID đã bị xoá → lọc bỏ, cột rỗng bị xoá,
  fraction chuẩn hoá lại.

## Out of scope (phase này)

- Duplicate một session ở nhiều pane.
- Kéo sắp xếp lại pane bằng header (chỉ drag từ sidebar).
