# mTerm

A native macOS terminal **multiplexer** — run several shells side by side in one
window, split panes by drag-and-drop, maximize one to focus, and keep everything
organized in workspace folders. Built in Swift with SwiftUI + AppKit, backed by
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) for the terminal engine.

> **Requires macOS 14 (Sonoma) or later**, Apple Silicon or Intel.

---

## Install

1. Download `mTerm-<version>.dmg` from the
   [**latest release**](https://github.com/luanzt/mTerm/releases/latest).
2. Open the `.dmg` and drag **mTerm** into your **Applications** folder.
3. **First launch:** the app is ad-hoc signed but *not notarized*, so macOS
   Gatekeeper will block a normal double-click. Pick whichever is easiest:
   - **Right-click the app ▸ Open**, then confirm in the dialog — once is enough.
   - Or System Settings ▸ Privacy & Security ▸ *Open Anyway*.
   - Or strip the quarantine flag from Terminal, then open normally:
     ```bash
     xattr -c /Applications/mTerm.app
     ```
     (`xattr -c` clears the `com.apple.quarantine` attribute macOS adds to
     downloaded apps, so Gatekeeper stops blocking it.)

---

## Using mTerm

mTerm opens with a sidebar and a pane deck. Almost everything is driven by the
mouse; the sidebar is your session and workspace list.

### Sessions & workspace folders
- **New terminal** — click **＋ New terminal** at the top of the sidebar. It
  spawns a fresh shell in a new pane.
- **Workspace folders** — group related terminals into folders (e.g. one folder
  per project). Add a folder with the **folder ＋** button; opening a terminal
  inside a folder starts it in that folder's chosen directory.
- **Reorder** — drag sessions or folders in the sidebar to rearrange them.
- **Close** — hover a session and click its **✕**, or use its context menu.

### Splitting the pane deck
The deck holds up to **3 columns**, and a column can be split into **2 rows** —
so you can see several shells at once.

- **Drag a session from the sidebar onto a pane** to place it. Drop zones light
  up as you hover:
  - **center** → replace the pane
  - **left / right** → open a new column beside it
  - **top / bottom** → split that column into two rows
- Panes float with small gaps; the layout self-heals if a drag leaves it in an
  odd state.

### Focus & sizing
- **Maximize a pane** — click the **⤢** button in a pane's header to blow it up
  to fill the deck. Click **⤡** to restore the previous layout. Any structural
  change to the grid (adding/closing a pane) clears the saved layout.
- **Resize** — drag the gutter between columns, or between the two rows of a
  split column, to change the split ratios.

### Keyboard
| Shortcut | Action |
|----------|--------|
| **⌘B**   | Toggle the sidebar (also **View ▸ Toggle Sidebar**, or the titlebar button) |

> Hidden sessions keep running. A shell parked out of the visible grid is **not**
> killed — its process stays alive so nothing is lost when you swap panes.

---

## Build from source

mTerm is a Swift Package Manager **executable** (not an Xcode `.xcodeproj`). You
need the Swift toolchain that ships with Xcode 15+ (or the standalone toolchain).

```bash
git clone https://github.com/luanzt/mTerm.git
cd mTerm

swift build            # compile (debug)
swift run mTerm        # build & launch the app
swift test             # run the test suite
```

Run a single test / suite (XCTest name filter):

```bash
swift test --filter PaneGridTests
swift test --filter WorkspaceStoreTests/testToggleMaximizeCollapsesThenRestoresLayout
```

> **Editor diagnostics can lie.** SourceKit inline errors in this project are
> frequently stale (e.g. "Cannot find X in scope" right after adding a file).
> Trust `swift build` / `swift test`, not the squiggles.

### Building a distributable `.app` / `.dmg`

```bash
./scripts/package.sh 1.2.3     # → build/mTerm-1.2.3.dmg
```

The script does a release build, assembles `mTerm.app` (embedding
`packaging/AppIcon.icns` if present), **ad-hoc code-signs** it so it launches on
Apple Silicon, and packs it into a drag-to-Applications `.dmg`. The result is
**not notarized** — see the first-launch note under [Install](#install).

### Cutting a release

Maintainers can use the bundled `release-app` skill (or run the steps manually):

```bash
./scripts/package.sh <version>
git tag v<version> && git push origin v<version>
gh release create v<version> build/mTerm-<version>.dmg --generate-notes
```

---

## Architecture (at a glance)

| Piece | File | Role |
|-------|------|------|
| App boot | `Sources/mTerm/main.swift`, `mTermApp.swift` | Boots `NSApplication`, builds the menu, hosts SwiftUI in an `NSWindow` |
| State | `Store/WorkspaceStore.swift` | Single `@MainActor` source of truth: sessions, workspaces, selection, the grid |
| Layout model | `Models/PaneGrid.swift` | Pure value type: columns → panes, with drop-zone placement and self-healing invariants |
| Rendering | `Views/WorkspaceView.swift` | Lays panes out by absolute frame + offset; parks hidden sessions off-screen |
| Terminal bridge | `Views/TerminalHostView.swift` | Wraps SwiftTerm's `LocalProcessTerminalView` |
| Theme | `Views/Theme.swift` | The "Emerald" dark palette |

Only **workspace folders** are persisted (UserDefaults); terminal sessions are
intentionally ephemeral and rebuilt each launch.

For the deeper design notes — and the non-obvious constraints (no pane-frame
animation, off-screen parking, the grid invariant) — see
[`CLAUDE.md`](./CLAUDE.md).

### SwiftTerm fork

`Package.swift` pins **`luanzt/SwiftTerm`**, a fork of upstream with a single
change: `Buffer.isReflowEnabled = false`. Upstream rewraps lines on resize, which
makes zsh / powerlevel10k leave duplicated prompt lines on every resize. To bump
SwiftTerm, rebase the fork's `edev-no-reflow` branch onto the new upstream
revision, re-apply that one-line patch, and update the `revision:` pin — don't
point back at upstream.
