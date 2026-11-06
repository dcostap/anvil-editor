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

## Markdown syntax and presentation

The normal suites include source-range contracts, Anvil extension rules, edit/undo/redo checks, and 120 CommonMark reference examples.

Run the focused files:

```sh
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/markdown_syntax_contract.lua --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/markdown_commonmark.lua --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/markdown_inline_contract.lua --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/markdown_link_labels.lua --print-errorlogs
```

The complete standards audit also runs known differences. It currently reports 120 passes and 17 failures: two code-padding differences and 15 syntax defects. The failures include the trailing-space bold case. They remain failures, not replacement expectations.

```sh
meson test -C build-windows-x86_64 anvil:lua-ui --test-args tests/lua/markdown_spec --print-errorlogs
```

This audit is outside the default `runtime/` and `ui/` test folders. It checks 137 selected CommonMark 0.31.2 examples, not the complete specification. [Markdown fixtures](fixtures/markdown/README.md) describes the scope, source license, importer, and reviewed differences. Do not change an Anvil rule solely to make the standards audit pass.

## Edit history

Three files play random edits, then check that Undo restores earlier text and Redo restores later text:

- `runtime/buffer_edit_history.lua` applies batch edits, reloads and saved-state checkpoints to a Buffer. A second generator checks timed edit groups with the normal undo merge timeout.
- `ui/edit_history_commands.lua` runs editing commands, typing and paste in a Text View and Markdown Live Preview. It checks table source editing with 17 carets, table cells, lists, tasks, quotes, Selection Surrounding and the per-caret clipboard.
- `ui/edit_command_results.lua` also checks command results against independent string edits, not just recorded output. It covers typing, character deletion, plain paste and selected-text case changes. A second View keeps a reversed selection outside the edits, including Undo and Redo from either View. A separate check copies, cuts and pastes Unicode selections with up to 24 carets.

The result generator keeps edits away from the second View's selection boundaries. Boundary affinity and whole-Buffer case replacement need separate checks. Its text has no indentation or language syntax; the command-history generator covers those interactions.

A scenario is plain data: a start text and a list of steps. A step sets carets, then runs a command or types text. A step can also be an undo or a redo. A seed makes the same scenarios on each run. `tests/fixtures/edit_history.lua` holds the history model and the shrinker.

Steps can keep the previous selections, so one command's carets reach the next command. Generators use up to 24 carets or edits, Unicode, tabs and CRLF paste. Command tests reject logged errors and rejected transactions. They check final newlines and caret bounds after each step and each undo or redo. Shrinking keeps input carets at UTF-8 boundaries.

The runtime test checks saved history positions, including a new edit after Undo. Saved Buffers use history positions for dirty state, not byte equality. Restoring the same text with a separate edit can still leave a Buffer dirty.

A failure prints the seed and the smallest scenario that still fails. Copy that scenario into the file's `regressions` list, then fix the bug. These variables change a run:

- `ANVIL_EDIT_HISTORY_RUNS`: the number of seeds for each generator in the file. The defaults take a few seconds. Large Live Preview runs take longer because each edit waits for its Markdown parse.
- `ANVIL_EDIT_HISTORY_SEED`: the first seed.
- `ANVIL_EDIT_HISTORY_ALL=1`: report all failing seeds, not only the first.

```sh
ANVIL_EDIT_HISTORY_RUNS=5000 meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/edit_history_commands.lua --print-errorlogs
```

Meson prints only the last 100 lines of a failure. Read `build-windows-x86_64/meson-logs/testlog.txt` for a long report.

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
