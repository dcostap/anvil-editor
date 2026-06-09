# Native Document Core Refactor Plan

## Fred decomp location

The Fred decompiled source dump is at:

```text
C:\Projects\my_decomps\fred_src_dump
```

The recovered Fred source files most relevant to text editing are under:

```text
C:\Projects\my_decomps\fred_src_dump\D_\git_projects\fred\src
C:\Projects\my_decomps\fred_src_dump\D_\git_projects\fred\inc
```

Key files inspected:

- `D_\git_projects\fred\src\fredbuf.cpp`
- `D_\git_projects\fred\src\ed.cpp`
- `D_\git_projects\fred\src\ed-buffer-manager.cpp`
- `D_\git_projects\fred\src\undo-graph.cpp`
- `D_\git_projects\fred\inc\undo-data.h`
- `D_\git_projects\fred\src\basic-textedit.cpp`

## What we learned about Fred's architecture

Fred's text editing architecture is a native C++ editor core centered on a persistent piece-tree text store, a shared document/buffer manager, byte-offset cursors, native multi-cursor editing, incremental Tree-sitter integration, and a branching undo graph.

### Text storage: piece tree

Fred stores text in `PieceTree::Tree` in `fredbuf.cpp`.

Important recovered methods/types:

- `PieceTree::Tree::Tree(BufferCollection *)`
- `PieceTree::Tree::insert(CharOffset, String8 *, SuppressHistory)`
- `PieceTree::Tree::internal_insert(CharOffset, String8 *)`
- `PieceTree::Tree::internal_remove(CharOffset, Length)`
- `PieceTree::Tree::node_at(BufferCollection *, RedBlackTree, CharOffset)`
- `PieceTree::Tree::line_start<&PieceTree::Tree::accumulate_value>(...)`
- `PieceTree::Tree::line_start<&PieceTree::Tree::accumulate_value_no_lf>(...)`
- `PieceTree::Tree::line_at(CharOffset)`
- `PieceTree::Tree::assemble_line(...)`
- `PieceTree::Tree::get_line_content(...)`
- `PieceTree::Tree::get_line_range(...)`
- `PieceTree::TreeWalker`
- `PieceTree::ReverseTreeWalker`
- `PieceTree::ReferenceSnapshot`
- `PieceTree::OwningSnapshot`
- `PieceTree::Tree::ref_snap(...)`
- `PieceTree::Tree::owning_snap(...)`
- `PieceTree::tree_length(...)`
- `PieceTree::tree_lf_count(...)`

Observed architecture:

- Text is stored as pieces in a red-black tree.
- The tree references original buffers plus a modification buffer.
- Nodes cache length/newline metadata so byte offset, line lookup, and line starts can be computed without flattening the file.
- Tree nodes are ref-counted, which enables cheap snapshots by retaining root nodes.
- Walkers traverse text without materializing the whole document.

### Shared document/buffer manager

Fred coordinates edits through `Editor::BufferManager` in `ed-buffer-manager.cpp`.

Important methods:

- `Editor::BufferManager::insert_buffer(Editor *, CharOffset, basic_string_view *)`
- `Editor::BufferManager::remove_range(Editor *, CharOffset, CharOffset)`
- `Editor::BufferManager::batch_edit(Editor *)`
- `Editor::BufferManager::complete_batch(BatchEdit *)`
- `Editor::BatchEdit::insert_buffer(CharOffset, String8 *)`
- `Editor::BatchEdit::insert_buffer_notify_all(CharOffset, String8 *)`
- `Editor::BatchEdit::remove_range(CharOffset, CharOffset)`
- `Editor::BatchEdit::remove_range_notify_all(CharOffset, CharOffset)`
- `Editor::BufferManager::snap_to(Editor *, UndoRedoNode *, EditCollection *)`
- `Editor::BufferManager::buffer_meta_compute(...)`
- `Editor::BufferManager::buffer_line_guides_compute(...)`
- `Editor::BufferManager::buffer_suggestions_compute(...)`

Observed architecture:

- There is a central manager for shared text state.
- Edits update the piece tree, Tree-sitter state, metadata, line guides, and all registered editors/views.
- Batch editing is a first-class native transaction concept.
- Multiple editors can reference the same underlying text state.

### Cursor, selection, and multi-editing

Fred's editor state lives mostly in `ed.cpp`.

Important methods/types:

- `Editor::Editor::Editor(Atlas *, BufferManager *, ID)`
- `Editor::Editor::insert_buffer(...)`
- `Editor::Editor::insert_char(char)`
- `Editor::Editor::insert_newline()`
- `Editor::Editor::backspace()`
- `Editor::Editor::del()`
- `Editor::Editor::bulk_move_cursors(...)`
- `Editor::anonymous_namespace::alloc_multi_cursor_at(Data *, CursorLocus)`
- `Editor::anonymous_namespace::clear_multi_cursors(Data *)`
- `Editor::anonymous_namespace::merge_multi_cursors(Data *)`
- `Editor::anonymous_namespace::move_cursor(...)`
- `Editor::anonymous_namespace::remove_selection(...)`
- `Editor::anonymous_namespace::insert_multi_cursor_group(Data *, String8Array *)`
- `Editor::anonymous_namespace::overwrite_insert_u8char_impl(...)`
- `Editor::anonymous_namespace::apply_cursor_desired_column(...)`
- `Editor::anonymous_namespace::cursor_line(Data *, CursorLocus)`

Observed architecture:

- Canonical cursor positions are byte offsets (`CharOffset` / `CursorLocus`).
- A cursor has a caret offset, optional selection offset, desired column state, animation/camera metadata, and matching-token metadata.
- Multi-cursor edits are applied through offset-based batch edits, with later cursors adjusted by accumulated deltas.
- Cursors are sorted and merged after multi-edit operations.

### Tree-sitter integration

Fred integrates Tree-sitter in the native edit path.

Important observed calls/methods:

- `ts_tree_edit(...)` in `BufferManager::insert_buffer(...)`
- `ts_tree_edit(...)` in `BufferManager::remove_range(...)`
- `tree_sitter_parse_edit(...)`
- `tree_sitter_parse(...)`
- `Editor::anonymous_namespace::generate_tree_sitter_output<PieceTree::Tree>(...)`
- `Editor::anonymous_namespace::build_editor_text_core(...)`
- `TreeSitter::query_for(...)`
- `ts_query_cursor_set_byte_range(...)`
- `ts_query_cursor_exec(...)`
- `ts_query_cursor_next_capture(...)`

Observed architecture:

- Edits compute Tree-sitter byte/point ranges as part of the native transaction.
- `ts_tree_edit` is called before reparsing.
- Rendering/highlighting queries Tree-sitter captures over the visible byte range instead of relying on a line-local Lua tokenizer.

### Cheap snapshots and undo graph

Fred has two undo-related layers:

- Piece-tree undo helpers in `fredbuf.cpp` such as `PieceTree::Tree::append_undo`, `try_undo`, and `try_redo`.
- Editor-level undo graph in `ed-buffer-manager.cpp` and `undo-graph.cpp`.

Important methods/types:

- `Editor::anonymous_namespace::commit_undo(RegisteredBuffer *, CharOffset)`
- `Editor::BufferManager::snap_to(Editor *, UndoRedoNode *, EditCollection *)`
- `UndoRedoNode`
- `UndoRedoGraph`
- `UndoGraph::Graph::build(...)`

Observed architecture:

- Undo nodes store snapshots of piece-tree roots (`snap_node`).
- Undo history is graph-shaped: nodes have parents and children.
- Moving through history means snapping the current tree root to a stored root and notifying registered editors.
- The undo graph has UI support in `undo-graph.cpp`.

## Comparison against Anvil's current architecture

### Current Anvil text storage

Relevant Anvil file:

```text
data\core\doc\init.lua
```

Important methods:

- `Doc:new(...)`
- `Doc:reset()`
- `Doc:load(filename)`
- `Doc:get_text(...)`
- `Doc:position_offset(...)`
- `Doc:apply_edits(edits, opts)`
- `Doc:raw_insert(...)`
- `Doc:raw_remove(...)`
- `Doc:insert(...)`
- `Doc:remove(...)`
- `Doc:undo()`
- `Doc:redo()`

Current Anvil model:

- Text is stored in `Doc.lines`, an array of Lua strings.
- Lines are the canonical storage unit.
- Positions are line/column byte positions.
- `Doc:apply_edits()` normalizes edits, sorts/rejects overlaps, reconstructs a new line array, maps selections, records inverse edits, updates highlighting/cache, and sends notifications.

Fred model to replace it with:

- Native piece tree.
- Canonical byte offsets.
- Line/column derived from piece-tree metadata.
- Native transaction engine instead of Lua line-array reconstruction.

### Current Anvil selections and Document View state

Relevant Anvil files:

```text
data\core\doc\init.lua
data\core\docview.lua
```

Important methods in `doc/init.lua`:

- `Doc:get_selection(...)`
- `Doc:get_selection_idx(...)`
- `Doc:get_selections(...)`
- `Doc:set_selection(...)`
- `Doc:set_selection_list(...)`
- `Doc:add_selection(...)`
- `Doc:remove_selection(...)`
- `Doc:merge_cursors(...)`
- `Doc:adjust_selection_state_for_insert(...)`
- `Doc:adjust_selection_state_for_remove(...)`
- `Doc:text_input_by_selection(...)`
- `Doc:text_input(...)`

Important methods in `docview.lua`:

- `DocView:new(doc)`
- `DocView:get_selection_state()`
- `DocView:set_selection_state(state)`
- `DocView:capture_selection_state()`
- `DocView:apply_selection_state()`
- `DocView:become_selection_mirror_owner()`
- `DocView.refresh_doc_selection_mirror(doc)`
- `DocView.sync_doc_mirror_owner_state(doc)`

Current Anvil model:

- Selection State is a list of line/column quadruples: `{ line1, col1, line2, col2, ... }`.
- Selection State belongs to the Document View.
- The Document has a compatibility mirror for older command/plugin code.

Fred model to adopt:

- Selection and cursor positions are byte offsets.
- A cursor has caret offset, optional anchor/selection offset, desired column, and related movement state.
- Multi-cursor editing is native and batch-based.

Anvil behavior to preserve conceptually:

- Selection State should remain per Document View, not global to the Document.
- The old Document mirror can be removed as part of the refactor if in-repo callers are migrated.

### Current Anvil undo/redo

Relevant Anvil file:

```text
data\core\doc\init.lua
```

Important functions:

- `push_undo(...)`
- `push_batch_undo(...)`
- `push_selection_undo(...)`
- `pop_undo(...)`
- `Doc:undo()`
- `Doc:redo()`
- `Doc:get_change_id()`
- `Doc:clean()`
- `Doc:is_dirty()`

Current Anvil model:

- Linear undo and redo stacks.
- Batch undo entries store inverse edits and selection snapshots.
- Undo merging is based on `config.undo_merge_timeout`.
- Dirty state is based on the current change id compared with `clean_change_id`.

Fred model to adopt:

- Undo graph with parent/children nodes.
- Each node stores a cheap piece-tree snapshot.
- Dirty state should be based on save node/snapshot identity, not only a linear change id.
- Redo can branch.

### Current Anvil syntax/highlighting/rendering

Relevant Anvil files:

```text
data\core\doc\highlighter.lua
data\core\docview.lua
```

Important methods in `highlighter.lua`:

- `Highlighter:start()`
- `Highlighter:reset()`
- `Highlighter:soft_reset()`
- `Highlighter:insert_notify(line, n)`
- `Highlighter:remove_notify(line, n)`
- `Highlighter:batch_notify(changed_ranges)`
- `Highlighter:tokenize_line(idx, state, resume)`
- `Highlighter:get_line(idx)`
- `Highlighter:each_token(idx, scol)`

Important methods in `docview.lua`:

- `DocView:get_visible_line_range()`
- `DocView:get_col_x_offset(line, col)`
- `DocView:get_x_offset_col(line, xoffset)`
- `DocView:draw_line_text(line, x, y)`
- `DocView:draw_line_body(line, x, y)`
- `DocView:draw()`

Current Anvil model:

- Lua tokenizer/highlighter operates line-by-line.
- DocView renders visible lines using highlighter tokens.
- Rendering and hit-testing are line/column based.

Fred model to adopt:

- Native Tree-sitter parse tree per Document.
- `ts_tree_edit` during edits.
- Query captures over visible byte ranges.
- Native walkers over piece-tree text for rendering and analysis.

## Plans and objectives

The goal is a major refactor of Anvil's text editing core into a Fred-style native Document Core.

Primary objectives:

1. Replace `Doc.lines` as canonical storage with a native piece tree.
2. Use byte offsets as canonical positions internally.
3. Keep line/column as derived UI/API positions only.
4. Move edit application into native batch edit transactions.
5. Move cursor/selection/multi-cursor logic into native code.
6. Add cheap snapshots using ref-counted piece-tree roots.
7. Replace linear undo/redo with a deep branching undo graph.
8. Integrate Tree-sitter natively into the edit/render path.
9. Gradually migrate text-editing Lua commands/plugins into native C code.
10. Remove compatibility adapters and old Lua text-core code once all in-repo callers are migrated.

Non-objectives:

- Preserve the existing `Doc.lines` direct-access API.
- Preserve old Lua text-editing plugin internals.
- Preserve linear-only undo semantics.
- Keep the current Lua highlighter as the primary highlighting architecture.

## Migration order

### Phase 1: Native piece-tree library

Create a focused native text storage library before wiring it into the editor.

Likely files:

```text
src/text/piece_tree.c
src/text/piece_tree.h
tests/native/piece_tree_test.c
```

Implement:

- Original buffer + append-only modification buffer.
- Red-black tree of pieces.
- Ref-counted nodes.
- Cached subtree byte length and newline count.
- `insert(offset, text)`.
- `remove(offset, length)`.
- `node_at_offset(offset)`.
- `line_start(line)`.
- `offset_to_line_col(offset)`.
- `line_col_to_offset(line, col)`.
- `line_count()`.
- `tree_length()`.
- Forward and reverse walkers.
- Snapshot acquire/release.
- Restore snapshot.

Tests:

- Deterministic insert/remove cases.
- CRLF/LF cases.
- UTF-8 byte-preservation cases.
- Random edit fuzz test against a flat-string oracle.
- Snapshot restore tests.
- Line lookup tests after many edits.

Exit criteria:

- Piece tree survives large random edit sequences and exactly matches flat-string output.
- Snapshot restore is cheap and correct.
- Line lookup remains correct after insert/remove edge cases.

### Phase 2: Native Document wrapper

Add a native Document layer around the piece tree.

Likely files:

```text
src/text/native_doc.c
src/text/native_doc.h
src/api/native_doc.c
src/api/native_doc.h
```

Responsibilities:

- File loading and saving.
- Encoding/BOM metadata integration.
- Line ending mode metadata.
- Dirty/save snapshot state.
- Native edit transaction entry points.
- Line/column conversion API for UI boundaries.

Initial public operations:

- `native_doc_new()`.
- `native_doc_load(path)`.
- `native_doc_save(path)`.
- `native_doc_len()`.
- `native_doc_line_count()`.
- `native_doc_get_line(line)`.
- `native_doc_line_col_to_offset(line, col)`.
- `native_doc_offset_to_line_col(offset)`.
- `native_doc_apply_edits(...)`.

Exit criteria:

- Lua can create/load/save/read a native-backed Document.
- Existing Anvil Documents can be experimentally backed by the native core behind a feature flag or temporary branch.

### Phase 3: Replace `Doc.lines` assumptions

Migrate Anvil code away from direct `doc.lines` access.

Current pattern to remove:

```lua
#doc.lines
doc.lines[line]
```

Replacement model:

- Native line count API.
- Native line text API.
- Native offset/position APIs.
- Eventually, direct Lua line access should disappear.

High-risk areas:

- `data/core/docview.lua`
- `data/core/commands/doc.lua`
- find/replace commands
- text-editing plugins under `data/plugins`
- tests that assume `doc.lines`

Exit criteria:

- Main editing UI no longer depends on `Doc.lines` as storage.
- Compatibility mirror APIs are either removed or clearly temporary.

### Phase 4: Native Selection State and multi-cursor model

Move canonical Selection State to native byte-offset cursors.

Proposed cursor shape:

```c
typedef struct NativeCursor {
  uint64_t caret_offset;
  uint64_t anchor_offset;      // UINT64_MAX means no selection
  uint64_t desired_column;     // sentinel when unset
  uint64_t desired_anchor_col; // sentinel when unset
} NativeCursor;
```

Selection ownership:

- Selection State remains owned by the Document View.
- The Document owns text, snapshots, parse state, and undo graph.
- The Document View owns cursors/selections, scroll, viewport, and caret movement state.

Implement native operations:

- Move left/right/up/down.
- Word/chunk movement.
- Selection extension.
- Add/drop/sort/merge cursors.
- Selection removal.
- Multi-cursor insertion.
- Multi-cursor deletion/backspace.
- Desired-column handling.

Exit criteria:

- Core cursor movement and edit commands work without Lua selection mutation logic.
- Multi-cursor insert/delete is native and batch-based.

### Phase 5: Native batch edit transaction engine

Centralize every mutation through one native transaction path.

Transaction input:

```c
typedef struct NativeEdit {
  uint64_t start_offset;
  uint64_t end_offset;
  const char *text;
  size_t text_len;
  uint32_t cursor_index;
} NativeEdit;
```

Transaction output:

- Applied/rejected flag.
- Changed byte ranges.
- Changed line ranges.
- Cursor mapping results.
- Inverse edit list if needed.
- Tree-sitter edit descriptors.
- Undo graph node info.
- View notification payload.

Rules:

- Edits are expressed in old-document coordinates.
- Edits are sorted by start offset.
- Overlaps are rejected or explicitly clipped depending on operation type.
- All text-editing commands go through this path.

Exit criteria:

- Insert, delete, paste, replace, multicursor input, and find/replace share one transaction engine.
- Selection/cursor mapping is native and tested.

### Phase 6: Cheap snapshots and undo graph

Implement persistent snapshots and graph-shaped undo history.

Likely files:

```text
src/text/undo_graph.c
src/text/undo_graph.h
```

Proposed node shape:

```c
typedef struct NativeUndoNode {
  struct NativeUndoNode *parent;
  struct NativeUndoNode *first_child;
  struct NativeUndoNode *last_child;
  struct NativeUndoNode *next_sibling;
  PieceTreeSnapshot snapshot;
  uint64_t op_offset;
  NativeSelectionSnapshot before_selection;
  NativeSelectionSnapshot after_selection;
} NativeUndoNode;
```

Implement:

- Commit edit transaction as child of current node.
- Undo to parent.
- Redo to selected/default child.
- Branch creation after undo.
- Save node tracking.
- Dirty state based on current snapshot/node compared to save node.
- Optional future undo graph UI.

Exit criteria:

- Undo/redo can branch.
- Snapshots restore text without replaying inverse text patches.
- Save/dirty state works with branches.

### Phase 7: Native Tree-sitter integration

Add Tree-sitter after the text core and transaction engine are stable.

Likely files:

```text
src/text/native_treesitter.c
src/text/native_treesitter.h
```

Implement:

- Parser/tree/query state per Document.
- Language selection from filename/content.
- `ts_tree_edit` for transaction edits.
- Reparse once after batch edit.
- Query visible byte range for syntax captures.
- Native APIs for render/highlight spans.

Batch edit strategy:

- Keep transaction edits in old-document coordinates.
- Apply `ts_tree_edit` in a deterministic transformed order.
- Reparse once after all edit descriptors are applied.
- Prefer correctness over cleverness initially; add optimized multi-edit handling after tests are solid.

Exit criteria:

- Tree-sitter parse updates correctly after inserts/removes/multicursor edits.
- Visible-range syntax captures can replace Lua highlighter output.

### Phase 8: Native text-editing commands and plugin migration

Move text-editing behavior from Lua into native C modules.

Candidate areas:

- Text input.
- Backspace/delete.
- Word/chunk movement.
- Line movement.
- Indentation/unindentation.
- Duplicate/delete line.
- Find/replace edits.
- Multicursor commands.
- Search selections.
- Line guides.
- Syntax-aware features.

Lua can remain for command registration/config/UI glue if useful, but text mutation and selection logic should live in native code.

Exit criteria:

- Lua plugins no longer own core editing semantics.
- In-repo text-editing callers are migrated to native commands/APIs.
- Old Lua `Doc` text core can be deleted.

## Key design decisions

These decisions are accepted for the refactor.

### Canonical position type

Decision:

- Use byte offsets internally as the canonical position type.
- Line/column positions are derived boundary/API/UI values.

Rationale:

- Matches Fred's `CharOffset` / `CursorLocus` model.
- Simplifies native piece-tree operations.
- Fits Tree-sitter, which is byte-range oriented.
- Makes multi-edit delta adjustment more direct.

### Line endings

Decision:

- Store raw bytes and handle LF/CRLF explicitly.
- Preserve line-ending behavior through native APIs.
- Provide CRLF-aware line start/end helpers.

Rationale:

- Fred has explicit CRLF-aware paths such as `line_end_crlf` and `accumulate_value_no_lf`.
- Avoids hidden normalization surprises.
- Allows correct byte offsets for Tree-sitter and file output.

### Invalid UTF-8 and binary content

Decision:

- Native text storage must be byte-safe.
- UTF-8 helpers are layered on top of byte storage.
- Invalid UTF-8 should not corrupt the document or prevent byte-preserving save.

Rationale:

- Current Anvil has `binary` and `clean_lines` fallback behavior.
- The native core should preserve bytes even when display sanitization is needed.

### Undo semantics

Decision:

- Build graph-first undo/redo, not a compatibility wrapper around linear stacks.
- Dirty state should track save node/snapshot identity.
- Redo branching is allowed.

Open policy details to decide during implementation:

- Which child redo chooses by default when multiple children exist.
- Whether selection-only moves create undo graph nodes.
- How typing merge windows update the current undo node.
- How undo graph UI should expose branches.

### View ownership of Selection State

Decision:

- Preserve Anvil's user-facing rule that Selection State belongs to a Document View.
- Move the representation from line/column quadruples to native byte-offset cursors.

Rationale:

- This keeps split-editor behavior conceptually clean.
- It aligns with Fred's per-editor cursor state over shared text.
- The Document should not globally own one canonical selection.

### Compatibility policy

Decision:

- Prefer clean replacement over compatibility adapters.
- Direct `Doc.lines` access and Lua-owned text mutation should be removed as part of the migration.

Rationale:

- This is a major first-party refactor.
- Carrying both text cores would make correctness and testing harder.
- In-repo callers can be migrated together.
