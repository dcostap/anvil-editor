# Phase 4 fresh latency baseline investigation

## Status

The latency baseline gate remains open. Do not start Phase 5 milestone 2.
Both freshly built revisions show the large slowdown in the locked, display-off session.
This is not a candidate-only regression. A candidate bisect is not justified by these results.
The cause of the environment or harness effect remains unproved.
An unlocked, display-on repeat remains necessary before accepting the baseline.
Do not switch Windows desktops or operate the user's Windows to obtain that control.

Hosted mode stays opt-in. Differences below about 2 ms remain noise.
The probe measures generated input to Present, not physical input or scanout.
The historical 761 ms to 9 s tails remain unexplained.
These comparisons do not measure the subsequent Sidebar follow-up commit.

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
