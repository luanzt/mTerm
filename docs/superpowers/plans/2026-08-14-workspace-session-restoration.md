# Workspace Session Restoration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist mTerm's durable workspace state on quit, rebuild every terminal pane on relaunch, and automatically resume the exact Claude Code or Codex conversation that was active in each pane while preserving process cleanup on `⌘Q` and keeping all PTYs alive when the main window's `X` is clicked.

**Architecture:** Add a versioned, atomically written snapshot DTO layer between `WorkspaceStore` and runtime models. `WorkspaceStore` remains the `@MainActor` source of truth and owns stable per-pane agent locators plus the restore state machine. Every restored terminal starts a normal interactive login shell; after its first shell-idle OSC, `TerminalHostView` injects one typed, shell-escaped resume command exactly once. The app delegate hides the existing main window on `X`, but synchronously flushes the store before retaining the current forceful process cleanup on `⌘Q`.

**Tech Stack:** Swift 6, SwiftPM, AppKit, SwiftUI, Combine, SwiftTerm, XCTest, Foundation JSON/SQLite process access.

**Spec:** `docs/superpowers/specs/2026-08-14-workspace-session-restoration-design.md`

## Global Constraints

- Keep `WorkspaceStore` as the only mutation owner for sessions, grids, selection, maximize state, and agent restore state.
- Keep every `TerminalHostView` alive, including hidden restored sessions; do not add tmux, a daemon, or detached PTYs.
- Always start an interactive login shell (`-l`). Never restore through `SessionRecord.command`, `zsh -lc`, `--last`, or `--continue`.
- Keep `TerminalProcessRegistry.terminateAll(force: true)` and SwiftTerm teardown on `⌘Q`.
- Preserve the current Claude plugin/shim and Codex invocation-scoped notification channels; generated files must not alter user or project settings.
- Do not persist PIDs, terminal scrollback, transient titles, spinner/attention state, drag/hover/find state, or live process status.
- Production enables snapshot persistence explicitly; existing `WorkspaceStore(defaults:)` tests remain isolated from the user's real Application Support file.
- Every implementation commit must include `Co-authored-by: Codex <codex@openai.com>`.

---

## Task 1: Define the versioned snapshot and deterministic grid repair

**Files:**

- Create: `Sources/mTerm/Models/WorkspaceSnapshot.swift`
- Create: `Tests/mTermTests/WorkspaceSnapshotTests.swift`
- Modify: `Sources/mTerm/Models/SessionRecord.swift`

**Interfaces produced:**

```swift
struct WorkspaceSnapshot: Codable, Equatable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int
    var sessions: [SessionSnapshot]
    var grid: PaneGridSnapshot
    var savedGrid: PaneGridSnapshot?
    var selectedSessionID: UUID?
    var isSidebarVisible: Bool
    var sessionSequence: Int
}

struct SessionSnapshot: Codable, Equatable {
    var id: UUID
    var stableTitle: String
    var workingDirectory: String
    var workspaceID: UUID?
    var createdAt: Date
    var wasManuallyRenamed: Bool
    var activeAgent: AgentResumeDescriptor?
}

enum AgentResumeDescriptor: Codable, Equatable {
    case claude(sessionID: UUID)
    case codex(locator: CodexResumeLocator)
}

enum CodexResumeLocator: Codable, Equatable {
    case threadID(UUID)
    case name(String)
}

struct PaneGridSnapshot: Codable, Equatable {
    struct Column: Codable, Equatable {
        var panes: [UUID]
        var widthFraction: Double
        var rowFraction: Double
    }

    var columns: [Column]
    init(_ grid: PaneGrid)
    func repaired(validSessionIDs: [UUID], fallbackID: UUID?) -> PaneGrid
}
```

- [ ] Write `WorkspaceSnapshotTests` first. Cover JSON round-trip for every enum case, preservation of session order/manual rename/maximized `savedGrid`, unsupported schema rejection through `validated(validWorkspaceIDs:homeDirectory:fileManager:)`, and grid repair for orphan IDs, duplicates, empty columns, more than three columns, more than two rows, non-finite/out-of-range fractions, and an empty result falling back to the selected/first valid session.

  Core repair test shape:

  ```swift
  func testGridRepairDropsOrphansDuplicatesAndExcessCapacity() {
      let a = UUID(), b = UUID(), orphan = UUID()
      let snapshot = PaneGridSnapshot(columns: [
          .init(panes: [a, orphan, b], widthFraction: .infinity, rowFraction: 0.01),
          .init(panes: [a], widthFraction: -4, rowFraction: 2),
          .init(panes: [], widthFraction: 1, rowFraction: 0.5),
      ])

      let repaired = snapshot.repaired(validSessionIDs: [a, b], fallbackID: a)

      XCTAssertEqual(repaired.paneIDs, [a, b])
      XCTAssertEqual(repaired.columns.count, 1)
      XCTAssertEqual(repaired.columns[0].rowFraction, 0.2)
      XCTAssertTrue(repaired.columns[0].widthFraction.isFinite)
  }
  ```

- [ ] Run `swift test --filter WorkspaceSnapshotTests`. Expected: compilation fails because the snapshot types do not exist.

- [ ] Implement explicit tagged `Codable` representations for the two enums (a `kind` discriminator plus UUID/name field), so schema evolution never depends on Swift's synthesized enum wire format. Add conversions between `SessionRecord` and `SessionSnapshot`; restored records always use `command: ""` and `status: .running`.

- [ ] Implement `PaneGridSnapshot.repaired`. Preserve first occurrence order, cap at `PaneGrid.maxColumns` and two panes per column, clamp row fractions to `0.2...0.8`, replace invalid/non-positive width fractions with equal widths, then normalize the surviving widths to sum to one. If no pane survives, return `PaneGrid.single(fallback)` when possible; otherwise return an empty grid.

- [ ] Add `WorkspaceSnapshot.validated(validWorkspaceIDs: Set<UUID>, homeDirectory: URL, fileManager: FileManager = .default) -> WorkspaceSnapshot?`. Reject any schema other than `1` or a snapshot with no valid sessions; de-duplicate session IDs; detach missing workspace IDs; replace a missing/non-directory CWD with `homeDirectory.path`; repair both grids; drop `savedGrid` unless it still describes a valid multi-pane layout; and force selection into the visible grid.

- [ ] Run `swift test --filter WorkspaceSnapshotTests`. Expected: all snapshot and repair tests pass.

- [ ] Run `swift test --filter 'PaneGridTests|PaneGridHealTests|GridInvariantFuzzTests'`. Expected: existing grid invariants still pass.

- [ ] Commit:

  ```bash
  git add Sources/mTerm/Models/WorkspaceSnapshot.swift Sources/mTerm/Models/SessionRecord.swift Tests/mTermTests/WorkspaceSnapshotTests.swift
  git commit -m "feat: define workspace snapshot schema" -m "Co-authored-by: Codex <codex@openai.com>"
  ```

## Task 2: Add atomic snapshot storage with debounced writes and synchronous flush

**Files:**

- Create: `Sources/mTerm/Store/WorkspaceSnapshotStore.swift`
- Create: `Tests/mTermTests/WorkspaceSnapshotStoreTests.swift`

**Interfaces consumed:** `WorkspaceSnapshot` from Task 1.

**Interfaces produced:**

```swift
@MainActor
final class WorkspaceSnapshotStore {
    static var defaultFileURL: URL { get }

    init(fileURL: URL = WorkspaceSnapshotStore.defaultFileURL,
         debounceInterval: TimeInterval = 0.25)
    func load() -> WorkspaceSnapshot?
    func schedule(_ snapshot: WorkspaceSnapshot)
    func flush(_ snapshot: WorkspaceSnapshot)
}
```

- [ ] Write tests using a unique temporary directory. Verify `flush` creates parent directories and a decodable file, a second `schedule` replaces the first pending value, `flush` cancels pending work and writes the supplied newest value synchronously, writes use the expected `workspace-v1.json` URL, and malformed JSON returns `nil` without modifying its bytes.

  Debounce/flush test shape:

  ```swift
  @MainActor
  func testFlushCancelsPendingWriteAndPersistsNewestSnapshot() throws {
      let store = WorkspaceSnapshotStore(fileURL: fileURL, debounceInterval: 60)
      store.schedule(snapshot(sequence: 1))
      store.flush(snapshot(sequence: 2))

      let data = try Data(contentsOf: fileURL)
      XCTAssertEqual(try JSONDecoder().decode(WorkspaceSnapshot.self, from: data).sessionSequence, 2)
  }
  ```

- [ ] Run `swift test --filter WorkspaceSnapshotStoreTests`. Expected: compilation fails because `WorkspaceSnapshotStore` does not exist.

- [ ] Implement storage with a private `DispatchWorkItem?`. `schedule` captures the complete immutable snapshot and dispatches on the main queue after the configured interval. `flush` cancels the item and immediately encodes/writes with `Data.write(to:options:.atomic)`. `load` only reads/decodes; it never deletes or rewrites malformed data. Treat write errors as non-fatal and leave the previous atomic file intact.

- [ ] Run `swift test --filter WorkspaceSnapshotStoreTests`. Expected: all storage tests pass without sleeps longer than the debounce interval used by the test.

- [ ] Commit:

  ```bash
  git add Sources/mTerm/Store/WorkspaceSnapshotStore.swift Tests/mTermTests/WorkspaceSnapshotStoreTests.swift
  git commit -m "feat: persist workspace snapshots atomically" -m "Co-authored-by: Codex <codex@openai.com>"
  ```

## Task 3: Restore durable workspace state through WorkspaceStore

**Files:**

- Modify: `Sources/mTerm/Store/WorkspaceStore.swift`
- Modify: `Tests/mTermTests/WorkspaceStoreTests.swift`

**Interfaces consumed:** `WorkspaceSnapshotStore`, snapshot conversion/validation.

**Interfaces produced:**

```swift
init(defaults: UserDefaults = .standard,
     snapshotStore: WorkspaceSnapshotStore? = nil,
     codexTitleLookup: @escaping CodexTitleLookup = {
         await CodexThreadTitleResolver.title(for: $0)
     },
     codexThreadIDLookup: @escaping CodexThreadIDLookup = { name, directory in
         await CodexThreadTitleResolver.threadID(
             forExactName: name,
             workingDirectory: directory)
     })

func flushSnapshot()
func restorationIntent(for id: SessionRecord.ID) -> AgentResumeDescriptor?
```

- [ ] Replace the obsolete `testSessionsAreNotPersistedAcrossStoreInit` expectation with two explicit cases: no injected snapshot store still starts fresh (protecting existing unit tests), while two stores sharing an injected temporary snapshot file restore sessions. Add tests for stable title/manual rename, session order, workspace grouping, hidden session retention, grid fractions, selection, sidebar visibility, maximize/saved grid, monotonically continuing terminal numbers, CWD fallback, corrupted/unsupported snapshot fallback, and the fallback file remaining byte-for-byte unchanged until a real durable mutation.

- [ ] Add a test proving all restored sessions remain in `sessions` even when only one ID is present in `grid.paneIDs`; this is the model-side contract that lets `WorkspaceView` continue parking hidden terminal views off-screen.

- [ ] Run `swift test --filter WorkspaceStoreTests`. Expected: new persistence tests fail because the initializer ignores snapshots and `flushSnapshot`/`restorationIntent` are absent.

- [ ] Add optional `snapshotStore` injection. During init, load and validate once against already-loaded workspace IDs; if valid, rebuild sessions/grid/savedGrid/selection/sidebar/manual-renamed set/session sequence. Otherwise retain the current one-shell fallback. Do not schedule a write from initialization, so malformed/unsupported files are not overwritten merely by launch.

- [ ] Add a private stable descriptor dictionary populated from each restored `SessionSnapshot.activeAgent`, expose it read-only through `restorationIntent(for:)`, and project it back unchanged on flush. Runtime foreground/acknowledgement transitions are added in Task 4; this task only guarantees that loading and flushing durable workspace state cannot discard an agent locator.

- [ ] Add a single `makeSnapshot()` projection and `scheduleSnapshot()` helper. Ensure every durable mutation routes through it: session create/close/reorder/rename/CWD update, workspace reassignment/removal effects, visible grid open/hide/place/move/resize, maximize/restore, selection, sidebar visibility, stable agent identity, and restore failure. Use property observers or a centralized mutation helper so direct `selectedSessionID` updates from SwiftUI are also captured. Debouncing absorbs divider drag updates.

- [ ] Preserve existing UserDefaults persistence for `[WorkspaceFolder]`; the JSON snapshot references folders by UUID but does not replace the folder store.

- [ ] Make `flushSnapshot()` call the injected store synchronously with `makeSnapshot()`. With no injected store it remains a no-op.

- [ ] Run `swift test --filter WorkspaceStoreTests`. Expected: all old and new store tests pass.

- [ ] Commit:

  ```bash
  git add Sources/mTerm/Store/WorkspaceStore.swift Tests/mTermTests/WorkspaceStoreTests.swift
  git commit -m "feat: restore durable workspace state" -m "Co-authored-by: Codex <codex@openai.com>"
  ```

## Task 4: Implement safe resume commands and the per-pane restore state machine

**Files:**

- Create: `Sources/mTerm/Store/TerminalSessionRestoration.swift`
- Create: `Tests/mTermTests/TerminalSessionRestorationTests.swift`
- Modify: `Sources/mTerm/Store/WorkspaceStore.swift`
- Modify: `Tests/mTermTests/WorkspaceStoreTests.swift`

**Interfaces produced:**

```swift
enum AgentRestorationPhase: Equatable {
    case pending
    case launched
    case acknowledged
    case failed
}

enum TerminalSessionRestoration {
    static func command(for descriptor: AgentResumeDescriptor) -> String?
}

// WorkspaceStore
func reportRestorationLaunched(_ id: SessionRecord.ID)
func reportClaudeSessionIdentity(_ id: SessionRecord.ID, sessionID: UUID)
func restorationIntent(for id: SessionRecord.ID) -> AgentResumeDescriptor?
```

- [ ] Write command-builder tests for exact UUID commands and a Codex name containing whitespace, quotes, dollar signs, backticks, semicolons, newlines, and control characters. Expected safe results include:

  ```swift
  XCTAssertEqual(
      TerminalSessionRestoration.command(for: .claude(sessionID: id)),
      "claude --resume '\(id.uuidString.lowercased())'")
  XCTAssertEqual(
      TerminalSessionRestoration.command(for: .codex(locator: .name("Client's API"))),
      "codex resume 'Client'\"'\"'s API'")
  XCTAssertNil(TerminalSessionRestoration.command(for: .codex(locator: .name("bad\nname"))))
  ```

- [ ] Write `WorkspaceStoreTests` for `pending → launched → acknowledged`, changed-but-valid identities replacing the expected locator, first shell idle while pending preserving the locator, launched agent returning to idle without identity transitioning to failed and clearing the persisted descriptor, normal acknowledged agent exit clearing it, and `close` removing all restore state.

- [ ] Run `swift test --filter 'TerminalSessionRestorationTests|WorkspaceStoreTests'`. Expected: compilation/test failure because command builder and lifecycle methods do not exist.

- [ ] Implement shell quoting as single-quoted POSIX text with embedded `'` encoded as `'"'"'`; reject empty names and all control/newline characters. UUIDs are emitted lowercase. Keep executable/subcommand tokens hard-coded rather than persisting arbitrary commands.

- [ ] In `WorkspaceStore`, add a private runtime `AgentRestorationPhase` dictionary alongside the stable descriptor dictionary from Task 3. Restored descriptors begin `.pending`; newly observed live identities are `.acknowledged`. Update `setForeground` with these exact rules:

  - first `nil` while `.pending` preserves identity;
  - `reportRestorationLaunched` changes `.pending` to `.launched` immediately before command injection;
  - foreground matching the descriptor's agent keeps `.launched` while awaiting identity;
  - `reportClaudeSessionIdentity` or the Codex identity path accepts a valid new identity and marks `.acknowledged`;
  - `nil` while `.launched` marks `.failed` and removes the descriptor;
  - `nil` after `.acknowledged` is a normal agent exit and removes the descriptor;
  - unrelated foreground commands clear a live acknowledged descriptor, but cannot erase a not-yet-injected `.pending` restore.

- [ ] Project `activeAgent` into snapshots only from the stable descriptor dictionary. Never infer it merely from transient `claudeSessionIDs`/`codexSessionIDs`.

- [ ] Run `swift test --filter 'TerminalSessionRestorationTests|WorkspaceStoreTests'`. Expected: all command and lifecycle tests pass.

- [ ] Commit:

  ```bash
  git add Sources/mTerm/Store/TerminalSessionRestoration.swift Sources/mTerm/Store/WorkspaceStore.swift Tests/mTermTests/TerminalSessionRestorationTests.swift Tests/mTermTests/WorkspaceStoreTests.swift
  git commit -m "feat: model exact agent restoration" -m "Co-authored-by: Codex <codex@openai.com>"
  ```

## Task 5: Capture Claude Code session IDs through the official SessionStart hook

**Files:**

- Modify: `Sources/mTerm/Store/ClaudeIntegration.swift`
- Modify: `Tests/mTermTests/ClaudeIntegrationTests.swift`

**Interfaces consumed:** `WorkspaceStore.reportClaudeSessionIdentity` in the later view wiring task.

**Interfaces produced:**

```swift
static func sessionID(
    from payload: ArraySlice<UInt8>,
    foregroundCommand: String?
) -> UUID?
```

- [ ] Add parser tests accepting only `session;mTerm Claude;<uuid>` while foreground is exactly `claude`. Reject a wrong marker, non-UUID, extra fields, control bytes, and the same valid payload while foreground is `nil`/`codex`.

- [ ] Extend generated-plugin tests to require a `SessionStart` entry whose command passes `session_started`. Execute the generated script with `{"session_id":"<uuid>"}` and assert the decoded `terminalSequence` is exactly `ESC ]777;session;mTerm Claude;<uuid> BEL`. Execute malformed/missing `session_id` input and assert no spoofable sequence is emitted.

- [ ] Run `swift test --filter ClaudeIntegrationTests`. Expected: new parser and generated hook tests fail.

- [ ] Add `SessionStart` to `hooksConfiguration`. Change `notify.sh` to capture stdin once, use `/usr/bin/plutil -extract session_id raw -o - -` only in the `session_started` branch, and print the private OSC JSON only when a non-empty candidate exists. Continue consuming stdin for every existing branch and preserve all notification/turn-state behavior.

- [ ] Implement strict Swift-side parsing and UUID validation; this is the trust boundary even if the shell script's prefilter is permissive.

- [ ] Run `swift test --filter ClaudeIntegrationTests`. Expected: existing notifications, turn lifecycle, shim tests, and new identity tests all pass.

- [ ] Commit:

  ```bash
  git add Sources/mTerm/Store/ClaudeIntegration.swift Tests/mTermTests/ClaudeIntegrationTests.swift
  git commit -m "feat: capture Claude session identities" -m "Co-authored-by: Codex <codex@openai.com>"
  ```

## Task 6: Preserve exact Codex locators and resolve unique names through metadata

**Files:**

- Modify: `Sources/mTerm/Store/CodexThreadTitleResolver.swift`
- Modify: `Sources/mTerm/Store/WorkspaceStore.swift`
- Modify: `Tests/mTermTests/CodexThreadTitleResolverTests.swift`
- Modify: `Tests/mTermTests/WorkspaceStoreTests.swift`

**Interfaces produced:**

```swift
// CodexThreadTitleResolver
static func threadID(forExactName name: String,
                     workingDirectory: String,
                     codexHome: URL = defaultCodexHome) async -> UUID?
static func readThreadID(forExactName name: String,
                         workingDirectory: String,
                         codexHome: URL,
                         sqliteExecutable: URL = URL(fileURLWithPath: "/usr/bin/sqlite3")) -> UUID?

// WorkspaceStore initializer dependency
typealias CodexThreadIDLookup = @Sendable (String, String) async -> UUID?
```

- [ ] Create SQLite fixtures with `threads(id, title, name, cwd)`. Test that an exact name plus standardized CWD returns its UUID only when exactly one row matches; duplicate matches, different CWD, blank name, malformed UUID, absent database, and a schema without `cwd` all return `nil` without crashing. Keep existing title lookup tests passing.

- [ ] Add store tests proving: UUID terminal title persists `.codex(.threadID(id))` immediately; async title resolution/manual rename cancellation cannot erase that UUID; a normalized named title persists `.name(name)` before lookup; a unique metadata result upgrades it to `.threadID`; ambiguous lookup retains the exact name; a later UUID/title after `/resume` replaces the old locator; titles outside a foreground Codex process never create locators.

- [ ] Run `swift test --filter 'CodexThreadTitleResolverTests|WorkspaceStoreTests'`. Expected: new APIs and lifecycle behavior fail.

- [ ] Refactor `codexThreadIDs` into transient title-lookup state that is separate from the stable descriptor dictionary. `cancelCodexTitleResolution` may cancel tasks and transient display metadata only; it must never remove a stable resume locator.

- [ ] On a bare UUID OSC title, store the UUID descriptor synchronously before starting the existing automatic-title lookup. On a normalized non-UUID Codex title, store the exact-name fallback and launch the injected name+CWD lookup; upgrade only if the session remains foreground Codex and still owns that same name locator when the async result returns.

- [ ] Implement SQLite lookup without interpolating the arbitrary name/CWD into SQL. Read metadata rows with sqlite's JSON output, decode them in Swift, standardize paths, filter exact values, validate UUIDs, and return only a unique match. Do not open rollout/transcript files.

- [ ] Run `swift test --filter 'CodexThreadTitleResolverTests|WorkspaceStoreTests'`. Expected: all resolver and locator tests pass.

- [ ] Commit:

  ```bash
  git add Sources/mTerm/Store/CodexThreadTitleResolver.swift Sources/mTerm/Store/WorkspaceStore.swift Tests/mTermTests/CodexThreadTitleResolverTests.swift Tests/mTermTests/WorkspaceStoreTests.swift
  git commit -m "feat: preserve exact Codex resume locators" -m "Co-authored-by: Codex <codex@openai.com>"
  ```

## Task 7: Inject the restore command once after the interactive shell becomes idle

**Files:**

- Modify: `Sources/mTerm/Views/TerminalHostView.swift`
- Modify: `Sources/mTerm/Views/WorkspaceView.swift`
- Create: `Tests/mTermTests/TerminalRestoreCoordinatorTests.swift`

**Interfaces consumed:** `TerminalSessionRestoration.command`, `WorkspaceStore.restorationIntent`, identity/lifecycle reporting methods.

**TerminalHostView additions:**

```swift
let restorationIntent: AgentResumeDescriptor?
var onRestorationLaunched: () -> Void = {}
var onClaudeSessionIdentity: (UUID) -> Void = { _ in }

final class RestoreCommandCoordinator {
    init(intent: AgentResumeDescriptor?)
    func takeCommandOnFirstShellIdle() -> [UInt8]?
}
```

- [ ] Write pure coordinator tests. Verify no intent emits nothing; valid intent emits UTF-8 bytes for the safe command plus carriage return once; every later idle emits nothing; invalid/control-character name emits nothing and is consumed rather than retried; creating a new coordinator for a new terminal view starts a fresh one-shot lifetime.

- [ ] Run `swift test --filter TerminalRestoreCoordinatorTests`. Expected: compilation fails because the coordinator does not exist.

- [ ] Add a restore coordinator owned by `TerminalHostView.Coordinator`, initialized in `makeNSView` and never reset by `updateNSView`. Keep shell launch arguments unconditionally `[-l]`, ignoring restored `SessionRecord.command`. Validate the CWD again immediately before `startProcess`, falling back to `FileManager.default.homeDirectoryForCurrentUser.path` if it disappeared after snapshot load.

- [ ] In the OSC 633 `.idle` handler, preserve ordering: first dispatch `onForeground(nil)` so a `.pending` locator survives the initial prompt; then ask the coordinator for its one-shot command; call `onRestorationLaunched`; send command bytes and `0x0D` to the PTY. Never append the command to a prompt string and never use `--last`/`--continue`.

- [ ] In the OSC 777 handler, call `ClaudeIntegration.sessionID(from:foregroundCommand:)` before attention/state parsing and forward a valid identity. Keep notification payload handling unchanged. Codex continues through terminal titles.

- [ ] Wire `TerminalPane` with `workspace.restorationIntent(for:)`, `reportRestorationLaunched`, and `reportClaudeSessionIdentity`. Because `WorkspaceView` already constructs a terminal pane for every `workspace.sessions` entry and parks hidden sessions off-screen, do not filter construction to `displayedSessions`.

- [ ] Run `swift test --filter 'TerminalRestoreCoordinatorTests|ClaudeIntegrationTests|WorkspaceStoreTests'`. Expected: all restore handoff tests pass.

- [ ] Run `swift build`. Expected: the SwiftTerm callback/send APIs compile in the production target.

- [ ] Commit:

  ```bash
  git add Sources/mTerm/Views/TerminalHostView.swift Sources/mTerm/Views/WorkspaceView.swift Tests/mTermTests/TerminalRestoreCoordinatorTests.swift
  git commit -m "feat: resume agents from interactive shells" -m "Co-authored-by: Codex <codex@openai.com>"
  ```

## Task 8: Separate main-window close from full application quit

**Files:**

- Modify: `Sources/mTerm/mTermApp.swift`
- Create: `Tests/mTermTests/ApplicationWindowLifecycleTests.swift`

**Interfaces produced:**

```swift
enum ApplicationWindowLifecycle {
    static func shouldHide(candidate: NSWindow, mainWindow: NSWindow?) -> Bool
}

@MainActor
final class MTermAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool
}
```

- [ ] Write the pure identity-policy tests first: only the exact main-window object is intercepted; settings/other windows are allowed to close; a missing main window is not intercepted.

- [ ] Run `swift test --filter ApplicationWindowLifecycleTests`. Expected: compilation fails because the lifecycle policy does not exist.

- [ ] Construct production workspace as `WorkspaceStore(snapshotStore: WorkspaceSnapshotStore())`. Set `window.delegate = self`, `window.isReleasedWhenClosed = false`, and a stable frame autosave name such as `mTerm.mainWindow`. Restore the autosaved frame when present; center only when no frame was restored.

- [ ] Implement `windowShouldClose`: for the main window call `NSApp.hide(nil)` and return `false`; for any other window return `true`. Change `applicationShouldTerminateAfterLastWindowClosed` to `false`. Implement reopen by unhiding/activating and calling `makeKeyAndOrderFront` on the existing window; never rebuild the root view/store.

- [ ] At the first line of `applicationShouldTerminate`, call `workspace.flushSnapshot()` while sessions and agent locators are intact. Then retain the exact cleanup ordering for local monitors, `terminalProcesses.terminateAll(force: true)`, both content views, and `.terminateNow`. Do not close sessions through `WorkspaceStore` during quit.

- [ ] Run `swift test --filter 'ApplicationWindowLifecycleTests|ApplicationKeyboardShortcutTests|TerminalProcessRegistryTests'`. Expected: lifecycle policy, shortcuts, and process cleanup tests pass.

- [ ] Run `swift build`. Expected: AppKit delegate signatures and frame restoration compile.

- [ ] Perform a manual development-build check:

  1. Launch mTerm and run one long-lived shell command.
  2. Click main-window `X`; verify mTerm hides, the PID remains registered/running, and Dock reopen returns the exact same output/scrollback.
  3. Open Settings and close it; verify only Settings closes.
  4. Press `⌘Q`; verify the app exits and registered shell/process-group children are gone.

- [ ] Commit:

  ```bash
  git add Sources/mTerm/mTermApp.swift Tests/mTermTests/ApplicationWindowLifecycleTests.swift
  git commit -m "feat: preserve terminals when main window closes" -m "Co-authored-by: Codex <codex@openai.com>"
  ```

## Task 9: Synchronize architecture docs and run end-to-end verification

**Files:**

- Modify: `CLAUDE.md`
- Modify if test findings require it: files changed in Tasks 1-8

- [ ] Update `CLAUDE.md` core lifecycle notes with: main-window `X` hides without teardown; `⌘Q` flushes `workspace-v1.json` then force-cleans terminal Unix sessions; snapshot/runtime state split; exact Claude/Codex locator sources; interactive-shell one-shot restore ordering; and the explicit non-goals (no PTY/SSH/npm/editor/scrollback continuity across quit).

- [ ] Search for unfinished implementation markers and forbidden restore shortcuts:

  ```bash
  rg -n 'TODO|TBD|FIXME|claude --continue|claude --resume --last|codex resume --last|\["-lc"' Sources Tests CLAUDE.md docs/superpowers
  ```

  Expected: no new placeholders, no `--last`/`--continue`, and no restored-terminal `-lc` path. Pre-existing unrelated markers, if any, are inspected and documented rather than changed gratuitously.

- [ ] Run focused integration tests:

  ```bash
  swift test --filter 'WorkspaceSnapshot|WorkspaceStore|TerminalSessionRestoration|TerminalRestoreCoordinator|ClaudeIntegration|CodexThreadTitleResolver|ApplicationWindowLifecycle|TerminalProcessRegistry'
  ```

  Expected: all focused tests pass.

- [ ] Run the full required verification:

  ```bash
  swift test
  swift build
  ```

  Expected: zero failures and a successful debug build. Treat SourceKit diagnostics as advisory and resolve only command-line failures.

- [ ] Manually verify exact agent restoration with disposable conversations:

  1. Open at least three sessions: plain shell, Claude Code, and Codex; include one hidden session and a two-pane/maximized layout.
  2. Capture the Claude session UUID and Codex thread UUID/name shown by their official integrations.
  3. Press `⌘Q` while both agents are foreground; confirm shell/Node/agent child processes are cleaned.
  4. Relaunch; verify order, grouping, stable titles, CWDs, grid/maximize/sidebar/focus and window frame restore.
  5. Verify each agent pane injects exactly one command with its own locator, resumes the intended conversation, and notification/title/working indicators react normally.
  6. Exit one agent to the shell, quit/relaunch again, and verify that pane stays a shell rather than retrying the old agent.
  7. Temporarily make one locator invalid, verify CLI failure returns to shell, quit/relaunch, and verify no retry loop.

- [ ] Review `git diff HEAD~8..HEAD` (or the actual feature commit range) against every success criterion and out-of-scope item in the spec. Confirm no unrelated user changes were modified.

- [ ] Commit documentation and any verification-only corrections:

  ```bash
  git add CLAUDE.md
  git commit -m "docs: document workspace restoration lifecycle" -m "Co-authored-by: Codex <codex@openai.com>"
  ```

- [ ] Record final evidence for handoff: focused test result, full `swift test`, `swift build`, manual X/⌘Q result, exact Claude resume result, exact Codex resume result, and `git status --short`.
