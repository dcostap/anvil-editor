# Phase 6: shell restart and restore

## Status

Draft for review. No code yet. Commit and stop for review after each milestone.
Phase 5 closeout precedes milestone 1: matched latency for Phase 5 milestone 5, and the interactive foreground check.
Hosted mode stays opt-in.
Physical input, IME, mixed DPI, allocator failure, and instrumented lifetime acceptance remain open.

Read [the main plan](MULTIPROCESS_SHELL_PLAN.md) and [Phase 5](PHASE5_SEVERAL_WINDOWS.md) first.
Use the terms in `CONTEXT.md`. This plan does not rename them.
"Adoption" below names a shell taking over running Project processes. It is a plan term, not a glossary term.

## Goal

From the main plan:

- Restore Anvil Windows, Selected Projects, and Workspaces after a full quit, a crash, or a reboot.
- After a shell restart, adopt running Projects and Terminal Sessions.

## Current state

What exists and what this phase reuses:

- Workspaces save on activity, on focus loss, and at least every 10 s (Phase 1). A Project restores its own
  Workspace when it starts. Restore does not need new Workspace code.
- Terminal Session hosts survive Project and shell loss. They publish registry records. After a reboot, a
  Terminal Session revives from its disk snapshot and never reruns a command by itself (Phase 2).
- Dormant Projects load with their saved Workspace when selected (Phase 4).
- One shell per executable and user directory. A later launch forwards to it (Phase 5 milestone 5).
- The shell persists nothing. Each new Window opens at 80% of the primary display.
- On shell loss, a Project saves and detaches, then exits within 5 s (`src/hosted_surface.c`).
  The Sidebar process also exits.
- Each hosted Project writes the shared `appstate.lua` file itself.

## Scope

In scope: shell-written App State for Windows, cold restore, restore failure handling, and Project adoption.

Out of scope:

- direct mode and non-Windows behavior;
- final Sidebar design (Phase 7);
- automatic shell relaunch after a crash;
- adopting the Sidebar process (see decision 3);
- automatic GPU recovery.

## Milestones

### 1. Shell-written Window state and cold restore

The shell records each open Anvil Window in App State:

- placement, mode (normal or maximized), and monitor;
- the Selected Project, by path and identity;
- Window order, so the frontmost Window restores in front.

Writes are debounced, bounded in size, and atomic (write a temporary file, then replace).
A worker thread writes the file, so the native UI thread never waits on disk.
The shell writes after placement, selection, New Window, Move, and Close.
The shell owns the file. Lua never writes it.

A launch with no Project argument restores the saved Windows. Each Window loads its Selected Project.
That Project restores its own Workspace. Other Projects stay in the Project Sidebar as Dormant Projects.
Decision 2 covers a launch with a Project argument.

Seams: private-desktop fixtures through `tools/run_surface_latency_probe.py`.

- Two Windows with different Selected Projects and bounds. Close the last Window, then launch.
  The same Windows return with their bounds, modes, Selected Projects, and Workspace open files.
- Kill every Anvil process with `TerminateProcess` (crash and reboot model), then launch.
  The last written state returns.
- Sequential Close follows decision 1.

Red first: today the second launch opens one empty-sized Window with only the argument's Project.

### 2. Restore failure handling

Restore must never block startup or the native controls.

- A missing, corrupt, partial, or too-large state file starts one fresh Window. The shell logs why.
- A missing Project directory leaves its Window empty with a notice. Its Project Sidebar entry stays.
- A Window saved on a removed monitor moves fully onto a visible monitor. Mixed-DPI bounds use the target
  monitor's scale.
- Restored Projects start in a bounded sequence: the frontmost Window first, then the others.
  Native controls stay responsive in every Window while the others start.
- An external launch during restore waits for the restore's identities, like the first Project in
  milestone 5. It cannot duplicate a restoring Project.

Seams: the same fixtures with a corrupt file, a removed directory, off-screen bounds, delayed startup
(`ANVIL_SURFACE_FAULT_STARTUP`), and a concurrent external launch.

### 3. Project adoption after shell loss

Today a Project exits after shell loss. With adoption, it waits for a new shell instead:

1. On loss it still saves and detaches first, so a failed adoption loses nothing.
2. It stops rendering and publishes an adoption record under `USERDIR`: PID, Project identity, saved Window,
   pipe name, and creation time.
3. It listens on its own pipe for a bounded adoption period (decision 4), then exits as today.

The next shell (from any launch) reads the adoption records before it restores:

- It checks that each PID is alive and runs the same executable, as the same user, in the same session.
  It reuses the milestone 5 identity checks.
- It connects with a new connection generation and creates new shared surfaces.
- It places each adopted Project in its saved Window and starts new Projects only for the rest.
- A stale record, a dead PID, or a failed handshake falls back to a normal Project start.
  Never two runtimes for one Project.

The Project process accepts only a shell that passes the same checks. The request is bounded and versioned.
It does not add a general remote call.
Terminal Sessions need no adoption: they already reattach to their Project process, which stays alive.
The Sidebar process restarts (decision 3).

Seams: kill the shell with `TerminateProcess` and launch again.

- The same Project PIDs return in their saved Windows, with unsaved edits and live Terminal Sessions intact.
- With no new launch, each Project exits after the adoption period.
- A stale record, a hung Project, and a different user directory never block startup or duplicate a Project.

Run matched latency after this milestone, because it changes transport setup.

## Review decisions

1. **What does "full quit" restore?** Close is per Window. The last Window Close ends the shell.
   Recommendation: restore the Windows open when the shell ended. A Window the user closed earlier is gone.
   After separate Closes, only the last Window returns. A crash or reboot keeps every Window from the last write.
   Alternative: add an explicit Quit Anvil command that closes every Window and restores them all.
   Phase 5 kept that application-wide Quit out of scope.
2. **Launch with a Project argument.** Recommendation: restore the saved Windows, then handle the argument as
   an external launch: select the Project in its restored Window, or open a new Window for it.
   Alternative: a launch with an argument skips restore.
3. **Sidebar process.** The main plan says to adopt it. Recommendation: restart it instead. The shell owns the
   Project Sidebar model, so a new Sidebar process loses nothing, and its restart path is already tested.
4. **Adoption period.** Recommendation: 60 s after shell loss. Longer keeps unrendered Projects in memory;
   shorter loses edits made since the last save if the user relaunches late.
   No automatic relaunch: the user's next launch adopts.
5. **App State writers.** Hosted Projects still write `appstate.lua` for recent Projects and find history.
   Recommendation: the shell writes Window state to a separate file in `USERDIR`, so Project writes cannot
   overwrite it. Recent Projects stay where they are.

## Verification and completion

Use focused red-green checks at the private-desktop runner, with isolated data and owned process handles.
Do not capture pixels or use the user's Windows.
Run D3D11 and software checks for each milestone.
Milestones 1 and 2 do not change compositing or input, so they need no latency gate.
Milestone 3 needs matched latency against the previous milestone's portable.
Commit each milestone after its focused checks. Report hashes and deployment logs.
Keep all manual and instrumented acceptance gates visible.
