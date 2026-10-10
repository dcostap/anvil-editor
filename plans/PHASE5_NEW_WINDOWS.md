# Phase 5 milestone 2a: New Window and hosted commands

## Scope and review boundary

The user approved milestone 1 (`6b1b8227`) and authorized milestone 2a.
This slice adds several native Windows, empty Windows, native actions, and hosted command routing.
The Sidebar stays in the first Window. Closing that Window ends only its disposable Sidebar frontend.
Other Windows keep their Projects and native controls. Shared Sidebar surfaces remain milestone 2b.
Hosted mode stays opt-in. Direct mode and non-Windows command behavior remain unchanged.
Stop after the milestone-2a commit for review. Do not start milestone 2b.

## Ownership and routing

The shell stores bounded Window records with stable, non-reused IDs. The bound is 64 records.
Native callbacks resolve their Window through the `AnvilShellWindow` HWND property.
SDL events resolve their native Window. Project events resolve their connection and assigned Window ID.
No request defaults to the first Window. Projects, identity jobs, and picker results use Window IDs.
The retry tag carries the original connection and Window ID. A static assertion requires 64-bit `uintptr_t`.

A message-only HWND receives shell service notifications. It is not an Anvil Window.
It owns identity, retirement, Sidebar scan, Sidebar recovery, and Sidebar health timers.
The Terminal registry watcher also targets this HWND. Sidebar presentation resolves the explicit Sidebar Window ID.
Window-owned startup timers check their Project's assigned Window before delivering a timeout.

Window Close changes a generation. Pending identity and picker results cannot survive Close followed by Cancel or Restart.
Identity workers use copied input. Removing a Window discards its later results.
Projects unload or retire before their Window record can be freed.
Retirement retains Projects until transport users, queued messages, and native callbacks release them.
Native SDL dialogs can read their parent on their own thread. Closing cancels their native UI.
The shell retains the hidden SDL Window until those callbacks finish. Other Windows keep working.
Process shutdown retains outstanding native callback storage until process exit rather than freeing its parent beneath it.
Destruction removes `AnvilShellWindow` and restores the original native procedure before destroying the SDL Window.
Instrumented lifetime acceptance remains open. These ownership rules are not an instrumented safety result.

## Commands and empty state

`core:new_anvil_window` and `core.open_new_window()` request an empty Window from the existing shell.
The shell draws `No Project selected` and native menu instructions. It starts no Project for that Window.
Every Title Bar system menu offers New Window and Open Project, including empty Windows.
The shell owns the native folder picker and parents it to the requesting Window.
Cancel preserves that Window. A removed or closing requester cannot receive a late selection.

Hosted `core.open_project_in_new_window()` sends the path and configured Window ID.
The shell resolves canonical identity off the UI thread before creating a Window.
A loaded Project selects and raises its owner, without another Window or runtime.
An unloaded or Dormant Project loads normally in a new Window.
An empty Window's native picker loads there instead. An occupied Window's picker uses the new-Window policy.
The existing Open Project command, system picker command, and IPC wrapper delegate to these shell rules.
The frontend does not reject its already loaded Project path in hosted mode.
Shell status reports request, identity, Window creation, and runtime allocation failures.
Failed Project startup keeps native actions and the existing explicit recovery path available.
The surface protocol changes from 11 to 12 and carries stable Window identity in configuration.

## Red-green evidence

All GUI checks use the existing private-desktop runner, isolated app data, namespaces, and owned process handles.
They do not operate the user's Windows or capture pixels.

Targeted reds:

- `anvil-surface-latency-dzqpve6o`: public New Window failed with `New Window did not belong to the existing shell`.
- `anvil-surface-latency-31f9nom3`: Open Project failed with `Open Project escaped the requesting shell`.
- The same artifact: native menu failed with `Title Bar menu has no New Window action`.
- `anvil-surface-latency-lzkhl9t0`: picker slice temporarily disabled; `shell-owned Project folder picker did not start`.

The disabled picker implementation was restored before green verification.
The first New Window green used a corrected path separator in its launch-count fixture.
The failed count in `anvil-surface-latency-4kkl2fqh` is a fixture failure, not a runtime red.
Corrected New Window green: `anvil-surface-latency-2_oivc69`.
Commands and menu green: `anvil-surface-latency-3d5vycsj`.

`anvil-surface-latency-equim89t` retained picker cancellation failures.
The runtime supplied zero as its dialog result identity. The result validator correctly rejected it.
The picker now supplies its requesting Window ID. Cancel and accepted load pass in `anvil-surface-latency-hl0a9rt4`.
The late-result check also passes there. It closes the requester, creates a replacement, and delivers the old result.

That artifact also retains two fixture errors: native dialog helpers entered Window counts; Close waited for shell exit.
The corrected checks count only native shell Windows and wait on the first Project's owned process handle.
Native picker parent/cancellation and independent Close pass in `anvil-surface-latency-wa9f93uc`.
These fixture corrections are not runtime red-green evidence.

`anvil-surface-latency-p_zw4yaw` retained the existing native-control regression:
`Failed Restart did not launch a replacement`.
The replacement inherited pending Window Close and immediately closed. Explicit Restart now cancels that Window's Close state.
The same control check passes in `anvil-surface-latency-tj1cwlys`.

The first artifact also retains `Manual Sidebar Restart retained its hung frontend`.
Its log records a replacement Sidebar, but the old process missed the fixture's exit deadline.
The unchanged Sidebar Restart check passes in `anvil-surface-latency-tj1cwlys`.
The [cause record](PHASE5_SIDEBAR_RESTART_CAUSE.md) later identified its cause. No timeout was widened and no failed evidence was removed.

The extended Open Project check also verifies wheel input in both Windows through native event routing.
Scrolling B changes B's Editor, not A's Editor. Scrolling A changes A's Editor.
It verifies canonical duplicate selection, owner restoration from Minimize, unchanged runtime counts, and the existing Open Project command.

## Final checks, latency, and deployment

All 17 focused hosted checks pass on each renderer, for 34 checks:
`windows-new`, `windows-open`, `windows-menu`, `windows-picker`, `windows-picker-command`,
`windows-picker-late`, `windows-picker-native`, `windows-owner-close`, `controls`, `routing`,
`dialogs`, `dialog-late`, `loaded-quit`, `dormant-last`, `sidebar-recovery`, `fault-busy`, and `fault-stale`.

- D3D11: `%TEMP%/anvil-surface-latency-lwvleoj4`.
- Software: `%TEMP%/anvil-surface-latency-o3qh9fw8`.
- Native `hosted-routing`, `sidebar-page-drop`, and `latency-watermark` pass.
- Native log: `build-windows-x86_64/meson-logs/phase5-2a-final-native.txt`.
- Direct command/API tests: `runtime/project_launch.lua` passes through Meson.
- Direct log: `build-windows-x86_64/meson-logs/phase5-2a-direct-launch.txt`.
- LuaJIT syntax, Python compilation, four public latency runner tests, and `git diff --check` pass.

### Matched latency

Evidence: `%TEMP%/anvil-phase5-2a-matched-kwlg817l/results.json` and its six linked public-run JSON files.
The reference is the retained milestone-1 executable from `anvil-surface-latency-dzqpve6o`.
Its SHA-256 is `065744ab6a1cf719809af83f57034d2b2629c8379fceb9fad7aaf91532abf6fb`.
The candidate SHA-256 is `eb35fe963b3bbbe6a79a967213ec308bb044c9ce0e47392978a57efae3e94a2f`.
Both executables use the same current source data. Neither executable is stripped for these checks.
Order is reference/candidate, candidate/reference, reference/candidate. Each matrix uses normal scheduling and five seconds of warmup.
No builds, correctness checks, or other measurements overlap these runs.

All six public commands and all 24 native cases exit 0. No case times out.
Every case requests, completes, and retains exactly 120 samples: 2,880 inputs total.
Every row has three runs and 360 inputs per executable.
All 48 boundary snapshots report session 1 unlocked with display power on.
No runs or samples are removed. The full per-run tails remain in their linked files.

Values are milliseconds. Baseline is `81bccdaf` from the accepted 2026-10-10 comparison.

| Row | Baseline p50 | Matched reference p50 | Candidate p50 | Matched difference | Candidate p90 | p99 | Maximum |
|---|---:|---:|---:|---:|---:|---:|---:|
| Direct D3D11 | 7.476 | 7.711 | 8.138 | +0.427 | 17.357 | 21.482 | 71.538 |
| Hosted D3D11 | 7.412 | 8.940 | 8.028 | -0.912 | 17.646 | 20.476 | 22.309 |
| Direct software | 15.350 | 18.614 | 19.379 | +0.765 | 29.652 | 35.558 | 74.814 |
| Hosted software | 11.596 | 13.329 | 14.986 | +1.657 | 25.943 | 59.019 | 88.824 |

Reference p90/p99/max are 17.017/20.902/65.864, 17.990/20.808/23.032,
26.931/32.673/39.432, and 22.845/28.334/29.162 ms in the same row order.

Direct rows serve as machine-noise controls, not acceptance targets.
The aggregate hosted-software shift exceeds its matched direct control by 0.892 ms, below the approximately 2 ms threshold.
It does not establish a hosted-software median regression beyond that control. No performance gain is claimed.

Per-pair software medians and differences remain important:

| Pair | Direct reference/candidate | Direct difference | Hosted reference/candidate | Hosted difference |
|---|---:|---:|---:|---:|
| 0 | 18.854 / 16.598 | -2.256 | 12.755 / 16.284 | +3.529 |
| 1 | 18.527 / 17.503 | -1.024 | 15.384 / 12.802 | -2.582 |
| 2 | 18.628 / 24.190 | +5.562 | 11.687 / 16.667 | +4.980 |

Pair 0 has a larger hosted shift; pair 1 reverses it. Pair 2 also has a larger direct shift.
Keep these differences and the candidate hosted-software maximum of 88.824 ms. Their causes remain unproved.
The comparison does not explain historical tails or change renderer defaults.

### Deployment

The save-files and process-stop warning preceded `update-anvil-dev-build.bat`. The updater exits 0.
It restores all source-data junctions and starts the normal direct-mode portable app.
The build hash stays unchanged through deployment.

SHA-256:

- Build: `eb35fe963b3bbbe6a79a967213ec308bb044c9ce0e47392978a57efae3e94a2f`.
- Portable: `03cd99af0f4119014084566d647170e63996e4598320d0c19f309663a4c6bd3c`.

An independently stripped build matches the portable executable after PE timestamp/checksum normalization.
Fresh session/startup logs contain no warning, error, or failure diagnostics at verification:

- `anvil-20261010-103439-p37768.log`.
- `startup/anvil-startup-20261010-103439-p37768-m084322.log`.

These logs stay under portable user data, outside the repository.
Updater output: `%TEMP%/pi-bash-bg-2c8974068c6dc0ff.log`.

Stop for review after this milestone's commit. Shared Sidebar surfaces remain unimplemented.
Physical input, real IME, mixed DPI, allocator failure, and instrumented lifetime acceptance remain open.
Generated input-to-Present measures neither physical input nor scanout.
Historical multi-second timing tails remain unexplained.

## Approved milestone-2a follow-up: maximized Window selection

The user approved `cebffbf1` with a required selection fix before milestone 2b.
`finish_resolutions()` now restores a Window only when `IsIconic()` reports Minimize.
Loaded Project selection preserves Maximize through both hosted Open Project and the native Sidebar model action.
The existing Minimize-restore check remains in the same fixture.

Red: `%TEMP%/anvil-surface-latency-2rhoom2s` reports hosted Open Project removing maximization.
The extended red in `anvil-surface-latency-bxvpk1b6` reports both paths:
`Maximized Window lost its state: hosted Open Project=false Sidebar selection=false`.
Both renderer greens include the same selection check and the hosted picker command:

- D3D11: `%TEMP%/anvil-surface-latency-x1nwghpm`.
- Software: `%TEMP%/anvil-surface-latency-ddfckcwi`.

Quiet native logs now report stale Window IDs on New Window, Open Project, and picker requests.
The hosted picker command reports a rejected request instead of silently ignoring `false`.
Deferred Window destruction still enumerates owned dialogs on each pass while a native picker remains pending.
This is known repeated work, not a new safety or performance claim.

The fix changes selection-time Window state, not frame compositing or input transport.
Milestone 2b will retain this fix in its matched latency candidate.
Manual and instrumented acceptance gates remain open.

The warned updater restored source-data junctions and restarted the direct-mode portable app.
Independent stripped/normalized PE comparison matches.
Build SHA-256: `3ee83aaf4ee02249417445b96ff65a33c20ceeaf788658045f6e306853d8d7eb`.
Portable SHA-256: `16bfc6bd15b3b79f7782b09f36dc16303877f7e25002f36227479068d75870c7`.
Fresh session and startup logs show no warning/error/failure diagnostics at verification:
`anvil-20261010-104549-p41852.log` and `startup/anvil-startup-20261010-104548-p41852-m996291.log`.

The user then approved milestone 2b. See [shared Sidebar surfaces](PHASE5_SHARED_SIDEBARS.md) for its separate verification record.
That milestone replaces the first-Window-only Sidebar lifetime described in this historical 2a record.
