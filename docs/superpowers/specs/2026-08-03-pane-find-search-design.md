# Pane Find / Search — Design

Date: 2026-08-03

## Goal

Let the user search the text of a single terminal pane. A find bar reports the
**total number of matches** and the position of the current match, and Enter /
Shift+Enter step forward / backward through them.

## Requirements

- **⌘F** opens a find bar overlay on the **focused** pane (top-right, below the
  header). If already open for that pane, it re-focuses the input field.
- Typing searches immediately: case-insensitive substring over the pane's
  buffer + scrollback. The current match is selected and scrolled into view.
- The bar shows a **match counter** — `2 / 14` (current / total). No match →
  "No results". Empty field → counter hidden and any highlight cleared.
- **Enter** → next match; **Shift+Enter** → previous match. Both update the
  counter and scroll to the match.
- **Esc** or the ✕ button → close, clear the highlight, return focus to the
  terminal.
- State is **per pane**: each pane keeps its own find bar; ⌘F only touches the
  focused pane.

## Non-goals

- No regex / case / whole-word toggles (case-insensitive substring only).
- No ⌘G / ⇧⌘G menu items; navigation is Enter / Shift+Enter while the field has
  focus.
- No "highlight all matches" rendering — only the current match is selected
  (matches SwiftTerm's available public API).

## What already exists (SwiftTerm fork)

The pinned SwiftTerm fork already ships a complete search engine. All the
methods needed are **public on `TerminalView`**, so no fork change is required:

- `findNext(_ term:, options:, scrollToResult:) -> Bool`
- `findPrevious(_ term:, options:, scrollToResult:) -> Bool`
- `searchMatchSummary(_ term:, options:, limit:) -> (index: Int, total: Int)`
  — 1-based `index` (0 when no current match) and total count.
- `clearSearch()`

The fork also has an internal AppKit find bar (`TerminalFindBarView`) wired via
`performFindPanelAction`, but it is `internal` (not usable from mTerm), shows
**no match counter**, and uses stock AppKit styling that clashes with mTerm's
Emerald theme. mTerm therefore builds its own themed bar on top of the public
API — consistent with how it already replaces SwiftTerm chrome (e.g. hiding the
NSScroller, drawing its own pane headers).

## Architecture

### New file: `Sources/mTerm/Views/TerminalFindBar.swift`

- **`TerminalSearchController`** — `@MainActor final class: ObservableObject`.
  Holds `weak var terminalView: LocalProcessTerminalView?`. Proxies to the four
  public search methods. Returns `(index, total)` to the caller. Owning the
  weak reference here keeps mTerm from retaining the terminal view.

- **`TerminalFindBar`** — SwiftUI view styled from `MTermTheme` (`control`
  background, `controlBorder` stroke, `text`/`dim` foreground, rounded, soft
  shadow). Contains the input field, the counter label, ▲/▼ buttons, and a ✕
  button. Holds `@State` for the search term and the last `(index, total)`
  summary. On term change / Enter / Shift+Enter it calls the controller and
  refreshes the counter. On Esc / ✕ it clears the search and asks the store to
  close.

- **`FindSearchField`** — small `NSViewRepresentable` around a borderless,
  transparent `NSTextField`. Its coordinator implements
  `control(_:textView:doCommandBy:)`:
  - `insertNewline:` → previous if `NSApp.currentEvent` has `.shift`, else next.
  - `cancelOperation:` → close.
  - `controlTextDidChange` → report the new term.
  It becomes first responder when the bar appears. This mirrors the proven key
  handling in SwiftTerm's own `TerminalFindBarView`. SwiftUI draws the pill
  chrome; the NSTextField itself is transparent so the theme shows through.

### `WorkspaceStore.swift`

- `@Published var findSessionID: SessionRecord.ID?` — which pane shows the bar.
- `func showFind()` — set `findSessionID = selectedSessionID` (only when a
  session is selected).
- `func closeFind(_ id:)` — clear `findSessionID` when it equals `id`.
- In `close(_:)` and `hide(_:)`, clear `findSessionID` when it targets the
  affected session so a closed/hidden pane never leaves a dangling find bar.

### `TerminalHostView.swift`

- New parameters: `searchController: TerminalSearchController` and
  `isFindBarOpen: Bool`.
- Assign `searchController.terminalView = terminal` when the view is created.
- **Focus guard:** in `updateNSView`, skip the existing
  `makeFirstResponder(nsView)` when `isFindBarOpen` is true, so the find field
  keeps keyboard focus. When the bar closes, the normal re-render restores
  first responder to the terminal automatically.

### `WorkspaceView.swift` (`TerminalPane`)

- Add `@StateObject private var searchController = TerminalSearchController()`
  (stable per session because each `TerminalPane` is identified by `session.id`).
- Pass `searchController` and `isFindBarOpen: workspace.findSessionID ==
  session.id` into `TerminalHostView`.
- `.overlay(alignment: .topTrailing)` mounting `TerminalFindBar` when
  `workspace.findSessionID == session.id`, inset below the header.

### `mTermApp.swift`

- Add **Edit ▸ Find…** (`⌘F`) targeting a new app-delegate action that calls
  `workspace.showFind()`.

## Data flow

```
⌘F (menu) → MTermAppDelegate.showFindBar → WorkspaceStore.showFind()
          → findSessionID = selectedSessionID
TerminalPane sees findSessionID == session.id → mounts TerminalFindBar
          + passes isFindBarOpen=true to TerminalHostView (focus guard on)
FindSearchField becomes first responder
type / Enter / Shift+Enter → TerminalSearchController → TerminalView.find*
          → returns (index,total) → counter label updates
Esc / ✕ → controller.clearSearch() + WorkspaceStore.closeFind(id)
          → findSessionID=nil → focus returns to terminal
```

## Counter semantics

- Empty term: hide counter, `clearSearch()`.
- Non-empty, matches: `findNext` selects the match, `searchMatchSummary` gives
  `(index, total)` → display `index / total`.
- Non-empty, no matches: `findNext` returns false, selection cleared → display
  "No results".

## Testing (TDD)

Unit-testable pure logic and store state:

- `WorkspaceStoreTests`: `showFind()` sets `findSessionID` to the selected
  session; `closeFind` clears it; closing / hiding the find-target session
  clears `findSessionID`.
- A pure helper for the counter string (`2 / 14`, "No results", empty) and for
  resolving Enter/Shift+Enter → search direction, each with unit tests.

The find bar UI and the live SwiftTerm integration are verified by `swift build`
and running the app (they need a live terminal view, so they are not unit
tested).

## Known limitations

- In alt-screen mode (Claude/Codex TUIs, vim) SwiftTerm does not scroll to a
  match outside the visible region; search is most useful over ordinary
  scrollback output.
- Only the current match is highlighted (selection), not every match.
