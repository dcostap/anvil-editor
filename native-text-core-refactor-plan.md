# Native Buffer Core From-Scratch Plan

## Direction change

The refactor is no longer framed as a gradual rewrite of Anvil's current Lua `Doc`.

The goal is to build a new Fred-style native text editor core from almost scratch, beside the existing Anvil editor, and only reuse Anvil's windowing/rendering/input shell when the new core is ready for UI experiments.

Vocabulary decision for the new core:

- Use Fred's vocabulary for the new native core, even where it differs from the existing Anvil editor model.
- Use **Buffer** for the shared editable text state.
- Use **Buffer Manager** for the coordinator that owns shared Buffer state and applies edits.
- Use **Editor** for per-view editing state over a Buffer.
- Keep **Document / Doc** for the existing Lua editor model until that model is replaced.

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

Fred's recovered/decompiled sources are the golden reference and source of truth for the new native core's vocabulary, architecture, and behavior. Refer back to them during development rather than inventing Anvil-specific substitutes. Do not paste decompiled Fred code into Anvil; reimplement the architecture, behavior, and invariants cleanly in Anvil-owned C code, with tests as the executable specification.

## What we learned from Fred

Fred's text editing architecture is a native C++ editor core centered on:

- a persistent piece-tree text store
- a shared native Buffer Manager
- byte-offset cursors
- native multi-cursor editing
- incremental Tree-sitter integration
- cheap snapshots through retained tree roots
- graph-shaped undo/redo

### Text storage: piece tree

Fred stores text in `PieceTree::Tree` in `fredbuf.cpp`.

Important recovered methods/types:

- `PieceTree::Tree::insert(CharOffset, String8 *, SuppressHistory)`
- `PieceTree::Tree::internal_insert(CharOffset, String8 *)`
- `PieceTree::Tree::internal_remove(CharOffset, Length)`
- `PieceTree::Tree::node_at(BufferCollection *, RedBlackTree, CharOffset)`
- `PieceTree::Tree::line_start(...)`
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

- Text is stored as pieces in a tree.
- The tree references original file text plus append-only modification text.
- Nodes cache subtree byte length and newline metadata.
- Byte offset lookup, line lookup, and line starts are derived from metadata instead of flattening the file.
- Tree roots/nodes can be retained for cheap snapshots.
- Walkers traverse text without materializing the whole Buffer.
- Range extraction can be built on walkers for rendering/search without requiring whole-buffer flattening. **Implemented initially.**

### Native Buffer coordination

Fred coordinates edits through `Editor::BufferManager` in `ed-buffer-manager.cpp`.

Important methods:

- `Editor::BufferManager::insert_buffer(Editor *, CharOffset, basic_string_view *)`
- `Editor::BufferManager::remove_range(Editor *, CharOffset, CharOffset)`
- `Editor::BufferManager::batch_edit(Editor *)`
- `Editor::BufferManager::complete_batch(BatchEdit *)`
- `Editor::BatchEdit::insert_buffer(CharOffset, String8 *)`
- `Editor::BatchEdit::remove_range(CharOffset, CharOffset)`
- `Editor::BufferManager::snap_to(Editor *, UndoRedoNode *, EditCollection *)`

Observed architecture:

- A central native owner coordinates shared text state.
- Edits update the piece tree, Tree-sitter state, metadata, and registered views.
- Batch editing is a first-class transaction concept.
- Multiple views can reference the same underlying text state while keeping separate cursor/selection state.

### Cursor, Selection State, and multi-editing

Fred's editor state lives mostly in `ed.cpp`.

Important methods/types:

- `Editor::Editor::insert_buffer(...)`
- `Editor::Editor::insert_char(char)`
- `Editor::Editor::insert_newline()`
- `Editor::Editor::backspace()`
- `Editor::Editor::del()`
- `Editor::Editor::bulk_move_cursors(...)`
- multi-cursor allocation, clearing, sorting, and merging helpers
- selection removal and multi-cursor insertion helpers
- desired-column helpers

Observed architecture:

- Canonical cursor positions are byte offsets.
- A cursor has a caret offset, optional selection anchor, desired column state, and view/camera metadata.
- Multi-cursor edits are applied through offset-based batch edits.
- Later cursors are adjusted by accumulated edit deltas.
- Cursors are sorted and merged after multi-edit operations.

### Tree-sitter integration

Fred integrates Tree-sitter in the native edit path.

Observed architecture:

- Edits compute Tree-sitter byte/point ranges as part of the native transaction.
- `ts_tree_edit` is called before reparsing.
- Rendering/highlighting queries captures over visible byte ranges.
- Text can be streamed from the piece tree into Tree-sitter without flattening the whole Buffer.

### Cheap snapshots and undo graph

Fred has piece-tree snapshots plus an editor-level undo graph.

Observed architecture:

- Undo nodes store snapshots of piece-tree roots.
- Undo history is graph-shaped: nodes have parents and children.
- Moving through history means restoring a stored root and notifying registered views.
- Redo can branch.

## New architecture to build

Build a new native Fred-vocabulary stack beside the old Lua `Doc` stack:

```text
src/text/piece_tree.c/.h       low-level text storage
src/text/buffer.c/.h           shared Buffer text state and file metadata
src/text/buffer_manager.c/.h   transaction coordinator for shared Buffer state
src/text/editor.c/.h           per-view cursor/selection/editing state over a Buffer
src/text/undo_graph.c/.h       graph-shaped undo/redo snapshots
src/text/treesitter.*          later Tree-sitter integration
src/api/native_text.c          initial Lua/API bridge for sandbox UI
```

Initial UI integration should be a sandbox/experimental native-backed Buffer/Editor view, not a compatibility layer for the existing Lua `Doc`.

## Core decisions

### Canonical coordinates

- Native Buffer offsets are **0-based byte offsets**.
- Native line indexes are **0-based**.
- Native columns are **0-based byte columns from the line start**.
- Lua-facing/UI compatibility APIs may translate to Anvil's existing 1-based line/column conventions later.
- Visual columns, grapheme movement, tabs, and wrapping are view-layer concepts, not canonical storage coordinates.

### Buffer text bytes

- The native piece tree stores bytes.
- The first implementation should preserve byte sequences exactly.
- Encoding detection/conversion and display sanitization are layered above raw storage.
- Before replacing the old editor, decide whether loaded non-UTF-8 files are converted to internal UTF-8 or kept as original bytes. The piece tree must support both.

### Line endings

- Store raw bytes.
- Count LF (`\n`) as the primary line separator.
- Preserve CRLF bytes exactly.
- Add explicit CRLF-aware helpers for operations that need logical line ends.
- Track initial Buffer line-ending mode from loaded bytes and use it for native newline insertion, multi-selection joins, and line-ending unification. **Implemented initially.**

### Selection State ownership

- Selection State remains owned by an Editor / native per-view state.
- The shared Buffer owns text, file metadata, parse state, and the undo graph.
- Undo selection snapshots must be associated with the editing view that created the transaction, not treated as one global Buffer selection.

### Compatibility policy

- Do not preserve direct `Doc.lines` access in the new core.
- Do not make the old Lua `Doc` the migration target.
- Keep the old editor running while the new native core matures beside it.
- Replace the old text editor only when the native core plus sandbox UI is robust enough.

## Development strategy

### Track A: Native core, test-first

This is the main workstream. Native tests define correctness before UI wiring.

### Track B: Minimal sandbox UI

Only after core editing invariants are solid, add an experimental view using Anvil's renderer/input primitives.

### Track C: Replacement

Once the sandbox is strong enough, switch Anvil's primary editor to the native Buffer core and delete the old Lua text core instead of maintaining long-term adapters.

## Phase 1: Piece-tree library

Likely files:

```text
src/text/piece_tree.c
src/text/piece_tree.h
tests/native/piece_tree_test.c
```

Implement first:

- Original byte storage.
- Append-only modification byte storage.
- Tree of pieces referencing original/add storage.
- Cached subtree byte length and LF count.
- Insert by byte offset.
- Remove by byte range.
- Flatten/debug text extraction for tests.
- Offset-to-line/column conversion.
- Line/column-to-offset conversion.
- Line count.
- Tree length.
- Snapshot acquire/release.
- Snapshot restore.

Then add:

- Forward and reverse walkers. **Implemented initially.**
- CRLF-aware line start/end helpers. **Implemented initially through line range helpers.**
- Better balancing/invariant diagnostics if needed.

Tests:

- Deterministic insert/remove cases.
- Empty Buffer and EOF edge cases.
- LF and CRLF byte-preservation cases.
- UTF-8 byte-preservation cases.
- Invalid UTF-8 byte-preservation cases.
- Random edit fuzz tests against a flat-string oracle. **Implemented initially.**
- Snapshot restore tests.
- Line lookup tests after many edits. **Implemented in the random edit oracle.**
- CRLF-aware line range tests. **Implemented initially.**

Exit criteria:

- Piece tree survives large random edit sequences and exactly matches the flat-string oracle.
- Snapshot restore is cheap and correct.
- Line lookup remains correct after insert/remove edge cases.

## Phase 2: Native Buffer shell

Likely files:

```text
src/text/buffer.c
src/text/buffer.h
src/text/buffer_manager.c
src/text/buffer_manager.h
```

Responsibilities:

- Own a piece tree.
- Track file path and file metadata. **Initial owned path storage implemented.**
- Track dirty/save snapshot identity.
- Provide read APIs needed by rendering and tests. **Initial line and byte-range reads implemented.**
- Provide one transaction entry point for edits.

Initial public operations:

- `buffer_new()`
- `buffer_free()`
- `buffer_load_bytes(...)`
- `buffer_load_file(...)` **Implemented initially.**
- `buffer_save_file(...)` **Implemented initially.**
- `buffer_len()`
- `buffer_line_count()`
- `buffer_get_line(...)`
- `buffer_line_col_to_offset(...)`
- `buffer_offset_to_line_col(...)`
- `buffer_manager_apply_edits(...)`

Exit criteria:

- Native tests can create, edit, snapshot, save-state mark, inspect a Buffer without Lua, and preserve basic line-ending mode behavior.

## Phase 3: Editor state

Likely files:

```text
src/text/editor.c
src/text/editor.h
```

Implement:

- Cursor array owned by native editor/view state. **Implemented initially.**
- Caret offset. **Implemented initially.**
- Optional anchor offset. **Implemented initially.**
- Desired column state. **Implemented initially for line movement.**
- Cursor sort/merge. **Implemented initially.**
- Move left/right/up/down. **Implemented initially.**
- Word left/right. **Implemented initially with Fred-style byte-category boundaries.**
- Select variants of movement. **Implemented initially for character, line, and word movement.**
- Remove selections. **Implemented initially.**
- Select word. **Implemented initially.**
- Select line. **Implemented initially with CRLF-aware line ranges.**
- Selection readback and clipboard-shaped copy/cut/paste primitives. **Implemented initially for single and multi-selection.**
- Insert text at one or many cursors. **Implemented initially.**
- Open line above/below with Buffer line-ending mode and first-pass leading-indent preservation. **Implemented initially.**
- Backspace/delete. **Implemented initially.**
- Backspace word/delete word. **Implemented initially.**
- Delete line. **Implemented initially, including selected line spans and merged multi-cursor line ranges.**
- Move line up/down for the core cursor or selected line span. **Implemented initially.**
- Join line below with CRLF-aware line ranges and Fred-style leading-space trim. **Implemented initially.**
- Tab/untab with Fred default tab-byte indentation behavior. **Implemented initially.**
- First-nonempty-of-line, home-toggle-of-line, and empty-line up/down movement. **Implemented initially.**
- Duplicate cursor up/down. **Implemented initially with Fred-style moved core cursor behavior.**
- Unify line endings to the Buffer's selected line-ending mode. **Implemented initially.**

Exit criteria:

- Native tests can drive core editing behavior without Lua selection mutation logic.
- Multi-cursor edits are native and batch-based.

## Phase 4: Buffer Manager transaction engine

Centralize every mutation through one Buffer Manager transaction path.

Batch edit input shape:

```c
typedef struct BatchEditItem {
  uint64_t start_offset;
  uint64_t end_offset;
  const char *text;
  size_t text_len;
  uint32_t cursor_index;
} BatchEditItem;
```

Transaction output should include:

- Applied/rejected flag. **Implemented initially.**
- Changed byte ranges. **Implemented initially.**
- Changed line ranges. **Implemented initially as half-open byte-derived line ranges.**
- Cursor mapping results. **Implemented initially.**
- Tree-sitter-style edit descriptors. **Initial byte/point descriptors implemented in BatchEditResult.**
- Undo graph node transition info. **Implemented initially in edit/snap results.**
- View notification payload later. **Initial source-aware listener callbacks implemented for native Editor propagation.**

Rules:

- Edits are expressed in pre-edit Buffer coordinates.
- Edits are sorted by start offset.
- Overlaps are rejected unless an operation explicitly opts into clipping.
- All text-editing commands go through this path.

Exit criteria:

- Insert, delete, paste, replace, multi-cursor input, and find/replace share one transaction engine.

## Phase 5: Cheap snapshots and undo graph

Likely files:

```text
src/text/undo_graph.c
src/text/undo_graph.h
```

Implement:

- Commit edit transaction as child of current undo node. **Implemented initially.**
- Undo to parent. **Implemented initially.**
- Redo to selected/default child. **Implemented initially; default redo follows Fred's newest/last child behavior.**
- Branch creation after undo. **Implemented initially.**
- Save node tracking. **Implemented initially.**
- Dirty state based on current node/snapshot compared to save node. **Implemented initially with Fred-style node identity tracking.**
- Update current undo snapshot for coalesced/native operations. **Implemented initially.**
- Snap to arbitrary undo graph nodes. **Implemented initially at UndoGraph/Buffer/BufferManager layers.**
- Selection snapshots associated with the editing view. **Implemented initially across primary cursor edits and direct line/indent/line-ending commands; undo/redo still clears multi-cursors Fred-style when no stored snapshot applies.**

Policy decisions to settle before implementation:

- Whether selection-only moves create undo graph nodes.
- How typing merge windows update the current undo node. **Initial contiguous single-cursor insert coalescing implemented.**
- How undo graph UI should expose branches.
- How snap-to should propagate diff edits through registered native Editor views; Fred updates registered editors from diff records in `BufferManager::snap_to`. **Initial registered Editor propagation implemented for edit and snap paths.**

Exit criteria:

- Undo/redo can branch.
- Snapshots restore text without replaying inverse text patches.
- Save/dirty state works with branches.

## Phase 6: Tree-sitter integration

Likely files:

```text
src/text/treesitter.c
src/text/treesitter.h
```

Implement after the text core and transaction engine are stable:

- Parser/tree/query state per Buffer.
- Language selection from filename/content.
- `ts_tree_edit` for transaction edits. **Initial transaction descriptors are available; actual Tree-sitter integration still pending.**
- Reparse once after batch edit.
- Query visible byte range for syntax captures.
- Native APIs for render/highlight spans.

Exit criteria:

- Tree-sitter parse updates correctly after inserts/removes/multicursor edits.
- Visible-range syntax captures can replace Lua highlighter output in the sandbox view.

## Phase 7: Sandbox Buffer/Editor view using Anvil rendering

Build an experimental native-backed Buffer/Editor view that uses Anvil's renderer/window/input infrastructure but not the old Lua `Doc` internals.

Initial sandbox/API features:

- Lua `native_text` module for creating native Buffers and Editors. **Initial bridge implemented.**
- Open a native Buffer from bytes/file. **Initial in-memory and file-backed sandbox commands implemented.**
- Draw visible lines from piece-tree walkers. **Initial sandbox draws through native Buffer line reads; direct walker-backed drawing still pending.**
- Basic caret rendering. **Initial sandbox implemented, including multi-cursor carets.**
- Basic selection rendering. **Initial sandbox implemented.**
- Basic keyboard text input. **Initial sandbox implemented, including word, line-edge, and Buffer-edge movement bindings.**
- Basic mouse hit testing. **Initial sandbox implemented.**
- Scroll. **Initial sandbox implemented.**
- Undo/redo. **Initial sandbox commands implemented.**
- Save file-backed native Buffers. **Initial sandbox command implemented.**

Exit criteria:

- The sandbox is usable as a small text editor.
- Bugs are fixed in native tests first whenever possible.

## Phase 8: Replace old editor

Only after the sandbox is robust:

- Switch primary editor creation to the native Buffer stack.
- Migrate required first-party commands/plugins to native APIs or new Lua glue.
- Delete old Lua text-core code and direct `Doc.lines` assumptions.
- Keep Anvil's rendering/UI shell and user-facing app concepts.

Exit criteria:

- The old Lua `Doc` text storage/mutation path is gone.
- The native Buffer core is the only editing core.
