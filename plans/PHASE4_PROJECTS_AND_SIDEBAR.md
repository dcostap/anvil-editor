# Phase 4: several Projects and the Sidebar process

## Status

The user approved continued work while the Phase 3 physical-input, IME, and mixed-DPI checks remain open.
Hosted mode stays opt-in. The Phase 3 code reviews are complete.
Do not treat synthetic tests as manual acceptance.
Milestones 1 and 2 are implemented. Explicit unload and independent recovery remain Milestone 3 work.

## Scope

Keep several Projects loaded in one Anvil Window.
Selecting another Project must preserve the previous Project's live Buffers, Workspace, workers, and Terminal Session connections.
A loaded Project that no Window presents must stop rendering, not stop its background work.
A Dormant Project has no Project process. Selecting it loads its saved Workspace.

The shell owns Project identity, selection, lifecycle, and the Project Sidebar model.
The Sidebar process draws a minimal list and sends actions. It owns no Project state.
Keep the native window controls independent of both Lua processes.

Keep direct mode and non-Windows behavior unchanged.
Keep Project GPU recovery explicit. Do not add automatic renderer fallback.
Do not terminate a Project because its pipe failed or its Close request timed out.

## Milestones

### 1. Hidden rendering control

Add shell-owned rendering permission to hosted configuration.
Hiding or minimizing the current Window supplies the first real use of this permission.
Keep geometry configuration identity separate from rendering permission.
Do not use keyboard focus as rendering permission.

The Project must continue processing events, coroutine tasks, worker results, Workspace saves, and Terminal output while hidden.
Do not clear pending redraw requests while hidden.
Showing or restoring the Window must request a complete repaint of the latest state.
Keep the native first-frame timeout from rejecting a deliberately hidden Window.

Test the public `core.step` and `core.run_step` behavior at the window boundary.
Extend the existing owned-window fixture for minimize, hide, restore, background progress, and Close while hidden.
Run both renderers. Use no screen capture or user windows.
Compare typing latency separately from correctness checks.
If Close needs a user choice, show and restore the Window before waiting.
Cancellation must preserve unsaved edits and return the Project to Ready.

### 2. Several loaded Projects

Separate per-Project transport and process ownership from Window presentation state.
Tag queued work with Project and connection identity. Keep storage alive until its users stop.

Keep A loaded while selecting B. Selecting A again must use the same Project process and live state.
Configure, focus, and rendering permission must follow selection in one ordered stream.
Old frames, dialogs, input, and worker results must not reach another Project.
Keep one Project instance per path. Do not introduce several Anvil Windows yet.
Window Close checks each loaded Project in turn with its normal unsaved-data and Terminal policies.
Cancel stops further Close requests. Earlier accepted closes remain complete.
Quit inside a Project also closes the Window and checks its remaining loaded Projects in turn.
Per-Project Close will use explicit unload in Milestone 3. Do not change Quit into unload.

### 3. Dormant Projects and independent recovery

Add explicit Project unload and load, with the existing unsaved-data and Terminal policies.
Test Workspace restoration and live Terminal reattachment without command replay.
Keep crashes and hangs local to one Project.
Expose Wait and explicit Restart without blocking another Project or the native controls.

### 4. Project Sidebar model

Use recent Projects as the list source. Keep order stable, with new Projects first.
Include Project lifecycle and bounded asynchronous Terminal Session status.
Do not poll Terminal hosts or read registry files on the native UI thread.

### 5. Minimal Sidebar process

Use the existing renderer, surface transport, theme, and input boundaries.
Keep the first list UI small. Defer final presentation design to Phase 7.
A Sidebar crash or hang must not stop Project input or native controls.
Restart only the Sidebar after its failure.

## Deferred work

Phase 5 owns several Anvil Windows and moving Projects between them.
Phase 6 owns shell adoption and full restore after exit or reboot.
Do not add those features as part of Phase 4.

## Verification records

Record each milestone's targeted red-green evidence, focused checks, latency comparison, and commit.
Keep the deferred Phase 3 manual checks visible until the user supplies results.

### Milestone 1: hidden rendering control

Surface protocol 7 adds shell-owned rendering permission, separate from layout identity.
The Project processes events and service work without updating or drawing its UI while hidden.
The scheduler keeps ordinary coroutine tasks active after the focus-loss delay.
Showing or restoring requests a complete repaint and keeps the same Project process.
Terminal Views retain their native grid until they have valid layout geometry.
Close shows or restores the Window when it needs a user choice.
Cancellation keeps the dirty Buffer. Clean Close also works while hidden.

Targeted red-green evidence:

- `hidden_rendering.lua` failed because the hidden Project drew. Both editing and pending-redraw checks now pass.
- `hidden_terminal_geometry.lua` failed because missing layout changed the native columns. The retained-grid check now passes.
- The owned `hidden-render` case failed because Terminal output disappeared after the grid shrank.
  It now checks late coroutine work, worker results, Terminal output, saved Workspace, and the latest text after restore.
- Its idle check failed with the old scheduler mode when no redraw remained pending.
  With rendering permission disabled, ordinary coroutine tasks now continue without needing a redraw.
- `hidden-startup` failed when the first-frame deadline rejected a deliberately hidden Window.
  Restoring the visibility guard keeps the Project live beyond that deadline.
- `hidden-close-cancel` failed because its confirmation remained invisible.
  It now checks visible confirmation and Cancel for both minimized and hidden Windows.

The worker result collector originally replaced the echo result with an empty final message.
The fixture now retains the result message. This fixture correction is not a runtime fix.

All three focused Lua tests pass. Four owned-window cases pass on both renderers.
These checks use the existing private-desktop runner. They capture no pixels and touch no user windows.

Evidence directories under `%LOCALAPPDATA%/Temp`:

- Hidden rendering and clean Close: `anvil-surface-latency-0ycb65gp` and `anvil-surface-latency-eh1cs065`.
- Final rendering, clean Close, and startup: `anvil-surface-latency-vw_dkyll` and `anvil-surface-latency-3bm8lnn5`.
- Startup red: `anvil-surface-latency-d66mr1dl`.
- Hidden confirmation red: `anvil-surface-latency-k4roh0ih`.
- Confirmation greens: `anvil-surface-latency-ne5semq4` and `anvil-surface-latency-mrwc7qpu`.
- Terminal output red: `anvil-surface-latency-e3f346bl`.
- Idle scheduler red: `anvil-surface-latency-c0yw3prh`.
- Final idle and background greens: `anvil-surface-latency-gtnq_53t` and `anvil-surface-latency-u3481i7l`.

Meson logs include `phase4-m1-render-complete.txt`, `phase4-m1-terminal-grid-red.txt`, and `phase4-m1-terminal-final.txt`.
Lua syntax, Python compilation, and `git diff --check` pass.

#### Isolated typing latency

Both builds used three runs of 120 samples per mode and renderer.
Each row has 360 valid samples and no failed samples.
No correctness check or build ran during either measurement.
Values are p50 / p90 / p99 / maximum / mean, in milliseconds.

| Mode | Before | After |
| --- | --- | --- |
| Direct D3D11 | 7.25 / 16.27 / 19.68 / 52.17 / 8.76 | 6.95 / 16.34 / 18.76 / 58.52 / 8.51 |
| Hosted D3D11 | 7.38 / 16.15 / 19.86 / 24.74 / 8.89 | 6.94 / 15.62 / 18.89 / 19.79 / 8.65 |
| Direct software | 17.42 / 26.34 / 30.57 / 31.56 / 18.59 | 17.93 / 26.76 / 31.58 / 32.99 / 18.97 |
| Hosted software | 10.33 / 19.85 / 23.29 / 25.10 / 12.08 | 11.76 / 20.13 / 22.84 / 27.28 / 12.65 |

Hosted D3D11 has no measured median increase over direct D3D11 in this comparison.
The software median increased. Its hosted p99 decreased, while direct p99 increased by 1.01 ms.
These samples do not establish a cause or a performance gain. Maximum values remain variable.
The measurement ends at Present, not physical display scanout.

Before evidence: `anvil-surface-latency-abhxr76a`. After evidence: `anvil-surface-latency-o3fp_z8y`.
Milestone 1 is complete. The warned dev portable update rebuilt, installed, and restarted Anvil.
The fresh session and startup logs contain no errors, warnings, or startup failures.
Phase 3 physical-input, IME, and mixed-DPI checks remain open. Hosted mode remains opt-in.

### Milestone 2: several loaded Projects

Each Project now owns its process, pipe, workers, queues, configuration, dialogs, and Close state.
The Window owns one compositor and selects one Project for presentation and input.
Project records stay alive until shell exit. Queued packets retain their owner and connection tag.
Every connection gets a unique shell-wide tag. Late packets cannot enter a replacement connection.

The hosted Project selection request no longer changes the caller's directory or closes its Workspace.
The shell compares normalized Windows paths with Unicode ordinal case-insensitive comparison before loading another Project.
Selecting a loaded Project retains its process, Editors, text selections, workers, and Terminal clients.
Selection cancels capture and composition, changes focus, and sends rendering permission through each owned stream.
The shell releases the previous shared frame before presenting another Project.
It discards unselected frames before opening their resources.
Unselected window geometry requests do not change the Window. Dialog requests wait until their Project is selected.
Explicit Raise can select its owning Project, including a Project reached through IPC.

Project launch runs on a native worker. It cannot hold the native Window event loop during process creation.
Restart replaces only its Project. Native GPU recovery remains explicit, without automatic fallback.
Window Close checks Projects in turn. Cancel stops further requests and permits later Project selection.
An accepted Close remains complete. Force close still targets only its owned Project handle.
Shell shutdown shares one transport cleanup deadline across all Projects.

#### Targeted red-green evidence

- `loaded-switch` failed before the change: `Project selection changed A's directory`.
  Evidence: `anvil-surface-latency-r6ayeqo2`.
  The final case checks A–B–A process identity, live text, Editor identity, text selection, and Terminal attachment.
  It also checks hidden coroutine progress, worker results, Terminal output, Close cancellation, and final Window Close.
- With launch work temporarily moved onto the native UI thread, `loaded-launch` failed.
  Failure: `native Minimize waited for Project launch`.
  Evidence: `anvil-surface-latency-kraupin7`.
  The restored worker path passes native Minimize and Restore while the owned launch worker waits.
- The ownership change exposed the existing suspended Force-close regression again.
  Failure: `Force close left the failed shell open`.
  The Close flow waited for process exit after Force had completed.
  The accepted Force result now advances Close directly. D3D11 and software checks pass.

The worker submission and Buffer text expectations needed fixture corrections during development.
Those failures do not establish runtime defects.
The native routing fixture also needed explicit rendering permission after Milestone 1's protocol change.
Its publication check passes with that required configuration field set.

Review also found a dialog lifetime error when a synchronous callback cannot retain its result.
The callback can free the dialog before the show function returns.
The show function now retains the property handle locally and does not access the dialog after that call.
This fix came from inspection. No reproducible allocation-failure red test was available.
Ordinary dialog error, late-result, Close, and loaded-switch cases check the affected path on both renderers.
Final lifetime-fix evidence: `anvil-surface-latency-rru1iljx` and `anvil-surface-latency-nriv4xoc`.

#### Focused verification

The three new owned-window cases pass on D3D11 and software:
`loaded-switch`, `loaded-launch`, and `loaded-restart`.
Final D3D11 evidence: `anvil-surface-latency-jzowco2l`.
Software evidence: `anvil-surface-latency-y9g1xv3i`.

Affected startup, transport cleanup, Force close, dialogs, input routing, motion, and resource failures pass.
D3D11 evidence includes `anvil-surface-latency-wcbtlpu0` and `anvil-surface-latency-74z1nu3j`.
The software matrix uses `anvil-surface-latency-y9g1xv3i`.
Direct Quit, nonzero Quit, Restart, Project switch, and New Window pass in `anvil-surface-latency-5djmzeoa`.
Direct `launch` and `close` were invalid fixture invocations, not runtime acceptance checks.

Three native targets pass: hosted dialogs, hosted routing, and stalled hosted motion.
Focused Lua checks pass: 16 Workspace tests, five Terminal quit tests, and 34 untitled recovery tests.
Logs: `phase4-m2-native-final`, `phase4-m2-workspace`, `phase4-m2-quit`, and `phase4-m2-recovery`.
Lua syntax, Python compilation, the native build, and the scoped whitespace check pass.
No test captures pixels, uses user windows, or establishes physical-input, real IME, or mixed-DPI acceptance.

#### Isolated latency evidence

The initial comparison used three runs of 120 valid samples per row, without overlapping builds or correctness checks.
Values below are p50 / p90 / p99 / maximum / mean, in milliseconds.

| Mode | Before | After |
| --- | --- | --- |
| Direct D3D11 | 7.32 / 15.67 / 19.14 / 43.80 / 8.61 | 7.36 / 17.07 / 19.52 / 50.94 / 8.88 |
| Hosted D3D11 | 7.03 / 16.38 / 18.72 / 19.00 / 8.84 | 7.20 / 16.55 / 27.29 / 129.90 / 9.77 |
| Direct software | 18.35 / 27.11 / 31.46 / 33.72 / 19.48 | 16.10 / 24.43 / 29.96 / 32.18 / 16.79 |
| Hosted software | 10.67 / 19.56 / 23.51 / 25.78 / 12.16 | 12.07 / 20.59 / 23.90 / 96.39 / 13.49 |

Before evidence: `anvil-surface-latency-3co2jsj0`. After evidence: `anvil-surface-latency-xj98umm_`.
The hosted D3D11 p99 and maximum increased. That result required another comparison before deployment.

The matched comparison used the saved baseline executable and current executable with one fixed app-data copy.
Each row alternated builds for three runs of 120 valid samples per build.
No build, correctness check, or other latency run overlapped this comparison.

| Mode | Saved baseline | Current |
| --- | --- | --- |
| Direct D3D11 | 7.68 / 17.24 / 19.91 / 54.57 / 9.22 | 7.63 / 16.84 / 19.57 / 21.00 / 8.99 |
| Hosted D3D11 | 6.89 / 16.57 / 19.88 / 22.17 / 8.75 | 6.94 / 17.25 / 20.06 / 27.40 / 9.02 |
| Direct software | 16.68 / 25.87 / 29.72 / 30.37 / 17.67 | 17.65 / 25.40 / 29.32 / 32.13 / 18.01 |
| Hosted software | 11.27 / 20.84 / 24.01 / 25.74 / 13.14 | 10.85 / 19.70 / 23.52 / 26.96 / 12.58 |

Matched evidence: `anvil-m2-review-latency-gvbjqvl4/results.json`.
The initial hosted tail increase did not repeat at that size in the matched comparison.
The hosted D3D11 median increased by 0.05 ms and p99 by 0.18 ms.
Direct software's median increased by 0.97 ms. Maximum values remain variable across both comparisons.
These runs do not establish a cause or a performance gain. The measurement ends at Present, not physical scanout.

Milestone 2 is complete. The warned portable update rebuilt, installed, restored data junctions, and restarted Anvil.
Fresh logs contain no errors, warnings, or startup failures:
`anvil-20261008-200827-p30188.log` and `anvil-startup-20261008-200827-p30188-m288554.log`.
Hosted mode remains opt-in. Physical input, real IME, and mixed-DPI acceptance remain unavailable.

### Milestone 3 preparation: Project identity and selection rules

First launch and later selection now use one handle-based Project identity function.
It opens the directory and resolves its name with `GetFinalPathNameByHandleW`.
The cached identity uses Unicode ordinal case-insensitive comparison and removes trailing separators except at roots.
Junction and 8.3 aliases resolve to the same directory identity.

All identity file system I/O runs on resolve workers, including initial command-line path selection.
Workers receive copied paths and arguments. The native UI matches or creates Projects after completion.
The pending queue is bounded. A temporary native timer drains results when event delivery fails.
Selection allocation failure logs the rejection and leaves the current connection alive.
Selection sends keyboard focus only when the Window has input focus, with the existing latency-probe exception.

Targeted red-green evidence:

- `identity-trailing` and `identity-cwd` failed before the identity change with a second Project process.
  Evidence: `anvil-surface-latency-23t9l4ff`.
  An earlier fixture run left IPC forwarding enabled and did not establish the required red.
- The junction-first alias case fails with the saved `229d0618` executable.
  Evidence: `anvil-surface-latency-2kc0gti9`.
- `loaded-focus` failed with unconditional focus: selection gave focus to a minimized Window.
  Evidence: `anvil-surface-latency-nup23cc6`.
- Injected identity allocation failure reproduced the previous Failed-connection behavior and the Project stopped answering.
  The log confirms the consumed allocation fault. The corrected case retains the same live Project.
  Evidence: `anvil-surface-latency-nup23cc6`.
- Temporarily waiting for the identity worker on the native UI thread blocked Minimize.
  Evidence: `anvil-surface-latency-808fblm6`.
  The asynchronous case keeps native Minimize and Restore responsive during the owned seven-second identity delay.

Seven targeted cases pass on both renderers, including case, trailing-path, junction, and available 8.3 aliases.
Evidence: `anvil-surface-latency-p9m0yrp7` and `anvil-surface-latency-tle95y2z`.
The fixture obtained a real 8.3 alias on this file system.
Final cleanup and copied-input checks pass in `anvil-surface-latency-avotor7w`.
Three focused native targets pass in `phase4-identity-native.txt`.
Loaded Restart and both startup-timer recovery cases pass in `anvil-surface-latency-vemxxflo`.
Direct Quit, Restart, and Project switch pass in `anvil-surface-latency-sc5sjmgy`.

`loaded-quit` tests the current Quit rule with two loaded Projects.
A accepts Quit. The Window then asks about B's dirty Buffer.
Cancel keeps B and its Buffer alive, without restoring A. Later Window Close completes normally.
Unload remains separate Milestone 3 work.

Isolated latency after these fixes used three runs of 120 valid samples per row.
No build or correctness check overlapped the measurement.
Values are p50 / p90 / p99 / maximum / mean, in milliseconds.

| Mode | After identity and selection fixes |
| --- | --- |
| Direct D3D11 | 7.99 / 16.92 / 19.34 / 48.38 / 9.10 |
| Hosted D3D11 | 8.01 / 17.61 / 19.71 / 27.61 / 9.63 |
| Direct software | 12.17 / 21.60 / 25.47 / 42.76 / 13.72 |
| Hosted software | 11.61 / 19.62 / 23.52 / 25.29 / 12.67 |

Evidence: `anvil-surface-latency-8j2fapye`.
The prior matched `229d0618` measurements remain above. These later runs are not a matched comparison.
Software timing changed across runs. No performance gain or cause is established.
The measurement ends at Present, not physical scanout. Physical-input, IME, and mixed-DPI gates remain open.

The warned portable update rebuilt, installed, restored data junctions, and restarted Anvil.
Fresh session and startup logs contain no errors, warnings, or startup failures:
`anvil-20261008-211500-p1956.log` and `anvil-startup-20261008-211500-p1956-m839853.log`.
