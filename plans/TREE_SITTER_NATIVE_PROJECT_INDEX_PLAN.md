# Native Tree-sitter Project Index Plan

## Goal

Keep the current Tree-sitter behavior and user-facing capabilities, but make Project indexing substantially faster, simpler, and more reliable by removing Lua from the per-file/per-capture data path.

The intended result is:

- Tree-sitter parsing, query execution, symbol/usage record construction, aggregation, and large-index querying run natively.
- Lua starts/cancels a Project indexing run, observes small status updates, and requests bounded result pages.
- Project Symbol Search and Project Usage Search keep their current loading, partial, stale, truncation, open-Document overlay, exclusion, and targeted-refresh behavior.
- Large tables are not repeatedly converted, serialized, written to temporary files, read back, sorted, copied through Lua channels, and reconstructed on the UI Lua state.
- The final implementation has one clear ownership model and one clear cancellation model.

This plan focuses on **Project indexing and Project-wide symbol/usage queries**. The active-Document Tree-sitter service is already native and asynchronous; it should remain separate initially and only share proven reusable primitives such as compiled-query caches and native snapshot utilities.

## Post-migration responsiveness repair — 2026-07-13

A targeted-refresh performance capture found that the first Phase 6 implementation still called native Project snapshot construction from Lua worker-pool callbacks. Although records stayed native, constructing the immutable snapshot rebuilt global symbol/usage query structures synchronously on the UI thread. Repeated watcher scopes could also serialize into multiple targeted runs.

The repaired publication path now:

- creates builders from ready base snapshots inside the native worker run;
- builds both partial and final immutable snapshots on native worker threads;
- returns already-built snapshot handles in bounded progress/result messages;
- limits partial snapshot publication to full combined scans, not short targeted refreshes;
- transfers retired snapshot destruction to a native worker instead of freeing large snapshots from Lua callbacks/GC;
- coalesces overlapping watcher directory scopes and submits disjoint dirty directories in one scoped native run;
- queues repeated dirty-file intent instead of repeatedly cancelling/restarting the active targeted run;
- records native builder/snapshot time and targeted-refresh benchmark measurements separately.

Lua publication is consequently the generation check plus handle swap required by the original plan. The regression seam is the native Project-run result contract: a successful result must contain its completed immutable snapshot.

## Investigation summary

### Current Anvil pipeline

The current implementation is responsive compared with the old cooperative indexer, but its throughput path has accumulated several layers:

```text
UI Lua
  -> Lua Project walk coordinator
  -> Lua shard scheduler
  -> Lua worker state
       -> read and normalize file in Lua
       -> split source into Lua lines
       -> submit one native treesitter_index_text job
       -> poll a nested native pool
       -> native code copies/splits/snapshots the source
       -> compile queries
       -> parse and collect native captures
       -> build a line-range index
       -> expose captures to Lua as tables
       -> construct symbol/usage records in Lua
       -> repeatedly serialize records to estimate chunk sizes
       -> encode and write temporary artifacts
  -> Lua aggregate worker
       -> read/decode every artifact
       -> rebuild and sort all records
       -> encode another set of query artifacts
       -> serialize aggregate chunks
       -> copy aggregate tables through Lua channels
  -> UI Lua
       -> append aggregate chunks
       -> publish Lua tables
```

Relevant files:

```text
data/core/worker_pool.lua
data/core/worker_bootstrap.lua
data/core/treesitter/index_scheduler.lua
data/core/treesitter/native_index_adapter.lua
data/core/treesitter/project_index_records.lua
data/core/treesitter/artifact_codec.lua
data/core/treesitter/artifact_session.lua
data/core/treesitter/symbol_index.lua
data/core/workers/treesitter_project_index.lua
data/core/workers/treesitter_project_aggregate.lua
data/core/workers/treesitter_symbol_query.lua
data/core/workers/treesitter_usage_query.lua
src/worker_pool.c
src/api/worker_pool.c
src/treesitter/snapshot.c
src/treesitter/service.c
```

The code has sensible local safeguards—bounded chunks, cancellation tokens, generation checks, an adoption budget, file-backed artifacts, and async query workers—but those safeguards compensate for a transport architecture that moves the same logical data through too many representations.

### Main bottleneck candidates

The new diagnostics in the working tree are useful for confirming proportions, but the code already identifies the expensive boundaries:

1. **Nested worker architecture**
   - Each Project shard occupies a Lua worker while it submits to and polls a native pool.
   - `native_index_text_job` wakes every millisecond while waiting.
   - Scheduling, cancellation, and terminal state exist in both Lua and native layers.

2. **Repeated source preparation and copying**
   - Lua reads and normalizes the entire file.
   - Lua creates a line string table.
   - Native submission copies the full text into the job.
   - Native execution copies it again, splits it again, then creates a Tree-sitter snapshot.
   - The native path uses C-string length in places, which is less robust than carrying explicit byte lengths.

3. **Query compilation per file**
   - `run_treesitter_index_query` creates and deletes outline and usage `TSQuery` objects for every file.
   - Query source strings are copied into every native job.

4. **Unneeded native line indexes for Project scans**
   - `build_query_line_index` runs for every outline and usage result.
   - Project record construction consumes all captures sequentially and does not use line-range lookup.
   - The line index is valuable for active-Document visible-range queries, not for one-shot Project extraction.

5. **C-to-Lua capture expansion**
   - Every capture becomes a Lua table with many named fields.
   - Lua then groups, deduplicates, extracts text, builds nested ranges, collapses signatures, creates previews, and assigns symbol parents.
   - Most of those records are serialized immediately afterward.

6. **Serialization used as flow control**
   - `common.serialize` is repeatedly called to estimate record and payload sizes.
   - `artifact_codec.encode` traverses the same tables again.
   - The aggregate worker repeats sizing and encoding for aggregate and query artifacts.

7. **Disk artifacts as the normal ownership mechanism**
   - Artifacts prevent unbounded channel copies, but add encode/write/open/read/decode/delete work and crash-cleanup state.
   - They are then followed by another Lua-channel aggregate transfer, so they do not establish end-to-end native ownership.

8. **Whole-index Lua materialization**
   - Final symbols and usages are still reconstructed as large Lua tables.
   - Large Project queries require more snapshot/artifact machinery because the authoritative index is not queryable through a compact native handle.

### Fred findings

Fred is useful as architectural inspiration, not as code to copy directly.

Investigated sources:

```text
C:\Projects\my_decomps\fred_src_dump\D_\git_projects\fred\src\tree-sitter-bridge.cpp
C:\Projects\my_decomps\fred_src_dump\D_\git_projects\fred\src\thread.cpp
C:\Projects\my_decomps\fred_src_dump\D_\git_projects\fred\src\ed-buffer-manager.cpp
```

Useful patterns:

- `TreeSitter::query_for` keeps compiled queries in language slots rather than recompiling per parse.
- `Thread::thread_work(TreeSitterParse *)` performs Tree-sitter work entirely in native worker code.
- A task owns its parser, snapshot, old tree, result, and cancellation state.
- `background_task`, `result_if_complete`, and `cancel_task` pass typed native ownership handles rather than serialized object graphs.
- Parsing reads directly from Fred's PieceTree snapshot through the Tree-sitter input callback instead of flattening through an extension language.
- Result and queue locks are separate, and worker threads sleep on a condition variable.

Important differences:

- The recovered source is decompiled C-like C++, so exact implementation details are less trustworthy than its architecture.
- Fred's observed integration is primarily current-buffer parsing/highlighting, not Anvil's full Project symbol/usage index.
- Fred has fixed bundled language/query slots. Anvil permits query source changes and needs cache keys based on language plus query fingerprint.
- Anvil uses newer Tree-sitter parse/query progress callbacks and should not regress to deprecated cancellation APIs.
- Anvil must preserve Project Path Roles, open-Document overlays, bounded Project query behavior, usage caps, targeted refreshes, and the Markdown composite parser.

The main Fred lesson is therefore: **native work should own native input and native output for its full lifetime; Lua should not be the intermediate record-processing and transport layer.**

## Recommendation

Do not spend a large implementation pass micro-optimizing the current Lua artifact pipeline. Apply only small, measured low-risk wins there. The durable optimization is a native Project index snapshot and native Project indexing run.

Target architecture:

```text
Lua/UI
  start Project index -> NativeProjectIndexRun handle
  cancel run          -> atomic cancellation
  read status         -> small counters/state
  query symbols       -> bounded Lua result page
  query usages        -> bounded Lua result page
  publish overlay     -> native per-file replacement

Native Project index service
  enumerate eligible files
  assign deterministic batches and usage budgets
  queue background file jobs
  read/normalize source once
  parse/query with cached TSQuery and reusable worker resources
  construct compact native file records directly from captures/source
  merge file results by path
  build immutable native index snapshot
  atomically publish current-generation snapshot
  retain old snapshot until readers release it

Native snapshot
  immutable file table
  compact string storage
  sorted symbol references
  usage-name lookup
  native fuzzy index/search text
  Project generation and Project-paths generation
  truncation/completeness metadata
```

The authoritative large index should not be a Lua table or a set of temporary files. Lua should only receive the bounded records that a caller can display or act on.

## Required behavior contract

Before replacing the pipeline, capture the behavior that must remain stable:

- language matching and registered grammar/query selection;
- excluded Project paths and ignore patterns;
- Root Project and External Project Directory behavior;
- stable path normalization and relative paths;
- separate symbol and usage readiness/status reporting;
- early/partial Project symbol availability while a run is active;
- usage match/capture limits and Project-wide truncation reporting;
- deterministic symbol and usage ordering;
- symbol kind, source range, name range, parent/depth/children, signature, declaration, and declaration-name span;
- usage declaration preference and duplicate suppression by name/range;
- bounded line/declaration previews;
- dirty open-Document overlay replacing/suppressing disk data;
- targeted file refresh, targeted directory refresh, watcher refresh, deletion, and rename behavior;
- stale generation and stale Project-paths-generation rejection;
- cancellation/restart without publishing a mixed generation;
- async Project Symbol Search and Project Usage Search status semantics;
- existing language-intelligence and autocomplete caller behavior;
- current maximum file size and timeout behavior.

No optimization phase is complete if it changes these semantics accidentally.

## Native data model

### `AnvilProjectFileIndex`

One immutable result for one file:

```text
normalized absolute path
relative path
language id
fingerprint (size, modified time, query/language fingerprint)
symbol range in a native symbol array
usage range(s) in a native usage array
usage completeness/truncation state
compact string arena/offsets
```

Records should use offsets/lengths into owned string storage rather than individually allocating duplicate C strings. Frequently repeated values such as path, relative path, language id, kind, and capture name should be interned or represented by ids.

### `AnvilProjectIndexSnapshot`

An immutable, reference-counted published generation:

```text
root identity
generation
Project-paths generation
file table keyed by normalized path
sorted symbol references
usage-name dictionary -> contiguous usage references
native fuzzy index over symbol search text
symbol/usage completeness and truncation metadata
optional open-Document overlay layer
```

Readers acquire a reference, query without holding the service mutation lock, and release it. Publication swaps one pointer under a short lock. The old snapshot is freed only after all readers release it.

### `AnvilProjectIndexRun`

A cancellable builder:

```text
atomic cancellation flag
run/generation identifiers
phase and progress counters
file work queue
completed file results
failure/truncation metadata
published partial-symbol view, if enabled
final snapshot builder
```

A failed or cancelled run must never partially mutate the last ready snapshot. Partial results belong to the run and are explicitly reported as partial; final publication is atomic.

## Implementation plan

## Phase 0: freeze evidence and correctness fixtures

### Purpose

Establish independent correctness and performance evidence before moving code.

### Work

1. Keep the current detailed diagnostic patch long enough to collect repeatable profiles.
2. Add a benchmark runner, not timing assertions inside ordinary tests, for:
   - small fixture;
   - Anvil source;
   - a medium mixed-language Project;
   - a large synthetic Project with controlled symbol/usage density;
   - cancellation during walking, parsing, aggregation, and query.
3. Record separately:
   - wall time to first partial symbols;
   - wall time to final symbols;
   - wall time to final usages;
   - cumulative CPU time by stage;
   - files/bytes/captures/records;
   - peak process memory;
   - temporary bytes/files;
   - Lua GC time/count if available;
   - UI drain/adoption max and p95;
   - cancellation latency;
   - query latency for empty, short, and selective terms.
4. Create literal/fixture-backed expected outputs for C, C++, Odin, Kotlin, and representative malformed files.
5. Include edge fixtures for CRLF, final line without newline, Unicode, very long lines, oversized records, duplicate captures, nested symbols, invalid queries, and disappearing files.

### Red-green seam

Use public Project index/query behavior in Lua tests and native Project-file extraction APIs in native tests. Expected records must be literals or reviewed fixtures, not results computed by the old Lua algorithm inside the assertion.

The current targeted worker test already passes:

```text
meson test -C build-windows-x86_64 anvil:lua-runtime \
  --test-args runtime/treesitter_project_index_worker.lua --print-errorlogs
```

That validates the current working-tree diagnostic changes, but it is not a performance baseline.

### Exit gate

A saved baseline and reviewed behavior fixtures exist. Do not begin deleting the old path before this gate.

## Phase 1: low-risk native hot-path cleanup

### Purpose

Remove work that is clearly redundant while preparing reusable native primitives.

### Work

1. **Make result capabilities explicit.**
   - Add job flags describing whether capture paging, line-range lookup, or compact Project records are needed.
   - Do not build `line_order`/`line_tree_max_end` for Project extraction jobs.
   - Keep line indexes for active-Document/Markdown consumers that actually use range queries.

2. **Cache compiled queries.**
   - Cache by grammar/language ABI identity, query kind, and full query fingerprint.
   - Cache immutable `TSQuery` objects; create a separate `TSQueryCursor` per execution.
   - Use a mutex only for cache lookup/creation/publication, never around query execution.
   - Keep failed compilation metadata cached for the same fingerprint so a bad query is not recompiled for every file.
   - Invalidate naturally by changing the fingerprint; do not mutate a published cache entry.

3. **Reuse worker-local parser/query-cursor resources where safe.**
   - Keep a parser per native worker and reset/set language as needed.
   - Reuse cursors only serially on their owning worker and reset all byte ranges/match limits before use.
   - Prefer explicit worker context over hidden process globals.

4. **Use length-aware source buffers.**
   - Carry byte length in job specs/results.
   - Remove avoidable `strlen` dependence from Project input.
   - Define embedded-NUL handling explicitly: reject with a stable reason or support it without truncation.

5. **Eliminate one source copy.**
   - Allow native jobs to take ownership of submitted source buffers or read closed files directly from `path`.
   - Text snapshots remain necessary for dirty open Documents.
   - Preserve Anvil's normalized-newline coordinate semantics by normalizing once in native code, in place when possible.

6. Add quiet metrics for query-cache hits/misses and skipped line-index work.

### Files

```text
src/worker_pool.c
src/worker_pool.h
src/api/worker_pool.c
src/treesitter/snapshot.c
src/treesitter/service.c
tests/native/worker_pool_test.c
tests/native/treesitter_test.c
```

### Exit gate

- Fixture output is unchanged.
- Query compilation falls from per-file to per-query-fingerprint.
- Project jobs no longer build unused line indexes.
- Source preparation has a documented single-owner path.
- Baselines show an improvement or the changes are retained only when they materially simplify the next phase.

## Phase 2: construct Project records natively

### Purpose

Remove capture-by-capture C-to-Lua conversion and Lua record construction.

### Work

Add a dedicated native Project-file extraction result. During query iteration, retain the minimum capture metadata needed to resolve a match, or construct records directly when a match is complete.

Port the durable behavior from `project_index_records.lua`:

- select the largest `outline.*` item capture per match;
- select the smallest `name` capture per match;
- collect and order signature captures;
- extract/collapse symbol names and signatures;
- strip declaration bodies where current behavior requires it;
- calculate declaration-name spans;
- sort symbols by source range;
- assign parent, depth, and children relationships;
- recognize usage/declaration captures;
- deduplicate by name/start/end with declaration preference;
- produce bounded line previews;
- attach stable path/language/range metadata.

Implementation rules:

- Work from byte ranges against one owned source buffer; do not first create Lua line strings.
- Build one native line-start array so byte-to-line and line-preview operations are bounded.
- Store range values flat in native records. Create nested Lua range tables only for the bounded page returned to a caller that needs them.
- Intern capture/kind/language strings or map them to ids.
- Use checked growth helpers and overflow checks for every array/arena allocation.
- On allocation failure, fail the file/run cleanly without publishing a partial final snapshot.

Expose a temporary native API such as:

```lua
local result = native_project_index.index_file_for_test({ path = ..., language = ... })
local summary = result:summary()
local symbols = result:symbols({ offset = 1, limit = 100 })
local usages = result:usages({ offset = 1, limit = 100 })
```

This test API is a seam, not the final Project orchestration API.

### Tests

For each behavior slice:

1. add a focused native or Lua runtime fixture test;
2. run it against the missing native behavior and confirm red;
3. implement the smallest slice;
4. confirm green;
5. compare against the reviewed public behavior fixtures;
6. run the broader Tree-sitter suites.

Differential comparison with the old Lua extractor is useful during migration, but is supplemental; the old implementation must not be the sole oracle.

### Exit gate

A native file result is behavior-equivalent for all reviewed fixtures, and the Project worker no longer needs to page generic capture tables into Lua for migrated languages.

## Phase 3: native shard result ownership and native aggregation

### Purpose

Remove temporary Project-index artifacts and the Lua aggregate worker from the normal path.

### Work

1. Add native batch jobs that accept bounded file descriptors and return an owning native batch-result handle.
2. Merge batch results into a native run builder by transferring ownership; do not serialize or deep-copy records.
3. Keep per-file results keyed by normalized path so targeted replacement and deletion are direct operations.
4. Build final deterministic symbol order and usage-name lookup natively.
5. Allocate aggregate arrays once from known counts where possible.
6. Publish a reference-counted immutable snapshot.
7. Expose only small progress/status messages to Lua:

```lua
{
  files_discovered = n,
  files_completed = n,
  symbols_found = n,
  usages_found = n,
  status = "indexing" | "partial" | "ready" | "failed" | "cancelled",
}
```

8. Preserve early symbol behavior without parsing every file twice:
   - run outline and usage queries from the same tree;
   - make completed-file symbols queryable as an explicitly partial run view;
   - freeze/publish the final snapshot after all required files complete;
   - if usage extraction fails for a file, retain its valid symbols and mark usage completeness accurately.

9. Make the Project-wide usage cap deterministic under parallelism.
   - Enumerate eligible files in stable normalized-path order.
   - Assign per-file or per-batch usage reservations in that order before parallel execution, or deterministically truncate the final sorted usage set.
   - Do not use a racing global atomic “first workers win” cap.

### Avoid

- Do not let native worker jobs recursively submit to the same bounded pool and synchronously wait; that can deadlock when all workers become parents.
- Do not expose a mutable native vector while workers can reallocate it.
- Do not hold the run mutex during parsing, query execution, fuzzy scoring, or Lua conversion.

### Temporary migration

A temporary development-only switch may run old and new pipelines for comparison. Remove it and the old fallback before the phase is considered complete, consistent with the fork's clean-refactor policy.

### Exit gate

- Normal full scans produce no Tree-sitter Project chunk artifacts.
- No aggregate record tables cross Lua worker channels.
- Final publication is one snapshot-handle swap.
- Cancellation and stale generations release all native ownership under stress tests.

## Phase 4: native Project queries

### Purpose

Stop materializing the whole Project index in Lua and remove query snapshot artifacts.

### Work

1. Build/retain a native fuzzy index over Project symbol search text using the existing native fuzzy implementation in:

```text
src/fuzzy.c
src/fuzzy.h
src/api/fuzzy.c
```

2. Add bounded snapshot methods:

```lua
snapshot:query_symbols(query, { offset = 0, limit = 200, kinds = ... })
snapshot:query_usages(name, { offset = 0, limit = 500 })
snapshot:summary()
```

3. Return only display/navigation fields needed by the caller. Add an optional detail lookup by stable record id for declaration/signature fields if that reduces routine conversion.
4. Keep fuzzy scoring, sorting, filtering, and `has_more` calculation native.
5. Keep exact usage-name lookup native through an interned-name hash/dictionary.
6. Merge dirty open-Document overlays in native query execution:
   - overlay data replaces the disk entry for the same path;
   - closed/clean Documents fall back to the ready disk snapshot;
   - a pending overlay reports `overlay-indexing` without exposing stale disk records for that path.
7. Apply Excluded Project Path and Project Path Role filters before expensive result conversion. Either store role metadata in the snapshot or pass a compact generation-stamped filter description.
8. Update Project Symbol Search, Project Usage Search, language commands, and autocomplete to consume bounded native pages.

### Tests

- native and public query order matches reviewed fixtures;
- empty query and selective query behavior;
- pagination has no duplicates/gaps;
- stale query handles are discarded after generation changes;
- dirty overlay suppresses disk entries;
- excluded paths never appear;
- result limits and `has_more` are correct;
- cancelling rapidly changing fuzzy input does not retain old snapshots indefinitely.

### Exit gate

Project-wide query latency scales with the requested page and native search work, not with Lua conversion of the full index. Symbol/usage query artifacts are no longer produced.

## Phase 5: native Project run orchestration

### Purpose

Replace the Lua coordinator/shard scheduler/nested-pool state machine with one native run handle.

### Work

1. Add a native Project indexing service or native grouped-job primitive with:
   - background queue;
   - fixed/adaptive concurrency;
   - sleeping workers;
   - atomic cancellation;
   - progress counters;
   - immutable final result;
   - completion wakeup/event;
   - high- and low-priority lanes if sharing a pool with interactive work.
2. Move recursive Project enumeration into the native run, preserving ignore/exclusion semantics.
3. Batch by measured bytes/cost, not only file count.
4. Reserve capacity for active editor work. Project indexing must not saturate every logical CPU by default.
5. Coalesce progress notifications. Lua does not need one message per file.
6. Wake the UI on meaningful state transitions instead of nested 1 ms polling.
7. Keep Lua generation checks at the publication boundary even though native runs also carry generation ids.
8. Keep the active-Document parse service separate through this phase. Consolidate pools only after priority tests prove that active parsing cannot be starved.

### Lua facade after migration

`symbol_index.lua` should primarily:

- map loaded Projects to native run/snapshot handles;
- start/cancel based on Project and Project-path generation;
- publish user-facing statuses;
- manage watcher-triggered intent;
- publish dirty open-Document snapshots;
- adapt bounded native query pages to existing command/provider return shapes.

It should no longer:

- schedule individual shards;
- reserve shard usage budgets;
- gather artifact paths;
- rebuild aggregates;
- serialize index snapshots;
- run large sorts/filters;
- own large per-file symbol/usage tables.

### Exit gate

A full Project scan has one Lua-visible run handle and one final snapshot handle. Lua worker threads are not occupied by native Tree-sitter parsing jobs.

## Phase 6: targeted refreshes and watcher integration

### Purpose

Reach feature parity beyond full scans before deleting the old path.

### Work

1. Implement native immutable snapshot replacement for one changed file.
2. Implement directory refresh as a native scoped run that reuses unaffected file entries.
3. Remove deleted paths without rebuilding unrelated file records.
4. Coalesce repeated watcher events by normalized path and generation.
5. Cancel superseded file work quickly.
6. Preserve the previous ready snapshot until the replacement snapshot is valid.
7. Reuse unchanged file results when fingerprint and query/language fingerprint match.
8. Optionally persist a compact native cache only after the in-memory path is complete and measured. Persistence is not required for the first native architecture.

### Exit gate

Full scans, file refreshes, directory refreshes, watcher refreshes, deletions, renames, and open-Document overlays all use the native snapshot model.

## Phase 7: delete superseded machinery and simplify

Delete in-repo compatibility code after all callers migrate. Expected deletion candidates, subject to final reference search:

```text
data/core/treesitter/index_scheduler.lua
data/core/treesitter/native_index_adapter.lua
data/core/treesitter/project_index_records.lua
data/core/treesitter/artifact_codec.lua
data/core/treesitter/artifact_session.lua
data/core/workers/treesitter_project_index.lua
data/core/workers/treesitter_project_aggregate.lua
data/core/workers/treesitter_symbol_query.lua
data/core/workers/treesitter_usage_query.lua
```

Also remove the corresponding large sections from `symbol_index.lua`:

- artifact session creation/cleanup;
- chunk manifests;
- partial chunk merge;
- aggregate adoption queue work specific to Project artifacts;
- shard scheduling and budget accounting;
- query artifact construction/recovery;
- old diagnostic fields that only describe deleted stages.

Do not delete generic worker-pool or artifact facilities if another real in-repo customer still uses them. Remove only Tree-sitter-specific machinery proven unreferenced.

Retain concise native diagnostics:

- run wall/CPU time;
- files and bytes;
- query cache hits/misses;
- parse/query/record/merge time;
- peak records/bytes;
- cancellation latency;
- bounded Lua conversion/adoption time.

## Performance gates

Use repeatable release/debugoptimized builds with Anvil closed when replacing binaries. Report medians and p95 where meaningful.

### Correctness gates

- All existing Anvil Meson tests pass.
- New native extraction/snapshot/query tests pass.
- Fixture-backed Project symbols/usages match the reviewed contract.
- No stale generation is published.
- No old disk entry leaks through a pending dirty-Document overlay.

### Responsiveness gates

- No Project-index callback exceeds the established UI adoption budget.
- Project indexing does not regress active-Document parse latency.
- Cancellation reaches running parse/query work promptly and prevents publication.
- Rapid restart/watch storms do not grow result queues or retained snapshots without bound.

### Throughput targets

Calibrate exact numbers from Phase 0, then require at minimum:

- a clear wall-time improvement on the real medium and large Projects;
- near-elimination of Lua worker CPU attributed to Project capture/record/serialization work;
- zero normal-path Project artifact I/O;
- one source normalization/snapshot preparation per file;
- one parse per file for combined outline/usage indexing;
- query compilation amortized per query fingerprint, not per file;
- bounded Project query conversion proportional to result limit;
- materially lower peak memory than simultaneously holding capture tables, record tables, encoded strings, decoded aggregate tables, and final Lua tables.

Do not encode machine-specific timing thresholds as ordinary correctness tests. Keep benchmark thresholds in the benchmark/reporting harness.

## Stability and memory rules

- Use explicit byte lengths everywhere in the native Project path.
- Check integer multiplication/addition before allocation.
- Use reference-counted immutable snapshots and clear ownership transfer functions.
- Keep queue, result, run-state, and query-cache locks separate where practical.
- Never call Lua from a native worker thread.
- Never expose pointers into mutable/reallocating storage.
- Ensure every terminal path—success, parse timeout, query timeout, cancellation, allocation failure, file disappearance, shutdown—has one documented cleanup owner.
- Bound completed-but-unadopted native results or use run-owned storage so a fast producer cannot create an unbounded result queue.
- Add stress tests under repeated create/cancel/destroy and application shutdown.
- Keep old ready snapshots usable when a replacement run fails.
- Log optional failures and fallback decisions with `core.log_quiet` at the Lua boundary and equivalent quiet native diagnostics.

## Risks

### Native port changes subtle record semantics

Mitigation: migrate one behavior slice at a time with literal fixtures, and retain temporary differential diagnostics until parity is proven.

### Native snapshots consume too much memory

Mitigation: compact flat records, string arenas/interning, ids for repeated strings, one authoritative snapshot, bounded partial publication, and measured peak-memory gates.

### Query cache becomes unsafe or stale

Mitigation: immutable entries keyed by complete fingerprint, separate cursors, short creation lock, and no in-place query mutation.

### Parallel completion makes results nondeterministic

Mitigation: stable file enumeration, deterministic usage reservations/truncation, path-keyed merge, and final stable ordering independent of completion order.

### Background work starves active editing

Mitigation: reserve CPU capacity, use background concurrency caps/lanes, retain the separate active-Document service initially, and benchmark active parse latency during Project scans.

### A large native rewrite becomes hard to review

Mitigation: vertical phases with a public seam, red-green evidence, and deletion only after each replacement path is exercised. Do not combine extraction, storage, queries, watcher migration, and cleanup into one commit.

## Suggested commit sequence

1. Add baseline benchmark harness and reviewed Project-index fixtures.
2. Skip unused Project line indexes and add cache/source-ownership metrics.
3. Add compiled-query cache and worker-local native resources.
4. Add length-aware native Project file input.
5. Add native symbol extraction fixture by fixture.
6. Add native usage extraction and deterministic limits.
7. Add native batch-result handles and ownership stress tests.
8. Add immutable native Project snapshot and atomic publication.
9. Add native symbol/usage query paging and fuzzy integration.
10. Migrate full Project scans.
11. Migrate open-Document overlays and targeted file refreshes.
12. Migrate directory/watcher refreshes and deletion/rename handling.
13. Remove Project artifact/aggregate/query workers and simplify `symbol_index.lua`.
14. Run full correctness, stress, memory, and performance validation; update the existing Tree-sitter plans to mark the replaced architecture complete.

## Definition of done

- Project Tree-sitter data remains native from file input through indexed storage and query filtering.
- Lua receives only status summaries and bounded result pages.
- Full Project indexing parses each file once for outline and usage work.
- Compiled queries are reused safely by fingerprint.
- Temporary Tree-sitter Project artifacts are absent from the normal path.
- The Lua shard scheduler, nested native polling, Lua record builder, Lua aggregate worker, and query artifact pipeline are removed after migration.
- Project Symbol Search, Project Usage Search, autocomplete fallback, open-Document overlays, exclusions, targeted refreshes, watchers, truncation, and cancellation retain their behavior.
- Ready snapshots are immutable, generation-safe, and remain available when a replacement run fails.
- Benchmarks show lower wall time, lower Lua CPU/GC work, lower temporary I/O, bounded memory, and no active-editing responsiveness regression.
