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

## Visible closure

The shell's native log records `Shell Window Close begin` and `Shell Window hidden after Close`.
The latter includes elapsed milliseconds from the shell's Close request to hiding the Window.
`Project exit accepted by shell` records each Project's time to exit intent.
`Anvil shell surface process exited` records its exit code and total time from the Project's Close request.

Exit intent follows required saves, Close choices, and worker shutdown. Lua and renderer cleanup follow it.
The shell hides a closing Window after every assigned Project reaches exit intent or finishes exiting.
It can ask the next Project's Close choices while an earlier Project finishes cleanup.
A cancelled Close keeps the Window visible. Earlier accepted Projects still finish closing.

Project unload selects another available Project, or clears the content area, when exit intent arrives.
The shell keeps the closing process and its Project identity until process exit.
Selecting that Project during cleanup does not start a replacement process.
Existing Close timeout warnings remain active during cleanup.

Compare the native log with each Project's shutdown log to separate visible closure from final cleanup.
The native elapsed time starts when the shell handles Close, not when Windows first receives the click.

## Connection loss during an update

The shell keeps watching a Project's process after its pipe fails.
Pipe cancellation does not stop process-exit monitoring. Runtime teardown stops that wait before joining the reader.
A Project that exits during a requested Close completes that Close, even without its final notification.
A live disconnected Project still gets the Wait or Force close choice.

Repeated update requests resume unfinished Window Close requests.
They keep the Window layout saved by the first request and do not force-close a process.
The native log records `Shell update: resume unfinished Window Close requests` for a retry.

Run the isolated `windows-close-update-disconnect` shell probe after changes.
It suspends an owned Project, starts an update, breaks its pipe, and retries the update.
It selects Wait, resumes the Project, and checks that all Projects and the shell exit.
