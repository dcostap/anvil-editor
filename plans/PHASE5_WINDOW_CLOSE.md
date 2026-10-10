# Phase 5 milestone 4: per-Window Close and local failure

## Status

The user authorized milestone 4 on 2026-10-11, with the process-exit priority fix as its first step.
Step 1 is implemented. Per-Window Close is not started. Hosted mode remains opt-in.
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
