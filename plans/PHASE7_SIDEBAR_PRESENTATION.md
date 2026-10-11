# Phase 7: Project Sidebar presentation

## Status

Draft, 2026-10-12. The user left the design to the agent and will tweak it later.
The recommendations below are the starting design. [Hosted presentation quality](HOSTED_PRESENTATION_QUALITY.md)
comes first, because the Sidebar's look depends on layered composition.
Commit and stop for review after each milestone. Hosted mode stays opt-in.

Read [the main plan](MULTIPROCESS_SHELL_PLAN.md) and [Phase 4](PHASE4_PROJECTS_AND_SIDEBAR.md) first.
Use the terms in `CONTEXT.md`. This plan does not rename them.

## Goal

From the main plan: design the final Project Sidebar UI.
Phases 4–6 built the model, the Sidebar process, and the behavior. The current view is a diagnostic list.
This phase makes it a daily-use list without changing who owns what: the shell owns the model, the lifecycle,
and selection. The Sidebar process only draws and reports user actions.

## Current state

`data/core/sidebar_view.lua` (124 lines) draws every row with three text lines:

- Project row: folder name, then a state string such as `ready / Window 2 / Close choice`, then
  "Right-click for Move". A loaded Project has an "Unload" button on the right.
- Terminal Session row: title, then `running / busy`, then its working directory.
- A "Refresh" bar above the list. Right-click on a Project opens inline "Move to Window N" rows.

Facts that constrain the design:

- The width is fixed at 240 points (`SHELL_SIDEBAR_POINTS`). There is no collapse.
- Keyboard input always goes to the Selected Project. The Sidebar process receives mouse input only.
- The Sidebar process runs a minimal Lua runtime (`data/core/sidebar_app.lua`). It has the renderer, the theme,
  and the main font, but not the editor's context menu, tooltips, or command system.
- The model already carries: Project path, state (`dormant`, `starting`, `ready`, `closing`, `failed`), owning
  Window, `exists`, Close choice, deferred dialog; per Terminal Session: title, working directory, state
  (`running`, `exited`, `lost`), busy, bell, and attached.
- Bell is in the model but not drawn. Clicking a Terminal Session row does nothing.
- Order is stable: recent order, new Projects first. That was a product decision and stays.

## Scope

In scope: row layout, status display, Project actions, Terminal Session rows, Sidebar width and collapse,
theme keys, and the native menu for Sidebar actions.

Out of scope: keyboard navigation of the Sidebar, drag-and-drop reordering, Project groups or folders,
search in the Sidebar, direct mode, and non-Windows platforms.

## Review decisions

Each item has a recommendation. Accept, change, or reject each one.

1. **Project row.** Recommendation: one line per Project — a status mark, then the folder name.
   The full path shows in a hover tooltip drawn by the Sidebar. Disambiguate equal folder names by adding the
   parent folder name in dim text. The Selected Project of this Window has the selection background.
   Alternative: two lines, with the parent path always visible.
2. **Project status.** Recommendation: a small mark before the name instead of words.
   - Selected in this Window: no mark, selection background.
   - Loaded in another Window: a hollow dot, plus that Window's number in dim text on the right.
   - Loaded in this Window but not selected: a filled dot.
   - Dormant: no mark, dim name.
   - Starting: an animated mark. Failed, not responding, missing directory, Close choice, or open dialog:
     a warning mark in the theme's warning color, with the reason in the tooltip.
   Alternative: keep short status words on a second line.
3. **Actions.** Recommendation: remove the "Unload" button, the "Refresh" bar, and the inline Move rows.
   Right-click a Project to open a native Windows menu owned by the shell: Move to Window (submenu), Unload,
   Remove from list, Copy path, Open in Explorer. Left-click still selects. Refresh stays as an internal
   recovery path, not a visible control.
   Alternative: keep visible buttons that appear on hover.
4. **Remove from list.** New action. Recommendation: allowed only for Dormant Projects with no running Terminal
   Session. It removes the recent entry; it never deletes files or Workspace data. Opening the directory again
   brings it back.
5. **Terminal Session rows.** Recommendation: one line each, indented under its Project — the title, with the
   working directory in the tooltip. A mark shows busy, idle, exited, or bell. Clicking a row selects its
   Project and focuses that Terminal Session in the Project. Under a Dormant Project, clicking loads the
   Project first. Each Project's Terminal Sessions can be collapsed with a chevron; collapsed state persists.
   Alternative: show only a count of Terminal Sessions per Project.
6. **Bell.** Recommendation: a bell mark on the Terminal Session row, and also on its Project row while
   collapsed. Selecting that Terminal Session clears it. No sound, no taskbar flash.
7. **Width and collapse.** Recommendation: drag the Sidebar's right edge to resize it between 160 and 480
   points. A command and a native menu item collapse it to zero width and restore it. Width and collapse
   state apply to all Windows and are saved in the shell's state file.
   Alternative: per-Window width.
8. **Theme.** Recommendation: new style keys in `data/colors/default.lua` for the Sidebar background, row hover,
   status marks, and the warning mark. Other themes override them. The Sidebar process already loads the theme.

## Milestones

### 1. Row layout and status

Decisions 1, 2, and 8. One-line Project rows, status marks, dim Dormant names, folder-name disambiguation,
hover highlight, and the tooltip. Remove the "Right-click for Move" text and the status strings.
Seams: in-process Lua UI tests of `SidebarView` with a fixed model (row kinds, labels, marks, hit testing,
tooltip text). Render check through the render performance gate with a new Sidebar scenario.

### 2. Native Project menu

Decisions 3 and 4. The Sidebar reports a right-click with the Project and screen point. The shell shows a
native popup menu and performs the chosen action through its existing Move and Unload paths.
Remove from list goes through the shell model and its recent-Project source.
Seams: owned-window cases through `tools/run_surface_latency_probe.py` for each menu action, including Move
during a pending Close choice (rejected, as today) and Remove on a loaded Project (not offered).

### 3. Terminal Session rows

Decisions 5 and 6. The shell routes "focus Terminal Session" to the owning Project, which focuses or opens that
Terminal Session view. A Dormant Project loads first, then focuses it.
Seams: an owned-window case that clicks a Terminal Session row in another Window's Sidebar and checks that the
owning Window comes to the front with that Terminal Session focused. Lua tests for collapse and bell marks.

### 4. Width and collapse

Decision 7. Drag-to-resize in the shell, with the Project surface resized to match, plus collapse.
Seams: owned-window cases for resize, collapse, restore after relaunch, and mixed scale.
Run matched latency after this milestone, because it changes the composited layout.

## Verification

Use focused red-green checks per milestone at the seams above. Run D3D11 and software for owned-window cases.
Milestones 1–3 do not change compositing or input routing to Projects, so they need no latency gate.
Milestone 4 needs matched latency against the previous milestone's portable.
Commit each milestone and report hashes and deployment logs.
Manual check after milestone 4: the user uses the Sidebar for a day with hosted mode on.
