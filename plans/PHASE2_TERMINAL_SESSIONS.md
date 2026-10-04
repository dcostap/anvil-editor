# Phase 2: Terminal Session processes

This is the implementation plan for Phase 2 of
[the multiprocess shell plan](MULTIPROCESS_SHELL_PLAN.md). Read that plan first,
especially "Terminal Sessions", "Session registry", and "IPC".

Status: Milestones 1 to 4 are implemented.
Phases 0 and 1 are done.

Formatter check: `anvil:terminal-replay` failed with the requested VT extras.
Primary replay added leading spaces. Alternate replay restored the active screen,
but lost the primary screen and its scrollback. `screen.h` has no separate screen
formatter. `snapshot.h` has a binary codec, not a separate primary VT formatter.
Raw replay from byte zero passed the row text, cursor, scrollback, and screen checks.
Milestone 1 used a bounded raw prefix. Milestone 2 replaces it with the
Ghostty snapshot codec. `AnvilTerminalReplay` is removed.

## Goal

Each terminal's ConPTY and shell run in a Terminal Session process. The editor
attaches to it over a named pipe. A crash or restart of the editor must not end
the shell. After a restart, the editor reattaches and shows the same screen and
scrollback. A Terminal Session that died is revived from its last snapshot.

The editor's terminal model, rendering, selection, search, and input encoding stay
where they are. Only the byte transport changes.

## Design before Milestone 1

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
- Initial launches connect with `WaitNamedPipe` retries up to about 5 s. Restored clients connect on a `ReconnectJob` worker.
  Record, PID, and creation-time checks stay synchronous. A dead or stale record starts a new shell in the saved cwd.
  A valid record creates a `reconnecting` view. Pipe busy, access denied, or host loss then fails that view.
  It opens with
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

- `HELLO { session_id, cols, rows, cell_width, cell_height, client_pid, replay }`: first message.
  The host checks the session ID and the actual pipe client PID.
  Zero cols and rows retain the live grid until the restored View gets its layout.
  Normal clients request replay. Control clients omit replay and send `CLOSE` or `DETACH` after `WELCOME`.
  Control connections do not resize the model or build a snapshot.
- `INPUT bytes`
- `RESIZE { cols, rows, cell_width, cell_height }`
- `CLOSE`: end the shell and the session. The host deletes its registry record
  and snapshot.
- `DETACH`: the editor is leaving on purpose; the session keeps running.
- `CLEAR`: clear the host model and publish the clear sequence as ordered `OUTPUT`.

Host to editor:

- `WELCOME { host_pid, shell_pid, state, size }`: includes the actual live grid and cell size.
- `REPLAY bytes`: a binary Ghostty snapshot, in bounded chunks, then `REPLAY_END`.
  Sent once after `WELCOME`, before any `OUTPUT`. This replaces Milestone 1's raw replay.
  Change the terminal protocol version when this payload changes.
- `OUTPUT bytes`: raw ConPTY output, in order.
- `STATUS { busy }`: sent after replay and when the host's child-process state changes.
- `EXITED { exit_code }`: after the host drained the remaining ConPTY output.

The editor's writer queue holds framed records, so `INPUT` and `RESIZE` stay in
order. `f_terminal_resize` enqueues `RESIZE` instead of calling
`ResizePseudoConsole`.

The editor's reader thread keeps snapshot bytes separate from raw `OUTPUT` bytes.
It must not feed a binary snapshot into `ghostty_terminal_vt_write`.
The UI thread restores READY first, then restores history in bounded update steps.
It starts parsing queued `OUTPUT` after FINISH validates.
The host's `EXITED` flag replaces local shell process checks.
The host drains ConPTY, so the editor's draining only empties its own queue.

A pipe that breaks without `EXITED` starts a background reconnect if the host is still alive.
The editor keeps the last screen while reconnecting. It does not resend unacknowledged input.
A dead host moves to `failed` with "The Terminal Session process ended unexpectedly".
Invalid snapshots or protocol records also fail. Milestone 4 will add revival for dead hosts.

Normal close releases the client transport and closes its host process handle.
It never waits for the host to exit on the UI thread.
An independent worker sends `CLOSE` through an authenticated control connection.
A fresh connection avoids any partial frame left by a cancelled input write.
Detach uses the same path with `DETACH`. A broken pipe also detaches the host.
Only the failed path calls `TerminateProcess`. The host's kill job ends the shell.
Reconnect retries wait 250 ms, then double the delay to a 2 s limit. They fail after about 30 s.
Connection failures do not terminate a live host. Unknown state does not prove that a shell is idle.
After Lua teardown, native shutdown waits up to 1 s total for pending CLOSE commands.
Normal View close never runs this wait. The native `finish_close_commands` API is for shutdown only.

## Host internals

- Threads: one reads ConPTY output, one serves the pipe, one writes to the client.
  A lock protects the host model and the client queue.
- Every ConPTY read goes into the host model, then into the client queue if a
  client is attached.
- The client queue is bounded to 8 MB, including the record being written.
  A full queue blocks the ConPTY reader on a condition variable.
  The writer signals that variable after it sends a record.
  Detach only after about 10 s without writer progress while the queue is full.
  Clear that client's queue, keep parsing ConPTY output, and accept another client.
- On attach: apply an explicit client size to ConPTY and the host model, then build
  the replay under the lock, send it, and only then stream new output.
- When the shell exits, drain ConPTY output (the same quiet and maximum
  timings as `TERMINAL_DRAIN_QUIET_MS` and `TERMINAL_DRAIN_MAX_MS`) and send
  `EXITED`. Pause the drain deadline while the client applies backpressure.
  Start the disconnect deadline only after the writer sends `EXITED`.
  Then wait for the client to disconnect, up to a few seconds.
  Delete the registry record and exit.

## Replay with the Ghostty snapshot codec

Milestone 1's formatter probe failed. The raw prefix is temporary, not the reattach design.
Milestone 2 uses `ghostty/vt/snapshot.h`. Milestone 4 uses the same codec for disk snapshots.

- Enable bounded `GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES` tracking before the host receives VT input.
  This permits snapshots between reads, including unfinished VT and UTF-8 input.
- On attach, resize the host model, then encode it while holding the model lock.
  Use `ghostty_snapshot_encode_alloc` or the codec's writer API.
  Do not change the checkpoint while its REPLAY records wait for queue space.
  Send the complete snapshot through FINISH, then `REPLAY_END`, then live `OUTPUT`.
- Restore the snapshot on the UI thread with `ghostty_snapshot_decoder_ready`.
  This returns a new terminal, not bytes to feed into the old terminal.
  Replace the editor model safely. Restore its callbacks, userdata, shared options, and render state.
  The host model still has no `write_pty` callback.
- Publish the READY screen first. Call `ghostty_snapshot_decoder_next` in bounded update steps.
  Keep the decoder's source bytes and returned terminal alive until FINISH validates.
  Apply queued live output only after history finishes, so replay retains all applicable history.
- The decoder's reader must not return zero bytes for temporary starvation.
  Keep network waits off the UI thread. Reject truncated, corrupt, or oversized snapshots.
- Remove `AnvilTerminalReplay` and its raw prefix storage, append logic, and overflow behavior.
  Replay depends on current model state, not the amount of output since session start.
- Use red-green codec round-trip tests for row text, cursor, primary scrollback, and alternate-screen state.
  Check the retained primary screen after leaving the alternate screen.
  Check unfinished parser input by continuing the stream after restoration.
  The reattach test must also work after more than 8 MB of earlier raw output.

## Milestones

Each milestone ends with focused tests, a commit, and the dev build updated with
`update-anvil-dev-build.bat`. Follow the red-green rules in AGENTS.md.

### Milestone 1: the session process and attach

Implemented: the native host owns ConPTY, the shell job, and a replay model.
The editor uses framed pipe transport. Both models use the shared model options.
The host checks the client PID and session ID. The editor checks the server PID.
At Milestone 1, every disconnect ended the host and shell. Registry and reattach came in Milestone 2.
The temporary raw prefix became unavailable on overflow; it never became a suffix replay.

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

Milestone 1 backpressure correction, 2026-10-04:

- A real Terminal View runs `type` on a 50 MiB file.
  The test holds the UI thread for 10 s, then resumes updates for 5 s.
  Before the fix, the full host queue disconnected the client and the view became `failed`.
  After the fix, the writer resumes and the view continues to receive output.
  `ui/terminal.lua` passes all 67 tests.
- Queue waits release the model lock. Replay stays fixed while its records wait.
  The drain deadline pauses during backpressure. The exit deadline starts after `EXITED` is sent.

Milestone 1 close correction, 2026-10-04:

- The test suspends its own host process, then closes the Terminal View.
  Before the fix, close waited for the host and failed the UI responsiveness check.
  After the fix, close returns while the host is suspended.
  The test resumes the host and waits for cleanup outside the close operation.
  `ui/terminal.lua` passes all 68 tests.
- `runtime/terminal_native.lua` passes 27 tests. WSL remains unavailable and skips one test.
- Milestone 2's replay design now uses the snapshot codec. No Milestone 2 code is implemented yet.

`terminal-native-perf` passed before and after these corrections:

| Measurement | Before fixes | After fixes |
| --- | ---: | ---: |
| Typing echo p50 | 15.917 ms | 15.575 ms |
| Typing echo p95 | 16.065 ms | 16.118 ms |
| 20,000 output lines | 5,056.040 ms | 5,820.386 ms |
| Update p50 / p95 | 0.0055 / 0.0200 ms | 0.0082 / 0.0270 ms |
| Snapshot p50 / p95 | 0.2578 / 0.4824 ms | 0.3065 / 0.6187 ms |
| Ten-session update total | 52.054 ms / 2,110 calls | 6.671 ms / 2,170 calls |

Echo p50 changed by -0.342 ms. The benchmark remains within its budgets.

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

Implemented on 2026-10-04:

- Protocol version 2 carries binary snapshots. Host encoding and client collection each have a 128 MiB limit.
- Both models enable bounded continuation tracking. The decoder accepts at most 65 MiB of continuation data.
- The reader collects snapshot bytes separately from `OUTPUT`. The UI decoder reads an immutable, complete buffer.
- One update publishes READY. Later updates restore up to four history pages, with a 2 ms deadline between pages.
  FINISH must validate before live output is parsed. Trailing snapshot bytes are rejected.
- Model replacement restores callbacks, options, colors, and render state. Gesture pins leave the old model before release.
- Reattach keeps the live grid until layout is known. Unchanged grids do not resize ConPTY or trigger an old-screen repaint.
- Registry files use atomic replacement. Creation times use 16-digit hex strings, without Lua number precision loss.
- Pipe breaks and writer stalls detach the host, not the shell. Existing views reconnect on an independent native worker.
- Workspace exit, restart, and same-window Project switch detach after saving state. Tab close still ends the session.
- Attach and detach request Workspace saves. Records and snapshot paths are removed when the host ends normally.
- Idle orphan hosts exit after ten minutes without output or a shell child. Failed process probes keep the host alive.
- Disk snapshots and revival are not implemented. The record reserves the snapshot path for Milestone 4.

Red-green evidence:

- `anvil:terminal-replay` first failed to encode unfinished parser input. It now preserves both screens and primary history.
  It also checks cursor position, split UTF-8, split CSI input, corruption, and truncation.
- `ui/terminal_sessions.lua` first failed because Workspace state had no session ID.
  The 50 MiB `type` test also confirmed that the old writer timeout ended the host.
  It now holds the UI for 20 s, crosses that timeout, and reattaches to the same host and shell.
  Marker replay and new input also work after that output exceeds the old 8 MiB replay limit.
- With reconnect and Workspace detach disabled, `ui/terminal_sessions_lifecycle.lua` failed its recovery and lifecycle checks.
  Those checks pass with the implementation enabled.
- The clear regression first restored removed text. Ordered host `CLEAR` handling now keeps that text removed.
  Isolated verification also found a temporary-grid repaint. Reattach now retains the live grid until layout is known.

The focused checks cover stale creation times, dead hosts, second-client rejection, and Workspace restoration.
Tests retain process handles and end their own hosts during cleanup. They do not use the daily app.

Focused results: ten new UI checks passed. The codec check also passed.
Existing terminal checks passed: 68 UI, 14 contrast, and 27 runtime checks.
One WSL check skipped because no default distribution was available.
Final verification used separate runner folders because concurrent checks replaced the shared Meson folders and logs.

The before and after benchmarks passed:

| Measurement | Before Milestone 2 | After Milestone 2 |
| --- | ---: | ---: |
| Typing echo p50 | 15.665 ms | 15.509 ms |
| Typing echo p95 | 16.522 ms | 16.083 ms |
| 20,000 output lines | 5,188.089 ms | 5,591.244 ms |
| Update p50 / p95 | 0.0056 / 0.0209 ms | 0.0089 / 0.0237 ms |
| Snapshot p50 / p95 | 0.2582 / 0.4891 ms | 0.3192 / 0.5610 ms |
| Ten-session update total | 6.323 ms / 2,390 calls | 8.352 ms / 2,300 calls |

Echo p50 changed by -0.156 ms, within the 1 ms budget. Other totals include process scheduling noise.

- Replace raw prefix replay with the snapshot codec described above before adding reattach.
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

Implemented:

- Protocol version 3 adds `STATUS`. The reader publishes `status.busy` without parsing status bytes as VT output.
- The host polls shell children every 500 ms while attached and every 2 s while detached.
  Failed process probes remain busy. Status changes wait for queue space without blocking the host monitor.
- Normal quit first confirms unsaved buffers. It then asks once for all busy Workspace terminals.
- Keep detaches busy terminals and closes idle terminals. End closes all terminals. Cancel leaves them attached.
- The existing Nag View shows Keep, End, Cancel, and a Remember my choice toggle.
  The toggle uses the existing keep-dialog-open callback, not another dialog implementation.
- Storage keeps a remembered Keep or End answer under `USERDIR/storage/plugins.terminal/quit_choice`.
  Cancel is never remembered. Restart and same-window Project switch bypass this policy and keep detaching.
- `terminal.quit_decision` is the public decision seam. Reconnecting and unknown sessions are not treated as idle.
- Quiet logs record policy results. Native shutdown logs mark the bounded CLOSE drain.

Red-green checks:

- `ui/terminal_restore_async.lua` first failed because restoring a held pipe blocked for about 5 s.
  It now returns in less than 0.8 s, fails asynchronously, and leaves the first shell usable.
- `ui/terminal_quit.lua` first failed because the decision API and child status did not exist.
  Decision checks and a real `ping` child now pass.
  In-process dialog commands also check Cancel, remembered Keep, idle close, and busy reattach.
- `ui/terminal_reconnect_deadline.lua` checks a suspended, test-owned host and a bounded reconnect deadline.
  The saved Milestone 2 binary still retried at 34 s. The new binary fails at about 30 s without ending the host.
- `ui/terminal_close_shutdown.lua` checks three closes within one shared shutdown budget and host exit afterward.
  The saved binary had no shutdown drain API. The new check passes, including exit of all three hosts.

The tests use isolated app data. They do not change the daily app's remembered answer.
The five policy/status checks, async restore, reconnect deadline, and CLOSE drain pass.
The six lifecycle checks and four restoration/stall checks also pass.
The stall check now allows 30 s for queue fill and the timeout. At 20 s, a loaded run had stalled for only 8 s.

Same-workload benchmark, saved Milestone 2 binary versus the new binary:

| Measurement | Saved Milestone 2 | After Milestone 3 |
| --- | ---: | ---: |
| Typing echo p50 / p95 | 15.540 / 16.072 ms | 0.081 / 0.130 ms |
| 20,000 output lines | 6,133.036 ms | 5,715.453 ms |
| Update p50 / p95 | 0.0104 / 0.0309 ms | 0.0079 / 0.0242 ms |
| Snapshot p50 / p95 | 0.3668 / 0.6752 ms | 0.2993 / 0.5618 ms |
| Ten-session update total | 9.060 ms / 2,260 calls | 7.116 ms / 2,170 calls |

All existing benchmark limits pass. Other native work changed during this task.
Do not attribute the large echo change to the quit policy. The after run also reported dropped test event-queue notifications.
Transport output and tail checks passed. This test-loop warning remains outside the quit-policy change.

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

Implemented. The host owns disk encoding and writes. Revival starts on the existing connection worker.

Preparation follow-ups:

- `terminal:reset_quit_choice` clears user storage and writes a quiet log. The command test passes.
- The old echo comparison mixed inbox Windows ConPTY and the bundled Microsoft ConPTY runtime from `19f61330`.
  It also wrote unterminated characters. Inbox output batching affected that workload.
  Do not use the 15.5 ms to 0.08 ms comparison to measure the quit-policy change.
- The fixture now sends generated, numbered ACK replies. Local input echo cannot satisfy the measurement.
  Bundled ConPTY measured 0.178 ms p50 and 0.226 ms p95 after the wake fix.
  This measures API-to-shell-to-model round-trip time, not rendered input latency.
- The benchmark reproduced dropped `terminaloutput` notifications before the fix.
  Model updates cleared pending flags without consuming their queued events.
  All terminals now share one pending wake. Only event delivery clears it.
  The same three benchmark checks pass without dropped-event warnings after the fix.
- Attached busy probes remain at 500 ms. Detached probes remain at 2 s.

- The host writes a Ghostty codec snapshot to `USERDIR/terminal-sessions/<id>.snapshot`
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
  - The host decodes the snapshot into its model with the same codec used for attach.
    It then writes a revival marker line
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

Implementation notes:

- Disk payloads have an 8 MiB limit. Encoding trims a copy, not the live terminal.
  Oversized screens or parser continuation fail without replacing the last good snapshot.
- Each Project keeps at most 32 snapshots. Its mutex protects eviction and publication.
  One fixed staging file per Project bounds files left by a crash.
  The host flushes the staging file before atomic replacement.
- A model revision tracks pending writes, including clear and resize. A clock tick cannot hide later output.
- Records store OSC 7 cwd and the busy child's command line. Changed commands update the record.
  The host writes its final snapshot after output drains, including after a normal shell exit.
- Revival retains the session ID and saved grid. It resets old parser and application modes before starting the shell.
  It copies the decoded active alternate grid into primary history before the marker. Binary replay still uses the codec.
  The view waits for replay before offering the interrupted command. Rerun needs explicit approval.
- Shared-delete record reads permit atomic replacement. Read access errors do not start another shell.
- A system worker removes expired dead records at startup and dead records after explicit View close.
  Host identity checks remain conservative. A per-session mutex prevents cleanup from racing revival.
  Deletion uses derived paths, not a record's supplied snapshot path.

Focused checks:

- The first revival check failed because the host did not write a disk snapshot.
- Disabling the disk bound accepted an oversized unfinished payload. Restoring the bound made the check pass.
- Disabling the rerun offer failed with "revival did not offer the interrupted command".
- Disabling open-View revival failed with "open View did not revive".
- Disabling cleanup left an expired dead record. The worker now removes it and keeps recent and live records.
- The alternate-screen check failed because revival lost the last visible grid.
- Six revival checks cover host loss, explicit rerun, OSC 7 cwd, corrupt data, final output, and alternate-screen history.
  Cleanup and all six lifecycle checks pass. The native codec and disk checks pass.
  The dead-host fallback check now removes the snapshot to test the fresh-shell path.

Corrected benchmark, before disk snapshots versus after:

| Measurement | Before disk snapshots | After disk snapshots |
| --- | ---: | ---: |
| Generated reply p50 / p95 | 0.213 / 0.239 ms | 0.199 / 0.253 ms |
| 20,000 output lines | 5,383.614 ms | 5,684.978 ms |
| Update p50 / p95 | 0.0070 / 0.0171 ms | 0.0077 / 0.0205 ms |
| Snapshot p50 / p95 | 0.2794 / 0.4660 ms | 0.2992 / 0.5009 ms |
| Ten-session update total | 6.071 ms / 2,360 calls | 8.887 ms / 1,900 calls |

All three limits pass. Neither run reports dropped events. Do not treat small differences as causal improvements.

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
