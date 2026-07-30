# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
swift build                       # build
swift test                        # run all tests
swift run mTerm                   # build & launch the app (macOS GUI window)
.build/debug/mTerm &              # launch an already-built binary in the background

# Build a distributable, Sparkle-enabled app/DMG and prepare its signed feed:
./scripts/package.sh 1.2.3
./scripts/generate-appcast.sh 1.2.3

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
(`mTermApp.swift`) that manually builds the macOS menus and hosts the SwiftUI
`WorkspaceView` in an `NSWindow` via `NSHostingView`.

The manual menu currently owns these app-wide commands:

- mTerm ▸ Check for Updates… — Sparkle's standard updater UI.
- View ▸ Toggle Sidebar — ⌘B.
- Panes ▸ Pane 1…6 — ⌘1…⌘6, in the same visual order as `grid.paneIDs`.

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

`PaneGrid.paneIDs` is also the canonical pane-shortcut order: columns from left
to right, then panes from top to bottom within each column. Both
`WorkspaceStore.focusGridPane(at:)` and `shortcutNumber(for:)` must derive from
that same array. Visible pane headers show the matching `⌘N` badge immediately
to the left of the maximize/restore button; hidden sessions have no shortcut.

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

`ShellIntegration.terminalBaseEnvironment` replaces inherited terminal identity
with `TERM_PROGRAM=mTerm`, advertises true color, and defaults
`FORCE_HYPERLINK=1` because SwiftTerm supports OSC 8 but generic
`xterm-256color` detection cannot know that. This lets Claude/Ink-style CLIs emit
compact labels such as `#2761` with the URL embedded instead of printing a
fallback `#2761 (https://…)`. Preserve an explicit `FORCE_HYPERLINK=0` opt-out.

### Theme

`Views/Theme.swift` — `MTermTheme` holds the whole "Emerald" dark palette + a
`Color(hex:)` helper. All views read colors from here; don't reintroduce
`Color(nsColor: .windowBackgroundColor)`-style system colors. Terminal
foreground/cursor/link and ANSI 0–15 intentionally mirror the dark variants in
iTerm2's `plists/DefaultBookmark.plist`; the terminal background remains mTerm's
deck color so the embedded view blends into the pane.

## Dependencies

### SwiftTerm (fork)

`Package.swift` pins **`luanzt/SwiftTerm`** (a fork), not upstream. The fork carries
two mTerm-specific changes:

- `Buffer.isReflowEnabled → false`, because upstream rewraps lines on resize and
  makes zsh/powerlevel10k leave duplicated prompt lines.
- Apple terminal views expose `linkForegroundColor` and `linkHighlightColor`, so
  explicit OSC 8 links can match normal text at rest and change color only while
  highlighted; macOS also uses a pointing-hand cursor only while the configured
  link mode allows activation.

To bump SwiftTerm, rebase the fork's `edev-no-reflow` branch onto the new upstream
revision, re-apply both changes, and update the `revision:` in `Package.swift` —
do not point back at upstream.

### Sparkle

`Package.swift` pins Sparkle exactly. `MTermAppDelegate` retains a lazy
`SPUStandardUpdaterController`; the Check for Updates menu item targets the
controller directly. Do not replace this with a browser-only release checker:
Sparkle downloads the DMG, verifies its EdDSA signature, replaces the installed
app, and relaunches it.

SwiftPM's release executable alone is not distributable. `scripts/package.sh`
must continue to:

- copy `Sparkle.framework` into `mTerm.app/Contents/Frameworks`;
- add `@executable_path/../Frameworks` to the executable's rpath;
- write `SUFeedURL`, `SUPublicEDKey`, and `SUEnableAutomaticChecks` to Info.plist;
- preserve Sparkle's nested signatures, sign the outer app without
  `codesign --deep`, then verify with `codesign --verify --deep --strict`.

The app is currently ad-hoc signed and **not notarized**. Sparkle's EdDSA
signature authenticates update archives, but it is not Apple notarization.

## Release and update feed

`.claude/skills/release-app/SKILL.md` is the canonical release checklist. The
ordering matters:

1. Package `build/mTerm-<version>.dmg`.
2. Generate and verify `build/appcast.xml` with
   `scripts/generate-appcast.sh`.
3. Tag and publish the GitHub Release with that exact DMG.
4. Only after the release asset exists, copy the prepared feed to the repository
   root as `appcast.xml`, commit it, and push `main`.

The live feed is
`https://raw.githubusercontent.com/luanzt/mTerm/main/appcast.xml`. Never publish
an appcast that points at a missing release asset.

Sparkle signing uses the macOS Keychain account `mterm-ed25519`; the matching
public key embedded by `package.sh` is
`LzG6J9ahpYdZHqj/wzaotCscwjxGcVnN6zfv10dqqsU=`. The private key must never be
committed, printed in logs, or replaced casually: apps already installed with
this public key would reject future updates signed by a different key.

Version 1.1.2 predates the live appcast and is the one-time manual bootstrap.
Users install the first Sparkle-enabled release manually; subsequent releases
can update in place through mTerm ▸ Check for Updates….
