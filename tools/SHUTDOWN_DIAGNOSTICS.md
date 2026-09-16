# Shutdown diagnostics

Anvil creates a shutdown log when it accepts an exit or restart.
No environment switch is needed.

The dev portable app writes both logs under:

```text
C:\Projects\c_projects\anvil-portable\user\logs
```

Pair `anvil-<date>-<time>-p<pid>.log` with `anvil-<date>-<time>-p<pid>-shutdown.log`.
The session log records the shutdown log path.
Log retention removes both files together.

Reproduce the delay, then keep both logs from that Anvil Window.
Do not use a different window's newer log.

The shutdown log records elapsed milliseconds, native thread IDs, and shutdown phases.
Worker records include the job ID, job kind, current operation, operation duration, and file path.
The current operation can have started before shutdown.
File paths are limited to 1,023 bytes. Logs contain no file contents.

Look for a long phase or a `begin` record without its matching `end`.
Cancellation requests do not mean that a worker has stopped.
Native worker joins, result cleanup, Lua cleanup, and renderer cleanup have separate records.

Anvil writes each line directly, without a disk-sync wait.
The log stops at approximately 2 MiB and records that limit.
It stays open after the session log closes.
`SDL_AppQuit complete` marks the end of Anvil cleanup, before SDL's final platform cleanup.

These diagnostics do not change cancellation or shutdown waits.
