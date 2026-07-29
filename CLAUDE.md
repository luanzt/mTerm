# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
swift build                 # build
swift test                  # run all tests
swift run mTerm              # build & launch the app (macOS GUI window)
.build/debug/mTerm &         # launch an already-built binary in the background

# Run a single test / suite (XCTest name filter):
swift test --filter WorkspaceStoreTests
swift test --filter WorkspaceStoreTests/testToggleMaximizeCollapsesThenRestoresLayout
```

Editor (SourceKit) diagnostics in this project are frequently **stale/false**
(e.g. "Cannot find MTermTheme in scope" right after adding a file). Trust
`swift build` / `swift test`, not the inline diagnostics.

## Big picture

mTerm is a macOS terminal-multiplexer app: a SwiftPM **executable** (not a SwiftUI
`App`). `main.swift` boots `NSApplication` with an `MTermAppDelegate`
(`mTermApp.swift`) that builds the main menu (⌘B = Toggle Sidebar) and hosts the
SwiftUI `WorkspaceView` in an `NSWindow` via `NSHostingView`.

- `hosting.sizingOptions = []` is deliberate: without it, each SwiftTerm view's
  intrinsic width propagates up and AppKit grows the *window* when you add a pane.

### State: `WorkspaceStore` (Store/WorkspaceStore.swift)
Single `@MainActor ObservableObject`, the source of truth for everything:
`sessions`, `workspaces` (folders), selection/hover/drag IDs, and the `grid`.
All mutations (create/close/hide/place/maximize/resize) go through it. Only
`workspaces` is persisted (UserDefaults); sessions are intentionally not.
`savedGrid` backs maximize↔restore and is cleared by any structural grid change.

### Layout model: `PaneGrid` (Models/PaneGrid.swift)
Pure value type: `columns` of `GridColumn`, each column has `widthFraction` and
1–2 panes (`rowFraction` splits a 2-pane column). Max 3 columns. Drag-drop uses
`DropZone` (center/left/right/top/bottom) via `allowedZones` + `place`.
`enforceInvariants()` **self-heals** after every mutation: removes duplicate pane
IDs (a UI drag race can momentarily duplicate one) and empty columns. This
invariant is the subject of `PaneGridTests`, `PaneGridHealTests`, and
`GridInvariantFuzzTests` — preserve it.

### Rendering: `WorkspaceView.swift`
`TerminalDeck` lays panes out by **absolute frame + offset** inside a
`ZStack(alignment: .topLeading)`, from rects computed in `paneFrames(in:)`
(fraction math + a `gutter` inset so panes float with gaps). Critical, non-obvious
constraints learned the hard way:
- Every `SessionRecord` renders a `TerminalPane`; sessions **not** in the grid are
  parked off-screen (opacity 0) so their shell process keeps running. Never
  destroy a hidden session's view to "save resources".
- The deck's outer `.frame(..., alignment: .topLeading)` alignment is **required** —
  `.offset` doesn't contribute to intrinsic size, so a centered frame would shift
  every pane right / overflow.
- A pane's frame must **never animate**. SwiftTerm resizes the PTY on each
  intermediate size, so an animated width change becomes a SIGWINCH storm that
  makes the shell reprint its prompt repeatedly. Do not add `.animation` around
  pane frames.

### Terminal bridge: `TerminalHostView.swift`
`NSViewRepresentable` around SwiftTerm's `LocalProcessTerminalView`. The shell is
started from a **frame-change observer** (not `updateNSView`) the first time the
view has a real non-zero frame, so the PTY's initial winsize matches the pane and
prompts don't reprint on startup. `TerminalDeck.paneFrames` has a stderr tripwire
that logs `MTERM_GRID_ANOMALY` if a pane is ever duplicated/orphaned/missing a frame.

### Theme
`Views/Theme.swift` — `MTermTheme` holds the whole "Emerald" dark palette + a
`Color(hex:)` helper. All views read colors from here; don't reintroduce
`Color(nsColor: .windowBackgroundColor)`-style system colors.

## SwiftTerm dependency (fork)

`Package.swift` pins **`luanzt/SwiftTerm`** (a fork), not upstream. The only change
is `Buffer.isReflowEnabled → false`: upstream rewraps lines on resize, which makes
zsh/powerlevel10k leave duplicated prompt lines on every resize. To bump SwiftTerm,
rebase the fork's `edev-no-reflow` branch onto the new upstream revision, re-apply
that one-line patch, and update the `revision:` in `Package.swift` — do not point
back at upstream.
