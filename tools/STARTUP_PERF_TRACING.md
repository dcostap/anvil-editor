# Anvil startup performance tracing

Anvil writes one detailed startup trace for each normal Lua startup. This
includes a new process, a new window, and a same-window project restart.

Trace files are stored in:

```text
%USERDIR%\logs\startup\anvil-startup-*.log
```

The trace starts in `core/start.lua`. It records runtime setup, core module
loads, app-state loading, project selection, window creation or restoration,
plugin discovery and loading, CLI parsing, deferred startup work, scheduler
threads, every Lua module require, first-frame events, first-frame update,
first-frame draw, and the first present.

Each line includes a sequence number, monotonic time, elapsed time, nesting
depth, event type, stage name, and detail text. Stage lines include their
status and duration. The trace flushes after every event, so failed startups
retain the work recorded before the failure.

A successful trace ends with `status=ready detail=first_present`. A failed
startup ends with `status=error`. A quit or restart before the first present
ends with `status=stopped`.

Set this variable to disable tracing:

```text
ANVIL_STARTUP_TRACE=0
```

Set it to `1` when tracing a Lua test. Test runs disable tracing by default.
Anvil keeps the 100 newest startup traces.

The trace begins after the native launcher enters Lua. Native work before
`core/start.lua` is outside this file. The normal session log still records
that startup trace path and other application diagnostics.
