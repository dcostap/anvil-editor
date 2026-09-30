# Local Find performance

## Design

Local Find scans the Buffer lines table in C.
Plain matching does not join the Buffer or allocate lowercase line copies.
Regex matching uses the existing compiled PCRE2 expression.
The native index stores packed ranges by line and a count prefix tree.
Ordinal lookup and navigation do not need a full Lua match table.
Small result sets still expose the existing Lua tables.

Scanning starts at the caret. It can publish the nearest match before the count finishes.
The Prompt Bar keeps `Searching…` until the complete result is ready.
Native scanning and coverage construction use six-millisecond slices.
A line over 64 KiB uses the existing worker path.
Edits replace affected line blocks and update count prefixes.
They do not copy every match or rebuild every line list.

The overview retains complete pixel coverage during replacement work.
Uniform-layout edits update the affected coverage edges.
Wrapped coverage resumes against one completed row map.
An active wrap reconstruction does not replace the last complete coverage.
Drawing reads retained coverage and paints the selected marker last.
Equal neighboring coverage runs share one rectangle.

Find backgrounds and outlines reuse their range rectangles during a line draw.
They no longer calculate each range twice.

## Reference comparison

The fixture has 450,000 lines, 15,750,000 bytes, and 1,800,000 matches for `i`.
The reference is `ca53e833` in a separate worktree.
Both apps use isolated test data and the same generated fixture.
The reference executable uses the old changed C files and the same unchanged dependencies.
These runs did not enable the detailed recorder.

| Measurement | Reference | Candidate |
|---|---:|---:|
| Unwrapped complete results and markers | 2631.050 ms | 378.949 ms |
| Unwrapped caret reveal | 2436.347 ms | 97.517 ms |
| Wrapped complete results and markers | 46345.481 ms | 1921.140 ms |
| Wrapped caret reveal | 3004.747 ms | 38.604 ms |
| Unwrapped edit median / p95 | 90.219 / 159.093 ms | 1.933 / 2.766 ms |
| Wrapped edit median / p95 | 290.791 / 308.767 ms | 3.980 / 14.194 ms |
| Unwrapped edit frames without markers | 6 / 50 | 0 / 50 |
| Wrapped edit frames without markers | 50 / 50 | 0 / 50 |

The candidate's complete native scan took 7.489 ms.
Complete publication also includes UI scheduling, Lua materialization, and overview work.
A quick dispatch alone does not count as complete publication.

## Redraw observations

| View draw, median / p95 | Reference | Candidate |
|---|---:|---:|
| Unwrapped, Find open | 7.119 / 46.540 ms | 8.041 / 43.330 ms |
| Unwrapped, Find closed | 1.582 / 2.292 ms | 7.857 / 12.590 ms |
| Wrapped, Find open | 14.635 / 72.225 ms | 7.494 / 12.404 ms |
| Wrapped, Find closed | 2.516 / 2.918 ms | 2.356 / 3.120 ms |

These are isolated View draws, not complete Root Panel frames.
The reference's large C parse failed. The candidate's parse completed.
Thus their unwrapped syntax work differs. Do not claim that table as a like-for-like rendering improvement.

The old 29 ms report included unsettled work and incomplete frame flags.
Focused scopes showed line-body emission as the main Find draw cost.
The rectangle reuse change removes repeated range geometry work.
The overview draw cost stays independent of match count.

## Regression checks

`tests/lua/runtime/local_find_native.lua` compares native results with `scan_line` on varied inputs.
It covers plain and regex matching, empty matches, local replacement, and resumable coverage.
Its budgeted coverage test failed before the coverage change and passed afterward.
The nearest-match test failed before early stopping and passed afterward.

`tests/lua/ui/local_find_reveal.lua` checks early reveal and later caret movement.
`tests/lua/ui/local_find_coverage.lua` checks retained wrapped and unwrapped markers.
The existing large-Find tests pass.
The protected scrollbar-marker regression now passes.
The protected competing-highlight failure remains unchanged, as requested.

## Reproduce

Copy `tools/local_find_probe.lua` to `tests/lua/ui/_probe/local_find.lua`.
Run it through `tests/run-lua-tests.sh` with an isolated probe suite.
The probe reports complete results, reveal, marker retention, edit costs, and redraw costs.
Use `FIND_PROBE_PROFILE=1` only for separate scoped diagnostics.
Use `FIND_PROBE_ROOT=1` for Root Panel measurements.
Remove the temporary probe files and isolated probe data after the run.
