# Spare Project Process Plan

## Status

Plan, not started. This review changes the plan only, not the runtime.
No runtime measurements or fault probes were run for this review.

Commits `01900a24` and `5cd9f77f` come before this plan. The first stops the picker from leaving a half-closed
frame on screen. The second trims cold Project startup. The measurements below do not establish a percentage improvement.

## Goal

A Dormant Project should open quickly when a ready spare is available.
The target is a presented Project frame within 150 ms of selection, for a small Workspace.
Measure Project readiness separately. An empty frame does not prove that Workspace restore finished.

The shell keeps one spare Project process that has already started. When the user selects a Project that is
not loaded, the shell gives that Project to the spare. A Project that the spare cannot take starts cold, as it
does now.

## Measurements

The original plan reports these numbers from startup traces in `user\logs\startup`.
This review did not reproduce them. Preserve trace paths and build IDs with the next measurements.

A cold start of `learning_odin` took 836 ms to its first frame after `5cd9f77f`. Before that commit, a cold
start of `rise_of_nations` took 1202 ms. The 836 ms divides like this:

| Stage | ms | Does it need the Project? |
| --- | ---: | --- |
| Process and Lua start | ~10 | No |
| `display_info_and_scale` (SDL video start) | 105-120 | No |
| Core modules, panels, default commands | ~200 | No |
| `set_initial_project` | ~1 | Yes |
| `load_all_plugins` (includes fonts, ~125 ms) | 350-440 | Only in a few places (see Project gate) |
| `create_window` | ~50 | No |
| Settings apply in `core.run` | ~35 | No |
| First frame (includes Workspace restore) | ~50 | Yes |

These stages suggest a substantial saving, but their independence from the Project remains to be proved.
The two totals use different Projects, so they are not a controlled comparison.
The estimated 50-100 ms assignment path excludes unmeasured transport, validation, and shell presentation costs.

The original plan reports 250-670 MB of private memory for a loaded Project process.
A spare should use less without Buffers or a Project scan. Milestone 0 measures the real cost.

## Why a spare process, and not more startup trimming

A spare moves module, SDL, and font startup before selection. This is a promising trade of memory for latency.
The traces do not establish a 500 ms lower bound for startup trimming.
Keep the conservative gate if the deeper gate adds substantial complexity for little measured benefit.

## Review findings

- `data/plugins/workspace.lua` restores the Workspace in a `core.run` wrapper, before calling the wrapped function.
  A gate in the base `core.run` therefore cannot safely precede all Project work.
- `data/plugins/settings.lua` also wraps `core.run`. Its optional module reload reads `core.root_project()`.
  Settings preparation and Project startup need explicit ordering, not another wrapper.
- `src/main.c` creates Lua `ARGS` from native `AppState.argc/argv` whenever it creates a Lua state.
  Replacing only Lua `ARGS` does not preserve the assignment through a Lua restart.
- A folder's modification time does not detect edits inside existing plugin files.
  A recursive watch on a junction parent also needs verification against the dev directory layout.
- One ready flag does not prevent two launch workers from claiming the same spare.
  Timeout after acceptance can also create duplicate Project runtimes without explicit ownership rules.
- `core.init` reads App State and cleans recent Projects before `parse_startup_arguments`.
  Moving argument parsing alone leaves stale state in a waiting spare.
- Confirming process exit prevents concurrent runtimes, but cannot undo Workspace restore or other startup side effects.
  Automatic cold fallback needs a boundary before Project work starts.
- A spare prepared past plugin loading cannot return to the conservative gate.
  Choose its preparation depth before startup, not during assignment.

## Design

### Overview

1. When it has no other work, the shell starts one spare process: `anvil.exe --anvil-spare=<offer pipe>`.
2. The spare runs every startup stage that does not need the Project, then stops at the Project gate. It waits
   for an assignment on its offer pipe.
3. The user selects a Project that is not loaded. The shell's launch worker sends an assignment to the spare.
   The assignment names the surface pipe and gives the Project's argument list.
4. The spare connects to the surface pipe, as an adopted Project does, and continues from the gate.
5. The shell starts a new spare when the system is idle again.

### Shell side

`launch_thread` in `src/anvil_shell.c` already has two process sources. It adopts an orphaned Project when it
has `adopt_pid`. Otherwise it calls `CreateProcessW`. The spare becomes a third source between them:

- Adopt an orphaned Project, when one is offered.
- Else, assign the Project to the spare, when it is ready and can take the Project.
- Else, start a cold process.

After assignment, retain the existing transport and selection behavior. Start the Project startup timer at assignment, not spare creation.
Keep first-frame and Project-ready reports separate. The spare is not a `ShellProject` before its assignment. It is
not in `shell.projects`, in the Sidebar, in Window state, in App State or in adoption records.

The shell keeps one record with the process handle, pipe identity, timestamps, and lifecycle state.
Use explicit states: absent, starting, ready, and claimed. A failed process leaves the record after cleanup.
The shell thread owns this record. It transfers the handle to one launch worker before dispatching that worker.
Other launches start cold. They never wait for a starting or claimed spare.

The spare reports ready only after preparation and preparation-input validation succeed.
Validate assignment inputs later, when they exist.
It sends this report on the offer channel, not the Project surface channel.
Bound preparation time as well as assignment time.

Spare rules:

- Start the spare after Restore completes and pending Project launches finish, with an initial five-second quiet interval.
  This is tuning, not a test contract. Measure foreground latency during preparation; low priority does not remove I/O contention.
- Start the spare at below-normal priority. The assignment sets normal priority.
- Keep one spare for each shell, not one for each Window.
- After a spare crash, start a new one with backoff. Show nothing to the user. Log it quietly.
- On shell exit, cancel preparation and assignment, then release their handles without blocking the shell event loop.
  An unassigned spare also exits when its owning shell dies. Do not publish an adoption record for it.
- If assignment times out, terminate the claimed spare and confirm its exit before starting cold.
  If exit cannot be confirmed, report the launch failure rather than start a duplicate runtime.
  Measure the whole fallback delay, including termination. Do not promise that it equals the pipe timeout.
  This automatic fallback applies only before the shell authorizes Project startup, as defined below.

Do not start a replacement while the claimed process still belongs to an unfinished assignment.
After transfer to normal Project ownership, schedule replacement preparation through the same quiet-period rule.

### Assignment contract

Keep this a single-use assignment, not a reusable process pool.
Use a versioned, bounded message with an assignment ID, surface pipe, arguments, working directory, and required display information.
Encode argument lengths explicitly. Reject malformed, oversized, or unsupported requests before Project work starts.
Authenticate both pipe peers and bind the spare to its owning shell, including its user-directory identity.

Acceptance consumes the spare permanently. A refusal also discards it for the first implementation.
Acceptance does not authorize Project work. The spare first attaches to the assigned surface transport.
The shell then records normal Project ownership and authorizes continuation from the gate.
Record ownership before sending authorization. Once sending begins, assume Project work can start, even without a reply.
Reuse an existing transport handshake if it can enforce this boundary; otherwise add one explicit continuation message.
Before authorization, cancellation can terminate the spare and retry cold after confirmed exit.
After authorization, use normal Project startup failure handling, not automatic spare fallback.
A lost authorization reply must not trigger a second Workspace restore or duplicate Terminal Session creation.
Match replies and surface connections to the current launch connection and assignment.
Ignore late replies after cancellation. Never return a claimed process to the ready state.
Cover shell exit and Project removal during assignment. A selection change alone follows existing background-load behavior.

Use the current launch arguments as the source of truth, not a second independent command-line builder.
Initially exclude Sidebar launches, CLI commands, and restart launches from spare use.
Keep adoption first. Already-loaded Projects continue through their existing selection path.

### Project side

New argument `--anvil-spare=<offer pipe>`. The process is a hosted Project without a connection until its
assignment. `system.is_hosted_surface()` is true, so plugins load in their hosted form.

The offer pipe reuses the identity checks of `src/shell_adoption.c`. The spare accepts only a shell that runs
the same executable as the same user in the same session. The adoption request names only a pipe. The
assignment adds the argument list that `build_child_command_line` now puts on the command line, for example
`--project <path>` and `--anvil-project-arguments ...`. Restart launches remain cold initially.

After assignment, update both native argument storage and Lua `ARGS`, plus the existing native Project and restart state.
Remove spare-only arguments. Preserve argument ownership for the process lifetime.
Resolve relative paths using the launch working directory, not the spare's preparation directory.
Set the process working directory and `core.init_working_dir` before Project startup.
Audit other cached launch state. Replacing arguments alone does not update cached paths or native launch flags.
Test both Lua restart and shell-managed restart against the assigned Project.

Before assignment, the spare sends only lifecycle messages on its offer channel.
It sends no Project surface, Sidebar, readiness, or adoption messages.
The Lua run loop and scheduled coroutines remain stopped at the gate.
This does not stop native workers or child processes started during module loading; audit those separately.
Waiting must still detect owner death, cancellation, and input invalidation without a Lua frame loop.
An unassigned spare must not save App State, restore a Workspace, scan a Project, or open visible windows.

### Project gate

The gate splits startup into two parts:

- `core.init` and the pre-loop part of `core.run`: everything that does not need the Project.
- The Project start: resolve the arguments, `core.set_project`, the Project Module, recent Projects, the
  Sidebar source, startup files, Workspace restore and the first frame.

Use explicit preparation and Project-start calls. Do not locate the boundary through `core.run` wrapper order.
A normal launch retains its current ordering and behavior. A spare waits between the explicit phases.
Move Workspace restore and Project-dependent settings reload into the assigned phase without changing normal launch semantics.
Move App State reads and recent-Project cleanup there too, including the initial Project choice derived from recents.
Do not retain the preparation-time `app_state` table for later restore or saving.
Ensure native hosted mode supports a hidden window before transport attachment; adoption alone does not prove this works.

Two facts determine where the gate can be:

1. `core.load_plugins` loads the Project Module (`.anvil_project.lua`) before the plugins. The Project Module
   can change any config, including `config.plugins`. Plugins that load before the Project is known cannot
   honor it.
2. The settings plugin applies saved settings in its `core.run` wrapper, after `core.init`. It also loads
   plugins that are off by default but that the user turned on.

Rules that follow:

- A Project with a Project Module always starts cold. Recheck its resolved path before acceptance.
  An inaccessible or uncertain result also starts cold. Do not treat a stat error as confirmed absence.
- Plugin load must not read the Project. This becomes a durable rule for first-party plugins: "Plugin load
  does not read the Project. Work that needs the Project runs after the Project start."
  Static searches cannot establish that rule. Plugin code can read the Project in functions called during load, so
  Milestone 3 audits executed load paths. API guards are diagnostics, not proof: table reads and cached references can bypass them.
- User modules and user plugins are external code. Do not assume that they obey the first-party rule.
  Initially use the conservative gate when such code is present. Deeper preparation requires a separate compatibility decision.
  Any preparation failure discards the spare; never assign a partly initialized runtime.

Choose one preparation depth for each spare. Initially, use only the conservative gate.
If deeper preparation is approved, use it only when the user-code check permits it before preparation starts.
Record that depth with the spare. Never try to undo plugin loading during assignment.
A new incompatible input invalidates the spare; start the requested Project cold.
Prepare the replacement at the newly eligible depth. Keep one spare, not one spare for each depth.

### Stale spare

A spare loads code, settings and fonts when it starts. A spare that waits for a long time can become stale:

- The user changes settings, the Color Theme, fonts or `USERDIR\init.lua`.
- The user enables or disables a plugin.
- In the dev install, Lua under the junctioned `data` folders changes.

Establish invalidation before reading preparation inputs. Check again after preparation and before acceptance.
Do not accept a generation that changed while preparing. Discard on watch failure or overflow.
Keep assignment checks bounded; do not scan the runtime tree on selection.

Track saved settings, user modules, plugin files, themes, and font files that preparation actually uses.
Also watch creation of previously absent user modules and plugin directories that determine deeper-gate eligibility.
Include user theme and font directories, not only `USERDIR\plugins`.
Watch actual junction targets in the dev install, and verify nested edits and atomic replacements.
Directory timestamps alone are insufficient. Settings migrations during preparation must not cause an endless replacement loop.
Audit and defer preparation writes where possible.

The standalone runtime may use its build identity instead of watching bundled files only if runtime immutability is established.
External user files still need invalidation. Workspace and recent-Project state must be read after assignment, not cached during preparation.

The spare also refuses an assignment when the target Window's display scale is different from the scale at the
spare's start. Fonts and layout use the scale at startup. Milestone 0 checks whether the runtime scale change
path can replace this rule.

## Milestones

Each milestone is its own commit, with red-green tests where a durable behavior exists.
Milestones 3 and 4 are optional. Proceed only after Milestone 2 shows that deeper preparation merits its added cost.
Do not build a general plugin lifecycle framework or a configurable process pool for this feature.

### Milestone 0: measure

- Find the private memory of a process that stops at the gate, both with the conservative gate and with the
  gate after plugins. Use a temporary environment switch. Do not commit the switch.
- Find the time from the gate to the first frame for 3 real Projects with different Workspace sizes.
  Use isolated copies of their Workspace state and the existing private-desktop runner.
  Do not measure through the daily portable app or change its user state.
- Check whether the runtime scale change path works for a spare that moves to a Window with a different
  scale.
- Write the numbers in this plan. Stop if the memory cost is too high, and ask the user.
- Agree on the memory budget before enabling automatic spares. Measure private bytes and preparation CPU/I/O cost.
- Compare cold, conservative-spare, and deep-spare paths on the same build, Project, Workspace, and display.
  Use repeated runs; report sample count, median, p95, and range.
  Record selection, acceptance, transport connection, first presented frame, and Project-ready timestamps.
  Use a common monotonic clock across processes. Measure presentation at the shell, not at frame submission.
  Identify the agreed small-Workspace fixture before evaluating the 150 ms target.
  Record cache conditions and alternate run order so filesystem warming does not favor the spare path.
- Compare foreground latency with spare preparation enabled and disabled.
  Report fallback latency and ready-spare hit rate separately from successful spare latency.
- Treat the deep-gate measurement as a disposable feasibility experiment, not proof that the startup split is safe.

### Milestone 1: split startup at a conservative gate

- Move `parse_startup_arguments` and everything from `resolve_initial_project_path` to the end of startup into
  a Project start function. Put the gate before it, so plugins still load after the Project.
- Move App State reads, recent-Project cleanup, and their derived initial Project choice after the gate.
  Keep only verified Project-independent state and panel construction before it.
- A normal launch calls both parts in sequence, with no change in behavior.
- Add focused startup-order tests for normal, hosted, and restart paths.
  Check the `switch`, `loaded-switch`, `restore-loaded` and `select-hold` shell probes.
  Run full Lua suites only if the actual refactor crosses enough boundaries to justify them.

### Milestone 2: spare process and assignment

- Add `--anvil-spare`, launch-mode routing, detached hosted initialization, the offer pipe, and complete argument replacement.
- Add the `shell.spare` record, the spare rules and the third process source in `launch_thread`.
- Add refusal for Project Modules and unsupported requests. Add invalidation for every input already prepared at this gate.
  Do not enable automatic spares until these checks pass. Milestone 4 expands coverage for the deeper gate.
- New shell probes:
  - `spare-assign`: selecting a Project that is not loaded uses the spare's PID. A new spare starts later.
  - `spare-crash`: a crashed spare causes a cold start and a new spare. The user sees no notice.
  - `spare-quit`: shell exit does not wait for the spare and leaves no process.
  - `spare-project-module`: a Project with `.anvil_project.lua` starts cold.
  - `spare-race`: concurrent launches cannot consume one spare twice.
  - `spare-timeout`: lost acceptance and late replies never leave two runtimes for one Project.
    Cover both sides of startup authorization. After authorization, a transport failure must not repeat Workspace restore.
  - `spare-owner-exit`: owner death during preparation or assignment leaves no unassigned process.
  - `spare-restart`: assigned arguments and paths survive restart, including spaces and non-ASCII text.
  - `spare-current-state`: assignment reads Workspace and App State changes made while the spare waited.
    Include relative startup paths resolved from a working directory different from the preparation directory.
- Add native protocol tests for malformed messages and peer validation.
- This milestone saves only stages before the conservative gate. Measure the saving before proceeding.
  Stop here if its measured benefit is sufficient. Record that decision instead of implementing the deeper gate by default.

### Milestone 3: move the gate after plugins

- Replace settings and Workspace startup wrapper ordering with explicit phase calls before moving the gate.
  Keep Project Modules before plugins on cold launches. Prepare settings and a hidden window only on eligible spare launches.
- Audit first-party plugin loads, callbacks, native workers, and file writes with no Project present.
  Use Project API guards where practical. Move required Project work into the assigned phase.
- Add a UI test for the durable rule: a plugin load with no Project loaded completes, and the Project start
  then sets up the Project.
- Check observable ordering: Workspace restore occurs once and startup files resolve correctly.
  No Project state changes before startup authorization.
  Preserve User Module, Project Module, mandatory defaults, and saved-settings precedence on cold launches.
  Test settings-enabled plugins as well as plugins enabled by default.
- Run focused startup scenarios and shell probes. Use the existing private-desktop runner for native verification.

### Milestone 4: stale spare

- Complete input invalidation and the scale check before enabling the deeper gate by default.
- New shell probes:
  - `spare-stale-settings`: a settings change after the spare's start causes a cold start, and then a new
    spare.
  - `spare-stale-data`: a Lua file change under `DATADIR` causes the same result.
  - Extend these probes for nested junction files, atomic replacement, preparation-time changes, and watch failure.
  - Check user theme/font changes and display-scale mismatch through their supported paths.

### Milestone 5: finish

- Add quiet lifecycle logs from Milestone 2 onward. Include assignment IDs, reasons, durations, and cold fallback outcomes.
- Update `AGENTS.md`: spare lifecycle, gate rule, probes to run.
- Deploy with `update-anvil-dev-build.bat`. Compare selection-to-first-frame times with the measurements in
  this plan.
  This applies to runtime implementation, not this plan-only review.

## Open questions

1. Memory budget: what spare cost is acceptable? Milestone 0 provides the number.
2. Spare timing: is "5 s after the last Project start" correct, or must the spare start only after the user has
   been idle for a period?
3. Should the shell keep a spare when no Window is open? The recommendation is no: the shell then exits.
4. Does the conservative gate save enough time to avoid deeper startup changes?
5. Is deeper preparation needed with user modules or user plugins? Default to the conservative gate until compatibility is established.

## Completion criteria

- Matched measurements show the saving, its memory cost, and its effect on foreground work.
- Eligible ready-spare selections meet the 150 ms p95 target for the agreed small-Workspace fixture, or the shortfall is reported.
- Normal launches, Project Modules, restart, adoption, and Workspace restore retain their behavior.
- Fault probes show no duplicate Project runtime, unassigned orphan, or shell event-loop wait.
- Stale or unsupported spares fall back safely. No performance claim depends on skipping those checks.
