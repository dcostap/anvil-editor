# Phase 5: Sidebar Restart deadline failure cause

This record satisfies the milestone-4 entry gate in [the Phase 5 plan](PHASE5_SEVERAL_WINDOWS.md).
No shell or Sidebar timeout changed. No retained failure artifact was removed.

## Retained failures

- `anvil-surface-latency-p_zw4yaw` (2a, 10:17): `Manual Sidebar Restart retained its hung frontend`.
- `anvil-surface-latency-78ao9u5m` (2b, 18:09): `Sidebar stopped before its restart limit`.
- `anvil-surface-latency-h1fnf5co` (2b, 18:12): hung frontend survived the Restart deadline.
- `anvil-surface-latency-dvd39mol` (`f565e01c` reference, 18:12): same hung-frontend failure.

All four used D3D11. In each, the shell behaved correctly:

- Manual Restart terminated the old process and connected a replacement within about 90 ms.
- In `78ao9u5m`, the shell saw the first killed Sidebar's pipe end 4.3 s after the kill.
  It never saw the second one end before the fixture's 6 s deadline.
  The shell intentionally restarts only after the old process exits.

The failing quantity was the time Windows needed to finish terminating a killed Sidebar process.
The fixture asserted that time against shell deadlines.

## Cause

A D3D11 Sidebar process contains NVIDIA user-mode driver threads (`nvwgf2umx.dll`) at idle thread priority.
A live-process sample found 161 such threads at base priority 1 across one run's Sidebar processes, all starting in that module.
Anvil, SDL, and the test runner do not set idle priority. The runner only raises its own launch thread.

Process termination must schedule every thread once.
On a saturated CPU, Ready idle-priority threads starve until the Windows balance-set manager boosts them after about 4 s.
Thread snapshots of slow exits show all 12 remaining threads `Ready` (state 1) at priority `1/1`.
Windows already reports the termination code (125 for shell Restart, 107 for fixture kills).
The exits cluster at 4.7–5.2 s, matching the starvation boost. Some reach 7–10 s.

The software renderer creates no D3D11 device. Its Sidebars have no idle-priority driver threads.
In an interleaved batch, every D3D11 run from the third onward failed, with 2–10 s exits.
All ten software runs passed, with exits below 1.6 s.

The load came from the user's workloads: WSL (`vmmemwsl` about 93% CPU), Python training and multiprocessing jobs,
and Defender, with a run queue of about 21 threads on 16 logical processors.
At 18:04:12 Windows also reported low virtual memory and extended the page file.
These workloads were not stopped.

Raw data: `%TEMP%/anvil-restart-investigation/` (`run-*.txt`, `b2/`, `b3/`, `green/summary.txt`, `threads.txt`, `idle_threads.txt`).

## Fixture corrections

These deadlines measured Windows termination instead of shell behavior.
Their values are unchanged; each now starts where the shell can act.

- Manual Restart: within the same 3 s, the hung frontend must report the shell's termination code, 125.
  Windows sets that code when termination starts.
- Crash loop, budget reset, and the several-Window recovery check: after each kill, wait for the process to exit,
  bounded by 30 s, the shell's own exit wait (`SHELL_CONNECT_TIMEOUT_MS`).
  The existing 6 s, 15 s, and 10 s restart deadlines start at that exit.
- Project A's 30 s and 120 s waits for the driver now bound each driver step instead of the whole sequence.
  The driver reports progress after each killed Sidebar exits.
- Diagnostics: the Sidebar fixture records each terminated Sidebar's exit time.
  For an exit pending after 1 s, it records the exit code and each thread's state, wait reason, and priority.

Red: before the correction, the unchanged check failed at the manual-Restart exit whenever the exit exceeded 3 s.
Six consecutive D3D11 runs failed this way, with 4.7–9.4 s exits, and the shell's termination code was already set.
The first corrected run, `anvil-surface-latency-xuyf1689`, passed both corrected checks with 3.6–7.3 s exits.
It then failed Project A's 30 s whole-sequence wait, which led to the per-step bound.
Green: `anvil-surface-latency-9_ea_1fl` passes with exits of 4521, 7397, 2318, 9558, and 2588 ms.
`anvil-surface-latency-ept3dwbi` passes with exits of 4472, 4887, 4775, 7497, and 4895 ms.

Related checks pass after the correction:

- `windows-sidebars-recovery`: D3D11 `85ntwx4y`, software `q_df6ld6`
- `sidebar-recovery-reset`: D3D11 `twhishyp`
- `sidebar-recovery`: software `lbrhjwp0`
- `sidebar-process`: D3D11 `y7saqvcg`; `sidebar-log`: D3D11 `x2w0v5z8`; `sidebar-idle`: software `8xa8761j`

Artifact names omit the `anvil-surface-latency-` prefix. LuaJIT syntax checks pass for both fixtures.
Only test fixtures and plans changed. No build or deployment is needed.

## Product impact and open risk

On a saturated CPU, a killed or restarted D3D11 Sidebar can remain in the process list for several seconds.
Automatic Sidebar recovery waits for that exit, so it can arrive seconds later. Manual Restart does not wait.
Hosted Project processes also use D3D11 and contain the same driver threads.
Project exit checks elsewhere, such as Restart refusing while the previous Project has not exited, can be delayed the same way.
Other fixture deadlines that include Project termination (3–10 s in `hosted_project_probe.lua`) can fail under the same load.
They have not failed in retained evidence and are unchanged.

Milestone 4 step 1 raises the dying process's idle-priority threads before Anvil ends it.
See [its record](PHASE5_WINDOW_CLOSE.md). Crashes and the fixture's own kills are not covered.
