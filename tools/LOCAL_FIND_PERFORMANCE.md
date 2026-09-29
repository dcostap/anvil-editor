# Local Find performance

## Design

Local Find scans ordinary lines in UI slices. Each slice has a 2 ms time budget and a work limit.
The scanner builds the match list and line index together. It does not rebuild the line index after the scan.
Current-match lookup and navigation use binary search.

A native string or regex search cannot yield inside one long line.
Lines over 64 KiB use `core.workers.local_find_line` through the system worker pool.
The worker sends bounded batches. Both paths use `core.local_find_scan` for identical matching rules.

Pending scans show `Searching…`, not a final count. Results remain private until the scan finishes.
Each resume checks the Buffer, text revision, query, regex mode, and case mode.
Worker callbacks check the same values before they accept a batch.
A newer query cancels the previous scan. Closing Find also cancels the scan.
A later caret move prevents a pending scan from moving the caret back.

The existing transaction `ranges` path still updates completed matches after edits.
Navigation requested during a scan waits for the complete match list.

The overview caches pixel-row coverage outside drawing.
Its key includes text and match-set revisions, scrollable height, track geometry, and visual-layout state.
Horizontal track expansion reuses row coverage.

Unwrapped text with uniform row height uses two binary searches per track row.
It needs no per-match visual-row lookup. Cache construction costs O(height × log(matches)).
Wrapped or composed rows use sliced range-edge accumulation. This also handles unequal, clamped marker heights.
Unwrapped composed rows group matches by line before they request visual-row positions.
Drawing costs O(height), regardless of the match count.

Opaque markers draw once per covered pixel row.
Translucent markers retain repeated blending, including integer rounding, with at most 255 draws per row.
Equal-color blends reach a fixed point within 255 steps on an 8-bit channel.
The selected marker draws last with `style.search_overview`. The thumb then draws above the markers.

## Reproduce the probe

Run from the repository root:

```sh
bash tools/run_local_find_probe.sh
```

The script copies `tools/local_find_probe.lua` into `tests/lua/ui/_probe/local_find.lua`.
It calls `tests/run-lua-tests.sh` with run name `probe`.
It removes both `tests/lua/ui/_probe` and `.run-meson-tests/probe` after the run.
It refuses to overwrite an existing probe directory.

The probe writes a C file with 450,000 lines and 15,750,000 bytes.
Each line contains `int input = input + 1; /* input */`.
It uses a real Buffer, Editor, Find input, and renderer window in the in-process test harness.
It does not use the portable app or capture the desktop.

The probe types `input` three times, one character per event.
It checks each query and its complete match count.
Each query has three measured redraws: 15 input events and 45 redraws in total.
Input time covers event dispatch. Draw time covers `view:draw()`.
Frame time also includes renderer begin/end. Rectangle counts cover the complete Editor draw.
Generation, file loading, and result settling stay outside input and draw measurements.

For the original-runtime measurement, the probe used a private copy of the unchanged runtime.
The measured source predates the optimization. The same build executable ran both versions.
Do not load both plugin versions into one process. Duplicate wrappers change draw counts.

To repeat the original measurement, use a separate checkout:

```sh
git worktree add --detach ../anvil-find-before 51d1891a
mkdir -p ../anvil-find-before/tests/lua/ui/_probe
cp tools/local_find_probe.lua ../anvil-find-before/tests/lua/ui/_probe/local_find.lua
bash tests/run-lua-tests.sh build-windows-x86_64 ../anvil-find-before \
  build-windows-x86_64/src/anvil.exe tests/lua/ui/_probe/local_find.lua probe
rm -rf ../anvil-find-before/tests/lua/ui/_probe ../anvil-find-before/.run-meson-tests/probe
git worktree remove ../anvil-find-before
```

Run the original and current probes separately. Concurrent measurements increase timing noise.

## Measurements

Machine: AMD Ryzen 7 5800X3D, Windows, repository LuaJIT build.
These are local measurements, not measurements from the user's low-power CPU.

| Metric | Before average | Before p95 | Before max | After average | After p95 | After max |
|---|---:|---:|---:|---:|---:|---:|
| Input dispatch, ms | 779.396 | 2077.952 | 2077.952 | 2.278 | 3.071 | 3.071 |
| Editor draw, ms | 2527.254 | 3963.895 | 4305.706 | 28.928 | 45.725 | 59.886 |
| Complete renderer frame, ms | 2686.259 | 4149.628 | 4425.615 | 32.788 | 47.472 | 97.748 |
| Rectangles per redraw | 1530520 | 1800610 | 1800610 | 1060 | 1150 | 1150 |
| Editor update, ms | 0.610 | 1.490 | 1.490 | 2.360 | 2.574 | 84.863 |

Input no longer runs a full-file scan. The measured input maximum stays below one 16.67 ms frame.
Complete Editor frames still exceed 16.67 ms. This change does not claim otherwise.
Update maxima can include allocation, garbage collection, and other Editor work, not just scanner slices.

## Regression evidence

Targeted test file: `tests/lua/ui/local_find_large.lua`.

```sh
PATH=/c/msys64/mingw64/bin:$PATH /c/msys64/mingw64/bin/meson.exe \
  test -C build-windows-x86_64 anvil:lua-ui \
  --test-args ui/local_find_large.lua
```

The pending-status test failed against the original plugin: a complete scan returned a final count immediately.
The pending-navigation and pending-close tests also failed at their pending-status checks.
The regex and edit-range tests passed against the original plugin and protect its behavior.

The moved-caret test failed against the first sliced implementation. It moved the caret to the completed match.
The fix gives a later caret move priority over the pending reveal.

The long-line test failed before worker dispatch. Its scan returned without a pending state.
The worker fix preserves both plain and regex ranges and rejects stale query and text results.

All seven targeted tests pass after these fixes.
They assert match ranges, status counts, current matches, selections, navigation, and edit/undo results.
They do not assert internal call counts. The full test suite was not run.

## Pixel evidence

Use the private renderer runner described in `tools/RENDER_PERF_GATE.md`.
The Find scenarios use real Editor commands and wait for scan and overview completion.

```sh
python tools/run_render_perf_gate.py \
  --scenario find-overview --scenario find-overview-wrap \
  --runs 1 --metrics-runs 1 --max-runs 1 --actions 4 \
  --frames 12 --warmup-frames 2 --report-only --no-build
```

The original capture is under:

```text
tools/perf-results/render-gate/20260929_201850_60800/
```

The checked candidate capture is under:

```text
tools/perf-results/render-gate/20260929_222012_41304/
```

Unwrapped and wrapped full-window images match exactly, including the selected marker.
The original image hashes are:

- Unwrapped: `b7f0809c82ad5c313544efc5874bd82fec884ff19159908d5ebe04bd1b76922f`
- Wrapped: `1cc7d04f413a3dbadfa41068cb50a374e66672d9e5a262486d1a7466706d5b0f`

Additional scenarios compare translucent markers against the former per-match drawing code:

```sh
python tools/run_render_perf_gate.py \
  --scenario find-overview-alpha --scenario find-overview-alpha-reference \
  --runs 1 --metrics-runs 1 --max-runs 1 --actions 4 \
  --frames 12 --warmup-frames 2 --report-only --no-build
```

These scenes use alpha 7, a fractional minimum marker height, and dense overlaps.
All pixels below the title bar match exactly. Only the scenario names in the title bar differ.
Each scene also passes the runner's three-capture stability check.
Their captures are under `tools/perf-results/render-gate/20260929_221340_62328/`.
The final wrapped scene also matches `find-overview-wrap-reference` below the title bar.

The first numeric baseline comparison did not pass the generic renderer gate.
It had no stored goldens and reduced rectangle counts, which the generic gate treats as a changed work count.
Later report-only runs passed capture and stability checks. Direct image comparisons supplied the exact-pixel evidence.
Do not describe these runs as a clean relative timing-gate pass.

All captures come from renderer surfaces on private desktops. No desktop screen capture was used.
The two user-owned test files were not changed, staged, or committed.
The portable update BAT was not run because it closes and launches the daily app.
The task forbids those actions. Runtime Lua changes use the existing source-data junctions.
