# Phase 3: hosted single Project

This plan follows [Phase 2](PHASE2_TERMINAL_SESSIONS.md) and
[the multiprocess shell plan](MULTIPROCESS_SHELL_PLAN.md).
Read both before implementation.

Status: Milestones 1 to 3 are implemented. Real IME and mixed-DPI checks remain open.
Milestones 4 and 5 remain planned. Hosted mode remains opt-in.
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
- General hang detection and Sidebar recovery: Phase 4.
- Shared ownership of several Anvil Windows or moving Projects: Phase 5.
- Shell adoption, window restoration, or a Project registry: Phase 6.
- Final Project Sidebar presentation: Phase 7.

Existing New Window commands must not open a second visible window inside a Project process.
For this phase, they start another independent shell with one Project.
Phase 5 replaces this launch boundary with shared shell ownership.
This limited behavior is approved.

### Two shells opening the same Project

Match current direct-mode behavior, using the existing Lua IPC setting and advertisements.
With single-instance IPC enabled, a later directory launch raises the advertised instance and exits.
Its Project must exit intentionally, so its shell closes rather than showing Failed.
It must not restore or save that Project's Workspace or attach its Terminal Sessions.
New Window commands use the same advertised-Project check.

Disabled IPC and simultaneous starts before advertisement can allow two instances, as in direct mode.
They share the existing Workspace storage; the last completed save wins.
Do not add Workspace merge, ownership locks, or a global Project coordinator in Phase 3.
Terminal Sessions still permit one client. A second attach fails visibly and never starts a duplicate shell.
Closing that failed View must not close the first client's Terminal Session.
Test advertised-instance forwarding and explicit duplicate-instance Workspace/terminal behavior against direct mode.

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
On shell loss, immediately save the Workspace, detach terminals, and exit without a hidden quit prompt.
There is no recovery wait or adoption attempt in Phase 3.
A native watchdog enforces a five-second deadline from detected shell loss, including startup and teardown.
If the Lua loop cannot save, retain the last durable Workspace and report the loss risk.
Do not extend the native exit deadline while waiting for a stalled Lua loop.

Workspace saves retain layout and file references, not unsaved named-buffer contents.
Named-buffer edits survive only if the existing save/autosave behavior already wrote them to disk.
The existing Untitled recovery flush can retain Untitled contents during the immediate save.
A stalled loop or interrupted flush guarantees only the last complete recovery file, not the latest edits.
This phase adds no buffer-content journal and never silently writes dirty named Buffers on shell loss.

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

Starting draws native status text and an available Close action.
Failed also offers Restart Project, using the same-window restart launch path.
Keep the last complete frame when it is safe; otherwise draw a native background.
Close timeout offers Wait or explicit forced close with an unsaved-data warning.
A quiet or minimized Project is not a hung Project.
Do not use missing frames alone as a health signal.
Phase 4 adds general health probes.

Normal Close asks the Project to run its existing unsaved-buffer and terminal policy.
Report pending, cancelled, and accepted decisions explicitly.
Cancel returns the shell to Ready and permits a later close attempt.
Repeated Close requests cannot bypass confirmation.
A dialog awaiting user choice is not a close failure.
On acceptance, let Project shutdown drain its existing shared Terminal CLOSE budget.
Never hold the shell event loop while waiting for the process.
Force closes affect only the Project; Terminal Session processes remain independent.

Project-initiated quit follows the same accepted-exit path and closes the shell cleanly.
Only an unexpected exit shows Failed. An intentional nonzero exit status does not imply a crash.
On shell loss, the Project immediately saves and detaches under the native deadline.
On Project crash, the shell remains responsive and shows Failed.
Do not automatically rerun terminal commands or create replacement shells.

GPU loss logs the cause, releases obsolete resources, and enters Failed with Restart Project and Close.
Do not add automatic software-publication fallback or a device-recreation loop in Phase 3.
The normal user-selected software renderer remains supported.
If presentation itself is unavailable, expose the same actions through native OS UI without Lua.

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
- Test immediate shell-loss save/detach and the hard deadline, including a stalled Lua loop.
- Test intentional Project quit and duplicate-Project behavior against direct mode.

Implemented:

- The shell launches explicit `--project <path>` mode and validates the child PID.
- The Project checks the pipe server PID and retains the shell process handle.
- `src/window_backend.c/.h` owns direct/hosted window operations and render-window creation.
- Hosted getters use cached shell configuration. Window requests use a bounded native writer queue.
- The shell no longer owns a kill-on-close Project job.
- Shell loss sends a distinct event, saves the Workspace, detaches Views, and bypasses interactive quit policy.
- A native watcher ends a stalled Project after five seconds. It does not run potentially blocked DLL teardown.
- Restart and same-window switch replace the Project process while retaining the shell process.
- New Window starts an independent shell. Advertised duplicate launches exit intentionally before Workspace restore.
- Intentional quit, including a nonzero Project status, closes the shell without showing Failed.
- Repeated Close no longer forces termination. Explicit forced-close UI remains in Milestone 4.

Native Failed controls, Restart Project UI, and GPU failure handling remain in later milestones.
Hosted dialogs currently have no parent; they never use the hidden render window.
Milestone 4 adds the shell parent and asynchronous dialog results.

Focused red-green evidence:

- The saved baseline failed explicit Project launch: `shell did not launch explicit Project mode`.
- It failed replacement: `hosted restart reused the old Project process`.
- It failed shell-loss persistence: `shell loss did not save the latest Workspace`.
- It failed the stalled-loop case: `native deadline did not protect a stalled Lua loop`.
- Nine hosted launch/lifecycle cases pass, including invalid launch, nonzero quit, and independent New Window.
- Four direct/hosted duplicate cases pass. They check forwarding, last-completed Workspace saves, and Terminal single-client conflicts.
- The six focused direct Terminal lifecycle checks pass through Meson.
- Lua syntax, Python compilation, native build, and diff checks pass.

The fixture uses background-eligible coroutines so an unfocused private desktop continues its OS polling.
Early missing-result runs exposed fixture setup and scheduling faults; they are not regression evidence.

Typing-to-Present measurements used 240 samples, three runs, and copied app data on a private desktop.
Each row contains 720 completed samples. No run lost samples.
D3D11 after-values use a repeat without concurrent fault checks; software uses the first complete after-run.

| Mode / renderer | p50 before → after | p90 before → after | p99 before → after | Maximum before → after |
| --- | ---: | ---: | ---: | ---: |
| Direct / D3D11 | 6.41 → 7.11 ms | 15.79 → 15.76 ms | 20.28 → 19.14 ms | 239.12 → 48.43 ms |
| Hosted / D3D11 | 7.32 → 6.54 ms | 16.19 → 15.88 ms | 19.46 → 19.31 ms | 30.47 → 25.61 ms |
| Direct / software | 17.95 → 18.21 ms | 26.77 → 26.89 ms | 30.42 → 31.65 ms | 32.42 → 37.60 ms |
| Hosted / software | 11.59 → 10.58 ms | 20.88 → 19.96 ms | 24.97 → 23.15 ms | 480.02 → 26.45 ms |

The first after-run showed a 705.66 ms direct D3D11 maximum and a 55.02 ms p99.
That run overlapped fault checks. The isolated repeat showed 48.43 ms and 19.14 ms, respectively.
This does not prove a cause. Retain both results instead of hiding the first tail.
Hosted D3D11 p50 was 0.57 ms below direct in the repeat, within the added-latency target.
Do not claim a causal performance gain from these small median differences or isolated maxima.
These measurements stop at native Present, not physical scanout or terminal shell replies.

Verification commands:

```sh
python tools/run_surface_latency_probe.py --no-build --project-case launch \
  --project-case invalid --project-case shell-loss --project-case stalled-loss \
  --project-case quit --project-case quit-error --project-case restart \
  --project-case switch --project-case new-window --keep
python tools/run_surface_latency_probe.py --no-build --mode shell --mode direct \
  --project-case conflict --project-case duplicate --keep
meson test -C build-windows-x86_64 anvil:lua-ui \
  --test-args ui/terminal_sessions_lifecycle.lua
```

### Milestone 2: native controls and placeholder

Implemented. Hosted mode remains opt-in.
The user checked foreground transfer by launching `anvil --shell` from two terminals.
The existing window came to the front and changed position.

The shell draws and handles its caption controls without Lua.
It uses native fonts and caches its own UI texture.
It shows the Sidebar placeholder and Starting state before the first Project frame.
Closing keeps Project confirmation visible. Failed offers Restart Project and Close.
Failed Restart uses a new Project process in the same shell.
It retains the last private Project frame behind the failure card when that frame remains safe.

Surface protocol version 4 reports the reserved control rectangle.
Hosted Title Bar layout leaves that rectangle empty and removes Lua caption targets.
Direct caption drawing stays unchanged. Native hit regions take priority over Project regions.
The shell clamps Project client regions and uses its own resize border.
Native caption actions do not wait for Project frames during resize.
Frame acquisition uses zero wait. A native timer retries a busy frame without delaying normal input events.

The lifecycle overlays are initial states, not the complete close or failure protocol.
Milestone 4 still owns explicit cancellation, asynchronous dialogs, and forced-close confirmation.
Milestone 5 still owns bounded GPU and surface failures.

#### Milestone 1 follow-ups

- A busy Terminal Session with remembered `end` survives shell loss and reattaches with the same host PID and Session ID.
  This check already passed before implementation changes. No quit-policy change was needed.
- Project logs distinguish shell process exit, pipe failure, queue overflow, and inbound/outbound allocation failure.
- Nonexistent file arguments no longer stop the native shell launcher.
  Initial hosted launch preserves the original CLI arguments instead of inserting another positional Project argument.
- Direct and hosted startup share one native path filter.
  It excludes options and their values from Project path selection.
  Known switches have no value. Other startup options consume one value or use `=value`.
  The shell does not load plugin flag definitions.
- IPC records report the visible window owner's PID.
  The forwarding Project grants foreground permission to that PID before requesting activation.
  The shell grants permission to its new Project and restores a minimized window before raising it.
  Older live IPC records can omit the window PID; log that boundary instead of failing startup.

#### Focused verification

`ui/titlebar_hosted.lua` failed with `Tabs cover native controls` before the layout change, then passed.
The owned-window option-value check failed with `file argument selected the wrong Project` in both modes, then passed.
The original launcher failed the nonexistent-file check with `nonexistent file prevented Project launch`.
The corrected launcher passed that check in both modes.

The native control probe suspends only its owned Project.
It checks minimize, maximize, restore, native drag/resize hit regions, movement, and resize completion.
After resume, it edits through `core.on_event`, creates a Pane, and changes Tab focus.
Repeated Close does not kill the suspended Project.
After an unexpected exit, Failed Restart keeps the shell and replaces the Project PID.
Run this probe with both Project renderers.

The six focused Terminal lifecycle checks passed.
The direct Title Bar file passed 24 of 26 checks.
The same two wheel checks failed with the original Title Bar restored.
Those unchanged failures are outside this milestone.

#### Native caption click correction

The user found that native Close and Minimize did not work on the interactive desktop.
The original probe posted press and release together. It missed normal mouse-capture ordering.
The corrected probe drains press, held motion, and release separately.
Before the fix, it failed with `native Minimize waited for the suspended Project`.

SDL released automatic capture before the shell consumed its queued button-up event.
The capture-change handler then cleared the pressed control without performing its action.
The shell now handles native control presses, held motion, and releases in its window procedure.
It does not also queue those control events through SDL.
Actual capture loss still cancels a pressed control.
Project input keeps its SDL path.

The probe now closes the replacement Project through the native Close button.
It no longer substitutes a Lua quit command for that check.
Minimize, Maximize, Restore, suspended-Project Close, Failed Restart, and accepted Close pass with both renderers.

The isolated direct D3D11 rerun completed 720 samples before this correction:
`6.91 / 16.48 / 20.35 / 57.64 ms` for p50 / p90 / p99 / maximum.
The earlier p99 of 36.22 ms did not repeat. One maximum does not establish a causal regression.
Evidence: `anvil-surface-latency-emm8v103`.
The initial caption red is `anvil-surface-latency-4iquf7dl`.
The final fixture also fails on the saved old executable in `anvil-surface-latency-2pd82i_2`.
It reports the same Minimize failure.
Final control checks with held motion pass in `anvil-surface-latency-yrmxpcx7` for D3D11
and `anvil-surface-latency-f697kkks` for software.

The final isolated latency matrix used the rebuilt executable after the held-motion correction.
No build or correctness check overlapped these measurements. Each row completed three runs of 240 samples.
The clock stops at Present, not physical scanout.

| Mode / renderer | p50 / p90 / p99 / maximum (ms) |
|---|---|
| Direct D3D11 | 7.20 / 16.45 / 19.76 / 46.21 |
| Hosted D3D11 | 6.53 / 15.64 / 19.27 / 21.57 |
| Direct software | 18.50 / 27.55 / 31.77 / 36.80 |
| Hosted software | 10.24 / 19.24 / 23.44 / 25.59 |

Evidence: `anvil-surface-latency-570cw0p1`.
An earlier isolated matrix after the initial correction is `anvil-surface-latency-zwg__tl7`.
Its direct D3D11 p99 / maximum were 19.17 / 39.20 ms.
The prior p99 increase did not repeat, so these results do not justify a causal bisect.

Milestone 4 must restore Closing to Ready after cancelled close and clear `close_requested_ns`.
This correction does not implement the Milestone 4 close protocol.

The foreground probe uses only owned windows on the private desktop.
It verifies minimized-window restoration and records foreground permission grants.
Windows returns no foreground window on that inactive desktop.
Its result reports `foreground_gate="unavailable"`; it does not prove interactive foreground transfer.
The user's subsequent two-terminal check supplies the interactive foreground result.
Do not switch desktops or use the user's windows to complete this gate without permission.

Each probe has isolated app data, process handles, and an IPC shared-memory namespace.
An earlier run found an older IPC record without the new window PID.
The new boundary check and namespace isolation replace those startup failures.
Other fixture failures used the removed `core.docview` module or included a newline beyond `get_text`'s exclusive endpoint.
The final fixture uses `core.editor` and the correct endpoint.

```sh
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/titlebar_hosted.lua
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/terminal_sessions_lifecycle.lua
python tools/run_surface_latency_probe.py --no-build --mode shell --mode direct \
  --project-case arguments --project-case option-arguments --keep
python tools/run_surface_latency_probe.py --no-build --project-case controls \
  --project-case end-loss --project-case foreground --keep
python tools/run_surface_latency_probe.py --no-build --renderer software --project-case controls --keep
```

#### Milestone 2 latency

Each table row contains three runs of 240 samples. All 720 samples completed.
Times measure generated input through native Present, not physical scanout or Terminal replies.
The baseline used the pre-milestone executable and runtime copied into an isolated app.

| Mode / renderer | Before p50 / p90 / p99 / max (ms) | After p50 / p90 / p99 / max (ms) |
|---|---|---|
| Direct D3D11 | 7.02 / 15.70 / 19.39 / 39.75 | 7.50 / 17.17 / 36.22 / 80.05 |
| Hosted D3D11 | 7.46 / 16.51 / 19.67 / 22.79 | 7.81 / 16.62 / 19.79 / 22.06 |
| Direct software | 18.36 / 27.36 / 31.12 / 36.33 | 20.02 / 29.09 / 38.61 / 63.20 |
| Hosted software | 10.98 / 19.52 / 22.73 / 25.55 | 11.85 / 20.35 / 24.64 / 26.72 |

Hosted D3D11's median exceeds direct D3D11 by 0.31 ms, within the added-latency target.
Some runs overlapped lifecycle checks. Small changes and isolated maxima do not prove a causal gain or regression.

The first implementation changed shell event scheduling to 60 Hz.
That run produced hosted medians of 26.14 ms for D3D11 and 26.90 ms for software.
Restore event-driven scheduling; use the timer only to retry a busy frame.
The final table retains the corrected run, not the slower trial.

Evidence folders under `%LOCALAPPDATA%\Temp`:

- Baseline: `anvil-surface-latency-u6_98et2`.
- Slower trial: `anvil-surface-latency-1zlj5z9f`.
- Corrected run: `anvil-surface-latency-08af71lc`.
- CLI red: `anvil-surface-latency-76ofiimm`.
- CLI green: `anvil-surface-latency-oomt7lxx`.
- Final native controls and foreground gate: `anvil-surface-latency-rj4y0jwn`.
- Software controls: `anvil-surface-latency-yrwk3ed9`.
- Direct/hosted duplicate and conflict checks: `anvil-surface-latency-tupkmxbt`.

### Milestone 3: input, IME, focus, and DPI

- Complete coordinate, text payload, capture, focus, and drop routing.
- Add configuration generations and reject stale geometry/frames.
- Test text edits, composition, selection drag across boundaries, wheel, focus loss, and complete text drops.
- Test fractional scales, nonzero origins, resize, and target replacement.
- Complete real IME candidate and mixed-DPI verification, or report the unavailable gate explicitly.
- Compare direct and hosted presented-input latency on both renderers.

Implemented:

- Surface protocol 5 identifies the configuration used by input, frames, IME areas, and Title Bar regions.
- The shell reports the physical surface origin. Pointer routing and presentation use that rectangle.
- SDL points convert to physical client pixels once. Display scale does not multiply packet coordinates.
- The shell owns capture until button release. Sidebar crossings do not change a pressed target.
- Focus loss, capture loss, and connection loss release pressed state. Focus loss also cancels composition.
- Replacement clears composition and capture. Connection IDs reject old queued shell notifications.
- Text and drop payloads have owned storage. Queue text remains valid until the next pop.
- The Project applies configuration, focus, and input in caller-visible order, not on the reader thread.
- Motion and resize coalescing never crosses an intervening event.
- Frame checks cover configuration, dimensions, resource owner, stride, and mapped storage.
- IME clipping adds both origin coordinates and retains the cursor offset within the clipped area.
- Configuration changes invalidate composition, IME placement, and Title Bar regions.
- Required-message queue failure ends the connection visibly. It does not silently lose one key.

The busy-frame timer now exists only during a failed acquisition. A successful load removes it.
Hover redraw uses cached GDI resources and native UI rectangles, not a full texture upload.
Milestone 2 UI statements now use separate lines.

#### Focused red-green evidence

- `drop-events` failed when queued UTF-8 text retained borrowed storage.
- It also failed when motion replaced an event before an intervening button event.
- `hosted-routing` failed when the reader changed focus before the UI consumed its packet.
- It rejected a same-size frame only after the configuration check was added.
- The configuration-order check failed when scale changed ahead of earlier queued text.
- The cursor check failed when clipping changed the candidate offset incorrectly.
- Captured Sidebar crossings failed to emit leave and enter events while retaining capture.
- `ui/titlebar_hosted.lua` failed because Project leave retained Title Bar hover.
- `ui/textview_ime.lua` failed with `composition survived focus loss` without the focus-loss change.
- Restoring the old truncation rule failed the private-desktop 40 KB text drop.
  The result reported `hosted text drop lost complete UTF-8 or trailing lines`.

The native routing and event-queue checks now pass.
Private-desktop routing passes with D3D11 and software Project renderers.
It checks native capture, selection across the Sidebar, release, wheel, focus loss, and complete text drops.
The drop retains UTF-8, blank lines, and trailing lines. It opens a new Pane instead of replacing work.
Native controls and Project restart also pass after the routing changes.

The routing fixture uses internal SDL input actions on the owned inactive desktop.
Posted Win32 button messages alone trigger SDL's real-button release checks and cannot prove a held drag there.
Native capture checks use the owned thread's GUI state. Focus cancellation uses its native focus-loss notification.
These checks do not prove physical mouse input, real IME candidate placement, or mixed-DPI monitor moves.
Those interactive IME and mixed-DPI gates remain unavailable in this session.
No user window or desktop was used for verification.

Evidence:

- Large-drop red: `anvil-surface-latency-n6plfm0r`.
- D3D11 routing, controls, restart, switch, and shell loss: `anvil-surface-latency-bzm8i3f8`.
- Software routing, controls, and restart: `anvil-surface-latency-a2dseswj`.
- Captured-hover red: `anvil-surface-latency-9xeuute0` and `phase3-m3-hover-red`.
- Captured-hover green: `anvil-surface-latency-ca6qikgy`, `anvil-surface-latency-gzukabnn`, and `phase3-m3-hover-green`.
- Meson logs: `phase3-m3-cache-order-red`, `phase3-m3-cache-order-green`, and `phase3-m3-cursor-red`.
- IME logs: `phase3-m3-ime-red` and `phase3-m3-ime-green`.

```sh
meson test -C build-windows-x86_64 anvil:hosted-routing anvil:drop-events
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/textview_ime.lua
python tools/run_surface_latency_probe.py --no-build --project-case routing \
  --project-case controls --project-case restart --keep
python tools/run_surface_latency_probe.py --no-build --renderer software \
  --project-case routing --project-case controls --keep
```

#### Milestone 3 latency and final checks

Final syntax, native build, event-queue, routing, IME, and Title Bar checks pass.
Final controls and routing pass with both Project renderers after the last formatting change.
Their evidence folders are `anvil-surface-latency-smtbgy1v` and `anvil-surface-latency-u4hhxjhk`.
The final Meson logs use the `phase3-m3-checked-` prefix.

Both latency matrices ran after correctness checks, without overlapping builds or tests.
The before matrix uses the saved caption-fix executable with the same current copied app data.
Each row completes three runs of 240 samples. No samples failed.
The clock stops at native Present, not physical scanout or Terminal replies.

| Mode / renderer | Before p50 / p90 / p99 / max (ms) | After p50 / p90 / p99 / max (ms) |
|---|---|---|
| Direct D3D11 | 6.30 / 15.65 / 19.05 / 45.48 | 6.75 / 15.30 / 18.50 / 55.76 |
| Hosted D3D11 | 6.71 / 15.89 / 19.26 / 22.46 | 6.97 / 15.81 / 19.11 / 23.45 |
| Direct software | 10.53 / 19.70 / 23.04 / 24.48 | 10.96 / 19.32 / 23.23 / 25.08 |
| Hosted software | 10.55 / 19.54 / 23.22 / 24.17 | 10.10 / 17.98 / 22.57 / 26.31 |

Hosted D3D11 adds 0.22 ms to the direct median, within the under-1-ms target.
Direct D3D11 p99 decreases; its single larger maximum does not establish a regression.
The fresh software baseline differs from older records for both executables.
Do not attribute that difference to this milestone or claim a causal performance gain.

Before evidence: `anvil-surface-latency-3skpgo2d`.
After evidence: `anvil-surface-latency-9tok8p6e`.
Real IME and mixed-DPI checks remain open. Hosted mode remains opt-in.

#### Input follow-up before Milestone 4

Consecutive inbound mouse motions now share one queue entry when their configuration matches.
The queue retains the last position and adds relative motion. Other events remain barriers.
Receive notifications occur only when the queue changes from empty to nonempty.
The stalled-UI test sends 100,001 motions. Before the fix, inbound overflow ended the connection.
After the fix, every packet completes and the final position and text barrier reach the caller.
Evidence: `phase3-m4-motion-red` and `phase3-m4-pre-green`.

Only coordinate and layout changes advance the configuration epoch.
Window position, refresh rate, mode, and move-loop status retain the current epoch.
The Project still applies those ordered metadata changes.
Same-epoch layout changes fail the connection instead of changing input coordinates silently.
Moving the owned window now retains composition, Title Bar client regions, and matching frames.
The red reported `window move cancelled composition` in `anvil-surface-latency-in7iyylq`.
D3D11 and software pass in `anvil-surface-latency-gdckuvnw` and `anvil-surface-latency-emy4uj41`.
The native epoch check also passes in `phase3-m4-pre-green`.

The Title Bar owns its configuration reset method. The redundant resize condition is removed.
The user has not supplied actual IME or mixed-DPI manual results. Both manual gates remain open.

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
Controls, routing, and lifecycle actions are available. Dialog and GPU failure actions remain planned.

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
- [ ] Named unsaved contents have no new survival guarantee; Untitled recovery limits are documented.
- [ ] Project-initiated quit closes the shell; unexpected exit offers Restart Project and Close.
- [ ] Duplicate Project launches match direct-mode Workspace and terminal behavior.
- [ ] Malformed/stale frames and failed connections produce bounded failure states.
- [ ] Both renderer latency comparisons pass; failures and tail changes are reported.
- [ ] No automatic Project restart, adoption, Sidebar process, or multi-window coordinator enters this phase.

After acceptance, update the main plan and propose Phase 4 separately.
