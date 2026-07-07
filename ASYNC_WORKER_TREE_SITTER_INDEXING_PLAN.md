# Async Worker Pool and Tree-sitter Project Indexing Plan

## Goal

Tree-sitter project indexing must be invisible during normal editor use.

The editor may take minutes to index a huge project if necessary, but indexing must not produce cursor/input/render lag. Any command or UI that depends on incomplete Tree-sitter project results should show a loading/indexing state, stale-results state, or partial-results state. The editor itself must remain responsive.

This plan introduces reusable async worker machinery first, then uses Tree-sitter project indexing as the first serious customer. The machinery should later be reusable for project search, fuzzy file indexing, recursive filetree metadata, git scans, and other expensive background work.

## Current implementation status — 2026-07-06

Implemented and committed foundation:

- `core.worker_pool` facade with Lua worker jobs, budgeted drain, cancellation, lifecycle, stale-result handling, and diagnostics.
- Native worker pool in `src/worker_pool.c` / `src/api/worker_pool.c`, exposed as `worker_pool_native`.
- Native cancel tokens shared across Lua states and observed by Tree-sitter parse/query work.
- Native job path through the `core.worker_pool` facade via `spec.native = true`.

Implemented in the current working tree:

- Native Tree-sitter worker job kind `treesitter_index_text`.
- Native Tree-sitter result handles with `summary()` and bounded `captures(kind, { offset, limit })` access.
- `data/core/treesitter/native_index_adapter.lua` for lazy/bounded capture iteration over native result handles.
- `data/core/workers/treesitter_project_index.lua` now uses native Tree-sitter jobs by default for project parse/query work, falling back to `treesitter.index_text` only if native submit fails.
- Project-index record construction consumes native captures lazily with iterator APIs in `project_index_records.lua`.
- Async targeted file reindex and async dirty-directory refresh now submit targeted worker jobs instead of defaulting to full project refresh when the index is ready.
- Sharded project scans can hand file-backed chunk artifacts to `core.workers.treesitter_project_aggregate`, which builds sorted disk aggregates off the UI thread and returns bounded aggregate chunks for adoption.

Still not done:

- Aggregate construction/sorting no longer has UI-thread fallback rebuild paths: full scans are always sharded/worker-aggregated, async targeted directory refresh uses the aggregate worker, and async single-file targeted refresh uses incremental aggregate updates.
- Workspace symbol/reference query paths are now bounded for synchronous calls: dirty aggregate direct-scan fallbacks were removed, large sync symbol/usage queries return `query-too-large`/pending instead of scanning the UI thread, async oversized symbol queries use persistent worker-produced query artifacts, and sync single-root symbol/usage queries avoid redundant aggregate copies/sorts.
- Watcher/listing setup still has cooperative/UI-side recursive work on non-single-watch backends; single-watch native backends now skip recursive watch registration.
- Dirty/open-document overlay extraction is worker-backed: query/ensure paths only remember open docs for suppression, and parse-ready overlay refreshes submit snapshot text to the project-index worker instead of querying synchronously.
- Large-project perf validation has not yet proven that indexing and adoption are invisible under realistic load.

Historical sections below describe the original failure mode and intended architecture. Treat them as context; the migration plan section tracks the current remaining work.

## Evidence from the performance capture

The motivating perf capture was:

```text
C:\Users\Darius\AppData\Local\Temp\anvil_perf_20260705_210435_summary.txt
```

Key observations:

- Worst frames were dominated by `run_threads_ms`, not drawing, events, or layout.
- Stalls included roughly `783ms`, `481ms`, `377ms`, `348ms`, `249ms`, etc.
- Adjacent frame attribution identified Tree-sitter project indexing:
  - `data/core/treesitter/symbol_index.lua:798`
- Top Lua samples were in symbol aggregate sorting/rebuild:
  - `data/core/treesitter/symbol_index.lua:425`
  - `data/core/treesitter/symbol_index.lua:426`
  - `data/core/treesitter/symbol_index.lua:427`
- The filetree cursor movement commands themselves were usually cheap. Input lag was felt there because queued input waited while the cooperative Tree-sitter coroutine monopolized the UI thread.

The current project-path cache fix reduces one amplification source, but it does not solve the core architectural problem: project indexing still does too much work on the UI thread.

## Original Anvil architecture and failure mode

### Existing async-looking Tree-sitter project index code

Current project indexing lives mostly in:

```text
data/core/treesitter/symbol_index.lua
```

Important current behavior:

- `symbol_index.ensure_scan()` schedules a Lua coroutine with `core.add_thread`.
- `scan_index()` performs project walking, filtering, parsing, querying, symbol extraction, usage extraction, aggregation, and sorting.
- It yields every few files/directories, but individual units can still be large.
- Aggregation/sorting can run for a long time without yielding.

The coroutine is scheduled here:

```lua
core.add_thread(function()
  scan_index(index, generation)
end)
```

That coroutine is still main-thread work. `core.add_thread()` is cooperative, not a real OS worker.

### Original expensive main-thread steps

In `symbol_index.lua`, these can all block the editor:

- Recursive file walking through `Project:files()`.
- Filesystem stats and directory listing.
- `io.open(path, "rb"):read("*a")` in `read_file_text()`.
- `lines_from_text()` on large file contents.
- `n.new_document_state(...)` plus `state:schedule_parse(...)` and `wait_parse(...)` loops.
- `state:query_captures(...)` for outline/usages.
- Lua symbol/usage object construction.
- `rebuild_disk_aggregates(index)`.
- `sort_symbols(symbols)` and `sort_usages(usages)`.

### Existing native Tree-sitter service

Anvil already has real native async parsing infrastructure in:

```text
src/treesitter/service.c
src/api/treesitter.c
data/core/treesitter/init.lua
```

It has:

- an SDL worker thread (`service.worker`)
- a parse job queue
- cancellation flags
- completed queue
- custom completion event `treesitter_complete`
- document state polling

However, this service currently moves only document parsing off-thread. Querying remains synchronous from the caller thread:

```c
bool anvil_ts_document_state_query_captures(...)
```

This function runs query cursor work on the caller thread while holding the Tree-sitter service lock. For project indexing, the caller is currently a Lua coroutine on the UI thread.

Also, project indexing should not enqueue thousands of project file parses into the same service lane used by active open documents. Active document parsing should remain high-priority and separate from background project indexing.

### Existing raw Lua thread/channel API

Anvil already exposes real SDL threads to Lua:

```text
src/api/thread.c
src/api/channel.c
```

Available Lua-style primitives:

```lua
local ch = thread.get_channel(name)
local worker = thread.create("name", function(...)
  -- separate Lua state
end, ...)

ch:push(value)
ch:first()
ch:last()
ch:pop()
ch:wait()
ch:supply(value)
ch:clear()
worker:wait()
```

These are useful, but too raw for editor-wide async work:

- no shared worker pool abstraction
- no standard job handles
- no cancellation protocol
- no result ownership contract
- no progress messages
- no UI-draining budget
- no priorities/lanes
- no reusable lifecycle management
- no standard diagnostics

Some plugins already use raw threads/channels, e.g. project search, but each reinvents its own coordination.

## Fred reference: what it does

Fred is used as a heavy inspiration because it demonstrates a fast, practical editor threading model. We do **not** need to copy it exactly, but its shape is the right reference.

### Author commentary summary

Fred's author described the thread system like this:

- There is one shared thread pool for the entire application.
- The pool is shared deliberately to avoid too much context switching and unnecessary thread proliferation.
- Threads sleep when no work exists.
- Work is submitted into a concurrent input queue guarded by a mutex.
- Results are stored in a separate results queue guarded by a separate mutex.
- The UI asks `result_if_complete(handle)` rather than waiting.
- Cancellation is handled by atomics attached to the work object.
- Long tasks check their cancellation flag and stop when appropriate.
- Tree-sitter parsing runs on worker threads.
- Search, chunked search, extra buffer metadata, suggestions, line guides, recursive file listing, and find-all use the same pool.
- Workers also support opportunistic async maintenance (`async_notify`) such as file tracking.
- Result memory is owned by the worker result object and transferred to whoever consumes the completed result.
- Fred's buffer snapshots are cheap and thread-safe because its buffer representation is persistent/functional; a snapshot is effectively pointer-sized.

Important quote-level ideas:

- "It is a pool that's shared with the entire application."
- "I don't want a lot of context switching happening."
- "Specific requests I want to make to the thread pool ... submits it to this queue."
- "The threads are looking at this queue and if there's nothing there they go back to sleep."
- "You have result_if_complete ... asks the results queue if there's anything that matches that handle."
- "Input queue and separate results queue ... locked independently."
- "We get that pointer back and now we basically own that memory."
- "Cancelling tasks ... driven by atomics."
- "Tree-sitter ... parse the text file ... done on a thread."
- "Line guides ... computed on a background thread."

### Fred setup pattern

From the screenshots, Fred creates one pool and registers it globally:

```cpp
// Setup the thread pool.
Thread::ThreadPool thread_pool;

thread_pool.startup(main_entry_arena);

Thread::set_system_thread_pool(&thread_pool);
```

This is an important architectural point: the pool is application infrastructure, not a feature-local helper.

### Fred handle/result API shape

Fred's thread header exposes typed handles and request/result wrappers.

Representative snippets from the screenshots:

```cpp
namespace Thread
{
    template <Enum E>
    constexpr bool valid_handle(E handle)
    {
        return handle == E{};
    }

    enum class TaskDurationMS : uint64_t { };

    struct TreeSitterResultRequest
    {
        TreeSitterParseHandle handle;
        TaskDurationMS duration_ms;
        bool being_cancelled;
    };

    struct SearchResultsRequest
    {
        SearchResultsHandle handle;
        TaskDurationMS duration_ms;
        bool being_cancelled;
    };
}
```

Fred then exposes the pool methods:

```cpp
// Startup.
void startup(Arena::Arena* arena);

// Shutdown.
void shutdown();

// Async notification.
void async_notify();

// Queueing tasks.
TreeSitterWorkHandle background_task(TreeSitterParseHandle handle);
SearchResultsWorkHandle background_task(SearchResultsHandle handle);
ChunkedSearchResultsWorkHandle background_task(ChunkedSearchResultsHandle handle);
ExtraBufferMetaWorkHandle background_task(ExtraBufferMetaComputeHandle handle);
SuggestionGatherWorkHandle background_task(SuggestionGatherComputeHandle handle);
LineGuidesWorkHandle background_task(LineGuidesComputeHandle handle);
RecursiveFilesWorkHandle background_task(RecursiveFilesComputeHandle handle);
FindAllWorkHandle background_task(FindAllComputeHandle handle);

// Retrieving results.
TreeSitterResultRequest result_if_complete(TreeSitterWorkHandle handle);
SearchResultsRequest result_if_complete(SearchResultsWorkHandle handle);
ChunkedSearchResultsRequest result_if_complete(ChunkedSearchResultsWorkHandle handle);
ExtraBufferMetaComputeRequest result_if_complete(ExtraBufferMetaWorkHandle handle);
SuggestionGatherComputeRequest result_if_complete(SuggestionGatherWorkHandle handle);
LineGuidesComputeRequest result_if_complete(LineGuidesWorkHandle handle);
RecursiveFilesComputeRequest result_if_complete(RecursiveFilesWorkHandle handle);
FindAllComputeRequest result_if_complete(FindAllWorkHandle handle);

// Task cancellation.
void cancel_task(TreeSitterWorkHandle handle);
void cancel_task(SearchResultsWorkHandle handle);
void cancel_task(ChunkedSearchResultsWorkHandle handle);
void cancel_task(ExtraBufferMetaWorkHandle handle);
void cancel_task(SuggestionGatherWorkHandle handle);
void cancel_task(LineGuidesWorkHandle handle);
void cancel_task(RecursiveFilesWorkHandle handle);
void cancel_task(FindAllWorkHandle handle);

// Queries.
uint64_t thread_count() const;
```

Anvil does not need all the typed overload boilerplate. A generic job API can provide the same semantics with less duplication.

### Fred task sorts

Fred's worker dispatch uses `TaskSort` values.

From screenshots/decompiled source:

```cpp
enum class TaskSort
{
    TreeSitterParse,
    SearchResults,
    ChunkedSearchResults,
    ExtraBufferMeta,
    SuggestionGather,
    LineGuides,
    RecursiveFiles,
    FindAll,
};
```

`TaskListEntry` stores a union of task pointers plus the sort:

```cpp
struct TaskListEntry
{
    TaskListEntry* next;
    union
    {
        TreeSitterParse* tree_sitter;
        SearchResults* search_results;
        ChunkedSearchResults* chunked_search_results;
        ExtraBufferMetaCompute* extra_buffer_meta;
        SuggestionGatherCompute* suggestions_gather;
        LineGuidesCompute* line_guides;
        RecursiveFilesCompute* recursive_files;
        FindAllCompute* find_all;
    };
    TaskSort sort;
};
```

The exact typed union is Fred-specific. For Anvil, a generic task record with task kind, job id, payload, and worker function is probably better.

### Fred queue/result structures

Fred keeps input and results separate.

Representative snippets:

```cpp
struct TaskList
{
    TaskListEntry* first;
    TaskListEntry* last;
    TaskListEntry* free_lst;
    uint64_t count;
};

struct TaskResultEntry
{
    TaskResultEntry* next;
    TaskResultEntry* prev;
    void* task_data;
    void* core_completion;
    // Sort is not required because these are already separated into lists by type.
    Timers::Stopwatch sw;
};

bool complete(TaskResultEntry* result)
{
    return result->core_completion != nullptr;
}

struct TaskResultList
{
    TaskResultEntry* first;
    TaskResultEntry* last;
    uint64_t count;
};

struct TaskResults
{
    TaskResultList results[count_of<TaskSort>];
    TaskResultEntry* free_lst;
};
```

Again, the exact structure is Fred-specific, but the principle is critical:

- Workers remove from input queue.
- Workers run task without holding queue mutex.
- Workers mark result complete under result mutex.
- UI checks result queue nonblocking.

### Fred pool data

Fred's `ThreadPool::Data` stores the shared state:

```cpp
struct ThreadPool::Data
{
    ThreadPoolArray pool{};
    Arena::Arena* task_arena;
    Arena::Arena* result_arena;
    OS::Mutex queue_mutex = OS::Mutex::Sentinel;
    OS::ConditionVariable queue_condition = OS::ConditionVariable::Sentinel;
    OS::Mutex result_mutex = OS::Mutex::Sentinel;
    TaskList input_queue{};
    TaskResults results{};
    uint32_t execute_async = false;

    bool terminate = false;
};
```

Important details:

- Queue mutex and result mutex are separate.
- Worker sleeps on queue condition.
- `execute_async` is an atomic/opportunistic flag for maintenance work.
- `terminate` cleanly shuts down workers.

### Fred task push/pop pattern

Fred pushes tasks into a queue and reuses list entries from a free list.

Representative snippets:

```cpp
template <typename H>
void push_task(Arena::Arena* arena, TaskList* lst, H handle)
{
    assert(handle);
    TaskListEntry* entry = nullptr;
    if (lst->free_lst != nullptr)
    {
        entry = lst->free_lst;
        SLLStackPop(lst->free_lst);
        zero_bytes(entry);
    }
    else
    {
        entry = Arena::push_array<TaskListEntry>(arena, 1);
    }

    fill_task(entry, std::move(handle));
    SLLQueuePush(lst->first, lst->last, entry);
    ++lst->count;
}

void pop_task(TaskList* lst)
{
    assert(lst->count != 0);
    TaskListEntry* entry = lst->first;
    SLLQueuePop(lst->first, lst->last);
    --lst->count;
    SLLStackPush(lst->free_lst, entry);
}

bool any_work(const TaskList& lst)
{
    return lst.count != 0;
}
```

Fred's `fill_task` overloads set sort and transfer ownership:

```cpp
void fill_task(TaskListEntry* e, TreeSitterParseHandle handle)
{
    e->sort = task_sort_for(handle.get());
    e->tree_sitter = handle.release();
}

void fill_task(TaskListEntry* e, SearchResultsHandle handle)
{
    e->sort = task_sort_for(handle.get());
    e->search_results = handle.release();
}
```

This is the ownership-transfer idea to preserve for Anvil: once a task is submitted, the worker system owns it until result/cancel/dispose.

### Fred result slot reservation

Fred reserves a result entry before queueing work:

```cpp
template <typename T>
TaskResultEntry* reserve_result_entry_slot(Arena::Arena* arena, TaskResults* results, T task)
{
    TaskResultEntry* entry = nullptr;
    if (results->free_lst != nullptr)
    {
        entry = results->free_lst;
        SLLStackPop(results->free_lst);
        zero_bytes(entry);
    }
    else
    {
        entry = Arena::push_array<TaskResultEntry>(arena, 1);
    }

    entry->task_data = task;
    TaskResultList* lst = &results->results[rep(task_sort_for(task))];
    DLLPushBack(lst->first, lst->last, entry);
    ++lst->count;
    return entry;
}
```

That is why `result_if_complete(handle)` can be cheap: a handle points at a result entry that either is complete or is not.

### Fred worker loop

Fred's worker thread loop is simple:

```cpp
void thread_work_core(void* data_p)
{
    ThreadPool::Data* data = static_cast<ThreadPool::Data*>(data_p);
    while (true)
    {
        TaskListEntry entry{ .sort = TaskSort::Invalid };
        {
            OS::lock_mutex(data->queue_mutex);

            // Wait to be woken up again.
            if (not any_work(data->input_queue) and not data->terminate)
            {
                do
                {
                    OS::wait_condition_var(data->queue_condition, data->queue_mutex, OS::MicroSec::Infinite);

                    // If there's async work, do it first then perform the normal work check.
                    if (os_atomic_u32_eval_cond_assign(&data->execute_async, 0, 1))
                    {
                        FileTrack::async_map_tick();
                    }
                }
                while (not any_work(data->input_queue) and not data->terminate);
            }

            if (data->terminate)
            {
                OS::unlock_mutex(data->queue_mutex);
                return;
            }

            entry = *data->input_queue.first;
            pop_task(&data->input_queue);
            OS::unlock_mutex(data->queue_mutex);
        }

        // Do work.
        assert(entry.sort != TaskSort::Invalid);
        Timers::Stopwatch sw;
        sw.start();
        switch (entry.sort)
        {
            case TaskSort::TreeSitterParse:
                thread_work(entry.tree_sitter);
                break;
            case TaskSort::SearchResults:
                thread_work(entry.search_results);
                break;
            case TaskSort::ChunkedSearchResults:
                thread_work(entry.chunked_search_results);
                break;
            case TaskSort::ExtraBufferMeta:
                thread_work(entry.extra_buffer_meta);
                break;
            case TaskSort::SuggestionGather:
                thread_work(entry.suggestions_gather);
                break;
            case TaskSort::LineGuides:
                thread_work(entry.line_guides);
                break;
            case TaskSort::RecursiveFiles:
                thread_work(entry.recursive_files);
                break;
            case TaskSort::FindAll:
                thread_work(entry.find_all);
                break;
        }

        // Then store completion/result under result mutex.
    }
}
```

Key properties to copy:

- Sleep without spinning.
- Hold queue mutex only to pop work.
- Run work with no queue lock held.
- Mark completion separately.
- Optional maintenance work can be triggered without enqueuing a normal task.

### Fred Tree-sitter handling

Fred's Tree-sitter parse work is one task sort:

```cpp
case TaskSort::TreeSitterParse:
    thread_work(entry.tree_sitter);
    break;
```

In Tree-sitter bridge code, Fred submits parse work to the system pool:

```cpp
TVar10 = Thread::ThreadPool::background_task(
    this_00,
    unique_ptr<Thread::TreeSitterParse>(...)
);
param_3->async_work = TVar10;
param_3->state = Parsing;
```

If an edit arrives while parsing:

```cpp
if (state == Parsing || state == ParsingNeedsReparse)
{
    state = ParsingNeedsReparse;
}
```

Later, the buffer manager polls the async work:

```cpp
Thread::ThreadPool::result_if_complete(
    Thread::system_pool,
    &request,
    buffer->tree_sitter_data.async_work
);

if (request.handle)
{
    buffer->tree_sitter_data.async_work = 0;
    buffer->tree_sitter_data.state = Parsed;
    // transfer tree/result into buffer state
}
```

If a reparse is needed:

```cpp
if (state == ParsingNeedsReparse)
{
    if (!request.handle)
    {
        if (!request.being_cancelled)
        {
            Thread::ThreadPool::cancel_task(pool, async_work);
        }
    }
    else
    {
        // reuse/refresh task state and submit another background_task
    }
}
```

Key properties to copy:

- Main thread marks state; worker does parse.
- Main thread never blocks waiting for parse.
- Stale/edited state becomes "needs reparse".
- Cancellation is best-effort and atomic.
- Finished result is accepted only if still relevant.

### Fred large payload strategy

Fred does not copy huge result data through tiny message channels.

Instead:

- work object owns source snapshot/result memory
- result queue holds a pointer/handle
- UI polls by handle
- when complete, ownership transfers to UI

This works especially well because Fred's buffer is persistent/functional: a snapshot is cheap and thread-safe. Anvil does not have the same editor-buffer snapshot model, so we must adapt:

- For project indexing, workers should read files from disk themselves. The UI should not send file contents.
- UI sends small job config: roots, exclusions, language/query config, symbol-index generation id, and project-paths generation id.
- Worker returns chunks or native-owned snapshots, not one enormous Lua table through a channel in a single frame.

## What Anvil should build

We should implement reusable core machinery and make Tree-sitter project indexing its first customer.

This should be designed as application infrastructure, not a one-off plugin hack.

## Design principles

1. UI thread never waits for background jobs.
2. Background jobs have handles.
3. Jobs can report progress, partial results, final results, errors, and cancellation.
4. Result draining on UI is budgeted.
5. Cancellation is best-effort and cheap.
6. Active document responsiveness has priority over background project work.
7. Payloads are not blindly copied as giant Lua tables through channels.
8. The API is reusable by future plugins/core systems.
9. Diagnostics are first-class.
10. Tree-sitter project indexing can be slow, but not visible as lag.

## Corrections from code audit

The plan must account for these concrete Anvil constraints:

- `thread.create` workers are real OS threads with separate Lua states. They do not run under Anvil's cooperative coroutine scheduler, so code paths that call `coroutine.yield()` cannot be moved into a raw worker unchanged.
- Each `thread.create` worker boots a full Lua state and runs `core/start.lua`; worker modules should avoid requiring UI/editor modules with side effects.
- Anvil channels are unbounded and deep-copy Lua values; they are fine for control and small messages, but not for arbitrary large project-index payloads without backpressure.
- Pure Lua worker threads cannot currently push arbitrary Anvil custom events; completion wakeups require native support or update-loop polling.
- Current Tree-sitter document-state parsing service is shared with active documents. Project indexing must not flood that service with bulk parses.
- `TSQuery` userdata and other native objects are Lua-state-local. Worker states must compile/cache their own queries or use a native helper that owns query compilation.
- Existing full-scan migration is not enough. `reindex_file`, `mark_directory_dirty`, watcher-triggered refreshes, and recursive watch/listing paths must also be made nonblocking.

## Proposed Anvil architecture

### Layer 1: reusable worker pool facade

Add a Lua-facing module:

```text
data/core/worker_pool.lua
```

Backed by a stable facade so the implementation can evolve. A small generic prototype may use existing `thread.create` + `thread.get_channel`, but **Tree-sitter project indexing should not ship on the raw channel-only design**. Real Tree-sitter indexing needs native-visible cancellation, completion wakeups, and bounded/handle-based result delivery early, not as an afterthought.

Proposed Lua API:

```lua
local worker_pool = require "core.worker_pool"

local pool = worker_pool.system()

local handle = pool:submit({
  kind = "treesitter_project_index",
  priority = "background",
  generation = generation,
  project_paths_generation = project_paths.generation(),
  phase = "symbols",
  payload = payload,
  on_progress = function(msg) end,
  on_result = function(msg) end,
  on_error = function(msg) end,
  on_cancelled = function(msg) end,
  on_complete = function(msg) end,
})

pool:cancel(handle)
local status = pool:status(handle)
pool:drain({ max_ms = 1.0, max_messages = 64 })
pool:shutdown({ cancel_running = true, timeout_ms = 1000 })
```

The exact callback API can evolve, but the underlying concepts should remain:

- `submit` returns a handle immediately.
- `cancel` never waits.
- results are consumed by polling/draining.
- `drain` is called from the main update loop or a core thread with a strict budget.
- `shutdown`/`close` is explicit: tests, plugin reloads, and editor shutdown must not leave persistent workers blocked forever in `channel:wait()` or detached by `__gc`.

### Worker lanes

The pool should support lanes or priorities. Minimum useful lanes:

- `interactive`
  - jobs directly related to visible/current document behavior
  - should be scarce and fast
- `background`
  - project indexing, git scans, filetree recursive counts, etc.
- `io`
  - optional future lane for IO-heavy operations if needed

Tree-sitter project indexing should use `background`.

Open-document Tree-sitter parsing should remain separate or high-priority. We should not let project indexing starve current-document parsing.

### Messages

Worker-to-UI messages should have a standard envelope:

```lua
{
  job_id = 123,
  generation = 45,
  project_paths_generation = 12,
  kind = "treesitter_project_index",
  phase = "symbols" | "usages" | "all",
  type = "progress" | "chunk" | "final" | "error" | "cancelled" | "log",
  time = 123.456,
  payload = { ... },
}
```

The UI should discard stale messages by job id, symbol-index generation, and `project_paths_generation`. Project roots/exclusions/ranks can change while a worker is scanning, independently from the symbol index generation; stale project-path payloads must be cancelled/restarted or rejected at adoption.

### Cancellation

Cancellation must be visible to a running job without requiring the worker's top-level input loop to read another message.

A naive Lua-worker design like this is **not sufficient**:

```lua
-- insufficient for long-running jobs
worker.input:push({ type = "cancel", job_id = handle.id })
```

If the worker is inside `handler.run(...)`, it will not pop that cancel message until the job returns. That means the cancel flag is never flipped during the long operation. This would fail the core requirement for generation restarts and user-triggered cancellation.

Acceptable cancellation mechanisms:

- native job handle with SDL atomic cancel flag, Fred-style
- shared-memory/atomic cancel flag visible to the running worker
- per-job control channel that the handler itself polls directly while it runs
- native Tree-sitter parse/query callbacks that check the same cancel flag

For Tree-sitter project indexing, prefer native atomics. The worker must check cancellation:

- before listing next directory
- before reading next file
- before parsing next file
- inside Tree-sitter parse progress callback where possible
- around/between query operations
- before sending next chunk
- before aggregate/sort/finalization

Cancellation is still best-effort, but native parse/query calls must be bounded by timeouts and/or progress callbacks. A running index job must stop emitting work promptly after cancellation and must never be adopted if its generation is stale.

### Result delivery strategy

For small/medium messages:

- channel table messages are acceptable if they are bounded.

For large Tree-sitter index results, raw `channel:push(table)` is dangerous because Anvil channels deep-copy Lua values into an unbounded linked queue. A fast worker can allocate thousands of messages faster than the UI can drain them. A strict UI drain budget does not by itself provide backpressure.

Required result-delivery rules:

- progress messages must be coalesced; workers should not enqueue one progress message per file
- chunks must have item and approximate byte caps
- output queues need a high-water/backpressure policy
- final large aggregates must not be copied through one giant Lua table
- stale job outputs should be cheaply droppable

Preferred strategies:

1. Native result handles
   - worker stores result/chunks in native-owned memory or a native job object
   - UI receives/polls a small handle
   - UI pulls bounded chunks from the handle
   - closest to Fred's pointer/result-entry model

2. File-backed temp/cache artifact
   - worker writes JSONL/binary chunks to temp/cache storage
   - UI reads bounded chunks incrementally
   - useful when native result ownership is too much for a first pass

3. Bounded chunked Lua results
   - acceptable for prototypes and small jobs only
   - must include high-water/backpressure and chunk caps
   - should not be the shipped mechanism for huge Tree-sitter project indexes unless measured safe

The architecture should make native handles or file-backed artifacts available before relying on the worker pool for large project indexing.

### UI draining budget

Add a core-level drain call, e.g. in `core.step()` or a background core thread:

```lua
worker_pool.system():drain({
  max_ms = config.worker_pool_drain_budget_ms or 1.0,
  max_messages = config.worker_pool_drain_max_messages or 64,
})
```

This is essential: moving work off-thread is not enough if the UI then applies 50,000 symbols in one frame.

### Worker lifecycle and shutdown

Persistent workers need an explicit lifecycle; relying on Lua `__gc` to detach threads is not acceptable for tests, reloads, or editor shutdown.

Required lifecycle API:

```lua
pool:shutdown({
  cancel_running = true,
  drain = false,
  timeout_ms = 1000,
})
```

Semantics:

- mark the pool closing so no new jobs are accepted
- cancel queued and running jobs according to options
- wake workers blocked in `channel:wait()` / condition waits
- join workers with a bounded timeout where supported
- after timeout, log quietly and detach/abandon only as a last resort
- release channels/native result handles/temp artifacts
- tests must be able to create and destroy isolated pools repeatedly

Current Lua `Thread:wait()` is blocking and has no timeout/detach API exposed to Lua. Therefore a pure Lua Phase 1 pool can only guarantee clean shutdown for cooperative/idle workers. Bounded shutdown for stuck native calls requires native support such as timed join/detach or a fully native pool lifecycle.

The system pool should hook into editor shutdown. Test pools should be independent from the global system pool when possible.

## Tree-sitter project indexing implementation plan

### Module being refactored

Primary file:

```text
data/core/treesitter/symbol_index.lua
```

Current state should be split into:

- UI-side index state and query API
- worker-side index builder
- native Tree-sitter indexing helper, if needed

### Worker entrypoint

Implemented worker module:

```text
data/core/workers/treesitter_project_index.lua
```

Supporting worker-safe record/adapter modules:

```text
data/core/treesitter/project_index_records.lua
data/core/treesitter/native_index_adapter.lua
```

The worker module runs in a worker Lua state. File walking, file reads, record construction, chunking, and targeted file/directory indexing now happen there. Tree-sitter parse/query is delegated to native `treesitter_index_text` worker-pool jobs where available.

Input payload should contain only serializable data:

```lua
{
  job_id = 123,
  generation = 45,
  project_paths_generation = project_paths.generation(),
  roots = {
    {
      path = "C:\\Projects\\...",
      role = "root",
      rank_penalty = 0,
      flags = { symbols = true, usages = true },
    },
  },
  excluded = {
    { path = "...", symbols = false, usages = false },
  },
  ignore_rules = { ... },
  languages = {
    c = {
      id = "c",
      grammar = "c",
      files = { "%.c$", "%.h$" },
      query_sources = {
        outline = "...",
        -- Preserve current fallback semantics: use usages.scm when present,
        -- otherwise locals.scm can drive usage/reference extraction.
        usages = "...",
        locals = "...",
      },
      usage_query_kind = "usages" | "locals" | nil,
      parse_timeout_ms = 750,
      outline_limits = { ... },
      usage_limits = { ... },
    },
  },
  options = {
    include_usages = true,
    usage_cap = 50000,
    max_file_bytes = ...,
  },
}
```

Important: worker should not require live `core` state or UI objects. It should work with plain payload data.

### Worker responsibilities

Current worker responsibilities:

1. Walk roots recursively. **Implemented** for full scans, coordinator batch walks, and targeted directory scans.
2. Apply ignore and exclusion rules. **Implemented**.
3. Identify language by filename patterns. **Implemented**.
4. Read files from disk. **Implemented** in Lua worker.
5. Parse with Tree-sitter off the UI thread. **Implemented** through native `treesitter_index_text` jobs.
6. Query outline/usages off the UI thread. **Implemented** through native `treesitter_index_text` jobs.
7. Construct symbol/usage records. **Implemented** in Lua worker, using lazy native capture iteration when available.
8. Aggregate and sort off the UI thread. **Not implemented**; this remains a major gap.
9. Emit progress and bounded chunks. **Implemented** with optional file-backed artifacts.
10. Emit final snapshot metadata. **Implemented**.
11. Stop quickly when cancelled. **Partially implemented**; Lua worker loops, native jobs, parse, and query all observe cancellation, but broader shutdown/backpressure behavior still needs stress validation.

### UI-side responsibilities

`symbol_index.lua` is now mostly state management for the async paths, but still owns some expensive UI-side work:

- keep current index per root/generation/project-paths-generation — **implemented**
- submit/cancel worker jobs — **implemented**
- receive progress/chunks/final — **implemented**
- apply chunks under budget — **partially implemented** through pool drain budgets and bounded chunks; adoption work itself still needs more budgeting/perf validation
- expose query APIs to commands/menus — **existing**
- preserve separate symbol and usage readiness:
  - `symbol_status`: idle/indexing/ready/stale/failed/cancelled
  - `usage_status`: idle/indexing/ready/stale/failed/cancelled/truncated
- allow symbols to become ready before slower usage/reference indexing completes — **implemented** for sharded symbol/usages phases
- discard stale job messages by job id, symbol-index generation, and project-paths generation — **implemented**

UI should never do expensive parse/query/aggregate work. Parse/query and aggregate construction have moved off the UI path for project indexing, workspace query paths now refuse oversized synchronous scans, and open-document overlays are refreshed by worker-backed snapshot indexing instead of synchronous query extraction.

### Dirty open-document overlay semantics

Current `symbol_index.lua` does not expose only disk-index results. It also tracks open documents and avoids stale disk answers for dirty buffers. The async migration must preserve this behavior:

- disk-index entries for dirty open documents must be suppressed or marked stale
- live open-document symbols/usages must overlay project results
- duplicate disk/live entries for the same path must not appear
- stale generation disk results must not replace newer live document state
- open-document overlay extraction must be bounded; if outline/usage extraction for a large open document is expensive, it should use the active-document Tree-sitter ready state or its own worker-backed path rather than running heavy query/aggregation work synchronously

This overlay should remain UI-owned state layered over the worker-built disk index, because workers index saved file contents from disk and cannot see unsaved editor text unless given an explicit snapshot.

### Query-time UI responsiveness

Moving indexing off-thread is not enough if commands still scan/sort/fuzzy-match the entire ready index on the UI thread. Current query paths rebuild combined symbol lists, copy arrays, sort, and fuzzy-match during command execution. The migration should also prevent command latency on large indexes:

- keep pre-sorted/pre-ranked aggregate symbol lists from the worker where possible
- cache combined disk+open-document views and invalidate them incrementally
- avoid full-list copies on every `workspace_symbols()` call
- apply result limits before expensive formatting where possible
- make fuzzy filtering over very large symbol/reference sets budgeted, incremental, or worker-backed
- preserve separate symbol/usage query behavior so workspace symbols can be responsive even while usage indexing is still running

Commands may show loading/stale/partial results, but they should not do unbounded per-query work on the UI thread.

### Dedicated Tree-sitter indexing native support

There are two implementation paths to consider, but only the native/independent path satisfies the real responsiveness requirement for large projects.

#### Option A: Lua worker using existing `treesitter` document-state module

This is useful only as a narrow prototype or compatibility experiment. It should not be the rollout path for real project indexing.

Pros:

- fastest to experiment with
- can reuse some Lua extraction/record-normalization logic
- fewer C changes initially

Blocking/serious cons:

- current `symbol_index.lua` wait logic uses `coroutine.yield()` in `wait_parse()`; a raw OS worker thread has no Anvil coroutine scheduler to resume that yield
- replacing the yield with a busy poll would waste CPU; replacing it with sleep still leaves other issues below
- `new_document_state():schedule_parse()` uses the existing global active-document Tree-sitter service
- thousands of project parses could starve or contend with active document parsing
- `query_captures()` is synchronous and holds the service lock while collecting captures
- compiled query userdata is per Lua state and cannot be passed from UI to worker; workers must compile/cache queries independently
- channel result copying may become expensive or unbounded

Therefore: do not make Phase 2 depend on this option for the actual fix. If used at all, mark it as non-shipping scaffolding. The real project-index path should use a separate worker-safe parse/query helper or a dedicated project-index native service before large-project rollout.

#### Option B: Add native worker-safe project indexing helper

Status: **implemented as a native worker-pool job**, not as a standalone `treesitter.index_file` Lua API.

Current API shape:

```lua
local native_pool = require "worker_pool_native"
local pool = native_pool.new({ name = "...", worker_count = 1 })
local handle = pool:submit({
  kind = "treesitter_index_text",
  language = "c",
  text = source_text, -- or path = file_path
  outline_query = "...",
  usage_query = "...",
  parse_timeout_ms = 1000,
  query_timeout_ms = 20,
  max_captures = 50000,
})
```

Results are returned as native handles through `pool:drain(...)`:

```lua
local summary = result:summary()
local captures = result:captures("outline", { offset = 1, limit = 512 })
```

The `core.worker_pool` facade can also submit native jobs with `native = true` and receive the result handle through normal callbacks.

This gives the desired independent parse/query lane: project files are parsed and queried in native worker threads without using the active-document Tree-sitter service.

Earlier possible API:

```lua
local ts = require "treesitter"

local result, err = ts.index_file({
  path = path,
  grammar = language.grammar,
  outline_query = language.query_sources.outline,
  usage_query = language.query_sources.usages or language.query_sources.locals,
  usage_query_kind = language.query_sources.usages and "usages" or "locals",
  parse_timeout_ms = language.parse_timeout_ms,
  query_timeout_ms = ...,
  max_captures = ...,
  include_usages = true,
  cancel = cancel_token,
})
```

The cancellation token must be native-visible. If `ts.index_file` is called from a Lua worker and `pool:cancel(handle)` fires while the helper is inside parse/query work, parse progress callbacks and query progress callbacks must be able to observe the same cancel flag before the native call returns.

Alternative API shape:

```lua
local cancel = worker_pool.cancel_token(handle)
local result, err = ts.index_file(path, language_spec, { cancel = cancel })
```

Or, for the strongest ownership model, make the whole project-index operation a native worker-pool job so parse/query callbacks directly read the job's atomic cancel flag.


Current native job capabilities:

- read file in C or accept text — **implemented**
- create parser locally — **implemented**
- parse locally — **implemented**
- compile/query locally — **implemented**
- preserve existing usage query fallback (`usages.scm` first, then `locals.scm`) and usage limits/fingerprint inputs — **implemented in the Lua project-index worker payload/fingerprint logic**
- check cancellation during parse/query — **implemented**
- return captures through a bounded native result handle — **implemented**
- return already-normalized compact records — **not implemented**; records are still constructed in the Lua worker

This avoids the active-document service lane and is closer to Fred's model.

Recommended approach status:

- Build the `core.worker_pool` facade first — **done**.
- Add native-visible cancellation — **done**.
- Add bounded/handle-based result delivery — **partially done** for native Tree-sitter capture results.
- Add completion wakeups — **not done**; draining still happens from the normal update/drain loop.
- Replace the current indexer for real project parse/query — **mostly done** for full scans and targeted file/directory refreshes.
- Keep project indexing independent from the active-document Tree-sitter parse service — **done for the worker-backed project indexing paths**.

### Chunking and finalization

Worker should emit periodic progress:

```lua
{ type = "progress", files_scanned = 1234, files_indexed = 200, current = path }
```

Worker should emit chunks:

```lua
{
  type = "chunk",
  root = root,
  files = {
    {
      path = path,
      fingerprint = fingerprint,
      symbols = { ... },
      usages_by_name = { ... },
      usage_count = 12,
      usage_complete = true,
    },
  },
}
```

Worker should emit final:

```lua
{
  type = "final",
  roots = roots,
  files_total = n,
  files_scanned = n,
  symbols_total = n,
  usage_count = n,
  usage_truncated = bool,
  duration_ms = n,
}
```

UI can either:

- maintain per-file map and build searchable aggregate incrementally; or
- accept a final pre-sorted aggregate from the worker.

To minimize UI work, worker should sort final aggregate. UI should swap in references or apply bounded chunks.

## Reusable worker pool implementation details

### Initial Lua implementation using existing threads/channels

A pragmatic first implementation can be pure Lua on top of existing native thread/channel support, but only as the facade/protocol prototype and for small generic jobs.

It is **not** sufficient by itself for Tree-sitter project indexing because:

- cancellation messages queued to the worker input channel cannot interrupt a running handler
- output channels are unbounded and deep-copy payloads
- pure Lua workers cannot currently push Anvil custom events
- existing Tree-sitter document-state wait code uses cooperative coroutine yielding
- routing project parses through the active-document Tree-sitter service can cause service contention

Files:

```text
data/core/worker_pool.lua
data/core/worker_bootstrap.lua
data/core/workers/treesitter_project_index.lua
```

Process:

- `worker_pool.system()` creates N persistent workers.
- Each worker has input and output channels.
- Main thread dispatches jobs round-robin or by lane.
- Worker waits on input channel.
- Worker loads a job handler by kind.
- Worker sends messages to output channel.
- Main thread drains output channels with a budget.

Rough sketch:

```lua
-- UI state
local pool = {
  workers = {},
  next_job_id = 0,
  jobs = {},
}

function pool:submit(spec)
  self.next_job_id = self.next_job_id + 1
  local job_id = self.next_job_id
  local worker = choose_worker(self, spec)
  local handle = { id = job_id, worker = worker.id, generation = spec.generation }
  self.jobs[job_id] = { spec = spec, handle = handle, status = "queued" }
  worker.input:push({ type = "run", job_id = job_id, kind = spec.kind, payload = spec.payload })
  return handle
end

function pool:cancel(handle)
  local worker = self.workers[handle.worker]
  if not worker then return end
  -- For tiny prototype jobs this can be a control message, but real jobs need
  -- a per-job cancellation primitive visible while handler.run() is executing.
  if handle.cancel then handle.cancel:set(true) end
  worker.input:push({ type = "cancel", job_id = handle.id })
end

function pool:drain(opts)
  local deadline = system.get_time() + ((opts.max_ms or 1) / 1000)
  local count = 0
  repeat
    local did = false
    for _, worker in ipairs(self.workers) do
      local msg = worker.output:first()
      if msg then
        worker.output:pop()
        self:dispatch_message(msg)
        did = true
        count = count + 1
        if count >= (opts.max_messages or 64) then return count end
        if system.get_time() >= deadline then return count end
      end
    end
  until not did
  return count
end
```

Worker bootstrap rough sketch for small prototype jobs:

```lua
local input = thread.get_channel(input_name)
local output = thread.get_channel(output_name)

while true do
  local msg = input:wait()
  input:pop()

  if msg.type == "shutdown" then break end

  if msg.type == "run" then
    -- msg.cancel must be a per-job primitive that handler.run() can inspect
    -- while it is running. A later { type = "cancel" } input message is not
    -- enough for long jobs.
    local ok, err = pcall(function()
      local handler = require("core.workers." .. msg.kind)
      handler.run(msg.payload, {
        cancelled = function() return msg.cancel and msg.cancel:get() end,
        send = function(out)
          -- send() must obey chunk caps/backpressure for non-trivial jobs.
          out.job_id = msg.job_id
          output:push(out)
        end,
      })
    end)
    if not ok then output:push({ job_id = msg.job_id, type = "error", error = tostring(err) }) end
  elseif msg.type == "cancel" then
    -- Only useful for queued/not-yet-started jobs unless backed by a shared
    -- cancel primitive.
  end
end
```

This is not as efficient or as safe as a native pointer-handle pool. It gets the API shape and simple integration in place, but it is not the final mechanism for large Tree-sitter project indexing.

### Later native implementation option

If Lua channel copying is too expensive, add a native job system:

```text
src/api/worker_pool.c
src/worker_pool.c
src/worker_pool.h
```

Conceptually closer to Fred:

- native job records
- native result records
- separate queue/result locks
- SDL condition variables
- SDL atomics for cancellation
- result handles exposed to Lua as userdata
- Lua drains completed handles
- optional custom event wakeup

This can coexist behind the same `core.worker_pool` facade.

### Custom event wakeup

For better latency without polling too often, register a worker completion custom event:

```text
worker_pool_complete
```

Native worker threads can push an SDL custom event when they enqueue output. Pure Lua workers cannot currently do this because `custom_events.c` does not expose a generic Lua API for registering/pushing custom events from worker states. If wakeup events are part of Phase 1, add the native binding then; otherwise Phase 1 must drain from the normal update loop.

This mirrors current Tree-sitter complete event:

```text
treesitter_complete
```

## Testing plan

### Worker pool tests

Add runtime tests under:

```text
tests/lua/runtime/worker_pool.lua
```

Test:

- submit returns immediately
- worker produces result
- multiple jobs complete
- cancellation emits cancelled or stale result is ignored
- errors are delivered as error messages
- result draining respects message count budget
- result draining respects time budget as much as possible
- shutdown does not leak/hang
- pools can be created and destroyed repeatedly in tests
- running long job cancellation is visible while the handler is running
- output high-water/backpressure prevents unbounded queued messages

Do not test exact timings except broad nonblocking expectations.

### Tree-sitter project indexing tests

Add runtime tests under:

```text
tests/lua/runtime/treesitter_project_index_async.lua
```

Test:

- indexing produces expected symbols for a small fixture
- excluded paths are not indexed
- stale generation results are discarded
- canceling a running job stops further useful output and prevents final adoption
- commands see `indexing` status before final result
- full scan results match current synchronous behavior for representative files
- targeted file reindex is worker-backed and does not stall UI
- dirty-directory/watch-triggered reindex is worker-backed and coalesces repeated events
- stale generation chunks/finals are discarded cheaply
- dirty open documents suppress stale disk-index entries and overlay live symbols/usages without duplicates
- existing `usages.scm` -> `locals.scm` fallback and usage limits are preserved
- symbol readiness and usage readiness remain separate; symbols can become queryable while usages are still indexing
- project path generation changes during an index cancel/restart or discard the stale worker result

### UI responsiveness/perf tests

Add or extend perf smoke tests:

- create a synthetic large project
- start project indexing
- drive cursor movement/filetree movement
- assert no `run_threads_ms` spikes attributable to symbol indexing
- assert no over-budget frames from project index apply path
- assert workspace-symbol/reference commands do not perform unbounded copy/sort/fuzzy work on ready large indexes

The key pass condition is not "index fast"; it is "index invisible".

## Migration plan

### Phase 0: keep current project-path cache fix

The recent `project_paths` caching fix should stay. It removes repeated effective-entry stat/rebuild overhead and helps both old and new indexing.

### Phase 1: introduce worker_pool facade and minimal protocol — done

- Add `data/core/worker_pool.lua`. **Done**.
- Add worker bootstrap module for small generic prototype jobs. **Done**.
- Back the prototype with existing `thread.create` and channels. **Done**.
- Define stable public concepts: job id, handle, generation, project-paths-generation, phase, status, progress, result, error, cancel, shutdown. **Done**.
- Add tests for small jobs, error delivery, stale generation discard, budgeted drain, and pool shutdown. **Done**.
- Add quiet logs and perf counters. **Done/ongoing**.
- Explicitly mark this prototype as insufficient for large Tree-sitter indexing until native cancel/backpressure/result delivery exists. **Superseded by native pool work in Phase 2**.

### Phase 2: add native job primitives needed by real background infrastructure — mostly done

- Add native-visible per-job cancellation, preferably SDL atomic-backed handles. **Done**.
- Add native cancel tokens that can be shared across Lua worker states. **Done**.
- Add native timed join/detach or native pool lifecycle if bounded shutdown is required beyond cooperative Lua jobs. **Native lifecycle exists; timed detach semantics still need stress review**.
- Add a completion wakeup path (`worker_pool_complete`) or document that drain is update-loop-only until the native event binding exists. **Not done; drain is update-loop/manual**.
- Add bounded/handle-based result delivery, or file-backed artifacts, so workers cannot grow unbounded channel queues. **Partially done**: native Tree-sitter result handles and file-backed project-index artifacts exist; generic high-water/backpressure policy still needs work.
- Decide whether this is a generic native worker pool (`src/api/worker_pool.c`, `src/worker_pool.c`) or native support behind the Lua facade while workers remain Lua-based. **Done: generic native worker pool plus Lua facade bridge**.
- Add stress tests for cancellation of a running long job and for output backpressure/high-water behavior. **Cancellation tests exist; backpressure/high-water stress tests remain**.

### Phase 3: make Tree-sitter project parse/query worker-safe and independent — done for project worker paths

- Add native `treesitter.index_file` / `treesitter.index_text`, or a dedicated project-index native service. **Done as native job kind `treesitter_index_text`**.
- Do not route project files through the active-document Tree-sitter document-state service. **Done for worker-backed project indexing**.
- Ensure project indexing cannot starve active-document Tree-sitter parsing. **Architecturally improved by separate native pool; still needs perf validation under load**.
- Ensure query execution is off UI thread. **Done for project indexing worker paths**.
- Add cancellation checks/timeouts for parse and query. **Done**.
- Preserve current usage query semantics, including `usages.scm` -> `locals.scm` fallback, usage limits, and fingerprint inputs. **Done in worker payload/fingerprint logic**.
- Ensure query compilation/cache strategy is per worker/service and does not pass TSQuery userdata across Lua states. **Done; query source strings are passed, native jobs compile locally**.

### Phase 4: add Tree-sitter project indexing worker — mostly done

- Add `core.workers.treesitter_project_index` or native equivalent. **Done**.
- Move file walking and file reading into worker. **Done**.
- Use the independent project-index parse/query helper. **Done through native `treesitter_index_text` jobs**.
- Emit coalesced progress and bounded result chunks/handles. **Done for chunks; native capture handles are used internally by the worker**.
- UI `symbol_index.lua` submits/cancels jobs and adopts only current symbol-index generation plus current project-paths generation results. **Done**.
- Preserve separate symbol and usage statuses/progress/adoption, or split symbols/usages into separate worker jobs/streams. **Done for sharded symbol/usages phases**.
- Migrate full scan, targeted file reindex, dirty-directory reindex, and watcher-triggered refresh paths. **Full scan done; targeted file done; dirty-directory done; watcher-triggered refresh benefits from dirty-directory path but watcher setup/listing still needs work**.
- Add bounded/cached query-time filtering so commands do not scan/sort/fuzzy-match the entire index per invocation. **Not done**.

### Phase 5: remove old synchronous/cooperative indexer path — mostly done

- Delete or disable `core.add_thread(function() scan_index(...) end)` project indexing path. **Done for project indexing; full scans are always sharded worker jobs with worker aggregate adoption**.
- Remove/replace cooperative heavy paths in `reindex_file`, `mark_directory_dirty`, and watcher-triggered scan/rebuild code. **Async file and directory dirty paths are worker-backed; sync/fallback reindex paths were removed rather than retained as safety adapters**.
- Keep only UI-side status/query/adoption in `symbol_index.lua`. **Mostly done; open-document overlays now submit worker-backed snapshot jobs and query paths no longer extract them synchronously**.
- Preserve public symbol index APIs used by commands. **Ongoing; tests cover current behavior**.

### Phase 6: apply machinery elsewhere

Good follow-up customers:

- project search / grep
- fuzzy_searcher file cache building
- filetree recursive folder count/metadata
- git status scanning
- markdown vault indexing
- large document metadata/line guide computation

## Remaining prioritized path from current state

1. **Aggregate construction off the UI path — done for project indexing paths**
   - Normal full scans are always sharded worker jobs; the non-sharded fallback path was removed.
   - Full scans and async targeted directory refresh use `core.workers.treesitter_project_aggregate` to load chunk artifacts, build/sort disk aggregates off-thread, and deliver bounded aggregate chunks.
   - Async single-file targeted refresh uses incremental aggregate updates for the changed path instead of full aggregate rebuilds.
   - The old synchronous file/directory reindex helpers and UI `rebuild_disk_aggregates()` fallback were removed from active code paths.

2. **Finish workspace query path hardening**
   - Synchronous workspace symbol/usage calls are bounded now: large ready indexes return pending/`query-too-large` instead of scanning/fuzzy-matching on the UI thread.
   - Oversized async symbol queries use persistent query artifacts produced by the aggregate worker for normal indexed projects; small bounded snapshots remain channel/file-artifact based.
   - The aggregate worker also produces an all-usages query artifact so oversized async usage/reference queries can be served by the usage query worker instead of building artifacts on the UI thread.
   - Remaining query work: migrate direct callers to async where they want large-project results instead of pending.

3. **Finish dirty/watch refresh migration**
   - Async file and directory dirty refreshes are targeted worker jobs now.
   - Watcher-triggered refreshes use those paths.
   - Single-watch native backends now skip recursive watch registration, but multiple-watch/scanning backends still have cooperative/UI-side recursive setup work.

4. **Open-document overlay extraction — mostly done**
   - Query paths no longer synchronously extract open-document overlays; they only remember open docs for dirty disk-entry suppression.
   - Parse-ready overlay refresh now sends a text snapshot to the worker-backed project-index path, adopts the resulting bounded file entry, and reports `overlay-indexing` while pending.
   - Remaining work is perf/stress validation and tuning caps for very large open documents.

5. **Stress/perf validation**
   - Large synthetic project.
   - Start indexing and drive cursor/filetree movement.
   - Confirm no large `run_threads_ms`, adoption, aggregate, or query spikes.
   - Validate cancellation/restart behavior under repeated dirty events.

## Risks and mitigations

### Risk: Lua channel payload copies are too expensive

Mitigation:

- keep chunk sizes small
- use compact records
- avoid sending file text
- add native result handles or file-backed artifacts if needed

### Risk: worker Lua states cannot safely load enough modules

Mitigation:

- keep worker handlers dependency-light
- pass plain serializable config
- avoid requiring UI modules in workers
- provide explicit worker-safe helper modules

### Risk: Tree-sitter native API is not safe across Lua worker states

Mitigation:

- isolate project indexing native helper from active document service
- compile queries per worker/job as needed
- protect global query/language data with mutexes if needed
- avoid sharing document-state objects across threads

### Risk: applying results still causes UI spikes

Mitigation:

- drain with strict budget
- adopt immutable final snapshots if possible
- use staged indexes: by_path first, aggregate later
- pre-sort in worker

### Risk: cancellation does not stop currently running native parse/query quickly

Mitigation:

- use Tree-sitter parse progress callbacks and query timeouts
- check cancellation between files
- accept best-effort cancellation for short bounded native calls

## Definition of done for this project

- Tree-sitter project indexing does not run heavy work in `core.add_thread` on the UI thread.
- Full scans, targeted file reindex, dirty-directory reindex, and watcher-triggered refreshes are all worker-backed or otherwise nonblocking.
- Project indexing does not route bulk work through the active-document Tree-sitter parse service.
- Dirty open-document overlay semantics are preserved, including stale disk-entry suppression.
- Starting indexing for a large project does not cause cursor/filetree input lag.
- Project symbol commands show indexing/loading/partial state as appropriate.
- Worker pool is reusable and covered by tests.
- Tree-sitter project indexer uses worker pool/native job handles and can be cancelled/restarted by symbol-index generation and project-paths generation.
- Symbol and usage readiness semantics match current behavior.
- Workspace symbol/reference query paths are bounded, cached, incremental, or worker-backed enough to avoid command latency on large indexes.
- Large result delivery has bounded memory behavior.
- Perf captures no longer show large `run_threads_ms` spikes from `symbol_index.lua` during indexing.

## Final intended architecture summary

Fred proves the shape:

```text
UI thread:
  submit job -> handle
  continue editing
  poll/drain result_if_complete under budget
  adopt only current symbol-index and project-paths generation

Worker pool:
  sleep on queue condition
  pop work under queue lock
  run heavy work without UI involvement
  mark result complete under result lock
  wake UI

Job:
  owns payload/result
  has cancel flag
  reports progress/final/error
```

Anvil should implement the same principles, adapted to Lua and the existing native code. The first application is Tree-sitter project indexing, but the real deliverable is a reusable async foundation for the editor.
