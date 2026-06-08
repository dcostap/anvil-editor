# Multi-cursor Movement Performance Fix Plan

## Triggering measurement

Input recording:

```text
C:\Users\Darius\AppData\Local\Temp\anvil_perf_20260608_214136_summary.txt
```

Important results:

```text
Elapsed: 30.220s
Redraw frames: 169
Max selections: 69900
Over-budget redraw frames: 72 (42.6%)
```

The worst stalls were not draw stalls:

```text
total_ms 9058.689, event_ms 8978.367, frame_ms 8.728
total_ms 7924.132, event_ms 7872.953, frame_ms 5.345
total_ms 7922.123, event_ms 7870.793, frame_ms 5.686
```

Draw/rendering is no longer the dominant problem in this scenario. The dominant problem is event-command work before drawing.

Perf detail counters identify the hot behavior:

```text
489300 doc_set_selections_calls
419750 doc_get_selections_calls
419407 doc_merge_cursors_calls
419400 doc_get_selections_reverse_or_idx_calls
15587.690 doc_merge_cursors_ms
```

The value `419400` is exactly `69900 * 6`, indicating repeated per-cursor command paths over a 69,900-cursor selection set.

## Proposed fixes covered by this plan

1. Batch `doc:move-to-previous-char` and `doc:move-to-next-char` instead of calling per-cursor movement APIs.
2. Replace full `Doc:merge_cursors()` duplicate removal with an O(N) implementation.

These fixes are deliberately narrower than a native `SelectionSet` refactor.

## Direct code verification notes

I verified the actual files/functions rather than relying on scout output:

- `data/core/commands/doc.lua` defines generic movement commands in the `translations` loop, then **overwrites** `doc:move-to-previous-char` and `doc:move-to-next-char` with special collapse-selection implementations. These two special commands are the relevant command entry points for left/right char movement.
- `data/core/command.lua` wraps both predicate evaluation and command execution with `DocView:with_selection_state(...)` when the active view or command argument is a DocView. Therefore command-level direct `doc.selections = new_table` inside `command.perform(...)` will be captured by `DocView:capture_selection_state()` after the command. A direct call to the command function outside `command.perform` would not get that guarantee, but first-party command execution does.
- `data/core/docview.lua:with_selection_state()` binds `doc.selections = self.selection_state.selections` before command execution and calls `self:capture_selection_state()` afterward. If command code replaces `doc.selections` with a new table, capture still copies that table into the view's selection state.
- `data/plugins/intellij_actions.lua` monkey-patches only `Doc:set_selection`, `Doc:set_selections`, `Doc:insert`, and `Doc:remove` to clear selection-origin/history state. A new direct-assignment batch path would bypass that plugin state unless we add an explicit first-party helper and patch/use it consistently.
- `data/core/doc/init.lua:Doc:merge_cursors(idx)` has two modes. The `idx` mode checks only one target cursor against previous cursors. The full mode scans all cursors with nested loops and removes duplicates by raw caret endpoint only. Any O(N) rewrite must preserve the narrower `idx` semantics.
- `data/core/common.lua:common.splice()` uses `table.move`; removing many duplicates one by one still shifts array elements repeatedly. Full duplicate merge should build a new table rather than repeatedly splicing.
- Existing tests touch command-level `doc:move-to-next-char` once and generic `Doc:move_to(...)` behavior, but there is no explicit `doc:move-to-previous-char` command test and no direct `merge_cursors` behavior test.

---

# Fix 1: Batch previous/next-char movement commands

## Current behavior

File:

```text
data/core/commands/doc.lua
```

Current special-case commands:

```lua
commands["doc:move-to-previous-char"] = function(dv)
  for idx, line1, col1, line2, col2 in dv.doc:get_selections(true) do
    if line1 ~= line2 or col1 ~= col2 then
      dv.doc:set_selections(idx, line1, col1)
    else
      dv.doc:move_to_cursor(idx, translate.previous_char)
    end
  end
  dv.doc:merge_cursors()
end

commands["doc:move-to-next-char"] = function(dv)
  for idx, line1, col1, line2, col2 in dv.doc:get_selections(true) do
    if line1 ~= line2 or col1 ~= col2 then
      dv.doc:set_selections(idx, line2, col2)
    else
      dv.doc:move_to_cursor(idx, translate.next_char)
    end
  end
  dv.doc:merge_cursors()
end
```

The intended behavior is correct:

- if selection is non-empty, collapse to start/end
- otherwise move caret one character left/right
- merge duplicate carets afterward

The performance bug is that collapsed carets call:

```lua
dv.doc:move_to_cursor(idx, translate.previous_char)
dv.doc:move_to_cursor(idx, translate.next_char)
```

And `Doc:move_to_cursor(idx, ...)` in `data/core/doc/init.lua` does:

```lua
for sidx, line, col in self:get_selections(false, idx) do
  self:set_selections(sidx, self:position_offset(line, col, ...))
end
self:merge_cursors(idx)
```

Even though `idx` makes this one selected cursor, it still performs API/iterator setup and then calls `merge_cursors(idx)` for every cursor. With 69,900 cursors, this produced hundreds of thousands of selection API calls.

## Desired behavior

Replace the command implementation with one explicit batched pass:

```text
for each selection, sorted intra-selection:
  if non-empty selection:
    next position = collapse endpoint
  else:
    next position = translate.previous_char/next_char(doc, line, col, dv)
  append collapsed selection { next_line, next_col, next_line, next_col }
replace doc.selections once
preserve last_selection as much as possible
merge duplicates once
sync selection mirror once
```

## Blast radius

### Direct files touched

```text
data/core/commands/doc.lua
```

Likely add a local helper near the existing movement command block:

```lua
local function move_char_batch(dv, move_fn, collapse_to_end)
  ...
end
```

Then rewrite only:

```lua
commands["doc:move-to-previous-char"]
commands["doc:move-to-next-char"]
```

### Runtime behavior affected

Only these command names should change implementation:

```text
doc:move-to-previous-char
doc:move-to-next-char
```

Default keybindings that invoke these commands:

```text
data/core/keymap.lua: left/right
data/core/keymap-macos.lua: left/right
```

Do not test exact keybindings. Test command behavior.

### Core APIs used but not changed by this fix

```text
data/core/doc/init.lua: Doc:get_selections
data/core/doc/init.lua: Doc:sanitize_position
data/core/doc/init.lua: Doc:merge_cursors
data/core/doc/translate.lua: translate.previous_char / translate.next_char
```

### Important semantic dependencies

- The current commands use `get_selections(true)`, so non-empty selections are sorted before deciding the collapse endpoint.
- Previous-char collapses to sorted start.
- Next-char collapses to sorted end.
- Empty/collapsed selections use UTF-8-aware translation through `translate.previous_char` / `translate.next_char`.
- `last_selection` should remain the same logical active cursor unless duplicate merging removes or shifts it.
- The command executes inside `DocView:with_selection_state()` because command dispatch for a DocView goes through the active view selection binding. Direct `doc.selections = new_table` is safe only inside that binding or if followed by the same mirror sync pattern used elsewhere.

### Risks

1. **Selection mirror sync**

   Verified detail: normal command execution already runs under `DocView:with_selection_state()`, and `with_selection_state()` calls `capture_selection_state()` afterward. That means direct `doc.selections = new_table` in these command functions will be captured for the active view when invoked through `command.perform(...)`.

   Still, prefer a small core helper rather than ad-hoc assignment, so tests/plugins have one API to use and future native storage has a clean seam.

2. **IntelliJ plugin monkey patch**

   `data/plugins/intellij_actions.lua` monkey-patches `Doc:set_selection` and `Doc:set_selections` to clear selection-origin tracking:

   ```lua
   local doc_set_selections = Doc.set_selections
   function Doc:set_selections(...)
     if not suppress_origin_clear then clear_selection_origin(self) end
     return doc_set_selections(self, ...)
   end
   ```

   A direct batch assignment bypasses this. Since the existing commands call `set_selections` for non-empty selections and `move_to_cursor -> set_selections` for carets, behavior today clears origin during movement.

   Preferred resolution after inspecting the actual plugin: add a core helper such as `Doc:set_selection_list(selections, last_selection, opts)` and update `intellij_actions.lua` to wrap that helper too. Then command batching can call the helper without losing origin-clear behavior. If we do not add that helper, the command must deliberately clear/recreate equivalent state, but `clear_selection_origin` is local to the plugin and not callable from core.

3. **Duplicate merge and last_selection**

   If multiple carets collapse/move to the same position, duplicate merging may remove some entries. `last_selection` must be clamped and preferably mapped to the surviving duplicate.

4. **Selections crossing lines**

   Sorting endpoints is required before collapse. Backward selections must still collapse to the correct side.

## Suggested implementation shape

Add a local helper in `data/core/commands/doc.lua`:

```lua
-- Preferred: implement this as a Doc method, not as a command-local helper,
-- so intellij_actions.lua can wrap it the same way it wraps set_selections.
function Doc:set_selection_list(selections, last_selection, opts)
  -- sanitize/import array once
  -- assign doc.selections once
  -- clamp last_selection
  -- sync_unbound_selection_mutation once
end

local function move_char_batch(dv, move_fn, collapse_to_end)
  local doc = dv.doc
  local new = {}
  local last = doc.last_selection or 1
  for idx, line1, col1, line2, col2 in doc:get_selections(true) do
    local line, col
    if line1 ~= line2 or col1 ~= col2 then
      if collapse_to_end then
        line, col = line2, col2
      else
        line, col = line1, col1
      end
    else
      line, col = move_fn(doc, line1, col1, dv)
    end
    new[#new + 1] = line
    new[#new + 1] = col
    new[#new + 1] = line
    new[#new + 1] = col
  end
  doc:set_selection_list(new, last, { merge_cursors = true })
end
```

The helper should avoid per-selection `Doc:set_selections()` calls. It should sanitize in a loop, assign once, and merge once. `intellij_actions.lua` should wrap this helper to clear origin state.

## Tests for Fix 1

Existing relevant test:

```text
tests/lua/ui/doc_selection_state_characterization.lua
```

Existing test case:

```text
movement commands preserve multi-caret state and subsequent text input edits moved selections
```

This already invokes:

```lua
command.perform("doc:move-to-next-char")
command.perform("doc:select-to-next-char")
```

Add new cases in the same file:

1. `doc:move-to-previous-char` preserves multi-caret state and clamps at document start.
2. `doc:move-to-next-char` collapses forward/backward selected ranges to sorted end.
3. `doc:move-to-previous-char` collapses forward/backward selected ranges to sorted start.
4. Movement command merges duplicate carets after movement in one batch.
5. A large-ish synthetic selection set verifies command path does not call `Doc:merge_cursors` once per cursor.

Do not test keybindings.

Suggested perf regression assertion:

- Monkey-patch `doc.merge_cursors` in test and assert one call for `doc:move-to-next-char` with many carets.
- Optionally monkey-patch `doc.move_to_cursor` and assert zero calls from the command.

---

# Fix 2: Make full `Doc:merge_cursors()` O(N)

## Current behavior

File:

```text
data/core/doc/init.lua
```

Current implementation:

```lua
function Doc:merge_cursors(idx)
  local table_index = idx and (idx - 1) * 4 + 1
  for i = (table_index or (#self.selections - 3)), (table_index or 5), -4 do
    for j = 1, i - 4, 4 do
      if self.selections[i] == self.selections[j] and
        self.selections[i+1] == self.selections[j+1] then
          common.splice(self.selections, i, 4)
          if self.last_selection >= (i+3)/4 then
            self.last_selection = self.last_selection - 1
          end
          break
      end
    end
  end
  self.last_selection = common.clamp(math.floor(tonumber(self.last_selection) or 1), 1, selection_state_count(self))
  sync_unbound_selection_mutation(self)
end
```

Behavior:

- Merges duplicate cursors by comparing raw caret endpoint `(line1, col1)` only.
- Does not compare anchor endpoint/range.
- For full merge, scans backwards and for each cursor scans all previous cursors.
- For `idx`, checks only one target cursor against previous cursors.

Performance:

- Full merge is O(N^2).
- Per-index merge is O(idx).
- Current `doc:move-to-previous-char` / `doc:move-to-next-char` accidentally calls per-index merge once per cursor.

## Desired behavior

Preserve semantics, but use a map for full merge:

```text
seen[caret_line .. separator .. caret_col] = kept_selection_index
for each selection in order:
  if key unseen: keep selection
  else: drop duplicate
adjust last_selection to point at kept equivalent or shifted surviving index
replace selection table once
sync once
```

For `idx` path, keep the current narrow semantics: only the target cursor is checked against previous cursors. Do not rewrite `merge_cursors(idx)` as a full merge, because callers may rely on only the targeted cursor being merged.

The largest win is full merge O(N). The command batching fix should also eliminate the repeated per-index merge storm.

## Blast radius

### Direct files touched

```text
data/core/doc/init.lua
```

Function changed:

```lua
Doc:merge_cursors(idx)
```

Potentially related helper:

```lua
merge_state_cursors(state, idx)
```

Recommendation: do **not** change `merge_state_cursors` in the first pass unless tests or profiling show it matters. It applies to inactive selection states and has its own risks.

### Callers affected

Core command callers:

```text
data/core/commands/doc.lua:150   target_doc:merge_cursors()
data/core/commands/doc.lua:1110  dv.doc:merge_cursors()
data/core/commands/doc.lua:1115  dv.doc:merge_cursors()
data/core/commands/doc.lua:1217  dv.doc:merge_cursors()
data/core/commands/doc.lua:1228  dv.doc:merge_cursors()
```

Core Doc callers:

```text
data/core/doc/init.lua:1860 self:merge_cursors(idx)
data/core/doc/init.lua:1870 self:merge_cursors(idx)
data/core/doc/init.lua:1880 self:merge_cursors(idx)
```

Plugins may also call movement/edit APIs that indirectly merge.

### Semantics to preserve

- Duplicates are detected by raw caret endpoint `(line1, col1)`, not sorted endpoint and not full range.
- First duplicate in document order survives.
- Later duplicates are removed.
- `last_selection` is decremented for removed selections before or at its old index.
- If the active last selection itself is removed as a duplicate, it should point to the surviving equivalent if possible; otherwise clamp to valid range.
- Always leave at least one selection.
- Call `sync_unbound_selection_mutation(self)` exactly once per merge call, preserving `selection_revision` cache invalidation behavior.

### Risks

1. **last_selection mapping**

   The old implementation decrements when a removed duplicate index is `<= last_selection`. If `last_selection` itself is removed, old behavior effectively moves active selection to the previous shifted slot, not necessarily the original duplicate survivor. We need to decide whether to preserve this exactly or improve it to survivor mapping.

   Preferred behavior for user-facing correctness: if active cursor is duplicate-removed, active selection should map to the surviving duplicate at the same caret position. Add tests to lock this down.

2. **Index-specific merge path**

   Verified in `data/core/doc/init.lua`: `merge_cursors(idx)` starts at one `table_index`, not at the end. Full O(N) merge must not run when `idx` is provided. Preserve old targeted behavior or implement an equivalent target-only check.

3. **Selection order**

   The new table must preserve original order of kept selections.

4. **Undo/redo assumptions**

   `merge_cursors` itself does not push undo. Preserve that.

## Suggested implementation shape

```lua
local function cursor_key(line, col)
  return tostring(line) .. "\0" .. tostring(col)
end

function Doc:merge_cursors(idx)
  if idx then
    -- keep old targeted semantics, or implement equivalent targeted map over previous entries
    ...
  else
    local old = self.selections
    local old_last = self.last_selection or 1
    local seen = {}
    local new = {}
    local old_to_new = {}

    for old_idx = 1, #old / 4 do
      local i = (old_idx - 1) * 4 + 1
      local key = cursor_key(old[i], old[i + 1])
      local kept_idx = seen[key]
      if kept_idx then
        old_to_new[old_idx] = kept_idx
      else
        local new_idx = #new / 4 + 1
        seen[key] = new_idx
        old_to_new[old_idx] = new_idx
        new[#new + 1] = old[i]
        new[#new + 1] = old[i + 1]
        new[#new + 1] = old[i + 2]
        new[#new + 1] = old[i + 3]
      end
    end

    if #new == 0 then
      local line, col = self:sanitize_position(1, 1)
      new = { line, col, line, col }
    end

    self.selections = new
    self.last_selection = common.clamp(old_to_new[old_last] or old_last, 1, selection_state_count(self))
  end
  sync_unbound_selection_mutation(self)
end
```

If exact old `last_selection` shifting is required, replace `old_to_new[old_last]` with an old-compatible decrement calculation. Prefer testing the intended user behavior.

## Tests for Fix 2

Add tests in:

```text
tests/lua/runtime/doc_edit_characterization.lua
```

Suggested cases:

1. `merge_cursors keeps first caret and removes later duplicates`.
2. `merge_cursors maps last_selection to surviving duplicate`.
3. `merge_cursors(idx) only merges targeted cursor with previous duplicates`.
4. `merge_cursors preserves non-duplicate selection order`.
5. Large synthetic case verifies runtime does not explode. Do not assert exact wall-clock time unless test framework has stable perf helpers; instead instrument `common.splice` or use a low-risk structural assertion if practical.

Existing coverage likely affected:

```text
tests/lua/runtime/doc_edit_characterization.lua
tests/lua/ui/doc_selection_state_characterization.lua
tests/lua/ui/intellij_actions.lua
```

---

# Combined expected performance effect

Before fixes in the bad recording:

```text
419407 doc_merge_cursors_calls
489300 doc_set_selections_calls
~8-9s event stalls
```

After Fix 1:

Expected for one previous/next-char movement over 69,900 cursors:

```text
doc_get_selections_calls: ~1-2 for command
doc_get_selections_iters: ~69900, not ~489336
doc_set_selections_calls: near 0 or 1 helper-level assignment, not 489300
doc_merge_cursors_calls: 1, not 69900+
event_ms: should drop from seconds to probably tens of ms or less
```

After Fix 2:

```text
doc_merge_cursors_ms: should be roughly linear in cursor count
```

With both fixes, the next likely bottleneck may be UTF-8 movement itself:

```text
translate.previous_char / translate.next_char
Doc:position_offset
Doc:sanitize_position
common.clamp
```

The sample file already shows many samples in `Doc:sanitize_position`, `Doc:position_offset`, and `common.clamp`. If event time is still too high after batching/merge, the next surgical target should be a specialized fast path for same-line previous/next-char over many ASCII carets.

---

# Validation plan

Lua syntax:

```sh
./build-windows-x86_64/subprojects/luajit/src/luajit.exe check-lua-syntax.lua data/core/doc/init.lua data/core/commands/doc.lua tests/lua/runtime/doc_edit_characterization.lua tests/lua/ui/doc_selection_state_characterization.lua
```

Targeted tests:

```sh
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/doc_edit_characterization.lua --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/doc_selection_state_characterization.lua --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/intellij_actions.lua --print-errorlogs
```

Full Anvil suite if targeted tests pass:

```sh
meson test -C build-windows-x86_64 --suite anvil --print-errorlogs
```

Manual validation:

1. Run F11 recording.
2. Open huge file.
3. Create/select many carets.
4. Press left/right repeatedly.
5. Stop F11.
6. Compare these fields:

```text
event_ms
doc_merge_cursors_calls
doc_merge_cursors_ms
doc_get_selections_calls
doc_get_selections_iters
doc_set_selections_calls
doc_apply_edits_ms
```

Success criteria:

- No multi-second `event_ms` spikes from previous/next-char movement.
- `doc_merge_cursors_calls` is no longer proportional to selection count.
- `doc_set_selections_calls` is no longer proportional to selection count for previous/next-char movement.
- Rendering remains below or near frame budget except for unrelated plugins/render hotspots.

---

# Implementation order

1. Add tests for command-level previous/next-char behavior and merge behavior.
2. Implement O(N) full `Doc:merge_cursors()` while preserving targeted `idx` semantics.
3. Implement batched previous/next-char command helper.
4. Run targeted tests.
5. Run F11 manual benchmark again.
6. Only then decide whether to optimize UTF-8/sanitize/position-offset movement hot paths.
