# Native Editor Replacement Plan

## Purpose

This plan starts the next phase after the native Buffer/Editor/Tree-sitter foundation work. The goal is to move from an experimental native-backed sandbox toward replacing Anvil's current Lua `Doc`/`DocView` editing path with the Fred-style native core.

This is not a plan to preserve the Lua `Doc` API indefinitely. The intended direction remains:

1. Keep the current Lua editor working while the native editor becomes complete enough to dogfood.
2. Promote native Buffer/Editor behavior behind a real editor view.
3. Replace the default editor creation path.
4. Delete the old Lua text storage/mutation stack when it is no longer needed.

The user is also considering how far the application should move toward C versus Lua. The current strategic answer is not an immediate pure-C rewrite. Anvil should first become a native-core editor with a Lua extension/configuration shell. C should own durable editor state, text mutation, undo/redo, parsing, search/replace over large Buffers, cursor normalization, and other performance-critical or correctness-critical mechanics. Lua can remain valuable for non-core-text-editing behavior such as commands, keybindings, prompt flows, project/file-tree behavior, default configuration, non-hot-path plugins, and fast UI experimentation.

This plan therefore avoids building new long-term Lua abstractions around the old `Doc` model, but it does not require deleting Lua from the whole application. The intended split is: C owns the native Buffer/Editor core and efficient editor primitives; Lua orchestrates app-shell behavior and customization through explicit native capabilities. If Lua later proves to be architectural drag for a specific subsystem, that subsystem can be migrated to C after the native editor path is stable.

## Vocabulary

Use the Fred vocabulary for the new native core:

- **Buffer**: shared editable text state, file path/dirty state, undo graph, parse state.
- **Buffer Manager**: central coordinator for applying text transactions to a Buffer.
- **Editor**: per-view cursor, selection, and editing state over a Buffer.

Keep **Document / Doc** only for Anvil's existing Lua editor until replacement.

## Fred reference notes

The native replacement is intentionally Fred-style. Fred's recovered/decompiled sources remain the golden reference for the native core's vocabulary, architecture, behavior, and invariants. Refer back to them during development rather than inventing Anvil-specific substitutes when an equivalent Fred concept already exists.

Fred decomp location:

```text
C:\Projects\my_decomps\fred_src_dump
```

Most relevant recovered source roots:

```text
C:\Projects\my_decomps\fred_src_dump\D_\git_projects\fred\src
C:\Projects\my_decomps\fred_src_dump\D_\git_projects\fred\inc
```

Key files to consult when extending or debugging the native core:

- `D_\git_projects\fred\src\fredbuf.cpp` — piece tree text storage, walkers, snapshots, line helpers.
- `D_\git_projects\fred\src\ed.cpp` — Editor cursor/selection/editing behavior.
- `D_\git_projects\fred\src\ed-buffer-manager.cpp` — Buffer Manager transactions, registered editor propagation, snap-to behavior.
- `D_\git_projects\fred\src\undo-graph.cpp` — graph-shaped undo/redo behavior.
- `D_\git_projects\fred\inc\undo-data.h` — undo data structures and invariants.
- `D_\git_projects\fred\src\basic-textedit.cpp` — baseline text editing behavior.

Guidelines:

- Use Fred as the behavioral and architectural reference for native Buffer/Buffer Manager/Editor/undo decisions.
- Do not paste decompiled Fred code into Anvil.
- Reimplement the architecture, behavior, and invariants cleanly in Anvil-owned C code.
- Prefer tests as the executable specification for Fred-inspired behavior.
- When behavior is unclear, inspect Fred first, then adapt only where Anvil has an intentional reason to differ.
- Record intentional deviations in this plan or nearby implementation comments when they affect future maintenance.

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
- Lua-facing file Buffer registry keyed by normalized path identity so native views can share file-backed Buffers instead of creating conflicting independent Buffers.
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

- `data/plugins/native_editor.lua` canonical plugin and Lua-hosted native editor view implementation.
- `data/plugins/native_text_sandbox.lua` legacy module shim retained only for old workspace/plugin references.
- `native_text` Lua bridge in `src/api/native_text.c`.
- `native-editor:open` (`native-text-sandbox:open` alias during transition)
- `native-editor:open-file` (`native-text-sandbox:open-file` alias during transition)
- `native-editor:save` (`native-text-sandbox:save` alias during transition)
- File-backed native Buffers.
- Dirty marker in tab title.
- Visible line rendering from native walkers.
- Tree-sitter highlighting.
- Multiple carets.
- Selection rendering.
- Basic mouse placement.
- Mouse drag selection, shift-click selection extension, double-click word selection, and triple-click line selection.
- Typing/editing.
- Movement shortcuts, duplicate cursor shortcuts, page movement, and go-to-line.
- Find next/previous, replace current match, and replace all.
- Clipboard copy/cut/paste.
- Save-as, dirty close/quit prompts, external reload prompts, save-conflict prompts, duplicate-open focusing, and native file Buffer registry reuse.
- Current-line highlight, horizontal scroll-to-cursor, status bar file/position/line-ending items, and recent/visited tracking.
- Workspace-style `get_state` / `from_state` serialization.
- Runtime coverage for saving and restoring native editor views through `workspace.lua` split/tab state.
- Undo/redo.
- Canonical `native-editor:*` command names for native editor behavior, routed through a native-editor view capability predicate, with `native-text-sandbox:*` aliases kept only as transition compatibility.
- `core.open_native_editor_file(filename)` facade for opening file-backed native editor views without calling sandbox-local helpers.
- Dynamic opt-in `core.open_file` routing through native editor when `config.plugins.native_editor.default_open` is enabled.
- Canonical workspace/plugin module name `plugins.native_editor`; old `plugins.native_text_sandbox` is kept as a transition module alias.
- Generic core helpers for file-backed views (`core.view_file_path`, `core.view_is_dirty`) now understand native editor Buffers as well as old DocViews.
- Generic close confirmation (`core.confirm_close_views`) can prompt for dirty native editor Buffers, and root close-all commands use it instead of assuming all dirty state lives in `core.docs`.
- Forced view-tree close paths call view close hooks so native file Buffer registry entries are released when native editor views are removed by close-all/project-switch flows.

Important status:

- Sandbox is usable for manual testing.
- Sandbox is still Lua-owned UI glue, not the final replacement editor.
- Native editor commands now have a non-sandbox namespace, but normal `doc:*` command routing remains intentionally separate until the default editor path is stable.
- The native file-open implementation is exposed through a core facade, and `core.open_file` dynamically uses it when native default-open is enabled. The first-party default now enables native default-open for hands-on dogfooding.
- Native editor workspace state now saves under canonical `plugins.native_editor` module name; old sandbox module remains loadable for transition restore.
- Core project/title/visited-file helpers can now see native editor Buffer paths instead of assuming every file-backed editor view has `view.doc.abs_filename`.
- Root close-all / close-all-others now use view-level dirty confirmation so native editor views are included in unsaved-change prompts, including the `core.file_context` close-all-others override.
- Fuzzy searcher accepted file/grep results can set cursor/selection in native editor views opened by native default-open.
- Generic `core.set_view_selection` supports both old DocViews and native editor views; find-file and project-search result navigation use it for native editor compatibility.
- Edit-location history records native editor edits and restores native editor file positions through the default open path.
- First-party default keymap fallbacks now prefer native editor find/replace/save/go-to-line commands while preserving old DocView command fallback.
- IPC open-file and tab-drag handoff paths route through generic file-backed views / `core.open_file`, so native editor default-open applies across single-instance and drag/drop flows.
- Native Buffer paths can be updated without saving (`buffer:set_path`), and filetree rename flows update open native editor Buffer paths/registry identities.
- Side/main panel file-opening and IntelliJ-style navigation history restore through `core.open_file` / generic selection so native default-open applies there too.
- User/project module opens and native-editor file dialog accepts now route through `core.open_file`, preserving default native routing and non-text special cases.
- Native default-open now covers missing files and unnamed scratch buffers: new named files open as dirty native Buffers, and `core:new-doc` opens a native scratch Buffer while native default-open is enabled.
- Autosave focus/idle paths can save dirty native editor Buffers through `core.save_native_editor_view`, while preserving protected-file exclusions.
- Workspace save/restore now has runtime coverage for native editor views in split layouts.

## Current strategic direction

The next work should stop treating Tree-sitter as the main project. The next milestone is native editor replacement readiness.

The strategic target is a **native-core editor with a Lua extension/configuration shell**, not a big-bang pure-C rewrite. The practical boundary is ownership: C owns the Buffer, Buffer Manager, Editor, undo graph, Tree-sitter state, search/replace helpers, and hot view/rendering primitives; Lua owns orchestration, commands, keybindings, prompts, settings, project/file-tree flows, and first-party plugins unless those paths become performance-critical or correctness-critical.

Do not preserve the old Lua `Doc` API as a long-term compatibility layer. In particular, avoid rebuilding `Doc.lines` or old selection structures on top of the native core. If a plugin needs old internals, either port it to native capabilities, keep it as temporary transition glue, or deprecate/archive it out of the supported load path.

First-party Lua plugins that implement behavior belonging in the native editor core should not be adapted around old Lua editor internals. Classify them explicitly instead: keep in Lua when they are app orchestration/customization, port to native capability APIs when Lua should only request or configure the behavior, port fully into C/native core when the behavior is durable editor mechanics, keep temporary glue only with a removal target, or deprecate/archive the plugin so it is no longer loaded or supported.

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

### Plugin compatibility / deprecation candidates

Questions:

- Which bundled plugins are mandatory first-party behavior?
- Which plugins assume Lua `Doc` internals?
- Which plugins should be ported to C/native APIs?
- Which plugins should be deprecated and archived because this is a personal fork and they are no longer part of the supported native-editor path?
- Which plugins are app-shell/customization behavior that can stay in Lua indefinitely?
- Which plugins are performance-critical or correctness-critical enough to become native C behavior?

Output:

- A table of plugin/command dependencies with one of:
  - keep in Lua as app-shell/customization behavior
  - keep and port to native capabilities
  - port fully into C/native core
  - keep temporarily through Lua glue
  - deprecate/archive out of the supported plugin load path
  - defer
- Include columns for old-editor coupling and migration risk:
  - uses `Doc.lines` or direct text arrays
  - uses old Lua selection structures
  - monkey-patches `Doc`, `DocView`, commands, or tokenizer/highlighter paths
  - requires view rendering/gutter/scrollbar integration
  - is required for daily dogfooding
  - is performance-critical or correctness-critical enough to become native

### Initial plugin/command inventory

This is the working inventory for native-editor migration. Keep it current as plugins are ported, archived, or reclassified.

| Area / plugin(s) | Old-editor coupling | Native-editor classification | Notes |
| --- | --- | --- | --- |
| `native_editor.lua` / `native_text_sandbox.lua` | none to old `Doc`; Lua-hosted native Buffer/View glue | keep temporarily through Lua glue, then promote to real editor path | `native_editor.lua` is the canonical plugin/workspace module and owns the Lua-hosted native view implementation; `native_text_sandbox.lua` is only a legacy restore shim. |
| `anvil_defaults.lua` | config/keybinding defaults only | keep in Lua as app-shell/customization behavior | Route defaults to native commands as default editor changes. |
| `workspace.lua` | generic view state; no text internals | keep in Lua as app-shell behavior, port state coverage to native capabilities | Native sandbox now has `get_state` / `from_state`; real workspace restore still needs default editor integration. |
| `core/commands/doc.lua`, `core/commands/findreplace.lua` | heavy `Doc.lines`, old selections, tokenizer/highlighter, `DocView` predicates | port to native capabilities, then delete old command path | Native command coverage should replace behavior command-by-command, not adapt `Doc.lines`. |
| `autoreload.lua` | `core.docs`, `Doc` dirty/reload lifecycle | keep and port to native lifecycle capabilities | Native sandbox has local external reload handling; final path should centralize file signatures/reload prompts. |
| `autosave_fast.lua`, `autosaveonfocuslost.lua` | historically `DocView`, `view.doc`, `doc:save`; now also uses generic/native save helpers | keep in Lua as app-shell save orchestration | Native Buffers are saved through `core.save_native_editor_view`; dirty/save state remains native Buffer-owned. |
| `search_ui.lua`, `intellij_find.lua` | current search commands route through old docs/selections | keep UI in Lua, port to native search/replace capabilities | Native literal find/replace exists; regex/search result decorations remain future native capabilities. |
| `gitdiff_highlight/` | `Doc.lines`, text-change hooks, `DocView`/scrollbar/gutter monkey-patching | keep Lua git orchestration; port rendering/state to native decoration layer | Model example for generic native decorations. Archive old renderer when native decoration path exists. |
| `bracketmatch.lua` | `DocView` patching, `doc.highlighter`, `doc.lines`, old selections | port to native decorations, probably Tree-sitter-aware | Should become native editor feature or native decoration producer; do not preserve tokenizer dependency. |
| `autocomplete.lua` | patches root input/mouse/update/draw and `Doc.remove`; reads `doc.lines`/highlighter/selections | defer or port to native completion capability | Not a blocker for initial dogfooding unless daily workflow requires it. |
| `linewrapping.lua`, `linewrapping_deep_indent.lua` | deep `Doc`/`DocView` rendering and positioning monkey-patches | port fully into native view/rendering or defer | Too invasive for compatibility glue. Archive old implementation if native wrapping is redesigned. |
| `diffview.lua` | custom paired `DocView`s, many `DocView` monkey-patches, `Doc.raw_insert/remove` hooks | port fully into native diff view or archive unsupported | Do not adapt around old `DocView`; use native Buffers/views if diff remains wanted. |
| `drawwhitespace.lua`, `indent_guides.lua`, `column_guides.lua`, `lineguide.lua`, `selectionhighlight.lua`, `smoothcaret.lua`, `sticky_scroll.lua`, `centered_editor.lua`, `editor_wallpaper.lua` | renderer/gutter/overlay hooks into `DocView`; some read `Doc.lines`/selections/highlighter | port to native view decorations or keep as Lua configuration over native render capabilities | Visual behavior should not monkey-patch final native view internals. |
| `detectindent.lua`, `trimwhitespace.lua`, `reflow.lua`, `quote.lua`, `tabularize.lua`, `sequential_numbers.lua`, `intellij_actions.lua` | old selections/text arrays/commands | port to native editor command/edit APIs where wanted | Text transforms should apply through Buffer Manager transactions. Archive unwanted commands. |
| `language_*.lua` tokenizer plugins | tokenizer/highlighter definitions for old Lua highlighter | defer; port wanted languages to native Tree-sitter/grammar registry | C/C++ Tree-sitter exists. Avoid long-term tokenizer compatibility unless a specific first-party feature needs it. |
| `filetree/`, `findfile.lua`, `fuzzy_searcher/`, `projectsearch.lua`, `command_slots.lua`, `contextmenu.lua`, `ipc.lua`, `settings.lua`, `performance_hud.lua`, `scale*.lua`, `custom_*`, `rootpickcolor.lua`, `macro.lua` | app/project/UI behavior; little or no `Doc.lines` dependence | keep in Lua as app-shell/customization behavior unless a hotspot appears | May need command-target adapters for native views, but not text-core owners. |
| `edit_perf_stress.lua`, `selection_perf_stress.lua` | directly stresses old `DocView`/selection internals | deprecate/archive or rewrite as native tests/tools | Old stress tools should not block replacement. |
| `autorestart.lua`, `untitled_tabs.lua`, `global_prompt_bar_sanitize.lua` | small lifecycle/UI hooks, some `Doc` awareness | keep in Lua; port only the doc-specific edge if still wanted | Low migration risk. |

### Deprecated plugin archive policy

When a bundled Lua plugin is no longer part of the supported native-editor path, do not delete it by default. Move it out of the normal plugin discovery path into a clearly marked archive, preferably:

```text
data/deprecated/plugins/<plugin-name>/
```

The deprecated archive is source history and reference material only. Archived plugins should not be loaded by `core.load_plugins`, should not be required by `anvil_defaults.lua`, and should not receive compatibility work. If an archived plugin contains behavior still wanted in Anvil, create a new native capability or supported Lua orchestration layer for that behavior instead of adapting the archived implementation around old `Doc`/`DocView` internals.

Add a small README in the archive explaining that these plugins are intentionally unsupported after native editor replacement and may depend on removed Lua `Doc` APIs.

### Decoration and marker producers

Some current plugins compute editor-adjacent state in Lua but render by patching `DocView` or depending on `Doc.lines`. Do not rebuild those against the old editor API for native replacement.

Git diff markers are the model example:

- Temporary Lua ownership is acceptable for git process orchestration, config, commands, and debug tooling.
- Native Buffer/View capabilities should own changed-line decoration state, efficient line mapping, gutter markers, overview/scrollbar markers, and navigation by decoration kind.
- Lua may become a producer that requests or updates diff decorations through a stable native API.
- Remove old `Doc.lines` diffing, `DocView.draw_line_gutter` monkey-patching, scrollbar monkey-patching, and `Doc:on_text_change` hooks from the active supported path once the native decoration path exists. Preserve the old plugin source in the deprecated archive if useful as reference material.

Prefer a generic native decoration layer over a one-off git-diff renderer so diagnostics, search results, line hints, and VCS diff markers can share the same view/rendering path.

### Native editor boundary / API contract

Define the long-term boundary between Lua and the native editor before promoting the native view from sandbox to default.

Lua and first-party plugins may interact with native Buffers/Editors through stable capability APIs such as:

- current command target lookup
- selected text retrieval
- replace selections / apply edits through Buffer Manager transactions
- cursor and selection movement commands
- save/save-as/close lifecycle operations
- visible range and scroll/camera queries
- diagnostics, line hints, decorations, and highlight overlays
- file path, dirty state, language, and encoding/line-ending metadata

Lua and first-party plugins should not depend on:

- `Doc.lines`-style text arrays
- direct piece-tree internals
- undo graph internals
- Tree-sitter tree ownership
- native cursor arrays or selection normalization internals
- renderer-specific view implementation details

Native replacement must also define a text/encoding policy at the API boundary. The current native core is byte-offset based, but user-facing behavior needs an explicit stance for UTF-8 cursor movement, invalid UTF-8 display/sanitization, NUL bytes, non-UTF encodings, byte offsets versus visual columns, and how those choices surface in Lua APIs.

The goal is to keep Lua useful without making it the owner of core text-editing state again.

## Phase B: Dogfooding readiness checklist

The native editor is ready for day-to-day dogfooding when these are complete:

### Required editor behavior

- Open/save/save-as file-backed Buffers.
- Duplicate-open policy through a native Buffer registry or equivalent file identity mechanism, so the same path does not silently create conflicting independent Buffers.
- Dirty close prompt or safe refusal to close dirty native views.
- Dirty quit handling for native views.
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

- Canonical native editor command target layer exists outside the sandbox namespace. (Started: `native-editor:*` commands now target native-editor-capable views; `native-text-sandbox:*` remains an alias layer only.)
- Opt-in core-facing native open path exists. (Started: `core.open_native_editor_file(filename)` opens/reuses file-backed native editor views; `core.open_file` dynamically routes through it when native default-open is enabled.)
- `core.open_doc` / file open path can create native Buffers/views for normal text files. (In progress: `core.open_file` routes existing and missing text paths through native default-open; old `core.open_doc` remains for legacy/tool views.)
- Existing tabs/splits/root panel can host native editor views without special sandbox commands.
- Workspace restoration can serialize and restore native editor views, including open file identity, tab/split placement, scroll position, and selection/cursor state. (Runtime split-layout save/restore coverage added; keep validating in real sessions.)
- Save/close/quit flows handle native views.
- Search UI works on native Buffers.
- Command palette commands target native editor views.
- First-party default keybindings route to native commands.
- Critical first-party plugins are ported, adapted, or explicitly moved to the deprecated archive and no longer loaded.
- Old Lua `Doc` no longer owns the primary editing experience.

## Phase D: Lua `Doc` deletion checklist

Only after the native editor is default and stable:

- Remove or quarantine old `data/core/doc` text mutation code for main editor text storage and mutation.
- Remove `Doc.lines` assumptions from bundled plugins/commands.
- Move unsupported/deprecated bundled Lua plugins to `data/deprecated/plugins` rather than deleting them, unless the user explicitly chooses deletion.
- Audit text-backed tool views separately. Command output, file tree internals, prompt text, generated/read-only text views, and similar tools should either move to native Buffer, move to purpose-built view models, stay as temporary Lua glue with a removal target, or be explicitly kept if they are outside the main editor replacement boundary.
- Remove compatibility glue that only existed for transition.
- Keep Lua only if it still serves the temporary app shell/plugin role.
- If pursuing pure C, begin moving command/keymap/view infrastructure into C after text editor replacement is stable.

## Suggested immediate implementation order

After completing the inventory, implement in this order:

1. **OS clipboard integration and native selection command bridge for native sandbox/view**
   - Wire copy/cut/paste commands to native Editor.
   - Expose already-built native primitives such as select-all, select-word, and select-line through the Lua bridge where needed.
   - Use existing platform clipboard APIs exposed to Lua initially if fastest.
   - Add native/API tests for copied text shape and cut/paste undo.

2. **Safe file lifecycle basics**
   - Save-as.
   - Dirty close prompt or safe refusal to close dirty native views.
   - Dirty quit handling for native views.
   - Better file error reporting.

3. **Duplicate-open / Buffer identity policy**
   - Add or choose the native Buffer registry/file identity mechanism before normal default-open dogfooding.
   - Ensure opening the same path reuses or focuses the existing native Buffer/view instead of silently creating conflicting independent Buffers.

4. **Mouse selection polish**
   - Add drag selection in sandbox/native view.
   - Add double-click word and triple-click line selection.

5. **Page movement and camera polish**
   - Add native page up/down commands based on visible line count from view.
   - Keep cursor visible after every command.
   - Improve horizontal scroll/long-line handling.

6. **Find/replace core helpers**
   - Add native Buffer search primitives.
   - Add Editor find-next/find-prev selection behavior.
   - Add replace and replace-all through Buffer Manager.

7. **External reload handling**
   - Detect when file-backed native Buffers changed on disk.
   - Integrate reload prompts or safe refusal when native Buffers have unsaved edits.

8. **Default-open experiment**
   - Add an opt-in setting or command path that opens normal files in the native editor view instead of the old `DocView`.
   - Dogfood with common project files.

## Explicit non-goals for this phase

- Do not add more Tree-sitter languages unless needed for replacement testing.
- Do not build long-term Lua compatibility layers for `Doc.lines`.
- Do not parameterize every UI constant prematurely.
- Do not preserve deprecated native APIs just for internal callers; update in-repo callers instead.
- Do not replace the whole Lua UI shell before the native editor is dogfoodable.
- Do not treat pure C as the default endpoint for every subsystem; migrate specific Lua-owned subsystems only when there is a concrete performance, correctness, maintainability, or architecture reason.

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

- `native-editor:open-file` while sandbox-hosted.
- The native default-open path is now enabled by first-party default for dogfooding.

## Success criteria for this plan

This plan succeeds when:

- There is a checked-off replacement inventory for `Doc`/`DocView` behavior.
- The native editor can be used for ordinary editing sessions without falling back to Lua `Doc` behavior.
- The default file-open path can be switched to native editor views behind an opt-in flag.
- Remaining Lua dependencies are app-shell concerns, not text-core concerns.
