# Multiprocess Shell Plan

## Status

Draft for review. This plan replaces `plans/older/MULTIPROCESS_PROJECT_HOST_PLAN.md`.
The older plan swapped native Project windows. This plan composites Project surfaces
inside one shell-owned window, like Chrome.

The first target is Windows. Other platforms keep the current single-process app.

## Goal

Run each Project and each Terminal Session in its own process.
A crash or hang in one of them must not affect the others.
Anvil must restore every Anvil Window, Project, layout, and Terminal Session after a
quit, a crash, or a reboot.

## Product decisions

- One native shell process owns every Anvil Window, window controls, and the Project
  Sidebar model. A separate Sidebar process draws the Project Sidebar.
- Each Anvil Window presents one Selected Project.
- The user can open any number of Anvil Windows.
- A Project is loaded at most once. It appears in at most one Anvil Window.
- A Project can move to another Anvil Window.
- The Project Sidebar lists every recent Project and its Terminal Sessions.
- Every Anvil Window shows the same Project Sidebar list.
- Selecting a Project shown in another Anvil Window brings that window to the front.
- A Dormant Project has no Project process. Its Terminal Sessions can still run.
- Selecting a Dormant Project loads it with its saved Workspace.
- Sidebar order is stable. New Projects appear first. UI tuning comes later.

## Process model

```text
anvil.exe                        shell: native windows, input, compositing, persistence
├─ anvil.exe --sidebar           one Project Sidebar process: Lua UI, offscreen surface
├─ anvil.exe --project <path>    one per loaded Project: editor runtime, offscreen surface
└─ anvil.exe --terminal-session  one per Terminal Session: ConPTY and terminal model
```

All four modes use the same executable.

### Shell

The shell is native C. It never initializes Lua and never loads plugins or user
configuration. Every keystroke and frame passes through it, so nothing in it may
block on Lua, garbage collection, or plugin code.

It owns:

- native windows, placement, DPI, and window controls;
- input capture and routing;
- compositing of surfaces from the Sidebar and Project processes;
- the Project Sidebar model: recent Projects, order, and status;
- Sidebar and Project process lifetime;
- shell state persistence.

The shell draws only window controls, surface backgrounds, and status overlays
such as "not responding". It uses the native renderer API directly.

A shell crash closes every Anvil Window. The Sidebar process, Project processes, and
Terminal Sessions keep running. A restarted shell adopts them again.

### Sidebar process

The Sidebar process draws the Project Sidebar with the normal Lua UI, renderer,
theme, and fonts. It renders into an offscreen surface like a Project process.

One Sidebar process serves every Anvil Window. It renders one surface per window.
It shows the shell's Project Sidebar model and sends user actions back to the shell.
It owns no Project state.

A Sidebar crash or hang blanks only the sidebar. Window controls and Projects keep
working. The shell restarts the Sidebar process.

### Project process

A Project process runs the current editor runtime for one Project.
It renders into an offscreen surface instead of a native window.
It keeps its Workspace, Buffers, Panes, indexes, LSP clients, and Git state.

A Project process does not own Terminal Sessions. It attaches to them.

When the shell disappears, a Project process waits for a new shell for a bounded time.
After that timeout, it saves its Workspace and exits.

### Terminal Session process

A Terminal Session process owns one ConPTY and one Ghostty terminal model.
It runs without Lua.

It keeps running when its Project process or the shell exits.
It publishes status for the Project Sidebar: title, cwd, busy, exited, bell, and
notification counts.

A Terminal Session crash affects only that terminal.

## Crash and hang matrix

| Failure | Effect | Recovery |
| --- | --- | --- |
| Project process crash | That Project's surface goes blank | Shell shows a restart action. Terminal Sessions stay live. |
| Project process hang | That Project stops drawing | Shell detects it and offers Wait or Restart. Other Projects stay usable. |
| Sidebar process crash or hang | The sidebar blanks or freezes | Shell restarts it. Windows and Projects stay usable. |
| Shell crash | All Anvil Windows close | Next launch adopts running Sidebar, Project, and Terminal Session processes. |
| Terminal Session crash | One terminal ends | Revive it from its latest snapshot. |
| Reboot or kill-all | Everything ends | Restore windows and Workspaces. Revive terminals from snapshots. |

## Surface compositing

### Rendering

Today each window creates a D3D11 swapchain for its HWND.
In Sidebar and Project modes, the D3D11 backend renders into a shared texture instead.

- Use NT shared handles and keyed mutexes.
- Double-buffer the shared textures.
- The surface process signals each completed frame over its pipe.
- The shell draws the latest completed frame and presents it.

The software renderer uses a shared-memory surface with the same frame protocol.

If shared textures add visible latency, evaluate DirectComposition surfaces next.

### Window-bound API seam

Add one native surface backend with two implementations:

- direct: the current SDL window path;
- hosted: requests sent to the shell.

Route the window-bound `system.*` functions through that backend, including:

- cursor, text input start, text input rectangle, and IME clear;
- window title, mode, size, visibility, focus, raise, and flash;
- Title Bar hit-test regions;
- native file dialogs.

Clipboard calls stay local because the OS clipboard is process-independent.
Lua callers keep their current APIs.

### Input

The shell receives SDL input in native code. It routes each event to the Sidebar or
Selected Project surface under the pointer or holding keyboard focus.
The receiving process pushes forwarded events into its normal event queue.

Forward:

- keyboard, text input, and text editing;
- mouse motion, buttons, wheel, enter, and leave;
- focus changes;
- file and text drops;
- resize and display-scale changes.

IME composition runs in the shell window.
The Project process reports its text input rectangle so the shell places the IME.

### Window controls and Title Bar

The shell draws minimize, maximize, and close. They must work while a Project hangs.
The Project process still draws Tabs and other Title Bar content.
It reports drag and client regions. The shell uses them for hit testing.

### Resize

The shell window uses the same native frame as a direct window.
Each `WM_SIZE` resizes the swapchain and sends the new size to the Project process.
The shell waits up to 50 ms for a frame at the new size before it presents.
A timed-out wait stops further waits until a frame of the right size arrives.
During a live resize, the Project process renders without the refresh-rate throttle.

### Hidden Projects

A loaded Project that no Anvil Window shows stops rendering.
Its timers, Autosave, indexes, LSP, and Terminal Session connections continue.

## Terminal Sessions

### Attach

A Project process connects to a Terminal Session over a pipe.

1. The session sends its current state as VT sequences from the Ghostty formatter.
2. The Project process feeds that state into its own Ghostty terminal.
3. The session then streams raw PTY output.
4. The Project process sends encoded input and resize requests.

Terminal rendering in the Project process stays unchanged.

The formatter must restore scrollback and the alternate screen. Verify this first.
If it cannot, replay a bounded raw-output buffer instead.

### Busy detection

A Terminal Session is busy when its shell has child processes.
This works without shell integration.

### Quit policy

- Idle Terminal Sessions end on quit.
- When any session is busy, Anvil asks once whether to keep running sessions.
- The user can remember that answer.
- Kept sessions appear live in the Project Sidebar after the next launch.

### Snapshots and revival

Each Terminal Session writes coalesced, bounded snapshots to disk.
A revived Terminal Session:

- starts a new shell in the last cwd;
- shows the previous contents above a revival marker;
- offers to rerun the interrupted foreground command;
- never reruns that command automatically.

## Persistence

### Shell state

The shell persists, through atomic replacement:

- open Anvil Windows with placement and mode;
- the Selected Project of each Anvil Window;
- Project Sidebar order;
- the quit-policy answer.

Recent Projects stay the source for the Project Sidebar list.

### Workspace durability

Workspace saves currently happen on clean exit, Project switch, and a few events.
Add debounced saves after structural changes:

- Pane, Pane Group, and View changes;
- Terminal Session attach and detach;
- Project Path changes.

Add a periodic save as a safety net.

### Session registry

Each Terminal Session registers itself under `USERDIR`.
A record holds the session ID, Project path, PID, pipe name, and snapshot path.
Adoption checks that the PID is alive and completes a handshake before trust.

## IPC

- Use named pipes with length-prefixed, versioned, bounded messages.
- Use fixed binary headers and UTF-8 payloads.
- Reject remote clients. Open each pipe with `FILE_FLAG_FIRST_PIPE_INSTANCE`.
- Name each pipe with the server PID and random bits.
- Authenticate a child connection with `GetNamedPipeClientProcessId`. The client must
  be the process that the server started. Default pipe security already limits access
  to the current user, so the pipes need no custom DACL and no token.
- Clients open pipes with `SECURITY_IDENTIFICATION`, so a server can not impersonate them.
- Do not add a general RPC framework.

Channels:

- shell to Project process: lifecycle, surfaces, input, window requests;
- shell to Sidebar process: surfaces, input, the Project Sidebar model, user actions;
- Project process to Terminal Session: attach, output, input, resize;
- shell to Terminal Session: status for the Project Sidebar model.

## Direct mode

The current single-process app remains:

- on non-Windows platforms;
- for Lua runtime and UI tests;
- as a development fallback.

## Phases

Each phase ends with focused tests and a commit.

### Phase 0: compositing probe

Prove that a hosted Project surface feels native.

Measure and verify:

- typing latency against direct mode;
- IME composition and candidate placement;
- live resize smoothness;
- mixed-DPI moves;
- maximize, restore, and snapping;
- D3D11 and software renderers.

Stop and reconsider if typing latency or IME is visibly worse than direct mode.

Status: implemented as `anvil --shell [args]`. The shell starts one hosted process,
forwards input, and composites its frames beside a placeholder sidebar strip.

- D3D11 frames use a keyed-mutex texture shared by name.
- Software frames use a named file mapping and copy only dirty rectangles.
- The shell presents with D3D11 for both renderers.
- `ANVIL_SURFACE_LOG=<file>` logs the shell and the hosted process to one file.

`tools/run_surface_latency_probe.py` measures typing latency on a private desktop. It
injects tagged key presses into the window that receives real input. It stops the
clock when a presented frame contains the edit. Results on 2026-10-03, 240 samples
per row:

| Mode | Renderer | p50 | p90 | p99 | max |
| --- | --- | --- | --- | --- | --- |
| direct | d3d11 | 7.41 ms | 16.89 ms | 21.78 ms | 48.45 ms |
| shell | d3d11 | 7.57 ms | 16.18 ms | 20.03 ms | 24.31 ms |
| direct | software | 18.75 ms | 26.67 ms | 32.82 ms | 47.57 ms |
| shell | software | 11.17 ms | 20.35 ms | 24.11 ms | 41.03 ms |

The shell adds no measurable typing latency with D3D11. Software is faster through
the shell because the shell presents with D3D11 instead of a GDI window blit.
The clock stops when Present returns, not at scanout. A private desktop paces
Present differently from the interactive desktop.

Checked by hand: edge resize, live-resize smoothness, maximize, restore, snapping, and close.
Still to check by hand: IME composition and candidates, and mixed-DPI moves.

### Phase 1: Workspace durability

Add debounced and periodic Workspace saves.
This phase is independent and useful immediately.

### Phase 2: Terminal Session processes

Move ConPTY ownership into Terminal Session processes.
Keep the current single-process editor as the client.

Deliver attach, the session registry, busy detection, snapshots, revival, and the quit
policy. Terminals become crash-safe before the shell exists.

### Phase 3: hosted single Project

Add the native shell and the hosted surface backend.
The shell draws window controls and status overlays without Lua.
One Project must look and behave like current Anvil.

### Phase 4: several Projects and the Sidebar process

Add Dormant and loaded Projects, Project switching, hidden rendering suppression,
Project crash restart, and hang detection.
Add the shell's Project Sidebar model with Terminal Session status.
Add the Sidebar process with a minimal list UI, plus its crash restart.

### Phase 5: several Anvil Windows

Add new windows, moving a Project between windows, and bringing the owning window
to the front.

### Phase 6: shell restart and restore

Adopt the running Sidebar process, Projects, and Terminal Sessions after a shell
restart.
Restore windows, Selected Projects, and Workspaces after a full quit or reboot.

### Phase 7: sidebar presentation

Design the final Project Sidebar UI.

## Risks to verify early

- Typing latency through shared-texture compositing.
- IME behavior with a shell-owned window.
- Ghostty formatter coverage for scrollback and the alternate screen.
- GPU device loss in the shell or in a Project process.
- Memory use with many loaded Projects, plus the Sidebar process.
- Sidebar appearing after the window opens, because its process starts separately.
- Foreground activation rules when the shell raises another Anvil Window.
