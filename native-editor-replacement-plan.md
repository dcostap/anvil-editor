# Native Editor Replacement Plan

## Purpose

This plan starts the next phase after the native Buffer/Editor/Tree-sitter foundation work. The goal is to move from an experimental native-backed sandbox toward replacing Anvil's current Lua `Doc`/`DocView` editing path with the Fred-style native core.

This is not a plan to preserve the Lua `Doc` API indefinitely. The intended direction remains:

1. Keep the current Lua editor working while the native editor becomes complete enough to dogfood.
2. Promote native Buffer/Editor behavior behind a real editor view.
3. Replace the default editor creation path.
4. Delete the old Lua text storage/mutation stack when it is no longer needed.

The user is also considering an eventual pure C application shell. This plan therefore avoids building new long-term Lua abstractions unless they are temporary sandbox glue.

## Vocabulary

Use the Fred vocabulary for the new native core:

- **Buffer**: shared editable text state, file path/dirty state, undo graph, parse state.
- **Buffer Manager**: central coordinator for applying text transactions to a Buffer.
- **Editor**: per-view cursor, selection, and editing state over a Buffer.

Keep **Document / Doc** only for Anvil's existing Lua editor until replacement.

## Context: what has been built so far

The current branch has a native text stack beside the old Lua `Doc` stack.

### Native text storage

Implemented:

- `src/text/piece_tree.c/.h`
- Persistent piece-tree storage with original/add buffers.
- Chunked pieces for large-file navigation.
- Cached byte length and LF metadata.
- Insert/remove by byte offset.
- Byte-range walking without flattening.
- Forward/reverse walkers.
- Line lookup, line ranges, CRLF-aware helpers.
- Cheap root snapshots and restore.
- Worker-safe text snapshots for background parsing.
- Native fuzz tests against a flat-string oracle.

Important status:

- Large-file movement/jumping is fast.
- Piece-tree snapshots are sufficient for undo and Tree-sitter background parsing.
- Text bytes are preserved; encoding conversion/sanitization remains a future layer.

### Native Buffer and Buffer Manager

Implemented:

- `src/text/buffer.c/.h`
- `src/text/buffer_manager.c/.h`
- File-backed Buffer load/save.
- Dirty state based on undo/save node identity.
- Line-ending mode tracking and newline insertion support.
- Central batch-edit transaction path.
- Pre-edit coordinate batch edits, applied in sorted/descending-safe order.
- Cursor mapping results.
- Changed byte/line ranges.
- Tree-sitter edit descriptors with byte and point data.
- Listener callbacks for native Editor propagation.

Important status:

- Normal typing no longer refreshes line-ending mode by flattening the file.
- Multi-edit and snap paths notify Tree-sitter as dirty/full reparse when needed.

### Native Editor

Implemented:

- `src/text/editor.c/.h`
- Byte-offset cursor model.
- Per-view cursor and selection state.
- Multi-cursor insertion/deletion.
- Cursor sorting/merging.
- Character/line/word movement.
- Shift-selection variants.
- Home/end and Buffer start/end movement.
- Duplicate cursor up/down.
- Selection copy/cut/paste primitives.
- Backspace/delete and word deletion.
- Line operations: delete line, move line, join line, open line.
- Tab/untab and line-ending unification.
- Undo/redo integration with selection snapshots.

Important status:

- The native Editor is strong enough for sandbox editing, but not yet complete enough to replace `DocView` UX.

### Undo graph

Implemented:

- `src/text/undo_graph.c/.h`
- Fred-style graph-shaped undo/redo.
- Branching redo.
- Snapshot-based restore instead of inverse patch replay.
- Save/dirty node identity.
- Selection snapshots associated with Editor/view operations.

Important status:

- Undo/redo works in native tests and sandbox.
- Branch UI/exposure is not implemented.

### Native worker pool

Implemented:

- `src/thread_pool.c/.h`
- Process-wide SDL worker pool.
- CPU-count worker sizing with minimum workers.
- Task handles, cancellation flags, result polling.
- Shutdown joins.

Used by:

- Native Tree-sitter background parsing.

Important status:

- Worker pool is intentionally generic and small, but follows Fred's handle/cancel/poll shape.
- Future expensive native tasks should use this pool instead of blocking UI work.

### Tree-sitter infrastructure

Implemented:

- `src/text/treesitter.c/.h`
- `src/text/treesitter_registry.c/.h`
- `data/treesitter/queries/c/highlights.scm`
- C/.h language support through `tree-sitter-c`.
- Native language registry for parser function, extensions, query asset, and capture style mapping.
- Query asset loading from bundled data.
- Shared compiled query cache per language.
- Query cache shutdown at app quit/tests.
- Per-Buffer main-thread parser for synchronous parse path.
- Per-task worker parser for background parse path.
- `ts_tree_edit` for single-edit incremental updates.
- Dirty/deferred reparsing for edit path.
- Background parse scheduling and main-thread polling/apply.
- Snapshot-backed async parsing from piece-tree text snapshots.
- Tree-sitter parse cancellation callbacks.
- Generation-based stale result discard.
- Native highlight span normalization with deterministic overlap resolution.
- Highlight spans expose capture, style, and priority.
- Opt-in diagnostics via `ANVIL_TREE_SITTER_LOG=1`.

Important status:

- Large `.c` typing in the sandbox is now smooth.
- Tree-sitter is robust enough to stop polishing unless bugs appear.
- More language support is intentionally deferred.
- Language injections/embedded languages remain future work.

### Sandbox UI

Implemented:

- `data/plugins/native_text_sandbox.lua`
- `native_text` Lua bridge in `src/api/native_text.c`.
- `native-text-sandbox:open`
- `native-text-sandbox:open-file`
- `native-text-sandbox:save`
- File-backed native Buffers.
- Dirty marker in tab title.
- Visible line rendering from native walkers.
- Tree-sitter highlighting.
- Multiple carets.
- Selection rendering.
- Basic mouse placement.
- Typing/editing.
- Movement shortcuts and duplicate cursor shortcuts.
- Undo/redo.

Important status:

- Sandbox is usable for manual testing.
- Sandbox is still Lua-owned UI glue, not the final replacement editor.

## Current strategic direction

The next work should stop treating Tree-sitter as the main project. The next milestone is native editor replacement readiness.

The replacement should proceed in layers:

1. Inventory what the Lua editor currently provides.
2. Decide what must exist before native editor dogfooding.
3. Implement missing native editor/view behaviors in tests first where possible.
4. Promote the native editor view from sandbox to real editor path.
5. Delete the old Lua `Doc` text core when replacement is stable.

## Phase A: Replacement inventory

Create a concrete checklist of what the current Lua editor does that the native editor must either support or intentionally drop.

Primary files to inspect:

- `data/core/doc/init.lua`
- `data/core/docview.lua`
- `data/core/commands/core.lua`
- `data/core/commands/files.lua`
- `data/plugins/anvil_defaults.lua`
- first-party plugins under `data/plugins` that reference docs/views/selections/text.

Inventory categories:

### File lifecycle

Questions:

- How does current open-file create `Doc` and `DocView`?
- How are duplicate opens handled?
- How are dirty prompts handled on close/quit/reload?
- How are external file changes detected/reloaded?
- How are save/save-as/save-all commands routed?
- How are file encodings and line endings surfaced?

Native gaps likely to close:

- Save-as command from native view.
- Dirty close prompt integration.
- External reload path.
- Better file error reporting.
- Encoding/display-sanitization decision.

### Commands and key routing

Questions:

- Which commands target `DocView` specifically?
- Which commands assume `Doc.lines` or Lua selection structures?
- Which commands are generic view commands and should keep working?
- Which first-party defaults bind editor behavior that native view must expose?

Native gaps likely to close:

- Native command coverage for common editor commands.
- A command dispatch boundary that can later move to C.
- Avoid testing exact shortcuts; test command behavior.

### Cursor and selection UX

Questions:

- What mouse selection behaviors exist now?
- How does drag selection work?
- How do double-click/triple-click selections work?
- How is multi-cursor selection created/cleared?
- How are rectangular/column selections handled, if at all?

Native gaps likely to close:

- Mouse drag selection.
- Shift-click selection extension.
- Double-click word select.
- Triple-click line select.
- Select all.
- Page up/down movement and selection.
- Better desired-column behavior under scrolling/page movement.

### Clipboard

Questions:

- How does current editor integrate with OS clipboard?
- What exact text shape is used for multiple selections?
- How are line selections copied/cut?

Native gaps likely to close:

- OS clipboard integration in sandbox/native view.
- Cut/copy/paste commands wired to native Editor.
- Multi-selection clipboard behavior tested.

### Search/find/replace

Questions:

- Which search UI commands operate on current `Doc`?
- How does find next/previous route through selections?
- How does replace one/all integrate with undo?

Native gaps likely to close:

- Native Buffer search helpers.
- Find next/previous from current cursor.
- Selection update after find.
- Replace through Buffer Manager transaction path.
- Replace-all as a batch edit.

### View/camera/rendering

Questions:

- How does current `DocView` scroll and clamp?
- How does it render current line, gutter, selections, minimap/scrollbar if any?
- How does it handle horizontal scrolling?
- How does it keep cursor visible?
- How are tabs, font metrics, wrapped lines, and long lines handled?

Native gaps likely to close:

- Page up/down.
- Horizontal scrolling.
- Scroll-to-cursor polish.
- Wheel/mouse scrolling parity.
- Long-line behavior.
- Current-line highlight.
- Gutter click/drag behavior if desired.

### Syntax and semantic features

Questions:

- Which Lua syntax highlighters are still relevant during transition?
- Which plugins rely on tokenizer/highlighter APIs?
- Is Tree-sitter highlight output enough for the native replacement path?

Native gaps likely to close:

- No more Tree-sitter architecture work unless replacement exposes bugs.
- Language additions are deferred.
- Tokenizer compatibility should not become a long-term goal unless needed for first-party features.

### Plugin compatibility / deletion candidates

Questions:

- Which bundled plugins are mandatory first-party behavior?
- Which plugins assume Lua `Doc` internals?
- Which plugins should be ported to C/native APIs?
- Which plugins can be deleted because this is a personal fork?

Output:

- A table of plugin/command dependencies with one of:
  - keep and port
  - keep temporarily through Lua glue
  - delete/drop
  - defer

## Phase B: Dogfooding readiness checklist

The native editor is ready for day-to-day dogfooding when these are complete:

### Required editor behavior

- Open/save/save-as file-backed Buffers.
- Dirty close prompt or safe refusal to close dirty native views.
- OS clipboard copy/cut/paste.
- Select all.
- Mouse drag selection.
- Double-click word selection.
- Triple-click line selection.
- Page up/down and shift-page selection.
- Find next/previous.
- Replace current match.
- Undo/redo works for all editing operations above.
- Multi-cursor insertion/deletion remains stable.
- Large-file navigation and typing remain fast.

### Required view behavior

- Cursor stays visible after commands.
- Vertical scrolling is smooth and clamped.
- Horizontal scrolling or long-line policy is usable.
- Selections render correctly across visible lines.
- Caret rendering remains correct under scroll.
- Dirty marker and view title are correct.
- Save errors are visible enough to notice.

### Required test coverage

Prefer native tests for model behavior:

- Clipboard text shape.
- Select all.
- Page movement offsets.
- Find/replace helpers.
- Batch replace undo.
- Multi-cursor edge cases.

Prefer Lua UI/sandbox tests only for temporary view glue:

- Command routing.
- View title dirty marker.
- Scroll/caret visibility state.
- Mouse selection behavior if still Lua-hosted.

## Phase C: Default editor replacement checklist

The native editor is ready to become the default editor when dogfooding is stable and these are complete:

- `core.open_doc` / file open path can create native Buffers/views for normal text files.
- Existing tabs/splits/root panel can host native editor views without special sandbox commands.
- Save/close/quit flows handle native views.
- Search UI works on native Buffers.
- Command palette commands target native editor views.
- First-party default keybindings route to native commands.
- Critical first-party plugins are ported, adapted, or explicitly deleted.
- Old Lua `Doc` no longer owns the primary editing experience.

## Phase D: Lua `Doc` deletion checklist

Only after the native editor is default and stable:

- Remove or quarantine old `data/core/doc` text mutation code.
- Remove `Doc.lines` assumptions from bundled plugins/commands.
- Remove compatibility glue that only existed for transition.
- Keep Lua only if it still serves the temporary app shell/plugin role.
- If pursuing pure C, begin moving command/keymap/view infrastructure into C after text editor replacement is stable.

## Suggested immediate implementation order

After completing the inventory, implement in this order:

1. **OS clipboard integration for native sandbox/view**
   - Wire copy/cut/paste commands to native Editor.
   - Use existing platform clipboard APIs exposed to Lua initially if fastest.
   - Add native tests for copied text shape and cut/paste undo.

2. **Select all + mouse selection polish**
   - Add native `editor_select_all`.
   - Add drag selection in sandbox.
   - Add double-click word and triple-click line selection.

3. **Page movement and camera polish**
   - Add native page up/down commands based on visible line count from view.
   - Keep cursor visible after every command.
   - Improve horizontal scroll/long-line handling.

4. **Find/replace core helpers**
   - Add native Buffer search primitives.
   - Add Editor find-next/find-prev selection behavior.
   - Add replace and replace-all through Buffer Manager.

5. **File lifecycle integration**
   - Save-as.
   - Dirty close prompt integration.
   - External reload handling.

6. **Default-open experiment**
   - Add an opt-in setting or command path that opens normal files in the native editor view instead of the old `DocView`.
   - Dogfood with common project files.

## Explicit non-goals for this phase

- Do not add more Tree-sitter languages unless needed for replacement testing.
- Do not build long-term Lua compatibility layers for `Doc.lines`.
- Do not parameterize every UI constant prematurely.
- Do not preserve deprecated native APIs just for internal callers; update in-repo callers instead.
- Do not replace the whole Lua UI shell before the native editor is dogfoodable.

## Validation expectations

For Lua-only sandbox glue changes:

```sh
./build-windows-x86_64/subprojects/luajit/src/luajit.exe check-lua-syntax.lua <changed-lua-files>
```

For native core/editor changes:

```sh
PATH=/c/msys64/mingw64/bin:$PATH /c/msys64/mingw64/bin/meson.exe test -C build-windows-x86_64 --suite anvil --print-errorlogs
```

For non-Lua changes, refresh the dev portable app:

```sh
cmd.exe //d //s //c "call C:\Projects\c_projects\anvil-editor\update-anvil-dev-build.bat"
```

Manual dogfooding should use:

- `native-text-sandbox:open-file` while sandbox-hosted.
- Later, the opt-in native default-open path.

## Success criteria for this plan

This plan succeeds when:

- There is a checked-off replacement inventory for `Doc`/`DocView` behavior.
- The native editor can be used for ordinary editing sessions without falling back to Lua `Doc` behavior.
- The default file-open path can be switched to native editor views behind an opt-in flag.
- Remaining Lua dependencies are app-shell concerns, not text-core concerns.
