# Native failure diagnostics

Anvil writes native logs before Lua starts. No setting is needed.

The dev app writes them under `../anvil-portable/user/logs`:

- `anvil-<date>-<time>-p<pid>-native.log`: current native log.
- `anvil-<date>-<time>-p<pid>-native-part02.log`: previous part, if the log rotated.
- `anvil-<date>-<time>-p<pid>.log`: Lua session log.
- `anvil-<date>-<time>-p<pid>-shutdown.log`: accepted shutdown phases.

Keep the shell log and the affected Project or Sidebar log. The newest log alone can belong to another process.

Each native record has local time, process role, process ID, and thread ID. Default logs also include priority and process-relative elapsed time. Compare local times across processes, not their elapsed times.

`Native process` records the executable path, application version, protocol version, SDL version, and diagnostics compilation time. The compilation time identifies the diagnostics module, not a Git revision. An explicit `ANVIL_SURFACE_LOG` path keeps the shared format used by isolated probes.

## Find the first failure

1. Find `Shell connection failed` or `Anvil shell surface process exited` near the reported time.
2. Read earlier records for the same `connection` and `pid`.
3. Find the matching Project or Sidebar log by process ID.
4. Compare both sides before their cancellation and recovery records.
5. Check the Lua and shutdown logs for saves and cleanup.

The shell assigns a new connection ID on each start. `Shell Project start`, `Shell started Project`, and handshake records connect that ID to a process and pipe. Pipe handles are local to one process and can be reused. Use the connection records, not a handle alone.

`Shell failure context` records the state before recovery changes it. It includes process status, readiness, exit intent, pending Close, inbound and outbound queue sizes, rendering configuration, and transport thread completion.

`Shell transport failure` identifies allocation failure, event notification failure, invalid packets, and queue overflow. It records the stage and message size. `Shell outbound queue overflow` includes the queued size and limit.

## Read pipe failures

`IPC pipe failure` records:

- Read or write, header or payload, and the failed operation stage.
- Windows error and wait result.
- Bytes requested and completed before the failed operation.
- Cancellation state and timeout.
- Peer process IDs, when Windows can still supply them.
- Message type, size, protocol version, and payload limit when the header is known.

An operation that fails while partially pending can transfer more bytes than the last confirmed completion. The completed count does not claim those bytes.

`IPC invalid-header` distinguishes protocol and size rejection from pipe closure. `IPC outbound-size rejected` reports a local size error before any write.

A cancellation record can be a consequence, not the cause. Search earlier records before treating `ERROR_OPERATION_ABORTED` as the first failure. A broken pipe only proves connection loss. It does not prove that the peer crashed.

`Project shell loss cause` distinguishes packet validation, pipe read failure, pipe write failure, process exit, and local failures. A failed read has `message=0 bytes=0`; its low-level pipe record owns any partial header. It does not report the previous successful message as the failed message.

Windows errors come from the failed operation before logging or cleanup changes the thread's last error. Logic failures have no implied Windows error. `error=0` on those records does not mean success. `SDL_last_error` is supporting context, not a confirmed Windows failure.

Common Windows errors:

| Value | Meaning |
| --- | --- |
| 13 | Invalid data |
| 109 | Broken pipe |
| 233 | Pipe has no process |
| 995 | Operation aborted |
| 1460 | Timeout |
| 1816 | Not enough quota |

Message type numbers come from `src/surface_protocol.h`. No diagnostic added here includes message payloads, document text, terminal input, or environment values. Project and executable paths can appear. Keep logs private.

## Startup, exit, and recovery

Startup records distinguish process creation, pipe creation, connection wait, peer identity, handshake, event setup, and thread setup. Connection waits report timeout, cancellation, or process exit separately. A first-frame failure also records whether Lua runtime readiness arrived and rendering was enabled.

Process exit records include decimal and hexadecimal exit codes for both Projects and the Sidebar. They also record exit intent, pending Close, and replacement state. Code zero can still be unexpected when the shell did not request an exit. A hexadecimal exception code can identify a native crash, but does not supply its stack.

`Project exit notification requested` and `Project pipe write result` distinguish an attempted exit notification from a successful write. The latter does not prove that the shell handled it. `Project exit accepted by shell` confirms receipt.

Connection recovery records report discarded outbound bytes and the adoption decision. They distinguish a live shell, an ended shell, failed rendering, and a disposable Sidebar. Save completion, adoption expiry, and watchdog deadlines have separate records.

These logs do not guarantee recovery of unsaved file text. Check actual save records. See [shutdown diagnostics](SHUTDOWN_DIAGNOSTICS.md) for cleanup phases and pending Close recovery.

## Focused checks

Run the native logging and connection tests:

```sh
meson test -C build-windows-x86_64 anvil:surface-log anvil:ipc-pipe anvil:hosted-loss-invalid anvil:hosted-loss-disconnect anvil:hosted-routing --print-errorlogs
```

Use isolated shell probes for lifecycle checks:

```sh
python tools/run_surface_latency_probe.py --no-build --mode shell --project-case fault-write --project-case fault-malformed --project-case startup-reader --project-case sidebar-recovery --project-case windows-close-update-disconnect --project-case shell-loss --keep
```

Use `--no-build` only after compiling current sources. Inspect each case's `surface.log` in the printed work directory. The runner uses a private desktop and private user state. Remove its retained directory after inspection.
