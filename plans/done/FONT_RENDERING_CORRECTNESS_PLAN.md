# Font Rendering Correctness Plan

## Purpose

Fix visible seams in connected monospace glyphs at normal editor sizes.

The main reproduction is a repeated box-drawing character:

```text
────────────────────────────────────────────
```

Anvil shows periodic color or brightness changes where glyphs meet. The lower edge can also remain soft at normal zoom.

Other Windows editors show the same effect only at much smaller sizes. Anvil therefore exposes a renderer defect, not only a font limitation.

This plan fixes the general font pipeline. It does not special-case one character unless the general fixes leave a proven gap.

## User-visible contract

Connected glyphs with one color must look continuous at normal code-font sizes.

The renderer must preserve these rules:

1. Text layout uses stable advances at every zoom level.
2. Glyph placement has no systematic left or right bias.
3. Hinting choices have defined and repeatable effects.
4. Font rendering order cannot change cached glyph pixels.
5. The D3D11 and software paths use the same glyph masks and placement.
6. Changing raster quality cannot move carets or change wrapping without an explicit layout change.
7. Fallback fonts, styled font copies, and ligature modes follow the same policy.

## Evidence collected

### Screenshot evidence

The reported screenshot contains three visible source-pixel rows after enlargement:

- a nearly covered top row;
- a fully covered middle row;
- a partly covered lower row.

The top and lower rows contain periodic RGB changes. The middle row is almost uniform.

This pattern is consistent with changing LCD coverage at glyph joins. It does not, by itself, prove which raster or blend step caused the changes.

### Exact-font comparison

The exact bundled font was rendered through Edge at 15, 16, 18, and 24 px:

```text
data/fonts/CaskaydiaCoveNerdFontMono-SemiLight.ttf
```

Edge produced continuous interior rows without periodic seams. This comparison used the same text and colors.

The comparison shows that DirectWrite can render this font continuously on this machine. It does not prove pixel parity because CSS size and FreeType ppem are different size interfaces.

### Font geometry

The bundled semi-light font defines U+2500 with these design metrics:

```text
advance: 1200 font units
bounds:  -85 through 1285 font units
width:   1370 font units
units/em: 2048
```

The glyph extends beyond both cell boundaries. This overhang is intentional. It lets adjacent box-drawing glyphs connect.

At 15 px, the design values are approximately:

```text
cell advance: 8.79 px
glyph width:  10.03 px
left overhang: 0.62 px
right overhang: 0.62 px
```

A renderer must handle this overlap without producing periodic marks.

### Native font hints

The bundled font contains native TrueType hinting programs:

```text
U+2500 glyph instructions: 8 bytes
cvt values:                 107
fpgm instructions:          3971 bytes
prep instructions:          579 bytes
```

Anvil currently forces FreeType's auto-hinter for every hinted font. It therefore ignores the font's preferred native hinter.

## Current Anvil pipeline

The main implementation is in:

```text
src/renderer.c
src/renderer.h
src/d3d11_backend.c
src/api/renderer.c
```

The Lua defaults are in:

```text
data/core/style.lua
data/plugins/anvil_defaults.lua
```

The current code-font default uses:

```text
antialiasing = subpixel
hinting = slight
ligatures = true
```

### Size selection

`font_set_face_metrics(...)` computes a physical pixel size. It then calls:

```c
FT_Set_Pixel_Sizes(face, 0, (int) pixel_size);
```

The cast truncates every fractional size. A request for 18.9 px becomes 18 px instead of 19 px.

### Load policy

`font_set_load_options(...)` currently combines three separate choices:

- antialiasing mode;
- hinting strength;
- hint source.

For all hinted fonts, it adds:

```c
FT_LOAD_FORCE_AUTOHINT
```

For slight hinting, it uses `FT_LOAD_TARGET_LIGHT`. For full hinting, it uses `FT_LOAD_TARGET_NORMAL`.

### Render policy

`font_set_render_options(...)` chooses the bitmap format. It also calls FreeType's process-wide LCD-filter API.

The current filter mapping is:

```text
hinting none   -> FT_LCD_FILTER_DEFAULT
hinting slight -> FT_LCD_FILTER_LIGHT
hinting full   -> FT_LCD_FILTER_LEGACY
```

FreeType 2.14 documents both legacy filter values as ignored.

More importantly, the vendored FreeType configuration and current Windows build do not define `FT_CONFIG_OPTION_SUBPIXEL_RENDERING`. They therefore use Harmony LCD rendering. In this build, every `FT_Library_SetLcdFilter(...)` call returns `FT_Err_Unimplemented_Feature` and changes nothing. Harmony uses the default RGB geometry `{-21, 0}, {0, 0}, {21, 0}` in 26.6 pixel units.

The current calls ignore their return values. They are dead policy in the Windows build and build-dependent global mutation in a ClearType-style FreeType build.

### Layout metrics

Glyph advances are loaded with hinting disabled:

```c
FT_LOAD_BITMAP_METRICS_ONLY
FT_LOAD_NO_HINTING
```

HarfBuzz 13.0.1 defaults to `FT_LOAD_DEFAULT | FT_LOAD_NO_HINTING`. Anvil does not set this policy explicitly. FreeType can still hint fonts marked `FT_FACE_FLAG_TRICKY` with these flags.

The bitmap later uses a different load policy. This can be a valid natural-layout model, but the code does not define it as one.

### Subpixel placement

Anvil caches three horizontal bitmap phases:

```text
0/3 px
1/3 px
2/3 px
```

FreeType outline transforms use 26.6 units, so the current code implements these as `0/64`, `21/64`, and `42/64` px.

The current phase calculation is effectively:

```c
phase = (int)(fractional_x * 3);
pixel_x = floor(x);
```

For nonnegative positions, this always rounds the phase down.

For example, an x position of `10.99` uses:

```text
pixel origin: 10
phase:        2/3
result:       about 10.66
```

The nearest cached position is `11.0`. The current result can lag the requested pen position by almost one third of a pixel.

The same calculation handles negative positions incorrectly because C truncates negative floating-point values toward zero.

### Compositing

Each glyph bitmap is blended directly onto the target. Connected glyphs can blend twice where their masks overlap.

The D3D11 path uses point sampling and integer destination rectangles. Linear texture filtering does not cause the reported blur.

The D3D11 blend path uses independent RGB coverage for LCD glyphs. The software path implements a similar channel blend in C.

Both paths blend into encoded 8-bit color targets. Neither path performs linear-light text blending.

## Confirmed implementation defects

### 1. Horizontal subpixel placement is floor-biased

For nonnegative positions, the phase selector always chooses the phase below the requested position. It never carries a near-one phase into the next pixel.

This creates periodic placement error when a fractional advance repeats. Connected overhanging glyphs make the error easy to see.

This defect affects shaped and unshaped text. Four drawing paths duplicate the phase expression.

### 2. Native font hints are always overridden

`FT_LOAD_FORCE_AUTOHINT` prefers the generic auto-hinter over native font instructions.

This choice is unsuitable as Anvil's only hinted mode. The bundled code font contains native instructions designed for small sizes.

The forced auto-hinter is a likely cause of the late transition from partial to solid horizontal coverage.

### 3. LCD policy is dead in the vendored build and unsafe in other builds

Anvil calls `FT_Library_SetLcdFilter(...)` while loading individual glyphs and ignores every result.

These calls do nothing with the vendored Harmony build. They therefore do not cause the reported Windows output.

In a ClearType-style FreeType build, `DEFAULT` and `LIGHT` change library-wide state. The ignored legacy value leaves the preceding filter active. Rendering order can then affect newly cached glyphs.

Hint strength and LCD rendering policy are separate choices. Remove the per-glyph calls in all builds.

### 4. Fractional physical sizes are always rounded down

The cast to `int` gives the face a smaller scale than requested for every positive fractional value. This affects both raster ppem and natural layout advances.

This delays size-dependent hint transitions. It can explain why Anvil needs more zoom than another editor before a stroke becomes solid.

### 5. Layout and raster policies are implicit

Anvil uses natural layout advances and hinted bitmaps. The layout loads disable hinting for ordinary fonts but retain FreeType's special handling for tricky fonts.

However, the policy is spread across several functions. HarfBuzz also relies on its default FreeType load flags.

A HarfBuzz update could change layout behavior without an intentional Anvil change.

### 6. No focused visual regression exists

Current tests cover font lifetime, width APIs, display packets, and text layout. They do not inspect final glyph coverage.

The render performance gate captures text, but it does not isolate connected glyph seams across sizes and x phases.

## Suspected secondary defects

These items need measurement after the confirmed implementation defects are fixed.

### Encoded-space LCD blending

FreeType recommends independent channel blending with gamma correction in linear space.

Anvil blends directly into `DXGI_FORMAT_B8G8R8A8_UNORM` and ordinary SDL pixels. This can make edges darker or more colorful.

Do not redesign color management in the first patch. First remove placement and hinting errors.

### Per-glyph overlap blending

Direct blending can darken two partial masks where glyphs overlap.

A run-level coverage mask could prevent repeated blending. It would add memory, batching, and color-run complexity.

Do not add run masks unless corrected placement and hinting still leave measurable seams.

### Three-phase quantization limit

Three phases match RGB subpixels and keep the cache small. They can still differ from a renderer with finer positioning.

Do not increase the phase count until nearest-phase placement is correct and measured.

## Things that are not the primary cause

### The bundled font

The font intentionally overhangs box-drawing cells. Edge renders the same file correctly.

Replacing the font would hide the defect and reduce confidence in the renderer.

### D3D11 texture sampling

The glyph sampler uses `D3D11_FILTER_MIN_MAG_MIP_POINT`. Glyph quads also use integer destination bounds.

A linear sampler is not blurring the glyph atlas.

### Ligatures alone

The issue can affect both shaped and unshaped runs. Disabling ligatures is not a general fix.

### A theme color

The selected color makes RGB differences visible. It does not create those differences.

## Target internal model

Create one explicit raster policy for each `RenFont`.

Suggested internal shape:

```c
typedef struct {
  FT_Int32 layout_load_flags;
  FT_Int32 bitmap_load_flags;
  FT_Render_Mode render_mode;
  bool uses_lcd_coverage;
} FontRasterPolicy;
```

Keep this type private to `src/renderer.c` unless a focused native test needs a small private header.

The policy must separate these concerns:

1. Layout metric source.
2. Hint source.
3. Hint strength.
4. Bitmap antialiasing mode.
5. LCD rendering policy.
6. Horizontal placement quantization.

### Recommended policy

Preserve the current natural-layout behavior for all modes in the first implementation.

Set the same flags explicitly on HarfBuzz:

```c
FT_LOAD_DEFAULT | FT_LOAD_NO_HINTING
```

This matches HarfBuzz 13.0.1's current FreeType default and Anvil's metric loads. It preserves existing wrapping and caret behavior while the raster changes.

FreeType can ignore `FT_LOAD_NO_HINTING` for a small set of `FT_FACE_FLAG_TRICKY` fonts. Do not add `FT_LOAD_NO_AUTOHINT` to layout flags in this phase because that would change those fonts' advances. If fully unhinted layout for tricky fonts becomes a goal, treat it as a separate layout change.

Use these bitmap policies:

| Antialiasing | Hinting | Bitmap hint source | Load target | Render mode |
|---|---|---|---|---|
| none | none | disabled | mono | mono |
| none | slight/full | native preferred | mono | mono |
| grayscale | none | disabled | normal | normal |
| grayscale | slight | native preferred | light | normal |
| grayscale | full | native preferred | normal | normal |
| subpixel | none | disabled | LCD | LCD |
| subpixel | slight | native preferred | light | LCD |
| subpixel | full | native preferred | normal | LCD |

"Native preferred" means that Anvil does not set `FT_LOAD_FORCE_AUTOHINT`.

FreeType then uses native hints when available. It can use its auto-hinter when a font has no native hinter.

The load target is a request to the selected hinter. A native hinter can ignore it. Therefore, `slight` and `full` can produce the same bitmap for some fonts. The contract is the selected flags, not a guaranteed visual difference for every font.

For hinting `none`, set both flags:

```c
FT_LOAD_NO_HINTING | FT_LOAD_NO_AUTOHINT
```

This gives the option one clear meaning, including fonts that FreeType classifies as tricky.

### LCD rendering policy

Choose one RGB LCD policy for the FreeType library. Set it once during renderer initialization.

Use a policy equivalent to RGB thirds with a light filter:

1. Call `FT_Library_SetLcdGeometry(...)` with `{-21, 0}, {0, 0}, {21, 0}`.
2. If it succeeds, the build uses Harmony. Do not call the filter API.
3. If it returns `FT_Err_Unimplemented_Feature`, call `FT_Library_SetLcdFilter(..., FT_LCD_FILTER_LIGHT)`.
4. Treat any other error as renderer initialization failure.

This selects the current vendored Harmony default explicitly. It also gives a ClearType-style system build the equivalent light-filter policy.

Do not compare `LIGHT` and `DEFAULT` in the vendored build. Both filter calls are unavailable there. A filter A/B test requires a ClearType-style FreeType build and is outside the first fix.

Do not map LCD policy to hint strength.

Do not add a user-facing LCD-filter option now.

### Placement policy

Create one helper that returns both the integer pixel origin and bitmap phase.

Suggested shape:

```c
typedef struct {
  int pixel_x;
  unsigned int bitmap_index;
} GlyphXPlacement;

static GlyphXPlacement font_quantize_glyph_x(
  const RenFont *font, double x
);
```

For an LCD font with three phases:

1. Compute `q = floor(x * 3 + 0.5)` so exact ties always go right.
2. Divide with floor semantics to get the pixel origin.
3. Use a positive modulo to get phase 0, 1, or 2.
4. Pass the chosen pixel origin into bitmap drawing.

The tie rule must satisfy `quantize(x + 1).q == quantize(x).q + 3`, including negative `x`. Do not use `lround(...)`; its away-from-zero tie rule breaks this property across the origin.

Do not call `floor(draw_x)` again inside `draw_glyph_bitmap(...)`.

Keep one-phase grayscale placement unchanged in the first patch. Review whole-pixel rounding separately to limit visual churn.

## Implementation plan

## Phase 1: Add a focused reproduction and record red evidence

### Files

Add or update:

```text
tools/run_render_perf_gate.py
data/plugins/perf_benchmark.lua
tools/RENDER_PERF_GATE.md
tests/tools/test_render_perf_harness.py
```

Add a focused `font-raster-correctness` render scenario.

Add a harness renderer setting with values `d3d11` and `software`. The current harness forces `ANVIL_RENDERER=d3d11` and rejects every non-command result. An environment override alone cannot test software output.

Include the renderer in report metadata and golden paths. Never compare a software capture with a D3D11 golden by exact pixels.

The scene should use the exact bundled code font. It should draw:

- repeated U+2500;
- a connected box such as `┌────────┐`;
- ASCII stems such as `iiiiiiii` and `========`;
- the text at several physical sizes;
- lines at cached phases 0, 1/3, and 2/3;
- lines immediately below, at, and above quantizer boundaries 1/6, 1/2, and 5/6;
- equivalent negative origins translated by an integer pixel;
- separate grayscale and subpixel `RenFont` instances.

Use one dark background and one light background. Use opaque text colors.

Add a seam analyzer for the repeated U+2500 rows. It should:

1. Exclude the first and last glyph cells.
2. Use fixture metadata for the text origin, baseline, requested size, run length, and measured advance.
3. Find the stroke rows from the known foreground and background colors.
4. Sample predicted glyph boundaries and control pixels midway between boundaries.
5. Report the maximum per-channel boundary-to-control difference for each stroke row.
6. Report row-wide periodic energy at the measured glyph advance as a diagnostic.
7. Fail when the boundary contrast exceeds a fixed threshold on either background.

The assertion must test continuity, not one exact theme color.

Choose the threshold before the renderer fix. It must separate the known bad Anvil capture from the Edge reference with a recorded margin. Store the threshold and fixture geometry in the scenario, not in a golden image.

Also record the DirectWrite lower-edge coverage range and first stable-stroke ppem. Use matched effective device-pixel sizes.

Run the scenario before implementation. Record the failing rows and channel ranges.

Keep the existing exact screenshot capture. Add a golden only after the behavior assertion passes.

### Optional low-level diagnostic

Add a test-only or compile-time diagnostic dump if the image does not explain a failure.

For one glyph, record:

```text
requested size
actual x_ppem and y_ppem
load flags
render mode
LCD algorithm, geometry, and filter initialization result
HarfBuzz advance
FreeType advance
linear advance
lsb_delta and rsb_delta
bitmap_left and bitmap_top
bitmap width and rows
selected subpixel phase
final integer pixel origin
```

Do not expose these fields through the normal Lua renderer API.

## Phase 2: Fix nearest subpixel placement

### Files

Change:

```text
src/renderer.c
```

Add `GlyphXPlacement` and `font_quantize_glyph_x(...)`.

Replace every duplicated expression based on:

```c
fmod(x, 1.0) * SUBPIXEL_BITMAPS_CACHED
```

The affected paths include:

- shaped-run drawing;
- unshaped-run drawing;
- software top-level drawing;
- D3D11 top-level drawing.

Change `draw_glyph_bitmap(...)` to receive the selected integer pixel origin.

Keep the exact pen position for advances. Quantize only the bitmap placement.

Handle negative x positions with floor division and positive modulo. This matters when the left clip cuts through a glyph.

### Verification

Run the focused scenario before any hinting change.

If the seams disappear, retain the remaining phases because they still correct real policy defects.

Verify that these public values do not change:

- `font:get_width(...)`;
- `font:text_layout(...)` advances;
- caret positions;
- wrapping points.

## Phase 3: Refactor and correct the FreeType policy

### Files

Change:

```text
src/renderer.c
data/core/style.lua
```

Keep the public option names:

```text
antialiasing: none, grayscale, subpixel
hinting: none, slight, full
```

Do not add compatibility aliases or another quality mode.

### Changes

1. Replace `font_set_load_options(...)` with a pure policy builder.
2. Remove `FT_LOAD_FORCE_AUTOHINT` from slight and full modes.
3. Set `FT_LOAD_NO_HINTING | FT_LOAD_NO_AUTOHINT` for none mode.
4. Keep layout metric flags separate from bitmap flags.
5. Set HarfBuzz FreeType load flags explicitly.
6. Remove LCD filter side effects from glyph loading.
7. Initialize the RGB-thirds LCD policy in `ren_init()` with the Harmony/filter fallback sequence above.
8. Store the resolved policy on `RenFont` or derive it from immutable font fields.
9. Clear glyph and shaped-width caches whenever a policy field changes.
10. Keep color-glyph loading separate. Embedded bitmaps, COLR outline layers, and color scaling use different paths. State that COLR outline layers use the bitmap hint policy but render grayscale masks for composition.

Update comments in `data/core/style.lua`. Add the missing `none` antialiasing value. State that hinting controls bitmap fitting, not text layout.

### A/B sequence

Do not combine all visual choices in one unmeasured patch.

Run these candidates in order:

1. Native-preferred hints with the explicit RGB-thirds LCD policy.
2. Forced auto-hints with the same LCD policy as a diagnostic reference.
3. Grayscale full hinting as a diagnostic reference.

Select the smallest policy that makes normal-size connected glyphs stable.

Do not change `anvil_defaults.lua` to grayscale as the primary fix. Subpixel rendering should work correctly.

## Phase 4: Correct physical size rounding

### Files

Change:

```text
src/renderer.c
```

Do not replace the cast with `lroundf(pixel_size)` without accepting a layout change. Natural glyph advances and HarfBuzz advances use the active face scale. Changing 18 px to 19 px therefore changes widths, carets, and wrapping.

Use one explicit size model for scalable faces instead:

1. Convert the requested physical size to 26.6 nominal pixels.
2. Request that fractional nominal size with `FT_Request_Size(...)`, or use `FT_Set_Char_Size(...)` at 72 dpi.
3. Let FreeType round `x_ppem` and `y_ppem` to the nearest integer for hint execution.
4. Keep the fractional face scale for natural layout advances.

For `FT_Set_Char_Size(...)`, the request is:

```c
long rounded_26_6 = lroundf(pixel_size * 64.0f);
FT_F26Dot6 requested_26_6 = (FT_F26Dot6)(rounded_26_6 < 64 ? 64 : rounded_26_6);
FT_Set_Char_Size(face, 0, requested_26_6, 72, 72);
```

At 72 dpi, points and pixels have the same numeric value. The input has 1/64-unit precision. The resulting ppem is still an integer.

Keep the existing nearest-strike selection and `color_scale` handling for fixed-size color faces. Do not send those faces through the scalable-size request.

Store or log the requested 26.6 size, resulting `x_ppem`, resulting `y_ppem`, and face scales during diagnostics.

Keep logical UI size, physical requested size, and integer hinted ppem as separate named values.

Review these metrics after the change:

```text
font->height
font->baseline
font->underline_thickness
font->space_advance
HarfBuzz advances
```

This size correction intentionally changes layout at fractional physical sizes because the old layout used a truncated scale. Record those changes as the explicit layout change allowed by the user-visible contract. Integer physical sizes must remain unchanged.

Verify zoom in both directions. The same requested zoom must select the same scale and ppem regardless of zoom history.

## Phase 5: Make the common glyph path obvious

The current shaped and unshaped paths repeat placement and draw decisions.

Introduce one small internal operation for a resolved glyph:

```c
static void draw_resolved_glyph(
  DrawGlyphContext *ctx,
  RenFont **fonts,
  RenFont *font,
  unsigned int glyph_id,
  double glyph_x,
  double y,
  double y_offset,
  bool draw_missing
);
```

This operation should:

1. Quantize the x placement once.
2. Select the matching cached bitmap.
3. Load the metric and surface.
4. Draw with the selected integer origin.
5. Update render statistics once.

Keep shaping and advance calculation outside this helper.

Do not merge width calculation with drawing. They have different performance and cache needs.

Use this refactor only after the first fixes are green. Avoid hiding causal changes inside a broad rewrite.

## Phase 6: Verify both output paths

### D3D11

Run the focused render scenario through the default D3D11 command renderer.

Check:

- no periodic seams;
- stable output across three captures;
- no new atlas sampling marks;
- no changed clipping at the left and right edges;
- no increase in glyph texture uploads after warm-up.

### Software

Run the same fixture through the new harness renderer setting:

```text
python tools/run_render_perf_gate.py --scenario font-raster-correctness --renderer software
```

The harness must set `ANVIL_RENDERER=software` and skip its current `renderer_path == "commands"` assertion for this mode.

Check the same connected rows.

The two paths need not produce byte-identical antialiasing. They must agree on glyph origin, phase, and continuity.

If practical, add a software-surface test around `ren_draw_text(...)`. Link only the renderer dependencies needed by that test.

Do not create a second font implementation only to make the test easy.

## Phase 7: Consider gamma-correct LCD blending only if needed

Enter this phase only when a corrected mask still shows visible color edges.

First measure the same glyph mask over light and dark backgrounds. Separate mask defects from blend defects.

If blending remains wrong, prototype one D3D11 change before changing the software path.

Possible approaches include:

- an sRGB render-target view with linear shader output;
- explicit transfer conversion in the text shader;
- a calibrated coverage curve that matches the software path.

Do not change the complete UI color pipeline for one text issue.

Any gamma change affects all antialiased text. It requires new visual goldens and broad manual review.

## Phase 8: Consider run-level coverage only as a last step

Do not implement a temporary run mask unless all earlier phases pass and overlap marks remain.

A run mask would need to handle:

- per-channel LCD coverage;
- different text colors;
- fallback fonts;
- combining marks;
- ligature glyphs;
- clipping;
- colored emoji;
- atlas batching and lifetime;
- D3D11 and software parity.

A simple channel-wise maximum is only an approximation of geometric union. It can undercount separate shapes inside one pixel.

If this phase becomes necessary, define the exact compositing model before implementation.

## Test plan

## Focused behavior tests

The main regression must test this durable behavior:

> A same-color connected box-drawing run has no periodic interior seam at normal code-font sizes.

Cover:

- bundled semi-light code font;
- bundled regular interface font;
- repeated U+2500;
- connected corners and horizontal lines;
- ligatures enabled and disabled;
- positive and negative clipped x origins;
- cached phases and every nearest-phase boundary;
- normal and increased zoom;
- dark and light backgrounds.

Do not assert exact keyboard zoom commands.

Do not assert one exact RGB edge value. Assert continuity and stable placement.

## Layout regression tests

Use existing public APIs to prove that placement, hint-source, and LCD-policy changes do not alter layout:

```text
font:get_width(...)
font:text_layout(...)
font:wrap_text(...)
```

Cover ASCII, U+2500, tabs, fallback glyphs, and one shaped non-ASCII run.

Test exact values only where the current public layout already requires them. Require equality before and after phases 2 and 3.

Test the size-model change separately. Integer physical sizes must keep the same values. For fractional sizes, record and assert the new fractional-scale values and stable wrapping points. Do not claim equality with the old truncated layout.

## Cache tests

Verify:

- a font resize clears old glyph phases;
- a font copy owns the correct policy;
- fallback children use their own policy and size;
- a stale display packet is rejected after font generation changes;
- repeated rendering does not upload unchanged glyph atlases again.

## Performance checks

Run only the focused scenario during each implementation slice:

```sh
python tools/run_render_perf_gate.py --scenario font-raster-correctness
```

After the common glyph-path refactor, also run:

```sh
python tools/run_render_perf_gate.py --scenario renderer-primitives
```

Run `--suite visual` only after the final raster policy is selected.

The expected pixel change is intentional. Do not update goldens until the seam assertion passes and the output is reviewed.

## Manual comparison matrix

Compare Anvil with Edge or VS Code using the exact bundled font file.

Record display scale and each renderer's effective device-pixel size. Do not equate a CSS `font-size` value with FreeType `y_ppem` without that conversion.

Use these physical sizes where possible:

```text
10, 12, 14, 15, 16, 18, 20, 24, 30 px
```

Check:

```text
────────────────────────
━━━━━━━━━━━━━━━━━━━━━━━━
┌──────────────────────┐
│                      │
└──────────────────────┘
iiiiiiiiiiiiiiiiiiiiiiii
========================
```

The goal is not pixel identity with DirectWrite. The goal is a comparable transition to stable strokes at normal sizes.

## Acceptance criteria

The work is complete when all these conditions hold:

1. The fixed seam analyzer passes at Anvil's standard code-font size.
2. The standard-size lower-edge coverage falls inside the reviewed DirectWrite reference range recorded with the red fixture.
3. The first stable-stroke ppem is no more than one ppem above the matched DirectWrite result.
4. Starting x phase does not create a recurring color pattern.
5. Negative clipped origins select the correct subpixel phase.
6. Dark and light themes both look stable.
7. D3D11 and software output both remain continuous.
8. Placement, hint-source, and LCD-policy changes leave widths, carets, and wrapping unchanged.
9. The explicit size-model change is deterministic and changes layout only at fractional physical sizes.
10. The focused red reproduction passes after the fix.
11. Existing renderer scenarios remain within their gate limits. The new scenario has a reviewed baseline.
12. No box-drawing character receives a hard-coded geometry replacement.
13. No default font is changed to hide the renderer defect.

## Red-green implementation order

Use these vertical slices:

1. Add the connected-line reproduction and confirm it fails.
2. Fix nearest-phase placement and confirm the same reproduction improves or passes.
3. Prefer native hints and confirm the normal-size stroke becomes stable.
4. Remove per-glyph LCD calls and initialize one explicit LCD policy. Confirm that vendored Harmony output does not change in this slice.
5. Adopt the fractional size model and confirm both layout values and zoom thresholds.
6. Refactor the common glyph draw path without changing output.
7. Run the focused D3D11 and software checks.
8. Update visual goldens only after review.

For each slice, record:

- the command used;
- the failing observation before the change;
- the exact change;
- the passing observation after the change.

## Risks and controls

### Text appearance changes broadly

Native hints can alter many glyphs at small sizes.

Control this risk with the font-raster scene and the existing renderer-primitives scene. Review prose, code, interface, and fallback fonts.

### Layout changes accidentally

Bitmap load flags can change wrapping and caret positions if they leak into layout loads. The size-model phase also changes fractional-size layout intentionally.

Keep the current layout flags explicit. Test public layout APIs after each policy slice. Review the size-model deltas separately.

### Cache contamination

A changed phase or raster policy can reuse old bitmaps if the cache key is incomplete.

Keep raster policy immutable for one `RenFont`. Clear all glyph caches on size or option changes.

### Cross-platform differences

Native hints and FreeType build options can vary by platform.

Assert continuity rather than exact Windows pixels in portable tests. Keep Windows exact goldens in the Windows render gate.

### Performance regression

A helper refactor can add work per glyph.

Keep placement arithmetic allocation-free. Do not create run masks or temporary surfaces in the main fix.

## Non-goals

- Do not replace FreeType with DirectWrite.
- Do not create a Windows-only text renderer.
- Do not special-case U+2500 in the first implementation.
- Do not change the bundled code font.
- Do not disable subpixel antialiasing globally.
- Do not add an LCD-filter preference.
- Do not implement full application color management.
- Do not redesign HarfBuzz shaping.
- Do not change text layout merely to improve raster appearance.

## Recommended first patch

The first implementation patch should contain only:

1. The focused failing reproduction.
2. Nearest-third subpixel placement with correct carry.
3. Correct negative-coordinate handling.

The second patch should contain:

1. Native-preferred hinting instead of forced auto-hinting.
2. Explicit HarfBuzz layout flags that match the current HarfBuzz default.
3. Removal of per-glyph LCD calls.
4. One explicit RGB-thirds LCD policy during renderer initialization.

The third patch should contain the fractional nominal-size model and its explicit layout updates.

Keep gamma correction, run masks, and box-drawing geometry out of that patch.

This order preserves red-green evidence and separates placement, hinting, and size effects.
