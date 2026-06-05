# Lua Batch Edit Plan

## Goal

Make multi-caret editing fast, deterministic, and Selection Owner correct by replacing per-caret text mutation loops with one shared Lua batch edit transaction primitive.

Target user-facing behavior: typing, deleting, pasting, line commands, and common transforms remain responsive with hundreds or thousands of carets, while undo/redo, Document View Selection State, syntax highlighting, wrapping, autosave, and plugin notifications continue to behave as one coherent edit.

## Non-Goals

- Do not change command names, keybindings, or public single-edit APIs.
- Do not encode shortcut choices in tests.
- Do not preserve first-party internal monkey-patch patterns when a clean transaction hook exists; migrate in-repo callers/plugins to the new surface.
- Do not implement native/C acceleration before the Lua transaction path is correct and measured.
- Do not make timing-threshold tests brittle; use structural assertions and local benchmark logs.

## Current Code Reality

Important constraints verified in the code:

- `data/core/command.lua` wraps command predicates and command bodies in `DocView:with_selection_state` when a Document View is active or passed as an argument. Most editor commands therefore mutate `doc.selections` while it is temporarily bound to the active Document View's Selection State.
- `data/core/doc/init.lua` has the current hot path:
  - `Doc:raw_insert` / `Doc:raw_remove` mutate `doc.lines`, update active selections, push undo entries, notify the highlighter/cache, and adjust inactive registered Document View Selection States.
  - `Doc:insert` / `Doc:remove` wrap the raw calls, clear redo, update clean ids partially, and call `on_text_change`.
  - `Doc:text_input`, `Doc:ime_text_editing`, `Doc:delete_to_cursor`, `Doc:replace`, `Doc:indent_text`, and many commands loop selections and repeatedly call `insert`/`remove`.
  - `Doc:remove` does not currently mirror `Doc:insert`'s clean-id guard when editing after undo; centralizing mutation should fix and test this rather than preserve the inconsistency.
- Selection State is view-owned:
  - `DocView:with_selection_state` temporarily exposes a Document View's Selection State through the Document Selection Mirror (`doc.selections` / `doc.last_selection`).
  - Inactive registered Document Views are currently adjusted through `DocView.adjust_registered_selection_states(doc, kind, active_view, ...)` and `Doc:adjust_selection_state_for_insert/remove`.
  - Selection undo uses `selection_owner_id`; if the owner does not match the current Selection Owner, current code avoids restoring the wrong active selections.
- Undo currently stores many small vararg entries (`selection`, `insert`, `remove`) and relies on timestamp merging. This is costly, uses large `table.unpack` snapshots, and can restore intermediate multi-caret selections incorrectly.
- First-party plugins hook mutation internals:
  - `edit_location_history.lua` wraps `Doc:insert` / `Doc:remove`.
  - `intellij_actions.lua` wraps `Doc:set_selection`, `Doc:set_selections`, `Doc:insert`, and `Doc:remove`, and has a paste undo patch for multi-cursor paste.
  - `linewrapping.lua` wraps `Doc:raw_insert` / `Doc:raw_remove`.
  - `intellij_find.lua` patches a local input doc's `raw_insert` / `raw_remove` to refresh the find UI.
  - `diffview.lua` wraps per-instance `raw_insert` / `raw_remove` to update the diff.
  - `autosave_fast.lua` and `gitdiff_highlight/init.lua` hook `Doc:on_text_change`.
- Some `Doc` subclasses/instances constrain mutation:
  - Global prompt `SingleLineDoc` strips `\r`/`\n` in `insert`.
  - Local find `SingleLineDoc` strips `\r`/`\n` in `insert` and uses a custom highlighter.
  - `CommandOutputDoc` rejects normal user edits and only allows internal mutation under `__command_output_mutating`.
  - `global_prompt_bar_sanitize.lua` additionally patches prompt doc input to remove `\r`.
- Hot edit loops exist outside core commands too:
  - `sequential_numbers.lua`, `trimwhitespace.lua`, local find replace-all, search/replace, diff apply/copy actions, `intellij_actions.lua` duplicate/comment helpers, and transform plugins eventually route through repeated `insert`/`remove`/`replace_cursor` calls.

The batch primitive must account for these realities; it is not enough to replace one loop with a faster loop.

## Design Invariants

- Document positions remain Anvil's existing 1-based byte columns, not UTF-8 character indices.
- `doc.lines` keeps the existing invariant: at least one string, and normal text lines include their trailing `\n` in the line string.
- Batch edits are simultaneous: every public edit range is expressed in coordinates of the original document before the transaction.
- A transaction is atomic: validation, authorization, normalization, inverse construction, and overlap checks finish before `doc.lines`, selections, undo stacks, highlighter state, caches, or plugin-visible state are mutated.
- Forward edits use original-document coordinates. Inverse edits use post-edit-document coordinates. This must be explicit because undo applies inverse edits as another simultaneous batch.
- Active command builders should compute exact final selections from their command semantics. The default mapper exists for inactive Selection States, undo fallback, and simple callers; it is not the primary caret-placement API for complex commands.
- Public API compatibility is preserved for `Doc:insert`, `Doc:remove`, `Doc:text_input`, `Doc:delete_to_cursor`, `Doc:replace`, `Doc:indent_text`, and command names, even though their internals change.

## Canonical Primitive

Introduce one public document mutation primitive:

```lua
local transaction = doc:apply_edits(edits, opts)
```

Each edit is a replacement of an original-document half-open range `[line1,col1) -> [line2,col2)`:

```lua
{
  line1 = line1,
  col1  = col1,
  line2 = line2,
  col2  = col2,
  text  = replacement_text,

  -- Optional final active Selection State entry in post-edit coordinates.
  -- If omitted, the caller must provide opts.selections or accept default mapping.
  selection = { line1, col1, line2, col2 },

  -- Optional original selection index for rebuilding final selections in caller order.
  idx = selection_index,

  -- Optional mapper affinity for generated/default selection mapping only.
  -- Explicit opts.selections should be preferred on hot command paths.
  affinity = "before" | "after",
}
```

`opts` should include:

```lua
{
  type = "insert" | "remove" | "replace" | "text-input" | "batch" | "undo" | "redo",
  selections = flat_final_selection_array,   -- preferred for hot paths
  last_selection = final_last_selection,
  merge_cursors = true,                      -- merge duplicate collapsed carets once
  record_undo = true,
  undo_stack = nil,                          -- internal: target stack for inverse command; defaults to self.undo_stack when record_undo
  clear_redo = true,                         -- false for undo/redo stack transfers
  notify = true,                             -- public on_text_change; internal transaction hooks still run
  owner_id = current_selection_owner_id,
  time = system.get_time(),
  strict = false,                            -- if true, rejected transactions error after logging
  allow_selection_only = false,
}
```

Return a transaction summary for hooks/tests:

```lua
{
  applied = true,
  changed = true,                    -- text changed
  selection_changed = true,
  rejected = false,
  reason = nil,

  type = opts.type,
  edits = normalized_forward_edits,   -- original-document coordinates
  inverse_edits = normalized_inverse_edits, -- post-edit-document coordinates
  changed_ranges = coalesced_line_ranges,

  old_selections = flat_old_selection_array,
  new_selections = flat_new_selection_array,
  old_last_selection = old_last_selection,
  new_last_selection = new_last_selection,
  selection_owner_id = owner_id,
}
```

For rejected or unauthorized transactions, return a transaction with `applied = false`, `changed = false`, `rejected = true`, and `reason`; leave all document, selection, undo, cache, and notification state unchanged. `opts.strict` may turn that into an error for tests or internal programming mistakes.

Public table-of-record edits are acceptable at the API boundary. Internally, normalize to flat arrays/records and avoid `table.unpack` in large hot paths.

## Normalization and Validation

Before mutating anything:

1. Snapshot `old_lines = self.lines`, active selections, `last_selection`, and Selection Owner once.
2. Sanitize ranges against `old_lines`, not against a partially edited document.
3. Sort positions within each range while preserving caller intent for final selection fields.
4. Normalize replacement text through document-specific hooks once per edit.
5. Split replacement text with the same semantics as current `split_lines(text)` so multiline insertion and empty-string deletion preserve line-table behavior.
6. Compute original removed text once per edit for inverse construction.
7. Drop no-op text edits after normalization unless `allow_selection_only` is set.
8. Sort normalized edits top-to-bottom by original start position.
9. Reject overlapping edits atomically.
   - Adjacent half-open ranges are allowed.
   - Duplicate zero-width inserts at the same position are ambiguous by default; command builders should pre-merge duplicate carets or explicitly opt into a deterministic policy.
10. Coalesce changed line ranges after validation, not by repeatedly notifying single edits.

Overlap checks should compare positions using original coordinates. If implementation needs absolute offsets for simpler comparison, compute line-start offsets from `old_lines` once; do not concatenate the entire document for normal editing.

## Transaction Semantics

`Doc:apply_edits` responsibilities:

1. Capture active Selection State and Selection Owner once.
2. Authorize the full transaction before any mutation.
3. Normalize text and ranges through document-specific hooks.
4. Validate sorting, no-op handling, duplicate insert policy, and overlap rejection.
5. Build inverse edits from original text, with inverse ranges expressed in post-edit coordinates.
6. Build the new `doc.lines` table in one pass from the old table and all replacements.
   - Do not call `common.splice` once per edit.
   - Do not call `raw_insert` / `raw_remove` once per edit from multi-caret paths.
7. Compute/install final active selections once.
8. Transform inactive registered Document View Selection States through the same batch position mapper.
9. Sanitize final selections and merge duplicate collapsed cursors once at the end when requested.
10. Update Selection Mirror ownership/state correctly after replacing `doc.selections`.
11. Push one undo transaction table when undo recording is enabled.
12. Clear redo and update `clean_change_id` exactly once for a new user transaction.
13. Update highlighter/cache/binary clean-lines/wrapping using coalesced changed ranges.
14. Run internal transaction hooks once per applied transaction.
15. Call `on_text_change(type, transaction)` once when public notification is enabled.
16. Emit quiet diagnostics for large batches, rejected overlaps, unauthorized edits, fallback paths, and slow transactions.

## One-Pass Line Rewrite Notes

The rewrite should be correctness-first and allocation-conscious:

- Work from immutable `old_lines` and normalized edits.
- Maintain an output line list and a current output line buffer/string.
- Copy untouched spans from `old_lines` into the output without per-edit splicing.
- For each replacement, append the untouched prefix before the edit, append replacement split lines, then continue from the untouched suffix after the edit.
- Preserve the invariant that the document has at least one line; an empty result becomes `{ "\n" }` if that matches current `raw_remove` behavior for full deletion.
- Assign `self.lines = new_lines` only after the complete output is built.
- Rebuild or realign auxiliary line-indexed state after `self.lines` is assigned.

Avoid optimizing this with native code until the Lua path is tested and measured.

## Position Mapping Rules

Use one explicit batch position mapper for inactive Document Views, undo selection restoration fallback, and default final selections.

For a position in the original document:

- Before an edit: apply only cumulative deltas from earlier edits.
- Exactly at a zero-width insertion point: keep before-affinity by default, matching current `raw_insert` behavior where positions at the insert column are not moved.
- Exactly at a deletion/replacement start: keep the start position.
- Inside a replaced/deleted range: collapse to the replacement start by default.
- Exactly at a deletion/replacement end: collapse to the replacement start by default, matching current `adjust_selection_state_for_remove` behavior.
- After a replaced range: shift by the edit's cumulative line/column delta.

Support an explicit after-affinity mapper for command builders or tests that need "stick after inserted text" behavior, but do not make hot active commands depend on mapper side effects. They should provide `opts.selections` or per-edit `selection` fields.

The mapper must fill flat selection arrays directly. Avoid repeatedly calling `Doc:set_selections`, `Doc:sanitize_selection`, `Doc:merge_cursors`, or `common.splice` while transforming thousands of selections.

## Selection Owner Rules

Selection correctness is as important as text correctness.

- `apply_edits` captures `owner_id` from the current bound Document View when inside `DocView:with_selection_state`; otherwise it uses the current Document Selection Mirror owner.
- When replacing `doc.selections`, keep `doc.last_selection` in range and let the active bound Document View capture the new table when `with_selection_state` exits.
- When not inside a bound selection state, synchronize the Document Selection Mirror owner after the transaction, equivalent to current `sync_unbound_selection_mutation` behavior.
- Add a batch version of registered Selection State adjustment, e.g. `DocView.adjust_registered_selection_states_for_batch(doc, active_view, mapper, transaction)`, so inactive Document Views are transformed once.
- Undo/redo selection restoration should target the stored Selection Owner:
  - If the current active owner matches, restore the active `doc.selections` / `doc.last_selection`.
  - Else if the owner view is still registered, restore that view's inactive Selection State without overwriting the current active view.
  - Else fall back to current behavior: restore only when there is no ambiguous multi-view owner.
- Never restore a stored Selection State into a different active Document View just because it shares the same Document.

## Undo / Redo Design

Add a batch undo command type while keeping legacy undo entries readable during the transition:

```lua
{
  type = "batch",
  time = time,
  change_type = transaction.type,
  selection_owner_id = owner_id,
  before_selections = flat_array,
  before_last_selection = n,
  after_selections = flat_array,
  after_last_selection = n,
  edits = inverse_edits,        -- coordinates in the document this command will be applied to
}
```

Undo/redo flow:

1. Popping a batch applies `cmd.edits` with `type = "undo"` or `"redo"`, `clear_redo = false`, and public `notify = false` while the merge group is being processed.
2. During that apply, push exactly one swapped batch command to the opposite stack, or have `pop_undo` construct/push it explicitly from the returned transaction. Do not rely on legacy `raw_insert`/`raw_remove` to populate redo.
3. For a timestamp-merged undo group, apply all grouped batch commands and call `on_text_change("undo", grouped_transaction)` once at the end, matching current public notification granularity.
4. Restore `before_selections` / `after_selections` through the Selection Owner rules above.
5. Keep timestamp merge behavior so consecutive typing transactions still undo together.
6. Preserve `Doc:get_change_id()` semantics by advancing `undo_stack.idx` once per user transaction, not once per caret.
7. Update `clean_change_id` exactly when a new edit is pushed before the clean point. Include tests for insert and remove after undo.
8. Continue reading legacy `selection`, `insert`, and `remove` entries until they can no longer exist in live stacks.

This should remove the need for `intellij_actions.lua`'s multi-cursor paste undo patch.

## Notification / Hook Surface

Do not depend on first-party plugins wrapping `insert`, `remove`, `raw_insert`, or `raw_remove` for batch-aware behavior.

Add/use transaction-level hooks:

- `Doc:on_text_change(change_type, transaction)` remains the public notification and is called once per public text-change transaction.
- Add an internal `Doc:on_text_transaction(transaction)` or equivalent helper if hook ordering must be separated from legacy `on_text_change`.
- Internal transaction hooks should run for undo/redo subtransactions even when public `on_text_change` is deferred until the merged undo group finishes.
- Every in-repo `Doc:on_text_change` wrapper must accept and forward `transaction`/`...`; otherwise earlier wrappers in the chain will drop transaction details.
- Add highlighter/cache/wrapping batch notification helpers rather than requiring plugins to observe raw single edits.

Migrate first-party plugins:

- `edit_location_history.lua`: record successful user edit transactions from `on_text_change` or a transaction hook; ignore undo/redo if that matches current behavior.
- `intellij_actions.lua`: clear selection origin from a transaction hook; remove paste undo patch after paste uses one batch undo transaction.
- `linewrapping.lua`: replace raw insert/remove wrapping with a batch changed-range hook. Correctness-first option: rebuild wrapping from the first changed line for multi-range batches before attempting precise per-range splice updates.
- `intellij_find.lua`: make local input view observe `on_text_change` or the transaction hook instead of patching raw methods.
- `diffview.lua`: replace per-instance raw insert/remove wrappers with transaction observation that refreshes the parent diff once per transaction.
- `autosave_fast.lua` and `gitdiff_highlight/init.lua`: keep `on_text_change`, accept/forward the transaction argument, and optionally consume transaction details.

## Document-Specific Mutation Hooks

Because some docs currently enforce rules by overriding `insert`, the batch path needs an explicit normalization/authorization layer.

Add overridable helpers such as:

```lua
function Doc:normalize_edit_text(text, edit, opts) return text end
function Doc:can_apply_edits(edits, opts) return true end
```

Then update:

- Global prompt `SingleLineDoc`: strip `\r`/`\n` through `normalize_edit_text`.
- Local find `SingleLineDoc`: strip `\r`/`\n` through `normalize_edit_text` and keep custom highlighter behavior.
- `CommandOutputDoc`: reject `apply_edits` unless `__command_output_mutating` is set; keep normal user edits silent/no-op as they are today.
- `global_prompt_bar_sanitize.lua`: remove or redirect prompt-doc method patching to the normalization hook and option sanitization.

`Doc:insert`, `Doc:remove`, `Doc:text_input`, and migrated commands should all route through this same authorization/normalization path.

## Highlighter, Cache, Binary Lines, and Wrapping

Add coalesced line-change support.

For each normalized edit, compute a range using original and new coordinates:

```lua
{
  old_line1 = line1,
  old_line2 = line2,
  new_line1 = mapped_start_line,
  new_line2 = mapped_start_line + replacement_line_count - 1,
  old_line_count = line2 - line1 + 1,
  new_line_count = replacement_line_count,
  line_delta = replacement_line_count - (line2 - line1 + 1),
}
```

Then coalesce adjacent/overlapping changed ranges where that preserves correct old/new mapping.

Update strategy:

- Add `Highlighter:batch_notify(changed_ranges)`.
  - Correctness-first implementation may invalidate from the first changed line and realign `self.lines` enough that unchanged suffixes remain usable.
  - Preserve tokenized entries for unaffected ranges only where cheap and clearly correct.
- Clear document caches by changed ranges; if many ranges, multiline replacements, or binary mode make precision expensive, clear from the first changed line or reset affected cache tables.
- For binary docs, rebuild `clean_lines` from the first changed line to EOF unless a precise batch update is implemented.
- Make line wrapping consume the same changed ranges. For initial safety, reconstruct wrapped breaks from the earliest changed line when there is more than one range or when a range is complex.
- Keep `Highlighter:insert_notify` / `remove_notify` available for legacy paths during migration, but do not use them in hot batch paths.

## Migration Targets

### Core `Doc` methods

Migrate first after infrastructure and hook migration are in place:

- `Doc:insert`
- `Doc:remove`
- `Doc:text_input`
- `Doc:ime_text_editing`
- `Doc:delete_to_cursor` / `Doc:delete_to`
- `Doc:replace_cursor` / `Doc:replace`
- `Doc:indent_text`

Keep method names and external signatures stable.

### Core commands

Migrate high-impact commands next:

- `doc:paste`
- `doc:newline`, `doc:newline-above`, `doc:newline-below`
- `doc:delete`, `doc:backspace`
- generated `doc:delete-to-*`
- `doc:join-lines`
- `doc:indent`, `doc:unindent`
- `doc:duplicate-lines`, `doc:delete-lines`
- `doc:move-lines-up`, `doc:move-lines-down`
- `doc:toggle-line-comments`, `doc:toggle-block-comments`
- `doc:upper-case`, `doc:lower-case`
- cut/delete half of `doc:cut`

### First-party plugins

Audit and migrate in-repo callers that loop edits:

- `sequential_numbers.lua`
- `trimwhitespace.lua`
- `intellij_actions.lua` duplicate/comment/paste-related actions
- `intellij_find.lua` replacement paths
- `search_ui.lua` and core find/replace replacement paths where they loop replacements
- `diffview.lua` apply/copy actions and raw mutation wrappers
- `quote.lua`, `reflow.lua`, `tabularize.lua` through `Doc:replace`
- `autocomplete.lua` completion replacement if it remains a hot multi-edit path
- any remaining `rg "get_selections.*(insert|remove|text_input|delete_to_cursor|replace_cursor)"` matches

## Command Builder Notes

All command builders should snapshot selections and needed original text before calling `apply_edits`. Do not iterate live selections while mutating.

- **Typing/text input**: build one replacement per original selection. Selected ranges are replaced; collapsed carets insert. Overwrite mode changes the range to the next character for single-character input. Final carets go after inserted text, matching current `move_to_cursor(sidx, #text)` behavior.
- **IME composition**: preserve current behavior first: inserted text creates a composition selection from end to start. Characterize `start`/`length` before attempting behavior changes.
- **Delete/backspace/delete-to**: selected ranges delete directly; collapsed carets delete the translated range. Zero-length deletes should not dirty the document or create undo entries.
- **Paste**: build all paste edits in one transaction, including whole-line paste. Preserve current one-clipboard-per-caret and many-clipboards-per-caret behavior. Explicitly test selections after whole-line paste at column 1 vs middle-of-line.
- **Indent/unindent**: coalesce by affected line, compute per-line prefix replacement from the original document, then adjust selection endpoints from per-line deltas.
- **Line duplicate/delete/move**: coalesce overlapping line selections before creating edits. Moving adjacent selected blocks needs explicit tests; avoid double-moving shared boundaries.
- **Comment toggles**: calculate comment/uncomment decisions from the original document, then emit prefix/suffix edits. Coalesce line-comment ranges that overlap.
- **Transforms/replace**: return the same result table shape as `Doc:replace` currently returns. Final selection behavior must be documented by tests before changing it.
- **Trim whitespace/save-time edits**: use one batch per document save, and ensure autosave/dirty semantics are intentional.

## Testing Strategy

Add tests before broad migration. Prefer behavior/state tests over exact timing assertions.

Suggested files:

- `tests/lua/runtime/doc_batch_edit.lua` for pure Document behavior.
- `tests/lua/ui/doc_batch_edit_selection_state.lua` for Document View Selection Owner/Mirror behavior.
- Extend existing UI tests for line wrapping, local find, side-panel split selection state, and command output read-only behavior where relevant.

Regression coverage:

- Single `apply_edits` insert/remove matches existing public `Doc:insert`/`Doc:remove` behavior.
- Multiple collapsed carets typing one character and multiline text.
- Multiple selected ranges replaced by typing.
- Overwrite-mode multi-caret typing.
- Backspace/delete/delete-to at many carets, including BOF/EOF no-ops and indentation backspace.
- Paste with one clipboard payload, per-caret payloads, whole-line payloads, and multiline payloads.
- Undo/redo of large batches restores text and the correct Document View Selection State.
- Undo/redo from a different split does not overwrite the active split's Selection State with another Selection Owner's state.
- If the original owner view is still registered, undo/redo restores that owner view's inactive Selection State.
- Inactive registered Document View Selection States are transformed by batch edits.
- Overlapping edits are rejected atomically and leave text/selections/undo/cache notifications unchanged.
- Adjacent edits are allowed and deterministic.
- Duplicate zero-width inserts are rejected or pre-merged according to the chosen policy.
- Line-ending/multiline replacements preserve Anvil's line-table invariant.
- Empty insert/remove and zero-length delete do not dirty the document or push undo.
- Editing after undo updates `clean_change_id` correctly for both insert and remove.
- `on_text_change` fires once per public batch with transaction details, and in-repo wrappers forward the transaction argument.
- Highlighter/cache/wrapping notifications remain correct enough for visible UI behavior.
- Local find input updates once per input transaction without raw method patches.
- DiffView refreshes once per relevant transaction after raw wrappers are removed.
- Global and local single-line docs still strip CR/LF.
- `CommandOutputDoc` remains read-only to normal edit commands but still updates through internal mutation.
- `Doc:replace` keeps its result table shape and documented final selection behavior.

Performance checks:

- Extend or add an env-gated stress/benchmark helper for 100, 1,000, and 5,000 carets typing/deleting/pasting. Existing `data/plugins/edit_perf_stress.lua` is a useful starting point.
- Assert structural performance where possible: one undo entry, one public text-change notification, one transaction hook, no per-caret raw mutation hook calls.
- Use elapsed-time quiet logging for local comparison, not brittle pass/fail timing thresholds.

Run syntax/tests with the repo-local LuaJIT/Meson commands documented in `AGENTS.md`.

## Implementation Phases

### Phase 0: Characterize and Protect

1. Add targeted tests for current intended behavior and known failure cases.
2. Add tests for Selection Owner behavior across two Document Views sharing one Document.
3. Add temporary instrumentation or stress commands to measure current multi-caret typing/paste/delete.
4. Decide and test exact `Doc:replace` final-selection semantics before changing internals.
5. Add clean-id tests for editing after undo with both insert and remove.

### Phase 1: Core Batch Infrastructure Behind a Direct API

1. Add edit normalization/validation helpers.
2. Add one-pass line-table rewrite.
3. Add batch position mapper for selections.
4. Add transaction summary and rejection diagnostics.
5. Add document-specific normalization/authorization hooks.
6. Add direct `Doc:apply_edits` tests without yet migrating public edit methods.

### Phase 2: Transaction Maintenance and Hook Migration

1. Add highlighter/cache/binary clean-lines changed-range helpers.
2. Add internal transaction hook and public `on_text_change(change_type, transaction)` forwarding conventions.
3. Migrate in-repo `on_text_change` wrappers to accept/forward transaction details.
4. Migrate `linewrapping.lua`, `intellij_find.lua`, and `diffview.lua` away from raw insert/remove hooks.
5. Migrate `SingleLineDoc`, `CommandOutputDoc`, and prompt sanitization to normalization/authorization hooks.
6. Verify existing UI/runtime tests still pass.

### Phase 3: Public Single-Edit Wrappers and Batch Undo

1. Refactor `Doc:insert` and `Doc:remove` to call `apply_edits` for one edit.
2. Add batch undo command support while preserving legacy undo entry handling.
3. Update `raw_insert` / `raw_remove` expectations: keep them only as legacy/single-edit helpers if still useful, but do not rely on them for notifications.
4. Verify undo/redo, clean id, autosave, git diff highlighting, and edit location history.

### Phase 4: High-Impact Multi-Caret Paths

1. Migrate `Doc:text_input` and `Doc:ime_text_editing`.
2. Migrate `Doc:delete_to_cursor` / `delete_to`.
3. Migrate `doc:paste` and remove the paste undo patch.
4. Migrate newline/delete/backspace commands.
5. Measure 1,000+ carets and inspect quiet logs.

### Phase 5: Line and Transform Commands

1. Migrate indent/unindent, duplicate/delete/move lines, join lines, comments.
2. Migrate `Doc:replace` and transform plugins through the primitive.
3. Migrate remaining first-party plugin edit loops.
4. Remove obsolete first-party compatibility patches/hooks.

### Phase 6: Cleanup and Polish

1. Remove dead per-caret helper paths that are no longer used in first-party code.
2. Keep public API documentation/comments current.
3. Keep diagnostics useful but quiet.
4. Run full Lua syntax checks and Anvil Meson test suite.
5. If non-Lua files were changed during implementation, refresh the dev portable app with `update-anvil-dev-build.bat`.

## Acceptance Criteria

- Typing, deletion, and paste with 1,000 carets complete interactively instead of hanging.
- Each user-facing multi-caret edit creates one transaction, one undo command, and one public `on_text_change` notification.
- Undo/redo restores text and the correct Selection Owner's Selection State without corrupting other split views.
- Inactive split views keep sensible Selection States after edits in another view.
- Highlighter, caches, wrapping, autosave, git diff highlighting, edit location history, diff views, and prompt/local find docs work through transaction hooks.
- Tests cover behavior, ownership, overlap rejection, clean-id semantics, no-op edits, and multiline edge cases.
- No hot batch path uses large `table.unpack`, repeated `common.splice`, or per-caret selection sanitization.
- First-party code no longer depends on raw insert/remove monkey-patches for normal edit notifications.
