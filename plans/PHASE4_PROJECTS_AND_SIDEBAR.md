# Phase 4: several Projects and the Sidebar process

## Status

The user approved continued work while the Phase 3 physical-input, IME, and mixed-DPI checks remain open.
Hosted mode stays opt-in. The Phase 3 code reviews are complete.
Do not treat synthetic tests as manual acceptance.

## Scope

Keep several Projects loaded in one Anvil Window.
Selecting another Project must preserve the previous Project's live Buffers, Workspace, workers, and Terminal Session connections.
A loaded Project that no Window presents must stop rendering, not stop its background work.
A Dormant Project has no Project process. Selecting it loads its saved Workspace.

The shell owns Project identity, selection, lifecycle, and the Project Sidebar model.
The Sidebar process draws a minimal list and sends actions. It owns no Project state.
Keep the native window controls independent of both Lua processes.

Keep direct mode and non-Windows behavior unchanged.
Keep Project GPU recovery explicit. Do not add automatic renderer fallback.
Do not terminate a Project because its pipe failed or its Close request timed out.

## Milestones

### 1. Hidden rendering control

Add shell-owned rendering permission to hosted configuration.
Hiding or minimizing the current Window supplies the first real use of this permission.
Keep geometry configuration identity separate from rendering permission.
Do not use keyboard focus as rendering permission.

The Project must continue processing events, coroutine tasks, worker results, Workspace saves, and Terminal output while hidden.
Do not clear pending redraw requests while hidden.
Showing or restoring the Window must request a complete repaint of the latest state.
Keep the native first-frame timeout from rejecting a deliberately hidden Window.

Test the public `core.step` and `core.run_step` behavior at the window boundary.
Extend the existing owned-window fixture for minimize, hide, restore, background progress, and Close while hidden.
Run both renderers. Use no screen capture or user windows.
Compare typing latency separately from correctness checks.
If Close needs a user choice, show and restore the Window before waiting.
Cancellation must preserve unsaved edits and return the Project to Ready.

### 2. Several loaded Projects

Separate per-Project transport and process ownership from Window presentation state.
Tag queued work with Project and connection identity. Keep storage alive until its users stop.

Keep A loaded while selecting B. Selecting A again must use the same Project process and live state.
Configure, focus, and rendering permission must follow selection in one ordered stream.
Old frames, dialogs, input, and worker results must not reach another Project.
Keep one Project instance per path. Do not introduce several Anvil Windows yet.

### 3. Dormant Projects and independent recovery

Add explicit Project unload and load, with the existing unsaved-data and Terminal policies.
Test Workspace restoration and live Terminal reattachment without command replay.
Keep crashes and hangs local to one Project.
Expose Wait and explicit Restart without blocking another Project or the native controls.

### 4. Project Sidebar model

Use recent Projects as the list source. Keep order stable, with new Projects first.
Include Project lifecycle and bounded asynchronous Terminal Session status.
Do not poll Terminal hosts or read registry files on the native UI thread.

### 5. Minimal Sidebar process

Use the existing renderer, surface transport, theme, and input boundaries.
Keep the first list UI small. Defer final presentation design to Phase 7.
A Sidebar crash or hang must not stop Project input or native controls.
Restart only the Sidebar after its failure.

## Deferred work

Phase 5 owns several Anvil Windows and moving Projects between them.
Phase 6 owns shell adoption and full restore after exit or reboot.
Do not add those features as part of Phase 4.

## Verification records

Record each milestone's targeted red-green evidence, focused checks, latency comparison, and commit.
Keep the deferred Phase 3 manual checks visible until the user supplies results.

### Milestone 1: hidden rendering control

Surface protocol 7 adds shell-owned rendering permission, separate from layout identity.
The Project processes events and service work without updating or drawing its UI while hidden.
The scheduler keeps ordinary coroutine tasks active after the focus-loss delay.
Showing or restoring requests a complete repaint and keeps the same Project process.
Terminal Views retain their native grid until they have valid layout geometry.
Close shows or restores the Window when it needs a user choice.
Cancellation keeps the dirty Buffer. Clean Close also works while hidden.

Targeted red-green evidence:

- `hidden_rendering.lua` failed because the hidden Project drew. Both editing and pending-redraw checks now pass.
- `hidden_terminal_geometry.lua` failed because missing layout changed the native columns. The retained-grid check now passes.
- The owned `hidden-render` case failed because Terminal output disappeared after the grid shrank.
  It now checks late coroutine work, worker results, Terminal output, saved Workspace, and the latest text after restore.
- Its idle check failed with the old scheduler mode when no redraw remained pending.
  With rendering permission disabled, ordinary coroutine tasks now continue without needing a redraw.
- `hidden-startup` failed when the first-frame deadline rejected a deliberately hidden Window.
  Restoring the visibility guard keeps the Project live beyond that deadline.
- `hidden-close-cancel` failed because its confirmation remained invisible.
  It now checks visible confirmation and Cancel for both minimized and hidden Windows.

The worker result collector originally replaced the echo result with an empty final message.
The fixture now retains the result message. This fixture correction is not a runtime fix.

All three focused Lua tests pass. Four owned-window cases pass on both renderers.
These checks use the existing private-desktop runner. They capture no pixels and touch no user windows.

Evidence directories under `%LOCALAPPDATA%/Temp`:

- Hidden rendering and clean Close: `anvil-surface-latency-0ycb65gp` and `anvil-surface-latency-eh1cs065`.
- Final rendering, clean Close, and startup: `anvil-surface-latency-vw_dkyll` and `anvil-surface-latency-3bm8lnn5`.
- Startup red: `anvil-surface-latency-d66mr1dl`.
- Hidden confirmation red: `anvil-surface-latency-k4roh0ih`.
- Confirmation greens: `anvil-surface-latency-ne5semq4` and `anvil-surface-latency-mrwc7qpu`.
- Terminal output red: `anvil-surface-latency-e3f346bl`.
- Idle scheduler red: `anvil-surface-latency-c0yw3prh`.
- Final idle and background greens: `anvil-surface-latency-gtnq_53t` and `anvil-surface-latency-u3481i7l`.

Meson logs include `phase4-m1-render-complete.txt`, `phase4-m1-terminal-grid-red.txt`, and `phase4-m1-terminal-final.txt`.
Lua syntax, Python compilation, and `git diff --check` pass.

#### Isolated typing latency

Both builds used three runs of 120 samples per mode and renderer.
Each row has 360 valid samples and no failed samples.
No correctness check or build ran during either measurement.
Values are p50 / p90 / p99 / maximum / mean, in milliseconds.

| Mode | Before | After |
| --- | --- | --- |
| Direct D3D11 | 7.25 / 16.27 / 19.68 / 52.17 / 8.76 | 6.95 / 16.34 / 18.76 / 58.52 / 8.51 |
| Hosted D3D11 | 7.38 / 16.15 / 19.86 / 24.74 / 8.89 | 6.94 / 15.62 / 18.89 / 19.79 / 8.65 |
| Direct software | 17.42 / 26.34 / 30.57 / 31.56 / 18.59 | 17.93 / 26.76 / 31.58 / 32.99 / 18.97 |
| Hosted software | 10.33 / 19.85 / 23.29 / 25.10 / 12.08 | 11.76 / 20.13 / 22.84 / 27.28 / 12.65 |

Hosted D3D11 has no measured median increase over direct D3D11 in this comparison.
The software median increased. Its hosted p99 decreased, while direct p99 increased by 1.01 ms.
These samples do not establish a cause or a performance gain. Maximum values remain variable.
The measurement ends at Present, not physical display scanout.

Before evidence: `anvil-surface-latency-abhxr76a`. After evidence: `anvil-surface-latency-o3fp_z8y`.
Milestone 1 is complete. The warned dev portable update rebuilt, installed, and restarted Anvil.
The fresh session and startup logs contain no errors, warnings, or startup failures.
Phase 3 physical-input, IME, and mixed-DPI checks remain open. Hosted mode remains opt-in.
