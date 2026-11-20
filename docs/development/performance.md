# Performance, C ports and diagnostics

## Speed work: measure first

Some ports are for speed. For these, do not port code because it looks slow. Measure it first.

1. Run the scenario that shows the problem with `--diagnose`. It writes a sampled profile and timers by phase. See [scenario runs](../../tools/SCENARIOS.md).
2. Find where the time goes in the attribution `details.csv` and profile stacks. Use `--heap` to measure retained Lua objects.
3. Ask if the work is necessary. Work that is not necessary is the largest win, in any language. Examples:
   - The Heading Outline ran the outline query on the whole note for each key. The worker's parse already had the headings.
   - Two callers joined the whole note into a Lua string for each edit, only to give it to C.
4. Port the work that is necessary.

These costs move to C first:

- Hot loops over plain data, such as rows, heights, or text positions.
- Work for each line or item of a document, where the count grows with the document.
- Large data that stays in memory, such as line layouts, token arrays, or document models.
  LuaJIT's GC has no generations. Each GC cycle marks all live Lua objects again, also data that does not change.
  Data in C memory adds no GC work.
- High GC or interpreter time in the profile for that code.

Code that runs in each frame, such as `update`, `draw`, and caret moves, must not make new tables, closures, or strings when old ones can be used again.

In the commit message of a speed port, give the measurement before and after the change.

## How to port

Port in small slices. Do not rewrite a module at once. For each slice:

1. For a speed port, measure the slice before the change.
2. Keep the old Lua path until the new path gives the same output. Compare both outputs on many real documents and edits. Use the repo's Markdown files and the scenario fixtures.
3. For a slice that changes what the editor draws or where, also compare pixels. Before the change, record golden images with the [render gate](../../tools/RENDER_PERF_GATE.md) (`--update-baseline --update-goldens`). After the change, the same scenes must match exactly. Add scenes when the existing ones do not show the changed line kinds.
4. Add tests that fail on the old code (red-green).
5. Run the full `lua-runtime` and `lua-ui` suites. Compare failures with a baseline; use a worktree only with user approval.
6. Run A/B scenarios against the baseline. Alternate the two versions, so machine load affects both. Give the numbers in the commit message.

## Known target: the document layout pipeline

Measured on the 19,185-line gallery note (`markdown-gallery-open`):

- Building Markdown render lines in Lua took 3.8 s. Cache lookups and fragment preparation took about 0.9 s more.
- The full row-height rebuild in Lua took 0.65 s. One rebuild took 465 ms in one frame.
- The C wrap call (`renderer.wrap_fragment_lines`) took 0.08 s.

The cost is Lua work for each line, spread over many functions. No single loop is hot. So port the pipeline in slices:

- C keeps the data for each line: style runs, wrap breaks, row heights, and line metrics. A worker thread can make them from the Buffer text and the tree-sitter parse.
- C also takes the presentation decisions: given the text, the parse tree, and the caret, which ranges to hide and which to style. Keep these decisions separate from wrapping and row heights, which depend on the renderer.
- Lua keeps widgets, clicks, and command wiring until they have clean seams. Lua reads results with a few calls for each frame.
- Before each slice, measure which line kinds cost the most, such as prose, headings, lists, tables, or code. Port the most costly kind first.

## Frame-time check

Run scenarios before and after each change to code that runs in each frame. This includes `update`, `draw`, scrolling, caret moves, the File Tree and the Fuzzy Searcher.

1. Before the change, run the smoke scenarios that use the changed code, for example `python tools/run_scenarios.py --scenario fuzzy-symbols-navigate-filetree-large --runs 1 --no-build`.
2. Run `--suite smoke` for changes to shared drawing code, such as `data/core/textview.lua`. The suite takes about 40 minutes.
3. After the change, run the same scenarios again.
4. In the commit message, give the p95 frame work, the maximum frame and the Lua heap size from both reports.

An explanation in a commit message does not approve a measured regression. If repeated measurements show worse performance, investigate it. Before committing, fix the regression or ask the user to accept the tradeoff.

Record any user-approved tradeoff in the commit message.

Many scenarios are over budget now. Without user approval, a change must not move them further over. See [scenario runs](../../tools/SCENARIOS.md) for the budgets.

Do not stop garbage collection to measure allocations. The removed allocation profiler exhausted system memory and crashed other programs. `--allocation` is disabled.

The shared Windows launcher limits each benchmark process tree to 4 GiB of committed memory. A `memory_limit` failure is not a passing measurement. Keep this protection in baseline worktrees too.

## Logging / diagnostics

Windows shell, Project, Sidebar and Machine server processes write memory samples in their native logs after five and 35 seconds. Then they check every 30 seconds, but write only after a 32 MiB change or a five-minute interval. `src/memory_stats.c` owns process totals, counters and the reporter thread.

Main Lua states sample after main-loop steps, outside LuaJIT traces, so FFI waits cannot bypass sampling. Worker states sample at safe waits; logs include sample age. No sample forces collection.

`system.memory_stats()` exposes all retained samples without writing a file. Logs show Lua totals, the main state and workers with at least 1 MiB. Tree-sitter allocator bytes, parser text snapshots, completed file records, completed Project index snapshots, CPU font glyph estimates, rendering surfaces and rendering buffers have separate counters.

Shared records count once. The D3D11 backend also counts owned texture payloads, including mip levels, under `Memory graphics`. Those bytes are not CPU commit or GPU residency.

These are partial measurements, not an exact account of process commit. Keep returned Tree-sitter range arrays on `anvil_ts_memory_free`, because its allocator tracks them. See [memory diagnostics](../../tools/MEMORY_DIAGNOSTICS.md) for omissions and investigation steps.

Run `anvil:memory-stats`, `anvil:surface-log` and `runtime/memory_stats.lua` after changes.

Terminal allocation counters cover Ghostty blocks, including alignment padding, client queues and retained replay/snapshot buffers. `terminal_native.memory_stats()` lists this Lua state's sessions, including prepared sessions without Views. Its weak registry retains no session.

`session:stats()` separates queue occupancy from capacity and reports the session's model allocations. Process-wide counters also include workers. Host processes and remote Machines are separate.

`core:record_memory_report` saves an on-demand report through a file worker. It takes memory samples before and after explicit full Lua collection, then walks the Lua owners. The census does not enter the collection comparison.

The `memory_report` control tool defaults to counters only; `collect: true` also collects and walks the calling state, which can pause the Project. Neither path collects worker states. Do not add native counters, graphics payload and Lua owner estimates together as process commit.

Run `anvil:terminal-replay`, `runtime/terminal_memory.lua`, `runtime/heap_census.lua`, `ui/memory_report.lua` and `ui/agent_control.lua` after changes.

Anvil writes persistent session logs to:

```text
..\anvil-portable\user\logs\anvil-*.log
```

Start with the newest logs when you investigate a crash or unexpected behavior. Then find the affected process and incident time. These logs are machine-local state and must stay outside the repo.

For Project failures, disconnects, startup failures, timeouts, or unexpected exits, read [native failure diagnostics](../../tools/NATIVE_DIAGNOSTICS.md) first. Match shell and Project or Sidebar records by process ID and connection ID. Read the first failure before cancellation and recovery records.

Include the rotated native log when needed. A broken pipe does not prove a crash; exit code zero does not prove an expected exit. Check save records separately before claiming that unsaved text survived.

Windows also writes native diagnostics before Lua starts. These logs are always on:

`USERDIR/logs/anvil-<date>-<time>-p<pid>-native.log`

Check the shell and hosted process logs for connection failures, rendering failures, and shell loss. The `D3D11 device:` line names the adapter. A frame that falls back to the software renderer logs `D3D11 frame failed: <reason>` once for each reason.

Each record includes local time, elapsed time, process ID, thread ID, and priority. Each process keeps two parts, with up to 10 MiB per part. The session log cleaner removes Lua, shutdown and native logs that are older than 7 days.

It keeps all logs to 100 MiB in total and removes the oldest logs above that limit. It does not limit the number of logs, because one launch writes logs for several processes. `ANVIL_SURFACE_LOG` selects an explicit shared file for probes.

It does not control normal logging.

Keyboard events include an always-on `Input trace:` diagnostic. See [keyboard input trace](../../tools/INPUT_TRACE.md) for stages and limits.

Accepted exits also write `anvil-<date>-<time>-p<pid>-shutdown.log` beside the matching session log. Use both files when you investigate a slow close. See [shutdown diagnostics](../../tools/SHUTDOWN_DIAGNOSTICS.md).

When adding new functionality, use `core.log_quiet(...)` liberally for diagnostics that could help debug future bugs or unexpected behavior. Prefer quiet logs for feature probes, optional integrations, state transitions, fallback decisions, and background task results. Quiet logs are useful in pasted logs without annoying the user.

Use visible `core.log`, `core.warn`, or `core.error` only when the user should actively notice something.
