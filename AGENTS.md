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

- `build-windows-x86_64\src\pragtical.exe`
- `build-windows-x86_64\src\pragtical.com`

The Lua/data files are not embedded in the exe. A runnable portable app is produced by `meson install` into `C:\Projects\c_projects\anvil-portable`.

## Dev portable workflow

Use the BAT files in the repo root:

- `setup-anvil-dev.bat`
  - first-time setup
  - builds the editor
  - installs a dev portable app to `C:\Projects\c_projects\anvil-portable`
  - creates Windows junctions so portable `data\plugins` and `data\colors` point back to this repo
  - launches the app

- `update-anvil-dev-build.bat`
  - use after C/C++ changes
  - close Anvil first
  - rebuilds and updates the dev portable app
  - restores the source-data junctions

Daily launcher target:

```text
C:\Projects\c_projects\anvil-portable\pragtical.exe
```

## Bundled Anvil defaults/plugins

The old personal `~\.config\pragtical` workflow has been promoted into the fork:

- bundled plugins: `data\plugins`
- bundled theme: `data\colors\onedark.lua`
- first-party startup defaults: `data\plugins\anvil_defaults.lua`

`anvil_defaults.lua` replaces the old user `init.lua` for the default Anvil experience. Keep personal machine-only state out of the repo, such as sessions, logs, caches, and fuzzy-search recent command history.

## Lua/plugin development

Built-in plugins live in this repo under `data\plugins`.

The dev portable install uses junctions:

- `anvil-portable\data\plugins -> anvil-editor\data\plugins`
- `anvil-portable\data\colors  -> anvil-editor\data\colors`

So plugin/color edits are made directly in the repo and can usually be reloaded in the running app without reinstalling.

## C/C++ development

C/C++ edits require rebuilding and restarting the app.

Run:

```text
update-anvil-dev-build.bat
```

Close Anvil before running it, because the exe may be locked.

## Why not Program Files for dev?

Do not use `C:\Program Files` for this dev install. It causes admin/write-permission issues and makes junction/rebuild workflows annoying. Use the writable dev portable folder instead.

A real installer for `C:\Program Files\Anvil` can be created later for deployment.
