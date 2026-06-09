# Native Document Core From-Scratch Plan

## Direction change

The refactor is no longer framed as a gradual rewrite of Anvil's current Lua `Doc`.

The goal is to build a new Fred-style native text editor core from almost scratch, beside the existing Anvil editor, and only reuse Anvil's windowing/rendering/input shell when the new core is ready for UI experiments.

Important naming note for Anvil code and docs:

- Use **Document / Doc** for Anvil's in-memory editable text.
- Avoid introducing **Buffer** as the Anvil-facing term. Fred uses buffer terminology internally, but Anvil's glossary reserves Document/Doc.

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

Do not paste decompiled Fred code into Anvil. Reimplement the architecture, behavior, and invariants cleanly in Anvil-owned C code, with tests as the executable specification.

## What we learned from Fred

Fred's text editing architecture is a native C++ editor core centered on:

- a persistent piece-tree text store
- a shared native document/text-state manager
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
- Walkers traverse text without materializing the whole Document.

### Native document coordination

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
- Text can be streamed from the piece tree into Tree-sitter without flattening the whole Document.

### Cheap snapshots and undo graph

Fred has piece-tree snapshots plus an editor-level undo graph.

Observed architecture:

- Undo nodes store snapshots of piece-tree roots.
- Undo history is graph-shaped: nodes have parents and children.
- Moving through history means restoring a stored root and notifying registered views.
- Redo can branch.

## New architecture to build

Build a new native stack beside the old Lua `Doc` stack:

```text
src/text/piece_tree.c/.h       low-level text storage
src/text/native_doc.c/.h       shared Document text state, file metadata, transactions
src/text/native_editor.c/.h    per-view cursor/selection/editing state
src/text/undo_graph.c/.h       graph-shaped undo/redo snapshots
src/text/native_treesitter.*   later Tree-sitter integration
src/api/native_doc.c/.h        later Lua/API bridge for sandbox UI
```

Initial UI integration should be a sandbox/experimental native-backed Document View, not a compatibility layer for the existing Lua `Doc`.

## Core decisions

### Canonical coordinates

- Native text offsets are **0-based byte offsets**.
- Native line indexes are **0-based**.
- Native columns are **0-based byte columns from the line start**.
- Lua-facing/UI compatibility APIs may translate to Anvil's existing 1-based line/column conventions later.
- Visual columns, grapheme movement, tabs, and wrapping are view-layer concepts, not canonical storage coordinates.

### Document text bytes

- The native piece tree stores bytes.
- The first implementation should preserve byte sequences exactly.
- Encoding detection/conversion and display sanitization are layered above raw storage.
- Before replacing the old editor, decide whether loaded non-UTF-8 files are converted to internal UTF-8 or kept as original bytes. The piece tree must support both.

### Line endings

- Store raw bytes.
- Count LF (`\n`) as the primary line separator.
- Preserve CRLF bytes exactly.
- Add explicit CRLF-aware helpers for operations that need logical line ends.

### Selection State ownership

- Selection State remains owned by a Document View / native editor view state.
- The shared Document owns text, file metadata, parse state, and the undo graph.
- Undo selection snapshots must be associated with the editing view that created the transaction, not treated as one global Document selection.

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

Once the sandbox is strong enough, switch Anvil's primary editor to the native Document core and delete the old Lua text core instead of maintaining long-term adapters.

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

- Forward and reverse walkers.
- CRLF-aware line start/end helpers.
- Better balancing/invariant diagnostics if needed.

Tests:

- Deterministic insert/remove cases.
- Empty Document and EOF edge cases.
- LF and CRLF byte-preservation cases.
- UTF-8 byte-preservation cases.
- Invalid UTF-8 byte-preservation cases.
- Random edit fuzz tests against a flat-string oracle.
- Snapshot restore tests.
- Line lookup tests after many edits.

Exit criteria:

- Piece tree survives large random edit sequences and exactly matches the flat-string oracle.
- Snapshot restore is cheap and correct.
- Line lookup remains correct after insert/remove edge cases.

## Phase 2: Native Document shell

Likely files:

```text
src/text/native_doc.c
src/text/native_doc.h
```

Responsibilities:

- Own a piece tree.
- Track file path and file metadata.
- Track dirty/save snapshot identity.
- Provide read APIs needed by rendering and tests.
- Provide one transaction entry point for edits.

Initial public operations:

- `native_doc_new()`
- `native_doc_free()`
- `native_doc_load_bytes(...)`
- `native_doc_len()`
- `native_doc_line_count()`
- `native_doc_get_line(...)`
- `native_doc_line_col_to_offset(...)`
- `native_doc_offset_to_line_col(...)`
- `native_doc_apply_edits(...)`

Exit criteria:

- Native tests can create, edit, snapshot, save-state mark, and inspect a Document without Lua.

## Phase 3: Native editor/view state

Likely files:

```text
src/text/native_editor.c
src/text/native_editor.h
```

Implement:

- Cursor array owned by native editor/view state.
- Caret offset.
- Optional anchor offset.
- Desired column state.
- Cursor sort/merge.
- Move left/right/up/down.
- Select variants of movement.
- Remove selections.
- Insert text at one or many cursors.
- Backspace/delete.

Exit criteria:

- Native tests can drive core editing behavior without Lua selection mutation logic.
- Multi-cursor edits are native and batch-based.

## Phase 4: Native transaction engine

Centralize every mutation through one native transaction path.

Transaction input shape:

```c
typedef struct NativeEdit {
  uint64_t start_offset;
  uint64_t end_offset;
  const char *text;
  size_t text_len;
  uint32_t cursor_index;
} NativeEdit;
```

Transaction output should include:

- Applied/rejected flag.
- Changed byte ranges.
- Changed line ranges.
- Cursor mapping results.
- Tree-sitter edit descriptors later.
- Undo graph node info later.
- View notification payload later.

Rules:

- Edits are expressed in old-Document coordinates.
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

- Commit edit transaction as child of current undo node.
- Undo to parent.
- Redo to selected/default child.
- Branch creation after undo.
- Save node tracking.
- Dirty state based on current node/snapshot compared to save node.
- Selection snapshots associated with the editing view.

Policy decisions to settle before implementation:

- Which child redo chooses by default when multiple children exist.
- Whether selection-only moves create undo graph nodes.
- How typing merge windows update the current undo node.
- How undo graph UI should expose branches.

Exit criteria:

- Undo/redo can branch.
- Snapshots restore text without replaying inverse text patches.
- Save/dirty state works with branches.

## Phase 6: Tree-sitter integration

Likely files:

```text
src/text/native_treesitter.c
src/text/native_treesitter.h
```

Implement after the text core and transaction engine are stable:

- Parser/tree/query state per Document.
- Language selection from filename/content.
- `ts_tree_edit` for transaction edits.
- Reparse once after batch edit.
- Query visible byte range for syntax captures.
- Native APIs for render/highlight spans.

Exit criteria:

- Tree-sitter parse updates correctly after inserts/removes/multicursor edits.
- Visible-range syntax captures can replace Lua highlighter output in the sandbox view.

## Phase 7: Sandbox Document View using Anvil rendering

Build an experimental native-backed Document View that uses Anvil's renderer/window/input infrastructure but not the old Lua `Doc` internals.

Initial sandbox features:

- Open a native Document from bytes/file.
- Draw visible lines from piece-tree walkers.
- Basic caret rendering.
- Basic keyboard text input.
- Basic mouse hit testing.
- Scroll.
- Undo/redo.

Exit criteria:

- The sandbox is usable as a small text editor.
- Bugs are fixed in native tests first whenever possible.

## Phase 8: Replace old editor

Only after the sandbox is robust:

- Switch primary editor creation to the native Document stack.
- Migrate required first-party commands/plugins to native APIs or new Lua glue.
- Delete old Lua text-core code and direct `Doc.lines` assumptions.
- Keep Anvil's rendering/UI shell and user-facing app concepts.

Exit criteria:

- The old Lua `Doc` text storage/mutation path is gone.
- The native Document core is the only editing core.
