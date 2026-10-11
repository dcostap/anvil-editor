# Phase 6: shell restart and restore

## Status

The user accepted all five review decisions on 2026-10-11 and authorized milestone 1.
Commit and stop for review after each milestone.
Milestones 1, 2, and 3 are implemented and deployed; see their records below. The user approved milestone 3.
Phase 6 is complete. Phase 5 milestone 5 matched latency is recorded; the interactive foreground check stays open.
Milestone 1 does not change compositing or input, so that latency run does not block it.
Hosted mode stays opt-in.
Physical input, IME, mixed DPI, allocator failure, and instrumented lifetime acceptance remain open.

Read [the main plan](MULTIPROCESS_SHELL_PLAN.md) and [Phase 5](PHASE5_SEVERAL_WINDOWS.md) first.
Use the terms in `CONTEXT.md`. This plan does not rename them.
"Adoption" below names a shell taking over running Project processes. It is a plan term, not a glossary term.

## Goal

From the main plan:

- Restore Anvil Windows, Selected Projects, and Workspaces after a full quit, a crash, or a reboot.
- After a shell restart, adopt running Projects and Terminal Sessions.

## Current state

What exists and what this phase reuses:

- Workspaces save on activity, on focus loss, and at least every 10 s (Phase 1). A Project restores its own
  Workspace when it starts. Restore does not need new Workspace code.
- Terminal Session hosts survive Project and shell loss. They publish registry records. After a reboot, a
  Terminal Session revives from its disk snapshot and never reruns a command by itself (Phase 2).
- Dormant Projects load with their saved Workspace when selected (Phase 4).
- One shell per executable and user directory. A later launch forwards to it (Phase 5 milestone 5).
- The shell persists nothing. Each new Window opens at 80% of the primary display.
- On shell loss, a Project saves and detaches, then exits within 5 s (`src/hosted_surface.c`).
  The Sidebar process also exits.
- Each hosted Project writes the shared `appstate.lua` file itself.

## Scope

In scope: shell-written App State for Windows, cold restore, restore failure handling, and Project adoption.

Out of scope:

- direct mode and non-Windows behavior;
- final Sidebar design (Phase 7);
- automatic shell relaunch after a crash;
- adopting the Sidebar process (see decision 3);
- automatic GPU recovery.

## Milestones

### 1. Shell-written Window state and cold restore

The shell records each open Anvil Window in App State:

- placement, mode (normal or maximized), and monitor;
- the Selected Project, by path and identity;
- Window order, so the frontmost Window restores in front.

Writes are debounced, bounded in size, and atomic (write a temporary file, then replace).
A worker thread writes the file, so the native UI thread never waits on disk.
The shell writes after placement, selection, New Window, Move, and Close.
The shell owns the file. Lua never writes it.

A launch with no Project argument restores the saved Windows. Each Window loads its Selected Project.
That Project restores its own Workspace. Other Projects stay in the Project Sidebar as Dormant Projects.
Decision 2 covers a launch with a Project argument.

Seams: private-desktop fixtures through `tools/run_surface_latency_probe.py`.

- Two Windows with different Selected Projects and bounds. Close the last Window, then launch.
  The same Windows return with their bounds, modes, Selected Projects, and Workspace open files.
- Kill every Anvil process with `TerminateProcess` (crash and reboot model), then launch.
  The last written state returns.
- Sequential Close follows decision 1.

Red first: today the second launch opens one empty-sized Window with only the argument's Project.

### 2. Restore failure handling

Restore must never block startup or the native controls.

- A missing, corrupt, partial, or too-large state file starts one fresh Window. The shell logs why.
- A missing Project directory leaves its Window empty with a notice. Its Project Sidebar entry stays.
- A Window saved on a removed monitor moves fully onto a visible monitor. Mixed-DPI bounds use the target
  monitor's scale.
- Restored Projects start in a bounded sequence: the frontmost Window first, then the others.
  Native controls stay responsive in every Window while the others start.
- An external launch during restore waits for the restore's identities, like the first Project in
  milestone 5. It cannot duplicate a restoring Project.

Seams: the same fixtures with a corrupt file, a removed directory, off-screen bounds, delayed startup
(`ANVIL_SURFACE_FAULT_STARTUP`), and a concurrent external launch.

### 3. Project adoption after shell loss

Today a Project exits after shell loss. With adoption, it waits for a new shell instead:

1. On loss it still saves and detaches first, so a failed adoption loses nothing.
2. It stops rendering and publishes an adoption record under `USERDIR`: PID, Project identity, saved Window,
   pipe name, and creation time.
3. It listens on its own pipe for a bounded adoption period (decision 4), then exits as today.

The next shell (from any launch) reads the adoption records before it restores:

- It checks that each PID is alive and runs the same executable, as the same user, in the same session.
  It reuses the milestone 5 identity checks.
- It connects with a new connection generation and creates new shared surfaces.
- It places each adopted Project in its saved Window and starts new Projects only for the rest.
- A stale record, a dead PID, or a failed handshake falls back to a normal Project start.
  Never two runtimes for one Project.

The Project process accepts only a shell that passes the same checks. The request is bounded and versioned.
It does not add a general remote call.
Terminal Sessions need no adoption: they already reattach to their Project process, which stays alive.
The Sidebar process restarts (decision 3).

Seams: kill the shell with `TerminateProcess` and launch again.

- The same Project PIDs return in their saved Windows, with unsaved edits and live Terminal Sessions intact.
- With no new launch, each Project exits after the adoption period.
- A stale record, a hung Project, and a different user directory never block startup or duplicate a Project.

Run matched latency after this milestone, because it changes transport setup.

## Review decisions

The user accepted each recommendation below.

1. **What does "full quit" restore?** Close is per Window. The last Window Close ends the shell.
   Recommendation: restore the Windows open when the shell ended. A Window the user closed earlier is gone.
   After separate Closes, only the last Window returns. A crash or reboot keeps every Window from the last write.
   Alternative: add an explicit Quit Anvil command that closes every Window and restores them all.
   Phase 5 kept that application-wide Quit out of scope.
2. **Launch with a Project argument.** Recommendation: restore the saved Windows, then handle the argument as
   an external launch: select the Project in its restored Window, or open a new Window for it.
   Alternative: a launch with an argument skips restore.
3. **Sidebar process.** The main plan says to adopt it. Recommendation: restart it instead. The shell owns the
   Project Sidebar model, so a new Sidebar process loses nothing, and its restart path is already tested.
4. **Adoption period.** Recommendation: 60 s after shell loss. Longer keeps unrendered Projects in memory;
   shorter loses edits made since the last save if the user relaunches late.
   No automatic relaunch: the user's next launch adopts.
5. **App State writers.** Hosted Projects still write `appstate.lua` for recent Projects and find history.
   Recommendation: the shell writes Window state to a separate file in `USERDIR`, so Project writes cannot
   overwrite it. Recent Projects stay where they are.

## Verification and completion

Use focused red-green checks at the private-desktop runner, with isolated data and owned process handles.
Do not capture pixels or use the user's Windows.
Run D3D11 and software checks for each milestone.
Milestones 1 and 2 do not change compositing or input, so they need no latency gate.
Milestone 3 needs matched latency against the previous milestone's portable.
Commit each milestone after its focused checks. Report hashes and deployment logs.
Keep all manual and instrumented acceptance gates visible.

## Milestone 1 record

### Implementation

- `src/shell_state.c` encodes, decodes, and atomically replaces `USERDIR/shell-windows.state`.
  A worker thread writes it. A partial or malformed file restores nothing.
- The shell writes 500 ms after the last placement, selection, focus, New Window, or Close change.
  It writes the final state when the last Window closes, and again when the shell ends with Windows open.
- A Window's entry is captured when its Close begins, because the Close changes the selection as it ends Projects.
- Restore creates Windows back to front, with their normal bounds set while hidden, then maximizes as saved.
- Restored Projects resolve as initial Projects. A launch argument after a restore runs as an external launch,
  so it waits for the restored identities and cannot duplicate them.
- Hosted Projects no longer apply their own saved window bounds or maximize at startup (`data/core/init.lua`).
  Before this, each restored Window moved to the Project's App State bounds, `800x600` at `0,0` by default.
  Direct mode is unchanged.

### Red-green

Native seam `anvil:shell-state` (`tests/native/shell_state_test.c`): round trip, every cut of a partial file,
malformed lines, the Window bound, and latest-wins atomic writes. The first run found a partial-file case that
decoded; the decoder now requires every line to complete.

Fixture `tests/fixtures/shell_restore_probe.lua` (`restore-*` cases):

| Case | Checks |
| --- | --- |
| `restore-crash` | Two Windows, one moved and one maximized. Kill every process, then launch with no argument. Both Windows return with their bounds, modes, front order, Selected Projects, and the Project's Workspace file. |
| `restore-sequential` | Close Window A, then Window B. The next launch restores only B, with its bounds. |
| `restore-argument` | A restored Project named by an aliased argument opens once. Another Project argument opens a new Window beside the restored one. |

- Red, deployed Phase 5 build (`xlij14ro`): "shell did not write its Window state", "restore did not load the last
  Window's Project", and "restore did not load Project".
- First green attempt (`y0wg7ee0`): `restore-crash` failed with Window A at `0,0 800x600`; the Project's
  startup bounds overrode the shell. Fixed in `data/core/init.lua`.
- Green: `vuzuqhig`, then D3D11 `rx4zc7aj` and software `rgo4knlo`.

### Regression checks

D3D11 `rx4zc7aj` and software `rgo4knlo`: all `launch-*` cases, `duplicate`, `foreground`, `new-window`,
`launch`, `arguments`, `controls`, `move`, `windows-new`, `windows-move`, `windows-close-dirty`,
`windows-close-quit`, `loaded-launch`, `dormant-launch`, and `identity-alias` pass, except one D3D11 `controls` run.
That run timed out waiting 5 s for a fixture-killed Project to exit while the machine ran heavy unrelated work.
Its log shows no exit at all within that time. Milestone 4 recorded that fixture kills stay slow under load.
Two reruns each with this build (`nlklk8nv`, `8xdog3od`) and the deployed Phase 5 build (`z5dxjpir`, `3nvc0kj0`) pass.

### Deployment

`update-anvil-dev-build.bat` rebuilt and installed the dev portable app. It ended all Anvil processes.

- Build `build-windows-x86_64/src/anvil.exe`: `ec59c5bdfb97525d4cab856f8b12173bf7e7a94bcca3f5f8bacb3f1184f8a857`
- Portable `anvil-portable/anvil.exe`: `7e712aa9b37bdca4ad676d035c945e70633e1fa0f21d7651d75830ae1e435d90`

## Milestone 2 record

### Implementation

- The shell logs whether the state file is absent or invalid. Either way it opens one fresh Window.
- A restored Window's identity job names its Project. If the folder is gone, the shell retires the placeholder
  and the Window stays empty with "Cannot restore this Window's Project. Its folder was not found."
  No Project enters Failed. If the user selects another Project while one resolves, the restore keeps that choice.
- Before showing a restored Window, the shell checks how much of it the monitors show. Windows only moves a
  Window that is completely off screen. When part of it is hidden, the shell clamps it into the nearest
  monitor's work area, shrinking it if needed.
- Restored Projects resolve concurrently but start one at a time, frontmost first.
  The next one starts when the previous one is Ready, has ended, or has run for 2 s.
  The sequence runs from the shell loop and a 100 ms timer; native controls never wait for it.
  A restored Window that begins Close drops out of the sequence. An external launch for a waiting Project
  moves it to the front of the sequence.
- External launches during restore still wait for the restored identities (milestone 1, `restore-argument`).
- Mixed-DPI bounds are not verified. The fixture desktop has one monitor; mixed DPI stays a manual gate.

### Red-green

New `restore-*` cases in `tests/fixtures/shell_restore_probe.lua`. The driver writes the state file directly.

| Case | Checks |
| --- | --- |
| `restore-invalid` | A truncated state file opens one Window and logs that the state is invalid. |
| `restore-missing` | The front Window's Project loads. The Window whose folder is gone stays, shows the notice, and nothing enters Failed. |
| `restore-offscreen` | A Window saved with 150 px on screen opens inside its monitor's work area. |
| `restore-stagger` | Three Windows with the middle one's launch paused 7 s. Starts run front to back, the back Project starts during the pause, and Minimize and Restore work in every Window meanwhile. |

- Red, deployed milestone 1 build (`lbgckv8p`, `vu6s9nnu`): "invalid state was not reported";
  "missing Project folder showed no notice" (the Project entered Failed); the Window stayed at `2410,100`
  outside the `2560` px work area; "restored Projects did not start front to back".
  A first `restore-offscreen` variant saved fully off screen and passed on the old build, because Windows moves
  such a Window itself. The case now saves a partly visible Window.
- Green: D3D11 `caaq3bfg`, software `k6144i76`. Under load the front Project took 2.1 s, so the 2 s interval
  started the next one first; the back Project started during the 7 s pause.

### Regression checks

D3D11 `uqm06cjk` and software `8tespfce`: `restore-crash`, `restore-sequential`, `restore-argument`,
`launch-forward`, `launch-concurrent`, `new-window`, `launch`, `arguments`, `controls`, `windows-new`,
`windows-close-dirty`, `windows-close-quit`, `loaded-launch`, `dormant-launch`, and `identity-alias` pass.

### Deployment

`update-anvil-dev-build.bat` rebuilt and installed the dev portable app. It ended all Anvil processes.

- Build `build-windows-x86_64/src/anvil.exe`: `8f38fc7e58d3e3385ee233e973027541050e9e8ae4fff01999ab13883a282224`
- Portable `anvil-portable/anvil.exe`: `272ca60c3f763fb839d839de71414e0fc8edab795743bfac92f01f4d748b5c24`

## Milestone 3 record

### Implementation

- On shell loss a Project stops rendering, publishes `USERDIR/adoption/<pid>-<created>.record`, and opens
  `\\.\pipe\AnvilAdopt-<pid>-<created>`. The pipe has a user-only DACL and rejects remote clients.
  Lua then saves the Workspace and App State, as a plain shell loss did. The native 5 s deadline still bounds that save.
- The Project then waits 60 s from the loss. It accepts only a client that is the same executable, user, and
  session. The request is versioned and names the shell's surface pipe, which must belong to that client's PID.
  On acceptance the Project connects to that pipe with a new HELLO and configuration, starts a new reader, and
  resends its title, hit test, border, and visibility. Outbound messages from the lost connection are dropped.
- With no adoption, the Project removes its record and exits through the old shell-loss path.
- The Sidebar process publishes no record. It exits as before and the next shell starts a new one (decision 3).
- The shell reads the records before it restores. A record for a dead PID, a different start time, or a different
  identity is deleted; damaged records are deleted too. Each valid record's Project returns to its saved Window,
  by Window id and path. Records for unsaved Windows join the frontmost Window, or one new Window.
- The restore sequence adopts instead of creating a process. The request waits up to 8 s, which covers the
  Project's save. If it fails, the shell ends the old process before it starts a new runtime, so one Project
  never has two runtimes. Adoption is tried once per Project.
- The shell state file is now version 2. Each Window line carries its Window id. Version 1 files restore nothing.
- `ANVIL_SURFACE_FAULT_ADOPTION_PERIOD_MS` and `ANVIL_SURFACE_FAULT_ADOPTION=hang` are probe faults. They need
  `ANVIL_SURFACE_FAULT_PROBE=1`.

### Red-green

Native `anvil:shell-state`: version 2 round trip and rejects, plus adoption record round trip, every partial
cut, and malformed records.

New `adopt-*` cases in `tests/fixtures/shell_restore_probe.lua`:

| Case | Checks |
| --- | --- |
| `adopt-return` | Two Windows, moved. Kill only the shell, then launch with no argument. Both Project PIDs return in their saved Windows. The unsaved edit stays in the Buffer and off disk. The Terminal Session host stays the same live process. No new runtime starts; records are removed; native controls respond. |
| `adopt-timeout` | With a 2 s period and no relaunch, the Project exits and removes its record. |
| `adopt-stale` | A dead-PID record, a live PID with another start time, and a damaged file are each removed. Startup is not delayed. |
| `adopt-hung` | The Project never answers. The shell opens the Window at once, native controls respond, then it ends the old process and starts one new runtime. |
| `adopt-userdir` | A shell for another user directory does not adopt or end the Project. |

- Red, deployed milestone 2 build: every case failed because no record was published, and `adopt-stale`
  failed with "the shell kept stale records".
- First green: `adopt-return` failed only on the fixture's expected text (`get_text` omits the final newline).
- Green on D3D11 and software, all five cases.
- Review fix: an adopted Project now gets the shell's foreground grant, and the shell closes no NULL thread handle.
  All five cases, `shell-loss`, `restore-crash`, `foreground`, and `launch-forward` pass on both renderers after it.

`shell-loss`, `end-loss`, and `stalled-loss` now set the 2 s probe period. They still check the Workspace save,
Terminal detach and reattach, and the native deadline.

### Regression checks

D3D11: `shell-loss`, `end-loss`, `stalled-loss`, `restart`, `switch`, `new-window`, all `restore-*` and `launch-*`
cases, `windows-close-dirty`, `windows-close-crash`, `windows-close-quit`, `windows-new`, and `windows-move` pass.
Software: `shell-loss`, `end-loss`, `stalled-loss`, `restart`, `restore-crash`, `restore-argument`,
`restore-stagger`, `launch-forward`, `launch-hung`, and `windows-close-dirty` pass.
The hosted native tests pass; `hosted_routing_test` now links the adoption sources.

### Matched latency

Reference: the milestone 2 portable exe (`272ca60c…`) with `data` from `f8bd1f51`. Candidate before the review
fix: `e10a53b0…`. Three alternating pairs, 360 valid samples per row and build, no failures.
Evidence: `%TEMP%/anvil-phase6-m3-matched-31zvwgrc/results.json`.

| Row | Reference p50 / p90 / p99 | Candidate p50 / p90 / p99 |
| --- | --- | --- |
| direct D3D11 | 8.16 / 17.53 / 29.05 | 8.22 / 17.53 / 25.68 |
| shell D3D11 | 8.30 / 19.76 / 39.51 | 8.03 / 17.22 / 21.23 |
| direct software | 15.67 / 24.42 / 30.25 | 13.12 / 22.94 / 25.43 |
| shell software | 28.65 / 39.40 / 51.73 | 25.10 / 34.54 / 50.43 |

The candidate's shell D3D11 maximum is 120 ms against 41 ms; one sample, with heavy unrelated load on the machine.
The review fix changes only the adoption branch and handle cleanup, not the steady-state transport.

### Deployment

`update-anvil-dev-build.bat` rebuilt and installed the dev portable app. It ended all Anvil processes.
The first attempt failed to link `hosted_routing_test`; the second passed. The fresh session log has no errors or warnings.

- Build `build-windows-x86_64/src/anvil.exe`: `15df32001a94b4844b23fc96e4926dcec1fe3e6f3651e643ca67c87402d26761`
- Portable `anvil-portable/anvil.exe`: `8628315ba8be224b7dc766937b609aac6e2f459825d6c370af0312f25000378d`

Manual gates stay open: a real reboot, physical input after adoption, and mixed DPI.
