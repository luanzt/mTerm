# Pane Find / Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-pane find bar (⌘F) that searches a terminal pane, shows the total match count, and steps through matches with Enter / Shift+Enter.

**Architecture:** The pinned SwiftTerm fork already exposes public search methods on `TerminalView` (`findNext`, `findPrevious`, `searchMatchSummary`, `clearSearch`). mTerm builds its own Emerald-themed find bar overlay on top of those — no fork change. A small per-session `TerminalSearchController` bridges the SwiftUI bar to the pane's `LocalProcessTerminalView`; `WorkspaceStore.findSessionID` tracks which pane shows the bar.

**Tech Stack:** Swift 5.10, SwiftUI + AppKit (`NSViewRepresentable`), SwiftTerm fork, XCTest.

## Global Constraints

- Platform: macOS 14 (`.macOS(.v14)`), SwiftPM executable target `mTerm`.
- Do **not** modify the SwiftTerm fork; use only its public `TerminalView` search API.
- All new UI reads colors from `MTermTheme` — no system colors.
- Pane frames must never animate (SIGWINCH storms); the find bar is an overlay and must not change the terminal's frame.
- Search options: case-insensitive substring only (`SearchOptions(caseSensitive: false)`). No regex/whole-word/case toggles.
- Navigation is Enter (next) / Shift+Enter (previous) / Esc (close). No ⌘G.
- Build check: `swift build`. Test check: `swift test --filter <name>`.
- Commit directly to `main` (project convention). End commit messages with the `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` trailer.

---

### Task 1: WorkspaceStore find state

**Files:**
- Modify: `Sources/mTerm/Store/WorkspaceStore.swift` (add published property + methods; clear in `close`/`hide`)
- Test: `Tests/mTermTests/WorkspaceStoreTests.swift`

**Interfaces:**
- Produces:
  - `WorkspaceStore.findSessionID: SessionRecord.ID?` (`@Published`)
  - `WorkspaceStore.showFind()` — sets `findSessionID = selectedSessionID` when a session is selected.
  - `WorkspaceStore.closeFind(_ id: SessionRecord.ID)` — clears `findSessionID` when it equals `id`.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/mTermTests/WorkspaceStoreTests.swift`:

```swift
func testShowFindTargetsSelectedSession() {
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    let store = WorkspaceStore(defaults: defaults)
    let selected = try? XCTUnwrap(store.selectedSessionID)

    store.showFind()

    XCTAssertEqual(store.findSessionID, selected)
}

func testCloseFindClearsOnlyMatchingSession() {
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    let store = WorkspaceStore(defaults: defaults)
    store.showFind()
    let target = try? XCTUnwrap(store.findSessionID)

    store.closeFind(SessionRecord.shell().id)   // some other id
    XCTAssertEqual(store.findSessionID, target)

    store.closeFind(target!)
    XCTAssertNil(store.findSessionID)
}

func testClosingFindTargetSessionClearsFindSessionID() {
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    let store = WorkspaceStore(defaults: defaults)
    let session = store.sessions[0]
    store.showFind()
    XCTAssertEqual(store.findSessionID, session.id)

    store.close(session)

    XCTAssertNil(store.findSessionID)
}

func testHidingFindTargetSessionClearsFindSessionID() {
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    let store = WorkspaceStore(defaults: defaults)
    let session = store.sessions[0]
    store.showFind()

    store.hide(session)

    XCTAssertNil(store.findSessionID)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter WorkspaceStoreTests/testShowFindTargetsSelectedSession`
Expected: FAIL — `value of type 'WorkspaceStore' has no member 'findSessionID'` / `showFind`.

- [ ] **Step 3: Add the published property**

In `Sources/mTerm/Store/WorkspaceStore.swift`, after the `hoveredSessionID` declaration (currently line 22):

```swift
    /// The pane whose find bar is currently shown, or nil when no find bar is
    /// open. Set by ⌘F (`showFind`), cleared by Esc/close (`closeFind`) and by
    /// closing/hiding the target pane.
    @Published var findSessionID: SessionRecord.ID?
```

- [ ] **Step 4: Add showFind / closeFind**

In the same file, immediately after the `hide(_:)` method (currently ends line 269):

```swift
    /// Opens the find bar on the focused pane. A no-op when nothing is selected.
    func showFind() {
        guard let selectedSessionID else { return }
        findSessionID = selectedSessionID
    }

    /// Closes the find bar for `id` (ignored if a different pane owns it).
    func closeFind(_ id: SessionRecord.ID) {
        if findSessionID == id { findSessionID = nil }
    }
```

- [ ] **Step 5: Clear findSessionID in close/hide**

In `close(_:)`, after `manuallyRenamedSessionIDs.remove(session.id)` (currently line 242), add:

```swift
        if findSessionID == session.id { findSessionID = nil }
```

In `hide(_:)`, before the closing brace (after the `selectedSessionID` reconciliation, currently line 268), add:

```swift
        if findSessionID == session.id { findSessionID = nil }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter WorkspaceStoreTests`
Expected: PASS (all, including the four new tests).

- [ ] **Step 7: Commit**

```bash
git add Sources/mTerm/Store/WorkspaceStore.swift Tests/mTermTests/WorkspaceStoreTests.swift
git commit -m "$(printf 'Track find-bar target pane in WorkspaceStore\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 2: Pure find helpers (counter + direction)

**Files:**
- Create: `Sources/mTerm/Views/TerminalFindBar.swift` (helpers only for now)
- Test: `Tests/mTermTests/TerminalFindTests.swift`

**Interfaces:**
- Produces:
  - `enum FindDirection: Equatable { case next, previous }` with
    `static func fromReturn(modifierFlags: NSEvent.ModifierFlags) -> FindDirection`.
  - `enum FindMatchCounter` with
    `static func text(term: String, index: Int, total: Int) -> String?`
    (nil when `term` empty; `"No results"` when `total == 0`; else `"index / total"`).

- [ ] **Step 1: Write the failing tests**

Create `Tests/mTermTests/TerminalFindTests.swift`:

```swift
import AppKit
import XCTest
@testable import mTerm

final class TerminalFindTests: XCTestCase {
    func testCounterHiddenForEmptyTerm() {
        XCTAssertNil(FindMatchCounter.text(term: "", index: 0, total: 0))
    }

    func testCounterShowsCurrentOverTotal() {
        XCTAssertEqual(FindMatchCounter.text(term: "foo", index: 2, total: 14), "2 / 14")
    }

    func testCounterShowsNoResultsWhenTotalZero() {
        XCTAssertEqual(FindMatchCounter.text(term: "foo", index: 0, total: 0), "No results")
    }

    func testPlainReturnSearchesForward() {
        XCTAssertEqual(FindDirection.fromReturn(modifierFlags: []), .next)
    }

    func testShiftReturnSearchesBackward() {
        XCTAssertEqual(FindDirection.fromReturn(modifierFlags: .shift), .previous)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TerminalFindTests`
Expected: FAIL — `cannot find 'FindMatchCounter' / 'FindDirection' in scope`.

- [ ] **Step 3: Create the helpers file**

Create `Sources/mTerm/Views/TerminalFindBar.swift`:

```swift
import AppKit
import SwiftTerm
import SwiftUI

/// Direction of a find step. A plain Return searches forward; Shift+Return
/// searches backward.
enum FindDirection: Equatable {
    case next
    case previous

    static func fromReturn(modifierFlags: NSEvent.ModifierFlags) -> FindDirection {
        modifierFlags.contains(.shift) ? .previous : .next
    }
}

/// Formats the match counter shown beside the find field.
enum FindMatchCounter {
    /// `nil` hides the label (empty term). `"No results"` when nothing matched.
    /// Otherwise `"index / total"`, where `index` is the 1-based current match.
    static func text(term: String, index: Int, total: Int) -> String? {
        guard !term.isEmpty else { return nil }
        guard total > 0 else { return "No results" }
        return "\(index) / \(total)"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TerminalFindTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/mTerm/Views/TerminalFindBar.swift Tests/mTermTests/TerminalFindTests.swift
git commit -m "$(printf 'Add pure find-bar helpers (counter text, key direction)\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 3: Search controller + themed find bar view

**Files:**
- Modify: `Sources/mTerm/Views/TerminalFindBar.swift` (append controller + views)

**Interfaces:**
- Consumes: `FindDirection`, `FindMatchCounter` (Task 2); `MTermTheme` (existing).
- Produces:
  - `@MainActor final class TerminalSearchController: ObservableObject` with
    `weak var terminalView: LocalProcessTerminalView?`,
    `func find(_ term: String, direction: FindDirection) -> (index: Int, total: Int)`,
    `func clear()`.
  - `struct TerminalFindBar: View` with initializer
    `TerminalFindBar(controller: TerminalSearchController, onClose: @escaping () -> Void)`.

- [ ] **Step 1: Append the controller and views**

Append to `Sources/mTerm/Views/TerminalFindBar.swift`:

```swift
/// Bridges the SwiftUI find bar to one pane's SwiftTerm view. Holds a weak
/// reference so mTerm never retains the terminal view.
@MainActor
final class TerminalSearchController: ObservableObject {
    weak var terminalView: LocalProcessTerminalView?

    private let options = SearchOptions(caseSensitive: false)

    /// Runs a search step, then returns the current match position and total.
    func find(_ term: String, direction: FindDirection) -> (index: Int, total: Int) {
        guard let terminalView, !term.isEmpty else { return (0, 0) }
        switch direction {
        case .next:
            _ = terminalView.findNext(term, options: options)
        case .previous:
            _ = terminalView.findPrevious(term, options: options)
        }
        return terminalView.searchMatchSummary(term, options: options)
    }

    /// Removes the current search selection/highlight.
    func clear() {
        terminalView?.clearSearch()
    }
}

/// An Emerald-themed find bar overlaid on the top-right of a focused pane.
/// Enter → next match, Shift+Enter → previous, Esc/✕ → close.
struct TerminalFindBar: View {
    let controller: TerminalSearchController
    let onClose: () -> Void

    @State private var term = ""
    @State private var summary: (index: Int, total: Int) = (0, 0)
    @State private var focusToken = 0

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MTermTheme.dim2)
            FindSearchField(
                text: $term,
                focusToken: focusToken,
                onChange: { runSearch(direction: .next) },
                onNavigate: { runSearch(direction: $0) },
                onClose: onClose)
                .frame(width: 150, height: 20)
            if let counter = FindMatchCounter.text(
                term: term, index: summary.index, total: summary.total) {
                Text(counter)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(summary.total == 0 ? MTermTheme.dim2 : MTermTheme.dim)
                    .fixedSize()
            }
            findButton(icon: "chevron.up", help: "Previous match (⇧⏎)") {
                runSearch(direction: .previous)
            }
            findButton(icon: "chevron.down", help: "Next match (⏎)") {
                runSearch(direction: .next)
            }
            findButton(icon: "xmark", help: "Close (esc)", action: onClose)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(MTermTheme.control)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(MTermTheme.controlBorder, lineWidth: 1)))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .onAppear { focusToken += 1 }
    }

    private func runSearch(direction: FindDirection) {
        guard !term.isEmpty else {
            controller.clear()
            summary = (0, 0)
            return
        }
        summary = controller.find(term, direction: direction)
    }

    private func findButton(
        icon: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MTermTheme.dim)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A borderless, transparent text field whose coordinator maps Return →
/// next/previous and Esc → close, mirroring SwiftTerm's own find field. The
/// surrounding SwiftUI view draws the themed pill; this field is transparent.
private struct FindSearchField: NSViewRepresentable {
    @Binding var text: String
    var focusToken: Int
    var onChange: () -> Void
    var onNavigate: (FindDirection) -> Void
    var onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.textColor = NSColor(MTermTheme.text)
        field.placeholderString = "Find"
        field.delegate = context.coordinator
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.appliedFocusToken != focusToken {
            context.coordinator.appliedFocusToken = focusToken
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
                field.currentEditor()?.selectedRange =
                    NSRange(location: field.stringValue.count, length: 0)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FindSearchField
        var appliedFocusToken = 0

        init(_ parent: FindSearchField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
            parent.onChange()
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                parent.onNavigate(FindDirection.fromReturn(modifierFlags: flags))
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onClose()
                return true
            default:
                return false
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: build succeeds. (Editor diagnostics may be stale — trust `swift build`.)

- [ ] **Step 3: Commit**

```bash
git add Sources/mTerm/Views/TerminalFindBar.swift
git commit -m "$(printf 'Add themed terminal find bar and search controller\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 4: Wire the find bar into the pane

**Files:**
- Modify: `Sources/mTerm/Views/TerminalHostView.swift` (new params + focus guard + controller wiring)
- Modify: `Sources/mTerm/Views/WorkspaceView.swift` (`TerminalPane`: `@StateObject` controller, pass-through, overlay)

**Interfaces:**
- Consumes: `TerminalSearchController`, `TerminalFindBar` (Task 3); `WorkspaceStore.findSessionID`, `closeFind` (Task 1).

- [ ] **Step 1: Add params to TerminalHostView**

In `Sources/mTerm/Views/TerminalHostView.swift`, add stored properties after `let isFocused: Bool` (line 8):

```swift
    let searchController: TerminalSearchController
    let isFindBarOpen: Bool
```

- [ ] **Step 2: Wire the terminal reference**

In `makeNSView`, right after `context.coordinator.terminal = terminal` (line 70), add:

```swift
        searchController.terminalView = terminal
```

- [ ] **Step 3: Guard focus while the find bar is open**

In `updateNSView`, replace the focus block (currently lines 276-278):

```swift
        if isFocused, isVisible, let window = nsView.window, window.firstResponder !== nsView {
            window.makeFirstResponder(nsView)
        }
```

with:

```swift
        // While the find bar owns keyboard focus, do not yank first responder
        // back to the terminal; the normal re-render restores it on close.
        if isFocused, isVisible, !isFindBarOpen,
           let window = nsView.window, window.firstResponder !== nsView {
            window.makeFirstResponder(nsView)
        }
```

- [ ] **Step 4: Add the controller and pass-through in TerminalPane**

In `Sources/mTerm/Views/WorkspaceView.swift`, in `struct TerminalPane`, add a stored object after its `@State private var dropZone: DropZone?` (line 973):

```swift
    @StateObject private var searchController = TerminalSearchController()
```

Then in the `TerminalHostView(...)` call, add the two new arguments immediately after `isFocused: session.id == workspace.selectedSessionID,` (line 985):

```swift
                                 searchController: searchController,
                                 isFindBarOpen: workspace.findSessionID == session.id,
```

- [ ] **Step 5: Overlay the find bar on the terminal**

In the same `TerminalPane` body, the terminal is rendered as
`TerminalHostView(...).onTapGesture { ... }.padding(10)` (padding at line 1020).
Attach an overlay right after that `.padding(10)`:

```swift
                    .padding(10)
                    .overlay(alignment: .topTrailing) {
                        if workspace.findSessionID == session.id {
                            TerminalFindBar(controller: searchController) {
                                searchController.clear()
                                workspace.closeFind(session.id)
                            }
                            .padding(.top, 8)
                            .padding(.trailing, 14)
                        }
                    }
```

- [ ] **Step 6: Build to verify it compiles**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 7: Commit**

```bash
git add Sources/mTerm/Views/TerminalHostView.swift Sources/mTerm/Views/WorkspaceView.swift
git commit -m "$(printf 'Mount find bar overlay on the focused pane\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 5: ⌘F menu command

**Files:**
- Modify: `Sources/mTerm/mTermApp.swift` (Edit menu item + app-delegate action)

**Interfaces:**
- Consumes: `WorkspaceStore.showFind()` (Task 1).

- [ ] **Step 1: Add the app-delegate action**

In `Sources/mTerm/mTermApp.swift`, after `@objc private func toggleSidebar(_ sender: Any?)` (ends line 103):

```swift
    @objc private func showFindBar(_ sender: Any?) {
        workspace.showFind()
    }
```

- [ ] **Step 2: Add the Edit ▸ Find… menu item**

In `installMainMenu`, in the Edit menu block (currently lines 250-253), after the Paste item and before `addSubmenu(editMenu, to: mainMenu)`:

```swift
        editMenu.addItem(.separator())
        let findItem = NSMenuItem(
            title: "Find…",
            action: #selector(showFindBar(_:)),
            keyEquivalent: "f")
        findItem.keyEquivalentModifierMask = .command
        findItem.target = self
        editMenu.addItem(findItem)
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 4: Manual verification (run the app)**

Run: `swift run mTerm`
Then verify by hand:
1. Type some output (e.g. `ls -la`, or `seq 100`). Press **⌘F** — the themed find bar appears top-right of the focused pane and the field has focus.
2. Type a term that appears several times — the counter shows `1 / N` and the first match is selected/scrolled into view.
3. Press **Enter** → advances to `2 / N`; **Shift+Enter** → back to `1 / N`. The ▲/▼ buttons do the same.
4. Type a term with no matches → **"No results"**.
5. Press **Esc** (or ✕) → the bar closes, the highlight clears, and typing goes to the terminal again.
6. Open the bar, then close that pane from its sidebar row → no dangling bar; no crash.

- [ ] **Step 5: Commit**

```bash
git add Sources/mTerm/mTermApp.swift
git commit -m "$(printf 'Add Edit > Find (Cmd-F) to open the pane find bar\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Self-Review

**Spec coverage:**
- ⌘F opens on focused pane → Task 1 (`showFind`) + Task 5 (menu) + Task 4 (overlay). ✓
- Case-insensitive substring search → Task 3 (`SearchOptions(caseSensitive: false)`). ✓
- Match counter `index / total` / "No results" / hidden → Task 2 + Task 3. ✓
- Enter/Shift+Enter/Esc → Task 2 (`fromReturn`) + Task 3 (`FindSearchField`). ✓
- Per-pane state → Task 1 (`findSessionID`) + Task 4 (`@StateObject` per `TerminalPane`). ✓
- Focus guard so the field keeps focus → Task 4 (`isFindBarOpen`). ✓
- Cleanup on close/hide → Task 1. ✓

**Placeholder scan:** No TBD/TODO; every code step is concrete. ✓

**Type consistency:** `FindDirection`/`FindMatchCounter` (Task 2) are used verbatim in Task 3. `TerminalSearchController.find(_:direction:) -> (index:total:)` and `TerminalFindBar(controller:onClose:)` (Task 3) match Task 4's call sites. `findSessionID`/`showFind()`/`closeFind(_:)` (Task 1) match Tasks 4–5. ✓
