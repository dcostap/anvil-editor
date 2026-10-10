# Phase 4 fresh latency baseline investigation

## Status

The milestone-2 latency entry gate is closed (satisfied) on 2026-10-10.
The user confirmed Windows was unlocked with the display on. The runner confirmed both states.
The same fresh revisions completed the matched, alternating, non-diagnostic repeat with historical-range medians.
Both revisions showed the large slowdown in the earlier locked, display-off session, not a candidate-only regression.
The large shift did not repeat under normal console conditions. The exact environment mechanism remains unproved.
Phase 5 still awaits plan review. Do not start its implementation without approval.
Do not operate the user's Windows or switch desktops to obtain environment controls.

Hosted mode stays opt-in. Differences below about 2 ms remain noise.
The probe measures generated input to Present, not physical input or scanout.
The historical 761 ms to 9 s tails remain unexplained.
These comparisons do not measure the subsequent Sidebar follow-up commit.
The locked/display-off cases remain diagnostic evidence, not an eligible baseline or performance gate.

## Accepted unlocked/display-on baseline

Artifact: `%TEMP%/anvil-fresh-matched-unlocked-display-on-9yvhy_i6/results.json`.
The repeat uses the same fresh executables, matching hashes below, and each revision's own data.
Order, five-second warmup, 120-input case size, normal harness scheduling, and diagnostic-disabled settings remain unchanged.
No builds, correctness checks, or other latency runs overlap the repeat.
The private-desktop runner uses only isolated data and owned process handles. It does not operate the user's Windows.

All 24 cases pass strict completeness and environment validity checks: 2,880 inputs in total.
Each row contains three complete cases and 360 inputs per revision.
All 48 boundary snapshots report console session 1 unlocked and the display on.
Original samples, per-case results, launch files, tails, and maxima remain in the artifact.

Values are p50 / p90 / p99 / maximum / mean, in ms:

| Row | `9ea92aeb` | `81bccdaf` |
|---|---|---|
| Direct D3D11 | 6.717 / 16.360 / 19.484 / 50.694 / 8.561 | 7.476 / 16.973 / 20.660 / 39.378 / 9.090 |
| Hosted D3D11 | 7.090 / 16.074 / 19.934 / 22.171 / 8.797 | 7.412 / 16.759 / 19.665 / 21.365 / 9.090 |
| Direct software | 15.767 / 24.810 / 28.906 / 37.510 / 17.026 | 15.350 / 24.446 / 27.959 / 29.951 / 16.458 |
| Hosted software | 10.772 / 21.227 / 23.234 / 25.126 / 12.832 | 11.596 / 20.925 / 22.979 / 25.015 / 12.959 |

These medians return to the historical range in the Phase 4 four-row comparisons.
Candidate median differences are +0.759, +0.322, -0.417, and +0.824 ms respectively.
All are below the approximately 2 ms noise threshold. Do not claim a performance gain or regression from them.
The direct-D3D11 maxima of 50.694 and 39.378 ms remain retained. This result does not remove all tails.

The prior locked comparison used console session 2; this repeat uses session 1.
The results do not isolate lock state from display power or other session changes.
The Present-pacing controls locate the earlier direct delay, but do not explain the historical multi-second tails.
Those older causes remain open and separate from the satisfied baseline entry gate.

Only evidence and plan status changed in this slice. No runtime change, build, portable update, or Phase 5 implementation occurred.

## Fresh build method

Detached worktrees:

- `C:/Projects/c_projects/anvil-baseline-9ea92aeb`.
- `C:/Projects/c_projects/anvil-baseline-81bccdaf`.

Both worktrees have no tracked changes.
Both builds compile their native code and pinned dependencies from source.
The second worktree reuses downloaded dependency sources, not the first build's binaries.
Options match: MinGW GCC/G++, `debugoptimized`, optimization 2, portable, external runtime, and PPM disabled.

The first setup attempt selected MSVC and found GNU `link.exe`. It produced no measurements.
The corrected build sets `CC=gcc` and `CXX=g++` explicitly.
Build log: `%TEMP%/pi-bash-bg-88389406148612eb.log`.

Executable SHA-256:

- `9ea92aeb`: `3a5d60ce19acd7c198abe920b864bc8a832cad01e89003a612209c366ec47a8f`.
- `81bccdaf`: `7e36fa09fbc3fa5f66f1e9fcb108f6a8cfcc9fcad7e51d27cd862643e567ef5f`.

Each app copy uses its own revision's data and generated `start.lua`.
Both use the same current runner, isolated user/project directories, and owned process handles.
Detailed latency logging is off. Scheduling uses the normal harness setting, not fixed UI-thread affinity.
Warmup is five seconds. Each case requests 120 inputs.
Order per row is A/B, then B/A, then A/B in the same session.
No builds, correctness cases, or other latency runs overlap these comparisons.

## Console state

Every case records state before and after the run.
All 24 cases report console session 2 locked and the display off at both points.
The observer records WTS session flags and `GUID_CONSOLE_DISPLAY_STATE` notifications.
It does not capture pixels or change display power or lock state.
State samples cannot rule out an unobserved transient between samples.

Observer: `%TEMP%/anvil-console-state.py`.
Comparison script: `%TEMP%/anvil-fresh-matched-baseline.py`.

## Matched results

Artifact: `%TEMP%/anvil-fresh-matched-locked-display-off-xnk0w3z7/results.json`.
All 24 cases pass strict completeness checks: 120 matched inputs, successful exit, and no timeout.
Each row has 360 inputs per revision. Original samples, tails, and per-case results remain in the artifact.

Values are p50 / p90 / p99 / maximum / mean, in ms:

| Row | `9ea92aeb` | `81bccdaf` |
|---|---|---|
| Direct D3D11 | 133.625 / 174.838 / 184.044 / 186.033 / 132.143 | 135.622 / 174.083 / 184.261 / 188.360 / 131.441 |
| Hosted D3D11 | 240.155 / 329.711 / 356.079 / 364.921 / 227.074 | 243.654 / 331.211 / 356.528 / 360.295 / 232.005 |
| Direct software | 97.709 / 143.953 / 160.048 / 164.939 / 97.016 | 92.288 / 135.607 / 158.819 / 160.135 / 91.585 |
| Hosted software | 168.182 / 321.191 / 357.176 / 362.945 / 155.729 | 178.002 / 324.724 / 359.190 / 366.007 / 159.778 |

Hosted-software medians vary substantially between runs in both revisions.
Do not interpret the aggregate difference as a reliable candidate regression or improvement.
The common large shift remains the blocking concern.

## Reversible Present pacing control

Artifact: `%TEMP%/anvil-baseline-sync-control-jz543lql/results.json`.
Script: `%TEMP%/anvil-baseline-sync-control.py`.
All six direct-D3D11 cases complete 120 inputs successfully.
The control changes only `ANVIL_D3D11_PRESENT_SYNC_INTERVAL` and restores it afterward.
It does not change source code or the deployed renderer defaults.
Console state remains locked/display-off at the recorded boundaries.

Values are p50 / maximum, in ms:

| Sync interval | `9ea92aeb` | `81bccdaf` |
|---|---|---|
| 1, first | 132.011 / 184.141 | 16.379 / 178.435 |
| 0 | 6.594 / 28.423 | 9.740 / 33.239 |
| 1, restored | 139.619 / 184.624 | 137.312 / 188.250 |

Both revisions return to low direct latency with interval 0 and high latency after interval 1 is restored.
The first candidate interval-1 run has a lower median, but retains a large tail. Preserve that exception.
This control establishes sensitivity to Present pacing under the current conditions, not the reason for that sensitivity.
It does not establish a lock-state cause, explain software behavior, or resolve historical multi-second tails.
Do not disable vsync or change normal defaults as a workaround from this evidence alone.

## Direct frame-cost diagnostics

Artifact: `%TEMP%/anvil-baseline-present-stats-5uapklsf/results.json` and its per-case `d3d11-stats.csv` files.
Script: `%TEMP%/anvil-baseline-present-stats.py`.
These two runs enable existing D3D11 statistics. They are diagnostics, not additional non-diagnostic baseline samples.
Both complete 120 inputs successfully and record 188 frames, with sync interval 1.
The console remains locked/display-off at the recorded boundaries.

Whole-run frame CSV values are p50 / p90 / maximum, in ms:

| Cost | `9ea92aeb` | `81bccdaf` |
|---|---|---|
| Frame CPU interval | 89.556 / 91.149 / 93.132 | 87.997 / 90.733 / 92.674 |
| DXGI Present call | 89.484 / 91.086 / 93.075 | 87.880 / 90.647 / 92.576 |
| DwmFlush | 0 / 0 / 0 | 0 / 0 / 0 |

These frame distributions include startup and warmup. They are not per-input latency distributions.
The Present call accounts for most measured frame time in both revisions under these conditions.
This locates the direct D3D11 delay. It does not explain why Present waits this long.
It does not establish the cause of software or historical multi-second delays.

An earlier statistics attempt failed while reading a partially written console-state JSON file.
Its native 120-input result and CSV remain in `%TEMP%/anvil-baseline-present-stats-3xprnkux`.
The script now retries metadata reads. The linked rerun does not replace the original artifact.

## Runner environment validity

The runner now reads console state directly before and after each typing case.
`tools/windows_console_state.py` uses WTS lock flags and the initial console-display power notification.
It does not create an Anvil Window, change a desktop, unlock Windows, or change display power.
There is no persistent observer process or temporary state-file dependency.

Locked or display-off state at either boundary marks `environment_invalid=true` and `baseline_eligible=false`.
Unavailable state also excludes the case. Native completeness remains a separate `ok` result.
All raw samples and both state snapshots remain in the public JSON result.
Baseline summaries include only complete, environment-valid cases.
CLI exit 1 indicates failed or incomplete execution. Exit 2 indicates an invalid environment without execution failure.
Lifecycle correctness cases do not use the typing baseline gate.

Red-green seam: the public CLI and JSON result, with fakes only at the external launcher and console-state boundaries.
Before the fix, locked/off cases at either boundary returned success: `0 != 2: Invalid environment passed the public CLI`.
After the fix, all four focused tests pass, including normal state, unknown state, and the existing incomplete-probe check.
Command: `python -m unittest discover -s tests/tools -p test_surface_latency_probe.py`.
Python compilation and the diff check also pass.
An observation-only native read reports console session 2 locked and the display off.
At the tooling milestone, no new latency run started. The repeat awaited the user's confirmation.

The matched-repeat script now uses the runner's direct boundary snapshots and eligibility fields.
It does not read or overwrite results with the stopped temporary observer's state file.

### Tooling update verification

The user received the save-files/process-stop warning before the portable updater.
The updater completed and restored the editable data junctions. Native runtime code did not change in this slice.

SHA-256:

- Build: `9ce94e93844494de6bbabd50e0032479e8535e60cf21e4434760f86c9363eb41`.
- Portable: `df4257676a5b50ecf0f76e437c155522535c531bc2b612050a7ad26f751f919c`.

An independently stripped build matches the portable after PE timestamp/checksum normalization.
Fresh logs under the portable directory contain no warning/error/failure entries:

- `user/logs/anvil-20261009-160417-p3100.log`.
- `user/logs/startup/anvil-startup-20261009-160417-p3100-m345596.log`.
- `user/logs/anvil-20261009-160417-p3100-shutdown.log`.

The session records an accepted forced Quit about five seconds after startup. It does not establish a running daily Window.
No Window was reopened for verification.
Hosted mode remains opt-in. Physical input, IME, mixed DPI, allocator failure, and instrumented lifetime acceptance remain open.
