# Thiết kế: Khôi phục workspace và agent session

**Ngày:** 2026-08-14
**Trạng thái:** Đã duyệt trong chat

## Mục tiêu

mTerm có hai hành vi đóng ứng dụng khác nhau:

- Bấm nút đóng cửa sổ (`X`) chỉ đưa mTerm xuống nền. Cửa sổ, các
  `TerminalHostView`, PTY và toàn bộ process đang chạy vẫn sống nguyên trạng.
- `⌘Q` thoát hẳn mTerm, ghi snapshot workspace rồi giữ nguyên cơ chế dọn sạch
  mọi process thuộc các terminal session để giải phóng RAM.

Khi người dùng mở mTerm sau `⌘Q`, app dựng lại danh sách session, layout pane và
thư mục làm việc. Pane nào đang chạy Claude Code hoặc Codex tại thời điểm quit
thì tự động resume đúng conversation/thread bằng ID đã lưu. Pane shell thường
khởi động một login shell mới tại thư mục cuối cùng.

## Tiêu chí thành công

- Đóng `X` rồi mở lại từ Dock trả về đúng các process đang chạy mà không spawn,
  kill hay resume process nào.
- `⌘Q` không để lại shell, Node, Claude, Codex hay process con thuộc Unix
  terminal session do mTerm quản lý.
- Sau relaunch, mTerm khôi phục đúng thứ tự session, workspace grouping, stable
  title, hidden/visible state, pane geometry, maximize state và focused pane.
- Mỗi agent pane resume bằng locator riêng của chính pane đó; không dùng
  `--last` hoặc `--continue`, vì các lựa chọn đó có thể trỏ nhiều pane vào cùng
  một conversation.
- Notification, agent icon, working indicator và transient agent title tiếp tục
  đi qua các integration/shim hiện có sau khi resume.
- Snapshot hỏng, CWD biến mất hoặc agent history không còn không làm app crash
  hay mắc vòng lặp restore.

## Ngoài phạm vi

- Không giữ process sống qua `⌘Q`; không dùng tmux, zellij hay helper daemon.
- Không phục hồi SSH connection, `npm run`, editor, shell environment hoặc
  terminal scrollback sau khi app đã quit.
- Không tiếp tục một Claude/Codex response đang stream từ đúng byte bị ngắt.
  Agent CLI chỉ resume conversation đến điểm nó đã ghi bền vững.
- Không thêm UI quản lý snapshot, nút "Restore previous workspace" hay setting
  bật/tắt restore trong phiên bản này.
- Không đọc hoặc parse Claude/Codex transcript để tìm nội dung hội thoại.

## Semantics vòng đời cửa sổ

### Đóng `X`

`MTermAppDelegate` trở thành `NSWindowDelegate`. Main window không được đóng
thật sự, vì teardown `NSHostingView` sẽ gọi `dismantleNSView` và dọn PTY. Thay
vào đó:

1. `windowShouldClose` nhận main window, gọi `NSApp.hide(nil)` và trả `false`;
   vì close bị hủy, content view và PTY không bị teardown.
2. `applicationShouldTerminateAfterLastWindowClosed` trả `false`.
3. `applicationShouldHandleReopen` gọi `NSApp.unhide(nil)`,
   `makeKeyAndOrderFront` cho cùng instance cửa sổ và trả `true`.

Settings window vẫn dùng lifecycle đóng/mở hiện tại. Không tạo lại
`WorkspaceView`, `WorkspaceStore` hoặc `TerminalHostView` khi main window được
hiện lại. Main window dùng AppKit frame autosave với một key ổn định để lần
launch sau giữ vị trí/kích thước; lần đầu chưa có frame đã lưu vẫn center như
hiện tại.

### Thoát bằng `⌘Q`

`applicationShouldTerminate` thực hiện theo thứ tự:

1. Flush snapshot đồng bộ, trong khi store vẫn còn đầy đủ session và agent
   locator.
2. Gỡ event monitors như hiện tại.
3. Gọi `TerminalProcessRegistry.terminateAll(force: true)` như hiện tại để dọn
   toàn bộ process thuộc các Unix terminal session đã đăng ký.
4. Gỡ content view để SwiftTerm đóng PTY descriptors/observers idempotently.
5. Trả `.terminateNow`.

Teardown khi quit không được gọi `WorkspaceStore.close` hoặc ghi snapshot rỗng
đè lên snapshot vừa flush. Process đã tự daemonize sang Unix session khác vẫn
nằm ngoài khả năng của registry hiện tại; tính năng này không thay đổi ranh giới
cleanup đó.

## Mô hình persistence

### File snapshot

Thêm `WorkspaceSnapshotStore` ghi atomically vào:

`~/Library/Application Support/mTerm/workspace-v1.json`

Dùng file JSON versioned thay vì key `edev.workspace.sessions` cũ để tách rõ
runtime state khỏi legacy state và cho phép validate/migrate schema. Danh sách
`WorkspaceFolder` tiếp tục dùng persistence hiện tại; snapshot tham chiếu
workspace bằng UUID.

Snapshot được schedule lại sau mọi durable mutation và debounce trong thời gian
ngắn để divider drag không ghi file ở mỗi pixel. `⌘Q` luôn gọi `flush()` đồng bộ,
không phụ thuộc debounce còn pending.

### Schema

```swift
struct WorkspaceSnapshot: Codable, Equatable {
    let schemaVersion: Int
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
```

`PaneGridSnapshot` dùng `Double` cho width/row fractions và UUID cho panes,
không decode thẳng runtime `PaneGrid`. Khi restore, một factory/repair path của
`PaneGrid`:

- bỏ pane ID không còn trong `sessions`;
- bỏ ID trùng, giữ occurrence đầu tiên;
- bỏ cột rỗng;
- giới hạn tối đa 3 cột và 2 pane/cột;
- clamp fractions về range hợp lệ;
- tạo single-pane grid từ selected/first session nếu kết quả rỗng.

`savedGrid` được validate bằng cùng logic. Nếu không còn tạo được multi-pane
layout hợp lệ thì bỏ maximize state.

### State không persist

Không persist PID, `SessionRecord.Status`, foreground sets, working spinner,
transient agent title, notification state, hover/drag, resize hoặc find bar.
Những state này được agent/shell integration tái tạo sau launch.

`activeAgent` chỉ có giá trị nếu Claude/Codex vẫn là foreground command tại lúc
snapshot được tạo. Khi user `/exit` agent và shell báo `idle`, snapshot tiếp theo
phải xóa `activeAgent`; relaunch sau đó chỉ mở shell, không tự bật agent lại.

## Thu thập agent identity

### Claude Code

Mở rộng local plugin hiện tại bằng `SessionStart` hook. Event này chạy cho
startup, resume, clear, compact và fork, đồng thời cung cấp `session_id` chính
thức. Hook:

1. Đọc JSON stdin và lấy duy nhất `session_id`.
2. Validate thành UUID; không đọc prompt, transcript path hoặc assistant output.
3. Trả allowlisted `terminalSequence` chứa private OSC payload:
   `OSC 777;session;mTerm Claude;<uuid>`.

`TerminalHostView` chỉ chấp nhận payload đúng marker, đúng UUID và khi foreground
command là `claude`, rồi chuyển identity về `WorkspaceStore`. `/clear`,
`/resume`, branch/fork trong cùng TUI sẽ cập nhật locator mới ngay khi
`SessionStart` kế tiếp chạy.

Generated plugin tiếp tục được inject bằng `--plugin-dir`; không sửa
`~/.claude/settings.json` hoặc project settings.

### Codex CLI

Giữ invocation-scoped `tui.terminal_title=["thread-title"]`. Với thread chưa
đặt tên, Codex phát UUID qua OSC 0/2; persist UUID ngay khi nhận được, trước khi
async title lookup chạy.

Stable resume locator phải tách khỏi `codexThreadIDs` dùng cho transient title
resolution. `/rename` có thể cancel title lookup nhưng không được xóa UUID đã
biết. Nếu một named thread không từng phát UUID trong pane, lưu validated exact
name làm fallback vì `codex resume` hỗ trợ UUID hoặc session name. Đồng thời mở
rộng metadata-only SQLite lookup hiện có: resolve exact name + current CWD sang
UUID nếu chỉ có một row hợp lệ; nếu lookup không duy nhất thì giữ name locator.
Không mở rollout JSONL.

Terminal-title update sau `/resume`, fork hoặc thread switch cập nhật locator
của pane tương ứng.

## Dựng lại terminal sau relaunch

### Khởi tạo store

`WorkspaceStore` load và validate snapshot trước khi `WorkspaceView` được tạo.
Nếu không có snapshot, schema version không hỗ trợ hoặc decode thất bại, app
fallback về hành vi hiện tại: một terminal shell mới. File lỗi không được ghi đè
cho đến durable mutation đầu tiên của workspace mới.

Mọi restored session vẫn render một persistent `TerminalPane`, kể cả session
đang hidden/off-screen, giữ nguyên invariant hiện có. Vì vậy các agent được đánh
dấu active sẽ resume cả khi pane chưa nằm trong visible grid.

### Chạy restore command

Không dùng `SessionRecord.command`/`zsh -lc` để auto-resume. Non-interactive shell
có thể bỏ qua generated `.zshrc`, làm mất PATH shim, foreground OSC và agent
notifications; nó cũng kết thúc pane khi agent exit.

Mỗi restored pane luôn khởi động interactive login shell giống terminal mới.
`TerminalHostView.Coordinator` giữ một typed, one-shot pending restore intent.
Sau shell integration phát marker `idle` đầu tiên, coordinator gửi một command
được shell-escape an toàn rồi nhấn Return:

```text
claude --resume <exact-uuid>
codex resume <exact-uuid-or-name>
```

Command chỉ được gửi một lần cho lifetime của terminal view. Không gắn prompt và
không dùng `--last`/`--continue`. Vì lệnh đi qua interactive zsh, Claude/Codex
shim hiện có vẫn thêm plugin/notification config như một launch bình thường.

Restore intent có runtime state machine riêng:

```text
pending → launched → acknowledged
                   ↘ failed
```

- `pending`: chờ first shell `idle`; event này chỉ trigger command, không xóa
  locator khỏi snapshot.
- `launched`: đã gửi command và đã thấy foreground `claude`/`codex`; chờ
  identity OSC/title.
- `acknowledged`: nhận identity hợp lệ; identity mới trở thành source of truth.
- `failed`: command quay lại shell `idle` trước khi có identity hợp lệ; xóa
  `activeAgent` để lần launch sau không retry.

Nếu snapshot đánh dấu agent active nhưng chưa từng thu được locator hợp lệ,
không dùng picker/`--last` làm phỏng đoán. Pane mở thành shell và snapshot mới
bỏ active-agent state.

Nếu `workingDirectory` không còn tồn tại, shell fallback về home directory. CLI
error/picker vẫn hiển thị trong pane; sau khi command trở lại shell, foreground
`idle` xóa `activeAgent` khỏi snapshot mới để lần launch sau không retry vô hạn.

Identity OSC/title trùng locator dự kiến xác nhận resume thành công. Identity mới
hợp lệ do CLI phát ra được coi là source of truth và thay locator cũ, bao phủ
trường hợp CLI fork hoặc name resolution.

## Luồng dữ liệu

### Close `X`

```text
X → windowShouldClose → NSApp.hide(existing app/window) → return false
  → WorkspaceStore + TerminalHostView + PTYs + processes tiếp tục sống
Dock reopen → applicationShouldHandleReopen → show cùng window instance
```

### `⌘Q` và relaunch

```text
⌘Q → snapshotStore.flush(current WorkspaceStore)
   → TerminalProcessRegistry.terminateAll(force: true)
   → dismantle terminal views → process exit

next launch → decode + repair WorkspaceSnapshot
            → render all restored TerminalPane instances
            → start interactive shells at saved CWDs
            → first shell idle marker
            → typed one-shot claude/codex resume command
            → existing OSC integrations rebuild runtime UI state
```

## Xử lý lỗi và an toàn

- Snapshot writes dùng atomic replacement để không để lại JSON nửa chừng khi
  app crash.
- Unsupported/corrupt snapshot fallback về một shell mới và log lỗi; app không
  crash.
- UUID validation và foreground-command checks bảo vệ private identity OSC.
- Codex name được normalize, giới hạn độ dài và shell-escape; snapshot không
  bao giờ chứa raw arbitrary launch command.
- Missing agent history để CLI tự báo lỗi trong terminal; pane vẫn trở về shell
  và dùng bình thường.
- Không persist hoặc log prompt, assistant output, transcript contents, auth
  token hay raw environment.
- Snapshot flush xảy ra trước process cleanup; teardown không được ghi state
  rỗng.

## Kiểm thử

### Unit tests

- Snapshot round-trip giữ session order, workspace IDs, stable/manual titles,
  CWD, hidden panes, fractions, selected pane, sidebar, session sequence và
  maximized/saved grid.
- Repair snapshot loại orphan/duplicate/overflow panes, clamp fraction và tạo
  fallback grid đúng invariant.
- Missing/corrupt/unsupported snapshot tạo một fresh shell.
- Agent foreground + known locator được persist; agent exit về shell xóa
  `activeAgent`; agent identity update thay đúng locator của đúng pane.
- Claude SessionStart hook phát đúng private OSC cho UUID hợp lệ và từ chối JSON
  thiếu/sai ID; parser yêu cầu foreground `claude`.
- Codex UUID vẫn còn sau manual title update; name fallback được normalize và
  exact UUID luôn được ưu tiên.
- Restore command builder shell-escape locator, không chấp nhận control
  characters và không tạo raw arbitrary command.
- One-shot restore intent chỉ fire sau first shell idle và không fire lần hai.
- First shell idle giữ locator ở state `pending`; idle sau launched-but-unacked
  chuyển state sang failed và xóa locator.
- Flush pending snapshot ghi ngay trong termination path.

### Integration/manual verification

- `swift test` và `swift build` pass.
- Mở nhiều pane gồm shell, Claude, Codex và Node; bấm `X`, xác nhận PID giữ
  nguyên và output tiếp tục; mở từ Dock xác nhận cùng terminal state.
- `⌘Q`, xác nhận process tree đã dọn; mở lại app, xác nhận layout khớp, plain
  shell là process mới, Claude/Codex vào đúng conversation riêng.
- Kiểm tra agent đã `/exit` trước `⌘Q` không tự resume.
- Xóa/move một CWD và xóa một agent history trước relaunch; app vẫn usable và
  không retry vô hạn.

## File dự kiến thay đổi

- `Sources/mTerm/Models/SessionRecord.swift` — typed agent restoration metadata
  hoặc projection cần thiết cho snapshot.
- `Sources/mTerm/Models/PaneGrid.swift` — snapshot conversion/validated repair.
- `Sources/mTerm/Store/WorkspaceSnapshotStore.swift` — schema, atomic
  persistence, debounce và flush.
- `Sources/mTerm/Store/WorkspaceStore.swift` — load/restore, dirty scheduling,
  agent locator lifecycle và snapshot projection.
- `Sources/mTerm/Store/ClaudeIntegration.swift` — SessionStart identity hook và
  OSC parser.
- `Sources/mTerm/Store/CodexThreadTitleResolver.swift` — stable UUID/name
  metadata resolution tách khỏi display-title task.
- `Sources/mTerm/Views/TerminalHostView.swift` — typed one-shot resume sau first
  shell idle.
- `Sources/mTerm/Views/WorkspaceView.swift` — truyền restore intent vào terminal
  host nếu cần.
- `Sources/mTerm/mTermApp.swift` — background close/reopen và flush-before-quit.
- AppKit window autosave — giữ frame của main window giữa các app launch.
- `Tests/mTermTests/` — snapshot, repair, agent identity và restoration tests.
- `CLAUDE.md` — đồng bộ core app, pane/session persistence và quit behavior.

## Quyết định kiến trúc

Chọn snapshot + exact agent resume thay vì tmux/helper daemon. Hướng này đáp ứng
trải nghiệm đã chốt: `X` giữ process thật, còn `⌘Q` giải phóng toàn bộ RAM và lần
mở sau chỉ dựng lại UI cùng conversation state. Nó giữ SwiftTerm là owner trực
tiếp của live PTY trong mỗi app run và không thay đổi dependency/packaging.
