# Incremental layout refactor plan

## Decision

Refactor layout updates and provider invalidation together. Keep the current flat data structures initially.

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

Reconsider these only when measurements identify a remaining cost that requires them.

## Current evidence and limits

The current composed-row builder walks the document and allocates new row entries.

An incremental wrapping path measures changed lines but rebuilds the flat row map. It excludes line-render providers.

Visual-row invalidation identifies a provider but does not provide its affected range. Global signatures combine several generations.

Buffer edit events already provide edit positions. Verify their timing and coordinate semantics before reusing them.

The Markdown model publishes from a worker. During typing, most publications describe an older text revision than the buffer.

Previous gallery measurements reported approximately 84 ms median typing latency and 20–24 seconds from open to ready.
These are historical observations, not a reproducible baseline for this work.

Allocation, measurement, provider work, and suffix updates must be measured separately. Their relative costs are not yet established.

## Update contract

Design this contract once for wrapping, folds, inserted rows, heights, and render caches.
Do not create a separate provider contract after implementing text-edit updates.

### Position mapping

Position mapping describes how a text replacement moves existing lines.

Layout uses line granularity: `{first_line, old_last_line, new_last_line}`.
Range markers and folds keep their own column-level mapping. Do not add columns or revision pairs to the layout contract until a layout consumer needs them.

Use existing buffer events as the source. Normalize them at the layout boundary only when necessary.

Specify these rules before implementation:

- Whether each event occurs before or after the buffer changes.
- Whether ranges include or exclude their end positions.
- How insertions and deletions map boundary lines.
- How undo, redo, and multi-caret edits enter the same path.

Do not introduce a new public buffer API unless existing events cannot express these requirements.

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

### Milestone 3: Migrate remaining paths

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

### Milestone 4: Remove obsolete recovery paths

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
Merge structures only if separate ownership still causes demonstrated consistency problems.
Add marker indexing only if marker work becomes a measured bottleneck.
Add column-level or revision-pair mapping to the layout contract only when a layout consumer needs it.
Choose estimated heights only through the separate opening-performance decision.
