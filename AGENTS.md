# Anvil development

Anvil is a personal editor fork. Prefer the smallest shared fix over new machinery or compatibility layers.

## Working rules

- Work in the main checkout unless the user requests a worktree.
- Leave other agents' changes alone. Stop if they change a file you need or block a build or test.
- Never stash or discard another agent's work. Suggest a worktree when work conflicts.
- Fix the shared behavior, not only the reported example. First identify the rule, entry points, and intentional differences.
- For cross-cutting changes, make a short coverage list. Check it before completion and report unsupported cases.
- Update all in-repo callers when changing an API. Keep compatibility only for an explicit request or an external boundary.
- Keep credentials, logs, caches, Workspaces, and other machine-local state out of Git.
- Commit each complete milestone after its checks. Commit only task files and report the commit hash.

`CONTEXT.md` is the glossary, not an implementation plan. Clarify conflicting terms before changing them. Ask before renaming an established term. Record agreed terms with [CONTEXT-FORMAT.md](CONTEXT-FORMAT.md).

## Repository and dev app

| Path | Purpose |
| --- | --- |
| `src/` | Native C logic; Lua bindings in `src/api/` |
| `data/core/` | Lua core |
| `data/plugins/` | First-party plugins |
| `data/colors/default.lua` | Base style schema |
| `data/plugins/anvil_defaults.lua` | Behavior defaults and mandatory plugins |
| `build-windows-x86_64/` | Dev build, including unstripped binaries in `src/` |
| `../anvil-portable/` | Dev app with a stripped executable and external runtime data |
| `../anvil-portable/user/` | `USERDIR`: local settings and state |

The dev app junctions `data/core`, `plugins`, `colors`, `widget`, and `treesitter` to this checkout. Edit the source, not the installed copy. Reload or restart after edits there; no install is needed.

Use `setup-anvil-dev.bat` for first setup. After native, build-system, or other installed runtime changes, run:

```sh
cmd.exe //d //s //c "call D:\Projects\c_projects\anvil-editor\update-anvil-dev-build.bat"
```

Use your checkout's path. Git Bash needs the double-slash CMD switches. Documentation-only changes need no app update.

The update builds first, saves Workspaces, detaches Terminals, then restarts through `scripts/start-dev-anvil.ps1`. Never replace that launcher with `Start-Process` or CMD `start`: their Windows job can kill the restarted app. Stop at an unsaved-file prompt; do not force-close or retry. Report build failures in unchanged code.

Use `launch-anvil-debug.bat` only for native debugging. Do not install the unstripped executable over the dev app. Keep dev data external; `build.bat` makes the separate standalone release at `dist/anvil.exe`.

In a requested worktree, build and test there. Update the dev app only from the main checkout after merging. Follow [worktree cleanup](docs/development/build-windows.md#worktree-cleanup), especially its dependency-link warning.

## Code rules

- Write new logic in C when it needs no Lua objects. Keep commands, configuration, plugins, and object wiring in Lua.
- Port existing Lua only at a clean boundary: plain data in, plain data out, with behavior tests. Do not expand a small task into a port.
- When a large change has that boundary, port the module. Otherwise, report it as a port candidate.
- Put C logic in modules without Lua headers. Use thin `src/api` bindings with the portable Lua C API, not FFI.
- Keep the PUC Lua build working. Test native edge cases: empty input, invalid UTF-8, and very long lines.
- Return results in batches. Avoid one C call per item and avoid allocations in per-frame code when objects can be reused.
- Put first-party config defaults in `anvil_defaults.lua` and styles in `data/colors/default.lua`, not module fallback values.
- Themes override the complete base schema. Do not make every constant a setting.
- Treat bundled plugins as first-party core unless there is a clear reason not to.
- Keep `anvil_defaults.lua` outside plugin disabling. It owns `core.first_party_core_plugins`, the mandatory plugin list.
- Use `core.log_quiet` for useful diagnostics. Use visible logs only when the user needs to act.

`core.add_thread` runs a coroutine on the UI thread, not an OS thread. Do not put blocking work there.

Use `core.worker_pool` for file reads, writes, stats, scans, and recurring process launches. Existing jobs include `file_info`, `file_read`, `storage_load`, `storage_save`, and `process_capture`. Lua handlers live in `data/core/workers`; native jobs use `src/worker_pool.c`. Send copied input, never live UI objects, and check revisions before applying results.

For streaming output, use `core.process_stream`. Cancel streams you stop reading. Git work uses `worker_pool.named("git")` through `plugins.git.backend.run_git`.

## Checks

Test behavior through commands, public models, Views, and event handlers. Do not assert private call counts, exact shortcuts, colors, or tuning constants. Use real editor objects; fake only external boundaries. Extend the nearest useful test instead of adding a speculative suite.

For bugs and new behavior, first run a targeted failing test. Apply the smallest fix, then rerun it. Report the failure and passing check. Explain any impractical red-first check. Removals and cosmetic tuning do not need regression tests.

Run focused files for small or medium changes. Use broader suites for large cross-cutting changes and the documented C-port checks. Keep known failures enabled; see [tests/README.md](tests/README.md#known-failures).

Validate changed Lua without executing it:

```sh
./build-windows-x86_64/subprojects/luajit/src/luajit.exe check-lua-syntax.lua data/plugins/example.lua
```

Pass all changed Lua files. If the CLI is missing, use `scripts/ensure-luajit-cli.sh`; ask before installing tools globally.

Run tests through Meson. Put the pinned Zig first: a test run can rebuild Ghostty, and another Zig fails that build.

```sh
export PATH="$(./scripts/ensure-zig.sh):/c/msys64/mingw64/bin:$PATH"
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/terminal.lua --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/storage.lua --print-errorlogs
```

Pass one file per `--test-args`; the runner reads only the first path. Use `--no-rebuild` only with current binaries. See [test execution](tests/README.md) and [test isolation](docs/development/testing.md) for runner controls and other checks.

Give each test a private folder under `USERDIR`. Remove it with `test.ok(test.remove_tree(path))`. Use generous deadlines for background work, ending the wait as soon as the condition holds.

Before changing per-frame code, measure the relevant scenarios. Repeat afterward and report p95 frame work, maximum frame, and Lua heap. Read [performance checks](docs/development/performance.md) for shared drawing, C ports, and regression rules. Do not accept a measured regression without user approval.

Never stop garbage collection to measure allocations or remove the benchmark's 4 GiB process-tree limit.

## Safe diagnostics and visual checks

Start with the newest logs in `../anvil-portable/user/logs/`. Read [native failure diagnostics](tools/NATIVE_DIAGNOSTICS.md) before investigating disconnects, timeouts, startup failures, or unexpected exits. A broken pipe is not proof of a crash. Verify saved data separately.

Read [the render gate](tools/RENDER_PERF_GATE.md) before checking pixels. Use its private desktop and isolated state. Do not capture, focus, move, close, or reuse the user's windows for verification. Do not use the dev portable app as a test process: its adjacent `user` folder overrides `ANVIL_USERDIR`.

## Task references

Read the relevant sections before changing a subsystem; do not load every reference for every task. Paths in code spans are repository-relative unless stated otherwise.

| Task | Reference |
| --- | --- |
| Builds, packaging, releases, updates, icons, dependency patches | [Windows builds](docs/development/build-windows.md) |
| Terminal startup, ConPTY, sharing, revival, Pi integration, agent control internals | [Terminal Sessions](docs/development/terminal.md) |
| Panes, Sidebar, Snooze, focus, launch, Window state, shell rendering | [Panes and Windows](docs/development/workspace.md) |
| Fuzzy Searcher, cross-Project search, autocomplete, covered Panes | [Search](docs/development/search.md) |
| Indentation, reload, storage, binary files, Markdown headings and images | [Text editing](docs/development/editing.md) |
| Scale, renderer, Tabs, popups, File Types, wallpapers | [UI and rendering](docs/development/ui.md) |
| Dialogs or `core.ui` controls | [Building Dialogs](docs/dialogs.md); use `core.ui`, not `data/widget` |
| Machine server, remote files, security, remote Terminals, Android | [Implementation and checks](docs/development/machines.md), [design](docs/machines.md) |
| Agent control tools, transport, discovery, security | [Agent control](docs/agent-control.md) |
| SQL Server | [SQL Server](docs/sql-server.md) |
| Language support or symbol selection | [Tree-sitter language maps](data/treesitter/languages/README.md) |
| Performance, C ports, memory and logging | [Performance and diagnostics](docs/development/performance.md) |

Keep grammar-specific work in its language folder. Review outline and usage queries; update the language review and focused tests. Do not add a query pattern for each nesting depth.

Consult the external Fred or IntelliJ source caches only when the user requests them. Their paths are in [Windows build notes](docs/development/build-windows.md#optional-reference-source-caches).

## Maintain these instructions

Keep this file for rules needed across tasks. Put feature contracts and focused test lists in the linked topic documents. Reuse existing documentation instead of copying it here. Document current behavior; put removed behavior and investigation history in commits. Do not hard-wrap Markdown prose.
