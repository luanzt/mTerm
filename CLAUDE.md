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

- mTerm ▸ About mTerm — opens AppKit's standard About panel with only the
  marketing version; the duplicate build-version suffix is intentionally hidden.
- mTerm ▸ Check for Updates… — Sparkle's standard updater UI.
- mTerm ▸ Settings… — ⌘, opens the retained typography/ANSI settings window.
- File ▸ New Terminal — ⌘N creates an ungrouped OPEN SESSIONS terminal in the
  focused pane; ⇧⌘N opens it as another pane, or replaces the focused pane when
  all six slots are occupied.
- File ▸ New Workspace Terminal — ⌘T creates a terminal in the focused
  session's workspace and replaces that pane; ⇧⌘T opens another pane with the
  same six-pane fallback. Both are no-ops when the focused session is ungrouped.
- Edit ▸ Copy / Paste — ⌘C / ⌘V route through the responder chain. There is no
  Select All shortcut.
- View ▸ Toggle Sidebar — ⌘B.
- Panes ▸ Toggle Pane Maximize — ⌥F maximizes the focused pane or restores
  its previous layout.
- Panes ▸ Pane 1…6 — ⌘1…⌘6, in the same visual order as `grid.paneIDs`.

- `hosting.sizingOptions = []` is deliberate: without it, each SwiftTerm view's
  intrinsic width propagates up and AppKit grows the *window* when you add a pane.

### Application and terminal lifecycle

The main window's close button intentionally does **not** close its
`NSHostingView`: `MTermAppDelegate.windowShouldClose` hides mTerm and returns
`false`. Reopening from the Dock unhides and fronts that same window instance, so
every SwiftTerm view, PTY, process, SSH connection, live command, and scrollback
continues untouched. Settings remains an ordinary closeable retained window.
`applicationShouldTerminateAfterLastWindowClosed` must stay `false`, and the main
window uses the stable `mTerm.mainWindow` frame autosave name.
Notification click-through must unhide the application before fronting the main
window and selecting the originating session.

`⌘Q` has deliberately different semantics. `applicationShouldTerminate` applies
the persisted `QuitBehavior`: `.restorePanes` synchronously flushes the durable
workspace snapshot, while `.startClean` cancels pending writes and removes that
snapshot so the next launch starts with one ungrouped shell. Clean quit preserves
workspace folders and app settings. Both modes then remove event monitors, call
`TerminalProcessRegistry.terminateAll(force: true)`, and dismantle both hosting
views before returning `.terminateNow`. Do not route quit through session-close
mutations or make process cleanup conditional: quitting must release shells,
Node, Claude, Codex, and other processes still owned by mTerm's terminal Unix
sessions. There is no detached PTY/tmux/helper daemon, so SSH, arbitrary running
commands, editor state, terminal scrollback, and an exact in-flight response byte
position do not survive `⌘Q`.

### State: `WorkspaceStore` (Store/WorkspaceStore.swift)

Single `@MainActor ObservableObject`, the source of truth for everything:
`sessions`, `workspaces` (folders), selection/hover/drag IDs, and the `grid`.
All mutations (create/close/hide/place/maximize/resize) go through it. Workspace
folders remain persisted in UserDefaults. Durable terminal state is separately
written atomically to
`~/Library/Application Support/mTerm/workspace-v1.json` through
`WorkspaceSnapshotStore`: ordered sessions, stable titles/manual-rename flags,
last CWD, workspace IDs, visible and saved/maximized grids, geometry, selection,
sidebar state, terminal sequence, and an exact active-agent locator. Writes are
debounced after mutations and synchronously flushed before quit. Snapshot decode
and repair remove orphan/duplicate/over-capacity panes, clamp geometry, detach
missing workspaces, fall back to home for a vanished CWD, and leave malformed or
unsupported files untouched until the user makes a new durable mutation.
PIDs, process status, transient agent titles, working/attention state, hover,
drag, resize, and find UI are runtime-only and must not be added to the schema.
`savedGrid` backs maximize↔restore and is cleared by any structural grid change.
Keyboard creation commands explicitly target `selectedSessionID`. A normal
sidebar session click replaces the focused pane; it must not use the last-hovered
pane because that hover becomes stale after the pointer enters the sidebar.
Command-click adds a hidden session as a split, or focuses it if it is already
visible, retaining the normal six-pane fallback when the grid is full. Sidebar
creation actions also replace the focused pane; stale hover state must not
override an explicit pane selection.
`renameSession` is the only user-title mutation path. A manually renamed stable
title is shared by the sidebar, pane header, and notification subtitle, and takes
precedence over later transient Claude/Codex OSC titles for that session.
Workspace folder rows expose creation in the active pane or a split, Finder and
path actions, and a display-name-only rename. Removing a workspace asks for
confirmation, closes all of its terminal sessions and their process trees, but
never deletes the folder on disk.
Session rows expose active-pane/split opening, a fresh terminal in the same live
directory, Finder/path actions, rename, and close. Double-clicking a session row
renames it inline; Return or focus loss commits, while Escape cancels.
The two open actions are disabled while that session is already visible because
the pane-grid invariant forbids showing the same terminal view more than once.

### Appearance settings: `AppSettings` (Store/AppSettings.swift)

`AppSettings` is the persistent `@MainActor ObservableObject` for terminal font
family, terminal content size, sidebar text size and width, the 16-color ANSI
palette, and the
default new-terminal placement. The placement defaults to the current pane;
normal creation actions honor it, while explicitly split-labelled actions and
⇧⌘N/⇧⌘T always request a split. The app delegate owns one instance and injects
it into both `WorkspaceView` and the
retained Settings window. Values are validated when loaded from UserDefaults;
the defaults remain the Meslo/system-monospace 14 pt terminal, 13 pt sidebar,
and `MTermTheme.ansiPalette`. Font and palette updates must be applied to the
existing SwiftTerm views rather than recreating them or their shell processes.
The sidebar width defaults to 250 pt, is clamped to 180–420 pt, persists, and can
be changed either in Settings or by dragging its trailing divider without animation.

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
Keep the badge and header buttons horizontally fixed so a long agent title can
truncate without collapsing those controls. Pane headers provide maximize and
hide controls only; closing a terminal is intentionally available from its
sidebar row instead.

Visible panes can be dragged from anywhere in their header, including its empty
space and controls; ordinary clicks on header controls still perform their
actions. Pane drag is disabled while maximized. A center drop swaps the two
visual slots, while edge drops move the source beside/above/below the target
without hiding a session. Capacity checks run after hypothetically removing the
source, allowing same-column row reorder and reuse of a column freed at the
three-column limit.
Unavailable edges are excluded from hit-testing so the remaining target area
falls back to a stable center swap rather than silently cancelling the drop. New
row moves reset that column to 50/50. Keep this pane-move state distinct from
sidebar session drags, whose center drop retains its open/replace behavior.

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
- A *deliberate* divider/window drag is also a stream of intermediate sizes, so
  the same storm applies. `WorkspaceStore.beginPaneResize`/`endPaneResize` post
  `mtermPaneResizeBegan/Ended`; each terminal defers its child-PTY winsize for the
  drag and flushes the final size once on release (window live-resize does the same
  via `viewWillStartLiveResize`). The local emulator still resizes live, so display
  stays correct — only the child SIGWINCH is coalesced. Drive this through
  NotificationCenter, **not** a `@Published`/`updateNSView` binding: reading resize
  state in a pane body while a drag mutates it trips a SwiftUI AttributeGraph cycle.
- Keep `TerminalPane` explicitly constrained to the `GeometryReader` size and
  keep its conversation title compressible/truncated. Agent titles can be much
  wider than a split pane; allowing either the title or SwiftTerm's intrinsic
  width to win makes the next pane appear to overlap the existing one.

### Terminal bridge: `TerminalHostView.swift`

`NSViewRepresentable` around SwiftTerm's `LocalProcessTerminalView`. The shell is
started from a **frame-change observer** (not `updateNSView`) the first time the
view has a real non-zero frame, so the PTY's initial winsize matches the pane and
prompts don't reprint on startup. `TerminalDeck.paneFrames` has a stderr tripwire
that logs `MTERM_GRID_ANOMALY` if a pane is ever duplicated/orphaned/missing a frame.
The bridge's focused-terminal key monitor maps Shift-Return and
Shift-keypad-Enter to LF (the same terminal input as Ctrl-J), so agent TUIs
insert a newline while plain Return keeps its normal CR/submit behavior.
Finder file drops are registered directly on the `FileDroppableTerminalView`
subclass rather than on a surrounding SwiftUI modifier: AppKit routes dragging
sessions to the embedded `NSView`. A drop focuses its pane and sends one escaped
path per file, using bracketed paste when the terminal mode requests it so
image-aware agent TUIs can attach Simulator screenshots.
Standard OSC 7 current-directory reports flow through the process delegate into
`WorkspaceStore`, which updates the folder label shared by the pane header and
sidebar without recreating the persistent terminal view.
The same shell-integration foreground marker (OSC 633 `run`/`idle`) also toggles
`Terminal.reflowOnResize`: on while a foreground program owns the pane so its
normal-buffer output rewraps across width changes (e.g. `yarn start` logs stay
un-clipped after shrink-then-widen), off again at the shell prompt so the prompt
never duplicates. Alt-screen TUIs are unaffected — their buffer has no scrollback,
so reflow stays disabled there regardless.
Sidebar session rows resolve single-click, Command-click, and double-click from
one tap handler. Do not install competing single/double SwiftUI tap gestures:
that defers every pane switch until macOS's double-click interval expires.
`TerminalHostView.updateNSView` also applies changed font and ANSI settings to
that same persistent view. It caches the last applied values in its coordinator
so unrelated SwiftUI updates do not repeatedly reset fonts, palettes, or PTY size.
The standalone SwiftTerm `NSScroller` is hidden to remove the trailing gray bar;
scrollback remains enabled through SwiftTerm's direct wheel/trackpad handling.
`TerminalProcessRegistry` records each PTY shell's Unix session ID. Closing a
session, removing a workspace, and quitting mTerm signal every process still in
the corresponding terminal session, then escalate from SIGTERM to SIGKILL after
a short grace period. Cleanup is app-owned and must not depend only on SwiftUI's
eventual `dismantleNSView`; that hook remains an idempotent fallback and releases
SwiftTerm's PTY resources.

Every restored terminal still starts a normal interactive login shell (`-l`),
never a persisted arbitrary command or `-lc`. A
`TerminalRestoreCommandCoordinator` owns one typed restore intent for the
lifetime of that terminal view. After OSC 633 reports the shell's first idle
prompt, the bridge reports idle to `WorkspaceStore`, marks restoration launched,
then sends exactly one safely shell-quoted command plus CR:
`claude --resume <uuid>`, `codex resume <uuid>`, or
`codex resume -- <exact-name>`. The `--` delimiter prevents a name such as
`--last` from becoming a CLI option. This ordering preserves the first pending
locator while allowing a failed command that returns to idle to clear it and
avoid a relaunch loop. Hidden restored sessions follow the same path because
their terminal views are still constructed and parked off-screen.

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

The plugin also listens to Claude Code's official `UserPromptSubmit`, `Stop`,
`StopFailure`, `PostCompact`, `SessionStart`, and `SessionEnd` lifecycle events
and emits distinct private
`OSC 777;state;mTerm Claude` `turn_started`/`turn_completed` payloads. Claude
ignores hook output for `StopFailure`, so the executable shim captures the
pane's controlling PTY before launching Claude and that handler writes the same
non-notifying completion sequence to it directly. A manual `PostCompact` clears
the turn because Claude emits no `Stop` for `/compact`; automatic compaction does
not clear it because the same turn continues. `SessionStart` clears stale work
for startup/resume/`/clear`, and `SessionEnd` is the final lifecycle boundary.
These payloads drive only the sidebar spinner; they are never forwarded as
attention notifications and do not inspect prompt, transcript, or assistant
message fields.

For `SessionStart`, the hook also extracts only `session_id` from stdin and
returns the private `OSC 777;session;mTerm Claude;<uuid>` sequence before its
completion sequence. The Swift parser accepts that UUID only while shell
integration says Claude owns the pane. Startup, resume, clear, compact, and fork
therefore replace the stable resume locator without reading a transcript or
modifying user/project Claude settings.

Authorization is requested in context the first time a supported agent starts,
rather than at app launch. Do not replace the Claude `Notification` hook with
`Stop` (which is not synonymous with "needs attention"), or use output regexes,
process polling, or a quiet-time heuristic. `Stop` is allowed only for the
non-notifying working-state transition above. Keep the OSC parser restricted to
mTerm's marker and known enum/state values so arbitrary terminal programs cannot
forge these events.

Foreground-command markers use zsh `preexec`'s alias-expanded command argument,
so aliases such as `cs='claude --model ...'` still activate Claude's pane icon,
working indicator, title handling, and trusted attention routing. Do not switch
this back to the command line exactly as typed.

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
- `tui.terminal_title=["app-name","run-state","thread-title"]` gives mTerm a
  scoped, non-animated lifecycle protocol (`Starting`, `Working`, `Thinking`,
  `Waiting`, or `Ready`) followed by Codex's manual thread name or unnamed UUID.

No `~/.codex/config.toml` setting is edited. A later user-supplied `-c` argument
can override these defaults for an individual invocation. Because OSC 9 is a
general terminal notification protocol, `TerminalHostView` accepts it only
while shell integration says `codex` is the pane's foreground command. The
Codex-supplied message is validated but deliberately not copied into
Notification Center: it may contain assistant text, a command, or a file path.
The native alert uses a privacy-safe generic summary and still routes back to
the exact pane when clicked. The same foreground-command state swaps both the
sidebar and pane-header terminal prompt marks for the white OpenAI app mark while
Codex is active. Claude uses its terracotta app mark in those same two locations.
Ordinary terminal sessions use a graphite app tile with a green `>` and white
underscore instead of a status dot; exited sessions dim that prompt motif.

The sidebar alone shows a spinner while an active Claude/Codex TUI is processing
a response. Claude's official lifecycle hooks own its state. After a trusted
Claude permission, elicitation, or agent-needs-input notification, Return may
also resume work without a new top-level prompt. Codex activity must come only
from the TUI-owned `run-state` title: `Starting`/`Working`/`Thinking`/`Waiting`
set working and `Ready` clears it. Never infer Codex activity from Return; slash
commands, menus, approvals, and short-lived local interactions make keyboard
inference asymmetric and can strand a spinner when no matching OSC 9 attention
event follows. OSC 9 remains the attention channel and an additional clear
boundary. Escape/Ctrl-C, returning to the shell, or closing the session also
clears either agent's state. Keep this indicator out of pane headers and terminal
content.

#### Agent conversation titles

Claude Code publishes its current conversation title through standard OSC 0/2;
the Codex invocation override above requests scoped run-state + thread-title
segments.
`TerminalHostView` receives those updates through SwiftTerm's process delegate.
Claude titles are briefly debounced to avoid rendering animated decoration;
scoped Codex run-state titles are delivered immediately to preserve event order.
`WorkspaceStore` validates and accepts the result only while shell integration
reports `claude` or `codex` as the pane's foreground command. It strips Codex's
`codex | <run-state> |` protocol prefix before title/locator handling.

Codex's `thread-title` falls back to a UUID until the user runs `/rename` or
starts with `--name`; never display that identifier. `CodexThreadTitleResolver`
uses the UUID to query only the matching row's `name`/`title` fields in Codex's
local `state_*.sqlite` metadata, with bounded retries for a new chat's first
prompt. It does not read rollout JSONL or prompt/assistant transcript content.
An OSC name from `/rename`, `--name`, or a named `/resume` cancels and overrides
the metadata lookup.

The UUID is also persisted immediately as that pane's exact Codex resume locator,
separately from transient display-title lookup state; cancellation or `/rename`
must never erase a UUID already known for the active thread. When Codex exposes
only a name, mTerm stores the validated exact name as a fallback and queries only
SQLite metadata rows for exact name + standardized CWD. A unique valid result
upgrades the locator to UUID; an absent or ambiguous result keeps the name.
The persisted/resumed name is the raw validated OSC value; display normalization
may collapse whitespace or truncate the sidebar label but must not mutate that
locator. Neither path opens rollout JSONL. Returning to the shell after an
acknowledged agent, or returning to idle after a launched restore without
receiving identity, clears the locator so the next app launch stays at a plain
shell.

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
foreground/cursor and ANSI 0–15 intentionally mirror the dark variants in
iTerm2's `plists/DefaultBookmark.plist`; the terminal background remains mTerm's
deck color so the embedded view blends into the pane. Those ANSI values are the
reset defaults; `AppSettings.ansiColors` is the live user-selected palette.

## Dependencies

### SwiftTerm (fork)

`Package.swift` pins **`luanzt/SwiftTerm`** (a fork), not upstream. The fork carries
these mTerm-specific changes:

- `Buffer.isReflowEnabled → hasScrollback && reflowOnResize`, making rewrap-on-
  resize a per-terminal toggle (`Terminal.reflowOnResize`, default `false`). Reflow
  stays off for shell prompts because zsh/powerlevel10k redraw on SIGWINCH assuming
  xterm no-reflow and otherwise leave duplicated prompt lines. mTerm turns it on
  only while a foreground program owns the pane (see below).
- `LocalProcessTerminalView.defersProcessWindowSizeUpdates` (default `false`) holds
  back intermediate child-PTY winsizes and flushes the final one when cleared, so a
  drag does not storm the shell with SIGWINCH.
- Apple terminal views expose `linkForegroundColor` and `linkHighlightColor`,
  but mTerm leaves both unset so explicit OSC 8 links retain the foreground
  emitted by the terminal application. On ⌘-hover, SwiftTerm keeps that color
  while adding an underline. macOS uses the pointing-hand cursor only while the
  configured link mode allows activation.

`Package.swift` pins the tip of the fork's `mterm` branch, which carries exactly
these changes on top of upstream. (`edev-no-reflow` is the working branch these
were developed on; `mterm` is the stable set mTerm ships against — keep it at the
pinned revision.)

To bump SwiftTerm, rebase the fork's `mterm` branch onto the new upstream
revision, re-apply these changes, and update the `revision:` in `Package.swift` —
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
