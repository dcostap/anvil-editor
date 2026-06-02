# Tests

Automated and diagnostic tests for Anvil.

## Layout

- `lua/runtime/` — Anvil-runtime Lua tests for non-visual APIs and behavior.
- `lua/ui/` — in-process UI tests. These use the same Lua test framework, but instantiate UI objects and call event handlers/methods directly.
- `native/` — native C/C++ tests wired into Meson.
- `run-lua-tests.sh` — Meson helper that builds an isolated `.run-meson-tests/<suite>` app/user/test tree and invokes `anvil test` internally.

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
- `anvil:lua-runtime`
- `anvil:lua-ui`

## Individual Meson targets

```sh
meson test -C build-windows-x86_64 anvil:fuzzy
meson test -C build-windows-x86_64 anvil:lua-runtime
meson test -C build-windows-x86_64 anvil:lua-ui
```

The Lua targets run through Anvil, not plain LuaJIT, because they depend on Anvil globals and native modules. The helper sets `SDL_VIDEO_DRIVER=dummy` automatically.

## Specific Lua files or directories

Use Meson's `--test-args` to pass a specific Lua test path to the relevant Lua suite target. No per-file Meson registration is needed.

```sh
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args tests/lua/runtime/tokenizer.lua
meson test -C build-windows-x86_64 anvil:lua-ui --test-args tests/lua/ui/markdownview.lua
```

Short paths under `tests/lua` are also accepted:

```sh
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/tokenizer.lua
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/markdownview.lua
```
