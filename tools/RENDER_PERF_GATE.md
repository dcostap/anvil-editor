# Autonomous render performance gate

`run_render_perf_gate.py` measures the D3D11 command renderer and checks deterministic frame captures without touching the interactive desktop.

## Isolation guarantees

Every benchmark process receives:

- a private Win32 desktop that is never switched to
- a private app tree copied from the Meson build and current source data
- a private `USERDIR`, work directory, IPC directory, and generated fixture
- internal deterministic actions rather than mouse or keyboard injection

The runner never finds, focuses, moves, closes, or reuses an existing Anvil process. Frame captures come directly from the D3D11 backbuffer, not from the screen. The normal portable app and its user state are not used.

## Measurement modes

Each scenario runs in two modes:

- **throughput**: records only frame count and elapsed time; this is the authoritative active-FPS score
- **metrics**: retains per-frame production timing and renderer counters in memory, then writes one CSV after measurement
- **paced metrics**: repeats user-facing scenarios with D3D11 vsync enabled and records completion-interval percentiles

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
--scenario NAME      run or update one scenario
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
- `renderer-primitives` — deterministic clipping, alpha, text, and shape scene

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
