# Autonomous render performance gate

`run_render_perf_gate.py` measures the D3D11 command renderer and its software fallback. It checks deterministic captures without touching the interactive desktop.

## Editor workload benchmarks and diagnosis

The same runner also measures interactive workloads. Do not create a separate
hidden-window runner for editor benchmarks.

Run the stress workloads and their diagnostic replays:

```sh
python tools/run_render_perf_gate.py --suite stress --diagnose --report-only
```

Use `--suite interactive` for search, file switching, file opens, and edits.
Use `--suite diff` for the Diff View size variants.
Use `--scenario NAME` for one workload.

For a short verification run:

```sh
python tools/run_render_perf_gate.py --suite stress --diagnose --report-only \
  --runs 1 --metrics-runs 1 --max-runs 1 --actions 4 \
  --frames 12 --warmup-frames 2
```

Open the printed `report.html` path. The runner does not open a browser.
The report contains:

- ranked absolute frame and action budget flags;
- action dispatch, readiness, and completed-redraw latency distributions;
- raw action results and per-frame timings;
- frame work counts, lifecycle timings, and memory growth;
- exclusive and inclusive draw-scope costs, separated by phase and action;
- offline SVG flame graphs and a Speedscope JSON export;
- a Chrome Trace timeline with actions, frame counters, lifecycle marks, and file-open stages;
- backbuffer or software-surface checkpoints;
- links to full profiler counters, slow frames, and sampled stacks.

The default budgets are 16.67 ms per frame and 100 ms per action.
For a 165 Hz target, use `--frame-budget-ms 6.06`.
Set another action limit with `--action-budget-ms`.
Flags report measured costs, not proven causes. Compare size variants before
you conclude that cost grows with file size or change count.
Run summaries use medians for typical costs. Maxima and memory peaks retain
the worst recorded value across repetitions.

`--report-only` does not require a baseline or golden image. It still fails
on crashes, missing results, timeouts, unstable state, or unstable captures.
A passing run can contain budget flags. Add `--fail-on-budget` to make those
flags fail the command.

You can pass a previous `report.json` as `--baseline PATH` for a relative comparison.
Use the same workload settings and frame counts. Use `--no-visual` when you
only want numeric comparisons without stored goldens. Do not use `--report-only`
for that comparison. Action p50 and p95 regress when both 10% and 2 ms limits are exceeded.

### Stress workloads

| Scenario | Workload |
|---|---|
| `diff-scroll-medium` | 4,000 source lines, dense changes, traversal across the file |
| `diff-scroll-large` | 40,000 source lines, the same change density and traversal |
| `diff-steady-large` | Repeated redraws of the large Diff View |
| `diff-navigate-large` | Commands that move to successive changes |
| `fuzzy-files-medium` | Real Project File Search over 1,000 generated files |
| `fuzzy-files-large` | The same search over 10,000 files |
| `fuzzy-text-large` | Exact text queries over 10,000 files |
| `file-switch-large` | Cached switching among 16 files with 4,000 lines each |
| `file-open-large` | First open of a generated 100,000-line file |
| `file-open-huge` | First open of a generated 500,000-line file |
| `long-line-edit` | Insert and undo in 32 lines with 64 KiB per line |
| `multi-caret-edit` | Insert and undo at 1,024 carets |

The stress suite also includes the File Tree edit and long Markdown link workloads.
Stress windows use fixed dimensions. The new workloads use low code zoom
through the normal scale API. Diff fixtures contain replacements, removals,
and unequal insertions. They use the real Diff View, not a mock Git response.

Fixture generation runs outside measurement. Each fixture has a content hash
and a manifest. Each new workload uses its own working directory. Git discovery
cannot reach the source repository above the private run directory.

### Action completion contract

The runner dispatches one action, then continues the real event loop.
It checks the requested result after updates and before drawing.
It completes the action only after that redraw finishes.
An asynchronous result that arrives later needs another redraw.

File search completes when the requested result appears in the visible result list.
This measures result availability, not completion of all background index work.
The first query has a separate first-query label. Later queries reuse the picker.
Startup index preparation can finish before the first query. This is not an index-cold measurement.
Queries stay within the generated Project. They do not use the user's Everything service.

First-open workloads start with a neutral View. They do not open the large file
during warmup. Each process measures exactly one first open. File switching
preloads its files because it measures cached switching, not first opens.
Here, cached means that the Buffer is already loaded. View and renderer caches
can still need work after a switch.
First-open workloads require `--user-state-mode clean`.
The runner checks loaded line counts, file identity, edit results, and navigation results.
It also rejects a scroll scene that sends no scroll actions.
Older baselines can fail state checks after these corrections. Inspect the
results before you replace a baseline.

`--actions N` controls new workloads. First-open workloads always use one action.
`--frames N` controls the existing frame-driven scenes, not asynchronous action counts.
New action workloads warm up by redrawing without sending actions.
The stress suites default to 20 warmup frames and 12 actions.

Action timeouts are independent of heartbeat activity. A picker that keeps
redrawing without producing its result still fails. Use
`--action-timeout-seconds N` to change the 30-second action deadline.

Compare action latency for interactive workloads. FPS alone can be misleading:
a pending search can produce many frames before it produces a result.
Completed-redraw latency does not include physical display scanout or OS input delivery.

### Diagnostic pass limits

`--diagnose` repeats the same workload in another private process.
Diagnostic costs never replace throughput or action scores.
The runner compares its final state and action results with the scoring runs.

The diagnostic pass records draw scopes on every redraw.
It also uses LuaJIT's timer sampler with a requested 1 ms interval.
Flame graphs include Lua call stacks, compiled Lua, C boundaries, GC, and JIT compilation.
They separate setup, readiness, warmup, and measured actions.
Heap deltas show net growth, not total allocations. Profiler allocations affect them.

Native call stacks are not captured. A C address identifies a Lua call boundary,
not the full native call tree. Native renderer counters and file-open stage
timers provide further evidence. Worker threads and child processes need a
separate native profile when those boundaries own the cost.

The report states when LuaJIT sampling is unavailable. Short phases can have
few samples or no samples. The sampler retains at most 50,000 distinct stacks;
an overflow row retains the remaining sample count.
Diagnostic files can contain Buffer text and paths. Keep run folders private.

### Adding a workload

1. Add fixed settings and fixture generation in `tools/perf_workloads.py`.
2. Add real actions and result checks in `data/core/perf_workloads.lua`.
3. Keep fixture generation out of measured actions.
4. Define what makes the result ready to draw.
5. Verify the workload through the private runner and inspect its checkpoint.

Use commands, input handlers, and View or Buffer methods. Do not inject OS input.
Do not use arbitrary delays as evidence that an asynchronous action completed.

## Isolation guarantees

Every benchmark process receives:

- a private Win32 desktop that is never switched to
- a private app tree copied from the Meson build and current source data
- a private `USERDIR`, work directory, IPC directory, and generated fixture
- internal deterministic actions rather than mouse or keyboard injection
- a Windows Job Object that owns and reaps the complete benchmark process tree

The runner never finds, focuses, moves, closes, or reuses an existing Anvil process. D3D11 captures come from the backbuffer. Software captures come from the renderer surface. The runner does not capture the screen. It does not use the normal portable app or its user state.

The benchmark writes an atomic heartbeat and lifecycle timeline. The hidden
launcher enforces three independent watchdogs:

- startup deadline for the first in-app heartbeat;
- heartbeat-stall deadline after startup;
- absolute per-process wall-clock deadline.

A watchdog failure is a categorical reliability regression with an infinite
performance penalty; it is never hidden inside a median. Before terminating the
Job Object, the launcher writes a local `timeout.dmp`, preserves the last phase,
and retains external memory samples. Dumps and all run artifacts are ignored by
Git and can contain Document contents, so do not publish specimen run folders.

## Measurement modes

The runner supports these modes:

- **throughput**: records frame count, elapsed time, and action latency; this is the authoritative scoring run
- **metrics**: retains per-frame production timing and renderer counters in memory, then writes one CSV after measurement
- **paced metrics**: repeats user-facing scenarios with D3D11 vsync enabled and records completion-interval percentiles
- **diagnostic**: repeats the workload with detailed scopes and LuaJIT samples; these costs do not affect scores

Metrics include p50/p95/p99/max, frame-budget miss counts, the longest run of
missed 16.67 ms budgets, first/last-quarter averages, rolling p95 maxima, and
least-squares progression slopes. A 250 ms external sampler records working-set
and private-byte growth without adding instrumentation to Anvil's hot paths.

Lifecycle milestones include plugin load, first redraw, fixture open,
semantic/wrapped readiness, first post-readiness frame, warmup, measurement, capture,
and completion. `startup_total_ms` covers process launch through the first
ready frame; readiness is not replaced by an arbitrary delay. Exact pixel
stability remains a separate three-capture check after measurement.

The detailed F11 profiler remains a diagnostic tool and is intentionally not used for performance scores.

## Commands

From `cmd.exe`:

```bat
tools\anvil_render_perf_gate.bat --suite quick
tools\anvil_render_perf_gate.bat --suite full
tools\anvil_render_perf_gate.bat --suite visual
tools\anvil_render_perf_gate.bat --scenario tab-heavy-titlebar
```

From MSYS/bash:

```sh
python tools/run_render_perf_gate.py --suite quick
python tools/run_render_perf_gate.py --suite full
python tools/run_render_perf_gate.py --scenario font-raster-correctness --renderer software
```

Run a private pathological specimen without opening or modifying the original:

```sh
python tools/run_render_perf_gate.py --suite specimen \
  --specimen "/absolute/path/to/private specimen.md"
```

The runner copies the specimen to the isolated work tree and reports only its
SHA-256, byte count, line count, longest line, and extension. The original path
is not stored in the report. Specimen baselines and goldens default to the
Git-ignored location
`tools/perf-results/render-gate/specimen-baselines/<sha256>/<state-mode>/`, not
the tracked renderer baseline directories.

Establish the local specimen baseline explicitly:

```sh
python tools/run_render_perf_gate.py --suite specimen \
  --specimen "/absolute/path/to/private specimen.md" \
  --update-baseline --update-goldens
```

Establish or intentionally refresh the local-machine performance baseline and visual goldens:

```bat
tools\anvil_render_perf_gate.bat --suite full --update-baseline --update-goldens
```

Baseline and golden updates are explicit. An ordinary run never silently accepts a changed image or slower score.

Useful development options:

```text
--runs N             throughput repetitions per scenario
--metrics-runs N     metrics repetitions per scenario
--paced-runs N       present-paced repetitions per applicable scenario
--frames N           measured redraws per repetition
--warmup-frames N    warmup redraws before measurement
--timeout-seconds N  absolute deadline for each benchmark process
--startup-timeout-seconds N
                     deadline for the first in-app heartbeat (default 30)
--heartbeat-timeout-seconds N
                     deadline for a stalled phase/event loop (default 15)
--user-state-mode clean|reuse
                     fresh USERDIR per process or reuse across repetitions
--scenario NAME      run or update one scenario
--renderer NAME      use d3d11 or software output (default d3d11)
--specimen PATH      copy a private local specimen into the isolated run
--baseline PATH      override the performance baseline
--golden-root PATH   override the exact-pixel golden directory
--no-build            use current Meson build outputs
--no-visual           skip frame capture comparisons
```

A partial `--update-baseline` merges into an existing complete, compatible
baseline. It refuses to run when the machine, fixture, frame counts, or
untouched scenario settings differ; use a full-suite baseline update in that
case.

## Scenarios

- `wrapped-document-steady` — tall wrapped Document View at a fixed location
- `wrapped-document-scroll` — deterministic one-line scrolling and cache churn
- `tab-heavy-titlebar` — 40 Pane Tabs with a stable active Editor
- `caret-repeat` — one `doc:move-to-next-line` command per redraw in an unwrapped Document View
- `filetree-edit-repeat` — alternate text input and Backspace in a File Tree with 425 visible rows and 1,800 collapsed children
- `markdown-long-link-caret-repeat` — one wrapped-row caret move per redraw inside a long revealed Markdown link
- `renderer-primitives` — deterministic clipping, alpha, text, and shape scene
- `font-raster-correctness` — connected glyph continuity across sizes, phases, hinting, antialiasing, and backgrounds

Use `--scenario image-viewer` for image controls, transparency, a fit preview, and a clipped pan at actual size.
This focused scene is not in the default suites. It does not yet have a full-suite performance baseline.

Use `--scenario image-filtering --renderer d3d11` to check image sampling through captured pixels.
The check covers reduced fine detail, enlarged color transitions, transparent edges, and unchanged pixels at actual size.
It uses independent expected colors, not a visual golden, to test filtering behavior.

The prior Edge comparison showed continuity at 15, 16, 18, and 24 ppem. It did
not establish the first stable DirectWrite size. That threshold remains
unverified. The report gives Anvil's first stable sampled fixture size only.

Private specimen scenarios are selected by `--suite specimen` and require
`--specimen`:

- `specimen-startup` — startup/readiness and stable presentation
- `specimen-scroll` — deterministic source-line scrolling and cache churn
- `specimen-caret-repeat` — repeated wrapped-row caret movement
- `specimen-soak` — deterministic forward/backward traversal for progression,
  memory growth, stutter, and long-running cache behavior

`--user-state-mode clean` is the application-cold definition: a fresh process
and fresh `USERDIR` for every repetition. `reuse` first runs an excluded
state-primer process, then starts a fresh measured process while reusing that
isolated `USERDIR` across repetitions. Hot ongoing Document work
is measured after semantic/layout readiness inside the scroll, caret, and soak
scenarios. The gate does not claim to flush or measure physically cold OS file
caches; doing that would disturb the desktop machine and make the isolation
claim misleading.

Fixtures are generated deterministically inside the isolated run directory. Their hash is recorded in every report.

The File Tree scenario measures edits, not unchanged cache hits. It checks focus, the caret, and retained collapsed children.
Its files have fixed modification times so metadata text does not change between repetitions.
It never applies the draft filesystem operations. Use it when changing File Tree path resolution, edit feedback, or rendering.
Live edit feedback uses the draft and cached metadata. Explicit apply commands validate disk state and collapsed subtrees.

## Results

Timestamped artifacts are written beneath:

```text
tools/perf-results/render-gate/<run_id>/
```

Important files:

- `report.md` — concise human-readable result
- `report.json` — complete machine-readable result and raw artifact paths
- `<scenario>/throughput-*` — authoritative FPS repetitions
- `<scenario>/metrics-*/metrics.csv` — per-frame metrics
- `<scenario>/*/lifecycle.csv` — in-app readiness milestones
- `<scenario>/*/heartbeat.txt` — last atomic progress marker
- `<scenario>/*/resources.csv` — external working-set/private-byte progression
- `<scenario>/*/timeout.dmp` — local minidump when a watchdog terminates a run
- `<scenario>/metrics-*/screenshot.png` — D3D11 backbuffer or software-surface checkpoint
- `<scenario>/metrics-*/screenshot-stability-*.png` — consecutive static-frame checks
- `<scenario>/metrics-*/visual_diff.json` — exact pixel comparison

The tracked performance baseline is:

```text
tools/baselines/render_perf_windows.json
```

Only D3D11 runs compare results with this performance baseline. Software runs
still report timing, image stability, and seam results. Their performance
baseline status is `not_applicable`. Software timing variation does not change
the command exit status unless `--fail-on-budget` is set.

Tracked renderer-specific visual goldens live under:

```text
tools/baselines/render/
```

## Gate policy

The gate checks both a relative regression budget and workload integrity:

- active FPS must not fall by more than 5% and 2 FPS
- steady frame-component medians generally must not regress by more than 5%
- p95 frame components generally must not regress by more than 8%
- structural renderer counts use tight relative limits with small absolute noise allowances
- measured frame count, scenario settings, and D3D11 command-renderer path must match exactly
- unstable repeated throughput is inconclusive; a stable active-FPS threshold breach fails even without another metric
- deterministic visual checkpoints require exact pixel equality
- three consecutive post-settle backbuffer captures must be byte-identical
- deterministic end state (Document lines/revision, wrapped rows, selection,
  and scroll position) must agree across repetitions and with baselines that
  contain state data
- any crash, startup stall, heartbeat stall, wall timeout, missing artifact, or
  unstable state is a hard failure

Raw p99 values are reported but not gated because they are more sensitive to unrelated system scheduling. Performance timing is intentionally kept out of Meson correctness tests; run this local hardware gate for performance changes.

## Per-change workflow

1. Run the relevant scenario before editing.
2. Make one focused optimization.
3. Run targeted Lua/native correctness tests.
4. Run the same scenario and inspect the generated report.
5. Run `--suite visual` for renderer changes.
6. Run `--suite full` before finalizing broad renderer work.
7. Use the F11 profile only when the low-overhead result needs attribution.

Do not update baselines merely to make a failure disappear. Inspect the numeric or image difference first, then update only for an intentional accepted change.

## Harness tests

The focused harness suite includes metric/statistics tests, private-copy
metadata checks, structured failure classification, lifecycle/resource
summaries, and a Windows integration test proving that a timed-out launcher
reaps a spawned descendant and writes a minidump:

```sh
python -m unittest tests.tools.test_render_perf_harness -v
python -m unittest tests.tools.test_perf_diagnostics -v
```

The action scheduler and isolated capture checks also run through Meson:

```sh
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/perf_actions.lua
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/perf_frame_costs.lua
```
