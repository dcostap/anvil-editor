# Tree-sitter Smoothness and Project Indexing Plan

## Goal

Make Anvil's Tree-sitter integration slick, fast, and unobtrusive while preserving the architecture that already works:

- native asynchronous parsing;
- incremental Tree-sitter edits;
- stale-generation rejection;
- cancellation;
- sharded Project indexing;
- worker-side aggregation;
- Project Symbol Search and Project Usage Search;
- dirty open-Document overlays;
- external Project directories.

This is a targeted steering plan, not a rewrite. The main objective is to remove unbounded UI-thread result adoption and unnecessary data expansion while retaining the current public behavior.

## Implementation status

Implemented on 2026-07-10. The completed path now uses compact manifests, framed binary artifacts, metadata-only full-scan `by_path` entries, off-thread targeted-directory merges, byte/record-bounded chunks, a deterministic adoption pump, compact internal records, one-pass Project indexing, session-owned artifact cleanup, coalesced Document snapshots, changed-range cache invalidation, batched highlighting, shared queries, two interactive parser workers, and reserved worker priority lanes.

Validation capture:

```text
C:\Users\Darius\AppData\Local\Temp\anvil_perf_20260710_000419_summary.txt
```

The capture's maximum worker callback was 0.066 ms. Legacy artifact roots were removed, and a subsequent process startup retained only its current `treesitter-artifacts/session-*` directory.

## Terminology

This plan follows Anvil's glossary:

- **Project Symbol Search** means named symbol search across a loaded Project.
- **Project Usage Search** means syntactic usage search across a loaded Project; it does not promise semantic references.
- **Document** and **Document View** are used instead of buffer/editor-tab terminology.

Some existing internal APIs still use `workspace_*` names. Those names are implementation details and are not renamed as part of this plan.

## Executive diagnosis

The Tree-sitter parser itself is not the primary cause of the observed lag. Expensive parsing and querying generally run off the UI thread. The largest problem is the Project-index result transport and adoption path.

The current pipeline repeatedly converts and moves large result sets:

```text
native captures
  -> worker-side Lua capture tables
  -> rich symbol/usage record tables
  -> generated Lua source artifact
  -> filesystem
  -> UI-thread loadfile + execute
  -> per-file by_path records
  -> aggregate worker reloads the same artifact
  -> aggregate records copied back through channels
  -> UI aggregate tables
  -> persistent generated-Lua query artifacts
```

This creates avoidable costs:

- Lua parsing and bytecode generation for data files;
- large numbers of nested Lua table allocations;
- repeated strings and duplicated record fields;
- filesystem and antivirus overhead;
- duplicate copies of the Project index in UI memory;
- callback work that cannot be interrupted by the worker-pool drain budget;
- garbage-collector pressure;
- poor artifact lifecycle behavior.

## Baseline evidence

Source recording:

```text
C:\Users\Darius\AppData\Local\Temp\anvil_perf_20260709_184046_summary.txt
```

Recording duration: 8.370 seconds.

Observed behavior:

- 225 redraw frames, 26.9 whole-record FPS;
- median redraw interval 24.465 ms;
- p95 redraw interval 70.975 ms;
- maximum redraw interval 760.221 ms;
- 2,979.5 ms spent draining worker results;
- 2,928.6 ms spent in the slowest worker callbacks;
- 2,926.9 ms attributed to Tree-sitter Project chunk adoption;
- 90,520 Project-index records adopted in 61 chunks;
- only 148.2 ms spent applying Project path metadata;
- only 6.2 ms spent replacing per-file entries;
- only 0.45 ms spent in aggregate checks.

Worst callback:

```text
treesitter_project_index:usages:chunk:on_result
records: 1,561
time: approximately 734 ms
```

Other result callbacks blocked the UI for approximately 179, 140, 122, 120, 106, 81, and 57 ms.

Conclusion:

> The dominant hitch is synchronous reconstruction/loading of Project-index result data on the UI thread, not Tree-sitter parsing, input handling, LSP token work, selection handling, or D3D presentation.

## Fred comparison

Reference source:

```text
C:\Projects\my_decomps\fred_src_dump\D_\git_projects\fred
```

The reference is a decompiled source dump, so conclusions should be limited to clearly visible architectural behavior.

Fred's useful patterns include:

- native `TSParser`, `TSTree`, and `TSQueryCursor` ownership;
- native worker result ownership;
- shared/reference snapshots of its piece tree;
- explicit parsed/parsing/needs-reparse state;
- edit coalescing while a parse is in flight;
- visible-byte-range highlight queries;
- direct native capture iteration during rendering;
- globally cached language queries;
- cancellation and stale-result handling through worker handles.

Important scope difference:

> No equivalent eager, whole-Project syntactic usage index was found in Fred's Tree-sitter implementation.

Fred's perceived smoothness is therefore not solely due to better threading. It also avoids eagerly materializing the large Project Usage Search data set that Anvil currently maintains.

Anvil should adopt Fred's ownership, coalescing, and bounded-adoption principles without copying Fred's piece-tree architecture or dropping Anvil's Project features.

## Existing strengths to preserve

The following are valuable and should be leveraged rather than replaced:

- `src/treesitter/service.c` provides asynchronous native Document parsing.
- Incremental `ts_tree_edit` and old-tree parsing are implemented.
- Document parse generations reject stale results.
- Project-index generations and Project-path generations reject stale work.
- Native cancellation tokens reach parse and query work.
- Project indexing is sharded and has a concurrency cap.
- Native per-file indexing result handles already exist.
- Worker-side aggregate construction and sorting already exist.
- Large synchronous Project query paths are bounded.
- Dirty open-Document overlays suppress stale disk entries.
- Diagnostics already expose worker, adoption, aggregate, query, and rendering costs.

## Primary deficiencies

### 1. Generated Lua source is used as a bulk data format

Relevant files:

```text
data/core/workers/treesitter_project_index.lua
data/core/workers/treesitter_project_aggregate.lua
data/core/treesitter/symbol_index.lua
```

Workers serialize record graphs with `common.serialize()` and prefix them with `return`. Consumers load them through `loadfile()` and execute them with `pcall()`.

Loading a data chunk therefore requires:

- file I/O;
- Lua source parsing;
- bytecode generation;
- execution;
- hash-table allocation;
- nested table allocation;
- string allocation;
- garbage-collector participation.

This format is acceptable for diagnostics and small fixtures, but it is not suitable for high-throughput Project-index transport.

### 2. Full scan artifacts are loaded on the UI thread and then loaded again by a worker

During normal sharded scans, `symbol_index.lua` loads complete shard artifacts to populate `index.by_path`, preserves the artifact, and later submits the same artifact to the aggregate worker.

The UI does not require complete per-file symbol and usage graphs for ordinary full-scan bookkeeping. It primarily needs:

- file path;
- fingerprint;
- generation;
- completion/truncation flags;
- whether the path was seen.

Loading every rich artifact on the UI thread is avoidable.

### 3. Internal usage records are too rich

A Project usage record repeats or duplicates data such as:

- `name` and `text`;
- `file` and `relpath`;
- absolute path on every occurrence;
- language on every occurrence;
- scalar start/end positions and a nested `range` containing the same positions;
- name even when the record already lives under `usages_by_name[name]`;
- repeated capture/kind strings;
- a full line preview on every occurrence.

The public result shape may remain rich, but the internal index and transport format should be compact. Rich public records should be expanded only for the bounded result set returned to callers.

### 4. The UI retains duplicate Project-index graphs

A full scan creates rich per-file entries under `index.by_path`. The aggregate worker then reconstructs and returns another set of records under:

- `index.symbols`;
- `index.usages_by_name`.

Because these records crossed worker boundaries, they are separate Lua objects. This increases memory use and GC pressure.

After a full scan, `by_path` should normally retain compact metadata rather than another complete Project index.

### 5. Record-count chunking does not bound work

The default Project worker chunk limit is record-based. Record sizes vary with:

- source preview length;
- symbol signature length;
- absolute and display path length;
- nested range structures;
- capture names.

A 2,048-record chunk can still be more than a megabyte. A strict serialized-byte ceiling is required in addition to a record ceiling.

### 6. Worker-pool drain budgets do not bound callback duration

`worker_pool:drain()` checks its deadline between messages. It cannot preempt an individual callback.

Therefore:

```text
max_ms = 1
```

does not prevent one `on_result` callback from running for 734 ms.

Worker callbacks should validate and enqueue compact adoption work, then return. Actual adoption must be run through an explicit budgeted pump. Any atomic operation inside that pump, such as `loadfile()`, must itself be byte-bounded or removed.

### 7. Symbol and usage phases parse files twice

The current Project scan performs:

1. symbol phase;
2. symbol aggregation;
3. usage phase;
4. symbol and usage aggregation.

The usage phase runs outline and usage queries from one parse, but the same file was already parsed during the symbol phase.

The separate phases improve early symbol readiness, but double much of the work:

- reads;
- parses;
- outline queries;
- record construction;
- artifact output;
- aggregation.

A combined pass should be the normal path unless measurements prove that duplicate parsing is worthwhile for a particular Project size.

### 8. Open-Document highlighting crosses the native/Lua boundary per line

Relevant files:

```text
data/core/treesitter/highlight.lua
src/api/treesitter.c
src/treesitter/service.c
```

On a cache miss, each line:

- executes a native query;
- copies captures into C-owned temporary records;
- converts captures to Lua tables;
- resolves capture overlap in Lua;
- creates highlighter token arrays;
- is later traversed again by DocView.

Fred instead constrains one query to the visible byte range and directly iterates captures while rendering.

Anvil does not need to render exactly like Fred, but it should reduce native/Lua crossings and batch visible-range work.

### 9. Highlight overlap resolution can be quadratic

`highlight.resolve_line_tokens()` builds boundary intervals and scans every capture span for every interval.

A capture-heavy line can therefore perform approximately:

```text
boundary_count * span_count
```

comparisons. A sorted sweep/event algorithm can produce the same winner semantics with bounded sorting plus linear traversal.

### 10. Incremental parse completion invalidates the full highlight cache

When a parse becomes ready, the complete Tree-sitter highlight cache is cleared. The next redraw can synchronously rebuild highlighting for every visible line.

Tree-sitter can report changed ranges between the old and new trees. Anvil should invalidate only affected lines, with a small safety expansion where multiline query captures require it.

### 11. Document snapshots are copied in full for each scheduled parse

`snapshot_from_lua_lines()` iterates every Document line and constructs a complete contiguous native copy before queueing the parse.

The parse itself is asynchronous, but snapshot construction occurs synchronously. Rapid typing can repeatedly copy the complete Document even when intermediate parse generations are immediately cancelled.

A piece-tree rewrite is out of scope. The practical improvement is to debounce/coalesce snapshot construction and avoid creating snapshots for intermediate edits that will never be parsed.

### 12. Document parsing uses one native parser worker

All open Documents share one worker in `src/treesitter/service.c`. Parsing across Documents is serialized.

A small interactive parse pool can improve cross-Document responsiveness while preserving per-Document ordering and generation checks.

### 13. Query compilation is repeated across Documents

Open-Document query compilation should be cached by:

```text
grammar + query kind + query source
```

and shared across attached Documents. The Project-index side already demonstrates query caching.

### 14. Background priority is not a complete scheduling guarantee

Project jobs label themselves as background and the Project scheduler limits shard concurrency, but there are no fully enforced interactive/background lanes across the Lua worker pool.

A long-running shard already assigned to a worker cannot be preempted by an interactive query. This is not the main recorded hitch, but it can cause head-of-line latency.

### 15. Artifact lifecycle is incomplete

Observed state under the dev portable user directory:

```text
C:\Projects\c_projects\anvil-portable\user\treesitter-query-artifacts
  approximately 2,686 files
  approximately 3.24 GB
  8 session directories

C:\Projects\c_projects\anvil-portable\user\treesitter-index-artifacts
  approximately 110 files
  approximately 97 MB
```

Worker-produced query artifacts use an explicit session directory, while stale-session cleanup is tied to a UI-side fallback writer. Normal worker-produced artifacts can therefore bypass startup cleanup.

Stale sessions and abandoned indexing artifacts must be cleaned deterministically.

### 16. Targeted subdirectory aggregation likely replaces unaffected Project results

Concrete scenario:

```text
Project/
  src/A.kt
  tests/B.kt
```

If only `src` is marked dirty:

1. the targeted directory worker scans `src`;
2. the aggregate worker aggregates only `src` artifacts;
3. `finish_pending_aggregate()` swaps the global aggregate with that partial aggregate.

`tests/B.kt` can remain in `by_path` while disappearing from Project Symbol Search and Project Usage Search.

The current targeted-directory test indexes all relevant files inside the changed directory and therefore does not verify preservation of an unaffected sibling directory.

This correctness issue must be fixed before further optimizing targeted aggregation.

## Scope

This plan includes:

- eliminating unbounded UI-thread Project result adoption;
- reducing duplicate Project-index data;
- compacting internal Project records;
- bounding transport by bytes and records;
- fixing artifact lifecycle;
- preserving correct targeted refresh behavior;
- reducing duplicate Project parsing;
- smoothing open-Document highlighting and parse scheduling;
- adding performance-focused regression seams and real capture validation.

## Non-goals

This plan does not include:

- replacing Anvil's Document representation with Fred's piece tree;
- rewriting the complete Project index in C as the first step;
- changing Project Usage Search into semantic reference search;
- renaming existing `workspace_*` implementation APIs;
- removing dirty open-Document overlay behavior;
- dropping external Project directory support;
- increasing worker counts before adoption is safe;
- building a general database-backed code intelligence system.

# Milestone 0: Lock down correctness and reproducibility

## Goal

Establish red-green regression seams for known correctness and lifecycle risks before changing ownership and adoption behavior.

## Work

### Targeted subdirectory preservation test

Add a runtime regression test with this layout:

```text
Project/
  src/Changed.kt
  sibling/Unaffected.kt
```

Test through the public Project Usage Search and/or Project Symbol Search APIs:

1. index the complete Project;
2. verify both files contribute results;
3. edit a file under `src`;
4. call `symbol_index.mark_directory_dirty(src, ...)`;
5. wait for the targeted directory refresh;
6. verify the changed result is updated;
7. verify the unaffected sibling result remains available.

Red requirement:

- run the test before the fix and confirm the unaffected sibling disappears or otherwise demonstrates the current broken behavior.

Green requirement:

- targeted refresh updates the changed directory while preserving unaffected aggregate entries.

### Artifact lifecycle test

Use an isolated test root to verify:

- stale session directories are removed at startup/session initialization;
- current-session artifacts remain available;
- cancellation removes abandoned artifacts;
- successful finalization removes transient index artifacts;
- persistent query artifacts are removed when their index generation is invalidated.

### Adoption seam test

Introduce or identify a public-enough adoption pump seam where tests can enqueue synthetic chunk descriptors and step adoption with a budget.

Test durable behavior rather than wall-clock timing:

- one step processes no more than the configured byte/record allowance;
- unfinished work remains queued;
- stale-generation work is discarded;
- final state is complete after repeated steps;
- one oversized atomic item is rejected, split, or handled by a bounded fallback rather than silently violating the budget.

## Acceptance

- targeted directory red-green regression is recorded;
- artifact cleanup behavior has automated coverage;
- adoption has a deterministic bounded-step test seam.

# Milestone 1: Remove full-scan artifact loading from the UI thread

## Goal

Eliminate the exact path responsible for the recorded 734 ms Project-index callback.

## Design

During normal full Project scans, shard chunk messages should carry only:

```lua
{
  artifact = {
    path = ...,
    bytes = ...,
    files = ...,
    records = ...,
  },
  manifest = {
    { path = ..., fingerprint = ..., usage_complete = ... },
    ...
  },
  diagnostics = ...,
}
```

The UI callback should:

1. verify generation and Project-path generation;
2. record the artifact descriptor for worker-side aggregation;
3. adopt the compact manifest;
4. mark progress/redraw state;
5. return.

It must not call `loadfile()` for the complete shard artifact.

## `by_path` ownership

After a full scan, use metadata-oriented entries:

```lua
index.by_path[path] = {
  fingerprint = fingerprint,
  usage_complete = usage_complete,
}
```

A targeted file refresh may temporarily create a rich entry while updating the aggregate, but full Project scans should not retain a second complete symbol/usage graph under `by_path`.

## Files likely involved

```text
data/core/workers/treesitter_project_index.lua
data/core/treesitter/symbol_index.lua
data/core/workers/treesitter_project_aggregate.lua
tests/lua/runtime/treesitter.lua
tests/lua/runtime/treesitter_project_index_worker.lua
```

## Tests

- full scan chunks expose a compact manifest;
- full scan UI adoption does not invoke artifact payload loading;
- `by_path` still supports fingerprint freshness checks;
- pruning removes paths absent from the final manifest;
- targeted file reindex still updates Project results;
- stale manifests are ignored;
- cancellation does not adopt partial stale state as ready.

## Acceptance

- no full-scan `treesitter_project_index:*:chunk:on_result` callback loads rich artifact contents;
- full-scan callbacks contain work proportional to files in the compact manifest, not symbols/usages in the artifact;
- Project-index records are not duplicated under both rich `by_path` entries and global aggregates.

# Milestone 2: Fix targeted directory aggregate ownership

## Goal

Make targeted directory refresh merge correctly with unaffected Project results.

## Preferred approach

Treat a targeted directory refresh as a replacement of only the affected path subset:

1. aggregate the refreshed directory off-thread;
2. remove old aggregate records whose paths belong to that directory;
3. merge the refreshed aggregate records;
4. preserve records outside the directory;
5. sort or incrementally insert as appropriate;
6. swap only after the complete merged result is ready.

The merge should happen off the UI thread. UI adoption should receive a complete replacement aggregate or bounded delta that does not require scanning the entire old index in one frame.

## Tests

- changed file is replaced;
- added file appears;
- removed file disappears;
- unaffected sibling directory remains;
- stale targeted refresh does not overwrite a newer generation;
- failed targeted refresh retains the previous usable aggregate and reports stale/failed state honestly.

## Acceptance

- the Milestone 0 targeted-directory regression passes;
- no partial targeted aggregate is installed as the complete Project aggregate.

# Milestone 3: Add strict byte-bounded transport and adoption

## Goal

Ensure no individual Project-index transport unit can contain unbounded work.

## Work

### Dual chunk limits

Every Project-index and aggregate chunk should observe both:

```text
max_records
max_serialized_bytes
```

Suggested initial values for measurement:

```text
max_records: 256-512
max_serialized_bytes: 128-256 KiB
```

These are tuning values, not permanent behavioral rules. The durable requirement is that both dimensions are bounded.

### Oversized single record handling

If one record exceeds the byte ceiling:

- truncate optional preview/signature data using an explicit marker; or
- emit it as a bounded special case with diagnostics;
- never silently create a multi-megabyte chunk.

### Budgeted adoption pump

Worker callbacks should enqueue descriptors and return. A central adoption pump should:

- prioritize current-generation interactive/open-Document work over background Project indexing;
- process at most a configured time/byte/record slice per run-loop iteration;
- request redraw only when useful visible state changes;
- discard stale queued work cheaply;
- expose diagnostics for queue depth, oldest age, bytes, records, and max slice duration.

### Worker-pool diagnostics

Distinguish:

- channel/message extraction time;
- callback enqueue time;
- adoption pump time;
- artifact decode time;
- metadata application time;
- aggregate swap time.

## Tests

- synthetic variable-size records split by bytes;
- long previews cannot create oversized chunks;
- adoption requires multiple bounded steps for a large fixture;
- input events can be processed between steps;
- stale queued chunks are discarded without decoding;
- completion is reported only after all required chunks are adopted.

## Acceptance

- no normal Project-index callback exceeds 2 ms in a real capture;
- no single artifact/chunk exceeds its configured byte ceiling except an explicitly diagnosed oversized-record fallback;
- Project indexing cannot monopolize one run-loop iteration through callback adoption.

# Milestone 4: Compact internal Project records

## Goal

Reduce transport size, memory use, serialization cost, and GC pressure without changing public Project query behavior.

## Internal usage representation

Keep `usages_by_name` because named lookup is valuable, but store compact occurrences under each name.

Candidate conceptual representation:

```lua
usages_by_name[name] = {
  { path_id, start_line, start_col, end_line, end_col, kind_id, flags, preview_id_or_text },
  ...
}
```

Intern at Project-index scope:

- absolute paths;
- display/relative paths where stable;
- language IDs;
- capture/kind strings;
- repeated preview strings when worthwhile.

Do not store internally when derivable or duplicated:

- `name` when already under `usages_by_name[name]`;
- `text` when equal to name;
- both `file` and `relpath`;
- nested `range` plus duplicate scalar positions;
- repeated fallback flags as string-keyed table fields;
- `start_byte`/`end_byte` unless a caller requires them after indexing.

## Public expansion

At the query boundary, expand only returned results into the current public record shape. The normal query limit is bounded, so expansion should be proportional to visible results rather than total Project index size.

## Internal symbol representation

Symbols may retain richer declaration/signature data, but should still avoid:

- repeated path strings;
- duplicated range forms;
- repeated search text identical to name;
- repeated language and role metadata per symbol where it can be resolved by path.

## Artifact representation

Initially, compact positional Lua arrays may remain file-backed to minimize scope. This alone removes repeated table-key text and much of the object graph.

Generated Lua source should not be considered the final bulk format. Once compact arrays are measured, choose between:

1. native result/index handles;
2. a small framed binary format;
3. a line/framed format that can be incrementally decoded under budget.

Do not introduce a large database dependency for this milestone.

## Tests

- public Project Symbol Search results match the old shape;
- public Project Usage Search results match the old shape;
- declarations filtering remains correct;
- sorting remains stable;
- external Project directory display metadata remains correct;
- dirty open-Document overlays remain correct;
- synthetic artifact size is materially lower than the rich-table baseline.

## Acceptance

- `by_path` does not own complete rich usage graphs after full scans;
- compact internal usage records remove duplicated fields;
- rich records are expanded only for bounded query results or explicit API callers;
- a representative Project's artifact bytes and UI heap use are recorded before and after.

# Milestone 5: Make artifact lifecycle deterministic

## Goal

Prevent stale sessions, cancellations, failures, and restarts from leaving gigabytes of generated artifacts.

## Work

### Session ownership

Use one Tree-sitter artifact session root per process:

```text
USERDIR/treesitter-artifacts/session-<pid>-<nonce>/
```

Keep a clear separation between:

- transient shard artifacts;
- transient aggregate artifacts;
- persistent current-generation query artifacts.

### Startup cleanup

At Tree-sitter initialization:

- identify the current session root;
- remove all stale session roots from previous processes;
- remove legacy artifact roots where safe;
- log counts, bytes, duration, and failures quietly.

Cleanup must not depend on a fallback query writer being invoked.

### Cancellation/failure cleanup

Every job/run should own the artifacts it creates. On cancellation, stale rejection, failure, or generation invalidation:

- remove unadopted transient artifacts;
- release persistent artifacts belonging to the invalidated generation;
- tolerate already-removed files;
- never remove artifacts still referenced by a current request.

### Shutdown cleanup

Best-effort removal of the current session root should occur during clean shutdown. Startup cleanup remains the recovery mechanism for crashes or forced restarts.

## Tests

- stale session removal;
- current session preservation;
- cancelled shard cleanup;
- cancelled aggregate cleanup;
- stale query request does not remove an artifact still owned by the current index;
- index invalidation removes that generation's persistent artifacts;
- cleanup is idempotent.

## Acceptance

- startup leaves no stale Tree-sitter session directories;
- completed/cancelled runs do not leave transient shard artifacts;
- artifact disk usage is bounded by current active Projects and generations.

# Milestone 6: Remove duplicate Project parsing

## Goal

Use one file read and one parse for outline and usage extraction in the normal Project indexing path.

## Design

Use a combined Project scan:

```text
for each file:
  read once
  parse once
  run outline query
  emit/store symbols
  run usage query
  emit/store usages
```

Preserve separate readiness semantics if useful:

- symbol progress can update as file results arrive;
- `symbol_status` may become usable before the complete usage aggregate;
- `usage_status` remains indexing until usage aggregation completes.

Separate status does not require separate parsing passes.

## Project-size policy

Default to the combined pass for small and medium Projects.

Only retain a duplicate symbol-first pass for very large Projects if measurements show a meaningful improvement in time-to-first-usable-symbol results that justifies the extra work. If retained, make the policy explicit and diagnostic.

## Tests

- outline and usage results match the existing two-phase behavior;
- outline results remain usable when a usage query times out/fails;
- parse-count diagnostics prove one parse per indexed file in combined mode;
- symbols become incrementally available as designed;
- cancellation during usage extraction rejects stale work;
- global Project usage cap remains enforced across shards.

## Acceptance

- normal combined mode reports approximately one parse per indexed file;
- total reads/parses/artifact bytes decrease from the two-phase baseline;
- symbol readiness remains acceptably fast.

# Milestone 7: Smooth open-Document parse scheduling

## Goal

Prevent rapid typing from repeatedly performing full synchronous snapshot construction for obsolete intermediate generations.

## Work

### Coalesce parse requests

When edits arrive rapidly:

- apply `ts_tree_edit` semantics needed to keep the stale tree renderable;
- record the newest requested generation/edit state;
- schedule snapshot construction after a short debounce or at the next safe run-loop opportunity;
- replace older pending requests before their snapshots are built;
- continue to cancel native parses that have already started and become stale.

The debounce should be short enough that syntax feedback feels immediate. It should not become a user-visible fixed delay.

### Instrument snapshot cost

Measure separately:

- Lua line iteration;
- native snapshot allocation;
- byte copy time;
- bytes copied;
- coalesced requests;
- cancelled-before-snapshot requests;
- cancelled-after-parse-start requests.

### Small interactive parse pool

Evaluate replacing the single Document parser worker with a small pool, initially two workers, while preserving:

- one active parse per Document;
- generation ordering;
- cancellation;
- old-tree ownership safety;
- current-tree adoption on the UI thread;
- interactive priority over Project indexing.

## Tests

- a burst of edits produces fewer snapshots than edits;
- final parse corresponds to the latest Document generation;
- stale intermediate results are never adopted;
- two Documents can parse independently without violating per-Document ordering;
- closing a Document cancels and releases queued/running work safely.

## Acceptance

- rapid typing does not copy the complete Document once per intermediate edit;
- snapshot construction cost is visible in diagnostics;
- cross-Document parsing is not globally serialized when the pool is enabled.

# Milestone 8: Use changed ranges for highlight cache invalidation

## Goal

Avoid rebuilding all visible Tree-sitter highlighting after every incremental parse.

## Work

Before replacing an old tree with a new parse result, compute Tree-sitter changed ranges. Return compact changed-range metadata through Document parse polling.

On adoption:

- invalidate highlight cache lines intersecting changed ranges;
- remap cache entries across inserted/deleted lines as already supported;
- expand invalidation conservatively for multiline capture behavior;
- retain unaffected cached lines;
- invalidate the full cache only when changed ranges are unavailable or the parse was full/unreliable.

The same changed-range metadata may later help folding, outlines, and navigation caches, but those extensions are not required for this milestone.

## Tests

Use observable render-token behavior or a stable cache invalidation seam:

- an edit in one function preserves unaffected line tokens;
- multiline syntax changes invalidate all affected lines;
- line insertion remaps unaffected cached lines correctly;
- full parse fallback invalidates safely;
- stale parse completion does not invalidate the current generation.

Avoid tests that only assert private helper call counts.

## Acceptance

- incremental parse completion no longer clears the complete highlight cache by default;
- post-edit redraw does not synchronously query every visible line when most lines are unchanged.

# Milestone 9: Batch visible highlighting and optimize overlap resolution

## Goal

Reduce native/Lua crossings and CPU cost for highlighting cache misses.

## Work

### Shared compiled query cache

Cache compiled queries by grammar, kind, and source. Attached Documents should reference shared query objects rather than compiling identical queries repeatedly.

### Visible-range query API

Add a native/Lua API that queries one visible byte range and returns captures grouped or efficiently sliceable by line.

Possible shape:

```lua
local result = state:query_highlight_range(query, byte_start, byte_end, opts)
```

The implementation should avoid one native query and one capture-table conversion per line.

### Sweep-based overlap resolver

Replace the boundary-by-span nested scan with an event/sweep algorithm that preserves current precedence rules:

1. explicit priority;
2. capture specificity;
3. narrower span;
4. stable pattern/capture/order tie-breaking.

### Cache integration

Populate all visible missing line caches from one range result. Do not requery lines that already have valid cache entries for the current tree generation.

## Tests

- overlapping capture precedence matches existing behavior;
- multiline captures are split correctly by line;
- visible range starts/ends inside a capture correctly;
- cached and uncached lines produce identical render tokens;
- large capture-heavy line behavior is tested with independent expected tokens;
- unsupported/failed query falls back without breaking normal tokenization.

## Acceptance

- one visible-range query replaces many per-line native calls on cache refresh;
- capture overlap resolution no longer performs a full span scan for every boundary interval;
- typing and scrolling captures show no Tree-sitter highlight regeneration spikes above the frame budget.

# Milestone 10: Scheduling and query-path hardening

## Goal

Prevent background Project indexing from delaying interactive Tree-sitter and Project query work.

## Work

Choose the smallest measured solution:

### Option A: Dedicated Project indexing pool

Use a small background-only pool for coordinator, shard, and aggregate work. Keep interactive queries and open-Document overlays on the system/interactive path.

Pros:

- small implementation change;
- no head-of-line blocking behind shard jobs;
- straightforward concurrency control.

Cons:

- not a single Fred-style shared pool;
- separate pool lifecycle and worker resources.

### Option B: Real worker priority lanes

Extend the existing pool with enforced lanes:

```text
interactive
normal
background
```

Workers should prefer interactive jobs while ensuring background progress.

Pros:

- cleaner long-term shared pool;
- reusable beyond Tree-sitter.

Cons:

- broader worker-pool change.

Start with Option A unless another feature already justifies generic priority lanes.

### Query cache improvements

Persistent Project query artifacts and worker caches should be keyed by Project generation and evicted deterministically. Avoid sorting and reconstructing the complete Project symbol list for every fuzzy-search keystroke when a generation-stable cached index can be reused.

## Tests

- an interactive query completes while background shards are queued/running;
- cancelling a stale fuzzy query does not delay the newest query;
- background indexing still makes progress;
- pool shutdown cleans all job and artifact ownership;
- query cache invalidates on Project generation changes.

## Acceptance

- Project indexing does not create head-of-line latency for autocomplete, overlays, or Project search queries;
- background work remains bounded and cancellable.

# Performance validation

## Test Projects

Validate against:

1. a small correctness fixture;
2. the Anvil source Project;
3. a Project with a large external Project directory such as the Odin source tree;
4. a synthetic capture-heavy Project;
5. a large single Document for snapshot/highlight testing.

## Capture scenarios

### Scenario A: Active editing during initial Project indexing

- start a fresh Project index;
- hold cursor movement keys;
- type and backspace continuously;
- scroll the active Document;
- record until symbol and usage indexing complete.

### Scenario B: Targeted watcher refresh

- edit/add/delete files in one subdirectory;
- continue editing another Document;
- verify sibling Project results remain;
- capture refresh and aggregate merge.

### Scenario C: Project Symbol Search during indexing

- open the Fuzzy Searcher immediately;
- type and revise a query repeatedly;
- confirm stale query jobs cancel;
- confirm input remains responsive.

### Scenario D: Project Usage Search on a high-frequency name

- query a name with many syntactic usages;
- verify bounded result expansion;
- verify no full rich index copy occurs on the UI thread.

### Scenario E: Rapid edits in a large Document

- type continuously;
- verify snapshots are coalesced;
- verify changed-range invalidation;
- verify visible-range highlighting remains smooth.

## Required metrics

Project indexing:

- total wall time;
- time to first usable Project symbols;
- time to complete Project usages;
- files read;
- parses performed;
- outline/usage query time;
- transient and persistent artifact bytes;
- peak artifact count;
- UI adoption callback max/p95/p99;
- adoption pump slice max/p95/p99;
- queue depth and oldest queued age;
- stale/cancelled artifact cleanup;
- UI heap or process memory peak where available.

Open Documents:

- snapshot bytes and construction time;
- snapshots requested/constructed/coalesced;
- parse queue wait and parse duration;
- changed lines/ranges;
- highlight native query calls;
- highlight captures and resolution time;
- full versus partial cache invalidations.

Frame behavior:

- median/p90/p95/p99 redraw interval;
- maximum redraw interval;
- Tree-sitter-attributed UI work per frame;
- input event latency where measurable.

## Performance gates

Project indexing should satisfy:

- no normal worker callback over 2 ms;
- no UI-thread `loadfile()` of full Project-index artifacts;
- adoption pump capped at approximately 1-2 ms per iteration;
- no complete rich Project index duplicated under `by_path`;
- chunks bounded by records and bytes;
- no stale session artifact directories after startup cleanup;
- no Tree-sitter-attributed input hitch over 20-25 ms in the editing capture;
- cancellation removes abandoned transient artifacts;
- targeted subdirectory refresh preserves unaffected Project results.

Open-Document Tree-sitter should satisfy:

- incremental edits normally invalidate changed highlight ranges only;
- rapid typing constructs fewer snapshots than edit transactions;
- visible cache refresh uses a batched range query;
- no repeated query compilation per attached Document;
- no Tree-sitter-attributed post-edit redraw spike above the intended frame budget in representative Documents.

# Risks and mitigations

## Risk: smaller chunks increase total overhead

Mitigation:

- remove the duplicate UI artifact load first;
- compact records before aggressive chunk reduction;
- bound by bytes and records;
- measure total throughput as well as maximum latency.

## Risk: compact records complicate callers

Mitigation:

- preserve the public API shape;
- centralize compact-to-public expansion;
- test public Project search behavior rather than private storage fields.

## Risk: combined scanning delays symbol readiness

Mitigation:

- emit symbol progress/results as each file completes;
- separate readiness status from parse-pass count;
- retain a measured large-Project policy only if necessary.

## Risk: changed ranges miss query effects outside the textual edit

Mitigation:

- use Tree-sitter's old/new tree changed ranges rather than only edit coordinates;
- conservatively expand invalidation around multiline ranges;
- retain full invalidation fallback when confidence is low.

## Risk: multiple Document parser workers create ownership races

Mitigation:

- enforce one active parse per Document;
- retain trees/snapshots explicitly;
- adopt only current generations;
- stress cancellation, close, and shutdown.

## Risk: artifact cleanup removes a live artifact

Mitigation:

- session-scoped ownership;
- generation-scoped reference tracking;
- cleanup stale sessions only, never arbitrary current-session paths;
- idempotent deletion with quiet diagnostics.

## Risk: more workers worsen UI responsiveness

Mitigation:

- do not increase Project indexing concurrency before adoption is bounded;
- reserve interactive capacity;
- prefer a dedicated background pool or enforced priority lanes;
- measure input latency, not only indexing completion time.

# Recommended implementation order

1. Add the targeted-subdirectory preservation regression and artifact lifecycle tests.
2. Fix targeted directory aggregate merging.
3. Stop UI-thread loading of full-scan shard artifacts.
4. Make `by_path` metadata-only for normal full scans.
5. Add byte-bounded chunks and a deterministic adoption pump.
6. Add deterministic startup/cancellation/shutdown artifact cleanup.
7. Compact internal usage and symbol records while preserving public results.
8. Convert normal Project indexing to one combined parse pass.
9. Coalesce open-Document parse snapshots.
10. Add changed-range highlight invalidation.
11. Cache compiled queries and batch visible-range highlighting.
12. Add dedicated background scheduling or real priority lanes based on measurements.
13. Run full performance captures and tune only after structural costs are removed.

# Definition of done

The Tree-sitter work is complete when:

- Project indexing can run continuously without perceptible typing, cursor, or scrolling hitches;
- no full Project-index artifact is synchronously compiled/executed on the UI thread;
- worker callbacks only enqueue bounded adoption work;
- Project result adoption is explicitly budgeted;
- internal Project records are compact and public records are expanded lazily;
- `by_path` does not duplicate the full aggregate index;
- normal Project indexing reads and parses each file once;
- targeted directory refresh preserves unaffected Project results;
- stale and abandoned artifacts are cleaned deterministically;
- rapid Document edits coalesce obsolete snapshot work;
- incremental parses invalidate affected highlight ranges rather than the complete cache;
- visible highlighting avoids per-line native/Lua query crossings;
- real performance captures satisfy the stated latency gates;
- correctness, cancellation, stale-generation, overlay, external Project directory, and cleanup behavior remain covered by automated tests.

The guiding principle is:

> Keep Anvil's existing native parsing, generation checks, cancellation, sharding, and worker aggregation. Remove rich Lua data from hot transport paths and make every UI adoption step genuinely bounded.
