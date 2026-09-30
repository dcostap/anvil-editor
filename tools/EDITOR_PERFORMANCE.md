# Editor performance follow-up

## Scope

The generated C fixture has 450,000 lines and 15,750,000 bytes.
Each line contains `int input = input + 1; /* input */`.
Measurements use isolated test apps. They do not use the daily portable app.

The original source revision is `ca53e833` in a separate worktree.
The native reference uses that worktree's changed C files and unchanged build dependencies.
Each comparison runs the reference and candidate separately.

## Tree-sitter

The Lua scheduler uses text revisions, not a full line-length scan, to detect changes.
It does not submit another snapshot while the same Buffer has a queued or running parse.
It submits the latest text after that parse ends. It rejects obsolete publication.

The native API builds each immutable snapshot directly from the Lua lines table.
It returns the snapshot byte count after successful submission.
This keeps one existing ownership model. It does not add a second mutable text model.

The parser's progress timeout ends a slice, not the parse.
The worker resumes the same parser with the same immutable input.
The former code treated a slice timeout as a failed parse.

Workers also compare trees and release retired trees and snapshots.
The UI publishes completed trees and changed ranges without traversing old trees for destruction.

`tests/lua/runtime/treesitter_parse_followup.lua` checks bounded parser resumption.
It also compares highlights, outline, and symbols with a fresh parse after queued edits.

The ownership review covers submission, stale completion, cancellation, close, and shutdown in `src/treesitter/service.c`.
Each parse job retains its state and owns its snapshot, copied trees, and untransferred ranges.
Successful polling moves the new tree and snapshot into the state.
It moves ranges into the poll result and nulls the job pointer.
The cleanup queue owns retired data. Workers release it outside the service lock.
Stale or cancelled jobs keep their data until cleanup; they cannot publish it.
Close cancels active work and moves committed data into a cleanup job.
If that allocation fails, close uses the existing synchronous release fallback.
Completed jobs for closed Buffers stay owned until polling cleanup or shutdown.
Shutdown cancels work, joins workers, detaches queues, then releases remaining jobs outside the lock.
These paths retain ownership until release. The review did not add a second ownership model.
Allocation-failure handling was reviewed in source, not tested with fault injection.

## Add Next Occurrence

The command uses native streaming KMP over Buffer lines.
It starts at the active selection's end. It does not join or lowercase the complete Buffer.
It can match across line boundaries.

The command retains selection exclusion, case mode, and the two-step wrap rule.
Other callers of the old whole-text index keep their existing behavior.

`tests/lua/ui/next_occurrence_large.lua` checks multiline matching and case mode.
`tests/lua/ui/intellij_actions.lua` checks existing command behavior and wrap rules.

## File I/O

UTF-8 loading splits lines in C and prepares source and display lines together.
It retains invalid source bytes, BOM information, and CRLF conversion.
Repeated neighboring lines reuse string and validity results.
Other encodings keep their existing conversion path.

Synchronous UTF-8 saves write bounded batches instead of one call per line.
Encoding conversion keeps the existing synchronous path.

Large idle, retry, focus-loss, and deferred View-close saves can prepare files on a worker.
A named `file_io` pool keeps file preparation separate from background scans.
Workers write, flush, sync, and close temporary files before publication.
The UI rechecks settings, file identity, link count, and the save guard.
It then uses the normal save hooks and replacement rules.

Async saving requires an existing regular UTF-8 file and safe-write support.
Symlinks, multiple links, encoding conversion, and active LSP documents keep synchronous handling.
The existing backup and identity-preserving fallback rules remain unchanged.

Later edits remain dirty. A newer synchronous save cancels older preparation.
Large View closes wait without blocking input. They save again if later edits remain dirty.
The synchronous `save_before_close` API retains its completed-save return contract.

Tests cover BOM and CRLF bytes, late edits, merged text input, cancellation, guards, and replacement rejection.
The existing save and Autosave close tests also run.

## Find drawing

Find backgrounds and outlines reuse the same range rectangles within one line draw.
The former code calculated every range twice.
The overview keeps finished pixel coverage while replacement coverage builds.
See [Local Find performance](LOCAL_FIND_PERFORMANCE.md).

## Wrap reconstruction

A source edit rebases the pending forward cursor and prepared line arrays.
It marks affected prepared lines for repair after the forward pass.
For structural edits, it also repairs shifted render-provider plans.
This prevents old line positions or heights from reaching publication.

`tests/lua/ui/wrap_rebuild_enter.lua` controls the scheduler and clock.
The test failed before the change because Enter kept restarting preparation.
It passes after the change and compares final row counts with a fresh layout.
The existing wrapped publication, caret geometry, and large-file wrap tests pass.

## Checks and limits

The user-owned Find and Tree-sitter test files stay unchanged and unstaged.
The known competing-highlight Find failure remains unchanged, as requested.
The protected Tree-sitter file passes all 85 tests.
Earlier runs had Project watcher timing failures in both reference and candidate apps.

Performance timings stay outside correctness tests.
The probes report complete results, not only dispatch time.
File sync and process scheduling can vary between runs.
Do not treat an asynchronous dispatch improvement as a complete-save improvement.

## Measured results

| Generated C fixture | Reference | Candidate |
|---|---:|---:|
| Buffer open | 211.366 ms | 90.087 ms |
| Snapshot bytes during the edit probe | 94,500,073 | 47,250,034 |
| Snapshot UI work | 77.818 ms | 45.419 ms |
| Snapshots submitted | 6 | 3 |
| Completed / cancelled / failed parses | 0 / 0 / 1 | 3 / 0 / 0 |
| Edit and poll median / p95 | 2.081 / 5.173 ms | 2.652 / 3.141 ms |
| Next Occurrence median / p95 | 57.640 / 80.866 ms | 0.335 / 1.108 ms |
| No-case Next Occurrence median / p95 | 65.641 / 96.095 ms | 0.165 / 0.300 ms |
| Synchronous save | 68.018 ms | 67.126 ms |

The complete-save result did not improve in the asynchronous probe.
One candidate run dispatched in 38.263 ms and completed in 322.541 ms.
Its worker took 13.805 ms. UI completion took 8.861 ms.

A callback-timed run separated publication from test-coroutine resumption.
File sync varied substantially in that run: 173.011 ms synchronously and 176.528 ms on the worker.
Async dispatch took 36.764 ms. Publication took 270.707 ms. The test resumed after 425.752 ms.
Thus the former elapsed-time gap included test resumption and rendering, not unexplained worker work.
The async path reduces UI blocking. It does not guarantee lower complete-save or close latency.

## Render checks and remaining work

Two unchanged-revision `wrapped-document-steady` runs produced identical images.
The exact comparison found zero changed pixels, including the tab caption.
Frame p50 / p95 changed from 1.327 / 1.825 ms to 1.365 / 2.197 ms.
The historical caption-color difference did not reproduce. Its cause remains unproven.

Find alpha and wrapped reference scenes matched every document, overview, and footer pixel.
Their only differences were scenario names in the titlebar.
The alpha comparison changed 3963 caption pixels. The wrapped comparison changed 4161 caption pixels.
Both differences stayed inside `(14, 4, 297, 30)`.

The full standard gate rejected the first baseline attempt because wrapped scrolling ended at different offsets.
Otherwise identical states ended at `40842.0` or `40830.5` pixels.
The focused red run reproduced both offsets across unchanged processes.
The gate had skipped a scroll target when its line was visible during the preceding animation.
Scripted positions now always set their centered target. The editor's scroll methods stay unchanged.
The same three-run gate passes after this fix. Every final offset is `40830.5`.
Its frame p50 / p95 is 1.426 / 2.150 ms, with zero absolute flags.

Find pixel references now share their scene's fixture directory name.
Before this change, different Project captions caused 3963 and 4161 changed pixels.
Both whole-image comparisons now have zero changed pixels and zero ignored edge pixels.
The four Find scenes pass capture and state checks. Their slow per-match reference drawing produces budget flags.
These focused runs check pixels; they do not establish a performance baseline.

The historical caption race already has a fix in `a508d62d`.
Tab labels get their color from asynchronous file Git status.
That commit added decoration readiness to legacy warmup and capture.
It also rejected short legacy timing comparisons and stopped gating single paced maxima.
Current unchanged-revision images match exactly. The original 997-pixel images are unavailable here.
Thus code and history identify the race, but cannot prove the exact historical image difference.
Keep the existing readiness and paired timing checks. Do not weaken pixel or timing limits.

The first fresh baseline passed, but its next comparison failed with `KeyError: run_dir`.
Baseline publication had omitted the runtime path required by paired replay.
The baseline now retains that path. Missing snapshots produce a clear error instead of a lookup exception.
The targeted CLI test failed before this fix. All 24 gate harness tests pass after it.

The complete fresh baseline at `20260930_174052_46652` passes all eight standard scenes with zero absolute flags.
The unchanged-revision comparison at `20260930_174509_57812` also passes, using paired reference processes.
No comparison used update flags or report-only mode. Timing and exact-pixel limits remain unchanged.
Wrapped steady frame p50 / p95 is 1.304 / 1.623 ms in the baseline and 1.315 / 1.680 ms afterward.
Wrapped scroll changes from 1.385 / 1.992 ms to 1.395 / 2.046 ms.
Every captured standard scene passes exact pixel and state checks.
The local baseline is `tools/perf-results/render-gate/task-baseline/render_perf.json`; adjacent `goldens` holds its images.
Keep its referenced `app` directory. It contains the accepted runtime, not the current working files.

The final Find capture run is `20260930_175542_32016`.
Alpha and wrapped overview images each match their per-match reference with zero changed pixels and zero ignored edge pixels.
This short pixel check has ten budget flags. It does not replace the complete timing comparison above.

The ordinary View redraw distributions appear in `LOCAL_FIND_PERFORMANCE.md`.
The corrected Root Panel probe also includes shell Views, layout, and renderer completion.
The test loop and probe now use the same private window and viewport.
The probe waits for startup before selecting its Pane.
A missing optional package-manager binary had opened the Log View after the first yield.
Both former measurements therefore had invalid layout or visibility assumptions.

Two probe checks failed before correction: viewport changed to `800x600`, then the Log View replaced the Editor.
The corrected probe verifies actual Editor drawing at `1100x739` in all four cases.
Both reference and candidate probes pass. Timed frames use no detailed recorder.

| Root Panel update, draw, and renderer completion | Reference median / p95 | Candidate median / p95 |
|---|---:|---:|
| Unwrapped, Find open | 9.179 / 36.668 ms | 7.909 / 14.476 ms |
| Unwrapped, Find closed | 2.418 / 3.282 ms | 2.813 / 3.310 ms |
| Wrapped, Find open | 13.005 / 20.961 ms | 10.325 / 36.765 ms |
| Wrapped, Find closed | 2.249 / 2.974 ms | 2.312 / 3.434 ms |

The wrapped Find tail did not improve in this sample. Neither Find-open median meets the 6.06 ms budget.
Reference parsing failed; candidate parsing completed. Their syntax drawing work is not equivalent.
Keep these limits when reading the comparison.

Separate scope samples put candidate Root Panel layout at 0.210–0.292 ms.
Status Bar update costs 0.162–0.241 ms. Editor update costs 0.047–0.090 ms.
Find line-body drawing costs 6.836–7.464 ms and dominates emission.
Without Find, line-body drawing costs 1.869–2.180 ms.
The current measurements do not support a new panel or Status Bar cache.
Such caches would add invalidation rules for a small measured cost.

The required Markdown probe used 600 sections and 12,001 lines.
Software-renderer wrapped open took 3347 ms before and 3254 ms after.
Fast typing frame p50 / p95 changed from 84.45 / 145.92 ms to 84.48 / 112.43 ms.
Both runs reported zero pending full wrap rebuild frames during typing.
These frame timings do not establish the requested 24–36 ms target.

The centered-lane scope fix passed a red-green geometry regression.
It did not remove the opening width changes or repeated preparation.
The final profile still prepared 12,001 plain lines and another 12,001 semantic lines.
Widths still changed between `803.65104166667` and `744.66666666667`.
Single-preparation Markdown opening remains incomplete. Do not claim that requirement as implemented.

The next geometry fix installs the Markdown attachment state before its providers.
Provider invalidation now measures the current font and viewport width, not the old committed width.
This prevents a replacement layout from preparing the previous reading lane.

`wrap_provider_resize.lua` failed because provider publication retained the old viewport width.
`markdown_wrap_attachment.lua` failed because attachment published rows for the previous lane.
Both targeted tests pass after the fix.
Wrapped publication, Markdown open/resize, and Markdown metric reuse also pass.
Caret geometry passes 16/16; lane scope passes 1/1.
Markdown frame coherence passes 10/11 in both the original reference and candidate.
Its existing empty-nested-dash failure is unrelated to this change.
These checks prove geometry behavior, not single-preparation performance.

A row-map change now clears the current metric snapshot, not the retained metric tree.
The real UI-frame resize regression failed on `1f2e195d`: the scrollbar kept the previous row heights.
It passes with snapshot invalidation. This keeps incremental metric updates during typing.

The unchanged 600-section software probe at `1f2e195d` reports wrapped readiness at 2716 ms and unwrapped readiness at 1068 ms.
Wrapped fast frames have p50 / p95 / max of 72.14 / 122.41 / 123.26 ms.
Unwrapped fast frames have 92.72 / 150.16 / 154.31 ms.
Both modes report zero pending full wrap-rebuild frames while typing.

The later preparation trace has one plain pass and one complete semantic pass.
Plain preparation costs 23.65 ms. It prepares 12,001 lines before Markdown attachment.
That pass supplies the committed rows required by the existing open/resize contract.
Removing it would change `set_wrapping_enabled` behavior for callers that attach Markdown later.
Its cost is less than 1% of measured opening time. Further removal is not justified here.
The semantic pass prepares every line; later fence results repair a few changed lines.
Do not describe these distinct presentations as one total preparation pass.

Cold-frame timing separates 45–113 ms of software renderer completion from typical 5–14 ms updates and 2–7 ms emission.
The software probe therefore does not meet the historical 24–36 ms worst-frame target.
That limit was already exceeded by the reference. Do not hide renderer completion or report emission alone.

An experiment gave direct View calls and background slices their own global phase flags.
It reduced idle lookup work but did not improve complete opening or cold-frame latency reliably.
It also enabled native packet paths absent from the original probe.
The experiment was removed. No extra phase wrapper or larger slice budget remains.
Further renderer work requires a separate measured change and pixel checks, not reduced Markdown coverage.

The final serial reference/candidate repeat uses `1f2e195d` and the final Lua implementation.
Wrapped readiness is 3191 / 2995 ms; unwrapped readiness is 1448 / 1456 ms.
Wrapped fast-frame average is 118.47 / 119.20 ms; p50 / p95 is 116.14 / 171.44 versus 114.52 / 158.30 ms.
Unwrapped fast-frame average is 130.07 / 119.54 ms; p50 / p95 is 111.04 / 230.32 versus 120.86 / 187.05 ms.
Both modes pass and report zero pending wrap-rebuild frames. These variable results do not prove a new typing speedup.
The reference also exceeds the requested worst-frame limit. Single-pass opening and that limit remain unmet.
Further Part 7 work was not accepted: the measured plain pass is small, and the broader experiment changes probe paths.
The committed fixes preserve current geometry and metric publication without delaying a required layout or raising budgets.

## Final focused checks

- Protected Tree-sitter: 85/85 passed.
- Protected Find: 14/15 passed. The existing competing-highlight failure remains.
- Async save: 7/7 passed. Bulk file I/O: 2/2 passed. Existing saves: 8/8 passed.
- Encoding: 8/8 passed. Existing Autosave close: 19/19 passed. Large close: 1/1 passed.
- Centered Editor: 8/8 passed. Lane scope: 1/1 passed.
- Wrap caret geometry: 16/16 passed. Large-file wrap and Markdown metric reuse: 1/1 each passed.
- Lua syntax validation passed for the changed modules and the follow-up probe.

The lane-scope regression failed on the reference revision and passed with the scope fix.
Its assertion compares lane geometry, not a selected cosmetic size.
The final checks used isolated Meson apps. They did not replace or restart the daily app.

## Commits

- `493fd1cb`: continue pending wrap preparation after Enter.
- `1965ddb5`: native Find index and retained overview coverage.
- `9a537a09`: coalesced Tree-sitter scheduling and worker tree cleanup.
- `b849db71`: streaming Next Occurrence search.
- `66c36298`: batched UTF-8 I/O and worker save preparation.
- `16306853`: stable centered-lane geometry inside its scope.
- `cd32ee2d`: initial performance results and measurement limits.
- `61889d78`: complete Root Panel redraw measurements.
- `1f2e195d`: provider wraps at the current reading width.
- `aa263c44`: repeatable scroll targets and reference captions.
- `66f93ed9`: metric snapshot invalidation after row-map changes.
- `8d650507`: saved render-baseline runtime path.
