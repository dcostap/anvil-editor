# Test isolation and tools

Use [tests/README.md](../../tests/README.md) for Meson commands, suite layout, runner variables, and known failures. Use [AGENTS.md](../../AGENTS.md#checks) for test scope and regression rules.

## Runtime and UI tests

`data/core/test.lua` supplies `test.describe`, `test.it`, hooks, coroutine waits, and assertions. UI tests use the same framework. They run through `anvil test`, not plain LuaJIT.

The Meson runner creates an isolated app, user folder, and test tree in `%TEMP%/anvil-lua-tests/<suite>.XXXXXX`. It sets `SDL_VIDEO_DRIVER=dummy`. Each test file runs in its own process with its own user folder.

Four files run at once by default.

| Variable | Purpose |
| --- | --- |
| `ANVIL_TEST_JOBS` | Number of concurrent files |
| `ANVIL_TEST_FILE_TIMEOUT` | Per-file timeout, default 300 seconds |
| `ANVIL_TEST_KEEP_RUN=1` | Keep the isolated tree for inspection |
| `ANVIL_TEST_RUNS_ROOT` | Choose another parent folder |

The runner deletes its tree after completion and removes run folders older than 12 hours. Concurrent suite runs have separate folders.

Give process and worker waits generous deadlines. Return as soon as the expected condition holds. Clean temporary folders with `test.remove_tree`, which retries transient file locks.

On Windows, set `PYTHONIOENCODING=utf-8` with Meson's `--verbose`. Otherwise non-ASCII test names can break log output. New Anvil Meson targets use `anvil_test_env` for its sanitized `PATH`, unless they need another environment.

The built LuaJIT CLI checks syntax without running a file. `scripts/ensure-luajit-cli.sh` builds it and refreshes a stale LuaJIT checkout. To check all bundled Lua:

```sh
find data -name '*.lua' -print0 | xargs -0 ./build-windows-x86_64/subprojects/luajit/src/luajit.exe check-lua-syntax.lua
```

## Choose the test layer

- Use runtime tests for parsers, indexes, processes, storage, and other non-visual APIs.
- Use in-process UI tests for commands, focus, input routing, selection, layout, and View behavior.
- Use the [render gate](../../tools/RENDER_PERF_GATE.md) for pixels and renderer diagnostics.
- Use [scenarios](../../tools/SCENARIOS.md) for frame time and editor workflows. Shared scenes live in `tests/scenes`.
- Use native window probes only when the behavior requires Windows integration.

The render gate uses a private desktop and internal actions. It captures the rendering surface, not the user's screen. Add a scene there instead of making another capture system.

Until a suitable scene exists, use in-process UI tests.

Do not use `CopyFromScreen`, `PrintWindow`, or ad hoc desktop captures. Do not test against live user settings, credentials, file associations, or paired devices.

## README screenshots

Run `python tools/showcase/run_showcase.py --no-build` with current binaries. It makes `docs/screenshots/workspace.png` and `themes.png` on a private desktop.

The showcase needs Pi on `PATH`. It uses fake Projects from `tools/showcase/projects` and scenarios from `tools/showcase/agents.json`. Pi uses a private agent folder and a scripted model server; it makes no real model calls.

`tools/showcase/pi/showcase.cjs` supplies status times with OSC 7501 `since`. Shell command times are real.
