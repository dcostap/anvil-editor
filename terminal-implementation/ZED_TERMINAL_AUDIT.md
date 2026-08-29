# Zed Terminal View source audit

## Scope and revisions

This report uses Anvil's glossary term **Terminal View**.

The audit covers Zed's current `main` source at this revision:

- Zed commit: [`1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a`](https://github.com/zed-industries/zed/commit/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a)
- Commit date: 2026-08-29
- Commit title: `Fix searching for full SHA-256 commit hashes in Git graph (#63371)`

Zed pins its Alacritty fork at this revision:

- Alacritty commit: [`4c129667ce56611becdc82de6e28218c80e2e88f`](https://github.com/zed-industries/alacritty/commit/4c129667ce56611becdc82de6e28218c80e2e88f)
- Commit date: 2026-06-16
- Crate version: `alacritty_terminal 0.26.1-dev`
- VTE parser: `vte 0.15.0`

This audit inspected source code, tests, manifests, and Zed's terminal guide.
It did not rely only on public documentation.

## Executive summary

Zed gets terminal correctness from a pinned Alacritty fork.
Zed does not implement a terminal emulator from first principles.

The design has four main layers:

1. `Project` resolves shells, environment data, tasks, remote commands, and Python environments.
2. `Terminal` owns emulator state, PTY resources, process data, and terminal protocol behavior.
3. `TerminalView` connects the model to workspace actions, search, focus, and persistence.
4. `TerminalElement` lays out cells and paints the visible terminal grid.

The strongest pattern is the ownership boundary.
One model owns each PTY and its child process.
The view only sends input and renders model snapshots.

The second strong pattern is mode-aware input.
Paste, mouse, focus, cursor keys, and scrolling follow current terminal modes.
This behavior is necessary for full-screen terminal applications.

The third strong pattern is conservative persistence.
Zed restores shell recipes and layout.
It does not claim to restore live processes or terminal scrollback.

Zed's terminal code is not small.
The central source files contain more than 21,000 lines.
Much of this size comes from panel, task, link, remote, AI, and custom rendering features.

Anvil should not port this stack.
Anvil already uses Ghostty's terminal model and a native ConPTY owner.
That is a better base for Anvil's current Windows scope.

Anvil should adopt selected behaviors and tests.
It should retain its simpler `TerminalSession -> TerminalView -> generic Pane` model.

The highest-value Zed patterns are these:

- explicit resource ownership and idempotent shutdown
- resize by cell geometry, not every pixel change
- input routing based on current terminal modes
- bracketed-paste handling
- complete mouse gesture capture
- visible spawn failures
- terminal search through the standard search surface
- fixed persistence semantics
- focused regression tests for lifecycle, resize, selection, links, and focus

Anvil should avoid these Zed choices:

- a terminal-specific dock and split system
- foreground-process polling for current directories
- hand-written key protocol tables
- configurable path-regex machinery in the first release
- terminal-specific SQLite state
- vi copy mode
- AI blocks inside terminal layout
- full cell snapshots and full layout work when incremental data is available

## Architecture trace

```text
Workspace actions and task actions
              |
              v
Project::create_terminal_shell / create_terminal_task
  - choose local or remote shell
  - resolve working directory and environment
  - add terminal environment variables
  - prepare Python activation commands
              |
              v
TerminalBuilder::new                      [fallible background step]
  - create Alacritty Term<ZedListener>
  - create PTY or headless subprocess
  - start Alacritty EventLoop
  - retain process metadata
              |
              v
TerminalBuilder::subscribe                [GPUI entity step]
  - consume backend events
  - batch events for up to 4 ms
  - collapse Wakeup events
              |
              v
Entity<Terminal>
  - emulator and grid lock
  - PTY sender and child process data
  - mode-aware input and mouse encoding
  - selection, search, links, task status
  - backend-neutral Content snapshot
              |
              v
TerminalView
  - focus and action routing
  - clipboard and IME integration
  - workspace Item and SearchableItem
  - tab title, bell, task state, persistence
              |
              v
TerminalElement
  - derive cell geometry
  - resize PTY and emulator
  - sync model snapshot
  - batch text runs and background rectangles
  - paint selection, search, text, graphics, IME, cursor
```

### Output flow

The Alacritty event loop reads PTY bytes.
Its VTE processor updates the shared `Term` grid.
The event loop sends a `Wakeup` event to Zed.

`TerminalBuilder::subscribe` batches model events.
A `Wakeup` invalidates the view and search results.
`Terminal::sync` drains internal UI events and creates `Content`.
`TerminalElement::prepaint` lays out the visible cells.
`TerminalElement::paint` draws the prepared runs and rectangles.

Sources:

- [Zed Alacritty adapter and event loop creation](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/alacritty.rs#L180-L216)
- [Zed event batching](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/terminal.rs#L1402-L1460)
- [Model synchronization](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/terminal.rs#L2411-L2434)
- [Content snapshot conversion](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/alacritty.rs#L882-L936)
- [Element prepaint and paint](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal_view/src/terminal_element.rs#L1189-L1780)
- [Alacritty event loop](https://github.com/zed-industries/alacritty/blob/4c129667ce56611becdc82de6e28218c80e2e88f/alacritty_terminal/src/event_loop.rs)

### Input flow

Raw key events first enter Zed's terminal key mapping.
Mapped keys become control bytes or escape sequences.
Unmapped text goes through GPUI's input handler and IME path.
Paste uses a separate mode-aware path.
Mouse input uses current Alacritty mode flags.

Sources:

- [Input design notes](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal_view/README.md)
- [Key mapping](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/mappings/keys.rs)
- [Terminal input and paste](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/terminal.rs#L2130-L2410)
- [IME input handler](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal_view/src/terminal_element.rs#L1799-L1900)

### Resize flow

`TerminalElement` measures the selected font and available bounds.
It converts pixels to rows and columns.
It sends this geometry to `Terminal::set_size`.

The model ignores pixel changes that preserve the same grid and cell metrics.
It also replaces a pending resize with the newest resize.
The final event resizes both the PTY and emulator grid.

Sources:

- [Cell measurement and device-pixel snapping](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal_view/src/terminal_element.rs#L1250-L1364)
- [Resize coalescing](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/terminal.rs#L2085-L2110)
- [PTY and grid resize](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/terminal.rs#L1706-L1740)

### Close flow

Dropping `Terminal` releases the PTY resources.
Zed first shuts down the Alacritty event loop.
It then requests child termination.
A detached task sends a hard kill after 100 milliseconds.

Task terminals retain exit status and output.
Interactive shells normally close their view after user-driven exit.
Initial spawn failures remain visible when no keyboard input occurred.

Sources:

- [Resource release and forced kill](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/terminal.rs#L3057-L3083)
- [Exit classification](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/terminal.rs#L3109-L3185)
- [`Drop` cleanup](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/terminal.rs#L3384-L3391)

## Source map

| Area | Exact source | Purpose |
|---|---|---|
| Terminal domain and owner | [`crates/terminal/src/terminal.rs`](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/terminal.rs) | PTY ownership, events, modes, selection, search, mouse, paste, tasks, and lifecycle. |
| Alacritty boundary | [`crates/terminal/src/alacritty.rs`](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/alacritty.rs) | Converts backend types into terminal-domain types. Creates the emulator, PTY, and event loop. |
| Link detection | [`crates/terminal/src/alacritty/hyperlinks.rs`](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/alacritty/hyperlinks.rs) | OSC 8 links, URL matching, path regexes, punctuation cleanup, and timeout handling. |
| Key encoding | [`crates/terminal/src/mappings/keys.rs`](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/mappings/keys.rs) | xterm-style key and modifier escape sequences. |
| Mouse encoding | [`crates/terminal/src/mappings/mouse.rs`](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/mappings/mouse.rs) | Normal, UTF-8, and SGR mouse reports. Also handles alternate scrolling. |
| Process data | [`crates/terminal/src/pty_info.rs`](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/pty_info.rs) | Foreground process, current directory, title data, process-group termination, and bounded process refresh. |
| Settings | [`crates/terminal/src/terminal_settings.rs`](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/terminal_settings.rs) | Runtime settings for shell, display, history, links, cursor, bell, and panel. |
| Terminal View | [`crates/terminal_view/src/terminal_view.rs`](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal_view/src/terminal_view.rs) | Workspace item, commands, focus, IME, clipboard, search, tabs, and item persistence. |
| Renderer | [`crates/terminal_view/src/terminal_element.rs`](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal_view/src/terminal_element.rs) | Cell layout, text batching, backgrounds, cursor, selection, block graphics, clipping, and paint. |
| Panel and task tabs | [`crates/terminal_view/src/terminal_panel.rs`](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal_view/src/terminal_panel.rs) | Dock, tabs, split panes, task reuse, spawn failure UI, focus, and panel restoration. |
| Persistence | [`crates/terminal_view/src/persistence.rs`](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal_view/src/persistence.rs) | Pane tree JSON, per-item SQLite data, migrations, and shell recreation. |
| Path opening | [`crates/terminal_view/src/terminal_path_like_target.rs`](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal_view/src/terminal_path_like_target.rs) | Resolves local, remote, worktree, relative, line, and column targets. |
| Scrollbar bridge | [`crates/terminal_view/src/terminal_scrollbar.rs`](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal_view/src/terminal_scrollbar.rs) | Maps terminal history offsets to the shared UI scrollbar. |
| Project terminal creation | [`crates/project/src/terminals.rs`](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/project/src/terminals.rs) | Local and remote shell creation, task creation, environment resolution, and Python activation. |
| Task launch data | [`crates/task/src/task.rs#L42`](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/task/src/task.rs#L42) | `SpawnInTerminal` task contract and display policy. |
| Shell rules | [`crates/util/src/shell.rs`](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/util/src/shell.rs) | Shell kinds, quoting rules, separators, and control commands. |
| Shell command builder | [`crates/util/src/shell_builder.rs`](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/util/src/shell_builder.rs) | Converts task commands into platform shell commands. |
| Pinned parser and emulator | [`alacritty_terminal/src/term/mod.rs`](https://github.com/zed-industries/alacritty/blob/4c129667ce56611becdc82de6e28218c80e2e88f/alacritty_terminal/src/term/mod.rs) | VTE handler, grid, scrollback, modes, cursor, colors, OSC, and selection. |
| Unix PTY | [`alacritty_terminal/src/tty/unix.rs`](https://github.com/zed-industries/alacritty/blob/4c129667ce56611becdc82de6e28218c80e2e88f/alacritty_terminal/src/tty/unix.rs) | `openpty`, session creation, controlling terminal, signal reset, resize, exit, and cleanup. |
| Windows PTY | [`alacritty_terminal/src/tty/windows/conpty.rs`](https://github.com/zed-industries/alacritty/blob/4c129667ce56611becdc82de6e28218c80e2e88f/alacritty_terminal/src/tty/windows/conpty.rs) | ConPTY creation, process attributes, pipes, resize, exit watcher, and cleanup. |

## Behavior matrix

| Concern | Zed behavior | Assessment for Anvil |
|---|---|---|
| Emulator | Uses pinned `alacritty_terminal`. Zed wraps backend types behind terminal-domain types. | Keep Ghostty. Copy the boundary, not the backend. |
| Parser | Alacritty feeds bytes into `vte::ansi::Processor`. Display-only output also uses VTE parsing. | Keep one parser path for PTY and injected output. |
| Unix PTY | Uses `openpty`, `setsid`, `TIOCSCTTY`, signal reset, nonblocking I/O, and `TIOCSWINSZ`. | Adopt only when Anvil adds Unix support. Use a proven library. |
| Windows PTY | Uses Alacritty's ConPTY code and child exit watcher. | Keep Anvil's existing ConPTY owner. Do not add a second PTY layer. |
| Model ownership | One `Terminal` owns emulator state, live PTY resources, process data, and task completion. | Strong pattern. Keep one native owner per Terminal View. |
| Fallible creation | `TerminalBuilder::new` creates resources before `subscribe` creates the GPUI entity. | Keep fallible creation outside view construction where practical. |
| Output notification | PTY parsing happens off the UI path. `Wakeup` tells GPUI to sync and repaint. | Strong pattern. Anvil's `terminaloutput` event follows it. |
| Event pressure | Events batch for four milliseconds and cap each drain at 100 events. Wakeups collapse. | Keep coalescing. Prefer Anvil's bounded byte queues. |
| Key input | A manual mapper handles controls, cursor modes, function keys, and modifiers. IME handles text. | Keep Ghostty's key encoder. Do not copy Zed's protocol table. |
| IME | Marked text appears at the terminal cursor. Committed text goes to the PTY. | Adopt candidate placement and pre-edit rendering tests. |
| Paste | Bracketed paste strips escape bytes. Normal paste converts newlines to carriage returns. | Required behavior. Verify Ghostty covers both cases. |
| Clipboard images | Image paste sends raw `Ctrl+V` for terminal tools that read the system clipboard. | Useful optional behavior. Keep it outside the core model. |
| Dropped paths | Zed quotes paths, inserts spaces, focuses the terminal, then pastes them. | Useful. Use shell-aware Windows quoting, not POSIX-only quoting. |
| Focus reports | Zed sends focus-in and focus-out sequences when the terminal requests them. | Required for full-screen applications. |
| Mouse reports | Supports click, drag, motion, normal, UTF-8, and SGR reports. Shift bypasses mouse mode. | Required. Keep encoder logic in Ghostty. |
| Link clicks in mouse mode | Zed captures the full press-to-release gesture before opening a link. | Adopt this gesture rule. Never leak a partial gesture to the PTY. |
| Selection | Single click selects cells. Double click selects semantic words. Triple click selects lines. | Good default if Ghostty supports these gestures. |
| Selection jitter | A two-pixel threshold prevents a focus click from starting selection. | High-value small fix. Verify Anvil has an equivalent threshold. |
| Selection drag | Dragging beyond bounds scrolls by up to three lines per update. Alternate screen does not scroll. | Useful behavior. Anvil already has selection autoscroll. |
| Linux primary selection | Selection updates the primary clipboard. Middle click pastes it. | Defer until Unix support. |
| Copy policy | Supports copy-on-select and optional selection clearing after copy. | Optional preference. Not required for the first robust model. |
| Search | Uses the common search bar. Regex runs on the full retained grid in a background task. | Anvil already has terminal search. Keep bounded search steps. |
| Match invalidation | Every terminal wakeup invalidates matches. Resize also invalidates match positions. | Adopt explicit invalidation. Avoid stale highlights after reflow. |
| OSC 8 links | Uses hyperlinks stored on Alacritty cells. | Anvil already opens emulator hyperlinks. Keep this path first. |
| URL links | Uses a fixed URL regex and trims sentence punctuation. | Useful second link source. Keep the scheme list small. |
| Path links | Uses ordered configurable regexes, time limits, path resolution, and per-line directories. | Useful, but too large for the first pass. Add fixed formats later. |
| Current directory | Polls the local foreground process and stores directory changes by command boundary. | Do not copy. Prefer Ghostty's OSC 7 `pwd` data. |
| Remote directory | Zed returns no current directory for remote terminals. | Anvil can avoid this gap through shell-reported OSC 7 data. |
| Shell environment | Adds `ZED_TERM`, `TERM_PROGRAM`, `TERM`, `COLORTERM`, and version data. | Set only environment values that have clear compatibility value. |
| Project environment | Resolves directory environment data before terminal creation. Project settings can extend it. | Useful if Anvil later adds project environment providers. |
| Python environments | Finds the selected toolchain and sends activation commands before shell use. | Defer. Keep toolchain activation outside the terminal core. |
| Startup command | Uses a shell-specific marker handshake before an automatic initial command. | Avoid unless Anvil has a concrete automatic-command use case. |
| Resize | Resizes only when rows, columns, or cell metrics change. It replaces pending resize events. | Strong pattern. Anvil already compares geometry before resize. |
| Geometry | Clamps to at least one row and two columns. It handles float precision and device pixels. | Keep explicit clamps and geometry tests. |
| Scrollback | Interactive default is 10,000 lines. Maximum is 100,000. Tasks receive the maximum. | Keep one bounded setting. Avoid different limits without a need. |
| Rendering | Batches adjacent cells with equal style. It merges background areas. | Useful if profiling shows draw-call pressure. |
| Partial visibility | Skips layout when fully clipped. It filters rows when partly clipped. | Strong pattern for Terminal Views inside scrollable parents. |
| Wide and zero-width text | Skips spacer cells and appends combining characters to shaped runs. | Required. Keep emulator cell semantics authoritative. |
| Block graphics | Paints block, quadrant, sextant, and shade characters as rectangles. | Heavy. Add only after a visible font problem. |
| Color contrast | Adjusts theme ANSI colors, but preserves application-selected exact colors. | Good rule. Avoid changing true-color application output. |
| Cursor | Supports block, bar, underline, hollow, hidden, blink, and terminal-controlled blink. | Keep emulator-controlled shape and blink state. |
| Bell | Marks the tab and can play the system bell. Input clears the tab bell. | Useful quality-of-life behavior. Anvil already flashes the window. |
| Title | Uses OSC titles, custom tab titles, foreground process data, and PID tooltips. | Keep OSC title. Defer process polling and PID UI. |
| Tasks | Tracks running, unknown, success, and failure. It supports rerun and hide policies. | Keep task state in a future task layer, not Terminal View. |
| Task stop | Kills the foreground process group and then the shell. | Strong lifecycle rule for task-owned shells. |
| Interactive exit | User-driven shell exit closes the item. Initial command failure remains visible. | Keep failures visible. Do not close before users can read them. |
| Close | Releases PTY resources once. Requests termination, then forces a kill after 100 ms. | Use an explicit, idempotent close state. Tune grace time from evidence. |
| Spawn failure | Opens a clear failure item with error details and settings actions. | High-value behavior. Anvil should not show only a transient message. |
| Tabs | Uses the shared `Pane` tab system. Tab icons show shell or task state. | Reuse Anvil's generic Pane and View system. |
| Splits | Uses a terminal-specific `PaneGroup` inside the terminal dock. | Do not copy. Anvil already has general Pane splits. |
| Center terminal | A Terminal View can also be a normal center item. | Anvil's normal View placement already gives this behavior. |
| Persistence | Saves shell item IDs, split tree, active item, pin count, working directory, and custom title. | Save launch recipes only. Do not imply live process restoration. |
| Task persistence | Task terminals are omitted from saved terminal state. | Good rule. Completed task output should use a separate durable model. |
| Scrollback persistence | Zed does not save emulator grid or scrollback. Restored items start new shells. | Good 90% rule. Anvil's Terminal Text Capture covers durable text. |
| Diagnostics | Logs spawn choice, PTY writes, resize, event work, link timeouts, layout, and paint timing. | Keep lifecycle and error logs. Avoid logging terminal input or every frame. |
| Accessibility | No terminal-specific accessible text tree was found in these crates. | Treat this as an open requirement, not a pattern to copy. |

## Detailed findings

### PTY, parser, and process boundary

Zed's `Terminal` does not read PTY bytes itself.
It delegates transport and parsing to Alacritty's `EventLoop`.

The event loop owns the platform PTY.
It handles partial reads, partial writes, polling, resize, shutdown, and child exit.
It feeds output bytes into the VTE processor under the terminal grid lock.

On Unix, the pinned fork creates a session and controlling terminal.
It restores the child signal mask and default signal actions.
This prevents background executor signal state from breaking `Ctrl+C`.

On Windows, the fork uses ConPTY.
It creates an extended process attribute list for the pseudo-console handle.
It uses a child watcher for exit notification.

Zed stores live PTY resources separately from retained process data.
`PtyResources::Released` prevents a second shutdown.
The view can retain output and status after resource release.

Zed also has a no-PTY path for headless hosts.
That path pumps piped stdout and stderr into the same emulator.
It converts bare line feeds to carriage-return line-feed pairs.
This preserves column alignment without a PTY line discipline.

Relevant sources:

- [Terminal builder and PTY creation](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/terminal.rs#L1080-L1400)
- [PTY options and adapter](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/alacritty.rs#L120-L215)
- [Headless subprocess path](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/terminal.rs#L3244-L3382)
- [Foreground process data](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/pty_info.rs#L76-L230)

**Lesson:** keep transport, emulator state, and child ownership in one native session.

**Do not copy:** Anvil does not need Zed's Alacritty adapter or headless host path.

### Input, paste, focus, and mouse

Zed exposes backend-neutral mode bits to the view.
The view also adds these modes to its key dispatch context.
Keymaps can distinguish alternate screen, application cursor, mouse, and paste modes.

Key handling has two paths.
Mapped terminal keys write bytes directly.
Text and IME input enter through `InputHandler`.
This prevents editor text actions from changing terminal content.

Paste follows bracketed-paste mode.
Zed removes escape bytes from bracketed text.
This prevents pasted text from ending bracketed mode early.
Normal paste changes line endings to carriage returns.

Mouse handling gives terminal applications first-class protocol reports.
Shift disables mouse mode for local selection.
Link clicks capture the complete mouse gesture.
A failed link gesture does not send an unmatched release to the application.

Relevant sources:

- [Mode-aware key context](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal_view/src/terminal_view.rs#L993-L1075)
- [Key conversion](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/mappings/keys.rs#L1-L327)
- [Paste implementation](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/terminal.rs#L2401-L2410)
- [Mouse press and release](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/terminal.rs#L2647-L2800)
- [Mouse protocol mapping](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/mappings/mouse.rs)

**Lesson:** route input by emulator mode and input type.

**Do not copy:** Zed's manual key table duplicates protocol knowledge.
Ghostty already owns this knowledge for Anvil.

### Rendering

`Terminal::sync` creates a complete backend-neutral `Content` value.
It contains visible cells, modes, cursor, selection, history sizes, and bounds.

`TerminalElement` measures the font using the width of `m`.
It disables ligatures by default.
It snaps origins and heights to device pixels.
It anchors full output and alternate screens to the bottom.

Layout batches adjacent cells with equal text style.
It collects and merges non-default background areas.
It filters clipped rows before layout.

The paint order is stable:

1. terminal background
2. cell backgrounds
3. search and selection highlights
4. text runs
5. block graphics
6. IME marked text
7. cursor
8. embedded block and link tooltip

The custom block renderer improves seams in terminal graphics.
It also adds much code and a quadratic merge pass.
Anvil should require measured visual evidence before copying it.

Relevant sources:

- [Cell snapshot](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/alacritty.rs#L882-L936)
- [Grid layout and batching](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal_view/src/terminal_element.rs#L438-L628)
- [Color and style rules](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal_view/src/terminal_element.rs#L868-L960)
- [Visible-row filtering](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal_view/src/terminal_element.rs#L1407-L1485)
- [Paint order](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal_view/src/terminal_element.rs#L1603-L1780)

**Lesson:** clip before layout and batch compatible text.

**Risk:** Zed still copies all renderable cells into `Content` on each sync.
Anvil should keep snapshot reuse and measure changed-row work.

### Selection and clipboard

Zed delegates selection storage and text extraction to Alacritty.
It keeps only selection phase and head data in its model.

A single click starts simple selection.
A double click selects a semantic unit.
A triple click selects full lines.
Shift-click extends an existing selection.
Shift-drag also works while an application owns mouse input.

A two-pixel threshold separates click jitter from a drag.
This prevents copy-on-select from replacing the clipboard after a focus click.

Zed supports regular clipboard copy and paste.
Linux also uses the primary selection and middle-click paste.

Alacritty's default OSC 52 policy is `OnlyCopy`.
Zed therefore lets terminal applications write the system clipboard without a prompt.
Display-only terminals disable OSC 52.

Relevant sources:

- [Selection event processing](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/terminal.rs#L1746-L1830)
- [Selection gesture rules](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/terminal.rs#L2577-L2726)
- [Clipboard backend events](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/terminal.rs#L1645-L1667)
- [Alacritty terminal configuration](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/alacritty.rs#L120-L145)

**Lesson:** emulator-owned selection avoids duplicate cell rules.

**Do not copy:** retain Anvil's confirmation before OSC 52 changes the clipboard.

### Find

`TerminalView` implements Zed's common `SearchableItem` interface.
It supports regex search.
It does not expose case, word, replacement, selection-scope, or select-all options.

Plain text queries are regex-escaped.
Search scans the full retained grid in a background task.
Activating a match selects it and scrolls it into view.

Every `Wakeup` invalidates matches.
A width change also requests match recalculation because reflow changes points.

Relevant sources:

- [Searchable item integration](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal_view/src/terminal_view.rs#L1960-L2120)
- [Backend regex scan](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/alacritty.rs#L1091-L1106)
- [Search invalidation](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal_view/src/terminal_view.rs#L1117-L1142)

**Lesson:** integrate terminal find with the normal View search surface.

**Anvil status:** Anvil already has incremental native terminal search.
Its benchmark sets a 50-millisecond responsiveness limit.

### Links and file navigation

Zed supports three link sources:

1. OSC 8 links attached to emulator cells
2. fixed URL scheme matching
3. configurable path regexes

Link hover requires the platform secondary modifier.
Zed throttles repeated link searches by movement and time.
It trims common sentence punctuation from detected URLs.

Path regexes can name `path`, `line`, `column`, and `link` captures.
A configured timeout stops work between regexes.
Invalid regexes produce warnings.

Path targets use a working directory for relative resolution.
Zed records local directory changes against scrollback command boundaries.
This lets an old output line resolve against its historical directory.

The view resolves candidate paths before showing a tooltip.
A click resolves again before opening the target.
The resolver handles worktrees, remote paths, and line positions.

Relevant sources:

- [Link search and normalization](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/alacritty/hyperlinks.rs#L22-L219)
- [Path regex processing](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/alacritty/hyperlinks.rs#L315-L480)
- [Historical directory selection](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/terminal.rs#L2918-L2966)
- [Path target resolution](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal_view/src/terminal_path_like_target.rs#L38-L157)

**Lesson:** validate a file target before presenting it as openable.

**Do not copy:** the historical-directory model is complex.
Anvil already gets `pwd` data from its Ghostty snapshot.
Use that source before adding process polling.

### Shell and remote integration

Zed selects the starting directory from current-file, current-project, first-project, home, or fixed-directory settings.
Remote terminals do not apply local home expansion or local directory checks.

Local shells use terminal settings.
Remote shells use the remote client's interactive command builder.
Users can also open a local shell from a remote project.

Zed adds these environment values:

- `ZED_TERM=true`
- `TERM_PROGRAM=zed`
- `TERM=xterm-256color`
- `COLORTERM=truecolor`
- `TERM_PROGRAM_VERSION=<version>`

Zed removes inherited `SHLVL`.
It adds `LANG=en_US.UTF-8` only when the parent has no locale.

Project environment settings can extend the shell environment.
Python toolchain detection can create activation commands.
Zed runs those commands before an interactive prompt becomes ready.

Zed does not inject broad shell integration scripts.
It infers local current-directory changes from foreground process data.
It cannot reliably infer the current directory on a remote host.

Relevant sources:

- [Working-directory policy](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal_view/src/terminal_view.rs#L2123-L2171)
- [Environment and shell setup](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/terminal.rs#L1080-L1215)
- [Project shell and environment work](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/project/src/terminals.rs#L284-L451)
- [Remote command creation](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/project/src/terminals.rs#L605-L641)

**Lesson:** keep shell policy above the terminal session.

**Do not copy:** do not put toolchain activation inside Anvil's native terminal owner.

### Tabs, panes, tasks, and focus

A Terminal View is a normal workspace item.
It can open in the center like an Editor.
It can also appear inside a docked `TerminalPanel`.

The panel uses shared `Pane` items for tabs.
It adds its own nested `PaneGroup` for terminal splits.
A split clones an interactive shell near the old current directory.
It does not clone a running task.

Task terminals support reuse, concurrency, reveal policy, rerun, success state, and hide policy.
The tab icon reflects task state.

Terminal creation avoids taking focus from an active modal.
Several tests cover this rule for center, panel, task, and restore paths.

Relevant sources:

- [Center terminal creation](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal_view/src/terminal_panel.rs#L835-L879)
- [Terminal pane split](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal_view/src/terminal_panel.rs#L428-L605)
- [Task placement and reuse](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal_view/src/terminal_panel.rs#L640-L833)
- [Normal workspace `Item`](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal_view/src/terminal_view.rs#L1440-L1847)

**Lesson:** a Terminal View should use normal View and Pane contracts.

**Do not copy:** Anvil does not need a nested terminal-only pane tree.

### Persistence

Zed stores terminal panel structure as JSON in its key-value store.
The tree contains split axes, flex values, pane tabs, active tabs, and pin counts.

Per-item SQLite data stores the working directory and custom title.
Task terminals do not enter saved state.
Terminal scrollback and process state do not enter saved state.

Deserialization creates a new shell for each saved item.
Missing or failed items are omitted.
An empty restored split receives a new default shell.

Restoration also merges terminals opened while restoration was in progress.
This behavior requires substantial race and focus handling.

Relevant sources:

- [Panel tree serialization](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal_view/src/persistence.rs#L27-L88)
- [Panel restoration](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal_view/src/persistence.rs#L90-L344)
- [Per-item persistence](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal_view/src/terminal_view.rs#L1849-L1957)
- [SQLite schema](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal_view/src/persistence.rs#L410-L543)

**Lesson:** persist the launch recipe and ordinary View placement.

**Do not copy:** Anvil's Workspace should own Pane topology.
A Terminal View should not own a second database model.

### Failure handling and lifecycle

PTY creation errors include the requested directory, shell, arguments, title override, and I/O cause.
The panel creates a focused failure item rather than losing the error.
That item offers direct settings actions.

The model keeps task output after process exit.
Task completion adds a short summary and command label when requested.
An unsafe Alacritty helper appends this summary after PTY exit.

The `Terminal` destructor is the last ownership guard.
Project terminal registries use weak handles.
Release observers remove dead entries.

The Alacritty event loop logs read and write errors before exit.
Linux PTY `EIO` receives special handling until the child-exit event arrives.

Relevant sources:

- [Structured spawn error](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/terminal.rs#L833-L893)
- [Failure item](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal_view/src/terminal_panel.rs#L932-L1048)
- [Failure item rendering](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal_view/src/terminal_panel.rs#L1395-L1469)
- [Project weak-handle ownership](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/project/src/terminals.rs#L250-L282)

**Lesson:** failures must remain visible in the failed View location.

**Risk:** appending task summaries uses an explicitly unsafe, partially synchronized emulator path.
Anvil should keep task summaries outside emulator internals.

### Diagnostics

Zed emits useful logs for these events:

- selected shell
- remote command creation
- PTY resize and shutdown failures
- invalid or slow path regexes
- process output read failures
- process status failures
- panel restore time
- saved terminal directories and titles
- terminal layout and paint timing

Zed also logs every PTY write at debug level.
This can expose commands, tokens, passwords, and pasted data.
Anvil should not copy this behavior.

Zed logs layout and paint timing on each call at debug level.
This can create noise and add cost during heavy output.
Anvil should keep opt-in performance counters instead.

Relevant sources:

- [PTY input logging](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/terminal.rs#L2112-L2128)
- [Path-regex diagnostics](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/alacritty/hyperlinks.rs#L56-L79)
- [Layout timing](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal_view/src/terminal_element.rs#L608-L627)
- [Paint timing](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal_view/src/terminal_element.rs#L1769-L1779)

### Accessibility

No terminal-specific accessible text model appears in `terminal` or `terminal_view`.
`TerminalElement` implements input and paint interfaces, but no accessible row or text interface.

IME cursor placement is implemented.
This is not a screen-reader text model.

This gap matters for any later Anvil accessibility plan.
A future design needs a stable text snapshot, caret, selection, and change events.

## Test audit

The inspected Zed terminal and terminal-view sources contain 197 Rust test attributes.
The tests span unit, GPUI, visual, integration, and performance layers.

Strong test areas include:

- key and modifier escape sequences
- application cursor mode
- mouse report formats
- bracketed input paths
- real PTY completion on supported Unix hosts
- headless piped-output handling
- task stop and completion
- resize coalescing and float precision
- click jitter and deliberate drag
- Shift selection during mouse tracking
- link gesture capture
- URL punctuation and path formats
- wide-character link coordinates
- current-directory history
- process map resource bounds
- normal-screen and alternate-screen key routing
- edit-menu copy and paste
- path drops and shell quoting
- working-directory selection
- render layout and device-pixel anchoring
- block graphics and contrast rules
- spawn failure UI
- pending spawn cancellation
- panel restoration races
- modal focus preservation

Representative tests:

- [Terminal model tests](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/terminal.rs#L3580-L5933)
- [Hyperlink tests](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/alacritty/hyperlinks.rs#L493-L1981)
- [Renderer tests](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal_view/src/terminal_element.rs#L2033-L3004)
- [Terminal View tests](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal_view/src/terminal_view.rs#L2174-L3278)
- [Panel tests](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal_view/src/terminal_panel.rs#L1870-L3369)
- [Process resource regression test](https://github.com/zed-industries/zed/blob/1662f5f3f6497c5f80830ccdca1edfd1fc0c6c6a/crates/terminal/src/pty_info.rs#L240-L289)

Test gaps remain:

- No Zed-layer end-to-end ConPTY GUI test appears in these crates.
- No screen-reader or accessible-text test appears.
- No explicit secret-redaction test covers PTY input logs.
- Persistence tests focus on panel races, not user-facing restore explanations.
- Full cell snapshot cost receives less direct coverage than link and panel behavior.

## Anvil baseline

Anvil already has the correct small architecture.
It should improve that architecture rather than replace it.

Current relevant files are:

- `src/api/terminal_native.c`
- `data/plugins/terminal.lua`
- `tests/lua/runtime/terminal_native.lua`
- `tests/lua/ui/terminal.lua`
- `tests/lua/benchmarks/terminal.lua`

Current Anvil strengths already match or exceed useful Zed patterns:

- Ghostty owns parser, emulator state, key encoding, mouse encoding, and selection gestures.
- One native session owns ConPTY, process handles, worker threads, queues, and render state.
- Native read and write queues have four-megabyte limits.
- The native layer coalesces output notifications.
- Lua resizes only after rows, columns, or cell metrics change.
- Terminal View uses the normal Pane and Workspace model.
- Terminal state persists only shell and working-directory launch data.
- Search is incremental and has a responsiveness benchmark.
- OSC clipboard changes require user confirmation.
- Bell and notification events remain visible.
- `Terminal Text Capture` provides durable text without pretending to restore a live process.

These local strengths change the adoption decision.
Most Zed architecture should remain reference material only.

## Useful patterns to adopt

### 1. Keep explicit lifecycle states

The native session should have clear states for running, exited, closing, and closed.
Every close path should be safe to call more than once.

Retain process exit data after transport release.
Keep the last render snapshot available after exit.

### 2. Treat mouse gestures as transactions

A click owned by link handling must stay outside PTY mouse reports.
A click owned by the PTY must send a complete press and release pair.

Add a small drag threshold before selection starts.
Test focus-click jitter and mouse-tracking applications.

### 3. Invalidate derived data after reflow

Search matches, hover ranges, and selection display points can change after width changes.
Use one explicit invalidation event after terminal reflow.

### 4. Keep failed Terminal Views visible

Creation failure should leave a focused error View in the requested Pane.
Show the directory, command, and native error.
Offer a restart action and settings action.

Do not show only a transient error message.

### 5. Clip before expensive layout

Skip snapshots or row shaping for fully hidden Terminal Views where possible.
For partial visibility, process only visible rows plus one safety row.

Measure this before adding complex caches.

### 6. Keep persistence semantics narrow

Persist the shell command, starting directory, optional custom title, and ordinary View placement.
Create a new shell during restore.

Never call this live terminal restoration.
Do not save emulator grids by default.

### 7. Use fixed path-link formats first

Start with OSC 8 links.
Then add a small fixed set for `path:line:column` and common traceback output.

Resolve the path before showing the open cursor.
Use the emulator-reported current directory.

### 8. Add focused regression tests

Use Anvil's public View and native-session seams.
Test visible behavior, not Ghostty internals.

The highest-value cases are:

- spawn failure remains visible
- close releases workers and process handles once
- resize ignores pixel-only changes
- resize updates both emulator and ConPTY geometry
- bracketed paste cannot inject its end marker
- Shift selection bypasses mouse tracking
- link gesture never leaks a partial PTY gesture
- search invalidates after reflow
- exited output remains readable
- OSC clipboard requests still require approval

## Heavy machinery Anvil should not copy

### Terminal-specific panel and split persistence

Zed's panel owns tabs, split panes, focus, tasks, restoration, and a second persistence layer.
Anvil already has general Panes and Workspace restoration.

Use those shared systems.
Do not create `TerminalPanel` or `TerminalPaneGroup` types.

### Alacritty domain adapter

Zed needs an adapter because its UI is Rust and its emulator is a separate Rust crate.
Anvil's native Ghostty API already returns terminal snapshots and events.

Do not add another domain object for every cell, point, range, mode, and cursor.

### Hand-written key and mouse maps

These tables duplicate terminal protocol details.
They need continued updates for new keyboard protocols and platform rules.

Keep Ghostty's encoders authoritative.

### Foreground-process polling

Zed uses `sysinfo`, PTY foreground groups, process caches, and resource safeguards.
This exists mainly for title and current-directory data.

Anvil already receives terminal `pwd` data.
Do not add process polling for this purpose.

### Configurable path-regex engine

Zed's path logic includes custom captures, wide-cell mapping, punctuation fixes, timeouts, and many resolver cases.
This is valuable for a large product.
It is not a 90% requirement for Anvil.

### Vi terminal mode

Alacritty provides much of Zed's vi mode.
The view still needs actions, selection state, and routing.

Anvil already has `Terminal Text Capture` for stable text navigation.
Use that smaller model.

### Task terminal framework

Zed combines Terminal View with task reuse, concurrency, reveal, rerun, hide, summaries, and status icons.
This is a separate task product.

Do not put task policy in Terminal View.
A future task runner can use Terminal View as one output target.

### Custom block painting

Zed's subcell renderer fixes visible seams for special glyphs.
It adds a large mapping and merge system.

Do not add it without a repeatable visual defect in Anvil.

### AI blocks and embedded terminal modes

Zed supports inline blocks under the cursor and large embedded terminal layouts.
These features add special scrolling, clipping, and focus rules.

They are outside Anvil's Terminal View requirement.

## Gaps and risks in Zed

### Security

Normal PTY terminals accept OSC 52 clipboard writes without confirmation.
An untrusted remote command can replace clipboard text.

Debug logs can include every byte written to the PTY.
This can expose secrets and pasted data.

Anvil's current clipboard confirmation is safer.
Anvil should also avoid input-content logging.

### Accessibility

The audited crates expose no terminal-specific accessible text tree.
IME support does not solve screen-reader access.

Anvil needs a separate accessibility design when its platform layer supports one.

### Resource pressure

Zed uses unbounded GPUI event channels.
It reduces normal pressure through wakeup collapsing and event batching.
A bounded contract would give stronger failure behavior.

The view copies all renderable cells into `Content` during sync.
It then performs layout on visible cells.
Large grids can still create snapshot cost.

### Process polling races

Foreground process data can become stale between lookup and action.
PID reuse and process-group changes make termination logic sensitive.
The code includes several safeguards because this boundary is hard.

### Remote current directory

Zed does not know the remote shell's current directory.
Relative links and restored directories therefore have weaker behavior remotely.

### Persistence meaning

The UI restores tabs that look like prior terminals.
Each restored item is a new shell.
Users can mistake this for process restoration without clear wording.

### Renderer coupling

`TerminalElement::prepaint` resizes and synchronizes the model.
A source comment already says some work should move out of render.
This coupling can make frame behavior difficult to reason about.

### Unsafe task summary append

Task summaries bypass normal PTY parsing after exit.
The helper documents incomplete grid synchronization.
This is fragile and should not be copied.

### Test platform coverage

The source has broad model and GPUI tests.
The audited crates show no direct end-to-end Windows ConPTY GUI test.
Anvil's existing Windows-native tests and benchmark are important.

### Documentation drift

`terminal_view/README.md` still mentions a `modal.rs` file that is absent.
The source map is more reliable than that design note.

## Smallest robust 90% model for Anvil

Keep this model:

```text
Generic Pane and Workspace
          |
          v
TerminalView in Lua
  - input and focus routing
  - draw native snapshots
  - clipboard approval
  - search prompt
  - launch recipe state
          |
          v
One native TerminalSession
  - ConPTY and child process owner
  - bounded read and write queues
  - Ghostty terminal, key, mouse, selection, search
  - typed status and terminal events
  - idempotent close
```

The model needs no terminal-specific panel.
It needs no second emulator abstraction.
It needs no process scanner.
It needs no terminal-specific database.

A robust 90% feature set is:

- PowerShell or configured shell launch
- project or active-buffer starting directory
- text, key, IME, paste, focus, mouse, and resize input
- color, style, cursor, selection, scrollbar, and scrollback rendering
- copy, paste, search, bell, OSC 8 links, and Terminal Text Capture
- visible exit and failure state
- duplicate and restart actions
- Workspace launch-recipe persistence
- bounded transport and diagnostic status
- focused runtime, UI, and native tests

Everything else should wait for a concrete use case.

## Prioritized recommendations

### P0: preserve and harden the current owner boundary

1. Keep Ghostty as the only emulator and protocol encoder.
2. Keep ConPTY and all child handles inside one native session.
3. Verify every close path is idempotent.
4. Keep bounded I/O queues and coalesced output wakeups.
5. Preserve the last snapshot and exit status after process exit.
6. Never log terminal input contents.
7. Keep OSC clipboard approval.

### P0: add lifecycle and gesture regressions

1. Test a failed shell launch through the Terminal View seam.
2. Test close during blocked read and blocked write states.
3. Test repeated close and restart calls.
4. Test focus-click jitter before selection starts.
5. Test Shift selection while mouse reporting is active.
6. Test that link handling consumes a complete gesture.
7. Test search invalidation after width reflow.

### P1: improve visible failure and exit behavior

1. Keep a failed Terminal View in the requested Pane.
2. Show shell, directory, and native error in that View.
3. Add restart and settings actions.
4. Keep exited output readable.
5. Show exit state in the View title without adding task machinery.

### P1: add small file-link support

1. Keep OSC 8 as the first link source.
2. Add fixed `path:line` and `path:line:column` formats.
3. Use Ghostty's `pwd` value for relative paths.
4. Resolve a path before showing it as clickable.
5. Do not add user regex settings yet.

### P1: keep rendering work bounded

1. Skip row work when the Terminal View is fully clipped.
2. Shape only visible rows for partial clipping.
3. Keep current snapshot reuse.
4. Add more batching only after profiling shows a bottleneck.

### P2: optional quality-of-life work

1. Add an optional custom terminal title.
2. Quote dropped paths for the configured Windows shell.
3. Add image-paste forwarding only for a proven terminal workflow.
4. Add Unix PTY support only when Anvil's platform scope expands.
5. Define an accessible text snapshot when platform accessibility work begins.

### Do not plan now

- terminal-only docks
- terminal-only split trees
- live process persistence
- saved scrollback grids
- foreground process polling
- vi terminal mode
- configurable path regexes
- Python environment activation
- task reuse and hide policies
- AI blocks in terminal layout
- Alacritty integration

## Final assessment

Zed is a strong behavior reference.
It is not a suitable architecture template for Anvil as a whole.

Its core lesson is simple.
Let a proven emulator own terminal semantics.
Let one session own the PTY and child.
Let the normal View system own placement and persistence.

Anvil already follows this model.
The best next work is targeted hardening, not architectural expansion.
