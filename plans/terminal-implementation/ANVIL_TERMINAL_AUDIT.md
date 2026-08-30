# Anvil Terminal View audit

## Scope

This report audits Anvil's current Terminal View.

The audit covers source at repository revision `0a7e55729ac76f7f21472e1ce46bf730249f5bc8`.

The Terminal View source had no local changes during this audit.

Anvil uses libghostty-vt revision `f64f4aca2c29b554d111b36c3d946a9bddd159ff`.

This report does not propose a second terminal emulator. It treats libghostty-vt as the terminal model.

## Verdict

The terminal engine is more complete than its user experience suggests.

The hard parts already work:

- ConPTY process control
- VT parsing
- bounded output work per frame
- output backpressure
- key and mouse protocol encoding
- Unicode cell data
- alternate screens
- scrollback
- selection
- search
- paste protection
- terminal colors
- incremental render rows
- process-tree cleanup

The main risks now sit around this engine.

Lifecycle, focus, failure display, links, session access, and hidden-session work need attention.

The smallest good model is still one Terminal View with one native session.

Anvil does not need VS Code's service graph or a separate terminal server.

## Source map

| Area | Source | Purpose |
|---|---|---|
| Terminal View | `data/plugins/terminal.lua` | View lifecycle, input, drawing, commands, and text capture |
| Native session | `src/api/terminal_native.c` | ConPTY, process control, queues, and libghostty-vt bridge |
| Defaults | `data/plugins/anvil_defaults.lua` | Shell, starting directory, and scrollback defaults |
| Theme | `data/colors/default.lua` | Terminal foreground, background, cursor, and ANSI palette |
| Build | `meson.build`, `src/meson.build` | Windows-only libghostty-vt and native bridge build |
| Dependency pin | `subprojects/ghostty.wrap` | Exact Ghostty revision |
| Ghostty build | `scripts/build-ghostty-vt.sh` | Zig build and dependency fetch |
| Native tests | `tests/lua/runtime/terminal_native.lua` | Real ConPTY and terminal model behavior |
| View tests | `tests/lua/ui/terminal.lua` | In-process Terminal View behavior |
| Benchmark | `tests/lua/benchmarks/terminal.lua` | Output, snapshot, search, and Lua heap timing |
| Pane service | `data/core/panes.lua`, `data/core/rootpanel.lua` | Hidden Terminal View updates and ownership |
| Workspace state | `data/core/panes.lua` | Saves only each Pane's Current View |

## Current design

### One View owns one session

`TerminalView:new()` creates one native session.

The native session owns one ConPTY, one root process, one Windows job, and the terminal model.

Copying a Terminal View starts a new session at the reported current directory.

Workspace restore also starts a new session. It does not reconnect the old process.

This is a good boundary for Anvil.

### Native work stays behind one Lua userdata

Lua calls a small session API:

- `update`
- `snapshot`
- `write`
- `paste`
- `key`
- `mouse`
- `resize`
- `scroll`
- `selection_gesture`
- `selected_text`
- `search`
- `text_capture`
- `focus`
- `set_colors`
- `close`

This boundary keeps VT details out of Lua.

It also keeps the UI independent from Ghostty's internal data structures.

### The UI thread owns the terminal model

A reader thread puts ConPTY bytes into a ring queue.

The UI thread drains at most 128 KiB per `update()` call.

It then writes the bytes into libghostty-vt.

This prevents parser work from blocking one frame without a limit.

A writer thread drains a second ring queue into ConPTY.

The design preserves output through backpressure instead of dropping bytes.

### Snapshots are incremental

The C bridge converts dirty terminal rows into Lua render runs.

It reuses unchanged row tables from the prior snapshot.

Text runs group adjacent cells with the same style.

Background spans use separate runs.

This is a sound rendering seam.

### Hidden sessions remain active

Pane ownership registers Terminal Views as suspended services.

`RootPanel:update()` calls `update_suspended()` for hidden Terminal Views.

This prevents a hidden process from blocking on a full output pipe.

It also lets bells and terminal requests arrive while the View is hidden.

## What is already strong

### Terminal compatibility

Anvil delegates terminal semantics to libghostty-vt.

That choice avoids a weak custom ANSI parser.

The current bridge handles:

- primary and alternate screens
- terminal resize and reflow
- 16-color and true-color cells
- bold, italic, faint, blink, and inverse text
- several underline forms
- strike and overline
- wide cells and grapheme text
- Kitty keyboard protocol state
- terminal mouse tracking
- bracketed paste
- OSC 7 and OSC 9;9 current directories
- OSC 8 hyperlinks
- OSC 52 clipboard writes
- OSC 9 and OSC 777 notifications
- focus reporting
- title changes
- terminal size reports

This gives Anvil a strong base.

### Output flow

The read queue holds 4 MiB and applies backpressure.

The update loop has a 128 KiB parsing budget.

A custom SDL event wakes the editor when output arrives.

The stress test checks a multi-megabyte stream and its final marker.

This is much safer than polling the process from Lua.

### Process cleanup

The root process starts suspended.

Anvil adds it to a kill-on-close Windows job before it resumes.

Closing the session kills its process tree.

The native test verifies this behavior with a delayed child process.

### Input

Application commands run before terminal input.

Unhandled keys then pass through Ghostty's key encoder.

SDL scancodes preserve physical keys and keyboard layouts.

Text input remains separate from encoded control keys.

The code avoids duplicate shifted text in Kitty keyboard mode.

IME composition stays local until SDL sends committed text.

### Selection and paste

Ghostty owns selection gestures and selected-text formatting.

Anvil supports character, word, line, and rectangular gestures.

Shift bypasses application mouse tracking for local selection.

Multi-line paste requires user approval.

Bracketed paste state comes from the terminal model.

OSC 52 clipboard writes also require approval.

### Rendering

Terminal fonts disable ligatures.

The View batches equal styles but keeps each run's grid columns.

The renderer receives known cell bounds.

The View draws terminal backgrounds before text.

It supports several cursor and decoration forms.

Theme changes update an active terminal session.

### Terminal Text Capture

Terminal Text Capture is a useful Anvil-specific feature.

It creates a read-only Text View from the complete terminal contents.

The capture preserves:

- stable text
- cursor location
- viewport location
- foreground and background colors
- bold and italic fonts
- faint text
- underlines
- strike marks

The source terminal keeps running.

This gives users normal text navigation without corrupting the terminal session.

## Confirmed source defects

These findings follow directly from the current control flow.

### P0: Hidden Terminal Views do not update focus

Normal `TerminalView:update()` sends focus changes at `data/plugins/terminal.lua:542`.

`TerminalView:update_suspended()` does not run this logic.

Opening another View can suspend the terminal while its focus state remains true.

Terminal applications can then believe they still own focus.

The same problem occurs when a Terminal View becomes hidden through Pane history.

The focus test covers only normal visible updates.

It does not cover suspension or application window focus.

**Required correction:** Use one focus synchronizer in visible and suspended updates.

The focus value must include the Anvil window focus state.

### P0: Suspended exited sessions repeat snapshot and redraw work

The native status contains `exit_code` on every later `update()` call.

See `src/api/terminal_native.c:1013` and `src/api/terminal_native.c:1053`.

`TerminalView:update_suspended()` treats any status table as a fresh change.

It then snapshots and requests a redraw at `data/plugins/terminal.lua:611`.

An exited hidden terminal can repeat this work for every root update.

Transport errors have the same repeated-status shape.

**Required correction:** Cache status transitions and snapshot only new state.

### P0: The global Terminal View list retains closed Views

`data/plugins/terminal.lua:20` creates a strong `views` array.

Every new Terminal View enters this array at line 210.

`TerminalView:on_close()` does not remove the View.

`M.open_views()` cleans the array only when another caller invokes it.

Production code does not call `M.open_views()`.

Tests call it during cleanup.

Each closed Terminal View therefore remains reachable for the process lifetime.

**Required correction:** Remove this registry or use weak membership.

Pane ownership must remain the source of truth.

### P0: Start failures are silent through normal commands

`TerminalView:new()` raises an error when native loading or process start fails.

`panes.place()` catches the factory error and returns it.

`M.open()` returns that result at `data/plugins/terminal.lua:1064`.

The open commands compare the View with `nil` and discard the error.

An invalid shell, invalid directory, unavailable ConPTY, or missing native module can fail silently.

Workspace restore also drops the detailed error through `from_state()`.

**Required correction:** Show one clear start error and write one quiet diagnostic.

### P1: A consumed application key can still send its release

`core.on_event()` runs the keymap before Terminal View key input.

A successful Anvil command consumes the key press.

Key releases still go to the active View through `TerminalView:on_key_released()`.

A terminal application using release reports can receive a release without its press.

This can affect Kitty keyboard protocol applications.

**Required correction:** Track terminal-routed presses and send only matching releases.

### P1: OS focus is not part of terminal focus

Normal focus checks only `core.active_view == self`.

It does not check `system.window_has_focus(core.window)`.

A terminal application can miss focus-out when the Anvil window loses focus.

**Required correction:** Combine View focus, Pane visibility, and window focus.

### P1: Clipboard approval can apply to a replaced request

`handle_events()` stores one mutable `pending_clipboard` value.

A later OSC 52 request replaces it while the approval dialog remains open.

The approval callback reads the latest value, not the request that opened the dialog.

The dialog also gives no size or preview.

**Required correction:** Bind each approval to one immutable request.

New requests must wait or replace the dialog with clear state.

### P1: Running restart is destructive without a guard

`TerminalView:restart()` always creates a replacement and closes the prior session.

The command is available while the old process still runs.

It gives no warning before killing that process tree.

**Required correction:** Limit restart to exited sessions or require clear approval.

## Important product gaps

### No reliable way to find every running terminal

A Terminal View can live in Pane history or retained View storage.

Pane branch changes can retain a running terminal outside navigation history.

The process remains active, but the user can lose a direct route back to it.

The current strong `views` list does not provide a command or picker.

A simple running-terminal picker would solve this gap.

It should list title, directory, state, and owning Pane.

It should use Pane ownership instead of a second session manager.

### Link support stops at explicit OSC 8 links

Ctrl-click opens only OSC 8 links.

The UI does not show a link cursor or underline before the click.

Plain web addresses are not links.

File paths and `path:line:column` text are not links.

`file://` links open through Windows instead of Anvil's file navigation.

A small resolver can cover most useful cases:

1. explicit OSC 8 link
2. web address under the cell
3. existing absolute or current-directory file path
4. optional line and column suffix

The resolver does not need an extension system yet.

### Find lacks state and feedback

Search is exact and case-sensitive.

It works on one physical row at a time.

It cannot match text across wrapped rows.

The prompt searches only on submit.

It shows no result count, no no-match state, and no active query state.

Search also replaces the user's terminal selection.

A small in-View find model would improve this feature.

Regex support is not necessary for the first improvement.

### Shell identity is weak

The child inherits Anvil's environment without terminal-specific values.

Anvil does not set `TERM_PROGRAM`, `TERM_PROGRAM_VERSION`, or `COLORTERM`.

It does not expose a small environment override table.

The shell option is one raw command string.

This is simple, but start errors and quoting errors are hard to diagnose.

A short set of built-in launch profiles can remain unnecessary.

One default command plus an optional environment table is enough for now.

### Current directory data is trusted too much

The View reads current directory data from terminal escape sequences.

`terminal_pwd()` decodes and converts that value without directory validation.

The result can become a new process directory or a file-context directory.

WSL paths and remote authorities can map to invalid Windows paths.

The View should keep both reported and validated directories.

Only a valid local directory should become a Windows process directory.

### Terminal titles need UI sanitation

`get_name()` returns the raw terminal title.

It does not remove control text or set a practical UI length.

The terminal model limits some OSC data, but the View still needs a UI rule.

Sanitize titles at the View boundary.

Do not change the title stored in the terminal model.

### Hidden output still builds Lua render snapshots

`update_suspended()` creates a full visible-row snapshot after output changes.

A hidden terminal needs parsing, process state, title, and events.

It does not need Lua text runs until it becomes visible.

A small status snapshot can avoid hidden render projection work.

This matters with several output-heavy terminals.

### The native resource cost is high per session

Each session reserves two 4 MiB ring queues.

Each session also creates two Windows threads.

The reader wakes every 2 ms while idle because it polls `PeekNamedPipe()`.

Ten idle terminals reserve about 80 MiB for queues and run ten polling readers.

The two-thread model is acceptable for Anvil.

The polling and fixed queue sizes are not necessary.

A blocking reader can use the existing cancellation path.

Smaller queues can still apply correct backpressure.

Measure before selecting new capacities.

### Scrollback has no byte ceiling

When Anvil sets a line limit, it removes Ghostty's byte limit.

See `src/api/terminal_native.c:646`.

The settings UI allows up to 1,000,000 physical rows.

Styled or very wide rows can consume large native memory.

Ghostty supports line and byte limits at the same time.

Anvil should use both.

A byte ceiling is more useful than another user setting.

### Ghostty scrollback compression is unused

The pinned libghostty-vt API supports caller-driven idle compression.

Anvil does not schedule it.

This can reduce memory for long-lived scrollback.

Add it only after byte limits and multi-session measurements.

### Cursor focus is unclear

A visible but inactive Terminal View can still draw a solid cursor.

The block cursor uses a translucent overlay instead of terminal cursor text colors.

A hollow inactive cursor would make focus clear.

Exact cursor text inversion can follow after other lifecycle work.

### Mouse scrolling loses precision

Mouse wheel handling uses only the delta sign.

Every event moves three rows, regardless of its size.

Touch handling discards sub-row movement because it has no accumulator.

This makes precision trackpads feel less direct.

### Failure diagnostics are incomplete

Start, resize, Ghostty update, and process-wait failures do not share one error path.

Several native methods return only `false`.

Some Ghostty result values are ignored.

Logs have start and close entries but no session identity or exit summary.

Add one stable session identifier and bounded state logs.

Do not log terminal text or pasted content.

## Features to defer

These features add high cost for little current value:

- a separate terminal service process
- cross-window process reconnection
- live process restore after Anvil restarts
- Kitty image rendering
- Sixel rendering
- a terminal extension-provider framework
- full shell command history storage in Anvil
- task-runner integration
- remote PTY transport
- full screen-reader mode before Anvil has a shared accessibility model
- many shell profile settings

Terminal Text Capture already gives a practical text-access path.

## Test audit

### Existing coverage

The native test file has 22 behavior tests.

The UI test file has 36 behavior tests.

The benchmark file has one sustained-output benchmark.

Useful native tests cover:

- theme and palette use
- light color scheme reporting
- real ConPTY output
- delayed output wake
- exit codes
- PowerShell input
- lock modifiers
- Kitty keyboard layout text
- repeated search
- text capture
- scrollback retention
- bell, clipboard, and notification effects
- multi-megabyte output
- alternate screen behavior
- interactive prompts
- repeated session start and close
- process-tree cleanup
- WSL
- OpenSSH

Useful UI tests cover:

- Pane placement and focus
- hidden service updates
- workspace state
- duplication
- theme changes
- application shortcut priority
- IME display
- resize
- restart behavior
- transport errors
- paste
- selection and copy
- scrollbars
- search commands
- mouse tracking
- focus changes
- render runs and decorations
- real ConPTY rendering

### Focused test results

The following command passed on 2026-08-29:

```text
meson test -C build-windows-x86_64 --no-rebuild \
  anvil:lua-ui --test-args tests/lua/ui/terminal.lua --print-errorlogs
```

Result: all 36 Terminal View UI tests passed.

The focused native file ran 22 tests.

Nineteen passed and three failed.

The failed checks were:

- delayed output did not reach the expected marker within its second wait
- 1,500-line output did not reach its tail within eight seconds
- the default WSL command produced no marker within fifteen seconds

The delayed-output wake flag itself passed before the text check failed.

The failures look like readiness and machine capability problems.

They do not prove output loss.

The WSL test does not first verify a working default distribution.

The scrollback test combines throughput readiness with retention behavior.

These tests need separate capability probes and longer bounded readiness rules.

### Missing durable tests

Add focused tests for these contracts:

1. A suspended Terminal View sends focus-out.
2. Window focus loss sends terminal focus-out.
3. An application shortcut does not leak a key release.
4. A closed Terminal View leaves no module registry reference.
5. A suspended exited session does not request repeated redraws.
6. A failed terminal command shows its start error.
7. A running restart requires the selected safe rule.
8. An OSC 52 approval applies to the shown request only.
9. A reported current directory must pass local validation.
10. Plain web and file links resolve through Anvil.
11. Native methods remain safe after session close.
12. A rapid process exit preserves its final output.

Add integration cases for:

- title and current-directory escape sequences
- combining marks and wide graphemes
- active mouse tracking after fractional scale changes
- bracketed multi-line paste bytes
- resize during an alternate-screen application
- missing shell and missing directory errors

### Tests not worth adding now

Do not test exact shortcuts, palette values, padding, or wheel speed.

Do not duplicate libghostty-vt's parser suite.

Do not add image-protocol tests until Anvil renders terminal images.

## Recommended order before reference synthesis

1. Fix lifecycle and registry defects.
2. Make failures visible and diagnostic.
3. Make terminal focus correct.
4. Add safe restart and clipboard request ownership.
5. Add running-terminal discovery.
6. Add web and file links.
7. Improve find state and feedback.
8. Add terminal environment identity.
9. Bound native memory and remove idle reader polling.
10. Avoid full render snapshots for hidden sessions.
11. Improve cursor and precision scrolling.
12. Consider Ghostty idle compression after measurements.

This order keeps the current model.

It improves correctness before it adds new behavior.
