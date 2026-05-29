# Lua Scripts

This directory contains Lua scripts for running with Anvil.

Lua tests live under `tests/lua` and are wired into Meson. Run automated tests with:

```sh
meson test -C build-windows-x86_64 --print-errorlogs
```

Run only Anvil's own suite with:

```sh
meson test -C build-windows-x86_64 --suite anvil --print-errorlogs
```

Run only the Lua runtime or UI suite:

```sh
meson test -C build-windows-x86_64 anvil:lua-runtime
meson test -C build-windows-x86_64 anvil:lua-ui
```

Run a specific Lua file or directory by passing a path through `--test-args`:

```sh
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/tokenizer.lua
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/markdownview.lua
```

### Build

**pgo.lua** This script is used to generate profiler data, for more details
check the instructions included inside the file.

### Benchmarks

**benchmarks/tokenizer.lua** Benchmarks the Lua and native tokenizer paths for
an input file.

```sh
./scripts/run-local build-windows-x86_64 run scripts/lua/benchmarks/tokenizer.lua /path/to/file.ext
```
