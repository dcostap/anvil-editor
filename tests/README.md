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

## Known failures

### Terminal input after a width change: PSReadLine 2.4.5

**Status: known external defect; accept this failure for now.** Keep the test enabled. Anvil has no workaround for this defect.

`ui/terminal_resize_prompt.lua` can fail its wider-resize case with `typed input left the prompt`. Input appears below the visible prompt. The narrow-then-wide case can still pass. The investigation reproduced the failure on 2026-10-31 with PSReadLine 2.4.5 and bundled ConPTY 1.25.2609.30003. Both PowerShell 5.1 and PowerShell 7 used that PSReadLine module and reproduced the failure.

PSReadLine skips resize checks for 50 ms after its last render. A resize and another key during that interval can leave its cached prompt coordinates unchanged. ConPTY accepts Anvil's correct cursor-position reply, but PSReadLine then sends absolute cursor moves to the old row. One capture corrected the cursor to row 14, then drew input at row 24.

The branch came from [PSReadLine PR #4448](https://github.com/PowerShell/PSReadLine/pull/4448). The [upstream source checked during the investigation](https://github.com/PowerShell/PSReadLine/blob/a2d143f78904/PSReadLine/Render.cs#L223-L250) still contains it. This PR introduced the optimization; it is not a fix for this failure.

#### Evidence

- A direct ConPTY probe reproduced the failure without Anvil code, Ghostty, or the test's background width-reporting thread.
- Two private PSReadLine copies ran in alternating order, without added waits. The stock copy failed 12 of 12 runs. A copy with only the resize-check time limit changed from 50 ms to zero passed all 12 runs. The separate queued-key rendering limit stayed unchanged.
- The unchanged Anvil test failed with the stock module and passed both cases with the diagnostic copy.
- The installed PSReadLine module stayed unchanged. The diagnostic copy was not installed or bundled.

#### Test policy

Do not skip this test, mark it as an expected failure, or add a fixed sleep to make it pass. Users can type during resize, so the test checks valid behavior. Do not delay Anvil input or change the installed PSReadLine module to hide the failure.

After a PSReadLine fix, rerun the unchanged test:

```sh
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/terminal_resize_prompt.lua --print-errorlogs
```

Match the test name and failure text before attributing a suite failure to this defect. Other Terminal failures still need investigation.
