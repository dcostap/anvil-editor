# Anvil editor development notes

This repository is the source for the personal Anvil editor fork.

## Layout

- Source repo: `C:\Projects\c_projects\anvil-editor`
- Dev portable app: `C:\Projects\c_projects\anvil-portable`
- Build dir: `C:\Projects\c_projects\anvil-editor\build-windows-x86_64`
- Source built-in plugins: `data\plugins`
- Source core Lua: `data\core`

## Build outputs

Compiling produces binaries in:

- `build-windows-x86_64\src\anvil.exe`
- `build-windows-x86_64\src\anvil.com`

The Lua/data files are not embedded in the exe. A runnable portable app is produced by `meson install` into `C:\Projects\c_projects\anvil-portable`.

## Dev portable workflow

Use the BAT files in the repo root
- `setup-anvil-dev.bat`
  - first-time setup
  - builds the editor
  - installs a dev portable app to `C:\Projects\c_projects\anvil-portable`
  - creates Windows junctions so portable `data\plugins` and `data\colors` point back to this repo
  - launches the app

- `update-anvil-dev-build.bat`
  - default finalization step only when non-Lua files were edited
  - use after C/C++, build-system, asset, or other non-Lua source/default-data changes so the dev portable app is refreshed consistently
  - skip for Lua/plugin/color-only edits; those paths are junctioned into the portable app and can usually be reloaded in the running app
  - close Anvil first if binaries may be replaced
  - rebuilds and updates the dev portable app
  - restores the source-data junctions

Daily launcher target:

```text
C:\Projects\c_projects\anvil-portable\anvil.exe
```

## Renderer selection

The dev portable build defaults to the D3D11 command renderer on Windows. Do not use the old two-flag test setup (`ANVIL_D3D11` plus `ANVIL_D3D11_COMMANDS`) for normal launches.

Use one runtime switch only when needed:

```text
ANVIL_RENDERER=software
```

Unset `ANVIL_RENDERER`, or set it to `d3d11`, to use the default D3D11 path. D3D stats are still opt-in with `ANVIL_D3D11_STATS=1` and `ANVIL_D3D11_STATS_FILE=...`.

## Bundled Anvil defaults/plugins

The old personal `~\.config\anvil` workflow has been promoted into the fork:

- bundled plugins: `data\plugins`
- bundled default theme/style schema: `data\colors\default.lua`
- first-party startup defaults: `data\plugins\anvil_defaults.lua`

`anvil_defaults.lua` replaces the old user `init.lua` for the default Anvil experience. Keep personal machine-only state out of the repo, such as sessions, logs, caches, and fuzzy-search recent command history.

### First-party defaults policy

Bundled Anvil plugins are first-party code in this fork. Do not hardcode fallback defaults inside first-party plugin modules for config/style keys they use. Put first-party defaults in the defaults layer instead:

- style/color defaults belong in `data\colors\default.lua`; theme-specific overrides belong in other theme files under `data\colors`
- behavior/config defaults belong in `data\plugins\anvil_defaults.lua` or another explicit first-party defaults file if one is introduced

First-party plugin code may assume its required first-party config/style keys exist after the defaults layer has loaded. Third-party/user plugins may still define their own fallback defaults for keys they own, because those keys are outside the first-party schema.

When adding a new first-party style key, ensure the base style schema remains complete so switching themes does not leave missing keys. Themes should override keys, not be the only place where required first-party keys are defined.

## Logging / diagnostics

When adding new functionality, use `core.log_quiet(...)` liberally for diagnostics that could help debug future bugs or unexpected behavior. Prefer quiet logs for feature probes, optional integrations, state transitions, fallback decisions, and background task results. Quiet logs are useful in pasted logs without annoying the user. Use visible `core.log`, `core.warn`, or `core.error` only when the user should actively notice something.

## Refactoring / compatibility policy

This is a personal fork with first-party ownership of the whole codebase, including bundled Lua plugins and defaults. Prefer clean refactors over compatibility adapters: when renaming concepts, APIs, fields, commands, or behavior, update all in-repo callers/configs/plugins/tests instead of leaving deprecated aliases, dead code, or compatibility slop. Only keep backward compatibility when the user explicitly asks for it or there is a concrete external boundary that cannot be migrated in the same change.

## Lua/plugin development

Built-in plugins live in this repo under `data\plugins`.

The dev portable install uses junctions:

- `anvil-portable\data\plugins -> anvil-editor\data\plugins`
- `anvil-portable\data\colors  -> anvil-editor\data\colors`

So plugin/color edits are made directly in the repo and can usually be reloaded in the running app without reinstalling.

### Lua syntax validation

After editing Lua files, validate syntax without executing the files using the root checker:

```sh
luajit check-lua-syntax.lua data/plugins/example.lua
```

For several changed files, pass all of them as arguments:

```sh
luajit check-lua-syntax.lua data/plugins/autosave_fast.lua data/core/docview.lua
```

To check all bundled Lua files:

```sh
find data -name '*.lua' -print0 | xargs -0 luajit check-lua-syntax.lua
```

Use LuaJIT for this because Anvil runs LuaJIT in the normal dev build, so it is the closest parser/runtime match. On this repo, use the Meson-built LuaJIT executable directly instead of relying on a global `PATH` entry:

```sh
./build-windows-x86_64/subprojects/luajit/src/luajit.exe check-lua-syntax.lua data/plugins/example.lua
```

A normal Meson build generates this executable. The dev setup/update BAT files also run `scripts/ensure-luajit-cli.sh`, which builds that CLI and refreshes a stale LuaJIT subproject checkout if needed. If the repo-local executable is still missing and cannot be built, ask the user before installing anything globally. On this PC the expected install command is:

```powershell
winget install --id DEVCOM.LuaJIT -e
```

### Automated tests

Anvil has a first-party Lua runtime test framework in `data/core/test.lua`. Tests use `test.describe`, `test.it` / `test.test`, hooks, coroutine yields, and assertion helpers such as `test.equal`, `test.same`, and `test.ok`.

Never test exact keyboard shortcuts or keymap bindings. Shortcuts are user-configurable workflow choices and may change freely. Test commands and behavior instead, usually by invoking `command.perform(...)` or direct view/model methods.

#### What to test and what not to test

Prefer tests for stable user-facing behavior and bug-prone logic:

- command behavior
- input/event routing
- focus changes
- selection state
- layout rules with durable semantics
- parsing, matching, indexing, persistence, and edge cases

Avoid tests that only restate tweakable constants or personal visual preferences:

- exact pixel values for cosmetic spacing
- exact width/height breakpoints chosen by taste
- exact keyboard shortcuts
- theme colors
- default UI tuning values

If a visual/layout test is needed, test the durable behavior rather than a magic number. For example, test that a panel clamps to minimum padding when below its configured breakpoint, not that a hard-coded breakpoint is exactly `1200 * SCALE`.

A test should generally fail when there is a bug, not merely because a preference was intentionally retuned. Tests should encode intent, not duplicate implementation/configuration.

#### Bugfix regression tests

When adding a regression test for a bug, prefer proving the test fails before the fix and passes after the fix. If the fix is already applied, temporarily revert or disable only the implementation change and run the targeted test to confirm it goes red before committing. If red-first verification is impractical or too costly, mention that explicitly in the final summary.

Current first-party tests live in:

- `tests/lua/runtime` — Anvil-runtime Lua tests for non-visual APIs and behavior.
- `tests/lua/ui` — in-process UI tests for views, widgets, layout, focus routing, rendering helpers, and panel behavior.
- `tests/native` — native C/C++ tests wired into Meson, currently `anvil:fuzzy`.
- `tests/gui/smoke` — actual GUI smoke tests that launch the real app window.

Run tests through Meson by default. The full Meson test command now includes Anvil's native fuzzy test plus the Lua runtime and in-process UI suites:

```sh
meson test -C build-windows-x86_64 --print-errorlogs
```

Use the Anvil suite filter when you want to skip third-party subproject tests:

```sh
meson test -C build-windows-x86_64 --suite anvil --print-errorlogs
```

If `meson` is not on `PATH` in the agent/MSYS shell on this PC, call it explicitly and prefix MinGW's bin directory so Meson can find `ninja` for rebuilds:

```sh
PATH=/c/msys64/mingw64/bin:$PATH /c/msys64/mingw64/bin/meson.exe test -C build-windows-x86_64 --print-errorlogs
```

Individual Anvil Meson test targets:

```sh
meson test -C build-windows-x86_64 anvil:fuzzy
meson test -C build-windows-x86_64 anvil:lua-runtime
meson test -C build-windows-x86_64 anvil:lua-ui
```

The Lua Meson tests use `tests/run-lua-tests.sh`, which prepares an isolated `.run-meson-tests/<suite>` app/user/test tree, sets `SDL_VIDEO_DRIVER=dummy`, and runs `anvil test` internally. This avoids source-tree test pollution and means agents usually do not need to call `./scripts/run-local ... test ...` directly.

On Windows, Anvil Meson test targets use `anvil_test_env` with a sanitized `PATH` so Meson can print failure logs reliably even if the inherited user environment contains non-ASCII/hidden characters. Add future Anvil Meson tests to this environment unless they explicitly need something else.

To run a specific Lua file or subdirectory without registering another Meson target, pass the path through Meson's `--test-args` to the relevant Lua suite target:

```sh
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args tests/lua/runtime/tokenizer.lua
meson test -C build-windows-x86_64 anvil:lua-ui --test-args tests/lua/ui/markdownview.lua
```

Short paths under `tests/lua` are also accepted:

```sh
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/tokenizer.lua
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/markdownview.lua
```

Use `--no-rebuild` only when the build artifacts are known to be current.

#### Test layers

There is not a separate Lua framework for in-process UI tests: they are ordinary Lua runtime tests executed by Meson's `anvil:lua-ui` target through `anvil test`. The difference is the test style:

- **Headless/runtime tests** instantiate non-visual objects such as Documents, commands, fuzzy indexes, processes, threads, and pure helper modules, then assert their state.
- **In-process UI tests** instantiate or reuse Anvil UI objects such as Document Views, panels, prompt bars, widgets, tabs/nodes, fuzzy pickers, and settings views. They drive behavior by calling methods/event handlers programmatically, such as `core.on_event(...)`, `core.root_panel:on_mouse_pressed(...)`, `view:on_mouse_moved(...)`, `node:set_active_view(...)`, or widget `on_change(...)`, then assert Lua state/layout/focus directly. These are the preferred layer for TDD of editor UI behavior.
- **Actual GUI black-box tests** launch the real Windows GUI and send OS-level input or inspect screenshots/stats. Current examples are `tests/gui/smoke/d3d11-smoke-test.ps1` and `tools/anvil_*_perf_test.ps1`. Use these sparingly for renderer/window/input diagnostics, not as the main regression-test layer.

When adding or changing runtime/editor behavior, prefer adding or adjusting Lua tests in `tests/lua/runtime` or `tests/lua/ui` alongside the implementation. Use in-process UI tests for focus, layout, panel, widget, Document View, prompt bar, fuzzy picker, and command-routing behavior whenever possible.

## Finalizing changes / updating the dev portable app

When a change or feature is finished and non-Lua files were edited, run the relevant BAT file from the repo root so `C:\Projects\c_projects\anvil-portable` is updated. For non-Lua changes, usually run:

```text
.\update-anvil-dev-build.bat
```

From the agent/MSYS bash, use the `cmd.exe` double-slash form documented below.

C/C++ edits require rebuilding and restarting the app. Lua/plugin/color-only edits are junctioned into the portable app, so do not run the BAT just for those changes; validate Lua syntax and reload/restart Anvil as appropriate.

Close Anvil before running the BAT if binaries may be replaced, because the exe may be locked.

### Running BAT files from the agent/MSYS bash

The coding-agent shell runs under MSYS2/MinGW bash in this repo. If you need to invoke a Windows BAT file through `cmd.exe`, use double-slash CMD switches so MSYS does not path-convert `/c`, `/d`, or `/s`:

```sh
cmd.exe //d //s //c "call C:\Projects\c_projects\anvil-editor\update-anvil-dev-build.bat"
```

Do **not** use plain `cmd /c ...` or `cmd.exe /c ...` from this shell; it may only print the CMD banner/prompt and not run the command. The double-slash form was verified to build, install to `C:\Projects\c_projects\anvil-portable`, restore junctions, and restart Anvil.

## Vendored/Meson subprojects

SDL3 is brought in through Meson's wrap system, not as a top-level git submodule:

- wrap file: `subprojects/sdl3.wrap`
- local checkout/build input: `subprojects/sdl3`
- Anvil-owned wrap patches/files: `subprojects/packagefiles/sdl3*`

If changing SDL3 behavior for Anvil, do not rely only on committing inside the local `subprojects/sdl3` checkout. Fresh clones rebuild SDL3 from the wrap, so reproducible changes must be represented in the top-level repo, usually with a patch listed in `subprojects/sdl3.wrap` via `diff_files` or files under `subprojects/packagefiles/sdl3`.

Current Anvil SDL3 patch:

- `subprojects/packagefiles/sdl3-titlebar-mousemove-opt-in.patch`
- listed by `diff_files` in `subprojects/sdl3.wrap`
- makes SDL3's Win32 titlebar synthetic `WM_MOUSEMOVE` workaround opt-in with `ANVIL_SDL3_TITLEBAR_MOUSEMOVE_FIX=1`
- default keeps the workaround disabled because it causes a one-frame cursor blink on normal titlebar clicks

When updating SDL3 upstream, verify this patch still applies. If it fails, rebase/regenerate the patch against the new SDL3 revision and keep it tracked in the top-level Anvil repo.

## Why not Program Files for dev?

Do not use `C:\Program Files` for this dev install. It causes admin/write-permission issues and makes junction/rebuild workflows annoying. Use the writable dev portable folder instead.

A real installer for `C:\Program Files\Anvil` can be created later for deployment.

# Domain awareness

During codebase exploration, also look for existing documentation:

### File structure

Most repos have a single context: CONTEXT.md

## During the session

### Challenge against the glossary

When the user uses a term that conflicts with the existing language in `CONTEXT.md`, call it out immediately. "Your glossary defines 'cancellation' as X, but you seem to mean Y — which is it?"

### Sharpen fuzzy language

When the user uses vague or overloaded terms, propose a precise canonical term. "You're saying 'account' — do you mean the Customer or the User? Those are different things."

### Discuss concrete scenarios

When domain relationships are being discussed, stress-test them with specific scenarios. Invent scenarios that probe edge cases and force the user to be precise about the boundaries between concepts.

### Cross-reference with code

When the user states how something works, check whether the code agrees. If you find a contradiction, surface it: "Your code cancels entire Orders, but you just said partial cancellation is possible — which is right?"

### Update CONTEXT.md inline

When a term is resolved, update `CONTEXT.md` right there. Don't batch these up — capture them as they happen. Use the format in [CONTEXT-FORMAT.md](./CONTEXT-FORMAT.md).

Before renaming an existing glossary/context term, always ask the user for explicit confirmation. Do not rename established context language on your own, even if a new name seems clearer.

`CONTEXT.md` should be totally devoid of implementation details. Do not treat `CONTEXT.md` as a spec, a scratch pad, or a repository for implementation decisions. It is a glossary and nothing else.
