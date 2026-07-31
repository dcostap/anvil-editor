# Autonomous render performance gate

`run_render_perf_gate.py` measures the D3D11 command renderer and checks deterministic frame captures without touching the interactive desktop.

## Isolation guarantees

Every benchmark process receives:

- a private Win32 desktop that is never switched to
- a private app tree copied from the Meson build and current source data
- a private `USERDIR`, work directory, IPC directory, and generated fixture
- internal deterministic actions rather than mouse or keyboard injection
- a Windows Job Object that owns and reaps the complete benchmark process tree

The runner never finds, focuses, moves, closes, or reuses an existing Anvil process. Frame captures come directly from the D3D11 backbuffer, not from the screen. The normal portable app and its user state are not used.

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

Each scenario runs in two modes:

- **throughput**: records only frame count and elapsed time; this is the authoritative active-FPS score
- **metrics**: retains per-frame production timing and renderer counters in memory, then writes one CSV after measurement
- **paced metrics**: repeats user-facing scenarios with D3D11 vsync enabled and records completion-interval percentiles

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
- `markdown-long-link-caret-repeat` — one wrapped-row caret move per redraw inside a long revealed Markdown link
- `renderer-primitives` — deterministic clipping, alpha, text, and shape scene

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
- `<scenario>/metrics-*/screenshot.png` — D3D11 backbuffer checkpoint
- `<scenario>/metrics-*/screenshot-stability-*.png` — consecutive static-frame checks
- `<scenario>/metrics-*/visual_diff.json` — exact pixel comparison

The tracked performance baseline is:

```text
tools/baselines/render_perf_windows.json
```

Tracked D3D11 visual goldens live under:

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
```
