# RAD-style live resize and refresh pacing plan

Goal: make Anvil window resizing and frame pacing feel closer to RAD Debugger on Windows, while keeping normal editor behavior stable, measurable, and easy to roll back.

This document started as the implementation plan. Runtime changes are now underway and the sections below remain useful as design rationale and future-test guidance.

## Implementation status

Implemented milestones in this branch:

- resize/D3D/Lua instrumentation gated by `ANVIL_RESIZE_STATS`, `ANVIL_LUA_RESIZE_STATS_FILE`, and existing `ANVIL_D3D11_STATS`;
- Win32 live-resize tracking for `WM_ENTERSIZEMOVE` / `WM_EXITSIZEMOVE` and final resize frame requests;
- immediate no-extra-sleep Lua frame path for live resize;
- SDL resize immediate-render suppression while the Win32 modal resize path owns live rendering;
- active-refresh-based C resize throttle outside true live resize;
- D3D11 resize unbind, resize timing, resize result logging, and RAD-style `ClearState()` after present;
- the default Windows/D3D11 live-resize path now uses `WS_EX_NOREDIRECTIONBITMAP`, owned `WM_SIZE` immediate frames, `Present(0, 0)` during live resize, and a DXGI swapchain background color matched to the detected theme background;
- laggier synchronization options remain opt-in: `ANVIL_D3D11_RESIZE_DWM_FLUSH=1`, `ANVIL_D3D11_RESIZE_FLUSH=1`, `ANVIL_WIN32_OWN_WM_PAINT=1`;
- live-D3D resize defers full window-sized CPU surface recreation and updates cached window dimensions instead;
- resize/pixel-size event queue churn is coalesced;
- app cursor updates are suppressed while Win32 live resize is active.

Automated synthetic live-resize smoke tests show no D3D present/resize failures, no Lua sleeps in immediate resize frames, and main surface recreation is deferred for live D3D resizes. Manual testing selected the default path above as the best trade-off found so far: smooth live resize with exposed swapchain-background artifacts reduced by matching the background color rather than using latency-heavy DWM flushes.

## Sources reviewed

RAD Debugger reference files:

- `raddebugger/src/win32/window_manager/win32_window_manager.c`
- `raddebugger/src/render/d3d11/render_d3d11.c`
- `raddebugger/src/raddbg/raddbg_core.c`
- `raddebugger/src/raddbg/raddbg_main.c`
- `raddebugger/src/base/base_entry_point.c`
- `raddebugger/src/window_manager/window_manager.h`

RAD was fetched through the pi web-fetch GitHub cache at:

```text
C:\Users\Dario Costa\AppData\Local\pi-web-smart-fetch\github-cache\EpicGamesExt\raddebugger
```

Current Anvil files:

- `src/win32_frame.c`
- `src/main.c`
- `src/d3d11_backend.c`
- `src/rencache.c`
- `src/renwindow.c`
- `src/api/renderer.c`
- `src/api/renwindow.c`
- `src/api/system.c`
- `src/system_events.c`
- `src/renderer.c`
- `data/core/init.lua`
- `data/core/config.lua`
- `data/core/view.lua`
- `data/plugins/anvil_defaults.lua`

## What RAD does that is relevant

RAD's smooth live-resize behavior appears to come from the combination of these details, not from one magic flag.

### Win32 live resize / paint path

RAD owns the Win32 loop and handles these messages directly:

- `WM_ENTERSIZEMOVE` sets a global live-resize flag.
- `WM_EXITSIZEMOVE` clears that flag.
- `WM_SIZE` and `WM_PAINT` do:
  - `BeginPaint(hwnd, &ps)`
  - `update()`
  - `EndPaint(hwnd, &ps)`
  - `DwmFlush()`

That means RAD renders synchronously inside the modal sizing loop, instead of waiting for a normal app loop tick.

Other Win32 details worth tracking, but not copying blindly:

- RAD registers its graphical window class with `CS_VREDRAW | CS_HREDRAW`.
- For the D3D11 backend, RAD creates windows with `WS_EX_NOREDIRECTIONBITMAP`.
- RAD's custom-border hit test asks `DefWindowProc()` first and lets default Windows handling own the resize borders/corners before applying custom title-bar behavior.
- RAD suppresses its own cursor changes while `w32_wm_resizing` is true, so the OS resize cursor is not fought during border drags.

Because Anvil's HWND is created by SDL, these are investigation points rather than immediate implementation requirements.

### RAD frame loop / pacing

RAD's `update()` calls `frame()`, which calls `rd_frame()`.

Relevant behavior from `raddbg_core.c`:

- `rd_request_frame()` requests a small run of frames by setting `num_frames_requested = 4`.
- Event polling only blocks when no frames are requested:
  - `wm_get_events(..., rd_state->num_frames_requested == 0 && !DEV_always_refresh)`
- Target delta time starts from `wm_get_system_info()->default_refresh_rate`.
- After enough frame history, RAD snaps to plausible Hz candidates based on observed frame time:
  - active/default target, `60`, `75`, `120`, `144`, `165`, `240`, `360`
- RAD still has a TODO to maximize target rate across all windows/monitors, so we should not treat its refresh choice as perfect for mixed-monitor setups.

Important nuance: RAD's `update()` can be called from inside `WM_SIZE` / `WM_PAINT` while the top-level frame is already dispatching Win32 messages. `rd_state->frame_depth` prevents nested event polling, but rendering still happens. Anvil currently avoids recursive `core.run_step()` with `app->in_run_step`; that is safer for Lua, but skipped resize requests must be counted and followed by a final/latest-size frame.

### RAD D3D11 swapchain / resize path

Relevant behavior from `render_d3d11.c`:

- Device uses `D3D11_CREATE_DEVICE_BGRA_SUPPORT` and hardware-first, WARP fallback.
- DXGI max frame latency is set to `1` initially and then clamped by window count.
- Swapchain:
  - `CreateSwapChainForHwnd`
  - `DXGI_FORMAT_B8G8R8A8_UNORM`
  - `BufferCount = 2`
  - `DXGI_SWAP_EFFECT_FLIP_DISCARD`
  - `DXGI_SCALING_NONE`
  - width/height set to `0` at creation so DXGI uses the window size.
- Resize happens inside frame begin when client resolution changes:
  - release all size-dependent render targets/views,
  - release backbuffer RTV/backbuffer,
  - `ResizeBuffers(wnd->swapchain, 0, 0, 0, DXGI_FORMAT_UNKNOWN, 0)`,
  - reacquire backbuffer,
  - recreate RTVs and size-dependent targets,
  - clear framebuffers,
  - `ID3D11DeviceContext::Flush()` if a resize occurred.
- End frame:
  - draw final output into the swapchain backbuffer,
  - `Present(1, 0)`,
  - `ID3D11DeviceContext::ClearState()`.

The `ClearState()` after every present is important to keep in mind: it ensures the context is not holding references to old render targets before a future `ResizeBuffers`.

Additional RAD renderer details that may matter later but should not distract from live-resize basics:

- RAD uses `ID3D11Device1` / `ID3D11DeviceContext1` when available.
- The swapchain buffer is BGRA8 UNORM, but RAD creates the framebuffer RTV with `DXGI_FORMAT_B8G8R8A8_UNORM_SRGB`.
- RAD renders into size-dependent staging targets and then performs a final full-window draw into the swapchain backbuffer before presenting.
- These choices may affect visual output and general renderer architecture, but the immediate resize plan should first measure sleep/message/DXGI resize stalls.

## Current Anvil behavior and likely differences

### Win32 / SDL callback path

Current Anvil uses SDL3 main callbacks plus a Win32 subclass for the custom native frame.

`win32_frame_enable()` keeps the HWND as an overlapped/thick-frame window (`WS_CAPTION | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_SYSMENU`) and extends a tiny DWM frame into the client area. `WM_NCCALCSIZE` collapses the native caption/client calculation, and Anvil's `WM_NCHITTEST` computes resize/title-bar zones itself rather than first asking `DefWindowProc()` like RAD does.

In `src/win32_frame.c`:

- `WM_SIZE`:
  - delegates to SDL's old window proc,
  - calls `live_resize_frame()` when not minimized.
- `WM_PAINT`:
  - delegates to SDL's old window proc,
  - calls `live_resize_frame()`.
- `live_resize_frame()`:
  - calls `ren_resize_window()`;
  - invalidates `rencache`;
  - pushes a synthetic `SDL_EVENT_WINDOW_RESIZED` directly into Anvil's internal event queue;
  - calls `anvil_request_resize_frame()`.

Known differences from RAD:

- No explicit `WM_ENTERSIZEMOVE` / `WM_EXITSIZEMOVE` tracking.
- `WM_PAINT` is not owned RAD-style by Anvil; it delegates to SDL's proc first.
- The custom path can duplicate SDL-generated resize/expose events, because SDL's old proc may also produce SDL callbacks while `live_resize_frame()` pushes a synthetic resize event directly.
- `WM_SIZE` and `WM_PAINT` can both request frames for the same size.
- No resize-only `DwmFlush()` after the direct resize frame.

### C-side resize frame request

In `src/main.c`, `anvil_request_resize_frame()` currently:

- has no message reason or live-resize state;
- throttles with a hardcoded `SDL_NS_PER_SECOND / 120` interval;
- calls the full `app_run_step()` when the throttle allows it.

`SDL_AppEvent()` also calls `anvil_request_resize_frame()` for `SDL_EVENT_WINDOW_RESIZED`, `SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED`, `SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED`, and `SDL_EVENT_WINDOW_EXPOSED`, after pushing the event into Anvil's internal queue.

Important suspected jank source: `app_run_step()` calls Lua `core.run_step()`, and `core.run_step()` may explicitly sleep after drawing to enforce FPS. During modal live resize this can block the Win32 sizing loop in addition to the `Present(1, 0)` vsync wait.

### Lua run loop

In `data/core/init.lua`:

- A `resized` event sets `core.window_resizing_until = system.get_time() + 0.20`.
- `core.step()` draws immediately when `resizing` is true.
- However, `core.run_step()` still performs normal scheduling around that draw:
  - runs coroutine scheduling before event processing;
  - polls and processes all pending events;
  - after a redraw, computes `next_frame = max(0, 1 / core.fps - elapsed)`;
  - calls `system.sleep(min(..., next_frame, time_to_wake))`.

So Anvil already bypasses some draw skipping while resizing, but it does **not** currently have a no-sleep live-resize path comparable to RAD's direct `update()` path.

### Window-size / software-surface coupling

Even on the D3D11 command path, Anvil still uses a window-sized `SDL_Surface` as part of the renderer/cache model:

- `renderer.begin_frame()` calls `rencache_begin_frame()`.
- `rencache_begin_frame()` gets size from `rencache_get_surface()` / `ren_get_size()`.
- `RenWindow:get_size()` also returns the size of `cache.rensurface.surface`.
- `ren_resize_window()` calls `renwin_resize_surface()`.
- `renwin_resize_surface()` calls `init_surface()` when pixel size or scale changes.
- `init_surface()` destroys/recreates the window-sized `SDL_Surface`; in the D3D11 path it also makes sure SDL's renderer/texture fallback objects are not active.

This is a potentially important difference from RAD. RAD's D3D path queries the HWND client rect and resizes GPU resources; it does not recreate a full CPU window surface on every size tick. Anvil may be paying CPU allocation/free/cache-invalidation cost during resize before it even reaches `ResizeBuffers()`.

Also note the duplicate route: `live_resize_frame()` calls `ren_resize_window()` immediately, then the synthetic or SDL resize event later reaches `f_poll_event()`, which may call `ren_resize_window()` again. The second same-size call should usually be cheap, but the first size-change call can still recreate the surface.

### D3D11 resize path

In `src/d3d11_backend.c`:

- Swapchain creation is close to RAD:
  - flip-discard,
  - BGRA8,
  - 2 buffers,
  - `Present(1, 0)`,
  - max frame latency `1` when `IDXGIDevice1` is available.
- Differences / suspects:
  - swapchain creation uses explicit width/height instead of `0,0`;
  - `ResizeBuffers` uses explicit width/height instead of `0,0`;
  - resize occurs before `d3d11_stats_begin()`, so resize cost is not captured;
  - `d3d11_resize_window()` does not time release / `ResizeBuffers` / `GetBuffer` / RTV creation;
  - no context `Flush()` after resize;
  - no context `ClearState()` after present;
  - no explicit OM unbind before releasing RTV/backbuffer and calling `ResizeBuffers`.

The missing `ClearState()` / unbind is a high-priority suspect. D3D11/DXGI require all references to swapchain buffers to be released before `ResizeBuffers`; a bound RTV can be an indirect reference held by the immediate context. RAD avoids this by clearing state after present.

### Refresh-rate path

In Anvil:

- `RenWindow:get_refresh_rate()` queries `SDL_GetDisplayForWindow()` and then current/desktop display mode.
- `core.init()` sets `config.fps = DEFAULT_FPS`.
- `core.step()` updates `DEFAULT_FPS` / `config.fps` on `displaychanged` when `config.auto_fps` is true.
- `scalechanged` updates scale but does not currently refresh FPS.
- The C-side resize throttle does not use the window's display refresh rate.

This is probably acceptable for normal one-monitor startup, but it is incomplete for mixed-refresh monitor movement and live resize.

## Current best hypotheses, in priority order

These are not conclusions; they are the most likely things to instrument first.

1. **Lua sleep inside the modal resize path**
   - Direct Win32 resize frames call full `core.run_step()`.
   - `core.run_step()` may sleep after drawing.
   - That sleep blocks further `WM_SIZE` / `WM_PAINT` processing and can make the drag feel sticky.

2. **Window-sized CPU surface recreation during live resize**
   - The D3D11 command path still depends on `cache.rensurface.surface` for window size and fallback compatibility.
   - `renwin_resize_surface()` can destroy/recreate that full-size CPU surface on every pixel-size or scale change.
   - RAD's D3D path does not have this CPU-surface resize cost in its live-resize loop.

3. **D3D11 context holds the old RTV/backbuffer across frames**
   - Anvil does not `ClearState()` after present.
   - A resize can release app references but still leave context-held references.
   - `ResizeBuffers` may stall/fail or otherwise behave worse than RAD.

4. **Duplicate resize frame requests and stale sizes**
   - SDL old proc, `SDL_AppEvent`, `WM_SIZE`, `WM_PAINT`, and synthetic events can all request immediate resize frames.
   - Event coalescing is type-specific, so different resize-related event types can still accumulate.
   - `ren_resize_window()` can be reached from both the Win32 path and Lua event processing for the same latest size.

5. **Hardcoded 120 Hz throttle**
   - It is too low on 144/165/240 Hz displays.
   - It may be redundant when `Present(1,0)` is already pacing.
   - It is not tied to the active monitor.

6. **Window style / hit-test differences from RAD**
   - RAD lets `DefWindowProc()` own resize borders before custom title-bar hit testing.
   - RAD uses `WS_EX_NOREDIRECTIONBITMAP` for D3D windows and `CS_HREDRAW | CS_VREDRAW` on its class.
   - Anvil's HWND is SDL-created and its subclass returns resize hit-test codes manually.

7. **Missing RAD-style resize-only `DwmFlush()`**
   - RAD flushes DWM after resize/paint update.
   - Anvil has global opt-in `ANVIL_D3D11_DWM_FLUSH`, but not resize-only behavior.

8. **Resize resource recreation cost is hidden**
   - Stats currently start after D3D resize, so CSV data can under-report the cause of jank.
   - Stats also do not capture CPU surface resize/recreation cost.

## Non-goals

- Do not rewrite editor UI or public Lua drawing APIs.
- Do not optimize general text draw-call count in this plan unless it directly affects resize smoothness.
- Do not permanently enable `DwmFlush()` for all normal frames unless data proves it is needed.
- Do not remove software/SDL fallback paths.
- Do not remove the window-sized software surface until there is a fallback-safe replacement for APIs that still depend on it.
- Do not switch away from `Present(1,0)` unless a later, measured experiment proves it necessary.
- Do not introduce busy-spinning to get smoothness; prefer vsync / message cadence / no-extra-sleep.
- Do not change SDL-created HWND styles or paint ownership without an opt-in experiment and an easy rollback.

## Success criteria

A successful implementation should show:

- Smooth visual feedback while dragging borders/corners.
- No blank/stale client area during resize.
- No sticky feel caused by extra sleeps in the modal sizing loop.
- Normal frames still use the hardware D3D11 command path.
- No major regression in normal `cpu_ms` / `present_ms` stats.
- Resize stats show:
  - frame cadence close to active monitor refresh or a sensible divisor;
  - no unbounded queue of stale resize frames;
  - D3D resize resource recreation cost isolated and understandable;
  - CPU surface resize/recreation cost isolated and understandable;
  - no unexpected software/surface-upload fallback;
  - no repeated `ResizeBuffers` failures or device-loss churn.

## Stage 0: Baseline and reproducibility

Purpose: define exactly what is being measured before changing behavior.

### 0.1 Record environment for every manual capture

Capture:

- Windows version/build.
- GPU adapter name.
- Monitor refresh rates and which monitor the window is on.
- `ANVIL_RENDERER`, `ANVIL_D3D11_*` environment variables.
- Whether the app is maximized, restored, high-DPI, or crossing monitors.
- If possible, a screen recording of a 5-10 second resize drag.

### 0.2 Keep a RAD comparison note

When comparing against RAD, record:

- RAD commit/build date.
- Same monitor and similar window size.
- Whether RAD is on the same GPU.
- Subjective observation plus any profiler/screen-recording data available.

## Stage 1: Instrumentation before behavior changes

Purpose: determine whether jank comes from Lua scheduling/sleep, Win32 message cadence, CPU surface resizing, D3D resize, present blocking, or DWM synchronization.

### 1.1 Add live-resize/message counters

Add C-side stats for:

- `WM_ENTERSIZEMOVE` count/time;
- `WM_EXITSIZEMOVE` count/time;
- `WM_SIZE` count;
- `WM_PAINT` count;
- whether each message occurred while in live resize;
- client size and pixel size per message;
- calls to `live_resize_frame()`;
- calls to `anvil_request_resize_frame()`;
- calls skipped by throttle;
- calls skipped by same-size dedupe;
- calls skipped by reentrancy (`app->in_run_step`);
- whether a skipped reentrant request scheduled a final/latest-size frame;
- immediate-frame reason: `wm_size`, `wm_paint`, `sdl_resized`, `sdl_pixel_size`, `sdl_scale`, `sdl_exposed`, `exit_sizemove`.

Candidate files:

- `src/win32_frame.c`
- `src/main.c`

### 1.2 Measure C/Lua resize-frame duration and sleep

Add instrumentation around `app_run_step()` when called from resize paths:

- total `app_run_step()` duration;
- whether Lua returned after drawing or skipping;
- whether it happened inside live resize;
- time spent sleeping inside `core.run_step()`.

Lua-side timing candidates:

- `run_threads_ms`
- `poll_events_ms`
- `root_update_ms`
- `draw_ms`
- `post_draw_sleep_ms`
- `did_redraw`
- `resizing`
- `pending_event_count` if exposed cheaply
- `resize_immediate` / reason if C asked for an immediate frame
- `sleep_suppressed` for later immediate-mode experiments

Candidate file:

- `data/core/init.lua`

Keep this gated behind an env/config flag to avoid noisy normal runs.

### 1.3 Extend D3D11 stats for resize timing

Move/extend stats so a frame that resizes the swapchain includes the resize cost.

Add CSV columns, gated by existing `ANVIL_D3D11_STATS`:

- `frame_kind` (`commands`, `surface_upload`, maybe `resize_commands`);
- `live_resize`;
- `resize_done`;
- `resize_old_w`, `resize_old_h`, `resize_new_w`, `resize_new_h`;
- `resize_release_ms`;
- `resize_buffers_ms`;
- `resize_get_buffer_ms`;
- `resize_create_rtv_ms`;
- `resize_flush_ms`;
- `clear_state_ms`;
- `present_interval_ms`;
- `target_refresh_hz`;
- `sync_interval`;
- `swap_effect` and `buffer_count`;
- `resize_hr` separately from present `hr`.

Candidate file:

- `src/d3d11_backend.c`

### 1.4 Add refresh-rate diagnostics

Expose/log:

- `SDL_GetDisplayForWindow()` id/name;
- `SDL_GetWindowSize()` points and `SDL_GetWindowSizeInPixels()` pixels;
- current display mode refresh;
- desktop display mode refresh;
- fallback refresh;
- Lua `DEFAULT_FPS`, `config.fps`, and `core.fps`;
- C resize throttle target.

Candidate files:

- `src/api/renwindow.c`
- `src/main.c`
- `data/core/init.lua`

### 1.5 Measure software-surface and command-cache resize churn

Add stats around `ren_resize_window()` / `renwin_resize_surface()` / `init_surface()`:

- old/new window point size and pixel size;
- old/new surface dimensions and scale;
- whether a new `SDL_Surface` was created;
- time to query SDL size/scale;
- time to destroy old surface and forget D3D11 cached surface;
- time to `SDL_CreateSurface()`;
- time spent in `setup_renderer()`;
- whether D3D11 command mode was active;
- number of `ren_resize_window()` calls per immediate resize frame;
- whether the resize originated from Win32 `live_resize_frame()` or Lua `f_poll_event()`.

Candidate files:

- `src/renwindow.c`
- `src/renderer.c`
- `src/api/system.c`
- `src/win32_frame.c`

If this cost is significant, plan a later D3D-only decoupling experiment instead of assuming DXGI is the bottleneck.

### 1.6 Manual resize capture procedure

Launch portable Anvil with something like:

```text
ANVIL_RENDERER=d3d11
ANVIL_D3D11_STATS=1
ANVIL_D3D11_STATS_FILE=...
ANVIL_D3D11_STATS_FLUSH=1
```

Then:

1. Open a normal source file.
2. Let the app idle for 2 seconds.
3. Drag the right border continuously for 5-10 seconds.
4. Drag a corner continuously for 5-10 seconds.
5. Maximize/restore a few times.
6. If multiple monitors exist, move the window between monitors and repeat.
7. Close Anvil cleanly.
8. Analyze stats and, if available, screen recording.

Optional later: automate resize using a Win32 `SetWindowPos` loop, but manual drag remains the most representative test because it exercises Windows' modal sizing loop.

## Stage 2: Match RAD live-resize control flow

Purpose: make Anvil's Win32 behavior structurally closer to RAD while respecting SDL subclass constraints.

### 2.1 Track `WM_ENTERSIZEMOVE` / `WM_EXITSIZEMOVE`

In `src/win32_frame.c`:

- add live-resize boolean state to `Win32FrameData` or app state;
- set true on `WM_ENTERSIZEMOVE`;
- set false on `WM_EXITSIZEMOVE`;
- request one final frame on exit sizing;
- expose this state to `src/main.c` and optionally Lua.

Use the state to distinguish:

- live border/corner drag;
- programmatic resize;
- maximize/restore;
- expose/paint without live sizing.

### 2.2 Decide ownership of `WM_PAINT`

Current code delegates `WM_PAINT` to SDL's old proc and then renders. RAD owns paint with `BeginPaint` / `EndPaint` around `update()`.

Plan an experiment after instrumentation:

- Current behavior: call old SDL proc first, then render.
- RAD-like behavior: `BeginPaint`, render, `EndPaint`, optionally skip old proc for `WM_PAINT`.
- Hybrid behavior: call old proc only for messages where SDL state must update, but own actual paint validation.

Acceptance conditions:

- no broken SDL window state;
- no infinite paint loop;
- no missing expose events;
- less stale/blank area during resize.

### 2.3 Avoid duplicate resize frames

Introduce a resize-frame serial/generation concept before changing pacing:

- Record the latest requested pixel size.
- If another request is for the same size and a resize frame already ran for that size, skip it unless it is `WM_PAINT` after invalidation.
- Coalesce across related event types (`RESIZED`, `PIXEL_SIZE_CHANGED`, `DISPLAY_SCALE_CHANGED`) when they refer to the same window and same latest pixel size.
- Make only one source responsible for the immediate frame during a Win32 live resize. Prefer the Win32 modal path; SDL events should update Lua state but not trigger duplicate direct renders for the same size.

Candidate files:

- `src/win32_frame.c`
- `src/main.c`
- `src/system_events.c`

### 2.4 Inspect native border, hit-test, and HWND style parity

Do not change these first, but log and compare them against RAD:

- `GetWindowLongPtr(GWL_STYLE)` and `GetWindowLongPtr(GWL_EXSTYLE)`;
- class styles from `GetClassLongPtr(GCL_STYLE)` if available;
- whether `WS_EX_NOREDIRECTIONBITMAP` is present or can safely be applied to SDL-created D3D windows;
- actual `WM_NCHITTEST` result for each resize edge/corner;
- whether `DefWindowProc()` would return the same resize hit-test result before Anvil's custom hit-test override;
- cursor changes while in `WM_ENTERSIZEMOVE` / `WM_EXITSIZEMOVE`.

Possible later experiments, only after instrumentation:

- Let `DefWindowProc()` handle native resize-border hit tests first, similar to RAD, and only override title-bar/client regions.
- Try `WS_EX_NOREDIRECTIONBITMAP` for the D3D11 portable build if it can be applied safely and does not break SDL/DWM behavior.
- Avoid app cursor updates during live sizing if they are fighting the OS resize cursor.

## Stage 3: Add a no-extra-sleep live-resize frame path

Purpose: avoid normal idle/FPS sleeps blocking the Win32 modal sizing loop.

This should be treated as a high-priority behavior experiment after Stage 1 confirms sleep time is non-trivial.

### 3.1 Add a way for C to call Lua in immediate mode

Options:

- Add `core.run_step({ immediate = true, reason = "live_resize" })`.
- Add a dedicated `core.run_resize_step()`.
- Add a C-visible Lua flag around the call, such as `core.in_live_resize_frame`.

The immediate path should:

- process pending resize/display/input events needed for correct layout;
- update root view size;
- draw immediately if needed;
- avoid post-draw `system.sleep()`;
- avoid long coroutine/background work during modal resize unless required;
- preferably process resize/display events before coroutine work for the immediate frame;
- preserve error handling and restart/quit behavior.

### 3.2 Keep the normal run loop unchanged for normal frames

Normal `SDL_AppIterate()` should keep the existing sleep/FPS behavior unless later data says otherwise.

Resize immediate mode should be active only for:

- live `WM_SIZE` / `WM_PAINT` while in `WM_ENTERSIZEMOVE` state;
- possibly `WM_EXITSIZEMOVE` final frame;
- optionally expose/paint when no normal iterate is expected soon.

### 3.3 Avoid reentrancy

Current `app->in_run_step` prevents recursive entry by returning early.

For resize work, explicitly record:

- attempted recursive resize frames;
- skipped recursive frames;
- whether a final frame is requested after the current one exits.

Do not allow nested D3D frames.

### 3.4 Disable or reset non-essential animations during live resize if measured

RAD explicitly resets panel layout animation when the window size changes (`window_is_resizing` participates in the reset condition). Anvil has general transitions in `data/core/view.lua` and bundled defaults enable smooth scrolling/transitions. These can keep requesting redraws and can make layout feel like it is chasing the resize.

Plan an experiment only if instrumentation shows animation/update work is visible during resize:

- expose a short-lived `core.live_resizing` / `core.in_live_resize_frame` flag;
- have layout/scroll transitions jump to their target or reset their move data while true;
- avoid changing normal scrolling feel outside live resize;
- measure `core.redraw` requests caused by transitions during resize.

## Stage 4: Refresh-rate-correct resize pacing

Purpose: remove the fixed 120 Hz assumption and align live-resize cadence with the active display and vsync.

### 4.1 Replace hardcoded resize throttle

Current code:

```c
const Uint64 min_interval = SDL_NS_PER_SECOND / 120;
```

Replace only after instrumentation with:

- active window display refresh if available;
- keep refresh as a float where possible (`59.94`, `143.98`, etc.) instead of rounding too early;
- fallback to Lua `config.fps` / `DEFAULT_FPS` if safely accessible;
- fallback to 60 Hz.

Prefer a C-side query for live resize because the modal Win32 path should not depend on a Lua value that may be stale. If SDL's display-for-window result appears stale during a drag, compare it with a Win32 `MonitorFromWindow()` / `EnumDisplaySettings()` query in diagnostics before changing policy.

### 4.2 Consider letting vsync be the primary throttle

Because the D3D11 path uses `Present(1,0)`, present should already block to the compositor/monitor cadence.

Possible policy:

- During true live resize, render latest size immediately unless a frame is already in progress.
- Use a small dedupe/debounce only to skip duplicate same-size requests.
- Let `Present(1,0)` pace the loop.
- Keep a safety cap based on active refresh for pathological message floods.

Measure this against explicit Hz throttling. Do not use `Present(0, ...)` / tearing as the default smoothness fix; windowed editor UI should first match RAD's vsynced `Present(1,0)` behavior.

### 4.3 Refresh-rate update on monitor movement

Investigate current SDL events:

- `SDL_EVENT_WINDOW_DISPLAY_CHANGED`
- `SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED`
- `SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED`
- window move events if enabled/available in this SDL version

Potential fix:

- `core.window:get_refresh_rate()` already queries `SDL_GetDisplayForWindow`; keep that.
- On display/scale/pixel-size/window-move related events, refresh `DEFAULT_FPS` and `config.fps` when `config.auto_fps` is true.
- C resize throttle should query the display directly and not wait for Lua to update.

### 4.4 RAD-style target-Hz snap policy later

After resize is smooth and measured, consider a simpler version of RAD's adaptive target Hz:

- start with active display refresh;
- maintain a frame-time history;
- if render+present cannot keep up for N frames, snap down to a candidate <= display Hz;
- candidates: display Hz, `60`, `75`, `120`, `144`, `165`, `240`, `360`.

Do not implement this before fixing the basic live-resize path.

## Stage 5: D3D11 resize-resource handling

Purpose: make Anvil's D3D11 resize behavior closer to RAD and DXGI best practices.

### 5.1 Unbind or clear D3D11 context state before `ResizeBuffers`

RAD calls `ClearState()` after every present. Anvil currently does not.

Experiments to plan:

1. RAD-style: call `ClearState()` after every successful command-frame present.
2. Resize-only: before releasing RTV/backbuffer and `ResizeBuffers`, call:
   - `OMSetRenderTargets(0, NULL, NULL)` and possibly unbind SRVs;
   - optionally `ClearState()`.
3. Measure overhead and resize reliability for both.

This should be one of the first D3D behavior experiments after instrumentation because it may affect correctness, not just smoothness.

### 5.2 Time and log `ResizeBuffers`

In `src/d3d11_backend.c`, measure separately:

- unbind/clear-state time;
- release old RTV/backbuffer time;
- `ResizeBuffers` time;
- `GetBuffer` time;
- `CreateRenderTargetView` time;
- optional resize `Flush()` time.

### 5.3 Add resize `Flush()` experiment

RAD flushes the D3D context after resize-dependent resource creation and clear.

Add opt-in first:

```text
ANVIL_D3D11_RESIZE_FLUSH=1
```

Then test during live resize. If beneficial and low-risk, consider enabling by default only when resize happened.

### 5.4 Validate swapchain size policy

RAD uses `0,0` for swapchain creation and `ResizeBuffers`, letting DXGI infer HWND size.

Anvil currently uses explicit pixel width/height from SDL's surface/window pixel size. That should be valid, but test both policies if resize stats still look bad:

- explicit pixel dimensions;
- `0,0` inferred dimensions.

Keep high-DPI behavior correct: swapchain dimensions must match pixel size, not logical point size.

### 5.5 Ensure every resize frame redraws the full client area

Flip-discard does not preserve backbuffer contents.

The command renderer clears and redraws commands every frame; verify stats/screenshots show:

- no dirty-rect-only swapchain update in normal D3D command frames;
- no accidental surface-upload fallback during normal UI;
- no partial redraw gaps after `ResizeBuffers`.

### 5.6 Decouple D3D command frames from window-sized CPU surface if measured

If Stage 1 shows `SDL_Surface` recreation is a major resize cost, plan a fallback-safe refactor:

- Keep the software surface for software/SDL fallback and APIs that need CPU pixels.
- In D3D11 command mode, let window size come from `SDL_GetWindowSizeInPixels()` or a cached pixel-size field, not from a freshly recreated window-sized surface.
- Avoid recreating the full CPU surface on every live-resize tick when the D3D command path is active.
- Recreate the CPU surface lazily only if the software fallback path is used or an API needs the window surface.
- Keep canvases/glyph atlas surfaces intact; the concern is the main window-sized backing surface, not all CPU surfaces.
- Preserve high-DPI behavior and `RenWindow:get_size()` semantics in pixels.

This should be a separate experiment from DXGI `ResizeBuffers` work so the data says which resize cost mattered.

## Stage 6: Resize-only `DwmFlush()` experiment

Purpose: test RAD's explicit DWM sync in the same narrow context where RAD uses it.

RAD calls `DwmFlush()` after `update()` in `WM_SIZE` / `WM_PAINT`.

Do **not** use the existing global `ANVIL_D3D11_DWM_FLUSH` as the default solution; that affects all frames and was intentionally made opt-in.

Add a separate experiment:

```text
ANVIL_D3D11_RESIZE_DWM_FLUSH=1
```

Measure:

- live resize with no DWM flush;
- live resize with resize-only DWM flush;
- normal idle/scrolling unchanged.

Track `dwm_flush_ms` separately from `present_ms`. If beneficial, consider enabling only during live resize / paint, not for normal frames. Prefer calling it from the Win32 resize/paint path after the immediate frame, matching RAD's scope, rather than hiding it inside every D3D present.

## Stage 7: Event queue and stale-size cleanup

Purpose: keep Lua's event state correct without forcing it to process stale resize history.

Current `system_push_event()` coalesces same-type resize events for the same window. Improve plan if stats show stale events:

- Coalesce all resize-related event types for the same window into a latest resize state where safe.
- Preserve semantic events that Lua needs (`displaychanged`, scale changes), but avoid multiple direct renders for the same final size.
- Track maximum queue depth during resize and count dropped events.
- Consider exposing pending-event count and latest resize serial for diagnostics.
- Ensure `core.window_resizing_until` is set by real resize events but does not remain the only source of live-resize truth.
- Consider a special latest-size slot for resize events so Lua sees the final size without replaying every intermediate size.

## Stage 8: Test matrix and acceptance

Run each with stats enabled.

### 8.1 Normal behavior

1. Normal idle with one file open.
2. Fast text scrolling.
3. Command palette open/close.
4. Typing in a normal file.
5. App loses/regains focus.

### 8.2 Resize behavior

1. Horizontal resize drag for 10 seconds.
2. Vertical resize drag for 10 seconds.
3. Corner resize drag for 10 seconds.
4. Resize very small then large.
5. Maximize/restore repeatedly.
6. Resize while command palette or other overlay is visible.

### 8.3 Monitor/DPI behavior

1. Resize on primary monitor.
2. Resize on high-refresh monitor.
3. Resize on 60 Hz monitor.
4. Move between monitors, then resize.
5. High-DPI / scaled display if available.

### 8.4 Metrics to compare

For normal frames:

- `cpu_ms`
- `present_ms`
- `dwm_flush_ms`
- `draw_calls`
- `maps`
- `quad_instances`
- hardware vs WARP
- command path vs surface-upload path

For resize frames:

- frame interval distribution;
- resize message cadence;
- skipped duplicate same-size frames;
- skipped throttle frames;
- skipped reentrant frames and final-frame recovery;
- `app_run_step()` duration;
- Lua `run_threads_ms`, event-poll time, draw time, and post-draw sleep duration;
- `ren_resize_window_ms` / `surface_recreate_ms`;
- number of main window `SDL_Surface` recreations;
- `ResizeBuffers` timing;
- `present_ms`;
- optional `resize_flush_ms`;
- optional `dwm_flush_ms`;
- number of stale/duplicate size frames;
- max internal event queue depth.

## Stage 9: Rollout and rollback strategy

Each stage should be its own commit:

1. instrumentation only;
2. live-resize state and final-frame request;
3. no-extra-sleep resize path;
4. duplicate/stale resize request cleanup;
5. CPU surface resize/recreation instrumentation and, if justified, D3D-only decoupling experiment;
6. D3D11 context unbind/ClearState experiment;
7. D3D11 resize flush/timing;
8. refresh-rate-based resize pacing;
9. resize-only `DwmFlush()` experiment;
10. optional Win32 style/hit-test parity experiment;
11. optional RAD-style adaptive Hz.

Do not combine instrumentation changes with behavior changes. Keep environment flags for experiments until the data justifies defaults.

## Open questions

- How much time does `core.run_step()` sleep when called from `WM_SIZE` / `WM_PAINT`?
- How much time is spent running Lua coroutines before resize-event processing in an immediate resize frame?
- How often is the main window `SDL_Surface` recreated during a live resize, and how expensive is it?
- Can the D3D command path safely get window size without forcing immediate main-surface recreation?
- Does `ResizeBuffers` ever stall or fail because the context still has a bound RTV/backbuffer?
- Does adding `ClearState()` after present have measurable normal-frame overhead in Anvil?
- Is the biggest visible jank from Lua scheduling, explicit sleep, CPU surface recreation, `ResizeBuffers`, `Present(1,0)`, DWM, or duplicate message cadence?
- Does `DwmFlush()` improve Anvil live resize like RAD, or does it add too much latency with SDL3/window integration?
- Does `core.window:get_refresh_rate()` report the correct monitor while dragging across displays?
- Is hardcoded 120 Hz below the user's active monitor refresh?
- Does SDL's old window proc need to see `WM_PAINT` for internal state, or can Anvil own paint like RAD?
- Would letting `DefWindowProc()` handle resize-border hit tests first improve native resize feel?
- Can `WS_EX_NOREDIRECTIONBITMAP` be used with SDL-created D3D11 windows without regressions?

## Immediate next action

Start with Stage 1 instrumentation, especially:

1. resize-frame `app_run_step()` duration and Lua post-draw sleep time;
2. `ren_resize_window()` / `SDL_Surface` recreation timing;
3. D3D11 resize timing and `ResizeBuffers` result;
4. message/request duplication and queue-depth counts.

Then run the manual resize capture. Do not change runtime behavior until the stats identify the primary bottleneck.
