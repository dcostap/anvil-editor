# Scripts

Scripts that configure and build Anvil.

- **build.sh**: Configure and build with Meson.
- **compile.sh**: Compile with a job limit. Accepts Meson compile arguments.
- **build-standalone-windows.sh**: Build and test the standalone `dist/anvil.exe`.
- **common.sh**: Functions that the other scripts share.
- **ensure-zig.sh**: Download the pinned Zig release when it is missing.
- **ensure-luajit-cli.sh**: Build the LuaJIT command-line tool for syntax checks.
- **generate-embedded-runtime.py**: Pack the runtime data into the standalone executable.
- **prepare-dev-update.ps1**: Save the running dev app before an update.
- **start-dev-anvil.ps1**: Start the dev app through Windows Explorer, outside the caller's Terminal process group.
  The app uses the desktop environment, not the build shell's environment.
- **sync-git-subprojects.py**: Refresh cached Git dependencies before Meson opens them.
  A refresh occurs when a wrap, patch, or package file changes, also in incremental builds.
  Local dependency edits go to that dependency's Git stash. Ignored build caches stay.
- **fontello-config.json**: Input for the icon font generator.
- **lua/**: Profile-guided optimization and benchmark scripts for `run-local`.
- **run-local**: Run a build from the build directory.

## Build memory

Scripted builds use two parallel jobs instead of Ninja's CPU-based default.
Set `ANVIL_BUILD_JOBS` to a positive integer to change the limit.
In PowerShell, use `$env:ANVIL_BUILD_JOBS = '1'` before running a BAT file to reduce memory use further.
Dev installation skips rebuilding because the build step has already completed.
Direct Meson and Ninja commands do not use this limit. Pass `-j 2` to those commands.
