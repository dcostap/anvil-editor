# Project Sidebar redesign

## Status

Started 2026-10-23. The user left the design to the agent and will test and give feedback.
Commit after each milestone.

Use the terms in `CONTEXT.md`: Project Sidebar, Selected Project, Dormant Project, Pane, Pane Group, Tab,
Terminal Session. The screenshots in this folder are the visual references.

## Goal

The Project Sidebar is the main way to switch between active Projects. Make it:

- Look modern and adapt to every Color Theme.
- Animate smoothly, also during keyboard navigation.
- Work fully with the mouse, including drag and drop from and into the Sidebar.

## Ownership does not change

The shell owns the model, the lifecycle and the selection. The Sidebar process only draws and reports user
actions. A Project changes its own Panes.

## Milestone 1: look and animation (Lua only)

Look:

- A search field below the window caption. A click focuses the Sidebar. The field shows the query, or a
  placeholder with the focus shortcut.
- A Project row has a letter badge, a bold name, a right-aligned note and a chevron. The badge color comes
  from the theme's terminal palette, so each Project keeps one color in every theme. The Window's Selected
  Project has a solid badge.
- A Project's status shows as a small dot on its badge only when it needs attention.
- A Pane Group with more Panes shows as one rounded container around its Tabs. The visible group's
  container has an accent rail.
- The active Tab of the Selected Project has a filled highlight. While the Sidebar has focus, the keyboard
  cursor has the strong fill and the active Tab a weaker fill, so both show.
- Dormant groups and older Terminal Session groups use section headers: a small uppercase label, a line,
  and a count.
- New style keys have defaults in `data/colors/default.lua`. Light themes override them.

Animation (time based, off when `config.transitions` is false):

- Rows slide to new positions when the list changes. New rows fade in.
- The cursor, the active highlight and the hover highlight glide between rows. Hover fades.
- Chevrons rotate. Scrolling eases.

Hit testing uses the final layout, so a click acts on the row that is moving to the pointer.

## Milestone 2: mouse and Pane drag inside a Project

- The pointer shows a hand over rows and the search field. Today the shell sets the arrow on each Sidebar
  motion and ignores the Sidebar's cursor reports.
- A left click acts on release, so a press can start a drag. A drag starts after a small move.
- The shell keeps sending pointer input to the Sidebar while a button that went down there stays down,
  also outside the Sidebar and outside the Window.
- Drop targets for a dragged Tab:
  - A gap between two Tabs of one Pane Group: join that group at that position.
  - A gap at a Pane Group boundary: a new Pane Group at that position.
  - The center of a Tab: join that Tab's Pane Group after it.
  - A Project row or one of its Terminal Session rows: a new Pane Group at the end of that Project.
  - A drop that changes nothing shows no target.
- The dragged Tab follows the pointer. The target shows as an insertion line, a highlighted group or a
  highlighted row. The list scrolls near its edges.
- After the drop, the Tab stays at the drop position until the new Pane report arrives, then slides.

Protocol: `PANE_REQUEST` and `PANE_ACTION` carry a Lua table as text, like the Pane report. A request names
its route: select the Project first, send to a loaded Project directly, or send to the Window's Selected
Project with the pointer position in that Project's coordinates. Bump the protocol version.

## Milestone 3: move a Pane to another Project

- The Sidebar asks the source Project to export the Pane. The source saves file-backed Buffers first. It
  refuses a Pane with a Terminal View, because a Terminal Session belongs to one Project.
- The source sends the Pane's snapshot to the target Project. The target restores it at the drop position
  and becomes the Selected Project.
- The target reports the result to the source. Only then does the source close its Pane. On failure the
  source keeps the Pane, and the user sees why.

## Milestone 4: drop files and text into the Sidebar

- The shell sends drop events over the Sidebar to the Sidebar, and the others to the Selected Project.
  When the drop moves between them, the one that it left gets a position outside its surface.
- Drop targets:
  - A gap inside a Pane Group: a new Pane in that group at that position.
  - A gap at a Pane Group boundary: a new Pane Group at that position.
  - The center of a Tab: the same as a drop into that Pane.
  - A Project row: a new Pane Group at the end of that Project.
- Each file opens in the View that handles it, such as an Editor or an Image View.

## Milestone 5: drag a Tab from the Sidebar into the work area

- Over the work area, the Selected Project shows the same drop overlay as a Title Bar Pane drag.
- A drop splits or swaps like a Title Bar Pane drag.

## Not in scope

- Reordering Projects by drag, and moving a Project to another Window by drag.
- A Tab context menu.

## Status by milestone

- Milestone 1: done. Lua tests run with transitions off; the motion tests turn them on.
  The `project-sidebar` and `project-sidebar-dark` render scenarios show the look.
- Milestones 2 to 4: done in one change, because they share the request protocol. `CONTRACT.md` describes it.
  A dragged Tab becomes a chip below and right of the pointer, so the drop mark stays visible.
  The `project-sidebar-drag` and `project-sidebar-drag-dark` render scenarios show a drag over a Pane Group.
  The shell's pointer capture and drop routing still need a check in a live Window.
- Milestone 5: done. A press on a Tab selects its Project, so a work-area drag always stays in that Project.

## Tests

- `tests/lua/ui/sidebar_view.lua` and `sidebar_navigation.lua`: clicks, drag targets and emitted requests.
- `tests/lua/ui/pane_requests.lua`: Pane requests change Panes as described.
- `tests/lua/ui/pane_transfer.lua`: a Pane moves to another Project only after the target confirms.
- `anvil:hosted-routing`: the shell's request routes.
- The `project-sidebar` render scenario for the look in light and dark themes.
