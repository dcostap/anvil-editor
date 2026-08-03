# Anvil Performance Audit

Living record for the production performance audit of Anvil.

## Scope

Audit production-reachable behavior in the normal daily configuration:

- Windows portable application
- default D3D11 renderer
- bundled defaults from `data/plugins/anvil_defaults.lua`
- current user configuration, which only changes the theme
- registered command-only features when realistically usable

A code path must be reachable in this configuration before a finding is
accepted.

## Explicit exclusions

- all LSP functionality, including `data/core/lsp/**`,
  `data/core/commands/lsp.lua`, and LSP-only integration branches
- tests and test fixtures
- environment-gated benchmark, capture, stress, and probe plugins
- disabled `editor_wallpaper` behavior
- non-Windows platform-specific implementations
- software-renderer-only code, except code shared with D3D11
- compatibility or legacy code without an active caller

Tree-sitter and non-LSP autocomplete/language intelligence remain in scope.

## Method and status

Two independent `openai-codex/gpt-5.6-luna` reviewers at `xhigh` examined
each of 13 areas (26 reviewers total). Fleet findings were treated as leads,
not conclusions. Main-agent curation then checked runtime reachability,
inspected the reported call paths, consolidated duplicates, separated
performance from correctness findings, and applied a realistic-trigger test.

Initial static curation is complete. Targeted measurements are still required
to order several medium-priority findings and to establish practical size
thresholds.

Priority meanings:

- **P1**: credible freeze, severe stutter, or large unbounded memory growth under
  a realistic workload.
- **P2**: meaningful scale-dependent sluggishness or retained work that should
  be fixed, but is less likely to block ordinary small workloads.
- **Measure**: reachable and technically credible, but practical impact needs a
  benchmark or trace before promotion.

Confidence meanings:

- **High**: independently repeated or directly verified from a short,
  unambiguous call path.
- **Medium**: verified statically, but impact depends strongly on workload or
  timing.

## Executive summary

The audit found recurring systemic patterns rather than one isolated subsystem:

1. Main-loop coroutines are frequently called “workers” but still perform
   non-yielding CPU or I/O on the UI thread.
2. Several incremental-looking pipelines still copy or scan entire Documents.
3. Generation cancellation often discards stale results without stopping stale
   work.
4. Count limits are used where byte, time, or aggregate-memory limits are
   needed.
5. Hidden views and dormant-looking integrations can continue updating.
6. D3D11 texture/glyph upload paths contain avoidable per-frame or per-glyph
   full-surface work.

The most urgent clusters are the ordinary edit pipeline, D3D11 image/glyph
uploads, Local Find, Markdown table discovery, command output accumulation,
File Tree rescans, and large Git/diff workloads.

# Curated findings by area

## 1. Runtime, scheduling, and plugin composition

### R1 — Process reads can drain unbounded output before honoring the requested size

- **Priority/confidence:** P1 / High
- **Trigger:** A chatty PowerShell, Git, or other child process continuously
  produces output.
- **Effect:** `read_stdout(8192)` can first drain all currently available bytes
  into an unbounded native pending buffer, monopolizing the UI thread and
  exceeding Lua-side output limits.
- **Evidence:** `src/api/process.c:490-505`, `src/api/process.c:1248-1265`.
- **Direction:** Impose a native byte/time budget per drain and enforce output
  caps at the process boundary.

### R2 — Completed worker jobs remain in the Lua pool forever

- **Priority/confidence:** P1 / High
- **Trigger:** A long session completes many Tree-sitter, Markdown, File Tree,
  or other native jobs.
- **Effect:** Terminal payloads are released, but entries are never removed from
  `self.jobs`, causing unbounded bookkeeping memory and ever-larger job-table
  scans.
- **Evidence:** `data/core/worker_pool.lua:51-69`, job insertion around
  `data/core/worker_pool.lua:236-302`, terminal dispatch around `:442-484`.
- **Direction:** Remove terminal jobs or retain a small bounded diagnostics ring.

### R3 — Cancellation and shutdown do not provide reliable bounded latency

- **Priority/confidence:** P2 / High
- **Trigger:** Rapid edits queue full-text native work, or Anvil exits while a
  large native parse/index job is running.
- **Effect:** Ordinary cancellation marks queued jobs but leaves their copied
  payloads queued until selected; native pool destruction then waits for worker
  completion without enforcing the Lua-requested timeout.
- **Evidence:** `src/worker_pool.c:3747-3795`, `:3848-3888`, `:4224-4237`;
  `data/core/worker_pool.lua:590-635`.
- **Direction:** Remove cancelled queued jobs immediately and implement a real
  bounded native shutdown contract.

## 2. Document model and editing

### D1 — Ordinary typing reconstructs the complete Document twice

- **Priority/confidence:** P1 / High
- **Trigger:** Any character insertion, including a single caret in a large
  Document.
- **Effect:** Selection mapping first builds complete replacement lines, then
  `apply_edits` independently rebuilds the complete Document and line-start
  arrays. CPU, allocation, and peak memory scale with total Document size per
  keystroke.
- **Evidence:** `data/core/doc/init.lua:1315-1450`, `:1741-1805`, `:1926-1968`.
- **Direction:** Add a localized edit fast path and map selections from one
  reusable edit plan without rematerializing the Document.

### D2 — Range-marker updates multiply full-Document scans by marker count

- **Priority/confidence:** P1 / High
- **Trigger:** Editing a large Document containing many fold/range markers.
- **Effect:** Every marker independently rebuilds line-start information to
  clamp offsets, producing approximately O(markers × Document lines) work per
  transaction.
- **Evidence:** `data/core/range_marker.lua:204-243`, `:318-323`.
- **Direction:** Compute line starts once per transaction or maintain an
  incremental Document offset index.

### D3 — Undo history is count-bounded but not byte-bounded

- **Priority/confidence:** P1 / High
- **Trigger:** Repeated whole-Document transforms such as replace-all or large
  generated edits.
- **Effect:** Up to 10,000 undo records may retain full old text and inverse
  edits, allowing very large memory growth.
- **Evidence:** `data/core/doc/init.lua:1074-1085`, `:1404-1412`;
  `data/core/config.lua:153-157`.
- **Direction:** Add an aggregate byte budget and evict oldest records by
  retained size as well as count.

### D4 — Large multicursor operations contain quadratic passes

- **Priority/confidence:** P2 / High
- **Trigger:** Thousands of carets/selections from occurrence selection or
  multicursor commands.
- **Effect:** Cursor merging, select-all-occurrences membership checks, and
  duplicate-line offset calculation can perform O(selections²) comparisons.
- **Evidence:** `data/core/doc/init.lua:664-679`;
  `data/core/commands/findreplace.lua:173-211`;
  `data/plugins/intellij_actions.lua:1144-1159`.
- **Direction:** Use hashed cursor identity and sorted prefix calculations.

## 3. Persistence and Document lifecycle

### P1 — Default autosave performs several full-file passes on the UI thread

- **Priority/confidence:** P1 / High
- **Trigger:** Idle/focus-loss autosave of a large dirty file, especially on a
  slow or network-backed path.
- **Effect:** Conflict comparison, backup copying, Document writing, and
  post-save snapshotting can perform multiple complete reads/writes without a
  yield. Focus-loss calls this synchronously.
- **Evidence:** `data/plugins/autosave_fast.lua:62-94`, `:323-386`, `:460-467`;
  `data/core/doc/init.lua:390-419`.
- **Direction:** Move conflict/hash and safe-write work off the UI thread, reuse
  already-read data, and batch dirty saves.

### P2 — External reload makes repeated full-Document copies before diff limits help

- **Priority/confidence:** P2 / High
- **Trigger:** A large clean open file changes externally.
- **Effect:** Autoreload clones old lines, reloads, and reload-diff presentation
  clones/scans old and new content again before complexity budgets are applied.
- **Evidence:** `data/plugins/autoreload.lua:46-54`;
  `data/plugins/reload_diff_flash.lua:163-196`.
- **Direction:** Check size first, avoid duplicate snapshots, and perform bounded
  diff preparation.

### P3 — Untitled recovery serializes full Documents and rewrites manifests repeatedly

- **Priority/confidence:** P2 / High
- **Trigger:** Editing one large untitled Document or flushing several dirty
  untitled Documents.
- **Effect:** The complete text is concatenated and synchronously replaced; a
  multi-Document flush reloads and rewrites the manifest once per Document.
- **Evidence:** `data/plugins/untitled_recovery.lua:341-365`, `:486-538`,
  `:560-574`.
- **Direction:** Snapshot off-thread/in chunks and batch one manifest update per
  flush generation.

### P4 — Workspace restore opens all retained views in one coroutine slice

- **Priority/confidence:** P2 / High
- **Trigger:** Starting a Project with many restored tabs/views.
- **Effect:** The coroutine does not yield between `DocView.from_state` calls,
  so file loading/parsing blocks startup until all views are restored.
- **Evidence:** `data/plugins/workspace.lua:327-353`;
  `data/core/panes.lua:620-640`.
- **Direction:** Restore incrementally or lazy-load inactive views.

### P5 — Autoreload metadata polling scales with all open files

- **Priority/confidence:** P2 / Medium
- **Trigger:** Many open tabs, particularly on slow filesystem paths.
- **Effect:** Windows single-watch fallback checks file metadata for every open
  Document each cycle on a main-loop coroutine.
- **Evidence:** `data/plugins/autoreload.lua:103-126`;
  `data/core/dirwatch.lua:69-83`, `:176-190`.
- **Direction:** Batch/native-watch files where possible and use a time budget.

## 4. Document View, wrapping, and editor rendering

### V1 — Live resize reconstructs wrapping for every line repeatedly

- **Priority/confidence:** P1 / High
- **Trigger:** Resizing a window containing a large wrapped Document.
- **Effect:** Width changes synchronously rebuild all wrap breaks, and the
  Windows owned resize path can request immediate frames for successive resize
  messages.
- **Evidence:** `data/core/linewrapping.lua:1458-1475`; Windows path in
  `src/win32_frame.c:338-447`.
- **Direction:** Coalesce width changes and perform a sliced/lazy final rebuild.

### V2 — Bracket matching can scan huge minified lines byte by byte

- **Priority/confidence:** P1 / High
- **Trigger:** Moving onto an unmatched/distant bracket in minified JSON or
  JavaScript.
- **Effect:** The 3,000-line cap does not bound bytes; bracket bytes repeatedly
  query tokens from the line start, making long bracket-heavy lines especially
  expensive.
- **Evidence:** `data/plugins/bracketmatch.lua:46-83`, `:109-145`.
- **Direction:** Use token-level scanning plus a byte/time budget.

### V3 — Sticky Scroll retains per-visited-line state and builds full models

- **Priority/confidence:** P2 / Medium
- **Trigger:** Scrolling through very large Documents with Sticky Scroll active.
- **Effect:** Full-Document scope construction consumes CPU across frames and
  the per-line ancestor cache has no eviction.
- **Evidence:** `data/plugins/sticky_scroll.lua:244-270`, `:367-374`.
- **Direction:** Build near the viewport and bound or remove the visited-line
  cache.

## 5. Native renderer, window, and input path

### G1 — Immutable images are converted and uploaded every visible frame

- **Priority/confidence:** P1 / High
- **Trigger:** Displaying an Image View or Markdown image under D3D11.
- **Effect:** `canvas.load_image` surfaces have no stable D3D generation, so the
  frame index becomes their update key and the complete image is CPU-converted
  and uploaded every frame.
- **Evidence:** `src/api/canvas.c:44-69`;
  `src/d3d11_backend.c:1336-1383`.
- **Direction:** Assign immutable surfaces a stable generation and update it
  only on mutation.

### G2 — First-use glyphs repeatedly upload complete atlas surfaces

- **Priority/confidence:** P1 / High
- **Trigger:** Rendering many previously unseen glyphs, especially fallback/CJK
  text.
- **Effect:** Every glyph increments the atlas generation; lazy replay can then
  reconvert/upload the same full atlas once per added glyph in a frame.
- **Evidence:** `src/renderer.c:438-453`;
  `src/d3d11_backend.c:1336-1383`.
- **Direction:** Track dirty regions or upload each dirty atlas at most once per
  frame after glyph collection.

### G3 — Owned Windows live resize performs uncapped synchronous frames

- **Priority/confidence:** P1 / High
- **Trigger:** Drag-resizing the default borderless Windows window.
- **Effect:** `WM_SIZE`/`WM_PAINT` run complete immediate frames; live-resize
  throttling is removed and `DwmFlush` can block each message.
- **Evidence:** `src/win32_frame.c:62-68`, `:338-447`;
  `src/main.c:529-566`.
- **Direction:** Coalesce duplicate size/paint requests and rate-limit or remove
  synchronous compositor flushing.

### G4 — Texture lookup is linear per textured quad/glyph

- **Priority/confidence:** P2 / High
- **Trigger:** Many font fallback atlases and retained image/canvas textures.
- **Effect:** Every textured quad scans the linked texture cache, making text
  rendering scale with glyph count × cached textures.
- **Evidence:** `src/d3d11_backend.c:1270-1274`, `:1387-1396`.
- **Direction:** Hash by `(surface, mode)` or attach cache entries to surfaces.

### G5 — Diff connector polygons force per-polygon CPU/GPU work

- **Priority/confidence:** P2 / High
- **Trigger:** Rendering a Diff View containing many change connectors.
- **Effect:** Each polygon creates temporary buffers/surfaces, forces flushes,
  uploads, and draws independently.
- **Evidence:** `src/rencache.c:719-750`;
  `src/d3d11_backend.c:1650-1696`.
- **Direction:** Cull and batch connectors or provide a GPU-native path.

## 6. Markdown semantic engine

### M1 — Open Markdown edits trigger an additional full vault-overlay parse

- **Priority/confidence:** P1 / High
- **Trigger:** Editing a saved Markdown Document tracked by the vault index.
- **Effect:** The entire Document is copied and submitted for overlay parsing in
  addition to the semantic model parse; larger files still undergo complete
  line splitting/scanning.
- **Evidence:** `data/core/markdown/vault_index.lua:1030-1053`;
  `src/markdown_vault_index.c:809-848`.
- **Direction:** Reuse semantic-model results or update only changed vault facts.

### M2 — Small scoped vault changes rebuild whole-Project indexes

- **Priority/confidence:** P1 / High
- **Trigger:** One note or attachment changes in a large Markdown Project.
- **Effect:** Even scoped manifest work clones/reindexes all reusable notes,
  links, targets, and completions.
- **Evidence:** `src/markdown_vault_index.c:731-738`, `:786-803`.
- **Direction:** Incrementally update affected note/attachment records and
  dependent indexes.

### M3 — Markdown completion ignores the requested result limit

- **Priority/confidence:** P1 / High
- **Trigger:** Typing a wikilink/completion query in a large vault.
- **Effect:** A request for 200 items materializes up to 4,096 rich note records
  synchronously, then Lua sorts/truncates them.
- **Evidence:** `src/api/worker_pool.c:1209-1224`;
  `data/core/markdown/vault_index.lua:950-953`.
- **Direction:** Honor the requested limit and return compact completion records.

### M4 — Per-Project vault snapshots are strongly retained indefinitely

- **Priority/confidence:** P1 / High
- **Trigger:** Visiting many large Projects in one Anvil process.
- **Effect:** Stopping the final consumer stops watching but does not close and
  evict disk/manifest snapshots, causing session-long native memory growth.
- **Evidence:** `data/core/markdown/vault_index.lua:46`, `:547-564`,
  `:1334-1342`.
- **Direction:** Reference-count and close inactive Project indexes or use an
  LRU budget.

### M5 — Several secondary Markdown caches/plans grow or rematerialize rich data

- **Priority/confidence:** P2 / High
- **Trigger:** Repeated vault generations, image rendering, link rendering, or
  rename operations.
- **Effect:** Image request keys are never pruned, link resolution pushes full
  note tables when callers need small fields, and completed rename plans can
  remain retained.
- **Evidence:** `data/core/markdown/images.lua:219-245`, `:362-375`;
  `data/core/markdown/live_render.lua:1178-1186`;
  `data/core/markdown/vault_index.lua:1386-1418`.
- **Direction:** Bound caches, expose lightweight native lookup results, and
  consume/remove terminal plans.

## 7. Markdown Live Preview

### L1 — Table discovery now rebuilds a whole-Document source index per revision

- **Priority/confidence:** P1 / High
- **Trigger:** First render/metric lookup after any edit in a large Markdown
  Document, including Documents with no tables.
- **Effect:** `table_for_line` unconditionally reaches source-table fallback,
  which parses every source line on a revision miss. Delimiter-heavy input can
  also scan up to 255 body rows per candidate.
- **Evidence:** `data/core/markdown/tables.lua:120-177`;
  `data/core/markdown/live_render.lua:1480-1508`.
- **Direction:** Make source discovery lazy/incremental and skip fallback when
  semantic state proves the line is unrelated to a table.

### L2 — Unrelated semantic edits discard every table layout

- **Priority/confidence:** P1 / High
- **Trigger:** Editing ordinary prose in a Markdown Document containing tables.
- **Effect:** Semantic publication clears all table layout geometry; the next
  extent/metric pass scans nodes and remeasures every table.
- **Evidence:** `data/core/markdown/live_render.lua:3944-3992`, `:4824-4917`.
- **Direction:** Preserve layouts outside changed semantic ranges.

### L3 — Inline delimiter changes can cause suffix-wide wrap invalidation

- **Priority/confidence:** P1 / High
- **Trigger:** Editing backticks or related raw-context syntax near the top of a
  large Markdown Document.
- **Effect:** The path scans lines for fences and can invalidate/re-wrap from the
  edit through EOF even when the change cannot alter multiline context.
- **Evidence:** `data/core/markdown/live_render.lua:4235-4249`, `:4860-4862`.
- **Direction:** Distinguish inline-only changes from true cross-line fence
  changes.

### L4 — Large/table selections perform repeated semantic and selection scans

- **Priority/confidence:** P1 / High
- **Trigger:** Extending large selections or selecting large rectangular table
  regions.
- **Effect:** Selection invalidation scans selected lines and repeats semantic
  queries; table rendering then scans the full selection list for each cell,
  creating quadratic behavior for many selected cells.
- **Evidence:** `data/core/markdown/live_render.lua:1984-1997`, `:5158-5220`.
- **Direction:** Process changed boundaries in bulk and build a selection map by
  table row/column.

### L5 — Ordered-list numbering rebuilds by scanning all source lines

- **Priority/confidence:** P2 / High
- **Trigger:** First ordered-list render after any text revision.
- **Effect:** Numbering state is reconstructed by scanning the entire Document,
  even when the change is unrelated or local.
- **Evidence:** `data/core/markdown/live_render.lua:2366-2401`.
- **Direction:** Recompute from the nearest list boundary or maintain
  incremental list state.

## 8. Syntax, tokenization, and Tree-sitter

One of the two Area 8 reviewers failed to follow its assigned scope and mostly
re-reviewed Markdown table code. Those duplicate results were discarded. The
remaining findings below received direct main-agent inspection.

### T1 — Every Tree-sitter edit copies the complete Document on the UI thread

- **Priority/confidence:** P1 / High
- **Trigger:** Editing any Tree-sitter-supported Document.
- **Effect:** Lua first counts all bytes, then the native binding walks every
  line and constructs a complete contiguous snapshot before incremental parsing
  begins. This is another O(Document size) copy on top of the core edit rebuild.
- **Evidence:** `data/core/treesitter/init.lua:172-203`;
  `src/api/treesitter.c:290-331`;
  `src/treesitter/snapshot.c:35-69`.
- **Direction:** Use immutable/incremental text storage or build snapshots off
  the UI thread from shared edit state.

### T2 — One non-ASCII byte makes long-line tokenization allocate by byte length

- **Priority/confidence:** P1 / High
- **Trigger:** A very long/minified line containing any non-ASCII character.
- **Effect:** The tokenizer allocates `sizeof(size_t) * (byte_len + 2)` for UTF-8
  offsets. On 64-bit Windows, a 50 MB line can require roughly 400 MB solely for
  this table.
- **Evidence:** `src/api/tokenizer.c:265-294`.
- **Direction:** Allocate by character count in chunks, use compact offsets, or
  build sparse/lazy mappings.

### T3 — Resuming time-sliced long-line tokenization rebuilds that index each slice

- **Priority/confidence:** P1 / High
- **Trigger:** A long line exceeds the tokenizer budget and requires repeated
  resume passes.
- **Effect:** Each resume reinitializes/scans the complete text and reconstructs
  UTF-8 offsets before continuing, multiplying long-line cost.
- **Evidence:** `src/api/tokenizer.c:1327-1414`;
  `data/core/doc/highlighter.lua:39-78`.
- **Direction:** Persist the text index and tokenizer-native resume state across
  slices.

### T4 — Open-Document Project overlays reparse content after the live parse

- **Priority/confidence:** P1 / High
- **Trigger:** A parse-ready event for an open indexed source Document.
- **Effect:** The complete Document is concatenated and submitted to
  `treesitter_index_text`, which reparses/requeries it for the Project index,
  duplicating live parsing on edits.
- **Evidence:** `data/core/treesitter/init.lua:351-356`;
  `data/core/treesitter/symbol_index.lua:1870-1930`.
- **Direction:** Derive overlay symbols from the live snapshot/query result or
  share the parsed tree.

## 9. Autocomplete and non-LSP language intelligence

### A1 — Project symbol completion synchronously scans the full index while typing

- **Priority/confidence:** P1 / High
- **Trigger:** Autocomplete updates in a large Project.
- **Effect:** Every relevant keystroke can call synchronous Project symbol
  search; member completion may issue additional queries. A small output limit
  does not avoid scanning all Project symbols.
- **Evidence:** `data/plugins/autocomplete.lua:1141-1152`;
  `data/core/treesitter/symbol_index.lua:1235-1251`;
  `src/treesitter/project_index.c:1005-1021`.
- **Direction:** Debounce/cache or use asynchronous cancellable queries.

### A2 — The 20-suggestion limit does not bound candidate construction/ranking

- **Priority/confidence:** P1 / High
- **Trigger:** Related open Documents contain thousands of cached symbols.
- **Effect:** Up to 10,000 symbols per Document can be materialized, fuzzy
  scored, sorted, and annotated before only 20 are retained.
- **Evidence:** `data/plugins/autocomplete.lua:1103-1108`, `:1279-1303`.
- **Direction:** Maintain bounded top-K candidates before rich item creation.

### A3 — Completion repeatedly runs full local and outline queries

- **Priority/confidence:** P1 / High
- **Trigger:** Typing in a large C/C++/Tree-sitter Document.
- **Effect:** Popup updates synchronously traverse full locals and outline
  captures; contextual member completion can add another outline pass.
- **Evidence:** `data/plugins/autocomplete.lua:1066-1075`;
  `data/core/treesitter/locals.lua:298-325`;
  `data/core/treesitter/outline.lua:269-309`.
- **Direction:** Cache by tree generation and query only the relevant scope.

### A4 — Outline previews copy complete captured bodies

- **Priority/confidence:** P2 / High
- **Trigger:** Autocomplete/navigation includes large function or class captures.
- **Effect:** Complete captured bodies are copied before truncation to a short
  declaration preview.
- **Evidence:** `data/core/treesitter/outline.lua:39-61`, `:133-158`.
- **Direction:** Extract only the needed declaration byte/line range.

## 10. Search, fuzzy selection, and navigation

### S1 — Local Find scans and stores every match on each query edit

- **Priority/confidence:** P1 / High
- **Trigger:** Typing a short/common query such as `e` in a large log/source
  Document.
- **Effect:** Every query change synchronously scans all lines, allocates one Lua
  table per match, builds another per-line index, and performs additional
  linear selection passes. There is no cap, debounce, or cancellation.
- **Evidence:** `data/plugins/intellij_find.lua:270-302`, `:419-482`.
- **Direction:** Debounce, cancel stale scans, process incrementally/off-thread,
  and cap stored matches.

### S2 — Native fuzzy top-K maintenance is O(index size × result limit)

- **Priority/confidence:** P1 / High
- **Trigger:** Broad file query over a large Project; normal picker limits are
  around hundreds of results.
- **Effect:** Every matching candidate insertion shifts a sorted array of up to
  the full result limit.
- **Evidence:** `src/fuzzy.c:610-648`.
- **Direction:** Use a bounded heap/selection algorithm and sort only final K.

### S3 — Rapid fuzzy typing invalidates results but does not cancel native work

- **Priority/confidence:** P1 / High
- **Trigger:** Typing quickly in the file picker.
- **Effect:** Every intermediate coroutine still performs a complete synchronous
  native index search before its stale generation is checked, delaying the
  newest query.
- **Evidence:** `data/plugins/fuzzy_searcher/init.lua:542-544`, `:3528-3572`.
- **Direction:** Coalesce before entering native search and add native
  cancellation/time budgets.

### S4 — Edit-location diagnostics perform synchronous file I/O for every mutation

- **Priority/confidence:** P1 / High
- **Trigger:** Normal typing, replacements, and even rejected internal-Document
  mutations.
- **Effect:** Hardcoded debug mode opens, appends, and closes a log file from
  `Doc:insert`/`Doc:remove`; the log is unrotated. Windows antivirus can amplify
  the typing latency.
- **Evidence:** `data/plugins/edit_location_history.lua:15`, `:40-48`,
  `:196-227`.
- **Direction:** Disable production tracing by default and buffer/rotate when
  explicitly enabled.

### S5 — Project file pickers repeat broad scans and stale work

- **Priority/confidence:** P2 / High
- **Trigger:** Startup prewarm, reopening the fuzzy picker, or invoking legacy
  `core:find-file`/Ctrl+P.
- **Effect:** Fuzzy prewarm can ingest continuous `rg` output without an
  explicit budget yield; picker reopen starts another full scan; legacy Find
  File defaults to no cache and performs another recursive index/full ranking.
- **Evidence:** `data/plugins/fuzzy_searcher/init.lua:735-801`, `:939-957`;
  `data/plugins/findfile.lua:404-469`; defaults at
  `data/plugins/anvil_defaults.lua:123-126`.
- **Direction:** Share/persist one filesystem snapshot, coalesce refreshes, and
  impose byte/time budgets.

### S6 — Line-qualified file search performs synchronous file reads at scale

- **Priority/confidence:** P2 / High
- **Trigger:** Queries such as `path:1` over many candidate files.
- **Effect:** Up to 1,000 candidates can be read to EOF on the UI scheduler even
  when only a small requested line needs validation.
- **Evidence:** `data/plugins/fuzzy_searcher/init.lua:1405-1420`, `:3564-3578`.
- **Direction:** Stop at the requested line and cache using file metadata.

## 11. Project model, filesystem, and File Tree

### F1 — Hidden File Tree performs eager and event-driven synchronous enumeration

- **Priority/confidence:** P1 / High
- **Trigger:** Startup in a large flat Project or filesystem events while the
  default Right Pane is hidden.
- **Effect:** Construction/refresh lists, stats, sorts, and then computes another
  full directory signature; hidden state does not defer this work.
- **Evidence:** `data/plugins/filetree/init.lua:225-245`, `:933-1024`,
  `:1399-1443`; defaults at `data/plugins/anvil_defaults.lua:114-121`.
- **Direction:** Lazy-initialize hidden views, workerize enumeration, and cache
  directory snapshots.

### F2 — One filesystem event can synchronously rebuild all expanded tree state

- **Priority/confidence:** P1 / High
- **Trigger:** Build/generated-directory churn in an expanded Project tree.
- **Effect:** The changed directory is fully listed/statted for a signature,
  then File Tree refresh performs more synchronous enumeration across expanded
  directories.
- **Evidence:** `data/plugins/filetree/init.lua:957-1024`.
- **Direction:** Coalesce events, refresh affected scopes only, and enumerate in
  a cancellable worker.

### F3 — Trash and recursive copy operations block the UI

- **Priority/confidence:** P1 / High
- **Trigger:** Deleting or copying a large/slow folder through editable File
  Tree operations.
- **Effect:** Windows trash waits/polls synchronously for up to 30 seconds and
  can fall back to synchronous PowerShell; recursive copies enumerate and copy
  directly on the UI coroutine.
- **Evidence:** `data/plugins/filetree/init.lua:452-476`, `:500-624`,
  `:2924-2947`.
- **Direction:** Run cancellable filesystem jobs asynchronously with progress.

### F4 — File Tree line hints consume cooperative UI time for directory counts

- **Priority/confidence:** P2 / High
- **Trigger:** Many visible folders, especially folders with many direct
  children; line hints are enabled by default.
- **Effect:** The “worker” is a main-loop coroutine that lists/stats each child,
  spreading but not removing substantial UI-scheduler work.
- **Evidence:** `data/plugins/filetree/init.lua:304-322`, `:1738-1779`.
- **Direction:** Use the native worker pool and cache counts by directory
  metadata/generation.

## 12. Git and diff functionality

### I1 — Superseded Git selections leave subprocesses and diff work running

- **Priority/confidence:** P1 / High
- **Trigger:** Rapidly moving among commits/files or closing/replacing Git views.
- **Effect:** Generation checks discard stale results but often do not cancel
  old `git show`/`git diff` jobs; some child handles are lost, and replaced
  DiffViews continue computation.
- **Evidence:** `data/plugins/git/model.lua:276-280`, `:745-789`;
  `data/plugins/git/backend.lua:427-440`;
  `data/plugins/git/view.lua:1038-1070`.
- **Direction:** Track and cancel every child job and dispose stale view work at
  the computation boundary.

### I2 — Working-tree diff files are read synchronously

- **Priority/confidence:** P1 / High
- **Trigger:** Selecting a large changed working-tree file.
- **Effect:** `io.open`/`read("*a")` executes on the UI scheduler for content up
  to the 16 MiB Git output default.
- **Evidence:** `data/plugins/git/backend.lua:444-469`.
- **Direction:** Move reads to a bounded worker and stream/size-check first.

### I3 — Inline diff allocates an unbounded quadratic matrix

- **Priority/confidence:** P1 / High
- **Trigger:** A modified pair of very long lines, such as minified/generated
  text.
- **Effect:** `(m+1) × (n+1)` allocation can require hundreds of megabytes and
  has insufficient allocation/complexity guards.
- **Evidence:** `src/api/diff.c:284-297`.
- **Direction:** Cap inline diff by bytes/cells and fall back to line-level or a
  linear-memory algorithm.

### I4 — Git-diff refresh computes non-cooperatively on the UI thread

- **Priority/confidence:** P1 / High
- **Trigger:** Editing a sufficiently complex tracked file after the 200 ms
  debounce.
- **Effect:** `ranges.build`/native diff and line-index construction run inside a
  main-loop coroutine without yields; the two-million-cell limit does not bound
  frame time.
- **Evidence:** `data/plugins/gitdiff_highlight/init.lua:317-355`.
- **Direction:** Use a cancellable native worker or a genuinely sliced diff.

### I5 — Diff connector/overview rendering scales with all changes every frame

- **Priority/confidence:** P1 / High
- **Trigger:** Viewing a highly fragmented large diff.
- **Effect:** Divider geometry is rebuilt for all changed blocks, allocates many
  point tables/polygons, and the D3D polygon path flushes/uploads per connector;
  Git overview similarly iterates all ranges every frame.
- **Evidence:** `data/plugins/diffview.lua:1466-1505`;
  `data/plugins/gitdiff_highlight/init.lua:505-543`; native path in G5.
- **Direction:** Cache/merge geometry, cull to visible rows, and aggregate
  overview markers by pixel row.

### I6 — Git pane/path documents are rebuilt every frame

- **Priority/confidence:** P1 / High
- **Trigger:** Leaving Git View open with hundreds of commits or changed files.
- **Effect:** `GitView:update()` reconstructs line arrays, metadata, and Path
  Trees on every update even when the model is unchanged; hidden retained views
  may also continue updating.
- **Evidence:** `data/plugins/git/view.lua:768-875`;
  `data/plugins/path_tree.lua:232-244`.
- **Direction:** Key pane models by generation and rebuild only on model or
  collapse-state changes.

## 13. UI shell and application tools

### U1 — Streaming command output repeatedly rebuilds all accumulated text

- **Priority/confidence:** P1 / High
- **Trigger:** A command emits many small chunks up to the default 10 MiB limit.
- **Effect:** Every chunk concatenates the complete output string, resets the
  Document, and reinserts all output. Total copying/parsing becomes quadratic.
- **Evidence:** `data/plugins/command_slots.lua:520-553`, `:637-651`.
- **Direction:** Append incrementally to the Document and batch incoming chunks
  under a frame/time budget.

### U2 — Command output history has no aggregate byte budget

- **Priority/confidence:** P1 / High
- **Trigger:** Four slots retain many large command outputs.
- **Effect:** Defaults allow 100 entries per slot and 10 MiB per output—roughly
  4 GiB of retained strings in the worst case. Closing the panel does not clear
  slot history.
- **Evidence:** `data/plugins/command_slots.lua:276-301`; defaults at
  `data/plugins/anvil_defaults.lua:98-105`.
- **Direction:** Add per-slot and global byte budgets with oldest-first eviction.

### U3 — Command Slots prewarm four PowerShell processes by default

- **Priority/confidence:** P2 / High
- **Trigger:** Every normal application launch, even if Command Slots are never
  used.
- **Effect:** Four persistent PowerShell workers and polling coroutines consume
  startup time and resident resources.
- **Evidence:** `data/plugins/command_slots.lua:1557-1570`; default
  `prewarm = true` in `data/plugins/anvil_defaults.lua:98-105`.
- **Direction:** Start lazily, prewarm one shared worker, or make prewarm opt-in.

### U4 — Hidden Right Pane views continue updating

- **Priority/confidence:** P2 / High
- **Trigger:** File Tree, Command Output, or another selected Right Pane view is
  hidden.
- **Effect:** Node update does not skip invisible/zero-width active views, so
  DocView/Git/output work can continue every frame without visible output.
- **Evidence:** `data/core/node.lua:669-681`;
  `data/core/panes.lua:241-254`;
  `data/plugins/command_slots.lua:902-907`.
- **Direction:** Suspend hidden view updates except explicit background services
  that opt in.

# Measurement queue

These leads are credible but should be benchmarked before promotion or major
refactoring:

1. `core.get_views_referencing_doc` makes rendered-frame Document cleanup scale
   as Documents × views (`data/core/init.lua:2467-2474`).
2. Local wrap-map suffix shifts and cache invalidation may still dominate newline
   edits after D1 is fixed (`data/core/linewrapping.lua`).
3. Long wrapped-line packet chunks restart prefix token/whitespace work and only
   retain one chunk (`data/core/docview_line_packets.lua:291-561`).
4. D3D11 logical/pixel DPI units appear inconsistent; correctness is clear
   enough to investigate, but the independent performance cost needs a DPI
   trace (`src/renderer.c`, `src/renwindow.c`, `src/win32_frame.c`).
5. Bundled C++ regexes lack an inner PCRE2 time/match limit; construct a
   pathological long-template fixture before assigning priority.
6. Navigation History debug stack serialization and nested tracking are enabled
   by default; measure normal navigation cost before changing diagnostics.
7. Status-bar temporary items, title-tab geometry, Nag View double layout, and
   inactive prompt updates allocate/work per frame, but practical impact is
   likely below the findings above.
8. File Tree Path Tree toggling uses repeated array insertion/removal and may be
   quadratic for very large trees; benchmark realistic Git/File Tree sizes.

# Consolidated or rejected fleet leads

- Area 8 reviewer B did not review its assigned area; its Markdown duplicate
  findings were discarded rather than counted as parsing corroboration.
- Correctness/data-safety findings discovered incidentally—dirty Project switch
  loss, CRLF retention, relative Markdown link resolution, stale watcher
  semantics, one-character Find behavior, and similar reports—are important but
  are outside this performance audit and are not listed as performance issues.
- Windows single-instance unlimited-client scenarios were rejected from this
  list because they require abusive/malicious launch patterns rather than a
  realistic daily workload.
- Four eagerly created idle Lua worker threads were judged low-impact compared
  with the verified queue/payload issues.
- Tree-sitter and fuzzy indexes serve different query products; their concurrent
  startup work may merit scheduling improvements, but calling either one simply
  duplicate/dead work was rejected.
- Small fixed-size log-array shifting, isolated status objects, and other bounded
  micro-allocations were not promoted without measurement.
- Duplicate reports across areas were consolidated under the subsystem that
  owns the fix. For example, process buffering is under Runtime, table indexing
  under Markdown Live Preview, and polygon flush cost under Native Rendering.

# Recommended first remediation wave

The first wave should target issues that are severe, directly verified, and
amenable to isolated regression/performance tests:

1. **G1:** stop per-frame immutable image uploads.
2. **D1:** eliminate the double whole-Document reconstruction on ordinary input.
3. **L1:** replace eager per-revision whole-Document table indexing.
4. **S1/S4:** bound Local Find and remove synchronous edit-location file logging.
5. **U1/U2:** make command output append-only and byte-budget its history.
6. **R1/R2:** bound native process draining and retire terminal worker jobs.
7. **F1/F2:** defer hidden File Tree work and workerize/coalesce rescans.
8. **I3/I4/I5:** add diff complexity guards and move/cull expensive diff work.
9. **G2:** batch glyph-atlas uploads.
10. **T1:** stop copying a complete Tree-sitter snapshot on each incremental edit.

Each remediation should use a targeted red-green behavior/performance regression
at the stable public seam, followed only by the relevant focused suite.
