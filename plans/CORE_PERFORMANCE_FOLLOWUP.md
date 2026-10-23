# Core performance follow-up

Date: 2026-10-23

## Result

Three small Lua changes remove measured preparation work. They do not solve all large-file latency.

1. Buffer loading compares normalized lines directly. It no longer joins both Buffers to detect a content change.
2. Text input and IME reuse one byte-offset index during planning, selection mapping, and application.
3. Windows path normalization skips component reconstruction for plain absolute drive paths.

The offset index belongs to one operation. It is not a persistent Buffer cache.
Application checks its line-table identity and text revision before reuse.
The existing line arrays, undo rules, encoding behavior, and save protections stay unchanged.

## Method

The private-desktop runner measured these workloads:

- First open of 100,000 and 500,000 lines.
- Insert and undo in long lines.
- Insert and undo at 1,024 carets.
- Switching between loaded files.
- First and later File Search queries across 10,000 files.

The initial run used three throughput repetitions, one metrics repetition, and a separate diagnostic replay.
Comparisons replayed saved baseline applications beside the candidate. Run order alternated.
No run used the daily portable application or the interactive desktop.

The paired comparison increased some repetitions to five because of timing noise.
Other development continued in this repository. The saved application snapshots preserve each measured version.
Do not infer small improvements from noisy totals.

## File opening

Paired results from `20261023_150113_78684`:

| Workload | Reference | Candidate | Interpretation |
|---|---:|---:|---|
| Open 100,000 lines, completed redraw | 132.085 ms | 88.902 ms | 33% lower median |
| Open 100,000 lines, dispatch | 80.333 ms | 61.698 ms | 23% lower median |
| Open 500,000 lines, completed redraw | 628.727 ms | 538.334 ms | 14% lower median |
| Open 500,000 lines, dispatch | 511.105 ms | 504.710 ms | No material improvement established |
| First frame after the huge open, instrumented | 96.714 ms | 19.843 ms | One metrics pair, not a general frame-time claim |

The earlier separate candidate run completed the huge open in 426.778 ms.
The paired run is the more conservative comparison. Do not report the earlier result as a guaranteed improvement.

The diagnostic profile identified file reading, native line splitting, and full-text comparison as the main preparation costs.
The patch removes the comparison allocation and adds a `buffer_split_lines` stage timer.
Lower allocation pressure also reduces later work, but no native GC profile established an exact allocation-to-frame attribution.

The original and candidate PNG captures for both file-open workloads have identical SHA-256 hashes.
This checks their final rendered output. It does not measure physical display latency.

## Buffer editing

`tools/audit/essential/buffer_perf.lua` measures plain Buffers without language services or drawing.
Each position gets ten warmup edits and 100 measured single-character edits.
These are separate before/after processes, not paired replay measurements.

| Buffer lines | Position | Reference median | Candidate median |
|---:|---|---:|---:|
| 10,000 | start | 0.125 ms | 0.101 ms |
| 10,000 | middle | 0.103 ms | 0.058 ms |
| 10,000 | end | 0.096 ms | 0.047 ms |
| 100,000 | start | 0.682 ms | 0.490 ms |
| 100,000 | middle | 0.624 ms | 0.472 ms |
| 100,000 | end | 0.729 ms | 0.609 ms |
| 500,000 | start | 2.601 ms | 2.268 ms |
| 500,000 | middle | 2.693 ms | 2.330 ms |
| 500,000 | end | 3.740 ms | 3.061 ms |

At 500,000 lines, the median improved by 13–18% in this probe.
Occasional pauses above 10 ms remain. Heap deltas fluctuate with collection and do not measure total allocations.

The paired GUI checks showed no material complete-action improvement for long lines, multicaret input, or file switching.
The multicaret frame comparison remained inconclusive under system load.
This patch does not claim to improve all editing workloads.

## Path normalization and File Search

The search profile showed repeated path normalization and membership preparation on the UI thread.
Already-normalized drive paths still passed through component tables and string reconstruction.
The fast path preserves drive-letter normalization and retains the existing general path for other inputs.
UNC roots, dot components, repeated separators, and trailing separators still use that general path.

`tools/audit/essential/path_perf.lua` compares both functions in one process.
It alternates their order, excludes five warmup rounds, and measures 20 rounds of 10,000 paths.

| Operation | Reference median | Candidate median |
|---|---:|---:|
| Normalize 10,000 plain Windows paths | 22.141 ms | 8.109 ms |
| Same operation, p95 | 23.779 ms | 8.543 ms |

The direct operation costs about 63% less in this probe.

The separate paired File Search run measured first-result completion at 881.965 ms versus 744.148 ms.
Candidate repetitions ranged from 582.026 to 951.408 ms, so treat the 16% median reduction as indicative.
Index preparation can overlap startup. This is not a physically cold disk benchmark.
Later-query latency was inconclusive: 13.113 ms versus 15.233 ms.
No warm-query improvement is claimed.

## Checks and limitations

The following focused test files passed:

- `runtime/buffer_snapshot.lua`
- `runtime/buffer_io_bulk.lua`
- `runtime/buffer_batch_edit.lua`
- `runtime/buffer_edit_characterization.lua`
- `runtime/buffer_transaction_order.lua`
- `runtime/buffer_text_change_listener.lua`
- `runtime/buffer_highlighter_batch.lua`
- `runtime/core_common.lua`
- `runtime/project_files.lua`

These files contain 92 passing tests. Lua syntax checks also passed.
The snapshot and path tests characterize unchanged behavior. They passed before and after optimization.
Performance measurements supplied the before/after evidence; no timing threshold was added to correctness tests.

The paired render gate did **not** pass its overall budget gate.
It still reported large-file, search-readiness, and frame-budget violations.
Several timing comparisons were inconclusive. There was no proven relative timing regression in those reports.

A separate `editor-type-baseline` scenario first encountered the runner's concurrent-run lock. The lock was not bypassed.
A later retry completed three scoring runs with 300 frames each.
Character input completed in 3.4–3.8 ms at p50 and 5.3–5.6 ms at p95.
Frame work reached 5.34 ms at p95, above the scenario's strict 4 ms budget.
The scenario therefore failed its budget gate. There is no before/after comparison for this scene.
Its report is `tools/perf-results/scenarios/20261023-151315/report.md`.

Only Lua production code changed. No native build or daily application restart was needed for the measurements.
Restart Anvil to load the changes in the daily application.

## Remaining priorities

1. Large-file loading still blocks dispatch for hundreds of milliseconds.
   Reading and line construction need bounded preparation and careful publication, not only a background read.
2. Large-Buffer edits still build one whole-Buffer offset index and copy the line array.
   Removing that remaining cost needs a separate design that preserves snapshots, observer behavior, and undo.
3. First File Search still waits for Project readiness. Separate startup overlap, scanning, membership preparation, and native index publication.
4. Rerun uncertain multicaret and warm-search comparisons under quieter system load before making small timing claims.
5. Reduce ordinary typing's frame work from 5.34 ms toward the 4 ms headroom budget.
   The attribution run identified Editor drawing and root-panel updates, not a new dominant Buffer cost.

Do not replace these constraints with unbounded threads, disable safety checks, or introduce a new storage model without further review.

## Local artifacts and reproduction

Artifacts are Git-ignored under `tools/perf-results/render-gate`:

- `20261023_145112_64724`: original six-workload baseline and profiles.
- `20261023_145727_56144`: file-open allocation change, profiles, and identical final captures.
- `20261023_150113_78684`: paired six-workload comparison after the Buffer changes.
- `20261023_150708_68064`: paired File Search comparison after the path change.

Each directory contains `report.json` and `report.html`.
Keep the `app` directory when reusing a report as a baseline.

```sh
python tools/run_render_perf_gate.py \
  --scenario file-open-large --scenario file-open-huge \
  --scenario long-line-edit --scenario multi-caret-edit \
  --scenario file-switch-large --scenario fuzzy-files-large \
  --runs 3 --metrics-runs 1 --max-runs 5 --actions 8 \
  --warmup-frames 20 --frames 24 \
  --baseline tools/perf-results/render-gate/20261023_145112_64724/report.json \
  --no-visual --no-build
```

Run each diagnostic Lua file separately through `anvil:lua-runtime --test-args`.
Use its absolute path because it lives outside normal test discovery.
For the path comparison, set `ANVIL_PATH_PERF_REFERENCE` to the saved baseline's `app/share/anvil/core/common.lua`.
