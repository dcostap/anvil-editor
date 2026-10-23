# Project Sidebar redesign: shared contract for milestones 2 to 5

Read `PLAN.md` in this folder first. Use the terms in `CONTEXT.md`. A Pane Group is a set of Panes
shown together in splits. Tab order is the Pane Groups in order, then each group's Panes in layout order.

Four lanes work at the same time in the same working tree. Each lane owns its files. Do not edit files
that another lane owns. If you need a change in another lane's file, write it in your final report.

| Lane | Owner | Files |
|---|---|---|
| Shell | agent | `src/anvil_shell.c`, `src/surface_protocol.c/.h`, `src/hosted_surface.c/.h`, `src/api/system.c`, `tests/native/*` |
| Pane requests | agent | `data/core/pane_requests.lua` (new), `data/core/pane_report.lua`, `data/core/init.lua` (the `panerequest` handler only), `data/core/rootpanel.lua` (drop functions only), `tests/lua/ui/pane_requests.lua` (new), `tests/lua/ui/pane_report.lua` |
| Pane transfer | agent | `data/core/pane_transfer.lua` (new), `data/core/panes.lua`, `tests/lua/ui/pane_transfer.lua` (new), `tests/lua/ui/panes*.lua` when a `panes.lua` change needs it |
| Sidebar | lead | `data/core/sidebar_view.lua`, `data/core/sidebar_app.lua`, `data/core/sidebar_scene.lua`, Sidebar tests, colors |

The lead does all visual design. Agents add no drawing code.

## Working rules

- Do not commit. The lead reviews and commits. End with a report: changed files, tests run and their
  results, open questions, and changes that you need in other lanes.
- Another agent works in this repo on unrelated buffer performance. Leave changes that you did not make
  alone, such as `data/core/common.lua` and buffer files.
- Do not run `update-anvil-dev-build.bat`, `setup-anvil-dev.bat` or the daily app in `anvil-portable`.
  They restart the user's editor.
- Lua lanes run tests with `--no-rebuild`, because the shell lane rebuilds the shared build folder:

  ```sh
  PATH=/c/msys64/mingw64/bin:$PATH /c/msys64/mingw64/bin/meson.exe test -C build-windows-x86_64 anvil:lua-ui --no-rebuild --print-errorlogs --test-args ui/pane_requests.lua
  ```

  If a test cannot start because the shell lane links `anvil.exe` at that moment, run it again.
- Lua tests run outside a shell. Stub `system.pane_request` and other shell calls in tests.
- Check Lua syntax with `./build-windows-x86_64/subprojects/luajit/src/luajit.exe check-lua-syntax.lua <files>`.
- Follow `AGENTS.md`: the test quality bar, red-green for new behavior, and `core.log_quiet` for
  decisions and failures.
- Keep code minimal. Reuse `panes.lua` operations. Do not add compatibility aliases for removed APIs.

## Messages

The protocol version goes from 32 to 33.

### Pane request: sender to shell

`ANVIL_SURFACE_MSG_PANE_REQUEST` (102). The Sidebar and every Project can send it.

```c
typedef struct {
  uint32_t route;      /* ANVIL_SURFACE_PANE_ROUTE_SELECT, _DIRECT or _POINTER */
  int32_t x, y;        /* ROUTE_POINTER: pointer in the sender's surface pixels. Otherwise 0. */
  uint32_t path_size;  /* bytes of the Project path that follow. 0 for ROUTE_POINTER. */
} AnvilSurfacePaneRequest;
/* Followed by the path bytes (no NUL), then the request text: a Lua table literal. */
```

Routes:

- `SELECT` (1): select the Project in the sender's Anvil Window, then deliver the request when the
  Project is Ready. This is today's `select_pane_path` behavior for the Sidebar's Pane focus and close.
- `DIRECT` (2): deliver the request to the loaded Project with this path now, in any Window. Do not change
  the selection. If the Project is not loaded and Ready, drop the request and log it.
- `POINTER` (3): deliver the request to the sender Window's Selected Project. Convert the pointer from the
  sender's surface to that Project's surface pixels. If the Project is not Ready, drop and log.

The text is at most `ANVIL_SURFACE_MAX_PAYLOAD` minus the header and the path. The shell does not read the
text. Validate the header, the path and the sizes.

The shell does not change Sidebar keyboard focus for a Pane request. Today it returns focus to the Project
for a Sidebar `focus` action. The Sidebar now sends `SIDEBAR_FOCUS` with 0 itself before such a request.
Both messages use the same connection, so the shell gets them in that order.

### Pane request: shell to Project

`ANVIL_SURFACE_MSG_PANE_ACTION` (13) keeps its number and gets a new payload:

```c
typedef struct {
  int32_t x, y;  /* ROUTE_POINTER: pointer in this Project's surface pixels. Otherwise -1, -1. */
} AnvilSurfacePaneDelivery;
/* Followed by the request text. */
```

Remove `AnvilSurfacePaneAction`, `AnvilSurfacePaneActionKind` and `anvil_surface_pane_action_valid`.

### Lua API

- `system.pane_request(route, path, text[, x, y]) -> boolean`. `route` is `"select"`, `"direct"` or
  `"pointer"`. `path` is a string, or nil for `"pointer"`. Returns true when the shell received it.
  This replaces `system.pane_action`. Remove `system.pane_action`.
- Event `"panerequest"` with `(text, x, y)`. `x` and `y` are -1 when the request has no pointer.
  This replaces the `"paneaction"` event. Remove `"paneaction"`.

## Request text

A Lua table literal from `common.serialize(request, {escape = true})`. The receiver loads it with
`load("return " .. text, "=Pane request", "t", {})` and checks every field.

### Position

```lua
target = {
  mode = "join" | "group",
  anchor = "pane-7",        -- a Pane of the receiving Project, or nil
  side = "before" | "after",
}
```

To place Pane P at a target in the receiving Project:

- `group` with no anchor: P becomes its own Pane Group after the last group.
- `group` with anchor A: P becomes its own Pane Group directly before or after A's group
  (`panes.move_to_group_boundary`).
- `join` with anchor A: P joins A's Pane Group next to A, before or after A in Tab order (`panes.move`).
  If P is already in A's group, this reorders it. The split uses the axis of the split that holds A.
  When A is alone in its group, use left for `before` and right for `after`.
- A target that does not change the layout does nothing.

After placement, P is the active Pane and its group is the visible group.

### Actions

| Action | Fields | Route used by the sender | Receiver |
|---|---|---|---|
| `focus` | `pane` | select | Focus the Pane. |
| `close` | `pane` | select | Close the Pane. |
| `move` | `pane`, `target` | direct | Place the Pane at the target. |
| `open` | `files` (absolute paths) and/or `text`, `target` | select | Open each file in a new Pane, in the View that handles it, the same way as a drop on an empty work area (`RootPanel:open_dropped_file` with a `new` target): a folder opens a File Tree. Text opens a new Untitled Buffer. Place the first new Pane at the target. Place each later one after the previous one with the same mode. |
| `drop` | `pane`, `files` and/or `text` | select | The same as a drop into that Pane: `RootPanel:deliver_drop_to_view` with no `x` and `y`. A Text View then inserts text at its caret. If the View does not take the drop, open each file in that Pane. |
| `export` | `pane`, `to` (Project path), `target`, `transfer` | direct to the source | See transfer. |
| `import` | `snapshot`, `target`, `source` (Project path), `transfer` | select to the target | See transfer. |
| `transferred` | `transfer`, `ok`, `error` | direct to the source | See transfer. |
| `drag` | `phase` (`"move"`, `"drop"`, `"leave"`), `source` (Project path), `pane` | pointer | A Tab dragged right of the Sidebar. The Title Bar shows and applies it like its own Pane drag. A Project ignores a Tab of another Project. |

`pane_requests.perform(text, x, y)` handles every action. It passes `export`, `import` and
`transferred` to `pane_transfer.perform(request)`.

### Transfer of a Pane to another Project

1. The Sidebar sends `export` to the source Project.
2. The source checks the Pane. It refuses a Pane whose Navigation History has a Terminal View, because a
   Terminal Session belongs to one Project. It saves each modified file-backed Buffer of the Pane. It
   builds a snapshot of the Pane, its Views and its Navigation History, like Reopen Closed Pane. An
   Untitled Buffer's text goes into the snapshot. If the snapshot does not fit in the message, refuse.
3. The source sends `import` with route `select` to the `to` Project. It remembers the transfer.
4. The target restores the Pane from the snapshot and places it with `pane_requests.place(pane, target)`.
   It sends `transferred` with route `direct` to the source, with `ok = true`, or `ok = false` and an
   `error` text.
5. On `ok`, the source closes its Pane without a prompt. Otherwise it keeps the Pane and shows the error
   with `core.warn`. If no answer comes, the source keeps the Pane.

On a refusal in step 2, the source shows the reason with `core.warn`.

### Functions that other lanes call

- `pane_requests.perform(text, x, y)`: parse, check and do one request. Returns true on success, or nil
  and an error text.
- `pane_requests.place(pane, target)`: place an existing Pane of this Project at a target. Returns the
  Pane, or nil and an error text.
- `pane_transfer.perform(request)`: handle `export`, `import` and `transferred`. Returns true, or nil and
  an error text.
- `panes.snapshot(pane)`: the Reopen Closed Pane snapshot of a Pane. Returns the snapshot, or nil and an
  error text. The transfer lane makes it public from today's `save_closed_pane`.
- `panes.restore(snapshot, opts)`: create a Pane from a snapshot, like `panes.reopen_last_closed`.
  `opts.focus` works as in `panes.create`. Returns the Pane, or nil and an error text.
  `panes.reopen_last_closed` uses it.

The Pane requests lane uses only `panes.lua` functions that exist now. If it needs a `panes.lua`
change, it writes that in its report.

The lead changes `data/core/sidebar_app.lua` from `system.pane_action` to `system.pane_request`. Until
then, the Sidebar's Pane focus and close use the old call and can fail. That is expected.

## Shell behavior for the Sidebar

- Pointer capture: after a mouse button goes down in the Sidebar, send every motion and the release to
  the Sidebar until all buttons are up, also outside the Sidebar and outside the Window. The Project does
  not get them. Coordinates stay in the Sidebar's surface pixels, so they can be negative or larger than
  its width.
- Cursor: while the pointer is in the Sidebar, or the Sidebar holds the pointer, show the cursor that the
  Sidebar last reported with `ANVIL_SURFACE_MSG_CURSOR`. Do not reset it to the arrow on each Sidebar
  motion. When the pointer leaves the Sidebar, show the arrow or the Project's cursor as today.
- Drops: forward SDL drop events over the Sidebar to the Sidebar, with the Sidebar's coordinates. Forward
  the others to the Selected Project as today. Send the drop begin and the drop complete to both. When the
  drop position moves from one to the other, send the one that it left a drop position of -1, -1. Send
  file and text events to the one under the pointer. The Sidebar takes drops in every Project state.
  In the Sidebar process, these become the normal Lua events: `dropbegin`, `dropmoved`, `filedropped`,
  `textdropped` and `dropcomplete`.
