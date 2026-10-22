# Spare Project Process Plan

## Status

Plan, not started. Nothing in this plan is implemented.

Commits `01900a24` and `5cd9f77f` come before this plan. The first stops the picker from leaving a half-closed
frame on screen. The second makes a cold Project start about 30% faster.

## Goal

A Project that is not loaded opens almost at once. The target is a first frame within 150 ms of the
selection, for a Project with a small Workspace.

The shell keeps one spare Project process that has already started. When the user selects a Project that is
not loaded, the shell gives that Project to the spare. A Project that the spare cannot take starts cold, as it
does now.

## Measurements

These numbers come from the startup traces in `user\logs\startup`.

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

About 90% of a cold start does not need the Project. A spare that does this work in advance leaves
approximately 50-100 ms for the selection.

Memory: a loaded Project process now uses 250-670 MB of private memory. A spare has no Buffers and no Project
scan, so it uses less. Milestone 0 measures the real cost.

## Why a spare process, and not more startup trimming

More trimming has a low limit. The remaining stages are each 50-400 ms of ordinary Lua module loading, SDL
start and font loading. Even a large effort leaves about 500 ms. A spare removes these stages from the
selection path completely, and does not change them.

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

After the process source, the launch path does not change. Transport, startup timer, states, the selection
hold and the Sidebar status all stay the same. The spare is not a `ShellProject` before its assignment. It is
not in `shell.projects`, in the Sidebar, in Window state, in App State or in adoption records.

The shell keeps a small `shell.spare` record: the process handle, the offer pipe name, the start time, and a
ready flag.

Spare rules:

- Start the spare only after Restore and its staggered startup finish, and after no Project has started for
  about 5 s. The spare must never slow a start that the user waits for.
- Start the spare at below-normal priority. The assignment sets normal priority.
- Keep one spare for each shell, not one for each Window.
- After a spare crash, start a new one with backoff. Show nothing to the user. Log it quietly.
- On shell exit, end the spare at once. It has no user state to save.
- If the spare does not accept an assignment within a short time, the shell ends it and starts a cold process.
  The fallback costs only that short timeout.

### Project side

New argument `--anvil-spare=<offer pipe>`. The process is a hosted Project without a connection until its
assignment. `system.is_hosted_surface()` is true, so plugins load in their hosted form.

The offer pipe reuses the identity checks of `src/shell_adoption.c`. The spare accepts only a shell that runs
the same executable as the same user in the same session. The adoption request names only a pipe. The
assignment adds the argument list that `build_child_command_line` now puts on the command line, for example
`--project <path>`, `--anvil-project-arguments ...` and the restart flag.

After the assignment, the process replaces `ARGS` with the assigned arguments. A later `core:restart` then
restarts the assigned Project, and does not wait for a new assignment.

Before the assignment, the spare sends nothing to the shell. It runs no coroutines: it waits inside a native
call at the gate, and the run loop has not started yet. Threads that plugins schedule during load run after the
assignment, when the Project exists.

### Project gate

The gate splits startup into two parts:

- `core.init` and the pre-loop part of `core.run`: everything that does not need the Project.
- The Project start: resolve the arguments, `core.set_project`, the Project Module, recent Projects, the
  Sidebar source, startup files, Workspace restore and the first frame.

A normal launch runs both parts in sequence, so its behavior does not change. A spare waits between them.

Two facts determine where the gate can be:

1. `core.load_plugins` loads the Project Module (`.anvil_project.lua`) before the plugins. The Project Module
   can change any config, including `config.plugins`. Plugins that load before the Project is known cannot
   honor it.
2. The settings plugin applies saved settings in its `core.run` wrapper, after `core.init`. It also loads
   plugins that are off by default but that the user turned on.

Rules that follow:

- A Project with a Project Module always starts cold. On 2026-10-22, none of the user's 21 recent Projects has
  one. The spare checks this when it receives the assignment, with one file stat.
- Plugin load must not read the Project. This becomes a durable rule for first-party plugins: "Plugin load
  does not read the Project. Work that needs the Project runs after the Project start." A static search found
  no top-level Project reads. Plugin code can still read the Project in functions that run during load, so
  Milestone 3 makes such reads fail in a spare.

### Stale spare

A spare loads code, settings and fonts when it starts. A spare that waits for a long time can become stale:

- The user changes settings, the Color Theme, fonts or `USERDIR\init.lua`.
- The user enables or disables a plugin.
- In the dev install, Lua under the junctioned `data` folders changes.

At assignment, the spare compares a fingerprint of its inputs with the fingerprint from its start. On a
difference, it refuses the assignment, and the shell starts a cold process and replaces the spare. The inputs
are:

- the modification times of `USERDIR\user_settings.lua`, `USERDIR\init.lua` and the `USERDIR\plugins` folder;
- a change counter from a recursive folder watch on `DATADIR`, for the dev workflow. A packaged build does not
  change `DATADIR`, so the watch costs nothing there.

The spare also refuses an assignment when the target Window's display scale is different from the scale at the
spare's start. Fonts and layout use the scale at startup. Milestone 0 checks whether the runtime scale change
path can replace this rule.

## Milestones

Each milestone is its own commit, with red-green tests where a durable behavior exists.

### Milestone 0: measure

- Find the private memory of a process that stops at the gate, both with the conservative gate and with the
  gate after plugins. Use a temporary environment switch. Do not commit the switch.
- Find the time from the gate to the first frame for 3 real Projects with different Workspace sizes.
- Check whether the runtime scale change path works for a spare that moves to a Window with a different
  scale.
- Write the numbers in this plan. Stop if the memory cost is too high, and ask the user.

### Milestone 1: split startup at a conservative gate

- Move `parse_startup_arguments` and everything from `resolve_initial_project_path` to the end of startup into
  a Project start function. Put the gate before it, so plugins still load after the Project.
- A normal launch calls both parts in sequence, with no change in behavior.
- Check: the Lua runtime and UI suites, and the `switch`, `loaded-switch`, `restore-loaded` and `select-hold`
  shell probes.

### Milestone 2: spare process and assignment

- Add `--anvil-spare`, the offer pipe, the assignment message and `ARGS` replacement.
- Add the `shell.spare` record, the spare rules and the third process source in `launch_thread`.
- Add a stale-spare refusal for the Project Module case only. Milestone 4 adds the other inputs.
- New shell probes:
  - `spare-assign`: selecting a Project that is not loaded uses the spare's PID. A new spare starts later.
  - `spare-crash`: a crashed spare causes a cold start and a new spare. The user sees no notice.
  - `spare-quit`: shell exit does not wait for the spare and leaves no process.
  - `spare-project-module`: a Project with `.anvil_project.lua` starts cold.
- This milestone saves only the stages before the conservative gate (about 300 ms).

### Milestone 3: move the gate after plugins

- Move the gate into `core.run`, after the settings wrapper applies saved settings and before the run loop.
  Move `create_window` before the gate.
- In a spare before its assignment, make `core.root_project()` and reads of `core.projects` raise a clear
  error. Run the spare with all plugins and correct each plugin that fails. Move its work after the Project
  start.
- Add a UI test for the durable rule: a plugin load with no Project loaded completes, and the Project start
  then sets up the Project.
- Run `tools/run_scenarios.py` and the shell probes again.

### Milestone 4: stale spare

- Add the fingerprint, the `DATADIR` watch and the scale check.
- New shell probes:
  - `spare-stale-settings`: a settings change after the spare's start causes a cold start, and then a new
    spare.
  - `spare-stale-data`: a Lua file change under `DATADIR` causes the same result.

### Milestone 5: finish

- Add quiet logs for spare start, readiness, assignment, refusal with its reason, and replacement.
- Update `AGENTS.md`: spare lifecycle, gate rule, probes to run.
- Deploy with `update-anvil-dev-build.bat`. Compare selection-to-first-frame times with the measurements in
  this plan.

## Open questions

1. Memory budget: what spare cost is acceptable? Milestone 0 provides the number.
2. Spare timing: is "5 s after the last Project start" correct, or must the spare start only after the user has
   been idle for a period?
3. Should the shell keep a spare when no Window is open? The recommendation is no: the shell then exits.
