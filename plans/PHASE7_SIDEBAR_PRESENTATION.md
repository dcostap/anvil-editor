# Phase 7: Project Sidebar presentation

## Status

Built, 2026-10-15. The user left the design to the agent and will tweak it later. See
[Decisions taken](#decisions-taken) for what shipped; the review list below is the original draft.
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

Commit f1899f7f redesigned the list. `data/core/sidebar_view.lua` now draws:

- A PROJECTS header with Refresh, then the loaded Projects with their Terminal Sessions, then RECENT Dormant
  Projects collapsed behind "Show more".
- One-line Project rows with status dots, rounded hover and selection, an Unload button on hover, and the
  owning Window only for Projects shown in another Window. Right-click still opens inline Move rows.
- One-line Terminal Session rows with a status dot and the title, or "Terminal" when the title is empty.

User feedback, 2026-10-15:

- A Terminal Session row must show the same live title as its tab, for example `[40 s] π - GLP4`. Today the
  Sidebar reads titles from the Terminal Session registry scan, which does not carry the live title.
- The Sidebar does not show which Terminal Session has keyboard focus in its Project.

More user feedback, 2026-10-15 (collected, not yet decided):

- The Sidebar should feel modern: resizable, collapsible, with an animated collapse.
- The PROJECTS header and the Refresh button are probably redundant. Remove that row.
- Group Projects by age. Projects active in the last week, loaded or Dormant, sit in a top-aligned main area.
  Older Projects go into bottom-aligned, collapsible groups such as "Older than a week" and "Older than a
  month", below a separator. The bottom area takes at most about 40% of the height. Loading an older Project
  moves it to the main area.
- Each Terminal Session shows its age, for example its last activity ("20 min", "1 d").
- A Project's age is its own activity or its newest Terminal Session's activity, whichever is later.
- Inside a Project, older Terminal Sessions go into collapsible subgroups, collapsed by default. A Project row
  is then at most three levels deep:

  ```text
  PROJECT
    terminal0 (20 min)
    terminal1 (1 d)
    terminal2 (3 d)
  + Older than a week
  - Older than a month
      terminal5 (1 month)
  ```

What exists today for ages: the recent Project list stores order only, with no time. The Terminal Session
registry record stores the host's process creation time, not activity. The host rewrites the record when busy
changes, on snapshots, and on attach and detach, so it could also store the time of its last activity.

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
2. **Project status.** (May change with the age groups below.) Recommendation: a small mark before the name instead of words.
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
5. **Terminal Session rows.** Recommendation: one line each, indented under its Project — the live title that
   its tab shows, with the working directory in the tooltip. A mark shows busy, idle, exited, or bell. The
   Terminal Session focused in the Selected Project has the selection background, and the Project row then has
   none. Clicking a row selects its
   Project and focuses that Terminal Session in the Project. Under a Dormant Project, clicking loads the
   Project first. Each Project's Terminal Sessions can be collapsed with a chevron; collapsed state persists.
   Alternative: show only a count of Terminal Sessions per Project.
6. **Bell.** Recommendation: a bell mark on the Terminal Session row, and also on its Project row while
   collapsed. Selecting that Terminal Session clears it. No sound, no taskbar flash.
7. **Width and collapse.** Recommendation: drag the Sidebar's right edge to resize it between 160 and 480
   points. A command and a native menu item collapse it to zero width and restore it. Width and collapse
   state apply to all Windows and are saved in the shell's state file.
   Alternative: per-Window width.
8. **Age groups.** Open. Needs answers to these questions first:
   - What counts as a Project's activity, and where the shell saves it.
   - What counts as a Terminal Session's activity: commands starting and ending, typed input, or output.
   - Whether rows reorder as activity changes. Sorting by activity would swap rows each time the user switches
     between two Projects. Grouping by age with a stable order inside each group would not.
   - Where a loaded Project older than a week goes. Today loading it counts as activity, so it moves to the
     main area.
9. **Collapsed Sidebar.** Open: hidden completely with a Title Bar toggle, or a narrow rail. Animating the
   width resizes the Project surface on every frame, which costs a round trip to the Project each time.
   A prototype must show whether that stays smooth or the Project should resize once at the end.
10. **Theme.** Recommendation: new style keys in `data/colors/default.lua` for the Sidebar background, row hover,
   status marks, and the warning mark. Other themes override them. The Sidebar process already loads the theme.

## Milestones

### 1. Row layout and status

Decisions 1, 2, and 10. One-line Project rows, status marks, dim Dormant names, folder-name disambiguation,
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

## Decisions taken

The user asked the agent to decide independently. These choices shipped on 2026-10-15:

- **Header row.** The PROJECTS header and the Refresh button are gone. Refresh stays an internal recovery path.
- **Live Terminal Session rows.** Each row shows the title its tab shows, and its age. The Terminal Session
  focused in the Selected Project takes the highlight instead of its Project. Clicking a Terminal Session row
  selects its Project and focuses that Terminal Session.
- **Activity.** A Terminal Session's activity is typing, clicks, selection, a command starting or ending, and a
  title change. Output alone does not count, so a noisy log tail does not look recent. A Project's age is its
  own activity or its newest Terminal Session's, whichever is later. A Terminal Session whose activity is
  unknown shows directly under its Project.
- **Age groups.** Projects active in the last 7 days sit in the top-aligned main area. Older Projects go into
  bottom-aligned "Older than a week" and "Older than a month" groups. The bottom area takes at most 40% of the
  height and scrolls. Terminal Sessions use the same 7 and 30 day groups inside their Project. Order inside a
  group is stable (recent order), so switching between Projects never swaps rows. Group collapse state lives in
  the Sidebar's storage.
- **Width and collapse.** Drag the Sidebar's right edge between 160 and 480 points. Double-click the edge to
  reset it to 240. The Title Bar's Sidebar button and the "Toggle Project Sidebar" command hide and show it
  with a 180 ms slide. The Project area follows the slide. Width and hidden state apply to all Windows and are
  saved in the shell's state file (version 4).
- **Native Project menu.** Right-click a Project for a native menu that follows the theme's dark or light
  mode. A loaded Project offers Move to each other Window, Move to New Window, and Unload. A Dormant Project
  offers Open in New Window. Both offer Copy Path and Show in File Explorer. The inline Move rows and the hover
  Unload button are gone. Terminal Session rows have no menu.
- **Remove from list: dropped.** Each Project process owns its recent Project list and saves it again, so the
  shell cannot remove an entry without a shared list of removed Projects. Revisit it with that list.
