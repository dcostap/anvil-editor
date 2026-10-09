# Phase 5: several Anvil Windows

## Status

Draft for review. Do not implement this plan before approval.
Phase 4 closeout precedes this work.
Hosted mode stays opt-in.
Physical input, IME, mixed DPI, allocator failure, and instrumented lifetime acceptance remain open.
Re-establish a reproducible latency baseline before milestone 2. This entry gate is blocking.
The [fresh baseline investigation](PHASE4_LATENCY_BASELINE.md) records current evidence and the remaining environment control.
Do not use unreliable latency results to accept a performance change.
Treat differences below about 2 ms as noise.

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

Entry gate: latency baseline re-established through matched, alternating runs of freshly built reference and candidate revisions.
Record console lock and display power state. Explain any shared environment or harness slowdown before accepting the baseline.

Add an explicit hosted New Window request.
Expose it through the existing command system as `core:new_window`, without prescribing a keyboard shortcut.
Create an empty Window without loading another copy of the current Project.
Let the one Sidebar frontend render each Window at its own size and scale.
Use bounded surface records and reject stale Window IDs or configuration generations.
Each snapshot includes Selected Project IDs per Window and the owning Window ID for every loaded Project.
Show each Project's owning Window in the Sidebar. Selection highlighting uses the receiving Window's Selected Project.
This is a minimal working presentation. Phase 7 owns the final design.

Tests must prove two owned native Windows, one shell, and one Sidebar process.
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
Warn before updating the portable app. The updater ends Terminal Sessions and running commands.
Report executable hashes and fresh deployment logs.
Keep all manual and instrumented acceptance gates visible.
