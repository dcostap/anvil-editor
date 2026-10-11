# Phase 5: several Anvil Windows

## Status

Approved for staged implementation. Commit and stop for review after each milestone.
Implement milestone 1 first, then 2a, then 2b after their separate reviews.
The user approved milestone 1. Its [verification record](PHASE5_WINDOW_STATE.md) retains checks, latency, and deployment evidence.
Milestone 2a is implemented and deployed. Its [verification record](PHASE5_NEW_WINDOWS.md) retains red-green checks and matched latency.
The user approved 2a and the separate selection fix, `f565e01c`, then authorized 2b.
Milestone 2b is implemented. Its [verification record](PHASE5_SHARED_SIDEBARS.md) retains checks and deployment evidence.
The user approved `f565e01c` and `ec0e91a3`, then authorized milestone 3.
Milestone 3 is implemented. Its [verification record](PHASE5_PROJECT_MOVE.md) retains checks, failures, and matched latency.
The user approved `f2742110`. Review follow-up `48b33622` keeps Move choices across Sidebar revisions.
The Sidebar Restart [cause record](PHASE5_SIDEBAR_RESTART_CAUSE.md) satisfies the milestone-4 entry gate.
The user authorized milestone 4. It is implemented. Its [verification record](PHASE5_WINDOW_CLOSE.md) retains checks, failures, and matched latency.
The user authorized milestone 5. It is implemented. Its [verification record](PHASE5_EXTERNAL_LAUNCH.md) retains checks and deployment hashes.
The user approved milestone 5. Its matched latency found no regression. Phase 5 is complete.
The interactive foreground check remains open with the manual gates below.
Hosted mode stays opt-in.
Physical input, IME, mixed DPI, allocator failure, and instrumented lifetime acceptance remain open.
The milestone-2 latency entry gate is satisfied on 2026-10-10.
The [fresh baseline investigation](PHASE4_LATENCY_BASELINE.md) records the accepted unlocked/display-on matched repeat.
Do not use unreliable latency results to accept a performance change.
Treat differences below about 2 ms as noise.
Use direct latency rows as machine-noise controls. Act on hosted-software shifts only when they clearly exceed matched direct shifts.

Read [the main plan](MULTIPROCESS_SHELL_PLAN.md) and [Phase 4](PHASE4_PROJECTS_AND_SIDEBAR.md) first.
Use the terms in `CONTEXT.md`. This plan does not rename them.

## Scope

One native shell owns several Anvil Windows and the shared Project Sidebar model.
Each Window presents one Selected Project or remains empty.
A Project remains loaded at most once and appears in at most one Window.
Selecting a Project presented elsewhere brings its owning Window forward.
An explicit move transfers a loaded Project without restarting it.
Terminal Sessions remain independent. A move does not detach them or replay commands.

Keep direct mode and non-Windows behavior unchanged.
Do not add shell adoption, full restore, or final Sidebar design. Those remain Phases 6 and 7.
Do not add automatic GPU recovery or terminate a Project after transport loss.

## Proposed ownership

Separate shell-wide services from per-Window state.

- Shell: Project identity, runtimes, Dormant records, Sidebar model, workers, and process lifetime.
- Window: native handle, placement, DPI, compositor, input capture, selection, and Close sequence.
- Project: assigned Window, connection generation, configuration, dialogs, and Close state.
- Sidebar frontend: one process with a separate hosted surface for each Window.

Use stable Window IDs. Do not use an HWND or pointer as a protocol identity.
Keep Project runtime ownership from Phase 4. Window removal must not invalidate asynchronous users.
Retain distinct frame resources, retry state, and configuration identities for every surface.
A frame or input event from Window A must never reach Window B.

## Milestones

### 1. Per-Window native state

Move existing Window state into a Window record without changing single-Window behavior.
Keep shell-wide Project identity and the Sidebar model outside that record.
Route native callbacks through their owned Window record.

Seams: existing owned-window lifecycle, routing, dialogs, frame failure, and loaded-Project checks.
Add a targeted red only for newly required observable behavior, not structure or helper ordering.
Commit after focused checks pass.

### 2. New Window and shared Sidebar surfaces

Implement this milestone in two separate commits. Stop for review after each commit.

#### 2a. New Window and hosted commands

Add New Window, the empty state, native Title Bar menu, and shell-owned folder picker.
Route the existing hosted commands and Project APIs through the shell.
Keep the Sidebar in the first Window during this slice.

#### 2b. Shared Sidebar surfaces

Add one hosted Sidebar surface per Window, served by the single Sidebar process.
Keep independent surface sizes, configurations, selection, and input routing.

Entry gate: latency baseline re-established through matched, alternating runs of freshly built reference and candidate revisions.
This gate is satisfied by the 2026-10-10 repeat. All 24 runs are complete and environment-valid, with historical-range medians.
Keep recording console lock and display power state. Exclude invalid environments from future baselines and performance gates.

Add an explicit hosted New Window request.
Reuse `core:new_anvil_window` and `core.open_new_window()`. Route them to the shell in hosted mode.
Do not add `core:new_window` or a duplicate command. Do not prescribe a keyboard shortcut.
Create an empty Window without loading another copy of the current Project.
The shell draws a simple empty state in its main area, not a blank Project surface.
Show "No Project selected" with instructions to open a Project or select one in the Sidebar.
This state requires no Project process. Phase 7 owns its final design.

Each Window exposes New Window and Open Project through a native Title Bar menu.
New Window sends the same shell action as `core:new_anvil_window`. It is not a second command.
Open Project opens a shell-owned native folder picker, with the requesting Window as its parent.
In an empty Window, it selects or loads the chosen Project there. It does not create another empty Window.
In a Window with a Selected Project, it uses the new-Window Project policy below.
The existing Sidebar list also selects or loads Projects for the receiving Window.
If a Project is loaded elsewhere, these selection actions raise and select it in its owning Window.
The requesting empty Window stays empty in that case.
The native menu remains usable without a Project process and while the shared Sidebar is unavailable.
Window Close invalidates an outstanding picker result. A late result must not load a Project into a removed Window.

Define the existing new-Window Project API separately from selection in an empty Window:

- Hosted `core.open_project_in_new_window(project)` sends the path and requesting Window ID to the shell.
- Resolve identity through the existing worker boundary before creating a Window.
- For an already loaded Project, raise and select its owning Window. Do not create a duplicate Window or runtime.
- For an unloaded or Dormant Project, create a Window and load it there through the normal launch path.
- Keep the new Window usable if loading fails. Report the failure through the existing Project status and recovery rules.
- Keep direct and non-Windows behavior unchanged.

The existing Open Project actions use this API, including `core:open_project_folder` and its system-file-picker variant.
In hosted mode, let shell identity rules handle an already loaded path instead of rejecting it in the Project frontend.
Update the hosted IPC wrapper and other in-repo callers to delegate to the shell, not spawn another shell.
Do not add alternative Open Project commands.

Let the one Sidebar frontend render each Window at its own size and scale.
Use bounded surface records and reject stale Window IDs or configuration generations.
Each snapshot includes Selected Project IDs per Window and the owning Window ID for every loaded Project.
Show each Project's owning Window in the Sidebar. Selection highlighting uses the receiving Window's Selected Project.
This is a minimal working presentation. Phase 7 owns the final design.

Tests must prove two owned native Windows, one shell, and one Sidebar process.
Invoke `core:new_anvil_window` and the existing Open Project actions through their public command seams.
Verify an empty Window's state and native New Window/Open Project actions without a Project process.
Verify load, duplicate selection, cancellation, and a late picker result after the requesting Window closes.
Select different Projects and verify independent input, resize, minimize, and native controls.
Suspend the Sidebar. Both Windows and their Projects must remain usable.
The shared-process boundary means every Sidebar surface stalls together. Projects and native controls keep working.
Crash it. Bounded recovery must recreate its surfaces without restarting Projects.

### 3. Owning-Window selection and explicit Project move

Selecting a Project in another Window raises that Window. It does not silently move the Project.
Move requires an explicit source Project and target Window.
Expose Move through a minimal Sidebar action that offers the existing target Windows.
Send the source Project ID and target Window ID. Do not infer the target from keyboard focus.
Phase 7 owns the final Move presentation.
An occupied target keeps its previous Project loaded but unpresented.
The source selects another assigned Project or remains empty.
Reject Move during a pending Close choice or an open native file dialog. Show a status message; do not queue it.
The open dialog retains its original parent until completion.

Apply a move as one shell-owned transition:

1. Validate both Windows and retain the Project.
2. Cancel old capture, focus, and composition.
3. Revoke old rendering permission and discard old presentation resources.
4. Change the assignment and configure the target surface.
5. Grant rendering and focus according to target visibility and native focus.
6. Release the retained reference after the transition.

Tests must prove unchanged Project PID, Buffers, text selection, Workspace, and Terminal Session attachment.
Check a move to an occupied Window, an empty Window, and a minimized Window.
Old frames, input, IME areas, and dialog results must not enter the target configuration.
Physical IME acceptance remains separate from synthetic checks.

### 4. Per-Window Close and local failure

Entry gate: identify the cause of the retained Sidebar Restart deadline failure.
The [cause record](PHASE5_SIDEBAR_RESTART_CAUSE.md) identifies it: idle-priority GPU driver threads delay process exit on a saturated CPU.
The user authorized milestone 4. Step 1 raises those threads before Anvil ends a process.
Step 2 adds the checks below and fixes a dropped pending selection. See [the record](PHASE5_WINDOW_CLOSE.md).

Window Close checks only Projects assigned to that Window, using the normal Close policies.
Unload each assigned Project through the normal Close policy. Terminal Sessions follow the Phase 4 unload rules.
Kept Terminal Sessions remain independent. Do not replace this policy with process termination.
Quit inside a Project closes its assigned Window, not every Window.
Cancel stops that Window's later Close requests. Earlier accepted closes remain complete.
The last accepted Window Close ends the shell through the existing bounded shutdown.

Test dirty Projects in both Windows. Closing A must not ask about or end B.
Test Close/Cancel, empty Window Close, and pending launch.
Test rejected Move during a Close choice or native dialog. Verify that it does not run later.
A crashed or hung Project must not block either Window's native controls.
A compositor failure must remain local where the native renderer permits it.
Document any unavoidable shared-device failure boundary before choosing recovery behavior.

### 5. External launch and duplicate selection

External hosted launches must reach the existing shell rather than create duplicate Project runtimes.
Perform discovery, identity validation, and process startup off the native UI thread.
Authenticate bounded requests. Do not add a general RPC system.
Preserve direct-mode IPC behavior and same-user-directory boundaries.

Test canonical path aliases, concurrent launch requests, stale shell records, and bounded launch failure.
An already presented Project raises its owning Window.
The external launcher grants the shell foreground permission with `AllowSetForegroundWindow` before requesting a raise.
Retain the explicit raise request and handle a denied foreground grant without blocking native controls.
Do not add adoption after shell loss in this milestone.

The user authorized milestone 5. It is implemented; see [the record](PHASE5_EXTERNAL_LAUNCH.md).

## Review decisions

The user accepted all seven decisions, with the file-dialog rule clarified below:

- New Window creates an empty Window. Loading a Project is a separate selection action.
- Each loaded Project has one assigned Window, including while unpresented.
- Selecting an unpresented Project assigned elsewhere raises and selects it in that Window.
- Explicit move preserves the target's previous Project as loaded and unpresented.
- Quit and Close remain per-Window; an explicit future application-wide Quit is outside this phase.
- Moving during a pending Close choice is rejected until that choice completes.
- A native file dialog keeps its original parent until completion. Reject Move with a status message while it remains open.

These decisions clarify assignment and pending-choice boundaries. They do not change the glossary.

## Verification and completion

Use focused red-green checks at commands, model actions, native events, and authenticated transport boundaries.
Reuse the private-desktop runner with isolated data, namespaces, and owned process handles.
Do not capture pixels or use the user's Windows.
Run D3D11 and software checks where the changed behavior crosses renderer boundaries.
Do not run unrelated suites or overlap latency with builds or correctness checks.
Retain partial runs, unmatched inputs, timing tails, and maxima. Incomplete matches fail.

Commit each complete milestone after its focused checks.
For compositing or input changes, require environment-valid latency runs with exit 0, not exit 2.
Report their medians beside the accepted 2026-10-10 baseline.
Warn before updating the portable app. The updater ends Terminal Sessions and running commands.
Report executable hashes and fresh deployment logs.
Keep all manual and instrumented acceptance gates visible.
