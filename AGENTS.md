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
  - default finalization step for most completed changes/features
  - use after C/C++ changes, and also after Lua/plugin/default-data changes so the dev portable app is refreshed consistently
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
- bundled theme: `data\colors\onedark.lua`
- first-party startup defaults: `data\plugins\anvil_defaults.lua`

`anvil_defaults.lua` replaces the old user `init.lua` for the default Anvil experience. Keep personal machine-only state out of the repo, such as sessions, logs, caches, and fuzzy-search recent command history.

## Logging / diagnostics

When adding new functionality, use `core.log_quiet(...)` liberally for diagnostics that could help debug future bugs or unexpected behavior. Prefer quiet logs for feature probes, optional integrations, state transitions, fallback decisions, and background task results. Quiet logs are useful in pasted logs without annoying the user. Use visible `core.log`, `core.warn`, or `core.error` only when the user should actively notice something.

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

A normal Meson build generates this executable. If the repo-local executable is missing and cannot be built, ask the user before installing anything globally. On this PC the expected install command is:

```powershell
winget install --id DEVCOM.LuaJIT -e
```

## Finalizing changes / updating the dev portable app

When a change or feature is finished, run the relevant BAT file from the repo root so `C:\Projects\c_projects\anvil-portable` is updated. In most cases, run:

```text
.\update-anvil-dev-build.bat
```

From the agent/MSYS bash, use the `cmd.exe` double-slash form documented below.

C/C++ edits require rebuilding and restarting the app. Lua/plugin/color edits are junctioned into the portable app, but still run the BAT finalization step unless there is a clear reason not to, because it refreshes the portable install and restores the expected junctions.

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

`CONTEXT.md` should be totally devoid of implementation details. Do not treat `CONTEXT.md` as a spec, a scratch pad, or a repository for implementation decisions. It is a glossary and nothing else.
