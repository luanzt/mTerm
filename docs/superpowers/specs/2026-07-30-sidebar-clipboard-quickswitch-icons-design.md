# Design: Clipboard, quick-switch, sidebar reordering, and live pane icons

Date: 2026-07-30

Four independent enhancements to mTerm:

1. Clipboard support (Copy / Paste / Select All).
2. Quick-switch to a grid pane with ⌘1–⌘6.
3. Drag-to-reorder sessions within the sidebar (OPEN SESSIONS and each workspace folder).
4. Replace the sidebar's green status dot with a round terminal icon, swapping to a
   Claude mark while Claude runs in that pane's foreground.

Each feature is self-contained; they can be built and reviewed in any order.

---

## 1. Clipboard — Edit menu

**Files:** `Sources/mTerm/mTermApp.swift`

SwiftTerm's `LocalProcessTerminalView` already implements the standard responder
methods `copy(_:)`, `paste(_:)`, and `selectAll(_:)` (verified in
`MacTerminalView.swift:2339/2347/2357`). They are unreachable today only because the
app builds no Edit menu, so no menu item routes to them.

Add an **Edit** menu in `installMainMenu()`:

| Item        | Key    | Selector      | Target |
|-------------|--------|---------------|--------|
| Copy        | ⌘C     | `copy:`       | `nil`  |
| Paste       | ⌘V     | `paste:`      | `nil`  |
| Select All  | ⌘A     | `selectAll:`  | `nil`  |

`target = nil` makes AppKit dispatch the action down the responder chain to the
first responder — the focused terminal view — so no code is needed in the terminal
bridge. Order the menu after the app menu and before View.

**Acceptance:** With a terminal focused, ⌘V pastes clipboard text into the shell,
⌘C copies the current selection, ⌘A selects the buffer. The menu items are enabled
(they validate through the terminal view's own `validateMenuItem`/responder support).

---

## 2. Quick-switch panes — ⌘1–⌘6

**Files:** `Sources/mTerm/mTermApp.swift`, `Sources/mTerm/Store/WorkspaceStore.swift`

Only panes currently in the workview grid are targets. Order is `grid.paneIDs`
(`columns.flatMap(\.panes)` — left-to-right by column, top-to-bottom within a
2-pane column). The grid holds at most 6 panes (3 columns × up to 2 rows), so
⌘1–⌘6 covers every possible pane.

**Store:**

```swift
/// Focus the Nth pane currently in the grid (0-based). No-op if out of range.
func focusGridPane(at index: Int) {
    let ids = grid.paneIDs
    guard ids.indices.contains(index) else { return }
    selectedSessionID = ids[index]
}
```

Setting `selectedSessionID` is enough: `TerminalHostView.updateNSView` already
makes the selected, visible pane the window's first responder.

**Menu:** add a top-level **Panes** menu with items *Pane 1 … Pane 6*, key
equivalents ⌘1–⌘6, each carrying `tag = N-1` and action `focusPane(_:)` on
`MTermAppDelegate`:

```swift
@objc private func focusPane(_ sender: NSMenuItem) {
    workspace.focusGridPane(at: sender.tag)
}
```

Items stay present even when fewer panes exist; those numbers simply no-op.

**Acceptance:** With 3 panes open, ⌘1/⌘2/⌘3 move focus (and the accent marker /
keyboard first-responder) between them in visual order; ⌘4 does nothing.

---

## 3. Drag-to-reorder sessions in the sidebar

**Files:** `Sources/mTerm/Views/WorkspaceView.swift`,
`Sources/mTerm/Store/WorkspaceStore.swift`

Reuse the existing session drag (`onDrag` already sets `draggedSessionID`). Mirror
the folder-reorder implementation (`FolderReorderDropDelegate`,
`FolderDropTarget`, insertion lines) for sessions.

**Scope guard:** a reorder is allowed **only when the dragged session and the drop
target share the same `workspaceID`**. This keeps OPEN SESSIONS (`workspaceID ==
nil`) reordering independent from each folder's children and prevents a drag from
silently yanking a session out of its section. Cross-section moves are out of
scope. Dropping a session onto a *pane* still places it in the grid exactly as
today — pane drops and sidebar-row drops are separate views and never conflict.

**Store:**

```swift
/// Reorder a session relative to another *in the same section*. `insertAfter`
/// places the dragged session below the target rather than above it.
func moveSession(_ id: SessionRecord.ID,
                 relativeTo targetID: SessionRecord.ID,
                 insertAfter: Bool) {
    guard id != targetID,
          let source = sessions.firstIndex(where: { $0.id == id }),
          let target = sessions.firstIndex(where: { $0.id == targetID }),
          sessions[source].workspaceID == sessions[target].workspaceID else { return }
    var destination = insertAfter ? target + 1 : target
    let item = sessions.remove(at: source)
    if source < destination { destination -= 1 }
    destination = min(max(destination, 0), sessions.count)
    sessions.insert(item, at: destination)
    persist()   // (sessions are not persisted today; call is harmless/no-op)
}
```

Because the sidebar's `ForEach` filters `sessions` by `workspaceID`, reordering the
backing array reorders the displayed rows. `sessions` is `@Published private(set)`,
so mutation must live in the store (this method).

The existing `move(_:before:)` method is superseded by `moveSession`; remove it if
it has no other caller (verify with a search before deleting).

**View:**
- Add `SessionDropTarget: Equatable { id: SessionRecord.ID; after: Bool }`.
- Add `@State private var sessionDropTarget: SessionDropTarget?` to
  `WorkspaceSidebar`, passed as a `@Binding` into each `SessionSidebarRow`.
- `SessionSidebarRow` gains top/bottom insertion lines (same style as
  `WorkspaceFolderRow.insertionLine`) shown when it is the current target, plus an
  `onDrop(of: [.text], delegate: SessionReorderDropDelegate(...))`.
- `SessionReorderDropDelegate` mirrors `FolderReorderDropDelegate`: `validateDrop`
  requires a `draggedSessionID != targetID` **and same `workspaceID`**;
  `dropUpdated` sets `sessionDropTarget` from the cursor's vertical half;
  `performDrop` calls `workspace.moveSession(...)` then `finishDragging()`.

**Acceptance:** Dragging a row within OPEN SESSIONS shows an insertion line and
reorders on drop; same within a folder. Dragging across sections shows no
insertion line and does nothing. Dragging onto a pane still opens/splits as before.

---

## 4. Live pane icon (terminal / Claude)

**Files:** new `Sources/mTerm/Store/ForegroundProcess.swift`,
`Sources/mTerm/Views/WorkspaceView.swift`,
`Sources/mTerm/Views/TerminalHostView.swift`,
`Sources/mTerm/Store/WorkspaceStore.swift`. New view struct(s) may live in
`WorkspaceView.swift` or a small `Views/SessionStatusIcon.swift`.

### 4a. Foreground-process probe

`ForegroundProcess.swift` (uses `Darwin`):

```swift
enum ForegroundProcess {
    /// The command running in the foreground of a pty (the master fd), or nil.
    /// Unwraps common interpreters (node/python/…) to the script they run.
    static func command(forPTY fd: Int32) -> String?
}
```

Implementation:
1. `pgid = tcgetpgrp(fd)`; guard `pgid > 0` (–1 once the child exits).
2. Read the process's argument vector with
   `sysctl([CTL_KERN, KERN_PROCARGS2, pgid], ...)`: buffer layout is
   `int argc` · `exec_path\0` · alignment padding · `argv[0]\0 … argv[argc-1]\0`.
3. Parse `argc`, skip `exec_path`, read `argc` argv strings.
4. `cmd = basename(argv[0])`. If `cmd` is an interpreter/launcher
   (`node`, `node*`, `deno`, `bun`, `python`, `python3`, `ruby`, `env`,
   `sh`, `bash`, `zsh`) and `argv[1]` exists, use `basename(argv[1])` instead.
5. Return `cmd`.

The interpreter set is a heuristic; matching stays substring-tolerant (e.g. a
`node20` binary). This function is pure given a buffer, so the parser is unit
tested against a hand-built `KERN_PROCARGS2` buffer.

### 4b. Store: fd registry + poller

```swift
private var ptyFDs: [SessionRecord.ID: Int32] = [:]
@Published private(set) var claudeSessionIDs: Set<SessionRecord.ID> = []
private var processTimer: Timer?

func registerPTY(_ id: SessionRecord.ID, fd: Int32) {
    ptyFDs[id] = fd
    startProcessTimerIfNeeded()
    refreshForegroundProcesses()
}
func unregisterPTY(_ id: SessionRecord.ID) {
    ptyFDs.removeValue(forKey: id)
    claudeSessionIDs.remove(id)
    if ptyFDs.isEmpty { processTimer?.invalidate(); processTimer = nil }
}
private func refreshForegroundProcesses() {
    var next: Set<SessionRecord.ID> = []
    for (id, fd) in ptyFDs where ForegroundProcess.command(forPTY: fd) == "claude" {
        next.insert(id)
    }
    if next != claudeSessionIDs { claudeSessionIDs = next }  // publish only on change
}
```

`processTimer` fires ~every 1.5s on the main run loop calling
`refreshForegroundProcesses()`. `close()` calls `unregisterPTY(session.id)`.
Hidden (parked-offscreen) sessions keep their fd registered so their icon still
tracks Claude — that is intended.

### 4c. Terminal bridge reports the fd

`TerminalHostView` gains `let onPTYReady: (Int32) -> Void`. In the coordinator,
right after `startShell?(term)` runs (inside `startShellIfReady`, once), call
`onPTYReady(term.process.childfd)`. `TerminalPane` supplies the closure:
`{ fd in workspace.registerPTY(session.id, fd: fd) }`.

### 4d. The icon

Replace the `Circle().fill(...)` in `SessionSidebarRow` with a `SessionStatusIcon`:

- A ~16pt circle. Fill/tint by state:
  - **running, not Claude:** accent-tinted circle + SF Symbol `terminal`.
  - **running Claude** (`workspace.claudeSessionIDs.contains(session.id)`):
    circle + a **vector-drawn Claude starburst** (SwiftUI `Path`, no bundled
    asset), tinted with the accent (or a Claude-orange constant in `MTermTheme`).
  - **exited** (`session.status != .running`): dimmed (`MTermTheme.dim2`) terminal
    glyph.
- The Claude mark is a radial burst of tapered spokes drawn in a `Shape`; sizing
  is relative to the circle so it scales.

The pane header dot (`TerminalPane.header`) is **out of scope** and unchanged.

**Acceptance:** Each sidebar row shows a round terminal icon. Running `claude` in a
pane flips that row's icon to the Claude mark within ~1.5s; exiting Claude reverts
it; a crashed/exited session shows the dimmed terminal glyph.

---

## Testing

- `WorkspaceStoreTests`: `moveSession` reorders within a section, is a no-op across
  differing `workspaceID`s, and clamps at ends; `focusGridPane(at:)` selects the
  right pane and no-ops out of range.
- `ForegroundProcessTests`: the argv parser returns the right command from a
  synthesized `KERN_PROCARGS2` buffer, and unwraps an interpreter (`node script` →
  `script`, `node claude` / bare `claude` → `claude`).
- Manual: Edit-menu clipboard actions; ⌘1–⌘6 focus; sidebar drag reordering; the
  live icon swap on `claude` start/exit.

## Out of scope

- Cross-section drag (moving a session into/out of a folder by dragging).
- Changing the pane-header status dot.
- Persisting session order (sessions are intentionally not persisted).
- Detecting tools other than Claude (the probe is general but only `claude` is
  wired to an icon).
