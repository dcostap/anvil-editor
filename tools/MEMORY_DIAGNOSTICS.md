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

`basis=allocator_usable` measures live allocator block sizes. It excludes allocator metadata, free blocks retained by the allocator and reserved address space. Anvil uses the platform's allocation-size query and adds no header to each Tree-sitter block. Supported allocator-size platforms are Windows, Linux and macOS.

`basis=owned_estimate` measures owned data sizes or capacities. It excludes allocator overhead. Completed record counters omit temporary construction buffers and failed builds. A text buffer taken from a caller uses its text length, because that API has no capacity field. Fuzzy index strings use their stored lengths. Glyph sizes use the renderer's existing estimate.

These categories do not cover all native memory. Notable omissions include:

- Project index builders, query-result caches and other worker buffers.
- Grammar scanner allocations that bypass Tree-sitter's allocator.
- Terminal screens and history, pending image decodes, image decoder internals and display packets.
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

The existing `core:record_heap_census` command still supplies Lua owner estimates. It forces collections and walks the Lua object graph. Use it only when the Lua samples justify that cost.

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
```

The native checks exercise report suppression, concurrent parser allocations, shared snapshot lifetimes and actual log output. The Lua check covers canvas lifetimes, an idle worker's heap, and fresh main-state samples from a real Machine server. Use the `prompt-typeahead` scenario to check main-loop sampling cost. Use `renderer-primitives` with both renderers to check rendering resource changes.
