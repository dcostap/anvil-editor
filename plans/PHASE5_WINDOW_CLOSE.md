# Phase 5 milestone 4: per-Window Close and local failure

## Status

The user authorized milestone 4 on 2026-10-11, with the process-exit priority fix as its first step.
Steps 1 and 2 are implemented. Commit this milestone and stop for review. Hosted mode remains opt-in.
Physical input, IME, mixed DPI, allocator failure, and instrumented lifetime acceptance remain open.

## Step 1: prompt process exit under CPU load

The [cause record](PHASE5_SIDEBAR_RESTART_CAUSE.md) found that D3D11 driver threads run at idle priority.
On a saturated CPU, they delay process exit until the Windows starvation boost, about 4 s or longer.

`src/process_exit.c` raises a process's below-normal threads to normal priority before it ends:

- `anvil_process_terminate` raises the target's threads, then terminates it. The shell uses it for
  manual Sidebar Restart, forced Project close, Sidebar shutdown at Quit, and latency-probe cleanup.
  The hosted shell-loss watchdog uses it on its own process.
- Every Anvil process registers `anvil_process_prepare_exit` with `atexit`.
  The shell's `_Exit` paths call it directly, because `_Exit` skips `atexit` hooks.

No timeout changed. A crash ends threads without Anvil code, so crash recovery still waits for Windows.
The fixture's own kills use `TerminateProcess` directly and stay slow under load. That is intentional;
they model crashes.

### Red-green

Native seam `anvil:process-exit` (`tests/native/process_exit_test.c`): a child with 12 idle-priority threads
ends while every logical processor runs normal-priority work. Both termination and normal exit must
finish within 2 s with exit code 7.

- Red, without the raise: termination took 5172 ms; normal exit took 4985 ms.
- Green: 93–140 ms in three runs of each.

### App evidence under induced load

The check was D3D11 `sidebar-recovery`, with one busy process per logical processor (`load.py 40`).
Runs interleaved the deployed reference (`--reference-exe`) and the candidate build.
Exit time is measured from the shell's Restart termination until the process object signals.

| Run | Reference manual Restart exit | Candidate manual Restart exit |
| --- | --- | --- |
| 1 | 7218 ms (`tfljowb1`) | 1009 ms (`iht2hxvh`) |
| 2 | 7163 ms (`g6_ygrvd`) | 977 ms (`5ivpm4dr`) |
| 3 | 4549 ms (`z1qihb6o`) | 407 ms (`qt1qw79k`) |

All six runs passed. The reference's slow exits show every remaining thread `Ready` at priority 1/1.
Fixture crash-loop kills stayed at 2.4–12.2 s in both builds, as expected.

Without induced load, these shell cases pass on D3D11 and software with the candidate:
`sidebar-recovery`, `force-close`, `stalled-loss`, `shell-loss`, `restart`, `quit`, `close`,
`windows-sidebars-recovery`, and `controls`.
Native targets `process-exit`, `hosted-routing`, `sidebar-watch`, `project-sidebar`, and `sidebar-scan` pass.

The full `--suite anvil` run at 100% CPU from the user's workloads passed 24 of 28 targets.
`process-exit` passed. The others do not involve this change's exit path:

- `markdown_parser` fails a Tree-sitter scanner check (`markdown_parser_test.c:197`); it does not link this code.
- `terminal-native-perf` fails its throughput benchmark under load.
- `lua-runtime` and `lua-ui` were still passing tests when their 240 s and 360 s limits expired.
  Two `fuzzy_searcher_symbols.lua` drawing tests report `no target window found` under the dummy video driver.

Raw data: `%TEMP%/anvil-m4-priority/` (`load-compare.txt`, `summary.txt`, `suite.txt`).
Artifact names omit the `anvil-surface-latency-` prefix.

### Step 1 deployment

`420882b2` is deployed with `update-anvil-dev-build.bat`, which ended all Anvil processes as the user permitted.

- Build `build-windows-x86_64/src/anvil.exe`: `205646cc72f12c2f2bed0898eeb7a4cc772b3a2f18fd2edc1d0b692c34df680d`
- Portable `anvil-portable/anvil.exe` (stripped): `48c54ba55ee0ab04ab94c03dcffea6c40a4da835962ea91e7860a668d66cde00`

## Step 2: per-Window Close and local failure

Most Close behavior already existed from milestones 2a and 3.
Window Close marks only its own Window as closing and asks its assigned Projects one at a time,
starting with the selected Project. Each Project uses its normal Close policy.
Cancel clears that Window's closing state, so its remaining Projects are not asked.
The shell exits only after it removes its last Window.

This step adds checks for the behaviors the plan lists and fixes one defect that they found.

### Defect: Open in New Window dropped a pending selection

A New Window request raised the requesting Window's selection revision.
The Window's earlier pending selection then looked stale, and the shell discarded it without a message.
Only a later selection should replace a pending selection. Unload and New Window requests do not check
the revision, so they no longer raise it (`queue_resolution`).

- Red: `windows-close-dirty`, run `nstjgmat`. Project selected Other, then opened Replacement in a new Window.
  Other never started; the driver timed out waiting for it.
- Green: the same case passes after the fix (`h15245zb`, then the final runs below).

### Checks

The new fixture `tests/fixtures/windows_close_probe.lua` runs on isolated owned Windows.
Window A holds Project and Other, with Other selected. Window B holds Replacement.
Every case ends by checking Window B's Project, shell, and native controls,
then closing Window B. That last Close must end the shell with exit code 0.

- `windows-close-dirty`: all three Projects have unsaved Buffers. Window A Close asks Other first.
  Discard ends Other. Cancel on Project keeps its Buffer and Window A, and no later request follows.
  Window B's Project is never asked. A second Close of Window A closes Project and removes the Window.
  The last Window Close asks Replacement before the shell exits.
- `windows-close-launch`: the shell's probe pauses Other's launch worker for 7 s.
  Window A's native controls respond. Close then waits for the launch and ends both Projects.
- `windows-close-hang`: Other is suspended. Both Windows' native controls and New Window still work.
  Window A Close shows the Wait or Force close warning, parented to Window A. Window B stays usable
  while it is shown. Force close ends Other, and Close continues with Project.
- `windows-close-crash`: Other is killed. The shell marks it Failed. Both Windows stay usable.
  Window A Close unloads the failed Project and closes Project.
- `windows-close-gpu`: an injected present failure in Window A fails only A's selected Project.
  That Project detaches through its shell-loss path. Project, Replacement, and Window B continue.
  Window A's native controls work and its Close completes.
- `windows-close-quit`: Quit inside Other closes Window A, including Project. Window B continues.

Existing checks cover the rest of the plan:

- `windows-owner-close`: Quit inside a Project closes its own Window only.
- `windows-new`, `windows-menu`: empty Window Close.
- `windows-move-close`, `windows-move-target-close`, `windows-move-dialog`: Move is rejected during a
  Close choice or native dialog and does not run after it ends.

Final results, all PASS (`%TEMP%/anvil-m4-close/runs.txt`):

| Case | D3D11 | Software |
| --- | --- | --- |
| `windows-close-dirty` | `ywp2acq3` | `hzepog1m` |
| `windows-close-launch` | `wbu03gzp` | `jzdn5uiz` |
| `windows-close-hang` | `fap9eobt` | `x9hgiqnn` |
| `windows-close-crash` | `q3muxvc_` | `13ub7847` |
| `windows-close-gpu` | `bzq4kzo3`, `btp0fdip` | `s5b1eeft`, `i58xnbuw` |
| `windows-close-quit` | `0na1ia4x` | `ed2dkh6a` |

Because selection and New Window requests changed, these existing cases were rerun and pass on both
renderers: `windows-owner-close`, `windows-open`, `windows-new`, `windows-picker`, `windows-picker-late`,
`windows-move`, `windows-move-close`, `windows-move-target-close`, `windows-move-dialog`,
`loaded-resolve`, and `loaded-launch`.
Native targets `process-exit`, `hosted-routing`, `hosted-dialogs`, `hosted-motion-stall`,
`project-sidebar`, and `sidebar-watch` pass.

Fixture corrections during the work, retained:

- `21hj9yss`, `nm89kvpb`: the crash case waited for a log line from the process-exit path.
  A crash is first seen as a broken pipe, so the case now waits for the Failed state.
- `udl2bv3k` (software): the GPU case required Other's process to keep running.
  A failed connection makes the Project detach and exit through shell-loss handling, as intended.
  The D3D11 run had checked before that exit. The case now checks only the Projects outside the failed connection.
- `j82_z6ji` passed `windows-close-launch` before the selection fix, but its paused launch was Replacement's,
  not Other's. That run does not count. After the fix, the paused launch is Other's (`cmthdky2`).

### Compositor failure boundary

Each Window creates its own D3D11 device and swap chain. Each Project process creates its own device.
A failure in one Window's compositor releases only that Window's resources.
It fails only that Window's selected Project connection. Explicit Restart recovers it.

A real device removal, such as a driver reset or TDR, affects every device on the adapter.
Every Window and every Project process then sees its own failure. Each recovers through its own
explicit Restart. The shell does not share one device across Windows, so no Window can make a
healthy device fail. The injected fault cannot reproduce adapter-wide removal; that remains manual.

### Matched latency

Evidence: `%TEMP%/anvil-phase5-m4-matched-hfnxjp8r/results.json`. Runner: `%TEMP%/anvil-phase5-m4-matched-latency.py`.
Reference: the stripped milestone 3 portable executable, `102ffe492d1d4890f5a8d120c13141c65cd8a35a7f14b9524b815b303654a76c`,
saved in `anvil-surface-latency-tfljowb1/app/bin`. `48b33622` and `a4a2eb08` did not change it.
The Lua runtime is unchanged in this milestone, so both executables use the current runtime.
Candidate: `7fb065d5d688f0e862457f5ceecd1ccfb8bb58a7e0d3589119e339be22f57ef0` (unstripped build).

Order: reference/candidate, candidate/reference, reference/candidate, with a five-second warmup.
All six public runs exit 0 with 120/120 matched inputs per case and every case baseline-eligible.
No other test ran during the measurement. The user's workloads held the CPU near 100%.

| Row | Reference p50 | M4 p50 | Difference | M4 p90 | M4 p99 | M4 max | Reference max |
|---|---:|---:|---:|---:|---:|---:|---:|
| Direct D3D11 | 8.728 | 8.716 | -0.012 | 18.438 | 43.338 | 54.372 | 102.397 |
| Hosted D3D11 | 8.582 | 10.332 | +1.750 | 21.331 | 41.114 | 83.054 | 29.669 |
| Direct software | 15.500 | 16.534 | +1.034 | 26.076 | 33.085 | 43.400 | 69.309 |
| Hosted software | 14.008 | 13.643 | -0.365 | 24.506 | 39.949 | 43.280 | 161.754 |

All values are milliseconds of generated input-to-Present, not physical input or scanout.
The hosted-D3D11 shift minus its matched direct shift is +1.762 ms; for software it is -1.399 ms.
Both are below the approximate 2 ms noise threshold. No gain or stable regression is established.

Per-pair candidate-minus-reference medians (direct D3D11 / hosted D3D11 / direct software / hosted software):

- Pair 0: +1.761 / -0.088 / +0.502 / -2.803
- Pair 1: -1.369 / +0.838 / -0.497 / -0.749
- Pair 2: -0.543 / +4.811 / +1.617 / +3.272

Pair 2's hosted shifts are unexplained and retained. The other pairs disagree in sign.
Neither code change runs on the input-to-Present path: the priority raise runs only at process exit,
and the revision change runs only when a selection request is queued.

### Step 2 deployment

`bb393d87` is deployed with `update-anvil-dev-build.bat`. It exited 0 and restored all five source-data junctions.
The build hash equals the measured latency candidate.

- Build `build-windows-x86_64/src/anvil.exe`: `7fb065d5d688f0e862457f5ceecd1ccfb8bb58a7e0d3589119e339be22f57ef0`
- Portable `anvil-portable/anvil.exe` (stripped): `c9508d0b85b2f45c76194a7c2a1860b28588fce8baf277b021af2a2a3d6a2304`
