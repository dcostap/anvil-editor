# Scripts

Scripts that configure and build Anvil.

- **build.sh**: Configure and build with Meson.
- **build-standalone-windows.sh**: Build and test the standalone `dist/anvil.exe`.
- **common.sh**: Functions that the other scripts share.
- **ensure-zig.sh**: Download the pinned Zig release when it is missing.
- **ensure-luajit-cli.sh**: Build the LuaJIT command-line tool for syntax checks.
- **generate-embedded-runtime.py**: Pack the runtime data into the standalone executable.
- **prepare-dev-update.ps1**: Save the running dev app before an update.
- **sync-git-subprojects.py**: Refresh cached Git dependencies before Meson opens them.
  A refresh occurs when a wrap, patch, or package file changes, also in incremental builds.
  Local dependency edits go to that dependency's Git stash. Ignored build caches stay.
- **fontello-config.json**: Input for the icon font generator.
- **lua/**: Profile-guided optimization and benchmark scripts for `run-local`.
- **run-local**: Run a build from the build directory.
