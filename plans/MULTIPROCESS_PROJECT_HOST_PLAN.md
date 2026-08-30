# Multiprocess Project Window Handoff Plan

## Status

This document replaces the earlier Win32 child-window embedding plan.

Literal HWND embedding is not a product requirement.
Do not use `SetParent()` for Project windows.
Do not place a permanent wrapper window around a Project window.
Do not stream Project pixels into another process.

The first implementation target is Windows.
The core window-handoff model must remain portable.
Other platforms keep the current behavior until they get a platform adapter.

## Goal

Let one Anvil Window contain an ordered set of independent Projects.

Each Project runs in a separate Anvil process.
Only the Selected Project window is visible for that Anvil Window.
Switching Projects replaces the visible top-level window at the same placement.

A user can open several Anvil Windows.
Each Anvil Window has its own Project set and Selected Project.
Each visible Anvil Window has one taskbar and Alt-Tab entry.

## Product contract

### Anvil Window

An Anvil Window is one logical application window.
It owns an ordered set of open Projects.

The Selected Project supplies the visible native window.
The native HWND can change when the Selected Project changes.
Users must not perceive that native handoff.

Anvil can show several Anvil Windows at the same time.
Each one has an independent Project set.

### Project process

Each Project runs in one separate Anvil process.
That process keeps the current one-Project runtime model.

Each process owns its own:

- Root Project;
- Workspace;
- Panes and Tabs;
- Buffers and Editors;
- terminals;
- LSP clients;
- tree-sitter indexes;
- Git state;
- Project Paths;
- `.anvil_project.lua` state;
- recovery state;
- plugin state;
- normal top-level native window.

Do not move Project models into the manager process.
Do not share Lua runtimes between Projects.

### Selected Project

Each Anvil Window has one Selected Project.

The Selected Project window is visible and receives input.
Other Project windows in that Anvil Window stay hidden.

A hidden Project process continues its background work.
It does not render normal frames while hidden.

### Project Sidebar

The Project Sidebar belongs to the Anvil product, not one Project model.

The selected child draws the sidebar inside its normal interface.
The manager supplies the Project list and actions.

The sidebar always starts hidden when an Anvil Window has a Project.
Do not restore its previous visibility.

When hidden, the interface stays visually identical to current Anvil.
When visible, it uses the left side of the selected Project interface.

The first sidebar includes:

- ordered Project names;
- the Selected Project marker;
- starting and crashed markers;
- an add action;
- one close action per Project.

Pane and Tab details remain deferred.

### Empty Anvil Window

Closing the final Project keeps its Anvil Window open.

The manager shows a small empty shell window for that logical Anvil Window.
The empty shell shows the Project Sidebar and an add action.

The empty shell exists only while the Anvil Window has no selected child.
It is not a permanent wrapper around Project windows.

### Project opening

Anvil exposes these actions:

- **Open Project in Current Window**;
- **Open Project in New Window**.

Current Window adds a Project to the caller's Anvil Window.
New Window creates another Anvil Window and starts the Project there.

If the Project exists in the current Anvil Window, Anvil selects it.
If it exists in another Anvil Window, Anvil raises that window.

Anvil never opens one normalized Project twice.

### Launch behavior

A normal `anvil.exe` launch requests one Anvil Window.

A Project path launch opens that Project in a new Anvil Window.
A file path launch uses current Project-selection behavior in a new Anvil Window.

A bare launch claims one saved Project set.
Further bare launches claim other saved sets.

An open set cannot be claimed twice.
If no saved set remains, a bare launch creates an empty Anvil Window.

**New Anvil Window** always creates an empty Anvil Window.
Its Project Sidebar starts visible.

### Window closing

Closing the visible Title Bar closes the complete Anvil Window.

The manager requests close approval from every Project first.
No Project exits during the approval phase.

If one Project cancels, all Projects remain open.
If all Projects approve, the manager commits the close.

Closing one Project uses the Project Sidebar action.
The manager selects that Project before it can show a close prompt.

## Required architecture

## Logical window groups

The manager owns logical window-group records.
Each record represents one Anvil Window.

A group record contains:

- a stable group identity;
- ordered Project records;
- Selected Project identity;
- current placement and mode;
- sidebar visibility for the current run;
- close transaction state;
- restore claim state.

A group does not need one permanent native window.

When a Project is selected, its normal top-level window represents the group.
When the group is empty, the manager's empty shell represents it.

## Process layout

One manager process coordinates all Anvil Windows.
Each open Project has one child process.

```text
anvil.exe manager
├─ logical Anvil Window A
│  ├─ Project process A1: visible top-level window
│  └─ Project process A2: hidden top-level window
├─ logical Anvil Window B
│  └─ Project process B1: visible top-level window
└─ empty Anvil Window C
   └─ manager-owned empty shell window
```

The manager does not initialize the editor Lua runtime.
It owns launch routing, process records, persistence, and handoff coordination.

## Why window handoff

Window handoff preserves the existing editor window.
It avoids cross-process child-window focus and resize rules.

The selected process keeps direct ownership of:

- native input;
- SDL focus;
- D3D presentation;
- DPI transitions;
- native dialogs;
- drag and drop;
- Title Bar behavior;
- live resize.

No Project window is embedded inside another window.
No process captures another process's rendered pixels.

## Handoff sequence

A ready Project switch uses this order:

1. block another selection request;
2. save the current group placement;
3. send `MANAGER_PREPARE_SHOW` to the target;
4. let the target apply the saved bounds and mode while hidden;
5. receive `PROJECT_PREPARED_SHOW`;
6. send `MANAGER_DEACTIVATE` to the old Project;
7. hide the old Project and its Project Tool Windows;
8. send `MANAGER_ACTIVATE` to the target;
9. show, raise, and focus the target window;
10. request one complete layout and redraw;
11. update the Selected Project record;
12. publish the new sidebar snapshot;
13. unblock selection requests.

The target must not use a different visible size during handoff.
The old and target windows must not remain visible together.

A short internal overlap during a no-activate preparation step is acceptable only if users cannot see it.

## Starting Project handoff

A new Project can take time to start.

The sidebar marks it as starting.
The current Selected Project remains visible while startup continues.

The manager selects the new Project only after `PROJECT_READY`.
If startup fails, the prior Project remains selected.

The failed row offers a restart action.

## Native window rules

Each Project creates an ordinary top-level window.
Do not add `WS_CHILD`.
Do not call `SetParent()`.

A hidden Project window must not appear in the taskbar or Alt-Tab list.
A selected Project window must appear exactly once.

On Windows, use normal hide and show operations first.
Change extended window styles only if hidden windows still leak into shell UI.

Do not create a taskbar proxy unless tests prove it necessary.
Do not maintain a transparent wrapper window behind selected Projects.

## Placement ownership

The manager owns logical Anvil Window placement.

The visible child reports settled bounds and mode changes.
The manager stores them in the group record.

Before activation, a target child receives the group placement.
The child applies that placement while hidden.

Hidden children do not save outer placement as independent App State.
They keep their internal Workspace state.

The selected child can process live resize normally.
No cross-process resize forwarding is required.

## Focus and input

The selected child is an ordinary foreground top-level window.
Windows and SDL handle its normal input path.

Do not forward ordinary keyboard, text, mouse, wheel, IME, or clipboard events through the manager.

The manager requests foreground activation during handoff.
The target child performs its own final focus operation.

Use `AllowSetForegroundWindow()` before activation when Windows requires it.
Use `AttachThreadInput()` only as a bounded fallback.
Always detach input queues immediately.

## Title Bar behavior

The selected child draws and owns the current Title Bar.

Minimize, maximize, drag, resize, and system-menu operations stay local.
They act on the visible Project top-level window.

The close action is different.
It requests a complete logical Anvil Window close from the manager.

The manager does not duplicate frame hit testing.

## Manager and child startup

The same `anvil.exe` binary supports manager and Project modes.

Example internal launch:

```text
anvil.exe --project-child \
  --manager-pipe <pipe-name> \
  --window-group-id <group-id> \
  --launch-token <random-token> \
  <project-or-file-path>
```

These arguments remain internal.
The child removes them before Lua receives `ARGS`.

Project mode bypasses global launch forwarding.
It must not compete for the manager mutex.

## Manager protocol

Use one private duplex named pipe per manager process.

The protocol must be:

- versioned;
- length-prefixed;
- bounded;
- asynchronous;
- authenticated with a random launch token;
- tied to the expected child PID;
- safe when a child stops responding.

Use fixed binary headers and UTF-8 payloads.
Do not add a general RPC framework.

Suggested header:

```c
typedef struct AnvilManagerMessageHeader {
  uint32_t magic;
  uint16_t version;
  uint16_t type;
  uint32_t payload_size;
  uint64_t request_id;
  uint64_t window_group_id;
  uint32_t child_pid;
} AnvilManagerMessageHeader;
```

Set a small payload limit.
Reject unknown versions and oversized payloads.

### Project-to-manager messages

The first complete version needs:

- `PROJECT_READY`;
- `PROJECT_IDENTITY`;
- `PROJECT_PREPARED_SHOW`;
- `PROJECT_ACTIVATED`;
- `PROJECT_DEACTIVATED`;
- `PROJECT_PLACEMENT_CHANGED`;
- `PROJECT_REQUEST_SELECT`;
- `PROJECT_REQUEST_TOGGLE_SIDEBAR`;
- `PROJECT_REQUEST_OPEN_CURRENT`;
- `PROJECT_REQUEST_OPEN_NEW`;
- `PROJECT_REQUEST_CLOSE_PROJECT`;
- `PROJECT_REQUEST_CLOSE_WINDOW`;
- `PROJECT_CLOSE_PREPARED`;
- `PROJECT_CLOSE_CANCELED`;
- `PROJECT_MODAL_BEGIN`;
- `PROJECT_MODAL_END`;
- `PROJECT_TOOL_WINDOW_OPENED`;
- `PROJECT_TOOL_WINDOW_CLOSED`.

### Manager-to-Project messages

The first complete version needs:

- `MANAGER_PROJECT_LIST`;
- `MANAGER_PREPARE_SHOW`;
- `MANAGER_ACTIVATE`;
- `MANAGER_DEACTIVATE`;
- `MANAGER_SET_SIDEBAR_VISIBLE`;
- `MANAGER_PREPARE_CLOSE`;
- `MANAGER_ABORT_CLOSE`;
- `MANAGER_COMMIT_CLOSE`;
- `MANAGER_OPEN_FILE`;
- `MANAGER_FOCUS`;
- `MANAGER_SHUTDOWN`.

## Narrow child API

Add a small native API for first-party Lua code.

Potential surface:

```lua
system.is_project_child()
system.window_group_id()
system.manager_request(action, payload)
system.project_is_selected()
```

Do not expose pipe handles or HWND values to plugins.
Do not create a second plugin IPC framework.

## Project Sidebar implementation

The selected child renders the Project Sidebar.
This keeps theme, scaling, input, and animation inside the existing UI system.

Add one first-party module:

```text
data/core/project_sidebar.lua
```

The module consumes manager-owned snapshots.
It does not discover or own Project processes.

The manager remains authoritative for:

- Project order;
- Selected Project;
- starting and crashed state;
- duplicate identity;
- sidebar actions.

The selected child's theme supplies sidebar colors.
Do not add native sidebar rendering while a Project is selected.

The empty manager shell can use small native controls.
It needs only an add action and empty Project list.

## Sidebar commands

Add these commands:

```text
core:toggle_project_sidebar
core:open_project_in_current_window
core:open_project_in_new_window
core:close_selected_project
```

Commands run in the selected child.
They send manager requests through the native bridge.

Do not test exact keyboard shortcuts.

## Folder selection

The add action opens a native folder picker.

When a Project child is selected, that child can own the dialog.
The child reports modal begin and end state.

When the Anvil Window is empty, the manager shell owns the dialog.

The chosen path opens in the same logical Anvil Window.

## Project identity

The manager owns one normalized identity per Project process.

On Windows, comparison must:

- normalize separators;
- resolve absolute paths;
- normalize volume spelling;
- remove redundant trailing separators;
- compare case without case sensitivity.

The child-reported Root Project becomes authoritative after startup.

If it matches another live Project, keep the existing Project.
Close the duplicate child and raise the existing Anvil Window.

## Launch routing and single instance

The manager owns the global single-instance mutex.
Later public launches send complete launch intents to the manager and exit.

A launch intent represents:

- bare launch;
- Project path launch;
- file path launch;
- new empty Anvil Window;
- command-originated new Anvil Window.

Extend the existing native launch transport.
Do not add another global service.

Project children bypass manager forwarding.
The Lua IPC plugin also skips duplicate-instance routing in Project mode.
Other plugin IPC features can remain available.

## Several Anvil Windows

The manager can own several logical window groups.

Each non-empty group has one visible Selected Project window.
Therefore, several Anvil Windows can be visible together.

Opening in New Window creates a new group.
Opening in Current Window targets the caller's group identity.

The manager raises the correct visible child when a duplicate Project already exists.

## Hidden Project behavior

A hidden Project remains alive.

On `MANAGER_DEACTIVATE`, it must:

- stop normal frame emission;
- stop caret animation frames;
- hide Project Tool Windows;
- finish the native hide operation;
- keep timers and background services active;
- keep autosave active;
- keep terminals active;
- keep LSP and indexes active.

On `MANAGER_ACTIVATE`, it must:

- apply the group placement while hidden;
- refresh display scale;
- show its normal top-level window;
- request complete layout and redraw;
- restore text input focus;
- run the existing reactivation repaint burst.

Do not unload renderer resources during ordinary switches.

## Project Tool Windows and dialogs

Project Tool Windows remain owned top-level windows.
They are visible only while their Project is selected.

Native dialogs belong to the selected Project window.
The manager blocks Project switching during a modal dialog.

Do not move dialogs between processes.

## Workspace and App State

Each child keeps its existing per-Project Workspace storage.
No Workspace format change is required.

The manager owns:

- logical Anvil Window bounds and mode;
- Project order;
- Selected Project;
- saved Anvil Window sets;
- restore claims;
- recent Projects.

Project children must not overwrite manager-owned window placement.

Find and replace history can remain child-local initially.

## Persistence

Add one manager-owned state file under `USERDIR`.

Prefer a bounded, versioned binary format with UTF-8 strings.
Do not execute Lua in the manager.
Do not add a JSON dependency only for this file.

The file stores:

- format version;
- logical window identity;
- ordered Project paths;
- Selected Project path;
- bounds and mode;
- last active time.

Write through a temporary file and atomic replacement.

Persist stable mutations immediately.
Coalesce repeated placement writes.

## Restore claiming

Saved Anvil Window sets start unclaimed.

Each bare launch claims the newest unclaimed set.
An open set remains claimed until its Anvil Window closes.

A closed set can be claimed again in the same manager process.
If no set remains, create an empty Anvil Window.

Restore the Selected Project first.
Start hidden Projects one at a time after that Project becomes ready.

## Child lifetime

Start children with `CreateProcessW()`.
Use explicit Windows argument quoting.

Keep each process handle until exit.
Place all children in a kill-on-close Job Object.

A Project crash does not close its Anvil Window.

If the Selected Project crashes:

1. mark it crashed;
2. select another ready Project;
3. show the empty shell if none remains;
4. keep a restart action in the sidebar.

## Close protocol

### One Project close

The manager selects the target Project first.

Then:

1. send `MANAGER_PREPARE_CLOSE` with a transaction token;
2. let the child show its normal confirmation UI;
3. receive prepared or canceled;
4. send `MANAGER_COMMIT_CLOSE` after approval;
5. wait for process exit;
6. remove the Project record;
7. persist the group.

### Complete Anvil Window close

Use a two-phase transaction.

Phase one asks every child to prepare.
No child exits in phase one.

If one child cancels:

1. send `MANAGER_ABORT_CLOSE` to prepared children;
2. keep every process alive;
3. restore the prior Selected Project;
4. end the transaction.

If all children approve:

1. send `MANAGER_COMMIT_CLOSE` to all children;
2. wait for graceful exits;
3. destroy the empty shell if present;
4. close the logical group;
5. persist the closed set.

Offer force close only after a bounded timeout.
Never force close automatically.

## Diagnostics

Add quiet diagnostics for manager transitions.

Include available identities:

- manager PID;
- window-group ID;
- child PID;
- Project path;
- child HWND on Windows;
- request ID;
- transition reason.

Useful events include:

- group created;
- child started;
- Project ready;
- handoff prepared;
- old Project hidden;
- target Project shown;
- focus result;
- placement copied;
- close prepared;
- close canceled;
- child crashed;
- saved set restored;
- duplicate Project redirected.

Use this opt-in diagnostics path:

```text
ANVIL_WINDOW_MANAGER_DIAGNOSTICS_FILE=<path>
```

Never log launch tokens.

## Security

Validate all child connections.

Check:

- expected child PID;
- process handle ownership;
- launch token;
- protocol version;
- message size;
- valid UTF-8 strings;
- absolute Project paths;
- native window ownership on Windows.

Use `GetWindowThreadProcessId()` before controlling a reported HWND.

## Code layout

Suggested native files:

```text
src/window_manager.c
src/window_manager.h
src/window_manager_protocol.c
src/window_manager_protocol.h
src/win32_window_handoff.c
src/win32_window_handoff.h
src/api/window_manager.c
```

Responsibilities:

- `window_manager`: logical groups, selection, duplicates, and close state;
- `window_manager_protocol`: bounded message encoding and decoding;
- `win32_window_handoff`: process launch, visibility, focus, placement, and empty shell;
- `api/window_manager`: narrow child bridge.

Keep group logic free of Win32 calls.

Expected native edits:

- `src/main.c`;
- `src/api/system.c`;
- `src/win32_single_instance.c`;
- `src/win32_single_instance.h`;
- `src/meson.build`.

Do not change renderer backends for window handoff.
Do not change `src/api/renwindow.c` for cross-process parenting.

Expected Lua edits:

- `data/core/init.lua`;
- `data/core/titlebar.lua`;
- `data/core/commands/core.lua`;
- `data/core/emptyview.lua`;
- `data/core/rootpanel.lua`;
- `data/plugins/fuzzy_searcher/init.lua`;
- `data/plugins/ipc.lua`;
- `data/plugins/workspace.lua`;
- `data/plugins/anvil_defaults.lua`;
- new `data/core/project_sidebar.lua`.

## Test strategy

Use four stable seams:

1. logical window-group transitions;
2. bounded protocol parsing;
3. child command routing;
4. actual top-level window handoff.

Do not test private helper calls.
Do not test exact shortcuts, colors, or sidebar dimensions.

## Native tests

Add one focused target:

```text
anvil:window-manager
```

Cover:

- Project insertion order;
- one Selected Project per group;
- several independent groups;
- duplicate path rejection;
- selection after removal;
- crash fallback;
- saved-set claim order;
- protocol truncation;
- oversized payload rejection;
- wrong version rejection;
- token mismatch rejection;
- close approval;
- close cancellation.

## Lua tests

Cover:

- Project child mode detection;
- Current Window routing;
- New Window routing;
- sidebar snapshot rendering;
- hidden render suppression;
- activation redraw;
- IPC duplicate-routing bypass;
- child placement-save suppression;
- Title Bar close routing.

Use public commands and window APIs.

## Windows GUI smoke test

Add:

```text
tests/gui/smoke/project-window-handoff-test.ps1
```

The test must:

1. start Anvil with an isolated `USERDIR`;
2. wait for the manager and first Project process;
3. add a second Project;
4. verify separate child PIDs;
5. verify exactly one visible Project top-level window;
6. record the visible window bounds;
7. switch Projects;
8. verify the old window is hidden;
9. verify the target uses the same bounds and mode;
10. type and save text in the target;
11. switch back repeatedly;
12. verify focus after each switch;
13. verify one taskbar and Alt-Tab entry for the group;
14. close the Anvil Window;
15. verify all group children exit.

Do not use screenshot equality as the main assertion.

## Manual verification

Manual checks remain required for:

- mixed-DPI handoff;
- IME composition;
- taskbar transition quality;
- Alt-Tab behavior;
- maximize and restore;
- native folder dialogs;
- Project Tool Window visibility;
- child crash recovery;
- several active terminals;
- rapid repeated switching.

## Red-green implementation phases

## Phase 0: Top-level window-handoff proof

### Purpose

Prove that two independent normal Project windows can represent one Anvil Window without visible seams.

Do not build the sidebar or persistence yet.

### Red test

Add a Windows probe that expects:

- one manager process;
- two Project child processes;
- one visible Project top-level window;
- one hidden Project top-level window;
- stable bounds after a switch;
- working text input after a switch.

It must fail before implementation.

### Implementation

- add temporary manager mode;
- launch two ordinary Project children;
- start the second child hidden;
- bypass global forwarding in both children;
- hand off one saved placement;
- hide the old child;
- show and focus the target;
- suppress hidden rendering.

Do not call `SetParent()`.
Do not add a wrapper around non-empty groups.
Do not change D3D or software renderer code.

### Green evidence

Run the probe with D3D11 and software rendering.

Repeat handoff at least twenty times.
Verify typing and file saving after every switch.

### Exit gate

Continue only when all conditions pass:

- no visible handoff flash;
- no duplicate taskbar entry;
- no duplicate Alt-Tab entry;
- reliable keyboard and mouse focus;
- reliable IME after manual review;
- unchanged live resize behavior;
- unchanged maximize and restore;
- correct mixed-DPI placement;
- hidden child stops rendering;
- hidden child background work continues.

If this gate fails, stop.
Reconsider either separate Project processes or one logical Anvil Window.
Do not mask failures with overlays, colors, proxy windows, or captured pixels.

## Phase 1: Manager model and protocol

Add native red tests for groups, selection, duplicates, crashes, and bounded protocol parsing.

Implement the platform-neutral model, named-pipe protocol, process records, Job Object, and diagnostics.

Run only `anvil:window-manager`.

## Phase 2: Transparent one-Project management

Keep one normal Project window visually identical to current Anvil.

Add manager launch routing, placement ownership, child mode, and close routing.

Run focused native and Lua tests.

## Phase 3: Project switching

Add activation, deactivation, placement handoff, hidden rendering suppression, and crash fallback.

Run the focused GUI handoff path.

## Phase 4: Project Sidebar

Add manager snapshots and child-rendered sidebar UI.
Add the native empty shell for groups with no Projects.

Test rows, selection, add, close, hidden-on-launch, and empty behavior.

## Phase 5: Project opening routes

Update Current Window, New Window, public launches, fuzzy actions, Empty View, and directory drops.

Remove stale same-window restart behavior.

## Phase 6: Transactional close

Add one-Project and complete-window two-phase close flows.

Verify cancellation keeps every process alive.

## Phase 7: Persistence and restore

Add atomic manager state, restore claims, bounds, Selected Project, and ordered background startup.

Run focused restart scenarios.

## Phase 8: Tool windows and polish

Add modal switching blocks, Project Tool Window visibility, crash restart, and final diagnostics.

Run the complete Windows GUI smoke test.
Run manual DPI and IME checks.

## Build and finalization

This feature changes native files.
Use the normal dev portable update workflow after each stable native slice.

```text
cmd.exe //d //s //c "call C:\Projects\c_projects\anvil-editor\update-anvil-dev-build.bat"
```

Use focused tests during each phase.
Run the complete Anvil suite only after the feature crosses all boundaries.

## Development switch

Keep one temporary switch during implementation:

```text
ANVIL_WINDOW_MANAGER=0
```

This starts the current direct editor process.
Remove the switch after the final release gate passes.

## Release gate

The first release is complete only when:

- one Project looks identical to current Anvil;
- several Projects use separate processes;
- one Project is visible per Anvil Window;
- several Anvil Windows can be visible together;
- hidden Projects continue background work;
- hidden Projects stop rendering;
- switching preserves placement, focus, and IME;
- each Anvil Window has one taskbar and Alt-Tab entry;
- live resize remains native and smooth;
- mixed-DPI movement works;
- the sidebar starts hidden;
- the sidebar can add, select, and close Projects;
- duplicate Projects are raised instead of reopened;
- canceled close keeps every Project alive;
- closing the final Project leaves an empty Anvil Window;
- saved Project sets restore correctly;
- Project crashes do not close other Projects;
- manager crashes do not leave child processes;
- non-Windows builds keep current behavior;
- focused tests pass;
- the Anvil suite passes;
- the Windows GUI smoke test passes.

## First code target

Start with Phase 0 only.

The first result must answer this question:

> Can ordinary top-level Project windows switch as one logical Anvil Window without visible or input seams?

A green result validates the simpler architecture.
Only then continue with the manager model and Project Sidebar.
