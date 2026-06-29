# Anvil perf capture benchmarks

These scripts launch Anvil, open a target file, run the same detailed performance recorder used by the F11 performance HUD, capture the editor window at the end, and optionally compare that screenshot against a visual baseline.

## Scripts

- `anvil_perf_capture_file.bat` / `anvil_perf_capture_file.ps1`
  - End-to-end benchmark harness.
  - Opens a file, records performance for a fixed duration, writes perf artifacts, captures `screenshot.png`, and compares it to a baseline.
- `compare_anvil_screenshot.bat` / `compare_anvil_screenshot.ps1`
  - Standalone image comparator for baseline-vs-current screenshots.

The BAT wrappers are convenient from `cmd.exe`/Explorer. From the agent MSYS shell, call the PowerShell scripts directly with `powershell.exe -NoProfile -ExecutionPolicy Bypass -File ...`.

## Quick start: default benchmark

The default target is:

```text
C:\Users\Darius\Downloads\odin_book_1_10_annotated_widgets.html
```

Create or refresh its baseline:

```bat
tools\anvil_perf_capture_file.bat -UpdateBaseline
```

Run a benchmark and compare the screenshot to the baseline:

```bat
tools\anvil_perf_capture_file.bat
```

If the screenshot differs from the baseline, the script exits with an error. That is treated as a visual regression unless you intentionally update the baseline.

## Benchmark any file

Use `-File` with any file Anvil can open:

```bat
tools\anvil_perf_capture_file.bat -File "C:\path\to\example.txt"
```

For a per-file baseline, pass a matching `-Baseline` path:

```bat
tools\anvil_perf_capture_file.bat ^
  -File "C:\path\to\example.txt" ^
  -Baseline "tools\baselines\perf_capture_example_txt.png" ^
  -UpdateBaseline
```

Then run the same command without `-UpdateBaseline` to check future screenshots:

```bat
tools\anvil_perf_capture_file.bat ^
  -File "C:\path\to\example.txt" ^
  -Baseline "tools\baselines\perf_capture_example_txt.png"
```

Keep the same window size, start line, renderer, and relevant plugin settings between baseline generation and comparisons. Pixel comparison is intentionally strict by default.

## Useful options

### Target and duration

```bat
-File "C:\path\to\file.ext"
-MeasureSeconds 2.0
-SettleSeconds 0.25
-StartLine 1
```

`-SettleSeconds` is the short delay after the file is ready and before recording starts. `-StartLine` positions the editor before the capture.

### Window geometry

```bat
-WindowX 80 -WindowY 60 -WindowWidth 1400 -WindowHeight 900
```

Baselines are geometry-sensitive. If you change these, update or use a separate baseline.

### Baseline and visual comparison

```bat
-Baseline "tools\baselines\perf_capture_my_case.png"
-UpdateBaseline
-RequireBaseline
-PixelTolerance 0
-MaxMismatchedPixels 0
-IgnoreEdgePixels 3
-AllowVisualMismatch
-NoScreenshot
```

- `-UpdateBaseline` copies the current run's screenshot to the baseline path.
- `-RequireBaseline` fails if the baseline is missing instead of creating one automatically.
- `-PixelTolerance` permits small per-channel color differences.
- `-MaxMismatchedPixels` permits a limited number of differing pixels.
- `-IgnoreEdgePixels` ignores unstable outer window edges.
- `-AllowVisualMismatch` reports differences but does not fail the command.
- `-NoScreenshot` runs only the performance capture.

Generated baseline PNGs matching `tools/baselines/perf_capture_*.png` are ignored by git.

### Renderer and process behavior

```bat
-SoftwareRenderer
-KeepOpen
-NoKillExisting
```

By default the harness stops existing Anvil processes for the same exe, launches the configured portable app, and closes it at the end. Use `-KeepOpen` while debugging. Use `-SoftwareRenderer` only when you specifically want the software renderer.

## Output files

Each run creates a timestamped folder under:

```text
tools\perf-results\perf-capture\<run_id>\
```

Typical files:

- `summary.json` — machine-readable run summary, paths, screenshot diff result.
- `screenshot.png` — captured editor window after the benchmark.
- `perf_capture_result.txt` — simple key/value result file written by the Anvil-side plugin.
- `anvil_perf_..._summary.txt` — human-readable F11-style performance summary.
- `anvil_perf_..._frames.csv` — per-frame metrics.
- `anvil_perf_..._lua_samples.csv` — Lua sampling data.
- `anvil_perf_..._api_calls.csv` — wrapped renderer/system API call counts.
- `anvil_perf_..._details.csv` — detailed counters/timers.

The PowerShell command also prints the JSON summary to stdout.

## Standalone screenshot comparison

Compare any two screenshots:

```bat
tools\compare_anvil_screenshot.bat ^
  -Baseline "tools\baselines\perf_capture_odin_book.png" ^
  -Current "tools\perf-results\perf-capture\<run_id>\screenshot.png"
```

Write JSON to a file:

```bat
tools\compare_anvil_screenshot.bat ^
  -Baseline "tools\baselines\perf_capture_odin_book.png" ^
  -Current "tools\perf-results\perf-capture\<run_id>\screenshot.png" ^
  -OutputJson "tools\perf-results\perf-capture\<run_id>\visual_diff.json"
```

The comparator exits with an error on differences unless `-AllowVisualMismatch` is passed.

## Agent/MSYS examples

From this repo's MSYS shell:

```sh
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/anvil_perf_capture_file.ps1 -UpdateBaseline
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/anvil_perf_capture_file.ps1
```

Benchmark a custom file:

```sh
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/anvil_perf_capture_file.ps1 \
  -File 'C:\path\to\file.ext' \
  -Baseline 'tools\baselines\perf_capture_file_ext.png'
```
