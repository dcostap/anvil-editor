# Phase 5 milestone 3: Project Move

## Status

Implemented and deployed. The user approved milestone 3 after `f565e01c` and `ec0e91a3`.
The user has since authorized milestone 4. Hosted mode remains opt-in.
Commit this milestone and stop for review. This record retains the failed runs and open acceptance gates.

Focused checks pass in `phase5-m3-final-native.txt`, `phase5-m3-final-view.txt`, and `phase5-m3-final-direct.txt`.
These cover five native targets, the Sidebar View file, and direct Project launch commands.
LuaJIT syntax, Python compilation, and all five runner tests also pass.
The final normal-build Move matrix passes on both renderers, including visibility checks on focus packets.

The user authorized work to resume with memory monitoring after the memory investigation.
On 2026-10-10, Windows reported 3,888,112 KiB of free virtual memory, with 27,239,016 KiB of free physical memory.
The failed hosted dialog check reported allocation failures during startup, before it created the test state.
The snapshot alone does not prove that Windows' commit limit caused those failures.
Do not treat its timeout as a pass or increase a timeout.
Do not stop the user's workloads to free memory.

## Changes under test

- Protocol 14 adds an explicit Project ID and target Window ID for Move.
- The Sidebar offers target Windows after a right-click on a loaded Project.
- A left-click on a target submits Move. A right-click alone does not move the Project.
- The shell validates both Windows, Close choices, and native dialogs before changing the assignment.
- Rejections show status messages. They do not queue a later Move.
- The source selects another assigned Project. A source left without a Project closes.
- The target retains its previous Project as loaded and unpresented.
- Move retains the Project reference through the transition. It does not restart the Project or detach Terminal Sessions.
- Window identity now changes layout identity, even when the surface sizes are equal.
- Selection clears native composition. Text input requires a visible, focused target.
- First assignment to a minimized Window uses that Window's retained surface dimensions.
- The Sidebar keeps a font for each live scale. Activation does not resize a shared font.
- Unused scale entries are removed. Mixed-DPI manual acceptance remains open.

The existing owning-Window selection path already implements the required policy.
The new test selects A from B's Sidebar while A is unpresented and its Window is minimized.
It checks that A becomes selected in its restored owning Window, while B stays unchanged.
This synthetic check does not establish physical foreground or input behavior.

## Red-green evidence

### Window identity

`phase5-m3-window-epoch-red.txt` failed before the layout change.
The public protocol seam must treat equal-sized Windows with different IDs as different configurations.
`phase5-m3-window-epoch-green.txt` passed after the change.
Existing transport checks cover stale input, frames, and IME areas through configuration epochs.
These checks do not establish real IME or instrumented lifetime safety.

### Sidebar Move choices

`phase5-m3-move-view-red.txt` failed before the View action existed.
`phase5-m3-move-view-green.txt` passed after the change.
The test drives the View mouse handlers and checks explicit Project and target Window IDs.
It also checks that right-click alone sends no Move.

### Move API and transition

`anvil-surface-latency-lexa8_q_` timed out waiting for the first Move.
Its Project log records `hosted Project Move API is missing` against the retained 2b executable.

`anvil-surface-latency-hnpsjtle` passed the occupied-target transfer, then lost the moved Project connection.
The minimized empty target supplied controls outside the source's retained surface dimensions.
The frontend rejected that configuration as an invalid packet.
The change now uses the minimized target's retained dimensions on first assignment.

`anvil-surface-latency-o6l_5nis` passed all three D3D11 cases:

- `windows-move`
- `windows-move-close`
- `windows-move-dialog`

The Move case checks the Project PID, Buffer text and selection, active Editor, persisted Workspace pane state,
Terminal Session ID, host PID, and attachment count.
It checks occupied and minimized-empty targets, source selection, target retention, and a return Move.
Later fixture changes also cover a normal empty target and the actual Sidebar Move mouse action.

### Close and native-dialog rejections

The guards were temporarily disabled after the first green run.
Both rejection tests failed in `anvil-surface-latency-3hq1l_j9`:
`Move rejection did not show its status message`.
The guards were restored without changing any timeout.

The tests require these messages:

- `Cannot move Project during a pending Close choice.`
- `Cannot move Project while a native file dialog is open.`

They also check unchanged assignment and no deferred Move after the blocker ends.
The dialog retains its original parent.

### Latest run and memory blocker

`anvil-surface-latency-bun6ybjt` passes `windows-move` and `windows-move-close` on D3D11.
This run includes the normal empty target and actual Sidebar Move input.
Its `windows-move-dialog` exits 124 without a result.
The Project fails to load mandatory defaults because it cannot allocate memory.
The driver also reports `Fatal error: not enough memory`.
No `a-ready.lua` exists. This failure precedes the Move or native-dialog test state.
Retain this failure. An unchanged passing repeat would not remove it.

### Memory investigation

The user asked for a check of the memory diagnosis.
`GetPerformanceInfo` and `GlobalMemoryStatusEx` agree with the WMI reading.
The first direct snapshot records 122,449,186,816 committed bytes against a 125,600,153,600-byte limit.
That leaves 3,150,966,784 bytes, or about 2.9 GiB, while 27,543,896,064 physical bytes remain available.
The low commit capacity is real. Free physical RAM does not measure unused commit capacity.

The built LuaJIT CLI reports x64 and GC64 enabled. It links the same LuaJIT library as Anvil.
The GC64 heap does not have the old 2 GiB limit.
Individual Lua strings and buffers still have separate length limits.
The private-desktop runner sets only kill-on-close policy on its Job Object, not a memory cap.

A temporary allocator probe records failed Windows mappings, request sizes, and Windows error codes.
Two isolated D3D11 dialog repeats pass with that probe:
`anvil-surface-latency-nfzx8je9` and `anvil-surface-latency-gfueiq01`.
No mapping-failure record is produced. The original allocation failure is not reproduced or explained.

The second repeat has 148 retained system samples, including 17 with owned test processes.
The samples show a minimum of 614.336 MiB of available commit capacity.
At that point, 23.916 GiB of physical RAM remains available.
The seven owned Anvil processes reach a combined private allocation peak of 2.232 GiB.
These measurements show little remaining capacity, but they do not prove that the test cannot run.
The earlier statement that hosted tests necessarily exceed available capacity was too strong.

Raw samples: `%TEMP%/pi-bash-bg-dd0f2c05b9ced8ff.log`.
Sampler: `%TEMP%/anvil-memory-check.py`.
No user workload was stopped, and no page-file setting was changed.
The allocator probe was removed, and its source hash matches the original:
`1a68f19342204bb6b1c27124e9e647a49a821a554c51725c146ce41319623274`.
The normal build is rebuilt without the probe. These diagnostic repeats are not latency measurements.
They do not complete the remaining both-renderer or deployment gates.

### Target Close choice

Review found a second Close-choice boundary: the target and requester can be the Window awaiting Close.
`anvil-surface-latency-spa43_rr` fails because the Project API reports `Project or target Window is unavailable`.
The Close-choice guard now runs before the requester-Closing rejection.

`anvil-surface-latency-r9w0aftk` then fails through the actual Sidebar action.
The Sidebar log shows the explicit Move request; the shell silently discards it as a closing-surface request.
An authenticated Move from a live Window awaiting Close now reaches the Close-choice status rejection.
The shell still discards all other closing-surface requests and all requests from removed Windows.
No rejected Move enters a queue.

The intermediate software run `anvil-surface-latency-y1k2d_ct` passes the status check but fails the later occupied-target Move.
The fixture's A process wrote the cancellation marker before B cancelled its own Close choice.
The fixture now lets only the blocking Project cancel, and waits for the shell's cancellation result.
Retain this fixture failure; it does not prove a Move regression.

### Final correctness matrix

All four cases pass on the final normal build:

- `windows-move`
- `windows-move-close`
- `windows-move-target-close`
- `windows-move-dialog`

Software artifacts: `anvil-surface-latency-pbxac1ak`.
D3D11 artifacts: `anvil-surface-latency-e2i1iysf`.
The target Close case drives the actual Sidebar Move action.
The source Close and dialog cases use the authenticated hosted API.
The three rejection cases check that a rejected Move does not run after its blocker ends.

Relevant existing checks pass on both renderers:
`windows-open`, `windows-sidebars`, `windows-sidebars-recovery`, `routing`, `controls`, `dialogs`, `fault-busy`, and `fault-stale`.
Their artifacts are `anvil-surface-latency-0143ehqp` and `anvil-surface-latency-y1k2d_ct`.
The latter also retains the target-Close fixture failure described above.

Memory records remain in `anvil-phase5-m3-memory-*` directories under `%TEMP%`.
The final Move runs retain `i4beokev` and `l1zgud7l`, with minima of 1603.590 and 627.188 MiB.
The earlier successful normal-build matrix retains `487m51ox` and `n2ilvjis`, with minima of 1501.289 and 532.254 MiB.
These checks do not explain the earlier startup allocation failure.

## Fixture corrections

Retain these runs, but do not count their setup failures as runtime reds:

- `anvil-surface-latency-zwn6hdi7`: the runner omitted `ANVIL_INPUT_ROUTING_PROBE` for the new cases.
- `anvil-surface-latency-ti11qxs4`: the fixture saved its specimen before first-run Workspace setup completed.
  Startup then restored that saved Workspace and replaced the fixture's Terminal View.
  The fixture now lets first-run setup complete before creating the specimen.
  Its Terminal log also retains registry write error 5.
- `anvil-surface-latency-z12e_hat`: transfers completed, but the driver did not close the remaining empty Window.
- `anvil-surface-latency-0zzka3hl`: direct synthetic Win32 right-button messages did not reach the Sidebar action.
  The existing owned-input probe now supports right-button events through the SDL event boundary.
  It remains disabled outside test runs.

## Performance and deployment

### Matched latency

Evidence: `%TEMP%/anvil-phase5-m3-matched-an8opid7/results.json`, its six public-run files, and their retained app directories.
Runner: `%TEMP%/anvil-phase5-m3-matched-latency.py`.
Reference: `ec0e91a3`, saved executable and matching runtime under `anvil-surface-latency-ne4l3nuv/app`.
Reference SHA-256: `d06b961b7f9088d9bd8b56a29e04ee4d0d06563417821d72ad0758325328a4ac`.
Measured candidate SHA-256: `252103d5549ce0e026a40f788a704d51a1df4ef0f7f5bd598c676ff1f24c96b4`.
The record also contains both runtime trees' changed Lua hashes and memory readings before and after each public run.

Order: reference/candidate, candidate/reference, reference/candidate.
All runs use normal scheduling and a five-second warmup.
No build, correctness check, or other latency run overlaps these measurements.
All 24 cases exit 0, without timeout, with 120/120 matched inputs each.
Retain all 2,880 samples: 360 per row and executable.
All 48 environment boundaries report session 1 unlocked and display-on.

| Row | Oct. 10 baseline p50 | Reference p50 | M3 p50 | Difference | M3 p90 | M3 p99 | M3 max |
|---|---:|---:|---:|---:|---:|---:|---:|
| Direct D3D11 | 7.476 | 6.588 | 7.210 | +0.622 | 16.594 | 21.757 | 57.367 |
| Hosted D3D11 | 7.412 | 7.252 | 7.631 | +0.379 | 16.378 | 20.027 | 21.863 |
| Direct software | 15.350 | 16.601 | 17.834 | +1.233 | 26.026 | 31.814 | 65.172 |
| Hosted software | 11.596 | 12.256 | 11.654 | -0.602 | 20.625 | 23.787 | 55.974 |

All values are milliseconds. Generated input-to-Present is not physical input or scanout.
The hosted-software shift minus its matched direct shift is -1.835 ms.
This remains below the approximate 2 ms noise threshold. No gain or stable median regression is established.

Software per-pair direct/hosted shifts are +2.466/+1.007, -1.393/-2.394, and +1.883/+0.033 ms.
The reference maximum is 67.898 ms; the candidate maximum is 65.172 ms.
These tails remain unexplained and retained. Renderer defaults remain unchanged.
The valid earlier 37.731 ms reference median and 198.712 ms maximum remain in the 2b record.
The high median does not recur here. These new runs do not explain or invalidate the earlier run.

### Deployment

The save-files/process-stop warning preceded `update-anvil-dev-build.bat`.
The updater exited 0, restored all five source-data junctions, and restarted normal direct-mode portable Anvil.
Updater output: `%TEMP%/pi-bash-bg-b635944ce05bce22.log`.

- Build SHA-256: `3afd0ae28cec84974670afb75a0ab7f9365cdca206d06a06fec721c45fe03d96`.
- Portable SHA-256: `102ffe492d1d4890f5a8d120c13141c65cd8a35a7f14b9524b815b303654a76c`.

The build hash stayed unchanged through the updater.
An independently stripped build matches portable after PE timestamp/checksum normalization.
Independent stripped file: `%TEMP%/anvil-phase5-m3-independent-strip.exe`.

A comment correction after measurement acknowledges native callbacks inside Move.
The rebuilt image has the different raw hash above, but its runtime content matches the measured candidate.
The first comparison failed because the old normalizer omitted the PE export-directory timestamp.
Section comparison shows identical code, data, resources, imports, relocations, and unwind tables.
Only the export-directory timestamp differs after the old normalization.
The complete stripped images match after COFF/export timestamp and checksum normalization.
That comparison also matches the measured candidate against deployed portable, not only selected code sections.
Normalized SHA-256: `18951209e68ff87e88001ad2968f3e8953e5c4cc7e127afcd80426b6ce68125d`.
Helper: `%TEMP%/anvil-phase5-m3-compare-pe.cjs`.

Fresh logs under portable `user/logs`:

- `anvil-20261010-201312-p38752.log`
- `startup/anvil-startup-20261010-201311-p38752-m590446.log`

They show no warning/error/failure diagnostics.
The session log retains a 290.2 ms startup frame stall as an INFO diagnostic.
These synthetic latency checks do not explain that startup stall.
Normal fields such as `last_error=0` are not failures.

## Review and open gates

The Sidebar Restart [cause record](PHASE5_SIDEBAR_RESTART_CAUSE.md) satisfies the milestone-4 entry gate.
Physical input, real IME, mixed DPI, allocator-failure, and instrumented lifetime gates remain open.

### Review follow-up: Move choices across Sidebar revisions

Review of `f2742110` found that every Sidebar revision closed open Move choices.
Revisions also arrive for Terminal state and registry changes.
A click meant for a Move target could then land on the next Project row and select it.

Red: `ui/sidebar_view.lua` "keeps Move choices across Sidebar updates while the Project keeps its owner"
failed with `expected 3 but got 2` after a Terminal busy-state revision.
Green: the same file passes all six tests after the change.
The View now keeps Move choices while the Project exists, stays loaded, and keeps the same owning Window.
An owner change or unload clears them.

Trust boundary: the shell accepts `MOVE_PROJECT` from any authenticated hosted Project, not only the Sidebar.
This matches `SELECT_PROJECT` and `UNLOAD_PROJECT`. Restrict all three together if hosted Projects become less trusted.
