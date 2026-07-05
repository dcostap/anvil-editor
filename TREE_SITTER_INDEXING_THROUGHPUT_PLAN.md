# Tree-sitter and File Indexing Throughput Plan

## Goal

The previous async worker work made Tree-sitter project indexing much less visible to the user by moving heavy work away from the UI thread. This plan is the next step: make indexing finish faster by using real parallelism and reducing duplicate work, while preserving the main responsiveness guarantee.

In simple terms:

- the editor must stay responsive;
- indexing should use multiple CPU cores when a project is large enough;
- the UI should adopt results incrementally and cheaply;
- project symbol/reference commands should avoid large synchronous copies/sorts/filtering on every invocation.

This is a throughput plan, not just a responsiveness plan.

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

- A single root/phase is still mostly one worker job, so a huge project does not fully use all CPU cores.
- Symbol and usage phases can parse the same file separately.
- Worker output still uses Lua channels, which deep-copy Lua tables.
- Result chunks are bounded, but large result ownership is not Fred-style native handle/pointer ownership.
- UI-side adoption still rebuilds aggregates from `index.by_path` after chunks.
- Workspace symbol/reference commands still do some UI-thread combining/filtering work over ready indexes.

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

## Milestone 1: Instrument current indexing throughput

### Goal

Before optimizing, measure where time goes now.

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

## Milestone 2: Avoid duplicate parse work per file

### Goal

Do outline and usage extraction from one parse when both are requested.

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

### Testing

Add tests for:

- outline succeeds when usage query is invalid;
- usage timeout marks usage incomplete without dropping symbols;
- combined query path returns same symbols as previous outline-only path;
- no regressions in `runtime/treesitter.lua`.

## Milestone 3: Bound UI adoption and add a Lua-side indexing scheduler

### Goal

Prepare the current Lua worker facade for parallel indexing without causing UI adoption spikes or starving other work.

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

## Milestone 4: Shard project indexing across multiple worker jobs

### Goal

Use multiple real worker threads for large projects, now that UI adoption and shard scheduling are bounded.

### Current issue

A single root/phase job walks and indexes files mostly serially.

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

## Milestone 5: Native result handles or file-backed artifacts

### Goal

Avoid deep-copying huge result tables through Lua channels.

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

## Milestone 6: Worker-backed workspace symbol/reference filtering

### Goal

Commands should not perform unbounded fuzzy/filter work on huge ready indexes in one UI frame.

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

## Milestone 7: Native shared worker pool

### Goal

Move from Lua-thread/channel facade to a Fred-style native pool for high-throughput jobs.

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

## Milestone 8: Parallel file walking and metadata indexing

### Goal

Speed up filesystem discovery and make it reusable.

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

## Milestone 9: Performance validation

### Goal

Prove the speedup and responsiveness improvements.

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
4. Add coordinator/shard model for multi-worker indexing, including global usage-budget coordination and shard-handle cancellation.
5. Add file-backed or native handle result delivery / compact index snapshots.
6. Add async query/filter path for huge symbol/reference sets using the compact transport from step 5.
7. Build native worker pool/lanes when the Lua facade becomes the bottleneck or when stricter priority scheduling is needed.
8. Reuse the machinery for file walking/search/filetree/git.

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
