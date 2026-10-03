# Phase 2: Terminal Session processes

This is the implementation plan for Phase 2 of
[the multiprocess shell plan](MULTIPROCESS_SHELL_PLAN.md). Read that plan first,
especially "Terminal Sessions", "Session registry", and "IPC".

Status: Milestone 1 is implemented. Milestones 2 to 4 have not started.
Phases 0 and 1 are done.

Formatter check: `anvil:terminal-replay` failed with the requested VT extras.
Primary replay added leading spaces. Alternate replay restored the active screen,
but lost the primary screen and its scrollback. `screen.h` has no separate screen
formatter. `snapshot.h` has a binary codec, not a separate primary VT formatter.
Raw replay from byte zero passed the row text, cursor, scrollback, and screen checks.
Use a bounded raw prefix. Never replay a prefix after it exceeds its bound.

## Goal

Each terminal's ConPTY and shell run in a Terminal Session process. The editor
attaches to it over a named pipe. A crash or restart of the editor must not end
the shell. After a restart, the editor reattaches and shows the same screen and
scrollback. A Terminal Session that died is revived from its last snapshot.

The editor's terminal model, rendering, selection, search, and input encoding stay
where they are. Only the byte transport changes.

## Current design

- `src/api/terminal_native.c` (3,500 lines) is the Lua module `terminal_native`.
  `native.new(options)` creates a `TerminalSession` userdata. It owns:
  - the ConPTY (`create_pseudoconsole`, `create_shell_process`,
    `terminal_environment`, `create_kill_job`);
  - a reader thread (`terminal_reader_main`) that fills `read_queue` from
    `output_read`, and a writer thread (`terminal_writer_main`) that drains
    `write_queue` into `input_write`;
  - the Ghostty terminal model and render state;
  - process exit and draining in `f_terminal_update`.
- `f_terminal_update` moves bytes from `read_queue` into
  `ghostty_terminal_vt_write`, publishes render state, and runs the state machine
  `running -> draining -> exited` or `failed`.
- The Ghostty model answers terminal queries by writing to the PTY through the
  `terminal_write_pty` callback.
- `data/plugins/terminal.lua` holds `TerminalView`. `create_session()` calls
  `native.new`. `get_state()` saves only `{ cwd, shell }`, and `from_state` starts a
  new shell. `on_close()` calls `session:close()`, which kills the shell through
  the kill job.
- The shell mode in `src/anvil_shell.c` puts its child in a job with
  `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`.

## Target design

```text
editor process (anvil.exe)                     Terminal Session process
TerminalView (Lua)                             anvil.exe --terminal-session ...
  terminal_native TerminalSession                ConPTY + shell (kill job)
    Ghostty model, render state   <-- pipe -->   Ghostty model (replay only)
    reader/writer threads                        registry record, snapshots
```

- The Terminal Session process is the pipe server. It outlives its clients.
- One client at a time. The pipe has one instance.
- The host keeps its own Ghostty model only to replay state when a client
  attaches and to write snapshots. The host model never answers queries; it has
  no `write_pty` callback. The attached editor's model answers them, as it does
  today. While no client is attached, queries go unanswered. Note this in the
  code. ConPTY answers DSR cursor-position reports itself.
- The editor has a single transport: the Terminal Session process. Remove the
  in-process ConPTY path from `terminal_native.c` rather than keep both. The
  module is already Windows-only.

## Code layout

Clean refactors only, per AGENTS.md. Suggested files:

- `src/ipc_pipe.c/.h`: generalize the overlapped pipe helpers from
  `src/surface_protocol.c` (`AnvilSurfacePipe`, `anvil_surface_pipe_read/write`).
  The header type, size, and version checks become parameters. Update the shell and
  hosted surface code to use it. Do not leave a copy behind.
- `src/terminal_protocol.h`: message types and payload structs.
- `src/conpty.c/.h`: ConPTY creation, the shell process, the environment, and the
  kill job, moved out of `terminal_native.c`.
- `src/terminal_model.c/.h`: Ghostty terminal creation with Anvil's options,
  including the semantic prompt patch option and the scrollback limit. Both the
  editor and the host must create models the same way.
- `src/terminal_host.c/.h`: the Terminal Session process.
- `src/api/terminal_native.c`: the client transport. The Lua API stays.

Add the new files to `src/meson.build` next to `api/terminal_native.c`.
`drop_events_test` and other native tests may need the shared files added.

## Process launch

- Mode: `anvil.exe --terminal-session` with arguments for the session ID, the pipe
  name, `USERDIR`, the shell, the cwd, cols and rows, the scrollback limit, and an
  optional `--revive-from <snapshot>`.
- Dispatch it in `src/main.c` like `shell_mode`, before any SDL or Lua setup.
  Skip single-instance forwarding and the IPC server. The host never creates a
  window. Run its loop from `AppInit` and end the process with the shell's exit
  status, or give it its own `main` path. Keep SDL out of the host if practical.
- The editor generates the session ID (128 random bits, hex) and the pipe name
  `\\.\pipe\anvil-terminal-<id>`.
- The host creates the pipe with `FILE_FLAG_FIRST_PIPE_INSTANCE`,
  `PIPE_REJECT_REMOTE_CLIENTS`, and one instance.
- The editor connects with `WaitNamedPipe` retries up to about 5 s. It opens with
  `SECURITY_IDENTIFICATION` and checks `GetNamedPipeServerProcessId` against the
  PID it started, or the PID in the registry record when it reattaches.
- Start the host with `CREATE_BREAKAWAY_FROM_JOB | CREATE_NO_WINDOW` and
  `bInheritHandles = FALSE`. If breakaway fails with `ERROR_ACCESS_DENIED`,
  retry without it and log the fallback quietly. That host then ends with the job.
- Add `JOB_OBJECT_LIMIT_BREAKAWAY_OK` to the job in `src/anvil_shell.c`.
- The shell stays in the host's kill job, so ending the host ends the shell.
- Logging: the host appends to `USERDIR/logs/terminal-session-<id>.log` with the
  PID and timestamps. Record start, attach, detach, exit, revival, and failures.

## Protocol

Length-prefixed binary records with `{ size, type, version }`, like the surface
protocol. Use a separate version constant. Bound every payload. Suggested types:

Editor to host:

- `HELLO { session_id, cols, rows, cell_width, cell_height }`: first message.
  The host checks the session ID.
- `INPUT bytes`
- `RESIZE { cols, rows, cell_width, cell_height }`
- `CLOSE`: end the shell and the session. The host deletes its registry record
  and snapshot.
- `DETACH`: the editor is leaving on purpose; the session keeps running.

Host to editor:

- `WELCOME { host_pid, shell_pid, state }`
- `REPLAY bytes`: VT state from the formatter, possibly in several chunks, then
  `REPLAY_END`. Sent once after `WELCOME`, before any `OUTPUT`.
- `OUTPUT bytes`: raw ConPTY output, in order.
- `STATUS { busy, ... }`: from Milestone 3.
- `EXITED { exit_code }`: after the host drained the remaining ConPTY output.

The editor's writer queue holds framed records, so `INPUT` and `RESIZE` stay in
order. `f_terminal_resize` enqueues `RESIZE` instead of calling
`ResizePseudoConsole`.

The editor's reader thread unpacks `REPLAY` and `OUTPUT` into the existing
`read_queue`. `f_terminal_update` stays almost unchanged. Replace
`process_running()` with the host's `EXITED` flag. The host drains ConPTY, so the
editor's draining only empties its own queue.

A pipe that breaks without `EXITED` means the host died. Move to `failed` with
"The Terminal Session process ended unexpectedly", until Milestone 4 adds revival.

## Host internals

- Threads: one reads ConPTY output, one serves the pipe, one writes to the client.
  A lock protects the host model and the client queue.
- Every ConPTY read goes into the host model, then into the client queue if a
  client is attached.
- The client queue is bounded, for example to 8 MB. If a client falls behind,
  disconnect it instead of blocking ConPTY reads. A stalled shell is worse. The
  editor reconnects and gets a replay.
- On attach: apply the client's size to ConPTY and the host model, then build
  the replay under the lock, send it, and only then stream new output.
- When the shell exits, drain ConPTY output (the same quiet and maximum
  timings as `TERMINAL_DRAIN_QUIET_MS` and `TERMINAL_DRAIN_MAX_MS`) and send
  `EXITED`. Then wait for the client to disconnect, up to a few seconds. Delete the
  registry record and exit.

## Replay with the Ghostty formatter

This is the biggest risk, so verify it first, before any other Phase 2 work.

- `ghostty/vt/formatter.h`: `ghostty_formatter_terminal_new`, then
  `ghostty_formatter_format_alloc`, with the VT format and these extras: `palette`,
  `modes`, `scrolling_region`, `tabstops`, `pwd`, `keyboard`, and screen `cursor`,
  `style`, `hyperlink`, `kitty_keyboard`, and `charsets`.
- The formatter formats the active screen. Check whether that includes primary
  scrollback, and what happens when the alternate screen is active. Also look at
  `snapshot.h` and `screen.h` for a way to format the primary screen separately.
- Goal: the replay rebuilds the primary scrollback, then enters the alternate screen
  (`CSI ? 1049 h`) and draws it when it was active, then restores modes and the
  cursor.
- If the formatter can't do this, fall back to a bounded raw-output ring that is
  replayed from session start while it fits. Replaying raw output from the middle
  of a stream is not acceptable.
- Write a native or Lua test: feed known VT into model A, format it, feed the result
  into an empty model B, then compare row text, the cursor, scrollback length, and
  the alternate-screen flag.

## Milestones

Each milestone ends with focused tests, a commit, and the dev build updated with
`update-anvil-dev-build.bat`. Follow the red-green rules in AGENTS.md.

### Milestone 1: the session process and attach

Implemented: the native host owns ConPTY, the shell job, and a replay model.
The editor uses framed pipe transport. Both models use the shared model options.
The host checks the client PID and session ID. The editor checks the server PID.
Every disconnect ends the host and shell. There is no registry or reattach yet.
An oversized raw prefix becomes unavailable; it never becomes a suffix replay.

Focused checks on 2026-10-03:

- `ui/terminal.lua`: 66 passed, including the new host termination test.
  Before implementation, that test failed because the session had no host PID.
- `ui/terminal_contrast.lua`: 14 passed.
- `runtime/terminal_native.lua`: 27 passed; WSL skipped because no distribution was available.
  Its drain test exposed a skipped `draining` status. It passed after fixing that transition.
- `anvil:terminal-replay`: passed. Disabling prefix overflow rejection made the test fail.
  Restoring rejection made it pass. Formatter results remain diagnostic, not a success claim.
- Hosted surface input: eight samples passed on each renderer after the shared pipe refactor.
- Lua syntax checks passed for the changed Lua files.

`terminal-native-perf` passed before and after. The typing check uses 80 echoes.
It measures queued input through the parsed screen, not display scanout.
The final measurement polls echoes without a sleep delay.
For that baseline, the original native transport came from commit `362fd5f3`.
The Milestone 1 transport was restored before the after measurement.

| Measurement | Before | After |
| --- | ---: | ---: |
| Typing echo p50 | 15.571 ms | 15.533 ms |
| Typing echo p95 | 16.116 ms | 16.098 ms |
| Typing echo max | 16.568 ms | 16.475 ms |
| 20,000 output lines | 5,548.526 ms | 5,135.059 ms |
| Update p50 | 0.0079 ms | 0.0057 ms |
| Update p95 | 0.0287 ms | 0.0215 ms |
| Snapshot p50 | 0.2788 ms | 0.2566 ms |
| Snapshot p95 | 0.6018 ms | 0.4950 ms |
| Ten-session update total | 12.032 ms / 3,560 calls | 55.282 ms / 1,950 calls |

The echo p50 change is -0.038 ms, within the 1 ms budget.
Output and multi-session runs include process scheduling noise. They do not prove a speed increase.
The dev update BAT already ends every Anvil process, including hosts.
The standalone script uses a separate candidate executable and does not replace the dev executable.

- Do the refactors: `ipc_pipe`, `conpty`, `terminal_model`.
- Build the host, the protocol, and the client transport.
- The host ends when its client disconnects, with or without `DETACH`. Behavior
  matches today, with ConPTY out of process.
- Add `host_pid` and `shell_pid` to `session:stats()`.
- Tests:
  - the existing `tests/lua/ui/terminal.lua` (65 tests) must pass through the host;
  - a new test: ending the host process moves the view to `failed` with a message.
    Process ending is an external boundary, so a test helper may terminate the PID
    from `stats()`.
- Run the `terminal-native-perf` benchmark before and after, and record both. The
  budget is under 1 ms extra p50 for typing echo. If it's worse, profile the pipe
  hop before going on.

### Milestone 2: the registry and reattach

- The host writes `USERDIR/terminal-sessions/<id>.lua` (or JSON) with atomic
  replacement:
  - version;
  - session ID;
  - Project path;
  - host PID and the host's creation time from `GetProcessTimes` (this guards
    against PID reuse);
  - pipe name;
  - shell, cwd, and status;
  - snapshot path.
- The host keeps running after its client disconnects.
- `TerminalView:get_state()` adds `session_id`.
- `TerminalView.from_state` reattaches when:
  - the record exists;
  - the PID is alive with the same creation time;
  - the pipe server PID matches;
  - the `HELLO` session ID matches.

  Otherwise it starts a new shell in the saved cwd. Milestone 4 replaces this
  fallback with revival.
- Add `session:detach()`, which sends `DETACH` and releases the transport without
  killing.
- These now detach instead of close:
  - `core.restart` (reload);
  - same-window Project switch;
  - Workspace close on exit.

  Closing a terminal tab still closes it.
- Request a Workspace save on attach and detach with
  `core.request_workspace_save`, from Phase 1.
- Orphans: a host with no client and no busy shell exits after a grace period, for
  example 10 minutes. Before Milestone 4, it keeps running while busy.
- Tests:
  - detach, then `from_state(get_state())`, reattaches. The marker printed before
    the detach is visible, and new input works.
  - A stale record with a dead PID, or a mismatched creation time, never attaches.
  - A second client can't attach while one is attached.

### Milestone 3: busy detection and the quit policy

- Busy means the shell process has child processes. Poll in the host every
  500 ms with `CreateToolhelp32Snapshot`, matching parent PID to the shell PID.
  Send `STATUS` when it changes. Expose `status.busy` from `session:update()`.
- The quit policy runs on a normal quit, not on restart or a Project switch:
  - Idle sessions close.
  - If any session is busy, ask once: "Keep N running terminals running in the
    background?" with Keep, End, and Cancel, plus "Remember my choice".
  - Store the remembered answer in `USERDIR` storage, not in the repo defaults.
  - Keep detaches the busy sessions. They reattach on the next launch of that
    Project.
- Put the policy decision in a function that tests can call directly. The
  confirmation UI should reuse the existing quit-confirmation or nag view
  patterns in `data/core`.
- Tests:
  - the policy decision for idle, busy, and remembered answers;
  - busy turns true while `ping -n 3 127.0.0.1` runs, and false after.

### Milestone 4: snapshots and revival

- The host writes a formatter snapshot to `USERDIR/terminal-sessions/<id>.snapshot`
  with atomic replacement, at most every 2 s after output. It also writes one when
  the shell exits and when the host shuts down. Bound it to about 8 MB by trimming
  the oldest scrollback.
- The record also stores:
  - the last cwd, from OSC 7 through the model's pwd, or else the launch cwd;
  - the busy child's command line while busy, read with
    `NtQueryInformationProcess(ProcessCommandLineInformation)`, so revival can
    offer it.
- Revival: if the record exists but the host is gone (reboot, crash, or kill), start
  a new host with `--revive-from <snapshot>` in the last cwd.
  - The host feeds the snapshot into its model, then writes a revival marker line
    such as `--- Restored session; the previous shell ended ---`.
  - The client gets all of this through the normal replay.
  - If a command was interrupted, the view offers "Rerun <command>". It never
    reruns automatically.
- Cleanup:
  - Closing a terminal tab deletes its record and snapshot.
  - Records with a dead PID that no Workspace references are kept for the future
    Project Sidebar.
  - Records with a dead PID older than 30 days are removed at startup.
- Tests:
  - ending the host, then `from_state`, revives with the old marker text above the
    revival marker, and a live shell;
  - snapshot writes are bounded and atomic: a partial file never replaces a good
    one.

## Pitfalls

- **The dev update BAT:** a running host locks `anvil-portable\anvil.exe`, so the
  install can't replace it. Make `update-anvil-dev-build.bat` end all
  `anvil.exe` processes, hosts included, and document that. Running terminals
  then revive from snapshots after Milestone 4. Check the standalone build script
  too.
- **Two models parsing the same stream:** only the editor model may answer
  queries. Duplicate answers corrupt applications such as vim and fzf.
- **Order:** replay first, then output. Never write output before `REPLAY_END`.
- **Resize races:** apply `RESIZE` in the host in the order received. The editor
  model resizes locally right away, as it does today.
- **Environment:** the host spawns the shell, so `terminal_environment()` runs in
  the host. The host inherits the editor's environment at launch. That's correct.
- **Ghostty patch:** the semantic-prompt option from
  `ghostty-semantic-prompt-fresh-line-option.patch` must be set in both models.
  Sharing `terminal_model.c` takes care of that.
- **The existing hosted surface mode and `--shell`:** terminals work the same
  there, because the Project process is the client.
- **Tests:** Lua UI tests run with `SDL_VIDEO_DRIVER=dummy`. Hosts are real
  processes, so every test must close or kill its sessions. Leaked hosts lock
  the build exe.

## Diagnostics

- Lua: `core.log_quiet` for attach, detach, reattach decisions (with the reason a
  record was rejected), revival, quit-policy decisions, and failures.
- Host: its own log file, as described above.
- `session:stats()` gains `host_pid`, `shell_pid`, `attached_at`, and
  `replay_bytes`.

## After Phase 2

Update the Phase 2 status in `MULTIPROCESS_SHELL_PLAN.md`. Then:

- Phase 0 manual checks are still open: IME composition and candidates, and
  mixed-DPI moves.
- Phase 3 (hosted single Project) mostly exists as the `--shell` probe. It still
  needs:
  - shell-drawn window controls and status overlays;
  - a real Sidebar placeholder;
  - routing native file dialogs through the hosted backend.
- Phases 4 to 7 are unchanged from the main plan.
