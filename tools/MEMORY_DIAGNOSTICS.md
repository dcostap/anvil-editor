# Memory diagnostics

Windows shell, Project, Sidebar and Machine server processes record memory samples in their native logs. No setting or heap scan is needed. Startup reports arrive after about five and 35 seconds. The reporter checks counters every 30 seconds. It writes another report when private commit or a category's current or peak size changes by at least 32 MiB. It compares with the last written report, so small changes accumulate. Otherwise, it writes a report every five minutes, including while the Window is idle.

The dev app writes `../anvil-portable/user/logs/anvil-<date>-<time>-p<pid>-native.log`. Keep its `-native-part02.log` too, when present. Native logs rotate after 10 MiB and keep two parts per process. The shared cleaner targets 100 MiB and seven days, but cannot remove protected open logs. Thus, 100 MiB is not a hard limit for all running processes. The reporter runs on a separate thread. It does not force garbage collection, read Lua objects from another thread, or inspect document text.

An existing process needs a restart to load these counters. A dev update restarts the shell and Projects, but keeps existing Terminal hosts. Terminal hosts use a separate log and do not have this reporter. Shells, Pi, language servers and other child programs are also outside these process totals.

## Find a process

1. Find the incident time in the native logs.
2. Use the shell's Project start records to match a Project path with its PID.
3. Find `Memory process:`, `Memory native:`, `Memory graphics:` and `Memory Lua:` in that PID's log.
4. Compare samples from the same process before, during and after the work.

For example, from the repo root:

```sh
rg 'Memory (process|native|graphics|Lua)' ../anvil-portable/user/logs/*-native*.log
```

The log prefix supplies local time, PID and process role. Each memory sample has a sequence number. The sequence belongs to one process, not the whole app. Samples from different processes are not simultaneous. Use `Native process` to check the executable version and build information. See [native diagnostics](NATIVE_DIAGNOSTICS.md) for process identity and rotated logs.

## Process totals

`Memory process` uses bytes, not KB or MB. Divide by 1,048,576 for MiB.

| Field | Meaning |
| --- | --- |
| `private_commit_bytes` | Private committed memory, including pages that are not resident in RAM. |
| `working_set_bytes` | All resident pages, including shared pages. |
| `private_working_set_bytes` | Private resident pages, as in Task Manager's usual Memory column. |
| `available` | Whether Windows supplied this sample. Zero means unavailable, not an empty process. |

Do not add working sets across processes as a measure of unique physical RAM. Shared pages can appear in several processes. Private commit is not GPU memory and is not the amount currently in RAM.

## Native categories

Each `Memory native` row has current `bytes`, lifetime `peak_bytes`, and current `objects`. Peak bytes do not reset when objects close. Categories that have never held memory have no log row. These are process-wide counters, including worker allocations. Concurrent allocation can change a counter between fields or rows.

Do not add category peaks. They can occur at different times.

| Category | Coverage | Objects |
| --- | --- | --- |
| `treesitter` | Allocations through Tree-sitter's allocator: parser buffers, syntax trees, queries, cursors and returned range arrays. | Live allocator blocks. |
| `ts_text_snapshots` | Owned parser input text, line arrays and snapshot structures. | Text snapshots, counted once across references. |
| `ts_file_records` | Completed native symbol and usage records, including their text and array capacities. | File results, counted once when builders and snapshots share them. |
| `ts_index_snapshots` | Completed Project index snapshots: lookup arrays, record references, fingerprints and symbol fuzzy indexes. Shared file records stay in `ts_file_records`. | Project index snapshots. |
| `font_glyphs` | The renderer's CPU glyph atlas, surface and metric size estimate. | Fonts with a non-empty glyph cache. |
| `render_surfaces` | CPU pixel storage owned by canvases and window surfaces, including row padding. Images and wallpapers count after a canvas takes them. | Owned surfaces. |
| `render_buffers` | Renderer command buffer capacities, Draw Captures, CPU quad arrays and texture upload scratch buffers. | Owned buffers. |
| `terminal_model` | Ghostty screens, history, parser storage, images, render state, encoders, formatters and snapshot decoders through Anvil's Terminal allocator. Alignment padding counts. | Live allocator blocks. |
| `terminal_queues` | Allocated client read and write queue capacities, including prepared sessions. | Allocated queues. |
| `terminal_snapshots` | Client replay buffer capacity and retained snapshot text scratch capacity. | Allocated buffers. |

`basis=allocator_usable` measures live allocator block sizes. It excludes allocator metadata, free blocks retained by the allocator and reserved address space. Anvil uses the platform's allocation-size query and adds no header to each Tree-sitter block. Supported allocator-size platforms are Windows, Linux and macOS.

`basis=owned_estimate` measures owned data sizes or capacities. It excludes allocator overhead. Completed record counters omit temporary construction buffers and failed builds. A text buffer taken from a caller uses its text length, because that API has no capacity field. Fuzzy index strings use their stored lengths. Glyph sizes use the renderer's existing estimate.

`basis=owned_capacity` measures the exact capacities requested for the tracked buffers. Queue occupancy does not change allocated capacity. It excludes Windows heap overhead and retained free pages.

The Terminal allocator keeps its original allocation pointer before each aligned span. `_msize` supplies the whole block's usable size, including alignment padding. A logical shrink retains that allocation and its count until a remap or free. Failed allocations change no counter. This shim needs no allocation stack or heap scan.

These categories do not cover all native memory. Notable omissions include:

- Project index builders, query-result caches and other worker buffers.
- Grammar scanner allocations that bypass Tree-sitter's allocator.
- Terminal transport jobs, search buffers, pending image decodes, temporary SDL image storage and display packets.
- Graphics-driver allocations and FreeType or HarfBuzz internals.
- Other indexes, mapped files, thread stacks and allocator retention.

Do not call the difference between process commit and these counters a leak. Do not subtract GPU estimates from CPU process totals. The report deliberately gives no exact "unaccounted bytes" field.

## Graphics resources

`Memory graphics` reports `d3d11_textures` with `basis=texture_payload`. This counts logical pixel bytes for textures that the Project or Sidebar D3D11 backend creates. It includes image mip levels, glyph textures, hosted render targets, shared output textures, upload textures and temporary capture textures. A release removes the backend's ownership from the counter, including failed setup and device recovery paths.

This is not GPU residency or CPU commit. A driver can pad, copy or retain resources after Anvil releases them. Shared textures can remain alive in the shell. Swapchain buffers, shell compositor textures, D3D buffers and driver storage are not counted. Do not add this category to the native CPU categories or subtract it from process commit.

## Lua samples

`Memory Lua` identifies each state by a process-local ID and thread name. `main` is the application's Lua state. Worker states have their thread names. The ID changes when a state closes and another starts.

`bytes` comes from Lua's heap counter without collection. It can include garbage that the collector has not reclaimed. It excludes native payloads behind userdata and allocator retention.

Only the state's owner samples its heap. The main state samples after startup and after main-loop steps, at most once every five seconds. This includes the Sidebar and Machine server, whose LuaJIT FFI waits bypass Lua API bindings. Sampling runs outside LuaJIT traces. Lua API sleep and event waits also sample before a long or unbounded wait. A worker samples before a channel wait and when its function returns. `age_ms` tells how old that observation is. A long calculation or blocked call can leave an old sample. It is not a current reading of that state.

`Memory Lua states` gives the number of retained samples, their total bytes, their maximum age, and the number omitted above the bounded registry limit. Detailed log rows show the main state and workers with at least 1 MiB. The total includes smaller workers. The API returns all retained states. A closed state removes its sample. Small temporary Lua states outside the application's normal state creation paths are not registered.

`system.memory_stats()` returns the same process totals and categories, plus the calling state's current `lua_bytes` and the registered state samples. It forces no collection and writes no file. Process fields are absent where the OS query is unavailable. Native category counters remain available outside Windows; automatic native logging is Windows-only.

## On-demand capture

Run **Record Memory Report** (`core:record_memory_report`) for a collection comparison and Lua owner census. It can pause the Project. It takes two full collections on the calling Lua state, then walks that state's object graph. Worker states keep running and are not collected. The report takes its second memory sample before the graph walk allocates its own tables.

The command writes a timestamped text file in the temp folder through the file worker. It copies the path after the write succeeds. It changes no focus and closes no referenced Terminal. Collection can close an unreachable native session through its normal finalizer. The report names the process ID and UTC sample times. Keep reports private: owner names can contain file paths and application keys.

Agents can use `memory_report` with an optional `project`. The default reads counters and session rows without forcing collection or writing a file. Set `collect: true` only for an explicit collection comparison and owner census. The reply includes `pid`, `collected` and the text `report`. Cross-Project routing uses the same discovery rules as other agent tools.

`core.memory_report.capture(collect)` returns the structured capture. `memory_before` and `memory_after_collection` contain process, native, graphics, Lua and Terminal samples. The latter is absent without collection. A collected capture also has `collection_ms` and the census fields. `core.memory_report.format` returns the text report. `core:record_heap_census` saves only the Lua owner table.

`terminal_native.memory_stats()` lists the calling Lua state's native sessions without keeping them alive. It includes prepared and remote sessions, also without Views. Closed sessions do not appear. `session:stats()` exposes the same fields for one session, including a closed one:

- `memory_id` identifies this native session object for its lifetime, including before a host assigns `session_id`.
- `model_bytes`, `model_peak_bytes` and `model_objects` measure that session's Ghostty allocations.
- `read_queue_capacity` and `write_queue_capacity` report allocated capacities. An unattached remote session has no queues.
- `read_queue_bytes` and `write_queue_bytes` report current occupancy under the queue locks. Existing high-water fields remain cumulative.
- `replay_capacity` and `snapshot_text_capacity` report the retained buffer capacities.
- `state`, `prepared`, `remote` and the host and session IDs identify the owner.

Process-wide Terminal categories also cover native workers. Per-session rows are a breakdown, not additional allocations. Host processes and remote Machines have separate memory. A session close releases its model and queues; allocator pages can remain committed after those live counts reach zero.

Census sizes are estimates from reachability, not allocation stacks or exact retained sizes. Shared objects count once by the first shortest path. Userdata and prototype payload sizes are omitted. Lua heap counters include their Lua-managed storage, so the census estimate need not equal the heap total.

Before/after changes include report overhead and concurrent background work. They measure a net change, not a guaranteed amount that future collection will recover. To measure a release, compare captures before and after the same controlled close or cache release. Use native allocation tracing in an isolated reproduction when counters cannot identify an owner. This report does not provide native allocation stacks, allocator free-page ownership or driver backing sizes.

## Investigate growth

1. Record the Project, operation, file sizes and incident time.
2. Compare private commit with the named native categories and fresh Lua samples.
3. Repeat the same operation, then close its files or unload its Project.
4. Check which current counters return and which keep growing.
5. Use peak counters to find temporary demand between periodic samples.

For example, growing `ts_file_records` points toward retained symbol or usage data, not necessarily syntax trees. Stable Tree-sitter counters with growing commit do not support blaming those tracked allocations. They also do not clear the omitted caches or allocator retention.

Persistent growth after repeated identical work needs investigation. A single large sample does not establish a leak or justify the allocation. If named counters do not explain the growth, use VMMap or allocation tracing in an isolated reproduction.

## Checks

```sh
meson test -C build-windows-x86_64 anvil:memory-stats anvil:surface-log anvil:treesitter anvil:markdown_parser --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/memory_stats.lua --print-errorlogs
meson test -C build-windows-x86_64 anvil:terminal-replay --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/terminal_memory.lua --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/heap_census.lua --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/memory_report.lua --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/agent_control.lua --print-errorlogs
```

The native checks exercise report suppression, concurrent parser allocations, shared snapshot lifetimes and actual log output. The Lua check covers canvas lifetimes, an idle worker's heap, and fresh main-state samples from a real Machine server. Use the `prompt-typeahead` scenario to check main-loop sampling cost. Use `renderer-primitives` with both renderers to check rendering resource changes.

Terminal checks cover allocation alignment, failed growth, logical shrink, snapshot decoding and release. The Lua checks cover local, prepared and unattached remote sessions, closed sessions and collection without diagnostic retention. Use `terminal-autoscroll-history` to check Terminal accounting cost. Automatic logging reads only the aggregate counters; it never runs the census or lists session objects.
