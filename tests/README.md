# Tests

Automated and diagnostic tests for Anvil.

## Layout

- `lua/runtime/` — Anvil-runtime Lua tests for non-visual APIs and behavior.
- `lua/ui/` — in-process UI tests. These use the same Lua test framework, but instantiate UI objects and call event handlers/methods directly.
- `native/` — native C/C++ tests wired into Meson.
- `tools/` — programmatic harness tests, including hidden-desktop watchdog and
  process-tree integration coverage on Windows.
- `run-lua-tests.sh` — Meson helper that builds an isolated app/user/test tree in `%TEMP%/anvil-lua-tests/<suite>.XXXXXX` for each run, runs each test file in its own `anvil test` process, and deletes the tree afterwards. Set `ANVIL_TEST_KEEP_RUN=1` to keep it, `ANVIL_TEST_JOBS` to set how many files run at once (default 4), and `ANVIL_TEST_FILE_TIMEOUT` to change the per-file limit (default 300 seconds).

## Main test command

Run automated tests through Meson:

```sh
meson test -C build-windows-x86_64 --print-errorlogs
```

If Meson is not on `PATH` in the MSYS shell on this PC, call it explicitly and prefix MinGW's bin directory so Meson can find `ninja` for rebuilds:

```sh
PATH=/c/msys64/mingw64/bin:$PATH /c/msys64/mingw64/bin/meson.exe test -C build-windows-x86_64 --print-errorlogs
```

To run only Anvil's own tests and skip third-party subproject tests:

```sh
meson test -C build-windows-x86_64 --suite anvil --print-errorlogs
```

Anvil's Meson suite contains:

- `anvil:fuzzy`
- `anvil:render-perf-harness`
- `anvil:idle-perf-harness`
- `anvil:lua-runtime`
- `anvil:lua-ui`

## Individual Meson targets

```sh
meson test -C build-windows-x86_64 anvil:fuzzy
meson test -C build-windows-x86_64 anvil:render-perf-harness
meson test -C build-windows-x86_64 anvil:lua-runtime
meson test -C build-windows-x86_64 anvil:lua-ui
```

The Lua targets run through Anvil, not plain LuaJIT, because they depend on Anvil globals and native modules. The helper sets `SDL_VIDEO_DRIVER=dummy` automatically.

## Specific Lua files or directories

Use Meson's `--test-args` to pass a specific Lua test path to the relevant Lua suite target. No per-file Meson registration is needed.

```sh
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args tests/lua/runtime/tokenizer.lua
meson test -C build-windows-x86_64 anvil:lua-ui --test-args tests/lua/ui/markdown_live_editor.lua
```

Short paths under `tests/lua` are also accepted:

```sh
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/tokenizer.lua
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/markdown_live_editor.lua
```
