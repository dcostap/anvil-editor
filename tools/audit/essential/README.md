# Essential implementation audit probes

These probes accompany [the audit report](../../../plans/ESSENTIAL_IMPLEMENTATION_AUDIT.md).
They describe baseline `9df5a67d` on Windows. They do not fix production code.

Run them through the isolated Meson Lua runner, not the daily portable application.
The runner gives each file a separate process and user folder.
The deletion probe creates a junction. Both its link and target stay inside that temporary user folder.

```sh
PATH=/c/msys64/mingw64/bin:$PATH PYTHONIOENCODING=utf-8 ANVIL_TEST_JOBS=1 \
  /c/msys64/mingw64/bin/meson.exe test -C build-windows-x86_64 \
  anvil:lua-runtime --print-errorlogs \
  --test-args "$(pwd -W)/tools/audit/essential"
```

Expected baseline: eight probes, with five failures that demonstrate defects.
Do not register this folder in the normal test suite.
When fixing a defect, move its focused regression case into the appropriate test suite.

| File | Evidence |
|---|---|
| `probes.lua` | Completed-job retention; recursive deletion crosses a directory junction. |
| `editor_probes.lua` | Failed Workspace save suppresses retry; bracket navigation enters a string; plain-Buffer edit timing. |
| `watch_probes.lua` | Unicode native-watch setup; missed changes in prefix-sharing sibling directories, with a positive control. |
| `filetree_probe.lua` | A source read error produces an empty copy that File Tree reports as successful. |

The worker probe inspects bookkeeping for diagnostics. It is not a proposed public-API regression test.
Memory and timing readings describe this run, not fixed performance contracts.
The I/O probes inject failures only at the filesystem boundary and restore the original function afterward.
