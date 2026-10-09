# Phase 4 Sidebar follow-up

## Status

The user approved `81bccdaf` and requested these changes before Phase 5.
The Sidebar changes pass focused checks and are deployed.
The latency baseline investigation remains separate and blocking before Phase 5 milestone 2.
Hosted mode stays opt-in. Phase 5 implementation has not started.
Physical input, real IME, mixed DPI, allocator failure, and instrumented lifetime acceptance remain open.

## Changes

- Restore the automatic restart budget after a replacement stays Ready and connected for about 60 seconds.
- Keep the crash-loop limit and explicit recovery for hangs.
- Add a visible Sidebar Refresh action. It requests a new worker scan, even when registry notifications failed.
- Watch only `USERDIR/terminal-sessions`, without recursive notification delivery.
- Treat a dropped `SIDEBAR_CHANGED` Lua event as a request to query the model, not transport loss.

The health timer belongs to one connection generation. Failure, replacement, and shutdown cancel it.
An early timer event waits for the remaining interval before it restores the budget.
The query-needed flag uses the existing event poll. It adds no polling timer or queue.

## Red-green evidence

The Refresh action test failed before the change and passes afterward.
Logs: `phase4-followup-refresh-red` and `phase4-followup-refresh-green` in `build-windows-x86_64/meson-logs`.

`anvil:sidebar-watch` reproduced unwanted nested-record notifications before the narrow watch.
`anvil:sidebar-change-drop` reproduced transport loss after a dropped change event.
Both pass afterward. The change-drop test also checks that the query request is consumed once.
Logs: `phase4-followup-notification-watch-red` and `phase4-followup-notification-watch-green`.
Final native checks pass: change-drop, registry watch, hosted routing, and Sidebar page-drop.
Log: `phase4-followup-final-native`.

The owned `sidebar-recovery-reset` case exhausted automatic attempts, kept the replacement healthy, then ended it.
Before the fix, no replacement started: `A stable Sidebar did not restore its automatic recovery budget`.
Red artifact: `%TEMP%/anvil-surface-latency-m9o_fzn2`.
The first timer implementation still failed in `%TEMP%/anvil-surface-latency-_2uepk7y`.
The final D3D11 run passes in `%TEMP%/anvil-surface-latency-40ftt4g3`.
The final software run passes in `%TEMP%/anvil-surface-latency-och1cdfx`.
Its log records an early event at 59,999 ms, then a restored recovery budget.
This check uses the real interval. It does not replace time with a shortened test setting.
The existing crash-loop and idle registry cases also passed in `_2uepk7y`.

Lua syntax, Python compilation, the public incomplete-probe regression, and the diff check pass.

## Deployment

The user received a save-files warning before `update-anvil-dev-build.bat`.
The update completed and restored the source-data junctions.

SHA-256:

- Build: `9ce94e93844494de6bbabd50e0032479e8535e60cf21e4434760f86c9363eb41`.
- Portable: `b38b285dd4957b8d47316aed04bfea892ae20a05db27f8a85826a13de671b057`.

The portable matches an independently stripped build after PE timestamp and checksum normalization.
Fresh logs contain no warning, error, or failure entries at verification:

- `user/logs/anvil-20261009-151618-p2548.log`.
- `user/logs/startup/anvil-startup-20261009-151618-p2548-m633850.log`.

These paths are under `C:/Projects/c_projects/anvil-portable`.
