# Phase 4: several Projects and the Sidebar process

## Status

The user approved continued work while the Phase 3 physical-input, IME, and mixed-DPI checks remain open.
Hosted mode stays opt-in. The Phase 3 code reviews are complete.
Do not treat synthetic tests as manual acceptance.
Milestones 1, 2, and 3 are implemented and deployed.
Milestone 3 adds unload, Dormant Projects, safe runtime retirement, and local recovery.
Milestone 4 is implemented and deployed. Its focused checks and two isolated latency comparisons are complete.
The Sidebar process remains a later milestone.

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

#### Unload crash prerequisite

An unexpected exit clears the unload request and its reserved Dormant record.
Restart also clears this state. Close acceptance alone does not announce a normal nonzero exit.
An explicit exit announcement or Force close still permits an intentional nonzero exit.
The duplicate retirement declaration is removed.

Two owned-window cases hold B after Close acceptance, then crash only B.
One unloads Failed B into Dormant state and keeps A unchanged.
The other restarts B, then checks that Quit closes the Window and A.
Both failed before the fix in `anvil-surface-latency-cw_acj7a`.
Both pass on D3D11 in `anvil-surface-latency-johzfd4a` and software in `anvil-surface-latency-r2ss0a4_`.
The pending-launch unload case also passes. These checks use no user windows or pixels.

#### Milestone 4 model and data boundary

The shell owns the list. The first recent source supplies its order.
Later sources add new paths first, in source order. Existing paths never move when selected, loaded, or unloaded.
Canonical directory identity merges aliases. The identity and status workers perform all directory checks.
Every Dormant record remains listed, including earlier records when the Window has no loaded Project.
Selection reserves a list entry before creating another runtime. A full list rejects a new selection without closing its connection.

Each Project supplies its recent source and user directory through the authenticated connection.
`core.request_project_sidebar()` requests a snapshot. `core.project_sidebar` receives the completed Project array.
Each Project includes its path, stable row ID, runtime ID, PID, lifecycle, selection, and path availability.
Separate flags report a deferred file dialog and a pending Close choice.
Each Project includes its Terminal records. They report ID, host PID, shell label, cwd, attachment, and running/exited/lost state.
Busy state uses `1`, `0`, or `-1` for unknown. Old records without busy state remain unknown.
The host saves busy changes in its existing atomic record. No Terminal command is replayed.
The label uses the shell string, not a live OSC title. Bell state remains unknown.

One asynchronous job owns copied inputs. The native UI thread does not read registry files or query Terminal hosts.
The worker checks directory paths, record bounds, PID creation identity, and Terminal state.
The worker continues when the Window has no loaded Project. It does not hold Project runtime references.
The job queue holds one scan. Scans run about every two seconds, with cancellation between operations.
One scan accepts 256 Project paths, 32 Sessions per Project, and 512 registry entries.
Each record accepts at most 1 MiB. A scan reads at most 8 MiB of record data.
The private Lua state has no libraries or globals. It disables JIT and limits memory and instruction execution.
Incomplete scans retain missing previous records and report `status_limited`. They do not claim removal from incomplete evidence.
These bounds do not promise a wall-clock deadline for file system calls. The bounded shutdown still exits only the shell.

Surface protocol 10 adds source, query, and model messages. Snapshots use complete records in bounded pages.
The receiver waits for all pages and rejects mixed revisions. Required transport failures retain the existing failure rules.
The owned-window model probe reads this same snapshot API and selects its stable row ID.
Its file output and action messages require the exact isolated fault gate. They do not run in normal use.
No Sidebar drawing or Sidebar process is added here.

#### Milestone 4 red-green evidence

- Native order red: `phase4-m4-order-red.txt`, then `phase4-m4-order-green.txt`.
  The empty model failed with `Recent Projects did not initialize the list`.
- Lifecycle red: `phase4-m4-lifecycle-red.txt`, then `phase4-m4-lifecycle-green.txt`.
  The model omitted selection and pending-choice state. The test also keeps several Dormant records and stable order after load.
- Terminal status red: `phase4-m4-status-red.txt`, then `phase4-m4-status-green.txt`.
  The model did not accept Terminal status. The green checks owned copies, detach updates, and removal.
- Owned model red: `anvil-surface-latency-3mnp93e3` lacked the snapshot API.
  The green checks recent order, new-first order, deferred dialogs, Close choice/Cancel, multiple unloads, and empty-Window selection.
- Native controls red: `anvil-surface-latency-jxu993kh` ran the delayed worker synchronously.
  It failed with `Path checks blocked native Minimize`. The asynchronous worker passes the same case.
- Real Terminal red: `anvil-surface-latency-7r58qkyl` reported busy `-1` for the kept busy Session.
  The host now records busy state. The green checks the same host, Session ID, detached state, cwd, and one command execution.
- Native page red: `phase4-m4-native-pages-red.txt` disabled snapshot publication.
  The green reconstructs complete pages and preserves record order, cwd, and quoted UTF-8 text.
- Lua page red: `phase4-m4-pages-red.txt` lost `status_limited` while combining pages.
  The green also rejects mixed model revisions through the public request/event boundary.

Fixture corrections do not count as runtime fixes. The driver now retains process handles before unload.
It waits for Dormant model state, not merely an exited process signal, before checking the empty Window.
The initial event handler also needed `_G.type` because its event name parameter already uses `type`.

Focused final checks pass: four native targets, two snapshot cases, five Terminal quit cases, and sixteen Workspace cases.
Native logs use `phase4-m4-native-final`; Lua logs use `phase4-m4-pages-final`, `phase4-m4-quit-final`, and `phase4-m4-workspace-final`.
D3D11 owned cases pass in `anvil-surface-latency-5p90szjz`; software cases pass in `anvil-surface-latency-4re1q3zd`.
Both sets include the two unload crash cases. D3D11 also checks loaded Restart and late dialogs.
Direct Quit, Restart, and switch pass in `anvil-surface-latency-ytqttt9g`.
Both renderer model checks also passed in `anvil-surface-latency-akdt83r8` and `anvil-surface-latency-aleiafqj`.
The final worker checks pass in `anvil-surface-latency-hwg_lwse` and `anvil-surface-latency-v42ar8s6`.
These checks follow inspection fixes for finite PIDs, exact ASCII record IDs, and the bounded interpreter.
Syntax, scoped formatting, Python compilation, and `git diff --check` pass.
Allocator-failure and memory-instrumentation acceptance remain open. Synthetic checks do not establish physical input or scanout.

The matched latency check alternates the prerequisite, Milestone 3, and Milestone 4 binaries.
It uses one fixed isolated data copy. A startup-only check skips the new source API in older binaries.
This check exists only in the benchmark copy, not production code. It leaves the Milestone 4 source update enabled.
No build, correctness case, or other latency run overlaps this measurement.

#### Milestone 4 isolated latency

The first comparison completed all 36 runs. Each row and binary has three runs and 360 valid samples.
Every run completed 120/120 samples, exited with code zero, and avoided the runner timeout.
Artifact: `anvil-m4-review-latency-20261009/results.json` under the machine's temporary directory.
The table gives p50 / p90 / p99 / maximum / mean, in milliseconds.

| Row | Prerequisite `35e5e426` | Milestone 3 `e751f6f9` | Milestone 4 |
| --- | --- | --- | --- |
| Direct D3D11 | 8.02 / 27.45 / 3816.58 / 4233.86 / 213.15 | 8.02 / 18.16 / 227.23 / 532.47 / 14.91 | 6.96 / 16.78 / 19.48 / 23.37 / 8.83 |
| Hosted D3D11 | 7.82 / 16.49 / 20.02 / 21.21 / 9.28 | 8.03 / 16.85 / 21.19 / 32.50 / 9.43 | 7.70 / 16.81 / 19.65 / 23.96 / 9.18 |
| Direct software | 19.10 / 3828.64 / 7978.96 / 8528.06 / 822.19 | 16.22 / 25.15 / 29.82 / 32.64 / 17.26 | 16.86 / 26.23 / 31.86 / 41.14 / 17.97 |
| Hosted software | 11.85 / 20.92 / 24.47 / 52.64 / 13.35 | 11.73 / 20.96 / 24.91 / 41.05 / 13.34 | 13.48 / 1544.88 / 5675.21 / 6215.12 / 440.39 |

The M3 direct median increase over the prerequisite did not repeat in this comparison.
M4 direct software increased by 0.64 ms over M3. Direct D3D11 decreased by 1.06 ms.
The first comparison also has multi-second tails. M4 hosted software has a 6215.12 ms maximum.
The prerequisite has 4233.86 ms and 8528.06 ms maxima. M3 direct D3D11 has a 532.47 ms maximum.
These completed runs remain evidence. Their causes are unproved; do not remove them or claim a performance gain.
A second isolated M3/M4 comparison completed all 24 runs with the same binaries and fixed data.
Every run completed 120/120 samples and exited with code zero. Each row and binary has 360 valid samples.
Artifact: `anvil-m4-repeat-latency-20261009/results.json` under the machine's temporary directory.

| Row | Milestone 3 | Milestone 4 |
| --- | --- | --- |
| Direct D3D11 | 7.00 / 17.44 / 20.61 / 27.76 / 9.03 | 8.21 / 17.12 / 20.23 / 23.41 / 9.40 |
| Hosted D3D11 | 8.06 / 18.79 / 955.24 / 1498.42 / 35.06 | 8.58 / 18.88 / 58.92 / 132.86 / 11.42 |
| Direct software | 18.89 / 1756.99 / 6075.94 / 6605.48 / 475.02 | 16.98 / 25.80 / 30.47 / 31.96 / 18.04 |
| Hosted software | 12.46 / 21.88 / 25.29 / 36.35 / 13.80 | 15.29 / 32.64 / 87.50 / 105.66 / 19.84 |

The direct software increase of 0.64 ms did not repeat. The second comparison decreased by 1.91 ms.
Direct D3D11 instead increased by 1.21 ms. These direct changes are not stable across the two comparisons.
Hosted software increased in both comparisons: 1.74 ms, then 2.84 ms. Report this repeated median increase explicitly.
Its multi-second M4 tail did not repeat, but its second p99 remains higher than M3.
M3 now has multi-second tails on hosted D3D11 and direct software. Their causes remain unproved.
The results do not establish a performance gain or its cause. Preserve both comparisons, including their tails.
The API registration table received whitespace cleanup after measurement. The measured functional code stayed unchanged.
The subsequent compile, four native checks, two snapshot cases, syntax checks, and diff checks pass.
Their logs use `phase4-m4-commit-native` and `phase4-m4-commit-pages`.
The measurement ends at Present, not scanout. It does not establish physical keyboard latency.

#### Milestone 4 deployment

The user received the save warning before the portable update. The warning explicitly included Terminal Session and command termination.
The updater exited with code zero. It installed the current build, restored source-data junctions, and restarted Anvil.
Fresh logs contain no errors or warnings:

- `anvil-20261009-020515-p31312.log`
- `startup/anvil-startup-20261009-020515-p31312-m501679.log`

SHA-256 values:

- Current build: `5183f9d27c76b7f1d662b12a728f38f157c17d5caff5faf3cd0a1ef0a80f36df`
- Portable executable: `8d21844452b332f8730e5ffc040769fad31f546790db8f769c3a57a173d56473`
- Measured M4 executable: `534fc7b39b2aece59f5a5eb2b01d680402f9c14fd476a31bbb0a3426e6279b9d`
- Saved M3 portable reference: `1d122fb5c437c35f9274d6938c072152cbd6a8e7dee89a795e0419e384bb44f6`

Stripping a build copy matches the portable executable except its PE timestamp and checksum.
The independent strip changed those header fields. The remaining bytes match after clearing only those fields in memory.
The measured build precedes the API table's whitespace cleanup. No functional source change followed its measurements.
Physical-input, IME, mixed-DPI, allocator-failure, and memory-instrumentation acceptance remain open. Hosted mode remains opt-in.

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

### Milestone 3: unload, Dormant Projects, and local recovery

Surface protocol 9 adds an explicit unload request.
The hosted `core:unload_project` command uses the normal unsaved-data and Terminal choices.
Cancel keeps the Project loaded and permits a later unload.
Accepted unload waits for that Project to exit. It does not end another Project or the Window.
The shell retains a separate Dormant record with the Project identity, path, title, and ID.
Selecting it starts a new Project process and loads its saved Workspace.
Unloading the last Project retains the Window with native Load Project and Close Window actions.
Selecting a Failed Project does not start it. Native Restart remains explicit and local.
Quit from either a selected or background Project closes the Window and checks the other loaded Projects.

Runtime ownership:

- The loaded registry owns one runtime reference.
- Inbound packets, launch jobs, reader and writer workers, file dialogs, and Force dialogs retain their runtime.
- Outbound packets belong to their writer queue. They do not retain that same runtime.
- Retirement cancels transport and polls completed workers without waiting for their exit on the native UI thread.
- A native timer continues retirement when no Project supplies events.
- The shell drops the registry reference only after it joins transport workers and drains owned packets.
- Late callbacks retain their storage but cannot deliver into a new connection.
- Loading clears the empty-Window record's borrowed path before it frees the Dormant record.
- Launch setup failure releases its copied arguments and runtime reference before returning.

The launch setup and borrowed-path fixes came from inspection.
No allocator-failure reproduction established a red for those lifetime paths.
The pending-dialog case checks ordinary unload, reload, late callback disposal, and continued native control use.
It is not allocator-failure or memory-instrumentation acceptance.

Targeted red-green evidence:

- The first `dormant-unload` run failed because the unload command was unavailable: `anvil-surface-latency-hss0aeuq`.
  It now checks B's process exit, unchanged A and Window, a new B process, saved text, and restored selection.
- A pending-launch guard reproduced retained B: `anvil-surface-latency-d8kkzhte`.
  The earlier `luzs4qqg` pass did not enable the launch fault gate. It is not pending-launch evidence.
- The actual pending-launch run then exposed a transport setup error: `anvil-surface-latency-gga9dy_w`.
  Close had removed the startup timer before launch completion. The transport now accepts that pending Close state.
  The green checks the armed seven-second delay and native Minimize and Restore during unload.
- Disabling only the unload cancellation reset made a later unload retain B: `anvil-surface-latency-2zvbo33v`.
  Restoring it passes Cancel, retained unsaved text, unchanged process identity, and a later successful unload.
- Immediate Restart after B's crash forwarded to B's stale IPC record: `anvil-surface-latency-ow4xu3xd`.
  Startup now ignores same-Window records because the shell owns that Window's Project selection.
  Other-Window duplicate forwarding and direct behavior remain separate checks.
- Background Project Quit did not check B: `anvil-surface-latency-zaiv4aae`.
  The accepted background exit now starts the same sequential Window Close policy.

The Terminal fixture initially searched only the active Pane for B's Editor.
It now searches restored Pane views. This fixture correction is not a Workspace fix.
The hang fixture also needed enough time for two real five-second Close decisions.
That timeout correction is not a runtime fix.
The initial empty-Window Close check passed. It did not establish a red.

Owned-window checks:

- `dormant-dialog`: unload B with its owned native file dialog pending; load B; then complete the old callback.
- `dormant-last` and `dormant-last-close`: retain an empty Window, load the saved Workspace, and accept native Close.
- `dormant-terminal`: Keep retains the host, Session ID, and one attachment after load. The command marker remains single.
- `dormant-terminal-end`: End stops the owned Terminal shell while A and the Window survive.
- `dormant-terminal-cancel`: Cancel retains B and its attached Terminal; a later Keep and unload succeeds.
- `dormant-crash`: B's crash leaves A live; selection does not restart B; explicit native Restart replaces only B.
- `dormant-hang`: suspend only B; select A; choose Wait; use native controls; explicitly Force close B and load it.
- `dormant-background-quit`: A quits while hidden; B's unsaved confirmation appears; Cancel retains B and its text.

These checks reuse the private-desktop runner and owned process handles.
The native control probe drives the existing control actions only with the isolated fault gate enabled.
The fixture resumes its owned suspended process during failure cleanup.
It ends only its owned retained Terminal host after verification.
No check captures pixels or uses user windows.

Green evidence under `%LOCALAPPDATA%/Temp`:

- Pending launch, pending dialog, and last-Project load: `anvil-surface-latency-3h50o24z`.
- Live Terminal reattachment: `anvil-surface-latency-ow4xu3xd`.
- Local crash and hang recovery: `anvil-surface-latency-6uqg2rr8`.
- Seven software unload and recovery cases: `anvil-surface-latency-afh6hq7o`.
- Cancel, Terminal End and Cancel, and empty-Window Close: `anvil-surface-latency-kgsgtfuw`.
- Background Quit, loaded Quit, late dialog, loaded Restart, and affected unload cases: `anvil-surface-latency-tnopvwq4`.
- Remaining software cases: `anvil-surface-latency-27ct8dpc`.
- Final current-build D3D11 matrix, all twelve cases: `anvil-surface-latency-an3ma_jp`.
- Final affected software cases: `anvil-surface-latency-o6g2rrfl`.

Three native targets pass: hosted dialogs, hosted routing, and stalled hosted motion.
Focused Workspace and Terminal quit suites pass.
Logs: `phase4-m3-native.txt`, `phase4-m3-workspace.txt`, and `phase4-m3-terminal-quit.txt`.
Other-Window duplicate and conflict checks pass in `anvil-surface-latency-3bouqip5`.
Direct Quit, Restart, and Project switch pass in `anvil-surface-latency-bmsx5qvk`.
Lua syntax, Python compilation, the native build, scoped formatting, and `git diff --check` pass.

#### Isolated matched typing latency

The comparison alternated the saved prerequisite executable and current executable over one fixed app-data copy.
Each row has three runs and 360 valid samples per build. All 24 runs completed without sample loss.
No build, correctness check, or other latency run overlapped this comparison.
Values are p50 / p90 / p99 / maximum / mean, in milliseconds.

| Mode | Saved prerequisite | Milestone 3 |
| --- | --- | --- |
| Direct D3D11 | 7.48 / 16.64 / 20.54 / 55.21 / 8.96 | 8.06 / 17.19 / 21.49 / 28.13 / 9.58 |
| Hosted D3D11 | 7.25 / 16.66 / 19.85 / 43.72 / 9.04 | 7.35 / 17.36 / 19.75 / 21.93 / 9.25 |
| Direct software | 16.83 / 25.81 / 31.94 / 340.35 / 19.27 | 17.50 / 26.57 / 30.82 / 34.28 / 18.58 |
| Hosted software | 11.85 / 20.93 / 24.32 / 25.91 / 13.20 | 11.99 / 21.42 / 23.90 / 27.62 / 13.56 |

Evidence: `anvil-m3-review-latency-u4_9e8vv/results.json`.
Hosted medians increased by about 0.10 ms on D3D11 and 0.14 ms on software.
Direct medians increased by about 0.58 ms and 0.67 ms.
The baseline software maximum was 340.35 ms. Its cause is unproved.
These samples do not establish a cause or a performance gain. Maximum values remain variable.
The measurement ends at Present, not physical scanout.

Milestone 3 is complete. The warned portable update rebuilt, installed, restored data junctions, and restarted Anvil.
Fresh logs contain no errors, warnings, or startup failures:
`anvil-20261009-000534-p20712.log` and `anvil-startup-20261009-000534-p20712-m891518.log`.

Physical input, real IME, and mixed-DPI acceptance remain unavailable. Hosted mode remains opt-in.
The Sidebar model and process remain later milestones. Multiple Windows and adoption remain later phases.
