# RAD-style frame pacing and high-refresh smoothness plan

Goal: refactor Anvil's frame scheduling so normal editing, scrolling, cursor motion, and UI transitions are paced like RAD Debugger: request frames while work/animation is active, let vsynced presentation be the real limiter, block/sleep only when idle, and track the window's current monitor refresh rate reliably.

This plan focuses on normal high-refresh smoothness. It complements:

- `docs/d3d11-rad-renderer-plan.md` for the D3D11 command renderer;
- `docs/d3d11-rad-live-resize-plan.md` for live resize behavior.

## Desired end state

On a 120/144/165/240 Hz monitor, Anvil should:

1. render active UI motion at the monitor refresh rate whenever CPU/GPU work fits within the frame;
2. avoid post-present sleep jitter and avoid double-throttling after `Present(1, 0)`;
3. keep animations time-consistent across refresh rates;
4. automatically update its target timing when the window moves between monitors;
5. idle efficiently without continuously redrawing;
6. degrade gracefully under real load without permanently lowering animation smoothness due to vsync wait being counted as CPU render cost.

## RAD reference model

RAD Debugger's relevant behavior:

- Native Win32 + D3D11.
- Flip-model swapchain, two buffers, `DXGI_SWAP_EFFECT_FLIP_DISCARD`.
- D3D11 max frame latency set to 1.
- Every normal rendered window ends in `Present(1, 0)`.
- Frame requests are counted, not continuously spun forever:

  ```c
  rd_request_frame(void) {
    rd_state->num_frames_requested = 4;
  }
  ```

- OS events are drained nonblocking while frames are requested, and blocking wait is used only when no frames are requested:

  ```c
  wm_get_events(..., rd_state->num_frames_requested == 0 && !DEV_always_refresh);
  ```

- Animations request more frames while they are not settled.
- Refresh rate is used as an animation timestep target and budgeting hint, not as a second post-present sleep limiter.

Important nuance: RAD's refresh source is not the part to copy literally. RAD mostly starts from a system/default refresh rate and snaps based on measured frame history; it is not perfect current-monitor tracking code. Anvil can and should do better by querying the SDL window's current display. The part to copy is the pacing principle: **vsynced present is the active-frame clock; event waiting is the idle clock.**

## Current Anvil behavior and problems

### Current relevant code

- Main app uses SDL3 callbacks:
  - `src/main.c`: `SDL_AppEvent()` queues events, `SDL_AppIterate()` calls `core.run_step()`.
- Lua run-loop has an FPS cap and adaptive downshift:
  - `data/core/init.lua`: `core.step()` measures time around `renderer.begin_frame()` / `renderer.end_frame()`.
  - `data/core/init.lua`: `core.run_step()` sleeps with `system.sleep()` after redraws and while waiting.
- `system.sleep()` is `SDL_Delay()`:
  - `src/api/system.c`.
- D3D11 path is already mostly RAD-like:
  - max frame latency 1;
  - flip-discard swapchain;
  - normal `Present(1, 0)`;
  - `ClearState()` after present.

### Primary issue: double throttling

`renderer.end_frame()` reaches D3D11 `Present()`. With sync interval 1, `Present()` can block until vsync. Lua measures that whole duration as `rendering_speed`, then applies adaptive FPS logic:

- if `rendering_speed * config.fps >= 1` for enough frames, Anvil lowers `core.fps`;
- `core.run_step()` then sleeps to the new lower `core.fps`.

On a 144 Hz monitor, the frame budget is ~6.94 ms. If `Present(1)` blocks ~6.9 ms and CPU work adds even a small amount, Lua thinks the frame missed budget and can reduce `core.fps`. That creates visible below-refresh pacing even though D3D vsync was already doing the right thing.

### Secondary issues

1. **Post-present `SDL_Delay()` jitter**
   - Even if the computed sleep is small, `SDL_Delay()` has scheduling granularity and can overshoot.
   - After a vsynced present, sleeping again is unnecessary during active motion.

2. **Refresh-rate updates are incomplete**
   - Anvil already does one thing better than RAD's simple default-display starting point: it can query the refresh from the actual SDL window display.
   - But it currently rounds refresh values, re-queries only after window creation and on display/scale changes, and does not route `SDL_EVENT_WINDOW_MOVED`.
   - Movement between mixed-refresh monitors may therefore leave stale timing until another display event arrives.

3. **`core.fps` mixes target timing and measured throughput**
   - `core.fps` is used by animation code as a timestep/factor.
   - Adaptive lowering of `core.fps` changes animation behavior and smoothness, even when the only "slow" part was vsync wait.

4. **Frame requests are implicit**
   - `core.redraw`, `run_next_step`, event presence, coroutine wake times, and animation code all interact indirectly.
   - RAD has a clearer model: request a small burst while motion is active; block when no frame is requested.

5. **SDL callback mode complicates true blocking waits**
   - RAD can call `GetMessage()` directly.
   - In SDL callback mode, Anvil cannot simply block in `SDL_WaitEvent()` inside `SDL_AppIterate()`; events are delivered through `SDL_AppEvent()`.
   - The first refactor should still work in callback mode, but the plan should leave room for a later explicit desktop event loop if idle latency/CPU cannot be made ideal.

## Design principles

1. **D3D/vsync first**
   - Normal D3D frames use `Present(1, 0)`.
   - Do not add a Lua sleep after a frame if the renderer is present-paced and active frames remain.

2. **Request frames explicitly**
   - Input, animation, blinking, and async results request future frames.
   - Each successful redraw consumes one requested frame unless more are requested during that frame.

3. **Separate target timing from throughput**
   - `config.fps` / monitor Hz is the desired animation/display target.
   - Actual CPU/GPU throughput is diagnostic and budget information.
   - Do not lower animation target just because `Present(1)` blocked.

4. **Idle should wait/sleep; active should present-pace**
   - When no frames are requested and no near-term timers exist, sleep/wait.
   - During active frame bursts, return quickly to the next iterate and let present block.

5. **Monitor refresh follows the window**
   - Query the refresh rate from the actual window's current display.
   - Update when the window moves, display changes, scale changes, restore/maximize, or pixel size changes.

6. **No busy-spinning as the default fix**
   - Smoothness should come from vsync and requested frames, not pegging a core.

## Proposed architecture

### New concepts

Add explicit scheduler state in Lua:

```lua
core.target_fps         -- monitor/config target, e.g. 144
core.frame_dt          -- 1 / core.target_fps, used by animation
core.present_paced     -- true when renderer present is expected to block to vsync
core.requested_frames  -- RAD-like small frame burst counter
core.frame_request_reason -- debug string / last reason
```

Add API functions:

```lua
function core.refresh_display_timing(reason) end
function core.request_frame(count, reason) end
function core.has_requested_frame() end
```

Recommended semantics:

```lua
function core.request_frame(count, reason)
  count = count or 4
  core.requested_frames = math.max(core.requested_frames or 0, count)
  core.frame_request_reason = reason or core.frame_request_reason
end
```

Frame request defaults:

- normal input: 2-4 frames;
- scroll/transition animation: 4 frames, refreshed while not settled;
- caret blink: 1 frame at blink deadline;
- async data/model changes: 2-4 frames;
- live resize: immediate special path remains, but should share diagnostics.

### Renderer pacing query

Add a lightweight C/Lua query so the run-loop knows whether post-frame sleep should be avoided:

```lua
renderer.is_present_paced() -> boolean
renderer.get_last_frame_stats() -> table? -- optional diagnostics
```

Initial behavior:

- D3D11 command renderer: `present_paced = true` for normal `Present(1)` frames.
- SDL renderer fallback with vsync enabled: probably `true`.
- software/window-surface fallback without vsync: `false`, so old FPS cap or a simple cap still applies.

This avoids hardcoding D3D policy in Lua.

### Timing split

Replace the current adaptive FPS logic with separated measurements:

- `update_cpu_ms`: Lua update/event processing time;
- `draw_build_cpu_ms`: Lua draw command emission time;
- `renderer_submit_ms`: command upload + present call wall time;
- `present_ms`: D3D present wait, from D3D stats when available.

Budget decisions should use CPU-side work, not `present_ms`.

If full split is too much initially, the first safe step is also the highest-confidence smoothness experiment and should land early behind a flag:

- keep `core.target_fps = config.fps`;
- keep `core.fps = config.fps` for compatibility;
- stop adaptive downshift when `renderer.is_present_paced()` is true;
- skip post-present sleep for active present-paced frames;
- use a conservative coroutine budget such as `max(0.001, min(0.004, core.frame_dt * 0.25))` until better CPU-only measurements exist.

This is deliberately smaller than the full RAD-like scheduler. It directly tests the suspected bug: a healthy vsync `Present(1)` wait being treated as render failure, followed by an extra Lua sleep.

## Staged implementation plan

### Stage 0: Baseline instrumentation

Purpose: prove current behavior and create before/after comparisons.

Add `ANVIL_FRAME_PACING_STATS=1` CSV, separate from resize stats. Suggested file: temp `anvil_frame_pacing_stats.csv` unless `ANVIL_FRAME_PACING_STATS_FILE` is set.

Columns:

```text
time,seq,reason,target_fps,core_fps,frame_dt,present_paced,
requested_before,requested_after,event_count,did_redraw,
run_step_ms,update_ms,draw_build_ms,renderer_submit_ms,present_ms,
sleep_requested_ms,sleep_actual_ms,monitor_display_id,monitor_refresh_hz,
run_mode,redraw_flag,queue_depth
```

Implementation notes:

- D3D already has `ANVIL_D3D11_STATS`; reuse/correlate where possible.
- For Lua, log per `core.run_step()`.
- For D3D, expose last `present_ms`, `sync_interval`, and path if practical.

Acceptance for this stage:

- On a high-refresh monitor, current logs should show post-redraw sleep and/or `core.fps` dropping below target during active smooth scrolling.
- Logs should distinguish CPU work from present wait where possible.

### Stage 1: Highest-confidence present-paced experiment

Purpose: quickly validate the main diagnosis before the larger scheduler refactor.

This stage should be small, flag-gated, and easy to revert. It does not require full explicit frame-request coverage yet.

Tasks:

1. Add `renderer.is_present_paced()`.
2. Return true for the D3D11 command renderer when normal frames use `Present(1, 0)`.
3. Optionally expose last D3D present stats:
   - path (`commands`, `surface_upload`, fallback);
   - `sync_interval`;
   - `present_ms`;
   - success/failure.
4. Behind `ANVIL_RAD_PACING=1` or `ANVIL_NO_POST_PRESENT_SLEEP=1`, change `core.run_step()` so a successful active present-paced redraw does not call `system.sleep()` afterward.
5. Behind the same flag, disable adaptive `core.fps` downshift when `renderer.is_present_paced()` is true. Keep `core.fps = config.fps` / monitor target for animation compatibility.
6. Keep legacy FPS sleep/cap for non-present-paced renderers and for idle.
7. Log before/after with `ANVIL_FRAME_PACING_STATS=1` and existing D3D stats.

Acceptance:

- Active D3D scroll/animation frames show `sleep_actual_ms == 0` after redraw.
- `core_fps` does not drop below `target_fps` merely because `present_ms` is near the refresh interval.
- On a high-refresh monitor, active frame intervals cluster near the monitor period when CPU work fits.
- Idle CPU does not spike because idle frames still sleep/wait.

### Stage 2: Monitor refresh correctness

Purpose: make the target refresh follow the real window.

Tasks:

1. Add `SDL_EVENT_WINDOW_MOVED` to the internal event filter in `src/system_events.c`.
2. Map it in `src/api/system.c` as e.g. `"moved"` with position data if useful.
3. Add `core.refresh_display_timing(reason)` in `data/core/init.lua`:

   ```lua
   function core.refresh_display_timing(reason)
     local hz = core.window and core.window:get_refresh_rate() or DEFAULT_FPS
     if hz and hz >= 30 then
       DEFAULT_FPS = hz
       if config.auto_fps then config.fps = hz end
       core.target_fps = config.fps
       core.fps = config.fps
       core.frame_dt = 1 / core.target_fps
       -- reset scheduler timing so stale next-frame deadlines do not survive monitor moves
     end
   end
   ```

4. Call it after window creation and on:
   - `displaychanged`;
   - `scalechanged`;
   - `moved`;
   - possibly `maximized`, `restored`, and `resized` if SDL does not reliably emit display changes.
5. Avoid integer-only assumptions where possible; keep fractional refresh such as 59.94/143.98 until display text/logging.

Acceptance:

- Move Anvil between monitors with different Hz; `target_fps` updates within one event/frame.
- `config.auto_fps=false` preserves user override but diagnostics still report monitor Hz.

### Stage 3: Add RAD-like frame requests

Purpose: make frame production explicit and animation-driven.

Tasks:

1. Add scheduler fields initialized in `core.run()`:

   ```lua
   core.target_fps = config.fps
   core.frame_dt = 1 / core.target_fps
   core.requested_frames = 0
   ```

2. Implement:

   ```lua
   function core.request_frame(count, reason)
     count = count or 4
     core.requested_frames = math.max(core.requested_frames or 0, count)
     core.frame_request_reason = reason or core.frame_request_reason
   end
   ```

3. Replace or augment major `core.redraw = true` sources:
   - Keep `core.redraw` for compatibility.
   - Add `core.request_frame()` in central paths, not every random plugin initially.
   - Recommended central hooks:
     - after any input event that can visibly change state;
     - `View:move_towards()` while not settled;
     - smooth scroll / scrollbar code while not settled;
     - caret blink deadline;
     - file/dialog/process async result events;
     - command view and autocomplete popup changes.

4. Update `View:move_towards()`:
   - If value is not at destination, call `core.request_frame(4, "transition:" .. name)`.
   - Keep `core.redraw = true` for compatibility.

5. Update scroll code paths if they bypass `View:move_towards()`.

6. At the end of a successful redraw, decrement requested frames by one:

   ```lua
   if did_redraw and core.requested_frames > 0 then
     core.requested_frames = core.requested_frames - 1
   end
   ```

   If code requested more frames during update/draw, preserve the higher value. Use a before/after value to avoid accidentally consuming a newly requested burst.

Acceptance:

- A single wheel scroll requests a short burst.
- Smooth transitions continue until settled without requiring a new input event.
- Idle editor reaches `requested_frames == 0`.

### Stage 4: Canonicalize no post-present sleep for active present-paced frames

Purpose: stop double-throttling.

Tasks:

1. Use `renderer.is_present_paced()` from Stage 1.
2. In `core.run_step()`, after a redraw:

   Current behavior sleeps for `next_frame = 1 / core.fps - elapsed`.

   New behavior:

   - if present-paced and frames are requested/animation is active:
     - do **not** sleep after redraw;
     - allow next `SDL_AppIterate()` to run; `Present(1)` will pace the next redraw;
   - if present-paced but no frames are requested:
     - use idle sleep/wait policy;
   - if not present-paced:
     - use old or simplified FPS cap to avoid runaway CPU.

3. Keep `config.draw_stats == "uncapped"` as an explicit benchmark override.
4. Remove adaptive `core.fps` downshift for present-paced frames.
5. Keep `core.fps = config.fps` or convert animation code to `core.target_fps` / `core.frame_dt` while leaving `core.fps` as compatibility alias.

Pseudo-code:

```lua
if did_redraw then
  consume_requested_frame()
  if renderer.is_present_paced() then
    if core.requested_frames > 0 or core.redraw then
      -- no post-present sleep; vsync is the limiter
      run_next_step = nil
    else
      -- no active animation; enter idle policy
      run_next_step = next_timer_deadline()
    end
  else
    -- fallback cap for non-vsynced renderer
    sleep_until_next_target_frame()
  end
end
```

Acceptance:

- Frame pacing stats show `sleep_actual_ms == 0` after active D3D redraws.
- D3D stats show `sync_interval=1` for normal frames.
- Active scroll on 144 Hz produces frame intervals clustered near 6.9 ms if workload fits.

### Stage 5: Replace adaptive FPS with CPU-only budgeting

Purpose: keep coroutine scheduling useful without corrupting animation target FPS.

Tasks:

1. Stop computing throughput from vsync-inclusive `renderer.end_frame()` wall time.
2. Introduce CPU-only budget estimate:
   - minimum: use measured Lua event/update/draw-command-build time;
   - better: expose D3D `present_ms` and subtract it from submit wall time;
   - best: explicit renderer stats for command build/upload/present.
3. Set coroutine budget based on target frame period:

   ```lua
   local frame_budget = 1 / core.target_fps
   local cpu_used = update_cpu + draw_build_cpu + renderer_nonpresent_cpu
   core.co_max_time = clamp(frame_budget - cpu_used - safety_margin, min_budget, max_budget)
   ```

4. Under overload:
   - reduce coroutine budget first;
   - possibly skip noncritical background work;
   - do **not** lower `core.target_fps` solely because present waited.
5. Only use adaptive lower effective FPS if CPU-side work repeatedly exceeds the target frame budget, and make that a separate diagnostic field such as `core.effective_fps`, not the animation target.

Acceptance:

- `core.target_fps` remains monitor/config target during normal vsync operation.
- Background coroutines do not eat the frame budget during scrolling.
- Real CPU overload reduces background work before reducing visible animation cadence.

### Stage 6: Idle policy in SDL callback mode

Purpose: avoid busy spinning while keeping latency acceptable.

Because Anvil currently uses `SDL_MAIN_USE_CALLBACKS`, it cannot mirror RAD's `GetMessage()` exactly inside Lua. The first implementation should use a practical idle policy:

Focused idle:

- If no requested frames and no events:
  - sleep until the nearest timer/coroutine deadline, but cap the sleep to a small value.
  - Suggested starting cap: 1-4 ms focused, configurable for testing. Start lower for 240 Hz experiments; 4 ms is already almost a full 240 Hz frame period.

Unfocused idle:

- Use larger caps, e.g. 50-100 ms, unless background work has an earlier deadline.

Active burst:

- No idle sleep after present-paced redraws.
- Let `Present(1)` pace.

Add environment/config knobs while tuning:

```text
ANVIL_IDLE_SLEEP_FOCUSED_MS=2
ANVIL_IDLE_SLEEP_UNFOCUSED_MS=100
ANVIL_NO_POST_PRESENT_SLEEP=1
```

Acceptance:

- Focused idle CPU remains reasonable.
- First input after idle is not noticeably delayed.
- Active scroll/animation has zero post-present sleep.

### Stage 7: Optional explicit desktop event loop

Purpose: if SDL callback idle policy still has poor latency/CPU tradeoffs, move Windows desktop builds closer to RAD's event loop.

Investigate replacing callback-mode main on desktop with an explicit loop:

```c
while (!quit) {
  if (frames_requested == 0 && !always_refresh) {
    SDL_WaitEvent(&event); // or Win32 MsgWaitForMultipleObjects / SDL wait equivalent
  }
  while (SDL_PollEvent(&event)) { ... }
  run_step();
}
```

Risks:

- SDL callback mode may have been chosen for portability/platform lifecycle reasons.
- Mobile/web platforms may still need callbacks.
- Need to preserve restart/quit behavior and custom events.

Recommendation:

- Do not start here.
- First implement Stages 0-6.
- Use metrics to decide whether a Windows-only explicit loop is worth it.

### Stage 8: Renderer policy cleanup

Purpose: align renderer defaults with the RAD-like scheduler.

Tasks:

1. Keep normal D3D frames on `Present(1, 0)`.
2. Keep max frame latency 1.
3. Keep `ClearState()` after present.
4. Revisit live resize `Present(0)` default:
   - current Anvil defaults to `Present(0)` during live resize;
   - RAD uses `Present(1, 0)` plus `DwmFlush()` in `WM_SIZE` / `WM_PAINT`;
   - test both with the new frame scheduler;
   - if RAD-like is better, make `Present(1)` default and keep `Present(0)` opt-in for resize experiments.
5. Consider making DXGI infer swapchain size (`ResizeBuffers(..., 0, 0, ...)`) after DPI validation, matching RAD more closely.
6. Add last-frame renderer stats API for diagnostics.

Acceptance:

- Normal editing path remains D3D command renderer.
- No software fallback during normal frames.
- No tearing/uncapped present by default.

### Stage 9: Animation timestep refactor

Purpose: make animations independent of actual frame-rate hiccups and avoid using downshifted `core.fps` as both target and measured rate.

Tasks:

1. Introduce `core.frame_dt` as the canonical animation timestep target.
2. Audit uses of `core.fps` and `config.fps` in animation/math:
   - `data/core/view.lua`;
   - `data/core/scrollbar.lua`;
   - doc view smooth scrolling;
   - caret/smoothcaret plugins;
   - fuzzy/search coroutine scan intervals where appropriate.
3. Replace animation rate math with `core.frame_dt` or target FPS.
4. Keep coroutine scan intervals configurable; not every `1/config.fps` is an animation.
5. For time-based animations, consider actual elapsed time clamped to a range:

   ```lua
   local dt = math.min(system.get_time() - previous_frame_time, 2 / core.target_fps)
   ```

   Use this carefully; RAD often uses target dt for stable UI feel.

Acceptance:

- Scroll animation duration feels consistent at 60/144/240 Hz.
- A temporary missed frame does not permanently slow animation.

## Proposed run-loop shape

The final `core.run_step()` should roughly become:

```lua
function core.run_step(options)
  local start = system.get_time()
  local immediate = options and options.immediate
  local present_paced = renderer.is_present_paced and renderer.is_present_paced()

  -- 1. Run bounded background/coroutine work only if budget allows.
  --    During immediate/live resize or active input bursts, use tighter budget.
  run_coroutines_with_budget()

  -- 2. Process all queued events.
  local event_count = core.process_events()
  if event_count > 0 then
    core.request_frame(4, "event")
  end

  -- 3. Decide whether to draw.
  local should_draw = immediate
                   or core.redraw
                   or (core.requested_frames or 0) > 0
                   or due_timer_requires_redraw()

  if should_draw then
    local requested_before = core.requested_frames or 0
    local did_redraw = core.draw_one_frame()
    if did_redraw then
      consume_one_requested_frame(requested_before)
    end

    if present_paced then
      -- Do not sleep after an active vsynced frame.
      if core.requested_frames > 0 or core.redraw then
        return true
      end
    else
      sleep_to_cap_if_needed()
    end
  end

  -- 4. Idle path only.
  sleep_until_next_deadline_with_cap()
  return true
end
```

Key difference from current code: **post-redraw sleep is not the normal active-frame limiter when present-paced.**

## Event/request policy

Initial policy table:

| Event/source | Request frames | Notes |
| --- | ---: | --- |
| key press/release | 2-4 | command response, caret, selection |
| text input/editing | 2-4 | caret and layout |
| mouse wheel | 4 | smooth scroll continues via transition requests |
| mouse drag/pressed/released | 4 | selection, scrollbar, splitters |
| mouse move | 1-2 if hover/cursor changed | avoid unnecessary redraws for no-op moves |
| window moved/display changed | 2 | refresh timing and redraw |
| resize/live resize | immediate path | keep special resize handling |
| transition not settled | 4 | refreshed each frame until settled |
| caret blink deadline | 1 | scheduled timer |
| async process/search result | 2-4 | visible list updates |
| config/theme/font change | 4 | full redraw |

## Diagnostics and manual testing

### Environment variables

Existing useful variables:

```text
ANVIL_D3D11_STATS=1
ANVIL_D3D11_STATS_FILE=...
ANVIL_D3D11_STATS_FLUSH=1
ANVIL_RESIZE_STATS=1
ANVIL_LUA_RESIZE_STATS=1
```

New proposed variables:

```text
ANVIL_FRAME_PACING_STATS=1
ANVIL_FRAME_PACING_STATS_FILE=...
ANVIL_FRAME_PACING_STATS_FLUSH=1
ANVIL_RAD_PACING=1              # temporary rollout flag
ANVIL_NO_POST_PRESENT_SLEEP=1   # temporary focused experiment
ANVIL_IDLE_SLEEP_FOCUSED_MS=2
ANVIL_IDLE_SLEEP_UNFOCUSED_MS=100
```

### Test matrix

1. Single high-refresh monitor:
   - 120 Hz;
   - 144/165 Hz;
   - 240 Hz if available.
2. Mixed monitor:
   - primary 60 Hz, secondary high Hz;
   - primary high Hz, secondary 60 Hz;
   - drag Anvil between monitors and repeat scroll tests.
3. Interactions:
   - mouse wheel smooth scroll;
   - scrollbar drag;
   - keyboard cursor repeat;
   - PageUp/PageDown;
   - typing;
   - command palette open/close;
   - autocomplete popup;
   - caret blink idle;
   - hover titlebar/buttons;
   - live resize.
4. Load cases:
   - large file;
   - multiple splits;
   - project search/fuzzy search results streaming;
   - background file watcher activity.
5. Renderer modes:
   - default D3D11;
   - `ANVIL_RENDERER=software` fallback.

### Success metrics

On a monitor with refresh `Hz`, active smooth UI motion should show:

- `target_fps ~= Hz` for auto FPS;
- `core_fps` not dropping below target due to present wait;
- normal frames `sync_interval=1`;
- active-frame `sleep_actual_ms=0` after present-paced redraws;
- frame intervals clustered around `1000 / Hz` ms when work fits;
- no long alternating frame pattern such as 6.9 ms / 13.8 ms on 144 Hz unless workload actually misses;
- idle CPU acceptable and no continuous redraw with `requested_frames=0`.

## Rollout strategy

1. Implement behind `ANVIL_RAD_PACING=1` or `config.frame_pacing = "rad"`.
2. Gather stats against current default.
3. Enable by default for Windows D3D11 only.
4. Keep old pacing selectable for one or two iterations:

   ```lua
   config.frame_pacing = "legacy" | "rad"
   ```

5. Once stable, remove or demote legacy path.

## Risks and mitigations

### Risk: higher idle CPU

Removing sleeps in the wrong place can cause a tight `SDL_AppIterate()` loop.

Mitigation:

- never skip idle sleep when `requested_frames == 0` and no redraw is needed;
- log idle iterations and sleep;
- cap focused idle with a tunable small sleep;
- consider explicit desktop loop only if needed.

### Risk: animations never stop requesting frames

A transition bug could keep `requested_frames` alive forever.

Mitigation:

- request finite bursts, not infinite flags;
- require animation code to re-request only while not settled;
- add diagnostics for reason and age of requests;
- add a debug overlay showing requested frame count/reason.

### Risk: background coroutines become sluggish

Reducing coroutine budget during active frames may delay search/indexing.

Mitigation:

- use separate foreground/background coroutine budgets;
- allow background work while idle;
- log coroutine backlog;
- never run large coroutine batches before an active input frame.

### Risk: software fallback loses FPS cap

If post-present sleep is removed for non-vsynced software paths, CPU may spike.

Mitigation:

- use `renderer.is_present_paced()`;
- keep legacy cap for non-present-paced renderers.

### Risk: mixed-monitor refresh still stale

SDL may not emit exactly the events expected on all platforms.

Mitigation:

- refresh display timing on multiple window events;
- optionally poll display ID once per second while focused/moving as a safety net;
- log display ID/refresh in frame pacing stats.

## Concrete first patch sequence

Recommended small commits, ordered by confidence/impact:

1. `docs`: add/update this plan.
2. `stats`: add minimal frame pacing CSV; correlate with existing D3D stats.
3. `renderer-stats`: add `renderer.is_present_paced()` and expose D3D last present stats (`sync_interval`, `present_ms`, path).
4. `pacing-experiment`: behind `ANVIL_RAD_PACING=1`, skip post-present sleep for active present-paced D3D frames.
5. `fps-downshift`: behind the same flag, disable vsync-inclusive adaptive `core.fps` downshift for present-paced frames.
6. `display`: route `SDL_EVENT_WINDOW_MOVED`; add `core.refresh_display_timing()` and keep fractional refresh where practical.
7. `scheduler`: add `core.request_frame()` and request bursts from central input/transition paths.
8. `budget`: replace adaptive FPS with CPU-only coroutine budgeting.
9. `idle`: tune SDL-callback idle sleep caps, especially for 240 Hz.
10. `default`: enable RAD pacing by default for Windows D3D11 after manual validation.
11. `cleanup`: simplify legacy pacing and update docs/settings UI.

## Bottom line

The renderer is already close to RAD's normal D3D11 presentation model. The main refactor is above the renderer: Anvil needs a RAD-like frame scheduler. Active frames should be requested and then paced by vsync; Lua should not measure a successful vsync wait as failure and then sleep again. Once that is fixed and refresh follows the window's monitor, high-refresh scrolling and UI motion should feel much closer to RAD Debugger.
