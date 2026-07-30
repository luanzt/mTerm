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

### Agent attention notifications

Agent notifications are event-driven, not inferred from rendered terminal
output or an idle timer.

#### Claude Code

1. `ClaudeIntegration.writeFiles()` creates a local Claude plugin under
   `~/Library/Application Support/mTerm/claude-notifications`.
2. The generated zsh startup file prepends a narrow `claude` executable shim to
   that pane's `PATH`. The shim preserves all CLI arguments and adds only
   `--plugin-dir`; it does not edit `~/.claude/settings.json`, and plugin hooks
   merge with existing user/project hooks.
3. The plugin listens to Claude Code's official `Notification` event for
   `permission_prompt`, `idle_prompt`, `elicitation_dialog`,
   `agent_needs_input`, and `agent_completed`. Its hook returns an allowlisted
   `terminalSequence` containing the private
   `OSC 777;notify;mTerm Claude;<kind>` payload. It never includes prompt/tool
   content.
4. `TerminalHostView` receives that OSC on the originating PTY and forwards it
   with the pane's session ID. `AgentNotificationCoordinator` posts a native
   `UNUserNotificationCenter` alert only while `NSApp` is inactive. Clicking it
   activates mTerm and focuses/reopens the originating session.

Authorization is requested in context the first time a supported agent starts,
rather than at app launch. Do not replace the Claude hook with `Stop` (which is
not synonymous with "needs attention"), output regexes, process polling, or a
quiet-time heuristic. Keep the OSC parser restricted to mTerm's marker and known
enum values so arbitrary terminal programs cannot forge these alerts.

`swift run` executes an unbundled binary from `.build`, where
`UNUserNotificationCenter.current()` raises an Objective-C exception because
LaunchServices has no application bundle proxy. The notification coordinator
must remain a safe no-op in that mode; packaged `.app` launches retain native
notification authorization, delivery, and click-through.

#### Codex CLI

`CodexIntegration.writeFiles()` creates a `codex` PATH shim under
`~/Library/Application Support/mTerm/codex-notifications`. The shim keeps the
user's arguments and applies four invocation-only overrides:

- `tui.notifications=true` enables Codex's built-in attention events, including
  completed turns, approval requests, and interactive prompts.
- `tui.notification_method="osc9"` makes the TUI emit its supported OSC 9
  terminal notification instead of BEL.
- `tui.notification_condition="always"` ensures mTerm receives events even
  without terminal focus reporting. `AgentNotificationCoordinator` still
  suppresses native notifications while `NSApp` is active.
- `tui.terminal_title=["thread-title"]` makes Codex publish its manually assigned
  thread name, or its thread UUID while unnamed, through standard OSC 0/2
  terminal-title updates without the animated activity/project-name suffix.

No `~/.codex/config.toml` setting is edited. A later user-supplied `-c` argument
can override these defaults for an individual invocation. Because OSC 9 is a
general terminal notification protocol, `TerminalHostView` accepts it only
while shell integration says `codex` is the pane's foreground command. The
Codex-supplied message is validated but deliberately not copied into
Notification Center: it may contain assistant text, a command, or a file path.
The native alert uses a privacy-safe generic summary and still routes back to
the exact pane when clicked. The same foreground-command state swaps both the
sidebar and pane-header running dots for the white OpenAI app mark while Codex
is active. Claude uses its terracotta app mark in those same two locations.

#### Agent conversation titles

Claude Code publishes its current conversation title through standard OSC 0/2;
the Codex invocation override above requests its thread-title signal.
`TerminalHostView` receives those updates through SwiftTerm's process delegate
and briefly debounces them to avoid rendering Claude's animated title states.
`WorkspaceStore` validates and accepts the result only while shell integration
reports `claude` or `codex` as the pane's foreground command.

Codex's `thread-title` falls back to a UUID until the user runs `/rename` or
starts with `--name`; never display that identifier. `CodexThreadTitleResolver`
uses the UUID to query only the matching row's `name`/`title` fields in Codex's
local `state_*.sqlite` metadata, with bounded retries for a new chat's first
prompt. It does not read rollout JSONL or prompt/assistant transcript content.
An OSC name from `/rename`, `--name`, or a named `/resume` cancels and overrides
the metadata lookup.

Keep the agent title as a separate display-only overlay. Never mutate the
session's stable `Terminal N` title, infer a title from rendered terminal text,
or read an agent's transcript. Clear the overlay when the next
foreground-command marker arrives, including the shell's idle `precmd` marker
after the agent actually exits. A Ctrl-C that only cancels an in-agent turn does
not return to the shell and therefore must not restore `Terminal N`.

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
