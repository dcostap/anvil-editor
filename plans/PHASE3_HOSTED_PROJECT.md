# Phase 3: hosted single Project

This plan follows [Phase 2](PHASE2_TERMINAL_SESSIONS.md) and
[the multiprocess shell plan](MULTIPROCESS_SHELL_PLAN.md).
Read both before implementation.

Status: draft for review. No Phase 3 implementation is authorized by this document.
Phase 2 Milestones 1 to 4 are complete.

## Goal

Present one Selected Project in a native Anvil Window.
The native shell owns the visible window, input, and presentation.
The Project process owns the editor runtime and its offscreen surface.
Window controls and status overlays must work without the Project's Lua loop.

Keep current editing, Workspace, terminal, and quit behavior.
Keep direct mode for non-Windows systems, Lua tests, and development.
Do not make hosted mode the default until the acceptance checks pass.

## Scope

Phase 3 delivers:

- One Anvil Window and one Project process per shell launch.
- A native Project Sidebar placeholder, not a Sidebar process or Project list.
- A complete direct/hosted window backend.
- Native window controls and local lifecycle status overlays.
- Input, IME, focus, capture, resize, and DPI routing.
- Shell-owned native file dialogs.
- Bounded launch, transport, surface, and close work.

Phase 3 does not deliver:

- Several loaded Projects or the Sidebar process: Phase 4.
- General hang detection, Project restart, or Sidebar recovery: Phase 4.
- Shared ownership of several Anvil Windows or moving Projects: Phase 5.
- Shell adoption, window restoration, or a Project registry: Phase 6.
- Final Project Sidebar presentation: Phase 7.

Existing New Window commands must not open a second visible window inside a Project process.
For this phase, they start another independent shell with one Project.
Phase 5 replaces this launch boundary with shared shell ownership.
This limited behavior needs approval with this plan.

## Starting point

The Phase 0 probe already provides `anvil --shell [args]`:

- `src/anvil_shell.c`: native SDL window, D3D11 presentation, process launch, and event routing.
- `src/hosted_surface.c/.h`: hidden SDL window, forwarded events, and surface publication.
- `src/surface_protocol.c/.h`: bounded surface messages and frame descriptions.
- `src/ipc_pipe.c/.h`: shared overlapped transport.
- `src/api/system.c`: several hosted branches for window-bound functions.
- `src/rencache.c` and native renderer backends: existing surface publication paths.
- `tools/run_surface_latency_probe.py`: private-desktop direct/hosted latency comparison.

D3D11 publication uses shared textures and keyed mutexes.
Software publication uses named memory and dirty rectangles.
The shell presents both through D3D11.
Retain these paths unless measurements show a fault.

The probe is not the finished backend:

- Lua still draws window controls in the Project surface.
- File dialogs need a visible shell-owned parent.
- Window APIs still contain separate hosted branches.
- A repeated close request can terminate the Project without explicit approval.
- Project exit currently ends the shell instead of retaining a failure overlay.
- Shell job cleanup currently kills the Project when the shell dies.

IME candidate placement and real mixed-DPI moves remain open Phase 0 checks.
Do not describe synthetic event tests as proof of these OS behaviors.

## Ownership and launch

```text
anvil.exe --shell [Project/file arguments]
  native Anvil Window, controls, placeholder, overlays, compositor
  |
  +-- anvil.exe --project <path> <private surface connection arguments>
        editor Lua, plugins, Workspace, Buffers, Panes, renderer
        |
        +-- existing Terminal Session processes
```

All modes use the same executable.
Dispatch shell and Project modes explicitly in `src/main.c`.
The shell must return before Lua initialization and plugin/config loading.
Only the Project process loads user configuration.

Use the existing worker launch and pipe helpers.
Authenticate the launched PID on both pipe ends.
Reject remote clients, protocol mismatch, malformed strings, and excess payloads.
Keep process handles to prevent PID reuse from changing identity checks.
Do not introduce general RPC or another process framework.

A Project process must not die merely because the shell's job handle closes.
Remove kill-on-shell-close ownership for that child.
On shell loss, preserve Terminal Sessions, wait for the documented bounded recovery period,
then save the Workspace, detach terminals, and exit without a hidden quit prompt.
Phase 6 supplies adoption; Phase 3 does not invent a replacement adoption protocol.
If the Lua loop cannot save, retain the last durable Workspace and report the loss risk.
Do not extend the native exit deadline while waiting for a stalled Lua loop.

Same-window Project switch saves and unloads the old Project before launching its replacement.
Restart launches a replacement Project runtime in the same shell.
Both paths detach Terminal Sessions and bypass the normal-quit policy.
Keep only one Project connected at a time.
Do not retry by launching another Project while the previous process might still be live.

## Native window backend

Create a small native backend, provisionally `src/window_backend.c/.h`.
Use explicit direct and hosted implementations behind the same operations.
Move existing hosted branches into this seam; do not leave parallel copies or aliases.
Lua callers keep their public `system.*` APIs.

Audit every operation that currently reads or changes an SDL window:

| Operation | Direct mode | Hosted mode |
| --- | --- | --- |
| Bounds, mode, scale, refresh, focus | Local window | Shell's last authoritative configuration |
| Title, mode, bounds, border, show/hide | Local window | Validated shell request |
| Raise and flash | Local window | Visible shell window |
| Cursor and pointer capture | Local window | Shell-owned pointer target |
| Text input, rectangle, IME clear | Local window | Shell-owned text service |
| Title Bar hit regions | Local window | Project regions plus shell-owned exclusions |
| File, save, directory dialogs | Local parent | Shell parent and asynchronous result |
| Clipboard | OS clipboard | OS clipboard; no pipe hop |

Keep the hidden Project SDL window as an event/render implementation detail.
Never show, raise, flash, or parent a dialog to it.
Use a cached configuration for getters; never wait for a pipe response in Lua's UI loop.
Bound outbound queues. Coalesce replaceable configuration and pointer-motion messages.
Never silently drop key, text, button, or lifecycle messages.
Fail the connection visibly if a required message cannot be retained.

File dialogs use bounded request IDs and explicit success, cancel, and failure results.
Preserve current callback semantics and multi-file/filter results.
Run modal OS work outside the shell's event/present loop.
Retain dialog state independently of a cancelled Project connection.
Discard late results for old connections and release their memory.
Do not add a general callback registry beyond these outstanding requests.

## Geometry and input

Use one surface rectangle as the routing authority.
Define packet coordinates in physical client pixels.
Keep display scale separate from coordinates; convert exactly once at each boundary.
Subtract the Project surface origin for pointer events.
Add that origin for IME rectangles and Title Bar regions.
Validate all rectangles against the current configuration.

The shell owns keyboard focus, OS capture, and text composition.
Route normal editing events to the connected Selected Project.
Keep native controls and overlay actions out of the Project event queue.
The placeholder takes no editing focus.

Forward keyboard, text input, text editing, mouse buttons, motion, wheel,
enter/leave, focus, file/text drops, size, and scale changes.
Copy UTF-8 and drop contents into owned payloads; never transmit process pointers.
Keep key and text events ordered and distinct.
Do not change user-configurable command bindings.

A pressed pointer keeps its target until release, even outside the surface.
Send leave and clear hover when the pointer crosses a surface boundary.
On focus loss or connection loss, release capture and clear pressed-state bookkeeping.
Clear composition on target change, Project replacement, and window focus loss.
No new input may reach an old connection after replacement.

The Project reports the text-input rectangle and cursor offset.
The shell applies them to the visible window and returns text/editing events.
Clip candidate placement to valid geometry without changing the editor's caret position.
Native dialogs and overlays must restore the correct focus and text-input state after dismissal.

Resize and DPI changes publish one authoritative configuration generation.
Frames identify the configuration they used, not only their publication sequence.
Reject old-connection frames and validate dimensions, stride, mapping size, and texture ownership.
Never copy a partially written frame.
Retain the latest complete frame while a new-size frame is pending.
Normal frame acquisition must not block window controls on a Project-owned mutex.
If the surface is busy, retain the private frame and try a later publication.

Keep the existing bounded live-resize wait and its timeout suppression.
Do not add waits per frame when a Project has stopped rendering.
Preserve native maximize, restore, snapping, drag, and resize behavior.
Cancel stale IME and hit-test geometry when scale changes.

## Native controls and overlays

The shell draws minimize, maximize/restore, and close through native renderer APIs.
It owns their hit regions, hover, press, pointer capture, and actions.
No control action calls Lua or waits for a Project frame.
Use native fonts or bundled assets without a Lua renderer wrapper.
The shell may accept bounded appearance data, but never loads themes or executes configuration.
It has its own usable appearance before the first Project frame.

The Project still draws Tabs and other Title Bar content.
The shell reports its reserved control rectangle.
Hosted Title Bar layout leaves that rectangle empty and removes Lua control hit targets.
Direct Title Bar drawing remains unchanged.
Native controls override Project drag/client regions.
Clamp reported hit regions so a plugin cannot cover native controls.

Use a small lifecycle state machine, not an overlay plugin:

- Starting: waiting for the authenticated Project and first complete frame.
- Ready: presenting the connected Project.
- Closing: a close operation awaits a Project decision or completion.
- Failed: launch, protocol, process, or surface failure.

Starting and Failed draw native status text and an available Close action.
Keep the last complete frame when it is safe; otherwise draw a native background.
Close timeout offers Wait or explicit forced close with an unsaved-data warning.
A quiet or minimized Project is not a hung Project.
Do not use missing frames alone as a health signal.
Phase 4 adds general health probes and restart actions.

Normal Close asks the Project to run its existing unsaved-buffer and terminal policy.
Report pending, cancelled, and accepted decisions explicitly.
Cancel returns the shell to Ready and permits a later close attempt.
Repeated Close requests cannot bypass confirmation.
A dialog awaiting user choice is not a close failure.
On acceptance, let Project shutdown drain its existing shared Terminal CLOSE budget.
Never hold the shell event loop while waiting for the process.
Force closes affect only the Project; Terminal Session processes remain independent.

On shell loss, the Project saves and detaches after its bounded wait.
On Project crash, the shell remains responsive and shows Failed.
Do not automatically rerun terminal commands or create replacement shells.

GPU loss releases obsolete textures and requests a fresh surface generation.
Allow a bounded software-publication fallback when the Project's D3D path fails.
If shell presentation cannot recover, log the failure and close cleanly without killing terminals.
Do not create an unbounded device-recreation loop.

## Milestones

Each milestone starts with a targeted failing test or reproducible native scenario.
Run only its focused checks, record evidence, and commit the complete milestone.
Run the portable updater after native changes, with advance warning about Terminal Sessions.

### Milestone 1: launch and backend seam

- Add explicit Project mode and preserve direct mode.
- Consolidate window-bound native operations behind the direct/hosted backend.
- Remove kill-on-shell-close ownership of the Project.
- Preserve same-window switch, restart, and the limited independent New Window launch.
- Test startup errors, authenticated connection, authoritative getters, and hidden-window ownership.
- Test shell loss followed by bounded Project save/detach and live Terminal Sessions.

### Milestone 2: native controls and placeholder

- Draw and handle shell controls without Lua.
- Reserve their geometry in hosted Title Bar layout.
- Add the native Project Sidebar placeholder and initial lifecycle overlays.
- Suspend the owned Project; verify minimize, maximize/restore, drag, and resize still complete.
- Resume it and verify Tabs and editing still work without duplicate control actions.

### Milestone 3: input, IME, focus, and DPI

- Complete coordinate, text payload, capture, focus, and drop routing.
- Add configuration generations and reject stale geometry/frames.
- Test text edits, composition, selection drag across boundaries, wheel, focus loss, and complete text drops.
- Test fractional scales, nonzero origins, resize, and target replacement.
- Complete real IME candidate and mixed-DPI verification, or report the unavailable gate explicitly.
- Compare direct and hosted presented-input latency on both renderers.

### Milestone 4: dialogs and accepted close

- Parent native dialogs to the shell and return asynchronous results.
- Preserve unsaved-buffer confirmation and Terminal Keep/End/Cancel behavior.
- Remove repeated-close implicit termination.
- Test dialog success/cancel/failure, cancelled quit followed by another quit, and explicit forced close.
- Test that Project restart/switch still detaches terminals without asking the normal-quit question.

### Milestone 5: failure handling and acceptance

- Complete bounded startup, transport, frame, device, and close failure handling.
- Keep native controls usable after Project exit and while operations wait.
- Test broken pipes, malformed packets, stalled frame locks, stale frames, and failed texture access.
- Test shutdown with pending dialog work and blocked transport workers.
- Run the focused acceptance matrix; report every skipped or manual gate.
- Keep `--shell` opt-in until review accepts the result.

## Tests and measurement

Follow [the render gate rules](../tools/RENDER_PERF_GATE.md).
Use the existing private-desktop launcher:
`tools/run_anvil_hidden_desktop.ps1`, through `invoke_hidden` where applicable.
Extend existing scenario tools; do not create another desktop/window runner.

All native checks use copied app data, isolated USERDIR, owned process handles,
and separate run folders. Never use the daily portable app or its user state.
Do not find, focus, move, close, suspend, or inspect the user's windows.

Use state, protocol traces, process handles, and presentation acknowledgements as evidence.
Do not use screen capture, `CopyFromScreen`, `PrintWindow`, or screenshots.
Use `--no-visual` for render-gate workloads that do not need pixels.
The input latency probe already stops on native presentation records without capture.
Add native action scenarios to the existing tools for controls and lifecycle checks.
Only inject into windows created by the private-desktop launcher.

Preferred test seams:

- Lua UI tests: public commands, Document/View state, focus, and Workspace behavior.
- Native protocol tests: bounded decode, coordinate transformation, and connection/configuration rejection.
- Hidden-desktop tests: real HWND behavior, dialogs, IME placement records, and process failures.
- Existing surface latency probe: tagged input through the presented edited frame.

Do not assert exact shortcuts, theme colors, cosmetic dimensions, or private helper call counts.
Assert results: correct text, focus, captured target, bounds, status, callback results,
terminal identity, responsive controls, and rejected invalid data.

Measure direct and hosted modes with the same executable, renderer, fixture, and sample count.
Run repeated pairs and report p50, p90, p99, maximum, and failed samples.
Use an under-1-ms extra typing p50 target for this phase.
Investigate tail growth; do not hide it behind an unchanged median.
Private-desktop Present timing is not physical scanout latency.
Terminal shell round-trip benchmarks do not measure hosted keyboard rendering.

Current latency command:

```sh
python tools/run_surface_latency_probe.py --no-build --samples 240 --runs 3 --keep
```

Use `--no-build` only with current binaries.
New controls, dialog, and fault scenarios are planned extensions, not existing command options.

## Acceptance checklist

- [ ] One visible shell window; no visible Project window or hidden-window dialogs.
- [ ] Shell starts and handles controls without Lua, plugins, or user configuration.
- [ ] Hosted and direct editor commands retain their public behavior.
- [ ] Native controls work while the owned Project is suspended or has exited.
- [ ] Input, capture, focus, drops, IME, resize, and scale checks pass.
- [ ] Real IME candidate placement and mixed-DPI evidence is recorded separately from synthetic tests.
- [ ] Native dialogs return current callback results without blocking presentation.
- [ ] Normal quit, Cancel, remembered terminal policy, restart, and switch remain correct.
- [ ] Shell loss and forced Project close leave Terminal Sessions live.
- [ ] Malformed/stale frames and failed connections produce bounded failure states.
- [ ] Both renderer latency comparisons pass; failures and tail changes are reported.
- [ ] No automatic Project restart, adoption, Sidebar process, or multi-window coordinator enters this phase.

After acceptance, update the main plan and propose Phase 4 separately.
