# Phase 5 milestone 1: per-Window native state

## Scope

This milestone moves native state into one `ShellWindow` record. It adds no several-Window behavior.
The record owns selection, empty state, Close sequencing, DPI, input capture, UI resources, and presentation resources.
Projects and identity jobs store their assigned Window record. Native callbacks resolve their owned record through an HWND property.
The retry timer retains the original connection tag and a stable Window ID.
Shell-wide Project identity, runtime lists, Dormant records, workers, and the Sidebar model remain outside the record.
Shell service notifications still use the first Window. Several-Window service lifetime remains later work.

The single Window record has static lifetime in this slice. Window removal is not implemented here.
No surface protocol, direct-mode path, or non-Windows path changes.
Hosted mode remains opt-in. Milestones 2a and 2b have not started.

## Correctness evidence

This refactor adds no observable behavior, so it adds no artificial structure test or runtime red.
The approved milestone-1 plan requires existing public/native checks before and after the refactor.

The initial D3D11 and software checks pass 12 cases each, except the old `controls` fixture.
Retained artifacts:

- `%TEMP%/anvil-surface-latency-j5yb08i0`: initial D3D11 matrix.
- `%TEMP%/anvil-surface-latency-2exafxpf`: repeated D3D11 header failure.
- `%TEMP%/anvil-surface-latency-nicqqpml`: initial software matrix.

The fixture tested caption drag inside the Sidebar Restart action. That area correctly returns `HTCLIENT`.
The corrected check finds a caption region through native hit testing.
The next run reached an old Restart coordinate based on the obsolete Sidebar width.
Those failures remain in `anvil-surface-latency-vhypss94` and `anvil-surface-latency-g7rxwapv`.
The fixture now calculates the Project origin from the reported surface width and the native client rectangle.

Both corrected checks pass with the unchanged saved binary, before testing the refactor:

- D3D11: `%TEMP%/anvil-surface-latency-t_ibijvy`.
- Software: `%TEMP%/anvil-surface-latency-r50797mi`.
- Saved executable SHA-256: `9ce94e93844494de6bbabd50e0032479e8535e60cf21e4434760f86c9363eb41`.

These fixture corrections are not runtime red-green evidence.

After the refactor, all 20 cases pass on each renderer:
`controls`, `routing`, `move`, `dialogs`, `dialog-close`, `dialog-late`, `hidden-render`,
`hidden-close-cancel`, `loaded-switch`, `loaded-quit`, `dormant-last`, `sidebar-process`,
`fault-resize`, `fault-present`, `fault-busy`, `fault-stale`, `loaded-resolve`, `loaded-focus`,
`dormant-unload-crash`, and `dormant-unload-restart`.
Here, `move` checks native Window movement, not Phase 5 Project transfer.

- D3D11: `%TEMP%/anvil-surface-latency-wg3ak55b`.
- Software: `%TEMP%/anvil-surface-latency-v125c82e`.
- Native targets: `hosted-routing`, `sidebar-page-drop`, and `latency-watermark` pass.
- Native log: `build-windows-x86_64/meson-logs/phase5-m1-native.txt`.
- LuaJIT syntax validation for `tests/fixtures/hosted_project_probe.lua` passes.
- The build and `git diff --check` pass.

## Environment-valid latency

No builds, correctness checks, fault checks, or other measurements overlap these runs.
The runner uses private desktops, isolated data, and owned process handles. It captures no pixels.
Each run requests, completes, and retains exactly 120 input samples. Every native and public exit is 0.
All 36 boundary snapshots report session 1 unlocked with the display on.
The first matrix has 12 cases and 1,440 inputs. The matched control adds six cases and 720 inputs.
The clock measures generated input to Present, not physical input or scanout.

First matrix: `%TEMP%/anvil-phase5-m1-latency-a6I31U/results.json`.
Native artifacts: `%TEMP%/anvil-surface-latency-xm8zhd02`.
Each row has three runs and 360 inputs. Values are milliseconds.
The baseline column uses `81bccdaf` from the accepted [2026-10-10 comparison](PHASE4_LATENCY_BASELINE.md).

| Row | Baseline p50 | Milestone 1 p50 | Difference | Milestone 1 p90 | p99 | Maximum |
|---|---:|---:|---:|---:|---:|---:|
| Direct D3D11 | 7.476 | 7.186 | -0.290 | 16.312 | 20.343 | 43.446 |
| Hosted D3D11 | 7.412 | 7.791 | +0.379 | 16.773 | 29.033 | 53.521 |
| Direct software | 15.350 | 17.864 | +2.514 | 27.479 | 34.765 | 48.966 |
| Hosted software | 11.596 | 12.119 | +0.523 | 21.338 | 26.837 | 51.784 |

Both hosted median differences remain below the approximately 2 ms noise threshold.
The direct-software shift required a current matched control. Do not infer its cause from the historical comparison.

Control files: `%TEMP%/anvil-phase5-m1-software-control-d6Ne6S/{reference,candidate}-{0,1,2}.json`.
The control uses the saved unchanged executable above and the refactored executable, with the same source data.
Pair order is reference/candidate, candidate/reference, reference/candidate. Each executable has 360 inputs.
All six public commands exit 0. No runs or samples are removed.

| Direct software | p50 | p90 | p99 | Maximum | Mean |
|---|---:|---:|---:|---:|---:|
| Saved before refactor | 17.701 | 26.586 | 31.076 | 54.149 | 18.540 |
| Refactored | 18.991 | 29.013 | 74.781 | 163.886 | 21.567 |

Per-pair medians are 17.708/19.512, 17.329/19.866, and 18.218/18.171 ms.
The aggregate difference is +1.290 ms, below the stated noise threshold. The second pair differs by +2.537 ms.
The current reference also exceeds the historical direct-software median.
This control does not establish a cause for the variation or the candidate tail. Do not claim a performance gain.
The 163.886 ms candidate maximum remains in the original samples and this report.
Historical multi-second tails remain unresolved. This milestone does not reopen or redefine the satisfied Phase 5 entry gate.

## Deployment and review

The save-files and process-stop warning preceded `update-anvil-dev-build.bat`. The updater exited 0.
It restored the source-data junctions and started the normal direct-mode portable app.
The build hash stayed unchanged through deployment.

SHA-256:

- Build: `065744ab6a1cf719809af83f57034d2b2629c8379fceb9fad7aaf91532abf6fb`.
- Portable: `9cc6418ee17103e1794036e557fde0a4087758e0a2ef86fc7f5c513a47de5739`.

An independently stripped build matches the portable executable after PE timestamp/checksum normalization.
Fresh session and startup logs contain no warning, error, or failure diagnostics at verification:

- `anvil-20261010-084632-p30976.log`.
- `startup/anvil-startup-20261010-084631-p30976-m903080.log`.

These logs remain under the portable user directory, outside the repository.
Stop after that commit for review. Do not begin milestone 2a automatically.
Physical input, real IME, mixed DPI, allocator failure, and instrumented lifetime acceptance remain open.
