# Tree-sitter and File Indexing Throughput Plan

## Goal

The previous async worker work made Tree-sitter project indexing much less visible to the user by moving heavy work away from the UI thread. This plan is the next step: make indexing finish faster by using real parallelism and reducing duplicate work, while preserving the main responsiveness guarantee.

In simple terms:

- the editor must stay responsive;
- indexing should use multiple CPU cores when a project is large enough;
- the UI should adopt results incrementally and cheaply;
- project symbol/reference commands should avoid large synchronous copies/sorts/filtering on every invocation.

This is a throughput plan, not just a responsiveness plan.

## Implementation status

As of the current implementation pass, Milestones 1-4 are complete:

- **Milestone 1 complete:** indexing now records quiet throughput diagnostics for worker scanning, file reads, native parse/query timing, record construction, chunk send/backpressure time, UI chunk adoption, and aggregate rebuilds. Baseline-style quiet logs are emitted per completed run/phase.
- **Milestone 2 complete:** `treesitter.index_text` now supports per-query result status/error metadata, and worker jobs that collect both symbols and usages parse each file once and run both queries from that parse. Outline results are preserved if usage extraction fails.
- **Milestone 3 complete:** UI chunk adoption no longer rebuilds aggregates on every chunk. Aggregate rebuilds are debounced during chunk arrival and forced at phase/fresh-query boundaries. A Lua-side `core.treesitter.index_scheduler` now exists to cap outstanding/running indexing jobs and reserve worker-pool capacity.
- **Milestone 4 complete:** project indexing now uses a worker-side coordinator walk that emits bounded file batches, and the UI submits those batches as bounded shard jobs through `core.treesitter.index_scheduler`. Shard chunks are adopted through the existing bounded path, stale generation/project-path messages are rejected, and usage indexing uses deterministic per-shard reservations so accepted shard budgets never exceed the project usage cap.

The throughput plan is **not fully complete**. The main near-term indexing speedup is now in place, but later milestones are larger transport/query/pool infrastructure work and should be implemented only after measurements show they are the next bottleneck.

Post-Milestone-3 responsiveness repair: real performance captures showed that chunk adoption was still doing per-record Project path resolution, occasional aggregate rebuild/sort work, huge single-file result transfers, synchronous pending-refresh drain work inside worker-pool callbacks, and forced aggregate rebuilds from workspace symbol/reference queries. Chunk adoption now caches Project path metadata per file/kind/project-path generation, defers aggregate rebuilds while indexing chunks are arriving, splits oversized single-file worker results into bounded partial chunks, uses a smaller default worker result chunk size, defers phase-completion aggregate/pending-refresh work out of the worker callback, and lets workspace queries read directly from per-file entries while aggregates are dirty instead of rebuilding the whole symbol/usage aggregate on demand. Milestone 4 was implemented on top of those containment fixes; re-measure before choosing Milestone 5/6/7 follow-up work.

Current committed milestones:

```text
58e454dd TREE_SITTER_INDEXING_THROUGHPUT_PLAN.md: Milestone 1 (Instrument current indexing throughput)
8ecf4424 TREE_SITTER_INDEXING_THROUGHPUT_PLAN.md: Milestone 2 (Avoid duplicate parse work per file)
f5f19bc7 TREE_SITTER_INDEXING_THROUGHPUT_PLAN.md: Milestone 3 (Bound UI adoption and add indexing scheduler)
```

Validation performed after Milestone 4:

```sh
meson test -C build-windows-x86_64 --suite anvil --print-errorlogs
```

passed.

## Current state after async indexing work

Relevant files:

```text
data/core/worker_pool.lua
data/core/worker_bootstrap.lua
data/core/workers/treesitter_project_index.lua
data/core/treesitter/project_index_records.lua
data/core/treesitter/symbol_index.lua
src/api/treesitter.c
src/treesitter/service.c
src/treesitter/snapshot.c
```

Current behavior:

- `symbol_index.lua` submits Tree-sitter project indexing to `core.worker_pool`.
- The worker walks roots, reads files, calls native `treesitter.index_text`, constructs symbols/usages, and emits progress/chunks/final messages.
- Symbol and usage phases are split so symbols can become available before usages finish.
- The old cooperative full-project `scan_index()` path was removed.
- Async dirty file/directory refreshes schedule worker-backed full refreshes rather than doing synchronous UI-thread indexing.

Important limitations:

- A single root/phase is now split into a coordinator walk plus bounded shard jobs, so large projects can use multiple Lua worker threads subject to the indexing scheduler cap.
- Symbol and usage phases can parse the same file separately.
- Worker output still uses Lua channels, which deep-copy Lua tables.
- Result chunks are bounded, but large result ownership is not Fred-style native handle/pointer ownership.
- UI-side adoption caches per-file Project path metadata and defers aggregate rebuilds while chunks are arriving; worker output can split one large file across partial chunks to keep Lua channel transfers bounded. Workspace queries can read directly from per-file entries while aggregates are dirty, so dirty aggregates should not force full rebuilds on the picker/query path.
- Workspace symbol/reference commands still do some UI-thread combining/filtering work over ready indexes, and adjacent picker/filetree/search code still has coroutine-based async work that can monopolize the UI thread.

## Fred-style target model

Fred's useful pattern is:

```text
UI thread:
  submit work -> handle
  keep editing
  poll/drain complete results under a strict budget
  adopt only current-generation results

Shared worker pool:
  sleep on queue condition
  pop jobs under queue lock
  run heavy work with no UI lock
  store complete/partial results under result lock
  wake UI

Job:
  owns payload/result memory
  has an atomic cancellation flag
  can be split into subjobs
  can be polled by handle
```

Fred's important throughput properties:

- one shared pool for the whole app;
- work split into many parallelizable tasks;
- native result ownership instead of copying large tables through message queues;
- cancellation via atomics, visible while work is running;
- UI never waits for a worker;
- UI result application is budgeted.

Anvil should move toward that model in stages.

## Design principles

1. Responsiveness remains the hard requirement.
2. Parallelism is useful only when result adoption remains bounded.
3. Do not flood all workers with background indexing if active editor work needs CPU.
4. Use multiple workers for large projects, but avoid excessive per-file job overhead.
5. Avoid parsing the same file twice when outline and usage queries can share a tree.
6. Avoid copying huge Lua tables through channels.
7. Preserve generation/project-path-generation stale result rejection.
8. Preserve dirty open-document overlay semantics.
9. Preserve separate symbol and usage readiness semantics.
10. Prefer measured changes over speculative tuning.

## Milestone 1: Instrument current indexing throughput — Complete

### Goal

Before optimizing, measure where time goes now.

### Status

Complete. Instrumentation was added in:

```text
data/core/workers/treesitter_project_index.lua
data/core/treesitter/symbol_index.lua
src/api/treesitter.c
```

The implementation records worker-side scan/read/parse/query/record/chunk metrics, native `index_text` parse/query metrics, and UI-side chunk adoption/aggregate rebuild metrics. `symbol_index.lua` preserves per-phase diagnostics so symbol-phase and usage-phase costs are not lost between phases.

### Work

Add quiet diagnostics and optional counters for:

- root scan duration;
- directory walk duration;
- file read duration;
- parse duration;
- outline query duration;
- usage query duration;
- symbol/usage record construction duration;
- chunk send wait/backpressure time;
- UI chunk adoption time;
- aggregate rebuild/sort time;
- number of files scanned/indexed/skipped;
- number of symbols/usages emitted;
- chunk sizes by files/items;
- worker id/job id/phase/root.

Suggested files:

```text
data/core/workers/treesitter_project_index.lua
data/core/treesitter/symbol_index.lua
src/api/treesitter.c
```

### Testing

- Add/extend runtime tests only for diagnostics not changing behavior.
- Run a real large-project capture and save summary logs.

### Output

Implemented as quiet baseline-style logs, including per-phase summary fields. A formal saved large-project capture artifact is still pending under Milestone 9.

A short documented baseline:

```text
Tree-sitter indexing baseline:
  project: ...
  files scanned: ...
  files indexed: ...
  wall time symbols: ...
  wall time usages: ...
  top costs: parse/query/read/adopt/etc.
```

## Milestone 2: Avoid duplicate parse work per file — Complete

### Goal

Do outline and usage extraction from one parse when both are requested.

### Status

Complete for worker jobs that request both symbols and usages. `treesitter.index_text` now returns per-query metadata, including query status and error fields. `core.workers.treesitter_project_index` now uses one native `index_text` call with both `outline_query` and `usage_query` when usages are included, so each such file is parsed once instead of once for outline and once for usages.

Important note: the editor still preserves early symbol availability via the existing two-phase project indexing flow. That means a normal full project index can still parse files in the symbol phase and again in the usage phase. Within a job that collects both symbols and usages, duplicate parse work is removed. Future Milestone 4 sharding/strategy work should decide when to run combined phases versus separate early-symbol phases at project scale.

### Current issue

The worker can run symbol and usage phases separately. This preserves early symbol readiness, but it can parse the same file twice.

### Work

Improve `treesitter.index_text` or add a sibling native API so one parse can run multiple independent queries and return per-query statuses.

Required behavior:

- parse once;
- run outline query;
- run usage query optionally;
- if usage query fails/times out/exceeds limits, keep outline results;
- return per-query result metadata:

```lua
{
  language = "c",
  byte_len = n,
  outline = {
    captures = {...},
    capture_count = n,
    status = "ready" | "failed" | "timeout" | "limit",
    error = nil,
  },
  usage = {
    captures = {...},
    capture_count = n,
    status = "ready" | "failed" | "timeout" | "limit" | "skipped",
    error = nil,
  },
}
```

Then update `core.workers.treesitter_project_index` to use this single-parse path when it is indexing both symbols and usages in the same job.

### Caveat

We still want symbols to become visible early. The implementation can choose one of these strategies:

1. **Two-phase for interactivity, one-parse for small/medium projects**
   - symbols first for fast UI availability;
   - use combined parse only when project/file count is below a threshold.

2. **Single pass with early symbol chunks**
   - worker parses once;
   - emits symbol records as soon as each file is done;
   - usage records may be included in later chunks or same file result.

3. **Parse tree/result cache inside worker job**
   - symbols phase parses and caches compact per-file native state;
   - usages phase reuses it.
   - This is harder if phases are separate jobs/workers.

Recommended first approach: add per-query statuses first, then explicitly choose the indexing strategy by project size:

- for small/medium projects, use a single combined pass and emit symbol chunks early from that pass;
- for huge projects, keep early-symbol behavior but measure the duplicate-parse cost before deciding whether to use a combined pass, a parse-result cache, or separate phases;
- track a parse-count metric in diagnostics so the milestone proves that duplicate parsing actually decreased where intended.

Do not call this milestone complete merely because the native API can return per-query statuses. It must either reduce parse count in at least one real indexing mode, or document why early-symbol latency is worth the duplicate parse for that mode.

Implemented evidence: worker runtime tests assert that jobs collecting symbols and usages report one parse call for a file, including the usage-query-failure case where symbols are retained.

### Testing

Add tests for:

- outline succeeds when usage query is invalid;
- usage timeout marks usage incomplete without dropping symbols;
- combined query path returns same symbols as previous outline-only path;
- no regressions in `runtime/treesitter.lua`.

## Milestone 3: Bound UI adoption and add a Lua-side indexing scheduler — Complete

### Goal

Prepare the current Lua worker facade for parallel indexing without causing UI adoption spikes or starving other work.

### Status

Complete as a prerequisite/foundation for sharding.

Implemented:

- chunk adoption applies per-file replacements and marks aggregates dirty instead of rebuilding on every chunk;
- aggregate rebuilds are debounced during chunk storms and forced on phase final / fresh-query boundaries;
- workspace symbol/usage queries do not return fresh results from dirty aggregates without first forcing a rebuild;
- `core.treesitter.index_scheduler` limits queued/running indexing jobs before they enter the shared Lua worker pool;
- scheduler cancellation handles queued/running jobs;
- stale terminal worker messages release scheduler slots;
- tests cover debounce behavior, worker reservation, queued cancellation, and stale terminal completion.

This milestone is a prerequisite for sharding. Multi-worker indexing increases chunk arrival rate; if every chunk rebuilds/sorts the whole index, parallelism can make responsiveness worse.

### Current issues

- `symbol_index.lua` applies chunks into `index.by_path` and can rebuild aggregate symbol/usage lists frequently.
- `worker_pool:drain()` checks its message/time budget between messages, but a single message callback can still do expensive work.
- The current Lua worker pool accepts `priority = "background"`, but does not enforce lanes or background concurrency caps.
- A sharded indexer needs a run-level scheduler so it does not enqueue unlimited shard jobs at once.

### Work: debounced aggregate rebuild

Change chunk adoption to separate cheap per-file replacement from aggregate rebuild/sort.

Suggested state:

```lua
index.aggregate_dirty = true
index.aggregate_rebuild_pending = true
index.next_aggregate_rebuild_at = system.get_time() + 0.05
```

During indexing:

- apply file entries to `index.by_path` immediately;
- mark aggregate dirty;
- rebuild aggregates at most every 50-100ms while chunks are arriving;
- always rebuild on phase final;
- keep command results honest: if aggregate is dirty, report partial/stale/indexing as appropriate instead of claiming a complete fresh result.

### Work: indexing scheduler / lane cap for the Lua pool

Before native lanes exist, add a Tree-sitter indexing scheduler in `symbol_index.lua` or a small helper module.

The scheduler should enforce:

```text
pool_workers = worker_pool.system().worker_count
max_running_index_shards = configurable, default max(1, min(cpu_count - 1, pool_workers - 1, 3))
max_outstanding_index_shards = max_running_index_shards
```

Until native lanes exist, the default must reserve at least one Lua worker for non-indexing work when the system pool has more than one worker. A cap equal to the full pool size is only acceptable after true priority/lane scheduling exists or when an isolated indexing pool is used.

It should not submit every shard to `worker_pool` at once. Instead:

- keep a queue of shard payloads;
- submit only up to the indexing concurrency cap;
- submit another shard when one completes/cancels/fails;
- cancel queued shards cheaply when the run is stale;
- cancel running shard handles when the run is cancelled.

This is a Lua-side substitute for native background lanes until Milestone 7.

### Acceptance gates

Do not proceed to sharding until:

- chunk adoption has a measured max-time budget;
- aggregate rebuilds are debounced or incremental;
- the indexing scheduler can limit outstanding/running shard jobs;
- a test proves an interactive worker-pool job is not stuck behind a large number of indexing shards.

### Testing

- chunks apply without rebuilding on every chunk;
- final result is complete and sorted;
- workspace symbols reports partial/stale correctly while aggregates are dirty;
- a synthetic chunk storm does not produce large UI-frame adoption spikes;
- scheduler never has more than the configured number of running shard jobs;
- cancelling a run cancels queued and running shard work.

## Milestone 3.6: Coroutine async responsiveness audit — Complete as sharding gate / Follow-ups classified

### Goal

Find and classify remaining UI-thread coroutine work that can mask Tree-sitter indexing responsiveness or become worse once indexing is sharded.

This is a gate, not a full rewrite milestone. The purpose is to avoid mistaking `core.add_thread` for real off-thread work in hot paths.

### Status

Complete as a gate for Milestone 4. Recent captures and the static hot-path audit showed that Tree-sitter worker callbacks/chunk adoption were no longer the dominant stalls after the post-Milestone-3 repairs. Remaining large `run_threads_ms` stalls are classified as adjacent coroutine work, primarily fuzzy Project symbol/search UI work and filetree/git refresh work. Those are not prerequisites for sharding because workspace symbol/usage queries can read directly from per-file entries while aggregates are dirty, and sharded chunk adoption stays on the same bounded adoption path.

### Current issue

Several features are asynchronous only in the cooperative-coroutine sense: they yield between operations, but expensive filtering, sorting, result formatting, process-output adoption, and redraw preparation still run on the UI Lua state. This can produce long frames even when worker-pool adoption is bounded.

Initial hot spots from captures and static scan:

- `data/plugins/fuzzy_searcher/init.lua`
  - Project symbol picker polling/formatting Tree-sitter or LSP results;
  - fuzzy grep stream candidate scoring/sorting/publishing;
  - this maps primarily to Milestone 6 if it needs a real worker-backed query path.
- `data/plugins/filetree/init.lua`
  - git status process-output parsing and aggregation;
  - filetree open/refresh paths that may still do synchronous sorting/metadata work;
  - this maps primarily to Milestone 8 if it needs reusable file walking / metadata jobs.
- `data/plugins/gitdiff_highlight/init.lua`
  - process-backed diff/highlight refresh work that can still run expensive adoption on the UI coroutine.
- Older file search paths such as `data/plugins/findfile.lua` and `data/plugins/projectsearch.lua`, which predate the worker-pool indexing model.

### Work

1. Use performance captures to separate:
   - Tree-sitter indexing/adoption/query stalls that must be fixed before Milestone 4;
   - fuzzy workspace symbol/reference/filtering stalls that belong to Milestone 6;
   - filetree/git/file-walking/search stalls that belong to Milestone 8;
   - renderer/layout/input stalls that are outside this throughput plan.
2. Add or keep attribution for `run_threads_ms` slow locations so large coroutine stalls are not misattributed to worker-pool indexing.
3. Apply only small containment fixes before Milestone 4 when they directly protect the indexing path, such as bounded chunk/adoption size, avoiding forced full-index rebuilds, or avoiding synchronous pending-refresh drains.
4. Do **not** migrate all coroutine-based fuzzy/filetree/search work before sharding unless a fresh capture shows it blocks normal editing or hides indexing regressions.

### Acceptance gates before Milestone 4

- Tree-sitter worker callbacks and chunk adoption stay below visible-stutter range in a real capture.
- Dirty aggregate/query paths do not force whole-index rebuilds during picker interaction.
- Remaining >50-100ms stalls are classified by subsystem and either:
  - fixed if they are Tree-sitter indexing prerequisites; or
  - explicitly assigned to Milestone 6, Milestone 8, or another follow-up.
- The plan has a current note explaining why Milestone 4 can proceed despite any remaining non-indexing coroutine stalls.

## Milestone 4: Shard project indexing across multiple worker jobs — Complete

### Goal

Use multiple real worker threads for large projects, now that UI adoption and shard scheduling are bounded.

### Status

Complete. The implementation uses Variant B: a worker-side walk/coordinator job emits bounded file batches, while the UI side owns shard submission and run state through `core.treesitter.index_scheduler`. The same sharded coordinator is used for the symbol phase and the usage phase, preserving early symbol readiness before usage indexing completes.

Implemented details:

- coordinator walk jobs run off the UI thread with `payload.mode = "walk"` and emit bounded compact batch descriptors using per-file language ids rather than copying full language/query tables per file;
- shard jobs consume explicit file batches through the existing `treesitter_project_index` worker;
- the run keeps its own pending batch queue and only submits shards when scheduler capacity is available, so outstanding shard jobs stay bounded instead of queueing the entire project at once;
- per-shard chunk adoption uses the existing bounded `apply_worker_chunk` path;
- phase completion waits for the coordinator and all required shards before pruning old entries or marking a phase ready;
- failed/cancelled shards do not prune old entries through the ready path;
- usage shards reserve deterministic budgets from the run-level project usage cap before submission and return unused reservation capacity for later pending batches;
- diagnostics aggregate coordinator/shard worker metrics and record coordinator/shard job counts.

### Resolved issue

A single root/phase job used to walk and index files mostly serially. It is now split into a coordinator walk and bounded shard jobs.

### Architecture

Split project indexing into coordinator + shards:

```text
symbol_index.lua / run scheduler:
  owns generation/project_paths_generation
  owns cancellation state
  owns global usage budget
  submits bounded shard jobs
  adopts current shard chunks

coordinator/walk job:
  walk roots or consume a prebuilt file list
  create file batches
  return batch descriptors

shard job:
  index N files using its assigned usage budget
  emit bounded chunks/final shard summary
```

Possible variants:

### Variant A: UI-side coordinator

`symbol_index.lua` walks minimally or asks a worker to walk, then submits batch jobs.

Pros:
- easier to integrate with current Lua worker pool;
- no worker submitting worker jobs.

Cons:
- UI-side walking must not become expensive;
- usually needs a separate worker walk job first.

### Variant B: Worker-side walk, UI-side shard scheduler

A coordinator worker walks roots and emits file batches; UI owns shard submission and run state.

Pros:
- filesystem walk stays off UI thread;
- UI can enforce shard concurrency and cancellation using existing handles;
- avoids worker-to-worker submission complexity.

Cons:
- batch descriptors still pass through channels;
- file list/result transport must remain bounded.

### Variant C: Native pool coordinator

Native job records own all subjobs and results.

Pros:
- closest to Fred;
- best long-term performance.

Cons:
- more C infrastructure.

Recommended first step: Variant B.

### Batch sizing

Use batches big enough to avoid overhead but small enough for load balancing:

```text
batch target:
  32-128 files, or
  2-16 MB total file size estimate, or
  one very large file alone
```

Tune from measurements.

### Global usage-cap coordination

Sharding must not allow each shard to emit up to the full project usage cap.

Required semantics:

- the run owns one global `project_usage_cap`;
- each shard receives an explicit `usage_budget` from the scheduler; or
- the scheduler disables usage collection for later shards after the global budget is consumed; or
- a native/shared atomic budget is introduced.

For the Lua implementation, prefer deterministic reserved shard budgets. Budget is reserved when the shard is submitted, not when the shard finishes, so concurrent shards cannot all see and spend the same remaining budget:

```lua
local budget = math.min(run.usage_budget_remaining, per_shard_cap)
run.usage_budget_remaining = run.usage_budget_remaining - budget
shard.usage_budget = budget
```

The sum of queued, running, and completed shard budgets must never exceed `project_usage_cap`. If a shard is cancelled before it starts, its reserved budget may be returned to the run. If a shard is stale, its output is ignored and its budget is not counted as completed output.

Shard final messages must report:

```lua
{
  usage_count = n,
  usage_budget_used = n,
  usage_truncated = bool,
}
```

The scheduler updates accepted usage counts from current-generation shard finals. Stale shard results must not consume completed output budget or affect truncation state.

### State model

For each project generation:

```lua
index.worker_run = {
  run_id = n,
  generation = n,
  project_paths_generation = m,
  phase = "symbols" | "usages" | "combined",
  queued_shards = {},
  running_shards = {},      -- shard_id -> handle
  completed_shards = 0,
  failed_shards = 0,
  cancelled = false,
  seen_paths = {},
  project_usage_cap = n,
  usage_budget_remaining = n,
  usage_truncated = false,
}
```

Adopt shard chunks only if:

- shard id/handle belongs to current run;
- generation matches;
- project paths generation matches;
- phase is expected.

### Completion, pruning, and failure rules

A sharded run may only prune old `index.by_path` entries and mark the phase fully ready after:

- the coordinator/walk stage is complete;
- all required shard batches for the phase have completed successfully;
- all accepted shard results belong to the current generation and project-paths generation.

If any required shard fails or is cancelled:

- do not prune entries for paths that may have belonged to unprocessed/failed shards;
- keep previously indexed entries for those paths;
- mark the phase `failed`, `cancelled`, `partial`, or `stale` rather than `ready`;
- keep already accepted current shard results if they are safe to expose as partial/stale results.

This avoids a partial sharded run deleting valid results from a previous generation.

### Cancellation

Cancellation needs either:

- every running shard handle stored in `running_shards`; and queued shards dropped; or
- a run-level cancellation primitive visible to all shards.

For the current Lua pool, use stored shard handles plus stale-generation rejection.

### Testing

Add runtime tests with synthetic projects:

- multiple shard jobs complete and aggregate correctly;
- shard concurrency never exceeds the configured cap;
- stale shard results are discarded;
- cancelling a run cancels queued/running shards;
- global usage cap is enforced across concurrent shards, including a case where every shard hits its assigned cap;
- excluded paths are not indexed;
- open-doc overlays still suppress disk entries;
- symbols become available before all usage shards finish if that semantic is preserved;
- a failed shard does not prune or delete previous-generation entries for files it did not successfully process.

## Milestone 5: Native result handles or file-backed artifacts — Pending / Larger transport work

### Goal

Avoid deep-copying huge result tables through Lua channels.

### Status

Pending. Current code still sends bounded Lua chunks through channels. Implement this after Milestone 4 measurements if channel copying becomes the next bottleneck.

### Current issue

Lua channels deep-copy values. Even with chunk caps, large projects can spend time and memory copying result tables.

### Options

#### Option A: Native result handles

Add native result storage:

```text
src/worker_pool.c
src/worker_pool.h
src/api/worker_pool.c
```

Lua receives small handles:

```lua
{
  type = "chunk_ready",
  job_id = 123,
  chunk_handle = userdata,
}
```

UI then pulls bounded pieces:

```lua
local chunk = worker_pool.take_chunk(handle, { max_items = 1000 })
```

Pros:
- closest to Fred;
- avoids copying large tables through channels;
- native ownership/lifetime can be explicit.

Cons:
- most implementation work.

#### Option B: File-backed artifacts

Workers write JSONL/binary chunks to temp/cache files and send file offsets/paths.

Pros:
- easier than native handles;
- naturally bounded memory;
- useful for debug/repro.

Cons:
- serialization/deserialization cost;
- temp file lifecycle management;
- JSONL may still be bulky.

#### Option C: Keep Lua chunks but enforce stricter caps

Pros:
- lowest effort.

Cons:
- not enough for huge projects long-term.

Recommended path:

1. Add file-backed artifacts first if native result handles are too large.
2. Move to native handles when building a native worker pool.

### Testing

- stress test with many symbols/usages;
- ensure stale artifact cleanup;
- ensure cancellation removes abandoned artifacts;
- ensure UI drains under budget.

## Milestone 6: Worker-backed workspace symbol/reference filtering — Pending / Depends on compact transport

### Goal

Commands should not perform unbounded fuzzy/filter work on huge ready indexes in one UI frame.

### Status

Pending. Should not be implemented by copying the whole Lua symbol/reference table into a worker per query. Prefer waiting for Milestone 5's compact transport/artifact path.

### Current issue

Even if indexing is async, commands can still be slow if they scan/filter/format huge symbol/reference sets synchronously.

### Work

Add an async query path for large indexes:

```lua
symbol_index.query_symbols_async(query, opts)
symbol_index.query_usages_async(name, opts)
```

Use immediate sync path for small indexes:

```text
if symbol_count < threshold then sync is fine
else submit worker query job
```

Worker query job input must be compact:

- either native/file-backed index handle;
- or a compact snapshot/artifact;
- avoid copying the entire symbol table per query.

This milestone depends on Milestone 5. Do not implement large-index async query jobs by sending the full Lua symbol/reference table through `thread` channels per keystroke. If compact transport is not ready, scope this milestone to small/snapshot-safe experiments only.

UI behavior:

- fuzzy picker opens immediately;
- shows `Indexing...`, `Searching...`, or partial results;
- updates results when worker query completes;
- cancels stale query jobs on text changes.

### Testing

- typing in workspace symbol picker cancels stale query jobs;
- large synthetic symbol list does not block UI;
- result ordering matches sync path for small fixtures.

## Milestone 7: Native shared worker pool — Pending / Large infrastructure project

### Goal

Move from Lua-thread/channel facade to a Fred-style native pool for high-throughput jobs.

### Status

Pending. This is a large standalone infrastructure project. The Milestone 3 Lua scheduler is the current substitute for native lanes/background caps.

### Current issue

`core.worker_pool` is a useful facade, but the underlying implementation still uses:

- Lua states per worker;
- Lua channels;
- deep-copy message passing;
- cooperative shutdown constraints.

### Work

Add native worker pool infrastructure:

```text
src/worker_pool.c
src/worker_pool.h
src/api/worker_pool.c
```

Features:

- shared process-wide pool;
- queue mutex and result mutex separated;
- SDL condition variable for sleeping workers;
- atomic cancel flags;
- native job records;
- native result records;
- optional custom event wakeup;
- Lua-facing handles/status/cancel/drain APIs;
- lanes/priorities:
  - interactive;
  - background;
  - IO.

The existing `core.worker_pool` Lua module should become a facade over the native implementation where possible.

### Testing

- create/destroy pools in tests;
- submit many jobs;
- cancel queued/running jobs;
- verify no hangs on shutdown;
- verify result drain budgets;
- stress with many background indexing jobs while UI tests run.

## Milestone 8: Parallel file walking and metadata indexing — Pending

### Goal

Speed up filesystem discovery and make it reusable.

### Status

Pending. Milestone 4 may introduce a project-index-specific worker walk/coordinator first; this milestone generalizes file walking for reuse by search/filetree/git/etc.

### Current issue

File walking can be expensive and currently lives inside the Tree-sitter worker.

### Work

Create reusable recursive file listing/indexing jobs:

```text
core.workers.recursive_files
```

or native equivalent.

Output:

```lua
{
  path = ...,
  type = "file",
  size = ...,
  modified = ...,
  language_hint = ...,
  project_path_flags = ...,
}
```

Use this for:

- Tree-sitter project indexing;
- fuzzy file indexing;
- project search;
- filetree recursive metadata;
- git scans later.

### Testing

- ignore rules/exclusions match current behavior;
- project path generation changes invalidate stale walks;
- large directory walk can be cancelled;
- filetree/project search can reuse results in later milestones.

## Milestone 9: Performance validation — Pending

### Goal

Prove the speedup and responsiveness improvements.

### Status

Pending. Milestone 1 added instrumentation, but a formal saved real/synthetic large-project capture has not yet been produced. This should be done after Milestone 4 at minimum, and repeated after later transport/query changes.

### Tests/captures

Use synthetic and real projects:

1. Small fixture:
   - correctness.

2. Medium project:
   - stable performance baseline.

3. Huge synthetic project:
   - many files;
   - many symbols;
   - many references.

4. Real large project:
   - e.g. Anvil source, Odin core, or another large workspace.

Metrics:

- total wall-clock indexing time;
- symbols-ready time;
- usages-ready time;
- CPU utilization;
- worker parallelism level;
- UI frame time;
- `run_threads_ms` spikes;
- result adoption spikes;
- memory peak;
- cancellation latency.

Pass criteria:

- UI remains responsive during indexing;
- indexing completes faster on multi-core machines than single-worker baseline;
- no large UI adoption spikes;
- cancellation/restart does not leak stale results;
- workspace symbol/reference commands remain responsive on large ready indexes.

## Risks

### Risk: parallel indexing saturates CPU and hurts editor responsiveness

Mitigation:

- background lane concurrency cap;
- user-configurable worker limit;
- reduce concurrency when app is actively receiving input;
- leave one or more cores free.

### Risk: too many tiny jobs increase overhead

Mitigation:

- batch files by count/size;
- dynamic batch size based on measured costs;
- shard by directory for locality.

### Risk: results arrive out of order

Mitigation:

- generation/project-path generation checks;
- deterministic final sort;
- stable per-file replacement by path.

### Risk: duplicate parsing remains necessary for early symbols

Mitigation:

- use one-parse combined path where appropriate;
- decide per project size/language;
- preserve early symbol chunks.

### Risk: Lua channel copying remains bottleneck

Mitigation:

- stricter chunk caps first;
- file-backed artifacts next;
- native result handles long-term.

## Suggested implementation order

1. Instrument and baseline.
2. Add per-query native result statuses and reduce duplicate parses in at least one measured indexing mode.
3. Bound UI chunk adoption and add a Lua-side indexing scheduler/concurrency cap.
4. Run the Milestone 3.6 coroutine responsiveness audit gate; fix Tree-sitter-indexing prerequisites and classify remaining coroutine stalls.
5. Add coordinator/shard model for multi-worker indexing, including global usage-budget coordination and shard-handle cancellation.
6. Add file-backed or native handle result delivery / compact index snapshots.
7. Add async query/filter path for huge symbol/reference sets using the compact transport from step 6.
8. Build native worker pool/lanes when the Lua facade becomes the bottleneck or when stricter priority scheduling is needed.
9. Reuse the machinery for file walking/search/filetree/git.

## Definition of done

- Large project indexing uses multiple real worker threads.
- Symbols become available quickly without blocking UI.
- Usages/references finish faster than the single-worker baseline.
- Active document Tree-sitter parsing remains responsive.
- UI result adoption stays within budget.
- Workspace symbol/reference commands do not block on huge indexes.
- Cancellation/restart is reliable and fast.
- Memory usage stays bounded for large result sets.
- Performance captures show reduced total indexing time and no indexing-caused input lag.
