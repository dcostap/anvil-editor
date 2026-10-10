# Phase 5 milestone 2b: shared Sidebar surfaces

## Scope and review boundary

The user approved milestone 2b after the separate maximized-Window fix, `f565e01c`.
One Sidebar process now serves every Anvil Window. Closing the first Window retains that process.
Each Window keeps its Sidebar configuration, presentation resources, input, selection, and scale.
Hosted mode stays opt-in. Direct mode and non-Windows command behavior remain unchanged.
Stop after this milestone's commit for review. Do not start milestone 3.
Move, shell adoption, full restore, and final Sidebar design remain outside this change.

## Ownership and transport

Protocol 13 adds Window-tagged Sidebar messages and explicit surface removal.
All surfaces use the existing authenticated Sidebar connection. This is not a general RPC interface.
The shell retains one transport/process record and separate per-Window surface records.
The per-Window records own no process handles or transport threads.
Their process ID identifies shared frame resources. Their connection identifies the current Sidebar frontend.
Each surface retains its own configuration epoch, frame generation, and compositor resources.
Input uses the receiving Window's configuration. Snapshot replies use the requesting surface's Window ID.
Removed or closing Windows cannot receive Sidebar actions or late frames.
The frontend maps SDL event identities to its own per-Window View and snapshot request.
It discards queued events after that View closes instead of applying them to another View.

The native shell bounds live Windows and Sidebar surfaces at 64.
The frontend also bounds retained records at 128 during surface removal.
Removal takes priority during enumeration. A full live list cannot hide cleanup.
A surface removed before Lua creates its Window releases its native record immediately.
Each surface gets a distinct software mapping name. D3D11 keeps its existing unique allocation names.
Window removal releases that Window's presentation and frontend renderer, not the shared process.
Sidebar startup and recovery timers use the shell service HWND.
Their service Window changes when its previous Window starts Close. User actions still require explicit Window IDs.
Restart replaces the shared frontend and recreates every live Window's surface.
Projects and Terminal Sessions keep their independent lifetimes. GPU recovery remains explicit.

Snapshots include owning Window IDs and Selected Project IDs per Window.
The minimal list shows each loaded Project's owning Window.
Each View derives its highlight from its receiving Window. It does not change the shared snapshot.
A visible Window can request a status scan even when another Window is minimized or closed.
This presentation is not the final Phase 7 design.

## Red-green checks

All native Window checks use the existing private-desktop runner and isolated data.
They use owned process handles, not the user's Windows. They capture no pixels.

- `anvil-surface-latency-_y7rj9p_`: the new `windows-sidebars` case fails against `f565e01c`.
  It reports `second Window has no Sidebar surface from the shared process`.
- `phase5-2b-selection-red.txt`: the public View draw check expects highlight `A`, but gets `nil`.
- `anvil-surface-latency-3zvxtmc8`: an intermediate implementation rejects its frame resource as unowned.
  Surface records now carry the authenticated Sidebar PID without borrowing its process handle.
- `anvil-surface-latency-4_ipm95i`: the first lifecycle green preserves the shared process after first-Window Close.
- `phase5-2b-selection-green.txt`: per-Window highlighting and owning-Window labels pass.
- `anvil-surface-latency-dy5xbiho` and `anvil-surface-latency-4eua3qce`: both-renderer lifecycle and recovery checks pass.

The lifecycle check verifies distinct owning Windows and independent snapshot selections.
It closes the first Window, retains the shared Sidebar process, and checks the surviving selection.
The recovery check suspends the Sidebar and exercises native Minimize, Restore, and New Window.
It then crashes that frontend and requires every Window's surface to return from the replacement.
Both Project process handles stay live. The check then closes the first Window independently.
The focused View check draws two Views from one snapshot and requires different highlights.

### Retained recovery exceptions

`anvil-surface-latency-78ao9u5m` retains `Sidebar stopped before its restart limit`.
The candidate repeat, `anvil-surface-latency-h1fnf5co`, reports a hung frontend surviving the fixture's Restart deadline.
The saved `f565e01c` reference also fails that deadline in `anvil-surface-latency-dvd39mol`.
These failures remain unexplained. Do not classify them as fixed by the new diagnostic labels.
No timeout was increased. No failed artifact was removed.
The unchanged recovery check later passes on D3D11 in `anvil-surface-latency-xev_20x1`.
It passes on software in `anvil-surface-latency-4z5nat2m`.

### Probe reference data

The saved reference needs its matching Lua data. Its executable lacks the new Sidebar surface APIs.
The public runner accepts `--reference-data` beside `--reference-exe` for this boundary.
Its regression test first fails because the CLI rejects that option, then passes with matching data.
The runner's five focused checks pass. Reference and candidate data remain separate and recorded.

## Final checks, latency, and deployment

The two new cases pass on both renderers after the final service-ownership changes:

- D3D11: `%TEMP%/anvil-surface-latency-yx6wnwbv`.
- Software: `%TEMP%/anvil-surface-latency-1tmdy8q7`.

The bounded-cleanup checks also pass in `anvil-surface-latency-3hwjys53` and `anvil-surface-latency-05pyprkj`.
Five native targets pass in `phase5-2b-final-native.txt`.
The four focused View checks pass in `phase5-2b-final-selection.txt`.
Direct Project launch checks pass in `phase5-2b-direct.txt`.
LuaJIT syntax, Python compilation, five runner checks, and `git diff --check` pass.

The focused existing hosted cases pass on both renderers:
`windows-open`, `windows-new`, `windows-picker-command`, `routing`, `controls`, `sidebar-idle`, `sidebar-recovery`, `fault-busy`, and `fault-stale`.
The Open Project case retains both-Window wheel routing, Maximize preservation, and Minimize restoration.
D3D11 evidence combines `anvil-surface-latency-78ao9u5m` with the retained recovery green, `anvil-surface-latency-xev_20x1`.
Software evidence is `anvil-surface-latency-4z5nat2m`.
The failed recovery runs above remain part of the evidence. These later passes do not explain them.

### Matched latency

Evidence: `%TEMP%/anvil-phase5-2b-matched-3msjw89f/results.json` and its six linked public-run files.
The reference is the retained `f565e01c` build and its matching runtime data from `anvil-surface-latency-_y7rj9p_`.
Reference SHA-256: `3ee83aaf4ee02249417445b96ff65a33c20ceeaf788658045f6e306853d8d7eb`.
Candidate SHA-256: `d06b961b7f9088d9bd8b56a29e04ee4d0d06563417821d72ad0758325328a4ac`.
The result records hashes for the three changed runtime Lua files in both data trees.

Order is reference/candidate, candidate/reference, reference/candidate.
Each public command uses normal scheduling, five seconds of warmup, and 120 inputs per row.
No builds, correctness checks, or other measurements overlap these runs.
All six public commands and all 24 native cases exit 0. None times out.
Every case completes and retains 120 of 120 requested inputs: 2,880 total.
Each row retains 360 samples per executable. All 48 boundary snapshots report session 1 unlocked, with display power on.
No run or sample is removed.

Values are milliseconds. Baseline is the accepted 2026-10-10 `81bccdaf` comparison.

| Row | Baseline p50 | Matched reference p50 | Candidate p50 | Difference | Candidate p90 | p99 | Maximum |
|---|---:|---:|---:|---:|---:|---:|---:|
| Direct D3D11 | 7.476 | 12.286 | 10.040 | -2.246 | 24.545 | 63.498 | 110.796 |
| Hosted D3D11 | 7.412 | 9.475 | 8.613 | -0.862 | 17.576 | 21.428 | 24.804 |
| Direct software | 15.350 | 19.160 | 19.145 | -0.015 | 28.661 | 34.479 | 50.739 |
| Hosted software | 11.596 | 16.003 | 16.721 | +0.718 | 25.475 | 35.789 | 54.715 |

Reference p90/p99/max are 49.700/140.312/198.712, 18.759/22.702/24.175,
30.443/41.636/69.225, and 29.662/51.018/59.508 ms, in the same row order.

Direct rows are machine-noise controls, not acceptance targets.
The aggregate hosted-software shift exceeds its matched direct shift by 0.733 ms.
That excess is below the approximately 2 ms threshold. No performance gain or established median regression is claimed.
The initial reference direct-D3D11 median is 37.731 ms. Later reference medians return to 7.960 and 9.270 ms.
Its 198.712 ms maximum remains unexplained. Do not infer a cause from this variation.

Rounded per-pair software medians retain the changes that the aggregate hides:

| Pair | Direct reference/candidate | Difference | Hosted reference/candidate | Difference |
|---|---:|---:|---:|---:|
| 0 | 21.91 / 20.29 | -1.62 | 23.16 / 17.08 | -6.08 |
| 1 | 17.60 / 18.67 | +1.07 | 14.54 / 15.13 | +0.59 |
| 2 | 18.70 / 19.18 | +0.48 | 12.12 / 18.46 | +6.34 |

Pair 2 has a larger hosted shift than its direct control. Pair 0 reverses it.
These opposing results do not establish a stable hosted-software regression.
The candidate maximum of 110.796 ms and all per-run tails remain in the linked files.
This comparison does not explain earlier timing tails or change renderer defaults.

### Deployment

The save-files and process-stop warning preceded the portable updater.
The updater exits 0, restores all five source-data junctions, and restarts the normal direct-mode portable app.
The build hash stays unchanged through deployment.

SHA-256:

- Build: `d06b961b7f9088d9bd8b56a29e04ee4d0d06563417821d72ad0758325328a4ac`.
- Portable: `bdf28b22ae8758f72b0c01f8b7aad0c5d269b4b3a69b9ea9f8a3038b69f708e9`.

The portable executable matches an independently stripped build after PE timestamp/checksum normalization.
Fresh session and startup logs show no warning/error/failure diagnostics at verification:

- `anvil-20261010-183436-p3504.log`.
- `startup/anvil-startup-20261010-183435-p3504-m529570.log`.

Normal `error=nil`, `last_error=0`, and Git's `--error-unmatch` arguments are not failures.
These logs remain under portable user data, outside the repository.
Updater output: `%TEMP%/pi-bash-bg-57429b488e258bed.log`.
Stop for review after this milestone's commit.
Physical input, real IME, mixed DPI, allocator failure, and instrumented lifetime acceptance remain open.
Generated input-to-Present measures neither physical input nor scanout.
Historical timing tails and the retained recovery exceptions remain unexplained.
