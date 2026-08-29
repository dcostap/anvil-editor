# Anvil Terminal View implementation plan

## Purpose

This plan improves Anvil's Terminal View without replacing its current model.

The target is a robust 90% implementation for daily Windows use.

The plan uses these source audits:

- [Anvil Terminal View audit](ANVIL_TERMINAL_AUDIT.md)
- [Zed Terminal View audit](ZED_TERMINAL_AUDIT.md)
- [VS Code terminal audit](VSCODE_TERMINAL_AUDIT.md)

The external audits reviewed these revisions:

- Zed `1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a`
- Zed's Alacritty fork `4c129667ce56611becdc82de6e28218c80e2e88f`
- VS Code `3aa54039a0bec1bd4f9b428cdb202b4271bf22ef`

The Anvil audit reviewed repository revision `0a7e55729ac76f7f21472e1ce46bf730249f5bc8`.

## Product target

The finished Terminal View must make these behaviors unsurprising:

1. A shell either starts or leaves a useful failed Terminal View.
2. A running process keeps all output through normal backpressure.
3. Final output appears before Anvil reports process exit.
4. Focus reports match View, Pane, and application-window focus.
5. Anvil commands and terminal key input never produce unmatched key events.
6. Hidden Terminal Views keep running without unnecessary render work.
7. Every running Terminal View remains reachable.
8. Exit, failure, restart, and close have clear meanings.
9. Clipboard and URI requests treat terminal output as untrusted data.
10. Common file locations and web addresses become safe Text POIs.
11. Search gives clear found or no-match feedback.
12. Terminal Text Capture remains the stable text-review surface.
13. Native memory, queues, and work stay bounded.
14. Logs explain lifecycle failures without recording user input or output.

## Core decision

Keep the current architecture.

```text
Generic Pane and Workspace
          |
          v
Terminal View in Lua
  - View lifecycle and focus
  - commands and user prompts
  - drawing and Text POIs
  - launch-recipe persistence
  - Terminal Text Capture
          |
          v
One native Terminal Session
  - ConPTY and process job
  - bounded input and output queues
  - libghostty-vt terminal model
  - key, mouse, paste, and selection encoding
  - render snapshots and terminal events
```

Do not add a terminal service.

Do not add a terminal-only tab or split model.

Do not add another emulator abstraction.

Do not add a separate PTY host without repeated native failure evidence.

## Lessons from Zed and VS Code

| Source lesson | Anvil decision |
|---|---|
| Both editors use a proven emulator. | Keep libghostty-vt as the only terminal model. |
| One model owns each PTY and process. | Keep one native session per Terminal View. |
| Views do not implement VT protocols. | Keep key, mouse, paste, and selection rules in Ghostty. |
| Output work needs flow control. | Keep bounded queues and producer backpressure. |
| Exit must wait for trailing output. | Add a final-output barrier before the exited state. |
| Process states are explicit. | Replace the Lua `running` Boolean with a small state model. |
| Failed starts remain visible. | Keep a failed Terminal View in the requested Pane. |
| Resize work ignores unchanged grids. | Keep current changed-geometry filtering. |
| Search and Text POIs invalidate after reflow. | Add one render-generation invalidation rule. |
| Link gestures must not leak mouse events. | Own each press-to-release gesture in one route. |
| Shell output is untrusted. | Validate clipboard requests, titles, directories, URIs, and paths. |
| Stable text improves accessibility. | Keep Terminal Text Capture instead of a live mirror editor. |
| Launch recipes can persist. Live processes cannot. | Restore a new shell at a saved validated directory. |
| Large products need terminal services and registries. | Anvil does not need those systems. |
| Debug logs can expose secrets. | Never log PTY bytes, commands, pasted text, or full environments. |

## Explicit lifecycle model

Use one state vocabulary in C, Lua, logs, and tests.

```text
new --start succeeds--> running
new --start fails-----> failed
running --process exits--> draining --quiet output drain--> exited
running --fatal transport error---------------------------> failed
exited --restart succeeds---------------------------------> running
failed --restart succeeds---------------------------------> running
any live state --View close-------------------------------> closed
```

### State meanings

**running**

The child process accepts input.

The native session can resize, parse output, and send protocol input.

**draining**

The root process has exited.

The reader can still receive final ConPTY output.

Input and resize requests must fail cleanly.

**exited**

The process exit code is final.

The transport is released.

The terminal model and final render snapshot remain readable.

**failed**

The shell did not start, or the live transport failed.

The View keeps the error and any last valid snapshot.

**closed**

The View released the native session.

No native method can access terminal or transport resources.

### State API

Refactor `session:update()` to return two values:

```text
changed, status
```

`status` contains:

```text
kind
revision
exit_code, when known
error, when known
```

Increment `revision` only for a new state or error transition.

Do not keep deprecated return forms.

Update all in-repository callers and tests in the same change.

### Why `draining` is necessary

The current code reports process exit before transport release.

It uses one fixed 100-millisecond delay from the first exit observation.

Late output does not reset that delay.

A short explicit draining state makes final-output behavior testable.

Use these native rules:

- Start the quiet period after process exit.
- Reset the quiet period when new output arrives.
- Finalize after 250 milliseconds of drained quiet.
- Force finalization after five seconds.
- Log forced finalization without logging terminal data.

Tests must verify final output, not exact timing constants.

## Trust model

The running terminal application controls these values:

- output text
- OSC title
- reported current directory
- OSC 8 URI
- OSC 52 clipboard request
- notification title and body

Treat all of them as untrusted.

Apply these rules:

- Sanitize titles before using them in Anvil UI.
- Use only validated local directories for Windows process starts.
- Allow only fixed URI schemes.
- Validate file targets before showing a Text POI.
- Bind clipboard approval to one immutable request.
- Bound all displayed and scanned text.
- Never put terminal data into shell commands without correct quoting.

## Phase 0: establish a reliable baseline

Do this phase before product changes.

The focused UI file currently passes all 36 tests.

The focused native file passed 19 of 22 tests during the audit.

Three readiness checks failed:

- delayed output missed its text deadline
- the scrollback producer missed its tail deadline
- the default WSL distribution produced no marker

These failures do not prove data loss.

They make later red-green evidence less clear.

### Slice 0.1: separate capability from behavior

Update `tests/lua/runtime/terminal_native.lua`.

- Probe for a usable default WSL distribution before the WSL behavior test.
- Skip the WSL test when the external capability is unavailable.
- Keep OpenSSH's existing capability probe.
- Report the skip reason clearly.

Do not treat an installed `wsl.exe` as a usable distribution.

### Slice 0.2: remove shell-speed timing from scrollback retention

Keep the retention contract.

Change the producer to write one prepared multi-line buffer.

Do not run 1,500 slow PowerShell pipeline operations.

Wait for a final marker before taking Terminal Text Capture.

The test must still prove that early and late rows remain.

### Slice 0.3: separate wakeup from output readiness

The wakeup test must prove two independent facts:

1. delayed output posts a terminal output event
2. the expected text arrives through normal update calls

Use a practical bounded deadline.

Do not use a two-second shell-start benchmark as a correctness rule.

### Baseline command

```sh
PATH=/c/msys64/mingw64/bin:$PATH \
  /c/msys64/mingw64/bin/meson.exe test \
  -C build-windows-x86_64 anvil:lua-runtime \
  --test-args tests/lua/runtime/terminal_native.lua \
  --print-errorlogs
```

Stop this phase when the focused native file is stable on the current machine.

## Phase 1: lifecycle and data integrity

This phase fixes the highest-risk behavior.

### Slice 1.1: add native states and final-output drain

#### Red test

Add a native test that exits after a large final write.

The test must observe this order:

1. running
2. draining, when observable
3. exited

The final snapshot must contain the tail marker.

Input during draining must return a clear nonfatal reason.

#### Implementation

Update `src/api/terminal_native.c`.

- Add the native state enum.
- Add a monotonic state revision.
- Record the root-process exit once.
- Track the last received output time.
- Keep the transport until drained quiet or the maximum deadline.
- Publish the exit code only with final state data.
- Retain the Ghostty terminal and render state after transport release.
- Make `close_session()` idempotent from every state.

Do not append exit messages into the terminal model.

The tab title can show exit state.

#### Green check

Run only `tests/lua/runtime/terminal_native.lua`.

### Slice 1.2: make every native method closed-safe

#### Red test

Close a native session.

Call each public session method once.

Each method must return `false`, `nil`, or a clear closed reason.

No method can crash or call Ghostty with a null terminal.

#### Implementation

Guard these native methods consistently:

- paste
- scroll
- selection methods
- selected text
- search
- mouse
- hyperlink lookup
- focus
- color update
- snapshot

Keep `close()` safe on repeated calls.

Do not add compatibility wrappers.

### Slice 1.3: keep failed starts visible

#### Red test

Run `terminal:open` with a missing shell.

Assert these observable results:

- a Terminal View exists in the requested Pane
- the View has state `failed`
- its title shows failure
- its displayed message contains the native reason
- restart remains available

#### Implementation

Update `data/plugins/terminal.lua`.

- Do not raise from `TerminalView:new()` after a start failure.
- Keep `launch_options` and `launch_error` in the View.
- Draw a simple failed state inside the same Terminal View.
- Show the directory, default or custom shell kind, and native reason.
- Log one quiet, session-tagged failure.
- Return the placed failed View from normal open commands.
- Preserve a failed View during Workspace restore.

Do not add a separate failure View class.

Do not add clickable settings machinery in this slice.

### Slice 1.4: use one visible and suspended service path

#### Red tests

Add UI cases for these contracts:

- a suspended exited terminal does not request repeated redraws
- repeated equal native status revisions do not create snapshots
- a hidden output update handles events without rebuilding Lua rows
- returning to the Terminal View refreshes all dirty rows once

#### Implementation

Replace duplicated update logic with one helper:

```text
service_session(include_rows)
```

Use it from `update()` and `update_suspended()`.

Extend native snapshot with one optional `include_rows` Boolean.

When `include_rows` is false:

- update title, directory, events, and state metadata
- keep old Lua row tables
- do not clear Ghostty render dirty state

When the View becomes visible again, request one full row snapshot.

Request redraw only for visible render changes or visible UI state changes.

### Slice 1.5: make focus exact

#### Red tests

Add UI tests for:

- Terminal View gains active focus
- another View in the Pane suspends it
- another visible Pane gains focus
- Anvil's application window loses focus
- application focus returns

The terminal must receive the exact Boolean sequence.

#### Implementation

Add one `sync_focus()` helper.

Compute terminal focus from:

- the View is the Pane's Current View
- its Pane Group is visible
- it is Anvil's Focused View
- the Anvil window has focus

Call this helper from visible and suspended service paths.

Clear IME composition when terminal focus becomes false.

### Slice 1.6: remove strong View retention

#### Red test

Close a Terminal View and release its Pane ownership.

Verify that a weak reference can clear after garbage collection.

Keep the test about observable ownership where possible.

#### Implementation

Remove the module-level strong `views` array.

Find Terminal Views through `panes.ordered()` and `panes.views(pane)`.

Remove `terminal_source_view` from Terminal Text Capture.

Store only capture data and a stable source title.

Do not create another global session registry.

### Slice 1.7: make physical key ownership exact

#### Red tests

Add UI and native cases for:

- an Anvil command consumes a key press and its release
- an unhandled control key sends both required protocol events
- unmodified text uses exactly one input path
- Kitty report-all mode gets matched press and release events
- shifted keyboard-layout text is not duplicated

#### Implementation

Use one physical-key ownership record per pressed scancode.

Each press chooses one owner:

- Anvil command
- Ghostty key encoder
- SDL text input

Send release only when Ghostty owned the press.

Replace the single `encoded_text_input` value with event ownership data.

Keep Ghostty's terminal mode as the protocol authority.

Do not add a manual terminal key table.

## Phase 2: safe daily lifecycle behavior

### Slice 2.1: make restart safe and atomic

#### Durable rule

Restart is available only for `exited` or `failed` Terminal Views.

A running process must not die through the restart command.

Pane close remains the explicit way to close a running session.

Do not add close confirmation without evidence of accidental closes.

#### Red tests

- restart is unavailable while running
- failed restart preserves the exited session and snapshot
- successful restart installs the replacement before closing the prior session
- restart keeps the launch command and validated directory

#### Implementation

Keep replacement creation atomic.

Only close the old session after the replacement starts.

Clear old search, focus, and transient protocol state after adoption.

### Slice 2.2: bind OSC 52 approval to one request

#### Red test

Deliver one clipboard request.

Open the approval dialog.

Deliver a second request before the first answer.

Approving the first dialog must apply only the first request.

The second request must receive a separate decision.

#### Implementation

Use one immutable active request.

Keep at most one bounded queued request.

A later request can replace only the queued request.

Show byte count and a short sanitized preview.

Keep Allow non-default and Deny default.

Do not allow clipboard reads.

### Slice 2.3: validate terminal titles

Sanitize terminal titles at the Lua View boundary.

- remove control characters
- collapse line breaks and tabs to spaces
- trim surrounding space
- use a practical display limit
- fall back to `Terminal`

Keep the raw title only inside the terminal model.

Add a UI test with control text and a long title.

Do not test the exact display limit unless it becomes documented behavior.

### Slice 2.4: separate reported and usable directories

Keep these concepts separate:

- launch directory
- terminal-reported directory
- validated local directory

`get_cwd()` must return a usable local Windows directory.

Use the launch directory when reported data is invalid or remote.

Rules:

- accept local paths that exist as directories
- accept valid existing UNC directories
- decode local `file://` values safely
- reject controls and embedded null bytes
- do not convert arbitrary WSL paths into fake Windows paths
- retain reported data for diagnostics without using it as a process directory

Add tests for local file URIs, UNC paths, bad authorities, WSL paths, and missing directories.

### Slice 2.5: move OSC 8 activation to Lua

The native layer must return URI data.

It must not call `ShellExecuteW`.

Lua owns trust, activation, and Anvil navigation.

Allow these external schemes first:

- `https`
- `http`
- `mailto`

Open local file URIs through Anvil's normal file opener.

Reject other schemes without executing them.

### Slice 2.6: own the complete URI mouse gesture

Current activation happens on mouse press.

Change it to a press-to-release transaction.

- press records the candidate and consumes the gesture
- drag outside cancels activation
- release over the same candidate activates it
- no part of this gesture reaches terminal mouse reporting
- a PTY-owned gesture still sends its complete press and release

Add UI tests with mouse tracking enabled.

### Slice 2.7: fix fractional mouse geometry

The View uses fractional cell width for drawing.

The native mouse encoder uses an integer cell width.

Map UI pixel positions into the native cell geometry before encoding.

The reported cell must match `TerminalView:mouse_position()` at every column.

Add a regression test with fractional font scale and a far-right cell.

Do not change the exact visual font advance.

## Phase 3: daily navigation and quality of life

### Slice 3.1: make every Terminal View reachable

Add one command:

```text
terminal:focus_next
```

It must traverse Terminal Views through Pane ownership.

It must include running Views retained outside normal Pane history.

Focusing a retained View must present it through the owning Pane.

Order by Pane order, then Pane-owned View order.

Do not add a terminal tab list or global terminal service.

Add behavior tests through the command seam.

Do not test its shortcut.

### Slice 3.2: extract the existing fixed file-location parser

`data/plugins/command_slots.lua` already parses common file locations.

Do not create a second parser in the terminal plugin.

Extract its fixed candidate and resolution logic into a small shared module.

A suitable boundary is:

```text
data/core/text_poi_locations.lua
```

Update Command Output View behavior and terminal behavior in one refactor.

Keep the current fixed formats, including:

- `path:line`
- `path:line:column`
- `path(line,column)`
- Python `File "path", line N`

Do not add user regex settings.

Do not rename existing glossary terms.

### Slice 3.3: expose one terminal row for Text POI detection

Add a bounded native row-text query.

It must return:

- UTF-8 text for one physical terminal row
- byte ranges mapped to terminal columns
- the current render generation

Call it only when the modifier is held and the mouse enters a new cell.

Bound row bytes and candidate count.

Do not scan full scrollback on hover.

### Slice 3.4: add fixed Terminal Text POIs

Detection order:

1. OSC 8 URI at the cell
2. `https`, `http`, or `mailto` text
3. validated file location from the shared fixed parser

Resolve relative files against the validated Terminal View directory.

Validate the target before showing the link cursor.

Open files through Anvil's normal View placement path.

Preserve line and column.

Cache only the current hovered candidate.

Invalidate it after output, resize, directory change, or modifier release.

Defer these cases:

- wrapped multi-row paths
- generic words
- configurable regular expressions
- historical per-command directories
- remote file providers

### Slice 3.5: add find feedback without a find subsystem

Keep the Global Prompt Bar.

Keep exact case-sensitive search for this stage.

Add visible states:

- searching
- found
- no match

Show the current query and no-match feedback.

Keep next and previous commands.

Clear pending search work when:

- query changes
- terminal width changes
- scrollback generation invalidates row positions
- the session restarts

Do not add regex, whole-word, result counts, or overview marks yet.

### Slice 3.6: make inactive cursor state clear

Draw a hollow cursor when a visible Terminal View lacks terminal focus.

Honor the application cursor shape while focused.

Keep application-controlled blink state.

Do not add custom cursor settings.

### Slice 3.7: preserve Terminal Text Capture independence

Verify these behaviors:

- capture remains readable after source close
- capture does not keep the source Terminal View alive
- source output does not change old capture text
- copied capture remains independent
- capture retains its saved title and colors

Terminal Text Capture remains the review and accessibility path.

Do not build a second live text mirror.

## Phase 4: resource bounds and diagnostics

### Slice 4.1: replace idle pipe polling with blocking reads

The reader currently calls `PeekNamedPipe()` and sleeps every two milliseconds.

Use blocking `ReadFile()` instead.

Keep `CancelSynchronousIo()` for shutdown.

Keep the existing condition-variable backpressure after each read.

Add lifecycle stress coverage for close during a blocked read.

Do not add overlapped I/O or an I/O completion port.

### Slice 4.2: keep both Ghostty scrollback limits

The current code removes Ghostty's byte limit when it sets the line limit.

Set both limits.

Use:

- the existing user-facing physical-row setting
- one internal 64 MiB native memory ceiling per session

Reduce the settings UI maximum from 1,000,000 rows to 100,000 rows.

Keep the default at 10,000 rows.

Describe the row setting as a target subject to native memory bounds.

Do not add a second scrollback setting now.

Do not test the exact byte constant as a user contract.

### Slice 4.3: make queue saturation recoverable

A full write queue must reject that write only.

It must not poison all later status results.

Return a reason such as `queue_full` to the caller.

Show one useful error for an explicit paste.

Use a bounded quiet log for key-input saturation.

Track these counters:

- output bytes read
- output bytes parsed
- input bytes queued
- read queue high-water mark
- write queue high-water mark
- rejected writes
- forced output-drain finalizations

Expose counters through one native stats method for tests and diagnostics.

Do not log terminal contents.

### Slice 4.4: add fixed terminal environment identity

Set these child values:

- `TERM_PROGRAM=anvil`
- `TERM_PROGRAM_VERSION=<Anvil version>`
- `TERM=xterm-256color`
- `COLORTERM=truecolor`

Merge them over the inherited environment.

Reuse the repository's existing process-environment rules where practical.

Keep Windows environment key comparison case-insensitive.

Do not expose an environment-provider registry.

Do not inject shell scripts.

Add a native behavior test that prints these values.

Do not print environment values in normal logs.

### Slice 4.5: add session-tagged quiet diagnostics

Give each Terminal View one monotonic local session identifier.

Log these transitions:

- start request
- start success or failure
- validated directory fallback
- grid resize
- running to draining
- draining to exited
- fatal transport error
- queue saturation
- restart result
- close result

Useful fields are:

- session identifier
- state
- rows and columns
- default or custom shell kind
- exit code
- Windows error code or operation
- byte and queue counters

Never log:

- PTY input
- PTY output
- pasted text
- command text
- clipboard contents
- full environment values

### Slice 4.6: measure several sessions

Extend `tests/lua/benchmarks/terminal.lua` or add one focused benchmark.

Measure:

- ten idle sessions
- one visible output-heavy session
- several hidden output-heavy sessions
- resize bursts
- no-match search
- Terminal Text Capture on large scrollback

Record update and snapshot timing.

Record queue high-water counters.

Do not add machine-dependent working-set limits to the test suite.

Do not reduce the current 4 MiB queue capacities without measured evidence.

### Slice 4.7: consider Ghostty idle compression only after measurement

The pinned libghostty-vt supports incremental scrollback compression.

Add it only when the multi-session measurement shows useful savings.

If added:

- schedule bounded work only during idle time
- stop when Ghostty reports no pending work
- restart after compression activity changes
- never run a full synchronous compression scan on the UI path

This slice is optional for the 90% target.

## Rendering limits for this plan

Keep the current render projection and batching.

Do not add:

- Kitty images
- Sixel images
- custom block-glyph painting
- ligature support
- a second GPU terminal renderer
- full-scrollback row layout

Fix visible rendering defects only with a repeatable case.

High-value rendering checks are:

- wide graphemes
- combining marks
- fallback fonts
- inverse text
- cursor shape
- fractional scale
- clipping at View bounds

## Persistence rules

Keep Workspace persistence narrow.

Persist only:

- shell command
- validated starting directory
- ordinary View placement through Workspace state

Restore a new shell.

Do not persist:

- live process identity
- ConPTY handles
- input state
- current prompt text
- scrollback grid
- selection
- search state
- protocol mode state

Do not call restored launch data a restored session.

Terminal Text Capture is the durable text option.

## Test plan

### Stable seams

Use these seams:

- terminal commands
- `TerminalView` public methods
- Pane ownership and View Suspension
- native session methods
- terminal snapshots and state
- real ConPTY behavior
- file opening through normal Anvil APIs

Do not assert private helper calls.

Do not duplicate Ghostty's VT parser tests.

### Test files

Use these existing files first:

- `tests/lua/runtime/terminal_native.lua`
- `tests/lua/ui/terminal.lua`
- `tests/lua/benchmarks/terminal.lua`

Use a new focused file for Text POI behavior if it keeps runs smaller:

- `tests/lua/ui/terminal_text_poi.lua`

### Red-green workflow

For each slice:

1. Add one durable failing test.
2. Run it before implementation.
3. Confirm the failure has the expected reason.
4. Apply the smallest implementation.
5. Run the same focused path.
6. Run the related terminal file when the slice is complete.

Do not write a broad speculative suite first.

### Focused commands

Native behavior:

```sh
PATH=/c/msys64/mingw64/bin:$PATH \
  /c/msys64/mingw64/bin/meson.exe test \
  -C build-windows-x86_64 anvil:lua-runtime \
  --test-args tests/lua/runtime/terminal_native.lua \
  --print-errorlogs
```

Terminal View behavior:

```sh
PATH=/c/msys64/mingw64/bin:$PATH \
  /c/msys64/mingw64/bin/meson.exe test \
  -C build-windows-x86_64 anvil:lua-ui \
  --test-args tests/lua/ui/terminal.lua \
  --print-errorlogs
```

Text POI behavior:

```sh
PATH=/c/msys64/mingw64/bin:$PATH \
  /c/msys64/mingw64/bin/meson.exe test \
  -C build-windows-x86_64 anvil:lua-ui \
  --test-args tests/lua/ui/terminal_text_poi.lua \
  --print-errorlogs
```

Benchmark:

```sh
PATH=/c/msys64/mingw64/bin:$PATH \
  /c/msys64/mingw64/bin/meson.exe test \
  -C build-windows-x86_64 anvil:terminal-native-perf \
  --print-errorlogs
```

Run the full Anvil suite only if a change crosses many non-terminal boundaries.

## File change map

### `src/api/terminal_native.c`

Planned work:

- explicit native states
- state revision
- final-output barrier
- closed-state guards
- recoverable queue rejection
- optional row-free snapshots
- bounded row-text and OSC 8 range queries
- blocking reader
- scrollback byte ceiling
- fixed terminal environment
- native counters
- removal of direct `ShellExecuteW` URI activation

Keep this as one Windows native bridge.

Do not split it until another platform creates a real shared boundary.

### `data/plugins/terminal.lua`

Planned work:

- explicit View state
- failed-state rendering
- shared visible and suspended service helper
- exact focus synchronization
- physical key ownership
- safe restart
- immutable clipboard requests
- title and directory validation
- complete URI gestures
- Terminal Text POIs
- find feedback
- focus-next command
- inactive cursor
- session-tagged quiet logs
- removal of strong View registries

Keep Terminal Text Capture in this module unless it grows independently.

### `data/core/text_poi_locations.lua`

Add only when Terminal View becomes the second caller.

Own fixed file-location extraction and validation.

Do not own terminal state, hover state, or file opening placement.

### `data/plugins/command_slots.lua`

Move existing fixed location parsing into the shared module.

Keep Command Output View behavior unchanged.

### `data/plugins/anvil_defaults.lua`

Keep the current three terminal behavior settings.

Do not add settings for every new internal limit.

### `data/colors/default.lua`

No new color key is required for this plan.

Reuse existing terminal, selection, and dim colors.

### Tests

Add focused behavior only for implemented slices.

Do not test exact shortcuts, colors, padding, limits chosen by taste, or timing constants.

## 90% completion line

The Terminal View reaches the target when all items below are true.

### Lifecycle

- [ ] Start success and failure both leave clear View state.
- [ ] Native states use one vocabulary.
- [ ] Final output precedes exited state.
- [ ] Close is idempotent.
- [ ] Native methods remain safe after close.
- [ ] Restart cannot kill a running session.
- [ ] Exited output remains readable.

### Focus and input

- [ ] Focus includes Pane, View, and window focus.
- [ ] Suspended Terminal Views send focus-out.
- [ ] Each physical key has one owner.
- [ ] Key releases match terminal-owned presses.
- [ ] IME input sends committed text once.
- [ ] Fractional-scale mouse reports use the correct cell.

### Hidden sessions and ownership

- [ ] Hidden sessions keep draining output.
- [ ] Hidden sessions do not build Lua row snapshots.
- [ ] Exited hidden sessions do not request repeated redraws.
- [ ] Closed Terminal Views have no module registry retention.
- [ ] Terminal Text Capture does not retain its source View.
- [ ] A command can reach every retained running Terminal View.

### Trust and daily behavior

- [ ] Clipboard approval applies to one immutable request.
- [ ] Titles are safe for one-line UI.
- [ ] Reported directories require local validation.
- [ ] OSC 8 activation uses fixed safe schemes.
- [ ] URI gestures never leak partial PTY mouse events.
- [ ] File-location Text POIs validate before activation.
- [ ] Search shows found or no-match feedback.

### Resources and diagnostics

- [ ] Output and input queues stay bounded.
- [ ] Queue rejection recovers.
- [ ] Idle readers do not poll every two milliseconds.
- [ ] Scrollback has line and byte limits.
- [ ] Terminal child environment identifies Anvil and true color.
- [ ] Logs contain session state and counters.
- [ ] Logs never contain terminal data or commands.
- [ ] Focused native, UI, and benchmark targets pass.

## Deferred work

Do not include these features in the 90% implementation:

- Unix PTY support
- a separate terminal host process
- process reconnection after Anvil restart
- scrollback replay into a new shell
- shell startup script injection
- command decorations
- command navigation marks
- recent terminal commands
- task-terminal reuse policies
- remote terminal backends
- extension pseudoterminals
- terminal-only tabs or splits
- configurable path regexes
- generic word Text POIs
- historical per-command directories
- vi copy mode
- HTML clipboard copy
- image protocols
- local type-ahead prediction
- AI terminal blocks

Revisit one item only after a concrete workflow needs it.

## Final implementation order

Use this order:

1. Stabilize the focused native baseline.
2. Add native lifecycle states and final-output drain.
3. Guard every native closed path.
4. Keep failed starts visible.
5. Unify visible and suspended service work.
6. Correct focus and physical key ownership.
7. Remove strong View retention.
8. Make restart, clipboard, title, directory, and OSC 8 behavior safe.
9. Add retained-terminal access.
10. Reuse fixed location parsing for Terminal Text POIs.
11. Add find feedback and inactive cursor state.
12. Replace reader polling and add native resource bounds.
13. Add terminal environment identity and session diagnostics.
14. Measure several sessions.
15. Add Ghostty compression only if measurements justify it.

This order fixes correctness before adding features.

It preserves Anvil's current simple architecture.
