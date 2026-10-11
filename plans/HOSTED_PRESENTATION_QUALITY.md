# Hosted presentation quality

## Status

Draft, 2026-10-12. The user reported visible jank in hosted mode and asked to fix the stack before the
Phase 7 Sidebar design. The user left the Sidebar design to the agent; it follows this work.
Commit and stop for review after each milestone. Hosted mode stays opt-in.

## Reported issues

From the user, using hosted mode on the deployed portable:

1. The Project Sidebar and the window controls are near-black. They do not follow the Project's background
   or wallpaper.
2. A popup's shadow, such as the fuzzy picker's, does not reach the Sidebar or the window controls.
3. During a resize the new area shows a black void, and the content takes visible time to catch up.
   Direct mode re-rendered and re-laid out instantly.
4. A fast resize also shows a blue void. Slow horizontal resizing shows it too.
5. Horizontal resizing is choppy even when slow.
6. Resizing from the left edge is the worst: rendered text jumps.

## Causes found in the code

Resize (issues 3–6):

- `resize_step` (`src/anvil_shell.c`) runs inside `WM_SIZE`. It sends the new size, then waits at most
  `SHELL_RESIZE_WAIT_MS` (50 ms) for a Project frame of that size. After one miss it sets
  `resize_wait_disabled` and stops waiting until a full-size frame arrives. During a drag that frame arrives only
  after the drag, so one slow step turns off synchronization for the rest of the drag.
- Without a matching frame, the shell presents the old, smaller Project surface over a fixed dark clear colour
  (`0.09, 0.09, 0.11`). That is the black void.
- The D3D11 Project path (`d3d11_create_hosted_buffers`, `src/d3d11_backend.c`) creates a new render texture, a
  new shared texture, and a new NT handle for every size. The shell then reopens the texture by name.
  This makes every step slow. The software path already grows its shared memory with slack.
- Direct mode sets the swapchain background colour (`SetBackgroundColor`) and the DWM border and caption colours
  to the theme background (`win32_frame_set_background`). The shell sets none of these on its own window, so
  areas Windows exposes before the next present use the system colours. This is the likely source of the blue
  void; milestone 1 confirms it.
- The swapchain uses `DXGI_SCALING_NONE`, anchored top-left. When the left edge moves, an old frame is drawn at
  the new left edge, so the content jumps sideways until a matching frame arrives.
- The shell's native log goes only to stderr unless `ANVIL_SURFACE_LOG` is set. Real sessions leave no
  shell evidence.

Layering (issues 1–2):

- The Project surface covers only the area right of the Sidebar (`origin_x = sidebar_w`).
- The shell copies layers with `CopySubresourceRegion`; it has no blending. The Sidebar surface and the native
  UI texture (window controls, Restart Sidebar, notices) are opaque and drawn over a fixed dark fill.
- Anything the Project draws, such as wallpaper, popup shadows, or dims, stops at its own surface edge.

## Milestones

### 1. Smooth resize

- Write the shell's native log to `USERDIR/logs/anvil-shell-<date>-<time>-p<pid>.log`, like session logs.
- The Project reports its background colour to the shell. The shell uses it for the clear colour, the swapchain
  background colour, and the DWM border and caption colours.
- The D3D11 Project surface grows with slack, like the software path. Frames carry their used size; the shell
  copies that region. A live resize then reuses the shared texture.
- Keep the 50 ms wait for each step. Stop waiting only after several consecutive misses (a hung or very slow
  Project), and wait again after the next matching frame.
- While no matching frame exists, the shell keeps the old content at its previous screen position and fills
  the rest with the Project's background colour. A left-edge drag no longer moves text.

Seam: a new `resize-live` probe case. It runs a scripted live resize (enter size/move, a sequence of
right-edge and left-edge sizes, exit size/move) on a private desktop. The shell log records each step's
outcome. Checks: most steps present a matching frame; stale steps keep content in place; no step uses a colour
other than the Project's background for exposed areas. Red first against the deployed build.
Run matched latency after this milestone.

### 2. Layered composition

- The Project surface spans the whole client area. The Project lays out its UI to the right of the Sidebar, and
  draws its background and wallpaper under the Sidebar too, with a Sidebar tint from the theme.
  Popups, shadows, and dims may then cover the whole window.
- The shell gains a small blend pass with premultiplied alpha. The Sidebar surface renders with a transparent
  background and is blended over the Project surface. The native UI layer (window controls, notices, Restart)
  is drawn with alpha and blended last.
- The Sidebar keeps its own process. A Project hang or crash keeps its last frame under the Sidebar; a Dormant,
  starting, or failed Project shows its last background colour.
- Software renderer: if the Sidebar cannot render alpha there, it draws an opaque background in the theme's
  Sidebar colour.

Seam: a probe-only capture of the shell's composed frame, gated by `ANVIL_SURFACE_FAULT_PROBE`. Checks
sample pixels: the Sidebar background and the control area show the Project's background or wallpaper, and an
open popup's shadow darkens pixels under the Sidebar. Red first. Run matched latency after this milestone.

### 3. First Sidebar design

Then Phase 7 continues with a first full Sidebar design (see [Phase 7](PHASE7_SIDEBAR_PRESENTATION.md)),
on top of the layered composition.

## Verification

Red-green at the seams above, on D3D11 and software. Keep existing restore, adoption, Window, and launch cases
passing. Do not widen product timeouts. Manual check after each milestone: the user resizes and uses hosted
mode on the deployed portable.
