# Phase 5 milestone 5: external launch and duplicate selection

## Status

The user authorized milestone 5 on 2026-10-11. It is implemented and deployed. Stop for review.
Hosted mode remains opt-in. Direct-mode single-instance IPC is unchanged.
The user approved milestone 5. Matched latency against milestone 4 found no regression; see below.
Physical input, IME, mixed DPI, allocator failure, and instrumented lifetime acceptance remain open.
An interactive foreground check also remains open. The private desktop has no foreground Window to grant from.

## Behavior

`anvil --shell` first looks for the running shell for the same executable, user directory, and Windows session.

- The key hashes the executable path and the canonical user directory. The user directory follows the
  `data/core/start.lua` rule. Each user directory has its own shell.
- The first launcher holds a named mutex and becomes the shell. When a shell ends or crashes, a later
  launch takes ownership. Shell records do not outlive the shell process.
- A later launcher forwards its absolute path arguments and working directory over a named pipe, then exits with code 0.
  It does not create a Window or a Project runtime.
- When a shell does not answer, the launcher retries within a 15 s budget, then exits with code 1. It never starts
  a second shell for the same key.

The running shell handles a request like a Project selection:

- Identity resolution runs on its own worker thread. Project startup uses the existing launch worker thread.
- A loaded Project is selected in its owning Window. The shell restores and raises that Window.
- Any other Project opens in a new Window of the running shell.
- A request waits while the first Project's identity is unresolved, so concurrent launches cannot duplicate it.
- The shell answers Busy while the Project's Window is closing or the shell is ending. The launcher retries.

### Request authentication and bounds

The request carries one launch. It is not a general remote call.

- The pipe allows only the current user and rejects remote clients. The first instance owns the pipe name.
- Each end checks the other's process: same executable image, same user SID, and same session.
- Requests hold at most 64 arguments of at most 32 KiB each, and at most 512 KiB in total.
- The shell reads each request within 2 s and answers within 10 s. It serves at most 16 requests at once.
- The launcher calls `AllowSetForegroundWindow` for the shell before it sends. The shell still requests the raise
  when Windows denies the grant.

## Red-green

Seam: `tests/fixtures/shell_launch_probe.lua`, run on private desktops by
`tools/run_surface_latency_probe.py --project-case launch-*`. Each Project runtime writes its own ready record,
so a duplicate runtime is visible.

| Case | Checks |
| --- | --- |
| `launch-forward` | A junction alias with a trailing separator raises the minimized owner without a second runtime. A relative path opens a new Window in the same shell. An uppercase repeat selects that Project again. Native controls still work. |
| `launch-concurrent` | Four launchers start with no shell. One shell remains, with one runtime and one Window. |
| `launch-stale` | After the shell is killed, the next launch becomes the shell. |
| `launch-hung` | With the shell suspended, the launch fails in under 20 s. No Project starts elsewhere. |
| `launch-userdir` | Another `ANVIL_USERDIR` gets its own shell for the same Project. |

Red, before the change (D3D11, run `srb8wzlp`):

- `launch-forward`: "aliased launcher did not exit". The launch became a second shell.
- `launch-concurrent`: "concurrent launchers did not leave exactly one shell".
- `launch-hung`: "hung shell launcher did not exit". The launch became a second shell.
- `launch-stale` and `launch-userdir` passed. They guard ownership recovery and the user-directory boundary.

Green: all five cases pass on D3D11 (`2n37an3e`) and software (`4o94lo21`).
The logs show the intended paths. Forwarded launches report `result=forwarded`. Concurrent launches wait for the
first resolution, then select the loaded Project. The hung launch reports "did not accept the launch in time".
Every launcher's foreground grant was denied on the private desktop (`allowed=0`). The raise still restored
the minimized owner, and native Minimize and Restore stayed responsive.

## Regression checks

D3D11 (`iailbct0`): `duplicate`, `foreground`, `launch`, `arguments`, `option-arguments`, `identity-alias`,
`identity-trailing`, `identity-cwd`, `loaded-switch`, `loaded-launch`, `loaded-resolve`, `dormant-launch`,
`dormant-unload`, `windows-new`, `windows-open`, `windows-picker`, `windows-move`, `windows-close-dirty`,
and `windows-close-launch` pass.

`new-window` failed. Its assertion expected a second shell, which was Phase 3 behavior. The deployed
milestone 4 build fails the same way (`cg1cq_lr`), so this is not a regression. The case now expects
hosted New Window to stay in the same shell; direct mode keeps its separate-process expectation.
After that update, `new-window`, `duplicate`, and `foreground` pass.

Software (`bkh05t_j`): all six `windows-close-*` cases, `windows-new`, `windows-move`, `loaded-launch`,
`loaded-resolve`, `dormant-launch`, `identity-alias`, `duplicate`, `launch`, and `arguments` pass.

## Deployment

`update-anvil-dev-build.bat` rebuilt and installed the dev portable app. It ended all Anvil processes.

- Build `build-windows-x86_64/src/anvil.exe`: `4a7c69c10880104ae96e95a42ba01dbc73a5e9f7bb31caf80f24d96619eaf190`
- Portable `anvil-portable/anvil.exe`: `6c20edcc270e51ea2f6cb54d3fd16f72120c2a8e243f30647b9a14fe9b4af7aa`
- Latency reference, milestone 4 portable: `c9508d0b85b2f45c76194a7c2a1860b28588fce8baf277b021af2a2a3d6a2304`

## Matched latency

Run on 2026-10-11, after the user approved Phase 6 milestone 3. The machine still ran other heavy work.
The saved milestone 4 and 5 portables no longer existed, so both builds were rebuilt from their commits
in detached worktrees (`anvil-baseline-5241a046`, `anvil-baseline-32df6800`). Options match the dev build:
MinGW GCC, `debugoptimized`, optimization 3, portable, `forcefallback`, PPM off. Each app was installed with
`meson install --strip` and uses its own revision's runtime data.

- Reference, milestone 4 (`5241a046`): `5f6f3d281dd87536acb4effe8305ec0bad231ef643eae2df166babad2ce88fbb`
- Candidate, milestone 5 (`32df6800`): `f90312e934948015fb5c9940402b6e7aa937887de16f15f1d792c297d3bd980e`

These hashes differ from the deployed portables above; PE timestamps differ between builds.
Three alternating pairs, 360 valid samples per row and build, no failed or ineligible runs.
Evidence: `%TEMP%/anvil-phase5-m5-matched-_cma7spy/results.json`.

| Row | Milestone 4 p50 / p90 / p99 | Milestone 5 p50 / p90 / p99 |
| --- | --- | --- |
| direct D3D11 | 8.61 / 17.44 / 21.25 | 8.16 / 17.53 / 30.62 |
| shell D3D11 | 8.12 / 17.43 / 20.76 | 8.88 / 18.32 / 21.59 |
| direct software | 16.87 / 26.12 / 43.36 | 16.07 / 24.11 / 30.96 |
| shell software | 13.91 / 22.92 / 27.78 | 13.52 / 21.93 / 26.57 |

Every p50 and p90 difference is below the 2 ms noise bound. The direct D3D11 p99 shift is in a control row:
milestone 5 did not change direct mode. No regression found. Milestone 5 changes launch forwarding only,
not compositing or input.
