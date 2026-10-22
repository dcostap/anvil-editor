# Incremental layout refactor plan

## Decision

Refactor layout updates and provider invalidation together. Then move the hot layout loops over plain data into C.

Keep behavior in Lua: providers, Markdown semantics, folds, and plugin logic.
Move a loop to C only when a measurement shows that it is hot and it works on plain data.
The target is a small amount of C that removes most of the hot-loop cost.

Keep flat data structures. In C, a splice of a flat array is fast enough for the measured documents.

Reuse existing buffer edit events. Add a clear contract for position mapping and layout invalidation.

Do not rewrite the buffer, introduce a balanced tree, or merge all layout caches in this project.

Treat typing latency and file-opening time as separate performance problems. Profile both, but do not block incremental layout on an opening strategy.

## Goals

- Preserve caret movement, selections, hit testing, folding, scrolling, and inserted-row behavior.
- Rebuild and measure only affected content when the change has a known boundary.
- Preserve unrelated row data and measurements across local edits.
- Replace cache-recovery heuristics with explicit updates.
- Give one coordinator ownership of layout update order.

A local edit must not trigger a full rebuild merely because the text revision changed.

A provider change must not trigger a full rebuild merely because its model version changed.

Full invalidation remains correct for genuinely global changes or changes whose affected range cannot be determined safely.

## Non-goals

- A new buffer representation or marker interval index.
- A balanced layout tree.
- One data structure for wrapping, composed rows, heights, and rendering.
- Stable identities for every Markdown syntax node.
- Estimated off-screen heights.
- An unrelated renderer or highlighting rewrite.
- A C rewrite of behavior code, providers, or the Markdown renderer.
- Lua-to-C calls for each row. Each native module has a coarse API.

Reconsider these only when measurements identify a remaining cost that requires them.

## Current evidence and limits

The current composed-row builder walks the document and allocates new row entries.

An incremental wrapping path measures changed lines but rebuilds the flat row map. It excludes line-render providers.

Visual-row invalidation identifies a provider but does not provide its affected range. Global signatures combine several generations.

Buffer edit events already provide edit positions. Verify their timing and coordinate semantics before reusing them.

The Markdown model publishes from a worker. During typing, most publications describe an older text revision than the buffer.

Previous gallery measurements reported approximately 84 ms median typing latency and 20–24 seconds from open to ready.
These are historical observations. Milestone 1 recorded a reproducible baseline. It agrees: 89 ms and 21.7 s.

The Milestone 1 baseline shows that whole-document rebuilds from provider reports cause most of the cost.
It did not isolate suffix updates. They are part of the rewrap time, about 6 ms for each letter in the gallery.

## Update contract

Design this contract once for wrapping, folds, inserted rows, heights, and render caches.
Do not create a separate provider contract after implementing text-edit updates.

### Position mapping

Position mapping describes how a text replacement moves existing lines.

Layout uses line granularity: `{first_line, old_last_line, new_last_line}`.
Range markers and folds keep their own column-level mapping. Do not add columns or revision pairs to the layout contract until a layout consumer needs them.

Use existing buffer events as the source. Normalize them at the layout boundary only when necessary.

The Milestone 1 audit resolved these rules. The existing events express them, so no new Buffer API is necessary.

- **Source.** Use the `changed_ranges` of each Buffer transaction. All edit paths make them: `apply_edits` (typing, multi-caret edits, batch undo and redo, load), `raw_insert`, and `raw_remove`.
- **Timing.** Transaction handlers run after the Buffer changes and after `text_revision` increments. `before` text listeners see the old text. `after` text listeners run after all transaction handlers.
- **Range shape.** Each range has `old_line1..old_line2` in the old text and `new_line1..new_line2` in the new text. Both ranges include their end lines. `line_delta` is the new line count minus the old line count.
- **Several ranges.** The ranges of one transaction are sorted and do not overlap. Their `new_line` values already include the deltas of earlier ranges.
- **Mapping.** To map an old line, go through the ranges in order and add the deltas of the ranges before the line. A line inside an old range has no mapping. Its content changed.
- **Boundary lines.** The range always includes the edited lines, also when their text stays the same. A line break at the end of line 100 gives `100..100 -> 100..101`, but line 100 keeps its text. Layout can keep the rows of a line whose source text and provider output did not change.
- **Undo and redo.** One undo applies all merged steps. Each step is a separate transaction. Batch undo and redo use `apply_edits`. So several transactions can occur before one layout read. The coordinator composes their mappings in order.
- **Multi-caret edits.** One transaction has one range for each caret.
- **Load.** A `load` transaction replaces all text. It is a full invalidation.

### Layout invalidation

Layout invalidation describes lines whose rows, measurements, or drawing data may have changed.

Support multiple affected ranges and an explicit full-invalidation operation.
Define invalidation ranges in the current revision after position mapping.

Use two kinds of effect:

- Geometry: rebuild rows and measurements for these lines. Wrapping can change their row count.
- Drawing: repaint these lines without a geometry change.

A text replacement and its layout invalidation are not necessarily the same range.

Examples:

- Inserting a newline moves later content without necessarily changing its measurements.
- Editing a fence delimiter can change layout across the remainder of a Markdown block.
- Editing a footnote definition can change inserted rows at distant references.
- Toggling a fold changes visible rows without changing buffer text.

Width and font changes can invalidate measurements globally. A color-only theme change need not invalidate geometry.

Today, a wrapped view has no drawing-only effect. `invalidate_line_render` also rewraps the lines.

### Worked examples

The examples use the gallery. Today's cost comes from the Milestone 1 baseline.

1. **Type one letter on line 100 of a wrapped file without providers.**
   - Mapping: `100..100 -> 100..100`, delta 0.
   - Geometry: line 100. Its row count can change. Rows after it move by that change.
   - Measure line 100 only. Keep all other rows and heights.
2. **Type one letter on line 8736 of the gallery in Live Preview.**
   - Mapping and text geometry: as in example 1.
   - The Markdown provider reports geometry for line 8736 after the publication. It reports more lines only if the parse changed them.
   - Today: each keystroke rebuilds all composed rows, about 27 ms. Each visible line renders and wraps two times: once at the edit and once at the publication.
3. **Insert a line break at the end of line 8736.**
   - Mapping: `8736..8736 -> 8736..8737`, delta +1. Every later line moves down one line.
   - Geometry: lines 8736 and 8737. Line 8736 keeps its rows, because its text did not change.
   - Move the later rows and their heights. Do not measure them again.
   - Today: 2.2 s. The view drops all measured rows, and the next read renders all 19,185 lines again.
4. **Type `# ` at the start of a paragraph line.**
   - Mapping: delta 0.
   - Geometry: the line becomes a heading, so its height changes. The provider can also report the lines before and after it, if their block spacing changes.
5. **Change a fence opener that starts a 60-line code block.**
   - Mapping: delta 0.
   - Geometry: the complete block. The fence service reports the block range. The provider passes it on.
6. **Edit a footnote definition on line 900 that line 120 references.**
   - Mapping: delta 0 at line 900.
   - Geometry: line 900, and the inserted card rows after the block that ends near line 120.
   - The footnote provider reports the reference block. It does not report the whole file.
7. **Collapse a fold of lines 300 to 320.**
   - No text change and no mapping.
   - Geometry: lines 300 to 320 become one fold row. Rows after it move up.
8. **Insert three line breaks above off-screen headings before the parse publishes.**
   - Mappings: three transactions with delta +1 each. They compose to delta +3.
   - While the parse is pending, the provider keeps its last output and maps it down three lines.
   - At publication, the provider reports each line whose output changed, including lines that it showed as raw source while the parse was pending.
   - Today, these headings keep the 24 px body height after the publication. A fresh view gives 46 px. See baseline mismatch 1.
9. **Undo a group of three merged steps.**
   - Three transactions. The coordinator composes them and updates layout one time, at the next read.
10. **Type with carets on lines 10, 50, and 90.**
    - One transaction with three ranges, each with delta 0. Geometry: three lines.
11. **Change the window width of a wrapped view.**
    - Full geometry invalidation. This is a global change.
12. **Change only theme colors.**
    - Drawing invalidation for the visible lines. No geometry change.

### Provider obligations

Each provider must report the ranges affected by its output change, or explicitly request full invalidation.

Providers must distinguish unchanged output from a new model publication. A new model version alone does not establish changed geometry.

Preserve row identity where practical. Track content or measurement changes separately from identity and position.

Do not use table identity alone as proof that a row's height remains valid.

Stale async output is the normal case during typing. A provider keeps its last output and maps it through position mapping until a newer publication arrives.
When a publication arrives, the provider compares it with its mapped output and reports only the changed ranges.
Each publication must identify its source revision. Reject a result only when the provider cannot map it safely, and log the reason.

During migration, unmigrated providers may request full invalidation. Log the reason so this path remains visible.

## Layout ownership

Introduce one coordinator for applying layout updates. Keep each cache responsible for its own representation.

Updates are lazy:

- At edit time, the coordinator records mapped line deltas and invalidation ranges. It does not update caches.
- On the first layout read after a change, the coordinator applies all pending changes in one pass, then answers the read.

Multi-caret edits, undo groups, and several provider reports therefore produce one update.
Readers cannot observe partially updated layout, because every layout read goes through the coordinator.

Establish the update order from actual dependencies, including:

1. Map existing positions through pending text changes.
2. Collect provider and fold invalidation.
3. Update affected wrapping and composed rows.
4. Update height aggregates and invalidate affected render data.
5. Publish the completed layout revision.

Resolve any dependency cycles before implementation. Do not assume this list replaces a dependency audit.

Keep global revisions for consistency checks and genuine global changes. Stop using them as the sole invalidation decision.

Maintain the existing flat lists initially. Measure suffix movement and renumbering as part of the complete update.

## Native layout core

LuaJIT costs more than the Lua code shows:

- In the open profiles, the JIT compiler has 23–40% of the samples. GC has 7–10%.
- While typing, GC has about 24% of the measured samples.
- A Text View near a 128-slot hash limit made open two times slower. Commit `782d3f36` fixed it with a larger start size.
  Small changes can move other tables to such a limit again.

Loops over plain data in C have none of these costs. Follow these rules for native modules:

- C owns the arrays. Lua keeps its row tables in a Lua array, and C stores an integer handle into that array.
- Lua calls C once for each edit, publication, or frame, with a batch. A LuaJIT trace stops at each C function call.
- Use the portable Lua C API, not FFI. The PUC Lua build (`-Djit=false`) must still work.
- Add the module under `src/api`, as `fuzzy.c` and `line_search.c` do.
- The layout reference compares the native result with a fresh build. Also add tests with independent expected values,
  because a fresh build uses the same native code.

## Correctness reference

Add a debug/test mode that compares the current layout with a fresh full rebuild.

The reference build must not modify the layout under test or share mutable cache state with it.

Compare observable results:

- Row order and row kinds.
- Text-position to visual-row mapping.
- Visual-row to text-position mapping.
- Row heights and vertical positions.
- Fold and inserted-row placement.
- Hit-testing results at affected boundaries.

Compare behavior, not table identity or incidental internal ordering.

Use independent fixture expectations for critical cases. Two paths can agree and still share the same bug.

Enable comparison in focused correctness tests and correctness scenarios. Disable it in performance runs.

Use deterministic provider inputs when comparing both paths. Do not publish async results between the two builds.

## Implementation milestones

### Milestone 0: Correctness reference

Build the comparison mode against the current layout code, before any refactor code exists.

Run it across the existing layout, folding, footnote, and Markdown tests and the correctness scenarios.
Record every mismatch it finds as the baseline. The collapsed Callout header that is 6 px short until redraw is a known candidate.

Do not fix baseline mismatches in this milestone unless the fix is trivial. List them so later milestones can tell old drift from new drift.

Deliverables:

- The isolated full-rebuild comparison mode, committed alone.
- A list of baseline mismatches with reproduction steps.

#### Result

`data/core/layout_reference.lua` compares a view with a fresh Editor on the same Buffer.
`reference.compare(view)` returns a report. `tests/lua/ui/layout_reference.lua` tests it.

The fresh Editor gets the same presentation inputs as the view under test:

- size, position, scroll, and the scroll of each wide Markdown table
- selection, focus, and Pane membership
- wrapping, Live Preview, owned feature state, folds, and providers

The report compares row keys, row positions, row heights, y offsets, line-to-row mapping, scrollable size, and a hit test in each visible row.
It does not compare horizontal extent or drawn pixels.

The reference skips a view in these conditions:

- The Markdown model has not published the current text.
- A Live Preview view has no Markdown model.
- A footnote editor is open. Its card height comes from text that is not in the Buffer.

Set `ANVIL_LAYOUT_REFERENCE=1` to compare the Editors that each Lua test opens, after the test passes:

```sh
PYTHONIOENCODING=utf-8 ANVIL_LAYOUT_REFERENCE=1 meson test -C build-windows-x86_64 anvil:lua-ui --timeout-multiplier 6 --verbose
```

The check lets the UI run frames for async work only when the test yielded.
A test that never yields can leave UI state that a frame must not see.
The check fails when the view under test changes during the comparison, because a change would hide drift.

The Markdown layout oracle in `tests/fixtures/markdown/layout_oracle.lua` stays.
It builds a new Buffer, so it also checks the incremental Markdown parser.
The layout reference shares the Buffer and checks only the view.

The repository has no correctness scenarios. `tools/run_scenarios.py` measures performance only.

The reference compares settled layout. It cannot find a mismatch that the next frame corrects.
It did not find the collapsed Callout header that is 6 px short until redraw.
A collapse and an expand of a Callout, with and without wrapping, matched a fresh view.

#### Baseline mismatches

The last full `anvil:lua-ui` run with the reference ran 2906 tests. 10 failed.

Layout drift:

1. Off-screen headings lose their height after consecutive edits in an unwrapped Live Preview view.
   - Steps: Open a 150-line note with a `##` heading on every eighth line. Turn wrapping off. Put the caret on line 10. Type three newlines, and update the view after each one, before the parse publishes. Wait for publication.
   - Result: Each off-screen heading from line 28 keeps the body row height, 24 px. A fresh view gives 46 px. One newline does not cause it. With wrapping on, the view matches.
   - A second view of the Buffer also loses the headings above the edit, and its visible rows move.
   - Test: `ui/markdown_layout_stability.lua` > "keeps measurements across consecutive edits without wrapping".
   - Cause, confirmed in Milestone 1: each line break drops the measured rows while the parse is pending. The rebuild measures the lines below the edit as raw source, so a heading gets the body height. The publication invalidates only the ranges that the parse changed. The edited view has the same problem off-screen.

Not explained:

2. `ui/markdown_live_editor.lua` > "toggles and persists view-local Source Mode without moving editor state" reports a scrollable size of 209 px. A fresh view gives 200 px. The row is off-screen.
   - This occurs only when the complete file runs. The same steps in a separate file match, in both comparison orders.
   - A state change from an earlier test in the file is the probable cause. Not examined further.

Not layout drift. These tests change an input of the view and restore it in the test body, before the check:

- `ui/markdown_live_editor.lua` > "honors disabled live image rendering" restores `markdown_live_render_images`.
- `ui/markdown_live_editor.lua` > "presents resolved note, heading, and block embeds as bounded visual rows" restores `core.projects` and deletes the embedded files.
- `ui/markdown_live_editor.lua` > "moves down onto implicit task content without revealing its prefix" and "reveals a marker-only task after moving left from implicit content" write `core.active_view` directly. No focus event gets to the view, so it keeps the revealed task prefix.

These tests fail without the reference too:

- `ui/linewrap_toggle_scroll.lua` > "keeps the top visible text fixed when enabling wrapping": `-6.500000000003` against `-6.5000000000027`.
- `ui/textview_scroll.lua` > "limits scroll-past-end to the final line's scroll context boundary": 120 against 120.5.
- `ui/markdown_heading_leading_gap.lua` > "keeps a heading fixed when its preceding blank line becomes text" fails in 5 of 10 runs without the reference.
- `ui/line_hints.lua` and `ui/fuzzy_searcher_preview.lua` fail under load and pass alone.

### Milestone 1: Establish the baseline and contract

Audit edit listeners, invalidation paths, provider APIs, and external readers of layout fields.

Include wrapping, composed rows, heights, render caches, folds, and Markdown model publication.

Inventory callers in diff views, whitespace drawing, diagnostic underlines, live rendering, find overview, benchmarks, and sticky scroll.

Inventory all inserted-row providers. Verify the reported list: footnotes, POI preview, diff views, unified diff, and File Trees.

Record repeatable gallery scenarios for typing, newline insertion, caret movement, scrolling, and opening.
Use the same file, viewport, renderer, and build configuration for comparisons.

Measure allocation, full rebuilds, measured rows, provider work, suffix updates, and end-to-end latency where supported.
Do not add a general telemetry framework for this task.

Deliverables:

- A documented update contract with worked edit examples.
- An invalidation and ownership inventory.
- Baseline measurements with commands and environment details.

#### Result

The update contract and its worked examples are in [Update contract](#update-contract).

##### Layout caches

Each Text View has these caches. The owner is the module that writes the cache.

| Cache | Owner | Valid while | Update paths |
| --- | --- | --- | --- |
| Wrap map: `wrapped_lines`, `wrapped_line_to_idx`, `wrapped_line_offsets`, `wrapped_presentations` | `linewrapping.lua` | wrap settings, `wrapped_text_revision`, line count | Line update with suffix renumbering, full rebuild, sliced rebuild with rebase |
| Composed rows: `__composed_visual_row_cache` | `textview.lua` | `visual_row_cache_signature` | Full rebuild only |
| Row heights: `__visual_metric_cache`, a Fenwick tree | `textview.lua` | `get_visual_metric_signature` | Dirty rows, wrap splice, composed pending lines, full rebuild |
| Render plans: `__line_render_cache`, keyed by line number | `textview.lua` | Line source text and line signature | Line range, full clear |
| Line widths: `__line_width_cache` | `textview.lua` | Line render generation | Line range, full clear |
| Line packets: `__line_packet_cache` | `textview_line_packets.lua` | Packet signature | Moves entries through the edit ranges |
| Folds: `fold_regions`, range markers | `textview.lua`, `range_marker.lua` | `fold_generation` | Each fold change increments the generation |

The composed-row signature includes `text_revision`. So each edit rebuilds all composed rows.
Composed rows exist when a fold is collapsed or an inserted-row provider is active. The gallery has collapsed Callouts and footnote definitions, so it always has composed rows.

The render-plan cache does not move entries when lines move. After a line break, each later line misses the cache, because its source text differs.
The line packet cache already moves its entries. It is a working example of the mapping in the contract. It is off for Markdown views and for views with variable row heights.

The row-height cache also has a frozen copy for an external reload. Composed rows, row heights, and render plans each have a copy for one UI frame.

##### Invalidation entry points

| Entry point | Range | Effect today |
| --- | --- | --- |
| `invalidate_line_render(id, line1, line2)` | Lines or all | Clears render plans. A wrapped view also rewraps the lines at once. A large range starts a sliced rebuild. |
| `invalidate_visual_metrics(id, line1, line2)` | Lines or all | Marks rows dirty, splices rows, defers composed lines, or drops all rows |
| `invalidate_visual_rows(id)` | All only | Increments the fold generation, so composed rows rebuild |
| `bump_fold_generation(reason)` | All only | Clears fold caches and composed rows |
| `clear_composed_visual_row_cache()` | All only | Wrapping calls it after each wrap update |
| Adding or removing a provider | All only | Full invalidation of its kind |

Wrapping gives its row change to the next `invalidate_visual_metrics` call through one field, `__line_render_wrap_change`. The next call reads and clears it. This hand-off is order-dependent.

##### Edit handlers

The Buffer calls each transaction handler in `pairs` order over a table with string keys. No order is defined between these handlers:

- `range_marker`, which moves folds
- `markdown-semantic-model`, which starts a parse
- `markdown-fence-highlight`
- `textview-render-caches`, which updates wrapping, render plans, and row heights at once

`textview-render-caches` updates each view eagerly, once for each transaction. An undo of three merged steps updates layout three times.
If no line-render provider says that it handles line shifts, a line break invalidates render plans and heights to the end of the file.
The Markdown provider says that it handles line shifts.

Other handlers and wrappers of `Buffer.on_text_transaction` do not change layout: Tree-sitter, LSP documents, autocomplete, local find, POIs, navigation history, LSP diagnostics, and the vault index.

##### Providers

| Provider | File | Kinds | Reports changes as |
| --- | --- | --- | --- |
| `markdown-live` | `markdown/live_render.lua` | render, height, decoration | Line ranges for edits, publications, fences, links, and Callouts. Full for Source Mode, typography, and attach. |
| `markdown.footnotes` inline rows | `markdown/footnotes.lua` | inserted rows, height | A generation that includes the Markdown `published_revision`. No ranges. |
| Footnote editor format | `markdown/footnotes.lua` | render | Full |
| POI preview | `poi_preview.lua` | inserted rows, height, decoration | A generation from the card layout. No ranges. |
| Unified diff other rows | `plugins/diff/unified_view.lua` | inserted rows, height, decoration | `invalidate_visual_rows` and full height invalidation |
| Diff view gaps | `plugins/diffview.lua` | inserted rows by count | The provider is added again for each alignment |
| File Tree path separators | `plugins/filetree/init.lua` | inserted rows | `invalidate_visual_rows` |
| Git commit line, path tree file icons, Terminal | `plugins/git/view.lua`, `plugins/path_tree.lua`, `plugins/terminal.lua` | render | Full |
| Copy feedback, reload flash, diff colors | several | decoration | Drawing only |

The reported list of inserted-row providers is correct and complete.
`set_visual_row_extension` had no callers. Milestone 2 removed it.

The Markdown provider has three generations:

- `generation` includes `semantic_pending_line` and the adoption generation. A line break sets `semantic_pending_line`.
- `line_generation` includes `generation`. So a line break changes the render signature of every line, above the edit too.
- `metric_generation` includes only typography and width.

The Markdown provider keeps its own projected renders of the visible lines while a parse is pending. It also reads `__line_render_cache` and `__visual_metric_cache` directly.

##### Recovery paths

These paths repair layout that no provider reported. Milestone 6 removes them.

- `reconcile_visible_line_layout` remeasures each visible line whose render plan is not the plan that wrapping or heights measured. It does not repair lines off-screen.
- `resolve_composed_metric_lines` compares old and new composed rows to keep heights. It fails when a row outside the edit is a new table, because it compares footnote rows by table identity.
- The signature checks in `invalidate_visual_metrics` keep rows when only `text_revision` changed.

##### External readers

These modules read layout fields directly instead of through Text View methods:

| Module | Fields |
| --- | --- |
| `lsp/diagnostic_underlines.lua` | `wrapped_lines`, `wrapped_line_to_idx` |
| `plugins/diffview.lua` | `wrapped_lines`, `wrapped_line_to_idx`, `__wrap_layout_generation`, `fold_regions` |
| `plugins/drawwhitespace.lua` | `wrapped_line_to_idx` |
| `plugins/intellij_find/overview.lua` | `wrapped_lines`, `wrapped_line_to_idx`, `__wrap_layout_generation`, `fold_generation`, `__async_wrap_reconstruction` |
| `plugins/sticky_scroll.lua` | `wrapped_line_to_idx` |
| `textview_line_packets.lua` | `wrapped_line_offsets` |
| `markdown/live_render.lua` | `__line_render_cache`, `__visual_metric_cache` |
| `editor.lua`, `plugins/diff/unified_view.lua` | `fold_regions` |
| `plugins/perf_benchmark.lua`, `perf_workloads.lua` | `wrapped_line_to_idx`, `__async_wrap_reconstruction` |

With a lazy coordinator, a direct field read can see layout before the coordinator applies pending changes.
Each reader must read through a coordinator method, or run after a layout read in the same frame. Milestone 6 checks each one.

##### Baseline measurements

Environment:

- Build: `69f010a6` with the scenario changes of this milestone. `debugoptimized` build in `build-windows-x86_64`, D3D11 renderer.
- Machine: Intel Core i7-14700, 16 GB, Windows 11 Pro 26200.
- File: `tests/fixtures/markdown/gallery-benchmark.md`, 19,185 lines, wrapped, in Live Preview.
- Window: 1400 x 900. The narrow case uses 780 x 900. There, footnotes show as inline rows.

Commands:

```sh
python tools/run_scenarios.py --suite markdown --no-build --attribute
python tools/run_scenarios.py --scenario markdown-gallery-newline --no-build --attribute
python tools/run_scenarios.py --scenario markdown-gallery-type-narrow --no-build --attribute
```

This milestone added `markdown-gallery-newline` and `markdown-gallery-type-narrow`.
The counters come from `<run>/<scenario>/attribution/details.csv`. The rebuild reasons come from the log in `<run>/<scenario>/run-1-user/logs`.

Latency is the median and p95 of each run's actions, from three scoring runs:

| Scenario | Actions | p50 ms | p95 ms | Frame work p95 ms |
| --- | ---: | ---: | ---: | ---: |
| `markdown-gallery-open` | 1 | 21,736 | 21,736 | 14.7 |
| `markdown-gallery-wheel` | 60 | 86 | 93 | 8.0 |
| `markdown-gallery-caret` | 80 | 82 | 88 | 6.9 |
| `markdown-gallery-type` | 60 | 89 | 281 | 135 |
| `markdown-gallery-type-narrow` | 60 | 1,388 | 1,564 | 941 |
| `markdown-gallery-newline` | 30 | 2,236 | 2,469 | 2,398 |
| `markdown-vault-type` | 40 | 62 | 99 | 27 |

Wheel and caret latency includes the smooth-scroll animation.

Layout work in the attribution run:

| Scenario | Full height rebuilds | Rows in full rebuilds | Composed-row builds | Render-plan misses | Rewrapped lines |
| --- | ---: | ---: | ---: | ---: | ---: |
| type, 60 letters | 0 | 0 | 57 | 3,471 | 3,471 |
| type-narrow, 60 letters | 114 | 2,237,550 | 57 | 26,030 | 3,672 |
| newline, 30 line breaks | 32 | 623,260 | 30 | 576,184 | 2,048 |
| caret, 80 moves | 0 | 0 | 5 | 0 | 0 |
| wheel, 60 scrolls | 0 | 0 | 0 | 208 | 227 |
| open, 1 open | 3 | 58,900 | 59 | 21,330 | 19,185 |

Time in the attribution run:

- **type:** composed-row builds take 27 ms on average and 147 ms at most. Resolving composed lines takes 29 ms for each letter, which includes the build. Rendering takes 7 ms and rewrapping 6 ms for each letter.
- **type-narrow:** each full height rebuild takes about 650 ms. Each letter causes two:
  - "signature": the footnote generation changes at each publication.
  - "rows": `resolve_composed_metric_lines` compares footnote rows by table identity. The provider makes new tables.
- **newline:** each line break drops all heights with reason `text-change`. Composed lines cannot defer a change of line count. The next read renders every line again, because each line signature changed. Full rebuilds take 2.2 s each. Rendering is 1.6 s of that, about 84 us for each line.
- **open:** a synchronous full wrap takes 1.0 s. The publication starts a second full wrap in 4 ms slices. That wrap takes 5.1 s over 1,113 frames. Three full height rebuilds take 0.6 s. Composed-row builds take 1.4 s. The open waits for paced work over about 3,200 frames. No single pass explains the 21.7 s.

The runner records the Lua heap size: 204 to 258 MiB in the suite run, 286 MiB for type-narrow, and 362 MiB for newline. It does not record allocation for each action. Add that only if a later milestone needs it.

##### Consequences for Milestone 2

The causes are provider reports, not walks of the flat lists. Fix them inside the provider-aware path:

1. Report footnote changes as ranges. Do not put `published_revision` in the footnote generation.
2. Compare inserted rows by provider row ID and content, not by table identity.
3. Remove `semantic_pending_line` from the Markdown view generation. Report pending lines through ranges.
4. Move render plans and heights through a line break instead of dropping them.
5. Stop rebuilding composed rows because `text_revision` changed.

Run `markdown-gallery-type-narrow` and `markdown-gallery-newline` before and after each change. The completion criteria use the rebuild counters above.

### Milestone 2: Complete one provider-aware path

Implement one local edit path through providers, wrapping, composed rows, heights, and render invalidation.

Use a wrapped view with inline footnotes. This tests the provider dependency that motivates the refactor.
The same path must also work for a plain wrapped file without providers.

Reuse unrelated rows and measurements. Do not rebuild all rows and then compare them to recover reuse.

Keep explicit full invalidation for unsupported paths during this milestone.

Add cases incrementally for:

- A local edit with unchanged footnote output.
- An edit while the Markdown model is still publishing an older revision.
- An edit that changes a displayed footnote's content or height.
- A definition edit that affects distant footnote references.
- A newline insertion and deletion above inserted rows.

Check geometry against the full rebuild and independent expectations.

Deliverables:

- One complete incremental path, including its provider.
- Red-green evidence for each implemented behavior.
- Before-and-after performance results with comparison mode disabled.

Do not expand the migration until this path proves both correctness and reduced work.

#### Result

Commits `b6ac5349`, `48227deb`, and `782d3f36`.

- Composed rows and row heights update from line changes. Row providers report their dependent lines.
- Footnote rows change only when the definitions or the reference order change.
- An unwrapped view without composed rows maps its heights through line changes. This fixed baseline mismatch 1.
- Text that changes outside a transaction rebuilds every composed row, and the log tells why.

| Scenario | Before (ms) | After (ms) |
|---|---:|---:|
| `markdown-gallery-type-narrow` p50 | 1388 | about 88 |
| `markdown-gallery-newline` p50 | 2236 | about 78 |
| `markdown-gallery-open` | 21,700 | 19,000–21,000 |

Costs that remain:

- Each edit copies and renumbers every composed row, and builds the line-to-row map again.
  This takes 3–11 ms for each frame while typing, and 20–37 ms for each edit in the gallery.
- Each edit copies every row height and builds the height tree again, also when no row count changes.
- A Markdown line wraps through a Lua cursor, one character at a time. This is about 75% of the wrapping time.
- A newline still wraps about 35 lines again.

Milestones 3 and 4 move the first three costs to C. Do not tune them in Lua first, because the native code replaces that Lua code.

### Milestone 3: Native row index

Move the composed rows and the row heights into one native index.

- C stores one record for each row: kind, line, row in line, payload handle, and height.
- C keeps the line-to-row map and the height prefix sums.
- A splice moves the records after the change with one `memmove`, and updates the sums.
- Lua still builds the rows of the changed lines with `append_line_rows`. C receives them as one batch.
- Each frame, Lua gets the visible rows with their y and height in one call.

Start with flat arrays. Use block sums only if a measurement shows that the flat splice costs too much.

Delete the Lua renumbering, the full `position_rows` build, the metric copies, and the Lua height tree.
Keep `layout_changes`, `dependent_lines`, and fold expansion in Lua.

Deliverables:

- The native index and its Lua API, with tests that use independent expected values.
- Layout tests that pass with `ANVIL_LAYOUT_REFERENCE=1`.
- Composed-row and height work below 1 ms for each edit in `markdown-gallery-type-narrow`.
- A PUC Lua build that compiles.

#### Result

Commits `fb779c3c`, `1b610a18`, `14618fd8`, and `1d57dced`.

- `src/api/layout_rows.c` has two objects: `rows()` and `heights()`. They are separate, because a view without composed rows still has heights.
- `rows()` keeps one record for each row: kind, line, last line, row in line, and payload handle. A plain text row has no payload, so it has no Lua table.
- `heights()` keeps the height and the render plan ID of each row, and lazy prefix sums.
- One `replace` call splices the rows of a change and moves the lines of later rows. It reads the whole batch before it changes a row.
- `composed_visual_rows()` is gone. Callers read one row with `get_visual_row_entry`.
- The layout tests have the same results as before, with `ANVIL_LAYOUT_REFERENCE=1`.
- `layout_rows.c` compiles with no warnings against the Lua 5.4 headers. A full PUC Lua build was not run.

The last 4.3 ms of each 5.1 ms update in the narrow window was not row bookkeeping.
Inline footnote rows parsed every footnote line again at each block end. Commit `1d57dced` gets the numbers only for a block that has a note.

| `markdown-gallery-*`, ms | Before | After |
|---|---:|---:|
| `type-narrow` composed-row update, each frame | 7.23 | 0.37 |
| `type-narrow` metric resolution, each frame | 9.11 | 0.58 |
| `type` composed-row update, each frame | 3.30 | 0.29 |
| `newline` composed-row update, each frame | 4.95 | 0.24 |
| `type-narrow` p50 / p95 latency | 92 / 280 | 61–66 / 151–162 |
| `newline` p50 / p95 latency | 92 / 267 | 60–71 / 171–202 |
| `open` | 18,100–19,800 | 19,300–20,100 |

Each edit now takes 0.38–0.61 ms of composed-row work. The open runs overlap. Three runs cannot show if the difference is real.

Deferred: a native call that returns the visible rows of a frame. A frame reads about 60 rows, and that cost is not measurable now.

Costs that remain, each frame while typing:

- Reconcile takes 6.5–8.5 ms. Each keystroke wraps 30–35 lines again, because their render plans change.
- The line render cache lookup takes 3.7–5.6 ms, and the line render build takes 1.8–3.1 ms.
- Line wrapping takes 1.6–2.2 ms.

### Milestone 4: Native fragment wrapping

The renderer already measures widths and wraps plain text in C.
Extend that wrap to lines with hidden spans, remapped text, and fixed-width widgets.
Lua resolves the fragments of a line. C finds the breaks for many lines in one call.

Use the same call for edits and for the sliced wrap when a file opens.
Measure `markdown-gallery-open` and `markdown-gallery-newline` before and after.

#### Result

Implementation commit `898f4129`.

- `renderer.wrap_fragment_lines` wraps rendered lines in one native call per batch.
- Lua prepares fragments. C handles hidden spans, remapped text, widgets, and word breaks.
- Edits and sliced opening use the same batch API. The old Lua character loop is gone.
- The focused fragment tests pass: eight cases with independent expected breaks.

Measurements alternated before and after on October 22, with three attempts per version.
Two before newline runs completed. Two after scoring runs and one after attribution run completed.
Other attempts failed during setup. The last pair allowed 600 seconds for newline setup instead of 240.
Temporary `probe_` timers used matching scopes. No probes remain in the implementation.

| `markdown-gallery-newline`, ms | Before | After |
|---|---:|---:|
| Wrap update, each frame | 5.72–7.41 | 2.36 |
| Wrap compute, each frame, including native calls | 4.57–7.02 | 2.15 |
| Wrap compute, each line | 0.170–0.244 | 0.075 |
| Rendered break loops, each frame | 2.78–2.80 | 0.064 |
| Rendered break loops, each rendered line | 0.098–0.106 | 0.0023 |
| Fragment layout preparation, each frame | 0.89–2.15 | 1.05 |
| p50 / p95 latency, first completed scoring run | 177 / 661 | 214 / 896 |
| p50 / p95 latency, second completed scoring run | 315 / 1520 | 131 / 444 |

Before, the Lua cursor alone took 0.261–0.293 ms per cursor line.
The rendered-loop comparison includes both old paths: the Lua cursor and native plain-text wrapping.
After, the native batch handles both groups. The compute timer includes preparation, not only break selection.
Load varied greatly. These samples show lower loop cost, but cannot establish an end-to-end latency improvement.

Both before `markdown-gallery-open` attempts timed out at the 60-second action limit.
Two after attempts also timed out; the last after scoring run completed in 58.5 seconds.
These results do not give a reliable open-latency comparison.
The following table uses the first committed sliced wrap during newline setup, from scoring and attribution runs.

| Sliced opening work, seconds | Before | After |
|---|---:|---:|
| Total slice work | 12.51–15.58 | 7.35–11.75 |
| Resolve line render plans | 8.18–10.54 | 5.85–9.35 |
| Lua cursor | 1.59–2.23 | removed |
| Native break loops | 0.14–0.20 | 0.082–0.373 |
| Fragment layout preparation | 1.23–1.55 | 0.65–0.97 |

An earlier comparison reported 9.5 seconds of resolution against 9.4 seconds of sliced work.
Those scopes differed: resolution included all process calls. New counters include only calls inside each slice.
Render-plan resolution accounts for 79–83% of the measured after slice work.
Building Markdown render plans remains the main opening cost, not native break selection.

Costs that remain:

- Lua builds text layouts with one `font:text_layout` call per fragment. This is the largest remaining measured wrap part.
- Render-plan resolution dominates sliced opening. It belongs to the separate opening-performance workstream.
- Reconcile and render-cache lookup still dominate the measured newline frames.

### Milestone 5: Migrate remaining paths

Migrate providers and layout consumers in small complete changes.

Cover fold changes, line-render providers, remaining inserted-row providers, undo, redo, and multi-caret edits.

For each path:

1. Identify its public behavioral seam.
2. Add a focused failing test or reproducible case.
3. Implement range-aware updates.
4. Compare results with a fresh rebuild.
5. Measure the affected scenario.
6. Remove the recovery logic that the new path replaces.

Include edits at fold boundaries and Markdown edits whose semantic effects extend beyond the edited line.

Preserve viewport anchoring and hit testing when content moves above the visible area.

Do not require a wholesale Markdown parser rewrite. Providers may derive affected output ranges from existing models initially.
Measure that derivation cost before introducing stable syntax-node identities.

### Milestone 6: Remove obsolete recovery paths

Remove `resolve_composed_metric_lines` and old/new row matching after the new contract covers their supported paths.

Remove signature exceptions whose only purpose was to infer local changes after global invalidation.

Keep the full-rebuild implementation as an explicit global-update path and correctness reference.
It must not remain a competing implicit update system.

Audit direct external access to layout fields. Update callers that bypass the coordinator's consistency rules.
Do not rewrite unaffected callers merely to create a larger abstraction.

Run the relevant integration tests and scenarios for the completed migration.

Deliverables:

- One clear incremental update path.
- Explicit, diagnosed full-invalidation paths.
- Removal of replaced matching logic.
- Final correctness and performance report.

## Separate workstream: opening performance

Profile open to ready before choosing an opening architecture.

Separate parsing, provider publication, highlighting, wrapping, measurement, rendering, and repeated passes.
Record both first visible content and ready-for-input time.

Investigate fence-cache access and eviction. Do not assume a larger cache fixes the underlying access pattern.

A reported 900 ms wrap pass does not explain a 20-second open. Account for the remaining time.

Apply measured redundant-work fixes first. Reassess exact-layout opening performance afterward.

If deferred measurement remains necessary, document the behavior of:

- Scrollbar size and viewport anchoring.
- Go-to-line and distant search results.
- Sticky scroll and the find overview.
- Mouse targets in unmeasured content.

Deferred exact measurement still needs provisional geometry, on-demand measurement, or temporary restrictions.
It is not a behavior-free alternative to estimated heights.

`core.add_thread` runs on the UI thread. Use bounded yields for cooperative work.
Use worker jobs only with copied inputs that do not access live UI objects.

Estimated heights require a separate decision and plan. Do not add them implicitly during this refactor.

## Validation

Follow the testing and commit rules in `AGENTS.md`.

Record known baseline failures and Milestone 0 mismatches separately. Do not attribute them to this refactor without evidence.

Keep performance thresholds out of ordinary correctness tests. Report repeated latency measurements and work counts separately.

## Completion criteria

The refactor is complete when:

- Supported local edits produce zero whole-document row rebuilds per keystroke. Check this with the existing rebuild counters in these scenarios:
  - typing in a plain wrapped file
  - typing in the gallery with inline footnotes
  - an edit above an expanded Callout
- Unchanged provider output does not cause global invalidation.
- Stale async provider output is mapped, not rejected or globally invalidated.
- Position shifts preserve unrelated measurements when their inputs remain unchanged.
- Distant provider effects invalidate all affected ranges correctly.
- Incremental geometry agrees with fresh layout across the supported scenarios, apart from recorded baseline mismatches.
- Caret movement, hit testing, folding, and viewport anchoring retain their behavior.
- Obsolete matching and signature-recovery paths are removed.
- Remaining full invalidations have explicit reasons.

Report latency and allocation changes from repeated measurements. They are a report, not a gate.
Do not promise a 16 ms typing budget from this change alone. Report any remaining dominant cost.

## Decision gates

Do not attach a fixed schedule to the current line-count estimate.
Estimate the remaining work after the first provider-aware path exposes the actual migration cost.

Add a tree only if measured suffix updates remain a material cost.
Use block sums in the native row index only if measured flat splices cost too much.
Move visible-row geometry for drawing to C only if it is still a measured cost after Milestone 3.
Stop the global `ipairs` wrapper in `data/compat/module.lua` only after an audit shows that no caller needs it.
Merge structures only if separate ownership still causes demonstrated consistency problems.
Add marker indexing only if marker work becomes a measured bottleneck.
Add column-level or revision-pair mapping to the layout contract only when a layout consumer needs it.
Choose estimated heights only through the separate opening-performance decision.
