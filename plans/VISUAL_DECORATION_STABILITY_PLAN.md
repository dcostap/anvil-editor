# Visual Decoration Stability Plan

## Purpose

Reduce visual jank while editing code by keeping editor decorations and highlighting visually stable while asynchronous semantic systems catch up.

The motivating symptom is that after edits, Diagnostic Underlines, Line Hints, syntax highlighting, and semantic coloring can temporarily disappear, jump, or fall back until LSP/Tree-sitter/highlighter refresh work completes. Mature IDEs avoid this by tracking ranges through edits, reusing previous highlighters, and incrementally invalidating only the necessary region.

This plan focuses first on diagnostics because they are the newest and most visible jank source, then expands to syntax highlighting and semantic tokens.

## Current Anvil behavior

Relevant current Anvil files:

```text
data/core/doc/init.lua
data/core/doc/highlighter.lua
data/core/language_intelligence.lua
data/core/treesitter/init.lua
data/core/treesitter/highlight.lua
data/core/lsp/diagnostics.lua
data/core/lsp/diagnostic_hints.lua
data/core/lsp/diagnostic_underlines.lua
data/core/lsp/provider.lua
data/core/lsp/documents.lua
data/plugins/linewrapping.lua
```

### Document edits

`Doc:apply_edits(...)` in `data/core/doc/init.lua` builds a transaction with:

- normalized edits in old-document order
- inverse edits
- changed line ranges
- old/new selections
- byte offsets for edit start/end on each normalized edit

It then calls highlighter notification hooks and `Doc:on_text_transaction(transaction)`.

This transaction is the natural place to update tracked visual ranges. Use `transaction.edits` for byte-accurate marker mapping; `transaction.changed_ranges` is line-oriented and is mainly useful for cache/wrap invalidation. The offset/line-start helpers used by `Doc:apply_edits` are currently local to `doc/init.lua`, so a marker module will either need its own small conversion helpers or a deliberate exported Doc helper.

### Regex/tokenizer highlighting

`data/core/doc/highlighter.lua` currently stores tokenized lines and can tokenize incrementally while rendering. However, normal `Doc:insert`, `Doc:remove`, and batch edits now go through `Doc:apply_edits(...)`, and `Highlighter:batch_notify(changed_ranges)` currently clears broad render state and calls `soft_reset()` for batch edits. The older `insert_notify` / `remove_notify` paths still splice cached highlighter lines, but they are used by raw edit paths rather than the normal batch-aware editing path.

That means simple edits can force much more visual instability than necessary. IntelliJ's equivalent does not drop all token segments: it re-lexes from a restartable point and shifts unchanged token segments after the edit.

### Tree-sitter highlighting

`data/core/treesitter/init.lua` has an incremental parse path for single edits:

- `treesitter.on_text_transaction(...)`
- `edit_for_transaction(...)`
- `treesitter.schedule_parse(doc, edit)`

Tree-sitter can mark the previous tree as `stale_renderable`, which is good, but `schedule_parse()` clears Tree-sitter highlight caches and invalidates render caches. While the new parse is pending, highlighting may fall back or query stale state against edited text in unstable ways.

### LSP document versions and local dirty state

`data/core/lsp/documents.lua` uses full-document sync. A local edit does not immediately increment `state.lsp_version`; `documents.on_text_transaction(...)` marks the state `pending_full_sync` and records `pending_change_id`, then `documents.flush()` / `flush_before_request()` sends `textDocument/didChange` and increments `state.lsp_version`.

This timing matters for diagnostics: after a local edit but before the debounced flush, current diagnostic storage can still look version-current even though it no longer describes the current Document text. `documents.is_current(state, lsp_version, change_id)`, `state.pending_full_sync`, and `state.last_synced_change_id` provide the needed freshness metadata, but diagnostics currently do not use the current doc change id in their freshness check. The stored snapshots are metadata snapshots only; they do not currently retain old text or line-start tables, so they are useful for freshness decisions but not enough by themselves to convert old LSP ranges against a past Document state. Any "fresh/current" diagnostic concept introduced for visual markers or navigation should require the LSP version to match and the current `doc:get_change_id()` to equal the last synced change id, not only LSP version equality.

### LSP semantic tokens

`data/core/lsp/provider.lua` keys semantic token cache entries by LSP document version. Before the debounced LSP flush, the old semantic token entry still has the current `state.lsp_version`, so `provider.render_tokens(...)` can overlay old absolute token spans onto edited text. The per-line cache key includes the line text and is invalidated through `Highlighter:batch_notify(...)`, but the underlying semantic token list is still version-current until `documents.flush()` runs. After `documents.flush()` increments `state.lsp_version`, old semantic token cache entries are no longer used; `provider.render_tokens(...)` schedules `textDocument/semanticTokens/full` and falls back to the base renderer while pending. Both phases are visually unstable and should use local dirty/change-id state, not version alone.

### Diagnostic Line Hints and Diagnostic Underlines

`data/core/lsp/diagnostic_hints.lua` and `data/core/lsp/diagnostic_underlines.lua` derive their display from `diagnostics.current_document_items(doc)`.

That means:

- before the debounced LSP flush, diagnostics may still be treated as current and are lazily re-converted against the edited Document using old LSP ranges
- once `state.lsp_version` advances, versioned diagnostics become stale and disappear from these renderers
- the underline/hint caches are keyed by diagnostics generation, doc change id, and LSP sync version, so they are rebuilt after local edits but from the same stale raw LSP ranges
- ranges are recomputed from current diagnostic storage rather than being edit-tracked visual objects
- after an edit, decorations can stay at old coordinates, jump, or disappear before LSP republishes diagnostics

This was intentionally conservative for correctness, but it is not visually stable. It also means navigation currently follows `diagnostics.current_document_items(doc)`, whose freshness check is version-based and does not by itself model unsent local edits. Existing tests such as the underline/hint "drops cached ... when document sync makes diagnostics stale" cases describe the current behavior and should be changed when marker-backed stale visuals become the intended behavior.

## IntelliJ reference material

Local IntelliJ repository cache:

```text
C:\Users\Darius\AppData\Local\pi-web-smart-fetch\github-cache\JetBrains\intellij-community
```

### Incremental syntax highlighting

```text
platform/editor-ui-ex/src/com/intellij/openapi/editor/ex/util/LexerEditorHighlighter.java
```

Important method:

```text
LexerEditorHighlighter.incrementalUpdate(...)
```

Key behaviors:

- Finds a lexer restart point before the edit.
- Re-lexes forward from that point.
- Stops when newly produced token segments converge with old shifted token segments.
- Calls `mySegments.shiftSegments(oldEndIndex, shift)` for unchanged tokens after the edit.
- Replaces only the changed token segment window.

This is the closest reference for making Anvil's regex/tokenizer highlighting stable when inserting/deleting lines.

```text
platform/core-impl/src/com/intellij/openapi/editor/ex/util/SegmentArray.java
platform/core-impl/src/com/intellij/openapi/editor/ex/util/SegmentArrayWithData.java
```

Important method:

```text
SegmentArray.shiftSegments(int startIndex, int shift)
```

This physically shifts cached token ranges after edits instead of rebuilding everything.

### Range markers and visual highlighters

```text
platform/core-impl/src/com/intellij/openapi/editor/impl/RangeMarkerImpl.java
```

Important method:

```text
RangeMarkerImpl.applyChange(...)
```

Key behaviors:

- If edit is after range: range unchanged.
- If edit is before range: range shifts by length delta.
- If edit is inside range: range expands/collapses.
- If edit partially replaces a range: range is clipped/shifted.
- Supports greediness/stickiness rules for insertion at range boundaries.

```text
platform/core-impl/src/com/intellij/openapi/editor/impl/RangeMarkerTree.java
```

Important methods:

```text
RangeMarkerTree.documentChanged(...)
RangeMarkerTree.collectAffectedMarkersAndShiftSubtrees(...)
RangeMarkerTree.updateAffectedNodes(...)
```

The tree maintains many tracked ranges efficiently and shifts unaffected subtrees as a group.

```text
platform/editor-ui-ex/src/com/intellij/openapi/editor/impl/RangeHighlighterImpl.java
platform/editor-ui-ex/src/com/intellij/openapi/editor/impl/MarkupModelImpl.java
```

Important concept:

A visual highlighter is backed by a tracked range marker. Diagnostic underlines are not recomputed directly from stale analysis results on every paint; they are live objects that track document edits.

### Avoiding diagnostic underline blinking

```text
platform/analysis-impl/src/com/intellij/codeInsight/daemon/impl/UpdateHighlightersUtil.java
```

Important methods:

```text
setHighlightersInRange(...)
createOrReuseHighlighterFor(...)
updateHighlightersByTyping(...)
```

Key behaviors:

- Existing highlighters in a refreshed range are recycled before removal.
- New matching highlighters can reuse recycled highlighters rather than destroying and recreating them.
- `updateHighlightersByTyping(...)` detects edits inside existing highlighter ranges and disables whitespace-only optimization when needed.

```text
platform/analysis-impl/src/com/intellij/codeInsight/daemon/impl/BackgroundUpdateHighlightersUtil.java
```

Important details:

- Background-thread version of highlighter updates.
- `createOrReuseHighlighterFor(...)` calls `recycler.pickupHighlighterFromGarbageBin(...)` before creating a new highlighter.
- For `HighlightInfoType.WRONG_REF`, it sets:

```text
highlighter.setGreedyToRight(true)
highlighter.setGreedyToLeft(true)
```

Commented rationale: typing immediately before/after an unresolved identifier should keep it visually red.

```text
platform/analysis-impl/src/com/intellij/codeInsight/daemon/impl/HighlighterRecycler.java
platform/analysis-impl/src/com/intellij/codeInsight/daemon/impl/ManagedHighlighterRecycler.java
```

Important concept:

Highlighters scheduled for removal are put in a temporary recycler/garbage bin. If the next analysis pass produces a matching highlighter, it is picked up and reused. This avoids flicker.

```text
platform/analysis-impl/src/com/intellij/codeInsight/daemon/impl/HighlightInfoUpdaterImpl.java
```

Useful comments and methods:

```text
recycleInvalidPsiElements(...)
assignRangeHighlighters(...)
```

Relevant comment: invalid PSI highlighters are recycled temporarily because PSI may be recreated in the same place later, avoiding annoying blinking.

### Dirty scopes

```text
platform/lang-impl/src/com/intellij/codeInsight/daemon/impl/DaemonListeners.java
platform/lang-impl/src/com/intellij/codeInsight/daemon/impl/PsiChangeHandler.java
platform/analysis-impl/src/com/intellij/codeInsight/daemon/impl/FileStatusMap.java
platform/analysis-impl/src/com/intellij/codeInsight/daemon/impl/FileStatus.java
```

Important concept:

Dirty analysis scopes are tracked as `RangeMarker`s too. The pending region that needs reanalysis moves through edits instead of turning the whole file visually unstable.

### Robust line/range restoration

```text
platform/core-impl/src/com/intellij/openapi/editor/impl/PersistentRangeMarker.java
platform/core-impl/src/com/intellij/openapi/editor/impl/event/DocumentEventImpl.java
```

Important methods:

```text
DocumentEventImpl.translateLineViaDiff(...)
DocumentEventImpl.translateLineViaDiffStrict(...)
```

These are more advanced fallback mechanisms for retaining range identity across larger replacements/whole-file changes.

## Design principles for Anvil

1. **Separate visual stability from semantic truth.**
   Navigation and commands should use current authoritative diagnostics. Visual decorations may be stale-but-tracked for a short period to avoid flicker.

2. **Track ranges through edits.**
   Diagnostics, semantic token spans, and future decorations should be range objects updated by `Doc:on_text_transaction`, not raw LSP ranges re-read every paint.

3. **Prefer shifting/reusing over clearing/rebuilding.**
   For syntax tokens and decorations, shift unaffected content when possible.

4. **Make stale state explicit.**
   A decoration can be `fresh`, `stale-tracked`, `pending-refresh`, or `invalid`. Rendering can choose to show stale-tracked decorations, while commands ignore them. For LSP-backed data, `fresh` should mean authoritative for the current document content: the server version matches and the document's current change id is the synced/received change id. It should not merely mean equal to the last flushed LSP version.

5. **Support boundary affinity.**
   Insertion at diagnostic boundaries needs greediness/stickiness rules. Error markers around an unresolved identifier probably want greedy left/right behavior like IntelliJ's `WRONG_REF`.

6. **Be conservative on destructive edits.**
   Large replacements, multi-cursor edits, or edits that consume most of a diagnostic can invalidate markers rather than guessing wildly.

7. **Measure and log quietly.**
   Use `core.log_quiet(...)` for marker remap decisions, invalidations, large-edit fallbacks, and recycling outcomes.

## Proposed architecture

### Milestone 1: Generic tracked range markers

Add a first-party module, likely:

```text
data/core/range_marker.lua
```

Core API sketch:

```lua
local marker = range_marker.new(doc, {
  line1 = 10,
  col1 = 5,
  line2 = 10,
  col2 = 12,
  greedy_left = false,
  greedy_right = false,
  sticky_right = false,
  kind = "diagnostic",
  data = {...},
})

marker:is_valid()
marker:range()
marker:update_for_transaction(transaction)
marker:invalidate(reason)
```

Document-level storage sketch:

```lua
range_marker.markers_for_doc(doc)
range_marker.add(doc, opts)
range_marker.remove(marker)
range_marker.update_doc(doc, transaction)
```

Implementation choices:

- Start with a simple per-doc list, not an interval tree.
- Use byte offsets internally if practical, because `Doc:apply_edits` already computes old-document edit start/end offsets on `transaction.edits`.
- Apply multi-edit transactions in normalized old-document order while accumulating byte deltas; do not try to derive byte mapping from `changed_ranges`.
- Store or compute new-document offsets by applying that accumulated delta; `transaction.edits` does not currently store `new_start_offset` / `new_end_offset` fields.
- Keep line/col cached for rendering or compute lazily from offsets.
- Prefer adding a small exported Doc offset helper if marker code would otherwise duplicate too much of `doc/init.lua`'s local offset conversion logic.
- Add a marker generation counter and invalidate marker-backed renderer caches when markers move, become stale, or are reconciled.
- Prefer adding a small first-party Document transaction listener registry, then registering marker updates through that registry. Existing LSP documents, Tree-sitter, and Line Wrapping currently use composable `Doc:on_text_transaction(...)` monkey patches, but adding another independent monkey patch would make load-order behavior more fragile. If a registry is too large for the first pass, install the marker hook in the same composable style and keep it mandatory/early-loaded.
- Add an interval tree only if profiling proves list updates too slow.
- Do not introduce a broad decorations framework in this milestone; prove the marker semantics with diagnostics first.

Range update rules based on IntelliJ's `RangeMarkerImpl.applyChange(...)`:

- Edit after marker: unchanged.
- Edit before marker: shift by byte delta.
- Insertion exactly at start/end: use greediness/stickiness.
- Edit fully inside marker: expand/collapse marker by delta.
- Edit overlaps marker prefix/suffix: clip to remaining content.
- Edit consumes marker entirely: invalidate, unless zero-width fallback is configured.

Test cases:

- insertion before range shifts range
- deletion before range shifts range back
- insertion inside range expands greedy range
- insertion at start/end respects greediness
- deletion overlapping range clips or invalidates
- multi-line range survives line insert/delete
- batch/multi-cursor edits apply in order

### Milestone 2: Diagnostic visual markers

Add or refactor into a diagnostics decoration layer, likely replacing most draw-time range derivation in:

```text
data/core/lsp/diagnostic_hints.lua
data/core/lsp/diagnostic_underlines.lua
```

Possible new module:

```text
data/core/lsp/diagnostic_markers.lua
```

Responsibilities:

- On `textDocument/publishDiagnostics`, first classify the publish against the current Document state. A publish is authoritative for visual replacement only when it describes the current Document text: versioned diagnostics must match `state.lsp_version` and `doc:get_change_id()` must equal `state.last_synced_change_id`; unversioned diagnostics for an open Document should be received while the Document is not locally dirty relative to the last sync.
- Keep markers grouped by doc URI/server/version.
- Attach severity/message/source/code data to each marker, plus the client's position encoding used to convert the original LSP range.
- Store enough freshness metadata to distinguish current-Document diagnostics from stale visuals. For versioned diagnostics, compare the diagnostic version with the document state and require `doc:get_change_id()` to equal the state's last synced change id; `documents.snapshot_for_version(...)` is useful for identifying old-version publishes but does not provide old text mapping today. For unversioned diagnostics, record the doc change id at receipt and mark stale after the next local edit.
- On local edit, markers update immediately through `range_marker` and become `stale-tracked` for that document/server snapshot, including edits before the debounced `documents.flush(...)`.
- On LSP document version advance, keep existing markers as `stale-tracked` instead of hiding them immediately.
- On an authoritative current-version publish, or an authoritative unversioned publish received while the Document is still at the synced change id, reconcile new diagnostics against old tracked markers.
- On any publish that is stale relative to the current Document, including the important "same LSP version but local edits are pending" case before the debounced flush, update raw diagnostic storage as needed, but do not remove or replace newer visual markers and do not create new markers by converting old LSP ranges against the edited Document. If no existing marker can be tracked forward, prefer no stale visual over a confidently wrong coordinate.
- On an authoritative current-version or authoritative unversioned empty diagnostics publish, remove markers for that URI/server.

Rendering:

- Diagnostic Underlines draw from diagnostic markers, including stale-tracked markers.
- Line Hints draw from diagnostic markers, choosing highest severity per visual line.
- Navigation commands should use a fresh/current diagnostic view that accounts for local dirty state. Prefer enhancing `diagnostics.current_document_items(doc)` / `diagnostics.current_for_doc(doc)` so they exclude diagnostics whose synced change id is older than `doc:get_change_id()`, because those helpers already back navigation and summary behavior. Marker-backed renderers can then intentionally opt into `stale-tracked` visuals.

Reconciliation strategy:

- Match by server id + severity + message + source/code + approximate range.
- If matched, update marker data/range without flicker.
- If unmatched but old marker is stale, keep it until an authoritative publish for that URI/server says otherwise.
- If an authoritative current-version or authoritative unversioned publish for the same URI/server arrives, remove stale markers not matched. LSP `publishDiagnostics` is full replacement per URI, but stale publishes must not clear visual markers for the newer Document state.

Tests:

- add runtime marker/freshness tests near `tests/lua/runtime/lsp_diagnostics.lua`
- update the existing stale-version underline/hint tests in `tests/lua/ui/lsp_diagnostic_underlines.lua` and `tests/lua/ui/lsp_diagnostic_hints.lua`; they currently assert disappearance after sync staleness, but the new intended visual behavior is stale-tracked rendering
- add underline/hint rendering tests near `tests/lua/ui/lsp_diagnostic_underlines.lua` and `tests/lua/ui/lsp_diagnostic_hints.lua`
- underline remains visible and shifts when editing before diagnostic before LSP republishes, including before the debounced `documents.flush(...)`
- hint remains visible and shifts line when inserting lines before diagnostic
- local edit marks old diagnostics stale for navigation even if `state.lsp_version` has not advanced yet
- authoritative current-version or authoritative unversioned empty publish removes marker
- stale marker is not used for diagnostic navigation
- publish replacing diagnostics reuses/updates markers without duplicate rendering
- same-version publish received while local edits are pending does not create fresh visual markers from old LSP ranges
- zero-width diagnostics stay visible
- wrapped underlines continue splitting by visual rows after shifts

### Milestone 3: Incremental tokenizer cache stability

Refactor `data/core/doc/highlighter.lua`.

Current issue:

```lua
function Highlighter:batch_notify(changed_ranges)
  self:invalidate_render_cache()
  ...
  self:soft_reset()
  self:invalidate(first_line)
end
```

Target behavior inspired by IntelliJ's `LexerEditorHighlighter.incrementalUpdate(...)`:

- For simple edits, splice `self.lines` according to line deltas instead of `soft_reset()`.
- Retain cached token lines below the edit where possible.
- Retokenize from the edit start line.
- Stop when token state and line text converge with an existing cached line.
- Notify only changed line range.

Practical Anvil version:

1. For single edit:
   - determine old changed line window and new changed line window
   - splice `self.lines` for inserted/deleted lines
   - mark from `new_line1` invalid
2. Background highlighter retokenizes forward.
3. Preserve enough cached lines below the edit for the existing `Highlighter:start()` convergence logic to stop early when a cached line's `init_state` and `text` still match the newly tokenized previous state.
4. Avoid clearing render caches for the entire file; invalidate only the affected line range, plus any lines retokenized before convergence.

Risks:

- Existing tokenizer state objects must be comparable or stable enough to test convergence.
- Some syntax modes may have long-lived states, requiring re-tokenizing far forward.
- Multi-edit transactions may still need conservative fallback.

Tests:

- inserting newline above a cached highlighted line preserves cached line tokens below after shift
- editing one line does not reset tokens before that line
- multiline comment/string edits retokenize until state convergence
- batch edits fall back safely

### Milestone 4: Tree-sitter stale render stability

Current Tree-sitter state already distinguishes:

```text
ready
stale_renderable
stale_unrenderable
```

Improvements:

- Do not clear all `ts.highlight_cache` immediately on `schedule_parse()` if previous tree is stale-renderable.
- Fix the cache key policy if stale caches are retained: `highlight.line_tokens(...)` currently keys by `tree_generation`, `ts.generation`, line index, and line text, while `schedule_parse()` increments `ts.generation` before the new tree is ready. Retained stale cache entries need a separate stale-cache key/remap path or they still will not be reused.
- Add stale cache remapping for simple line insert/delete.
- Query old/stale tree only where offset mapping remains plausible.
- Fall back line-by-line rather than whole-file.

Potential strategy:

- For single edit with incremental tree edit available, keep old highlight cache for unaffected lines shifted by line delta.
- Invalidate only edited line window and perhaps a small context band.
- When parse completes, replace with fresh Tree-sitter highlighting and clear stale cache.

Risks:

- Querying captures from a stale tree against changed text can produce misleading boundaries.
- Needs careful offset mapping and clipping.

### Milestone 5: LSP semantic token remapping

Current LSP semantic tokens in `data/core/lsp/provider.lua` are version-keyed. Once document version advances, they are not used.

Target behavior:

- Treat semantic token freshness as `(server version, doc change id)`, not version alone, so local edits before the debounced flush do not apply old absolute spans as if they were fresh.
- Keep previous semantic token spans as stale-tracked spans.
- Map spans through edits like range markers.
- Render stale/remapped semantic overlays until fresh semantic tokens arrive, both before the flush and after the LSP version increments.
- Mark stale semantic tokens separately so they can be discarded on large/ambiguous edits.

This should reuse the generic range marker/span mapping infrastructure from diagnostics.

Risks:

- Semantic tokens are numerous.
- Per-token range markers may be too heavy.
- Need a packed span list with batch offset shifting rather than one Lua object per token for large files.

Suggested approach:

- Start with diagnostics marker infrastructure.
- For semantic tokens, implement a specialized span array with the same edit-mapping algorithm.
- Store the doc change id associated with each semantic token result and invalidate/remap when `doc:get_change_id()` advances.
- Drop stale semantic spans on large edits or too many spans.

## Recommended implementation order

1. **Tracked range marker module**
   - No UI changes yet.
   - Full unit tests.

2. **Diagnostic markers backed by tracked ranges**
   - Underlines and Line Hints render from markers.
   - Navigation remains authoritative/fresh-only.

3. **Diagnostic marker reconciliation/recycling**
   - Avoid flicker on publish replacement.
   - Add quiet logs.

4. **Highlighter batch_notify incremental line shifting**
   - Improve base syntax stability.

5. **Tree-sitter stale cache policy**
   - Preserve stale renderable highlights more carefully.

6. **Semantic token stale remapping**
   - Only after marker/range infrastructure proves itself.

## Non-goals for the first milestone

- No interval tree initially.
- No perfect diff-based remapping for whole-file replacements.
- No semantic token remapping in the first marker pass.
- No changes to LSP server timing or debounce as the primary fix.
- No use of stale diagnostics for commands/navigation.

## Open design questions

1. How long should stale-tracked diagnostic visuals remain after a local edit or version advance if no fresh publish arrives?
   - Recommended default: until the next authoritative publish for that URI/server, or until a direct/destructive overlap invalidates the marker. Add a fixed timeout later only if stale visuals linger in real workflows.

2. Should stale-tracked diagnostics render differently?
   - Same color for stability, or slightly dimmed to indicate uncertainty?

3. How greedy should diagnostic ranges be?
   - IntelliJ makes unresolved-reference highlighters greedy both ways.
   - Anvil could use severity/type-specific policy later.

4. Should Line Hints show stale-tracked diagnostics?
   - Underlines probably should for stability.
   - Hints may be more semantically assertive, but hiding them causes visible layout/hint jank.

5. Should diagnostic marker reconciliation match by message only, range only, or both?
   - A pragmatic key is server id + source + code + severity + message, then closest range.

## Success criteria

- Inserting newlines above an LSP diagnostic shifts its Diagnostic Underline and Line Hint down immediately without disappearing, including during the debounce window before `didChange` is flushed.
- Editing before an unresolved identifier keeps the underline visually attached until LSP republishes.
- Current-version or unversioned empty diagnostics publish removes old decorations.
- Stale visual diagnostics are not used by next/previous diagnostic navigation, including after local edits before LSP version advance.
- Inserting lines above syntax-highlighted code does not cause the entire lower file to temporarily fall back or flash.
- Local edits before an LSP flush do not render old semantic token spans or diagnostics as if they were fresh for the edited text.
- Wrapped lines keep stable underline/hint placement after edits.
