# D3D11 renderer rewrite plan: RAD-style Anvil rendering

Goal: move Anvil's Windows renderer toward the architecture used by RAD Debugger while keeping Anvil's existing Lua/core renderer API stable.

## Scope

Allowed implementation surface:

- `src/d3d11_backend.*`
- `src/rencache.*` only where needed to route command submission
- `src/renderer.*` only where needed to feed glyph/image commands
- local test harness scripts in this repo

Do not rewrite editor UI/Lua code for this effort. The public drawing API should keep working:

- `renderer.draw_rect`
- `renderer.draw_text`
- `renderer.draw_canvas`
- `renderer.draw_pixels`
- clip rect commands

## RAD ideas that matter

The RAD Debugger renderer has a few high-leverage ideas worth copying:

1. **Frame bucket / pass model**
   - UI code emits simple draw commands into a frame-owned command list.
   - The backend submits a small number of passes to D3D11.
   - No software framebuffer is the normal path.

2. **Instance-based 2D quads**
   - Rects/images/text glyphs are instances.
   - Vertex shader uses `SV_VertexID` to expand one instance into a four-vertex quad.
   - This avoids pushing six CPU vertices per rectangle/glyph.

3. **Batch groups by GPU state**
   - Batch keys are texture, sampling mode, clip/scissor, and transforms.
   - Upload one dynamic instance buffer, then `DrawInstanced(4, instance_count, ...)`.

4. **Persistent GPU resources**
   - Swapchain and render target per window.
   - Cached textures for font atlases/images.
   - Dynamic scratch buffers reused across frames.

5. **Simple latency policy**
   - Use flip-discard swapchain.
   - Present with vsync.
   - Avoid extra `DwmFlush()` unless explicitly debugging; Present already blocks appropriately.
   - Set DXGI maximum frame latency when available.

6. **Useful instrumentation**
   - Log renderer path, adapter name, hardware vs WARP, frame timing, draw calls, maps, uploads.
   - Stats should make fallback paths obvious.

## Current Anvil problems to remove

The current D3D11 path is already command-based, but still carries old software-renderer architecture:

- A software `SDL_Surface` still exists as the canonical cache surface.
- Text rendering pushes glyph surfaces as texture quads, but batches use six vertices per glyph.
- Rects and textures have separate pipelines and force flushes between each other.
- `DwmFlush()` after every `Present()` adds several milliseconds of avoidable frame latency.
- Stats confirm D3D11 use, but do not say whether the device is hardware or WARP.

## Milestones

### M1: Safety plan and repeatable smoke test

- Document this plan.
- Add a local PowerShell smoke test that:
  - creates/updates a large file inside the provided test project,
  - runs the repo-local `.run/bin/anvil.exe`,
  - opens the file,
  - captures screenshots,
  - sends scroll/page-down input,
  - captures more screenshots,
  - writes D3D11 stats into the test project.

### M2: RAD-style latency and diagnostics

- Add D3D11 adapter/backend metadata to stats.
- Detect/log hardware vs WARP fallback.
- Set DXGI maximum frame latency to 1 when `IDXGIDevice1` is available.
- Make `DwmFlush()` opt-in via `ANVIL_D3D11_DWM_FLUSH=1`.
- Keep legacy behavior available only for debugging.

### M3: Instance-based texture/glyph pipeline

- Replace the texture/glyph six-vertex pipeline with one instance per textured quad.
- Vertex shader expands each instance with `SV_VertexID`.
- Continue preserving draw order by flushing when texture/mode changes.
- Keep old surface upload fallback intact.

### M4: Instance-based rect pipeline

- Replace rectangle six-vertex pipeline with one instance per rectangle.
- Move toward a unified RAD-like 2D quad pipeline.
- Preserve draw order with flush-on-state-change until a full batch-key pass exists.

### M5: Unified 2D batch groups

- Optional deeper step after M3/M4 are stable:
  - single quad instance type for rects, glyphs, images,
  - white texture for solid rects,
  - batch key includes texture/mode/clip,
  - one submit path for all 2D UI quads.

## Acceptance loop

For each implementation milestone:

1. Build with Meson.
2. Run the smoke test against `C:\Users\Dario Costa\Desktop\projects\castrosua_legacy\test_project`.
3. Verify screenshots exist and are non-empty.
4. Verify D3D stats show `path=commands`, successful frames, and no fallback to software upload for normal UI.
5. Compare frame stats before/after for lower CPU time, fewer bytes copied, fewer or equal draw calls.
6. Commit the milestone so rollback is easy.
