# Frame timing capture

Start and stop the normal performance recording while the Editor has focus.
During recording, scroll and move the pointer over the Project Sidebar.
Record for 10–15 seconds. Then stop recording from the Editor.

The summary path is copied to the clipboard. The capture writes these adjacent files:

- `_frames.csv`: Lua frame costs, sleep costs, frame deadlines, and active View scroll positions.
- `_native.csv`: Editor input delivery, event polling, loop boundaries, sleep, and frame publication.
- `_shell.csv`: shell events, forwarded input, received frames, surface copying, composition, and presentation.
- `_sidebar.csv`: Sidebar input delivery, event polling, loop boundaries, waits, and frame publication.

The shell and Sidebar write their files asynchronously after stop. Their native logs report write failures.
A direct Window has no shell or Sidebar capture. The summary reports whether native capture started.

## Reading native rows

Each row has `time,thread,stage,id,a,b`. Time uses the performance counter in seconds.
On Windows, this clock is shared across processes and matches Lua `system.get_time()`.
Do not compare SDL event timestamps with this clock. Use event timestamps only to match input records.

| Stage | id | a | b |
|---|---|---|---|
| `shell-event` | SDL event timestamp | SDL event type | zero |
| `input-forward`, `sidebar-input-forward` | SDL event timestamp | SDL event type | Window id |
| `input-received` | SDL event timestamp | SDL event type | queued inbound bytes |
| `input-dispatch` | SDL event timestamp | SDL event type | Window id |
| `input-polled` | SDL event timestamp | SDL event type | remaining event count |
| `frame-publish` | frame generation | configuration | frame kind |
| `frame-received` | frame generation | Project id | zero |
| `sidebar-frame-received` | frame generation | Window id | one |
| `frame-load-begin`, `frame-load-end` | frame generation | Project id | Sidebar flag |
| `frame-load-deferred` | frame generation | Project id | surface busy flag |
| `compose-begin`, `present-begin` | Window id | zero | zero |
| `present-end` | Window id | HRESULT as unsigned integer | zero |
| `step-begin`, `step-end` | zero | queued events | immediate frame flag |
| `idle-begin`, `sleep-begin`, `wait-event-begin` | zero | requested microseconds | zero |
| `dropped` | lost records | zero | zero |

`idle-end`, `sleep-end`, and `wait-event-end` close their matching stages.
Sidebar `wait-event` arms SDL's wait; it does not block inside that stage.
`shell-step` and `sidebar-service` stages delimit work on the shell UI thread.
A composition can return before `Present`, for example when a Window cannot render.
Match stages by process and thread. Frame generations belong to individual surfaces.
Input motion can be combined before dispatch. Missing intermediate motion records do not prove lost input.

Compare successive `present-end` times to find display submission gaps.
Then inspect received frames, copying, input delivery, and loop work during each gap.
`Present` completion is not physical display scanout. These records cannot measure monitor response time.

A frame notice identifies a publication, not an immutable copy of its pixels.
The shared texture can contain a later frame when the shell copies it.
Do not report notice-to-presentation delay as exact visible latency.

SDL drains callback events before it polls Windows input again.
Inspect the interval from `shell-step-end` to the next `shell-step-begin`.
Several presentations in that interval can delay the next input poll.

Normal Project and Sidebar frame notices now copy surfaces without presenting them.
The shell presents pending Windows after event dispatch, inside `shell-step`.
Live resize and startup reveal retain their immediate presentation paths.

## Isolated input stress check

Run this check on the private desktop, with Windows unlocked and the display on:

```sh
python tools/run_surface_latency_probe.py --mode shell --renderer d3d11 \
  --sidebar-hover --samples 160 --runs 2 --keep
```

This workload types rapidly while the pointer alternates between a Sidebar row and empty space.
It sends owned native window messages, not input to the user's windows.
The shell converts each tagged typing message into SDL input events.
The timing includes the wait for Windows message processing and ends after presentation returns.
It does not measure hardware input delivery or physical display scanout.

The default typing check injects directly into SDL. It does not measure the Windows message wait.
The stress check must use the shell. Its saved results identify the input path.
Add `--diagnostics` to log native stages. Logging adds measurement cost; leave it off for timing comparisons.
Use `--reference-exe` and `--reference-data` to compare saved builds with the same runtime data.
Use `--no-build` only when the required build outputs are current.

## Overhead and limits

Native records use bounded memory: 262144 records per process, about 12 MiB.
Recording takes a short lock for each record. It formats and writes rows only after stop.
The final `dropped` row reports overflow. Start and stop also produce markers.
Each Lua CSV stream buffers up to 32 MiB. The summary reports discarded bytes.
The existing Lua instruction sampler and detailed probes still add overhead.
Normal session logging remains active. This capture does not disable it.

Native timing rows contain event types, identifiers, counts, and times, not text or key codes.
Other performance artifacts can contain file paths. Keep captures private.
