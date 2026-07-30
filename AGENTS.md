# Repository instructions

These instructions apply to the whole mTerm repository. `CLAUDE.md` contains
the deeper architecture notes; keep it synchronized when changing core app,
pane-layout, updater, or release behavior.

## Build and verify

- Use `swift build` for a normal build and `swift test` for the full test suite.
- Treat SourceKit/editor diagnostics as advisory; they are often stale here.
  Confirm Swift failures with the command-line build.
- A distributable build is not complete after `swift build -c release`. Run
  `./scripts/package.sh <version>` and verify the resulting
  `build/mTerm-<version>.dmg`.
- Preserve unrelated user changes in a dirty worktree.

## Architecture invariants

- mTerm is a SwiftPM executable with a manually bootstrapped `NSApplication`,
  not a SwiftUI `App`.
- `WorkspaceStore` is the `@MainActor` source of truth. Route session, grid,
  selection, maximize, and resize mutations through it.
- Preserve `PaneGrid.enforceInvariants()` and its no-empty/no-duplicate-pane
  guarantees.
- Keep every terminal session's SwiftTerm view alive. Hidden sessions are
  parked off-screen so their shell processes keep running.
- Keep terminal pane frames non-animated; intermediate PTY resizes create a
  SIGWINCH/prompt-redraw storm.
- Keep `NSHostingView.sizingOptions = []` and the deck's top-leading alignment.
- Keep mTerm's child-process terminal identity and capability advertisement in
  `ShellIntegration.terminalBaseEnvironment`. OSC 8-capable CLI renderers rely
  on `FORCE_HYPERLINK=1`; preserve the user's explicit `0` opt-out.
- Use `MTermTheme` rather than reintroducing system colors.

## Pane shortcuts

`grid.paneIDs` defines visual shortcut order: left-to-right columns and then
top-to-bottom panes. `WorkspaceStore.focusGridPane(at:)`, the `⌘1…⌘6` Panes
menu, and each header's `⌘N` badge must remain in sync. The badge belongs
immediately to the left of the maximize/restore button and is shown only for a
visible grid pane.

## Dependencies

- Keep the pinned `luanzt/SwiftTerm` fork. It disables buffer reflow to prevent
  duplicated shell prompts during resize and exposes separate resting/highlight
  link colors plus an activation-aware pointing-hand cursor; do not silently
  switch to upstream.
- Sparkle is the in-app updater. Keep the standard updater controller retained
  by `MTermAppDelegate` and keep Check for Updates wired to it.
- Packaging must embed `Sparkle.framework`, add its executable rpath, include
  the Sparkle feed/public-key Info.plist values, preserve nested signatures, and
  verify the completed bundle.

## Releases

Use `.claude/skills/release-app/SKILL.md` for the full release workflow. In
summary:

1. `./scripts/package.sh <version>`
2. `./scripts/generate-appcast.sh <version>`
3. Publish tag and GitHub Release with the generated DMG.
4. After the asset is public, publish `build/appcast.xml` as root
   `appcast.xml`.

Do not publish a tag/release if packaging, appcast generation, EdDSA
verification, or tests fail. The Sparkle private key lives only in the macOS
Keychain account `mterm-ed25519`; never commit or log it. The app is ad-hoc
signed and not Apple-notarized, so do not describe it as notarized.

When Codex creates a commit in this repository, include:

`Co-authored-by: Codex <codex@openai.com>`
