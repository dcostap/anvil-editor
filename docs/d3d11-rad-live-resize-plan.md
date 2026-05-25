# RAD-style live resize and refresh pacing plan

Goal: make Anvil window resizing and frame pacing feel closer to RAD Debugger on Windows, while keeping normal editor behavior stable and measurable.

This plan is based on the current Anvil code and the checked RAD Debugger counterparts:

- RAD Win32 windowing: `raddebugger/src/win32/window_manager/win32_window_manager.c`
- RAD D3D11 renderer: `raddebugger/src/render/d3d11/render_d3d11.c`
- RAD frame pacing: `raddebugger/src/raddbg/raddbg_core.c`

## RAD observations to mirror carefully

RAD does the following relevant things:

1. Tracks live sizing explicitly:
   - `WM_ENTERSIZEMOVE` sets `w32_wm_resizing = 1`
   - `WM_EXITSIZEMOVE` sets `w32_wm_resizing = 0`

2. Handles resize/paint by rendering directly from the Win32 window proc:
   - `WM_SIZE` / `WM_PAINT` call `update()`
   - then `DwmFlush()`

3. Resizes D3D11 swapchain resources inside frame begin when client resolution changes:
   - releases size-dependent resources
   - calls `ResizeBuffers`
   - recreates render target views and other size-dependent targets
   - calls D3D context `Flush()` when resize occurred

4. Presents with vsync:
   - `Present(1, 0)`

5. Sets DXGI max frame latency:
   - initially `SetMaximumFrameLatency(1)`
   - later clamps by window count

6. Chooses a target frame rate from default display refresh and measured frame history:
   - starts from `wm_get_system_info()->default_refresh_rate`
   - snaps to candidates like 60/75/120/144/165/240/360 Hz when appropriate
   - RAD still has a TODO for fully maximizing target rate across all windows/monitors, so we should not over-assume perfection here.

## Current Anvil suspects

Relevant Anvil files:

- `src/win32_frame.c`
- `src/main.c`
- `src/d3d11_backend.c`
- `src/api/renwindow.c`
- `src/api/system.c`
- `src/system_events.c`
- `data/core/init.lua`
- `data/core/config.lua`

Known differences / likely issues:

- Live resize is not explicitly tracked with `WM_ENTERSIZEMOVE` / `WM_EXITSIZEMOVE`.
- `anvil_request_resize_frame()` throttles resize frames with a hardcoded `120 Hz` interval.
- Normal Lua frame pacing uses `config.fps`, but the C-side resize callback path has its own pacing behavior.
- Normal D3D11 `DwmFlush()` is intentionally off by default; RAD uses `DwmFlush()` specifically in `WM_SIZE` / `WM_PAINT`.
- D3D11 resize path does not currently have explicit per-resize timing instrumentation and may not flush after `ResizeBuffers` like RAD.
- Refresh-rate updates may depend on SDL window display events, which may not be sufficient for mixed-refresh monitor movement.

## Non-goals

- Do not rewrite editor UI or Lua drawing APIs.
- Do not optimize general text draw-call count in this plan unless it directly affects resize smoothness.
- Do not permanently enable `DwmFlush()` for all normal frames unless data proves it is needed.
- Do not remove software/SDL fallback paths.

## Success criteria

A successful implementation should show:

- Smooth visual feedback while dragging window borders/corners.
- No blank/stale client area during resize.
- Normal frames still use hardware D3D11 command path.
- No major regression in normal `cpu_ms` / `present_ms` stats.
- Resize stats show:
  - resize frame cadence close to monitor refresh or a sensible divisor,
  - no unbounded queue of stale resize frames,
  - resize resource recreation cost isolated and understandable,
  - no unexpected software/surface-upload fallback.

## Stage 1: Instrumentation before behavior changes

Purpose: establish where resize jank comes from before changing pacing.

### 1.1 Add live-resize state counters/logging

Add C-side stats for:

- normal frame vs live-resize frame
- `WM_ENTERSIZEMOVE` count/time
- `WM_EXITSIZEMOVE` count/time
- `WM_SIZE` count during live resize
- `WM_PAINT` count during live resize
- calls to `anvil_request_resize_frame()`
- calls skipped by resize throttle

Candidate files:

- `src/win32_frame.c`
- `src/main.c`

### 1.2 Extend D3D11 stats for resize timing

Add columns to D3D11 stats CSV, gated by existing `ANVIL_D3D11_STATS`:

- `frame_kind` or `live_resize`
- `resize_buffers_ms`
- `resize_resource_ms`
- `resize_flush_ms`
- `resize_done`
- `target_refresh_hz`
- `frame_interval_ms`

Candidate file:

- `src/d3d11_backend.c`

### 1.3 Add refresh-rate diagnostics

Expose/log:

- current SDL display for the window
- reported refresh rate from `SDL_GetCurrentDisplayMode`
- fallback desktop refresh rate
- Lua `config.fps`
- Lua `core.fps`

Candidate files:

- `src/api/renwindow.c`
- `data/core/init.lua`
- smoke/manual stats script

### 1.4 Manual resize test harness

Add a script or documented manual procedure to launch portable Anvil with:

```text
ANVIL_RENDERER=d3d11
ANVIL_D3D11_STATS=1
ANVIL_D3D11_STATS_FILE=...
ANVIL_D3D11_STATS_FLUSH=1
```

Then instruct user to:

1. Resize continuously for 5-10 seconds.
2. Move window between monitors if applicable.
3. Close Anvil cleanly.
4. Analyze stats.

Optional later: automate resize using Win32 `SetWindowPos` in a loop, but manual drag is more representative of Windows modal sizing.

## Stage 2: Match RAD live-resize control flow

Purpose: make Anvil's Win32 frame behavior structurally closer to RAD.

### 2.1 Track `WM_ENTERSIZEMOVE` / `WM_EXITSIZEMOVE`

In `src/win32_frame.c`:

- add live-resize boolean state to `Win32FrameData` or global/app state
- set true on `WM_ENTERSIZEMOVE`
- set false on `WM_EXITSIZEMOVE`
- request one final frame on exit sizing

Expose this state to `src/main.c` so `anvil_request_resize_frame()` knows whether this is a resize-driven frame.

### 2.2 Direct resize/paint update path

Current path already calls `live_resize_frame()` from `WM_SIZE` / `WM_PAINT`, but verify it is semantically close to RAD:

```text
WM_SIZE/WM_PAINT
  ren_resize_window
  invalidate rencache
  push resize event
  request frame
```

Potential improvements:

- ensure only the latest size is rendered
- avoid duplicated frame requests from both `WM_SIZE` and `WM_PAINT` for the same size
- avoid recursive/in-flight frame calls
- ensure `BeginPaint` / `EndPaint` handling remains correct when processing `WM_PAINT`

### 2.3 Add resize-only `DwmFlush()` experiment

RAD calls `DwmFlush()` after `update()` in `WM_SIZE` / `WM_PAINT`.

Implement an opt-in first:

```text
ANVIL_D3D11_RESIZE_DWM_FLUSH=1
```

Then test:

- normal frames without resize: no DwmFlush
- live resize frames with flag: DwmFlush after present or after resize frame request path

If it clearly improves smoothness without bad cost, consider enabling it only during live resize by default.

## Stage 3: Refresh-rate-correct resize pacing

Purpose: remove hardcoded 120 Hz resize pacing and tie it to the active window/display.

### 3.1 Replace hardcoded resize throttle

Current `src/main.c` uses:

```c
const Uint64 min_interval = SDL_NS_PER_SECOND / 120;
```

Replace with:

- current window refresh rate if available
- fallback to `DEFAULT_FPS` / `config.fps` equivalent if accessible
- fallback to 60 Hz

Need careful C/Lua boundary decision:

Option A: C-only refresh query through SDL APIs.

Option B: Lua provides current `config.fps` to C.

Prefer A for live-resize responsiveness because this code runs inside Win32 callback/modal sizing.

### 3.2 Refresh-rate update on monitor movement

Investigate current SDL events:

- `SDL_EVENT_WINDOW_DISPLAY_CHANGED`
- `SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED`
- `SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED`

Ensure Anvil updates `DEFAULT_FPS` / `config.fps` when active display changes, not only when primary display changes.

Potential fix:

- `core.window:get_refresh_rate()` should always query `SDL_GetDisplayForWindow`.
- On display/pixel-scale/window-move related events, refresh `DEFAULT_FPS` and `config.fps` if `auto_fps` is true.

### 3.3 RAD-style target-Hz snap policy

RAD adapts target Hz based on measured frame time history and candidate refresh rates.

Consider a simpler Anvil version:

- target = active display refresh
- if observed render+present frame time cannot keep up for N frames, snap down to nearest divisor/candidate
- candidates: display Hz, 60, 75, 120, 144, 165, 240, 360

This should be a later refinement after basic live resize improves.

## Stage 4: D3D11 resize-resource handling

Purpose: match RAD's resize-side GPU behavior and measure cost.

### 4.1 Add ResizeBuffers timing

In `src/d3d11_backend.c` around `d3d11_resize_window()`:

Measure separately:

- release old RTV/backbuffer
- `ResizeBuffers`
- `GetBuffer`
- `CreateRenderTargetView`

Write to stats when resize happened.

### 4.2 Flush D3D context after resize

RAD calls `Flush()` after resize-dependent resource creation.

Add an opt-in experiment:

```text
ANVIL_D3D11_RESIZE_FLUSH=1
```

Then test during live resize. If beneficial and low-risk, enable by default only after resize.

### 4.3 Ensure no stale backbuffer assumptions

Flip-discard swapchains do not preserve contents. Confirm every resize frame clears and redraws full client area.

Already expected for command renderer, but stats/screenshots should confirm no fallback or partial redraw gaps.

## Stage 5: Lua run-loop specialization for live resize

Purpose: avoid normal idle/sleep scheduling interfering with live resize frames.

### 5.1 Audit current `core.run_step()` during resize

Current Lua has:

```lua
local resizing = core.window_resizing_until and core.window_resizing_until > system.get_time()
...
if uncapped or resizing or priority_event or next_frame_time < system.get_time() then
  core.root_view:update()
end
...
if not uncapped and not resizing and ... then return false end
```

So resizing already bypasses some frame skipping. But `core.run_step()` still includes:

- coroutine scheduling
- event polling
- sleep decisions
- redraw scheduling

Measure if this is causing delay during live resize.

### 5.2 Add a dedicated resize step if needed

If instrumentation shows Lua scheduler overhead or sleeps during resize, add:

```lua
core.run_resize_step()
```

It should:

- poll/process pending resize/display/input events minimally
- update root view size
- draw immediately
- avoid normal sleeps
- avoid background coroutine work unless necessary

C-side live resize can call this instead of full `core.run_step()`.

### 5.3 Avoid reentrancy

Ensure resize callbacks cannot recursively enter rendering while a frame is already in progress.

Existing `app->in_run_step` helps. Extend or split for resize path if needed.

## Stage 6: Test matrix and acceptance

### 6.1 Test cases

Run each with stats:

1. Normal idle with one file open.
2. Fast text scrolling.
3. Horizontal resize drag for 10 seconds.
4. Corner resize drag for 10 seconds.
5. Maximize/restore.
6. Move between monitors, if multiple monitors exist.
7. Resize on high-refresh monitor.
8. Resize on 60 Hz monitor.

### 6.2 Metrics to compare

For normal frames:

- `cpu_ms`
- `present_ms`
- `draw_calls`
- `maps`
- `quad_instances`
- hardware path / success count

For resize frames:

- live resize frame intervals
- frames skipped by throttle
- `resize_buffers_ms`
- `present_ms`
- optional `dwm_flush_ms`
- number of stale/duplicate size frames

### 6.3 Rollback strategy

Each stage should be its own commit:

1. instrumentation only
2. Win32 enter/exit sizing state
3. resize-only DwmFlush experiment
4. refresh-rate pacing
5. D3D resize flush/timing
6. Lua resize-step if needed

Do not combine behavior changes with instrumentation changes.

## Open questions

- Does `DwmFlush()` improve Anvil live resize like RAD, or does it add too much latency with SDL3/window integration?
- Is the biggest jank from Present blocking, Lua scheduling, `ResizeBuffers`, or Win32 message cadence?
- Does SDL3 callback mode impose constraints RAD does not have because RAD owns its Win32 loop directly?
- Is hardcoded 120 Hz resize pacing currently below the user's monitor refresh?
- Does `core.window:get_refresh_rate()` report the correct monitor while dragging across displays?

## Immediate next action

Start with Stage 1 instrumentation, then run a manual resize stats capture. Do not change runtime behavior until the stats identify the primary bottleneck.
