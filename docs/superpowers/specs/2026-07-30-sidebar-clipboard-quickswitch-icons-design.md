# Design: Clipboard, quick-switch, sidebar reordering, and live pane icons

Date: 2026-07-30

Four independent enhancements to mTerm:

1. Clipboard support (Copy / Paste / Select All).
2. Quick-switch to a grid pane with ⌘1–⌘6.
3. Drag-to-reorder sessions within the sidebar (OPEN SESSIONS and each workspace folder).
4. Replace the sidebar's green status dot with a round terminal icon, swapping to a
   Claude mark while Claude runs in that pane — detected via zsh shell integration
   (event-driven, no polling).

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

## 4. Live pane icon (terminal / Claude) — shell integration

Detection is **event-driven via shell integration** (the approach Warp / VS Code /
iTerm2 use), not polling. The shell emits a marker escape sequence on every command
start/finish; mTerm listens for it through SwiftTerm's custom-OSC hook. No timer, no
per-frame process probing.

**Files:** new `Sources/mTerm/Store/ShellIntegration.swift`,
`Sources/mTerm/Views/WorkspaceView.swift`,
`Sources/mTerm/Views/TerminalHostView.swift`,
`Sources/mTerm/Store/WorkspaceStore.swift`. New view struct(s) may live in
`WorkspaceView.swift` or a small `Views/SessionStatusIcon.swift`. Integration
dotfiles are written at runtime under Application Support (not checked in).

**Scope:** zsh only (the machine's default shell). Non-zsh shells get no injection,
so their rows always show the terminal icon — this is the accepted "no fallback"
behavior; **there is no polling path.**

### 4a. Marker protocol (custom OSC 633)

SwiftTerm exposes `Terminal.registerOscHandler(code:handler:)` and consults
registered handlers **before** its built-in OSC switch
(`EscapeSequenceParser.dispatchOsc`), so registering code `633` needs **no fork
change** and cannot be shadowed by a built-in. (`633` is unused by SwiftTerm's
built-ins; `1337`/`52`/`7`/`8` are taken.)

The injected zsh hooks emit:

- **preexec** (just before a command runs): `ESC ] 633 ; run ; <cmd> BEL`
  where `<cmd>` is the basename of the command's first word (zsh `${${1%% *}:t}`).
- **precmd** (back at the prompt): `ESC ] 633 ; idle BEL`

So a long-running `claude` emits `run;claude` at start and `idle` only when it
exits. Payload carries a single basename token (no spaces/paths), so no escaping is
needed; the handler defensively ignores any payload with control characters.

`ShellIntegration.parse(_ payload: ArraySlice<UInt8>) -> Event?` (pure, unit-tested)
maps the bytes after `633;` to `.run(command: String)` or `.idle`.

### 4b. Injecting the hooks — ZDOTDIR (VS Code / iTerm2 pattern)

`ShellIntegration.swift`:

```swift
enum ShellIntegration {
    enum Event: Equatable { case run(command: String); case idle }
    static func parse(_ payload: ArraySlice<UInt8>) -> Event?
    /// Returns the child environment (as ["K=V"]) with ZDOTDIR redirected to
    /// mTerm's generated integration dir, or `base` unchanged when `shell` is not
    /// zsh. Writes/refreshes the integration dotfiles idempotently.
    static func childEnvironment(shell: String, base: [String: String]) -> [String]
}
```

`childEnvironment`:
1. If `basename(shell) != "zsh"`, return `base` untouched (no injection).
2. Ensure the integration dir exists at
   `~/Library/Application Support/mTerm/shell-integration/`, and (re)write four
   zsh startup files: `.zshenv`, `.zprofile`, `.zshrc`, `.zlogin`. This is
   required because setting `ZDOTDIR` redirects **all** zsh startup files, so each
   must re-source the user's original.
3. Return `base` plus:
   - `MTERM_USER_ZDOTDIR` = the user's original `ZDOTDIR` (or `$HOME`)
   - `ZDOTDIR` = the integration dir
   - `MTERM_SHELL_INTEGRATION=1`

The generated files, following VS Code's `shellIntegration-rc.zsh` model:

- `.zshenv` (sourced first for every zsh): restore `ZDOTDIR` back to the user's
  original before sourcing, then `source $MTERM_USER_ZDOTDIR/.zshenv` if present. It
  must re-point `ZDOTDIR` to the user's value so subsequent user files and tools see
  the real one.
- `.zprofile` / `.zlogin`: source the user's corresponding file if present.
- `.zshrc`: source the user's `.zshrc` **first**, then append the preexec/precmd
  hooks via `add-zsh-hook` (guarded by `MTERM_SHELL_INTEGRATION` so it installs
  once). Because the hooks are defined but print **nothing at load time**,
  powerlevel10k's instant prompt is unaffected (instant prompt only forbids output
  before the first prompt; our hooks fire after it).

This is the crux of the risk; it is contained to correct sourcing order + ZDOTDIR
restoration. The generated `.zshrc` never writes to stdout during startup.

### 4c. Store: foreground command per session

```swift
@Published private(set) var claudeSessionIDs: Set<SessionRecord.ID> = []

/// Called by the OSC handler. `command == "claude"` marks the row; a nil/other
/// command (idle or anything else) clears it. Publishes only on change.
func setForeground(_ id: SessionRecord.ID, command: String?) {
    let isClaude = command == "claude"
    if isClaude, !claudeSessionIDs.contains(id) { claudeSessionIDs.insert(id) }
    else if !isClaude, claudeSessionIDs.contains(id) { claudeSessionIDs.remove(id) }
}
```

`close()` also removes the id from `claudeSessionIDs`.

### 4d. Terminal bridge registers the OSC handler and injects env

`TerminalHostView` gains `let onForeground: (String?) -> Void`. In `makeNSView`:

- After creating the terminal, register the handler:
  ```swift
  terminal.getTerminal().registerOscHandler(code: 633) { [onForeground] payload in
      switch ShellIntegration.parse(payload) {
      case .run(let cmd): DispatchQueue.main.async { onForeground(cmd) }
      case .idle:         DispatchQueue.main.async { onForeground(nil) }
      case nil:           break
      }
  }
  ```
- Build the child environment with the injected `ZDOTDIR` and pass it to
  `startProcess(executable:args:environment:)`: start from
  `ProcessInfo.processInfo.environment`, ensure `TERM=xterm-256color`, then
  `ShellIntegration.childEnvironment(shell: shell, base:)`. (Today `startProcess`
  is called with no `environment`; this adds the explicit env.)

`TerminalPane` supplies `onForeground: { workspace.setForeground(session.id, command: $0) }`.

### 4e. The icon

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
zsh pane flips that row's icon to the Claude mark as soon as the command starts;
exiting Claude reverts it immediately; a crashed/exited session shows the dimmed
terminal glyph. The user's zsh config (aliases, powerlevel10k incl. instant prompt)
behaves exactly as before injection.

---

## Testing

- `WorkspaceStoreTests`: `moveSession` reorders within a section, is a no-op across
  differing `workspaceID`s, and clamps at ends; `focusGridPane(at:)` selects the
  right pane and no-ops out of range.
- `ShellIntegrationTests`: `parse` maps `run;claude` → `.run("claude")`,
  `idle` → `.idle`, rejects payloads with control chars / wrong prefix;
  `childEnvironment` injects `ZDOTDIR`/`MTERM_USER_ZDOTDIR` only for zsh (returns
  `base` unchanged for bash/fish) and writes the four dotfiles that re-source the
  user's originals.
- `WorkspaceStoreTests`: `setForeground(_,command:)` adds on `"claude"`, removes on
  `nil`/other, and `close()` clears the id.
- Manual: Edit-menu clipboard actions; ⌘1–⌘6 focus; sidebar drag reordering; the
  live icon swap on real `claude` start/exit; and — critically — that a fresh zsh
  session with the user's powerlevel10k config starts with no prompt-reprint or
  instant-prompt warning.

## Out of scope

- Cross-section drag (moving a session into/out of a folder by dragging).
- Changing the pane-header status dot.
- Persisting session order (sessions are intentionally not persisted).
- Shell integration for non-zsh shells (bash/fish get no Claude icon — accepted).
- Detecting tools other than Claude (the marker carries any command, but only
  `claude` is wired to an icon).
