# Native Line Display Packet Implementation Plan

## Status

Proposed implementation plan based on the performance recording:

```text
C:\Users\Darius\AppData\Local\Temp\anvil_perf_20260729_213623_summary.txt
```

This plan targets Standard Editor wrapped-line rendering. It does not attempt to replace the complete Anvil renderer in one change.

## Goal

Move stable, repeatedly reconstructed Document View line content out of the per-frame Lua draw path and into retained native **Line Display Packets**.

A Line Display Packet is an implementation-level, native-owned sequence of relative rendering commands for one Document line and its Wrapped Visual Rows. Once built, it can be replayed at a new screen origin and under the current clip without repeating Lua token traversal, substring creation, whitespace scanning, indentation analysis, or hundreds of Lua-to-native renderer calls.

The initial packet must contain the stable portions of ordinary wrapped source rendering:

1. syntax-highlighted text segments;
2. whitespace markers;
3. normal Indent Guides;
4. the Wrapped Visual Row boundaries needed to replay only visible rows.

Dynamic decorations remain outside the packet until there is evidence that moving them is valuable and safe.

## Performance target

The clean one-Document-View portion of the source recording measured:

| Work | Average cost per frame |
|---|---:|
| Draw emission | 6.14 ms |
| Document View line bodies | 4.58 ms |
| Draw Whitespace exclusive | 1.52 ms |
| Wrapped text inclusive | 1.59 ms |
| Indent Guides exclusive | 0.29 ms |
| Renderer end | 1.26 ms |
| Update | 1.44 ms |

At 164.96 Hz the complete frame budget is approximately 6.06 ms. The implementation should make ordinary stable frames fit that budget without disabling syntax highlighting, wrapping, whitespace markers, or Indent Guides.

The expected first-order saving is the removal of approximately 3.0-3.4 ms of repeated Lua reconstruction from a one-pane frame. Validate it in two modes: a detailed recording with the same scope instrumentation as the baseline, and a low-overhead cadence recording used for the headline refresh-rate result. The specific acceptance targets are:

- reduce clean one-pane `draw_emit_ms` from 6.14 ms to **3.0 ms or less on average** under the same detailed recording conditions;
- reduce same-mode `draw_emit_ms` by at least **50%** even if machine noise prevents the absolute target;
- in the low-overhead cadence run, achieve **at least 160 active-cadence FPS**, a complete-frame **p50 no greater than 5.5 ms**, a **p95 no greater than 6.06 ms**, and no more than **5% over-budget frames** during ordinary one-pane browsing;
- record the old wrapped-text, Draw Whitespace, and Indent Guide scopes plus the new packet build/replay scopes, but treat scope disappearance only as attribution evidence, never as proof of an end-to-end speedup;
- reduce their Lua/native submission count from hundreds of text/marker submissions to approximately one or two packet replays per visible Document line;
- avoid rebuilding packets on stable redraws caused by mouse movement, caret blinking, overlays, or unrelated UI animation;
- preserve the current rendering result and command ordering;
- keep complete ordinary frames near or below the 6.06 ms 164.96 Hz budget in the one-pane scenario;
- materially reduce long draw stalls associated with reconstructing the same visible lines.

Timing thresholds are validation goals, not exact automated-test assertions.

## Terminology

This plan follows `CONTEXT.md` for user-facing terms:

- **Document** is the editable text model.
- **Document View** is a visual surface showing a Document.
- **Standard Editor** is an ordinary source-code Editor.
- **Wrapped Visual Row** is one visual row created by wrapping a Document line.
- **Indent Guide** and **Diagnostic Underline** retain their glossary meanings.

**Line Display Packet** is internal implementation terminology, not a new user-facing concept and not a glossary addition.

## Current rendering path

The measured ordinary wrapped path is approximately:

```text
Root Panel
  -> node tree
    -> selected Document View
      -> centered editor wrapper
        -> DocView:draw_wrapped()
          -> visible Document lines
            -> selection/background wrappers
              -> Indent Guide wrapper
                -> diagnostic wrapper
                  -> DocView:draw_line_body()
                    -> backgrounds and selections
                    -> Draw Whitespace wrapper
                      -> Bracket Match wrapper
                        -> DocView:draw_line_text()
                          -> highlighter token traversal
                          -> token/row intersection
                          -> string:sub per rendered segment
                          -> renderer.draw_text[_known_bounds]
                    -> search/diagnostic/hint overlays
                -> Indent Guide submission
```

The dominant stable work is not D3D11 presentation. It is rebuilding equivalent text and decoration commands in Lua every time the Root Panel redraws.

Important source locations:

```text
data/core/docview.lua
data/core/linewrapping.lua
data/core/doc/highlighter.lua
data/plugins/drawwhitespace.lua
data/plugins/indent_guides.lua
data/plugins/bracketmatch.lua
src/api/renderer.c
src/rencache.c
src/rencache.h
src/ffiexports.c
data/core/jitsetup.lua
```

## Design principles

### Retain stable content; keep dynamic state dynamic

Packets should contain content that is stable across normal redraws. Carets, selections, current-line highlights, search results, hover state, diagnostics, and other rapidly changing overlays must not force text packets to rebuild.

### Preserve the existing renderer backends

The first implementation should replay packets into ordinary rencache commands. It must work with both:

- the default D3D11 command renderer;
- the software/SDL renderer selected through `ANVIL_RENDERER=software`.

Do not create a D3D11-only packet path in the first milestone.

### Optimize the steady state first

The critical behavior is:

```text
first visible draw or invalidation -> build packet
subsequent stable redraws          -> cache lookup + native replay
```

The cold build path may initially use Lua to produce packet commands, provided it runs only on real invalidation and does not reconstruct all visible lines every frame. Cold-build costs should then be measured before deciding whether the packet compiler itself must move fully into C.

### Do not cache pixels as the first solution

A Canvas/texture cache would introduce difficult invalidation, scaling, subpixel scrolling, theme, and text-quality problems. Retained native draw commands are a smaller boundary and preserve normal text rendering.

### Preserve exact draw order

Packets must not silently change layering. The relevant current order is:

1. line backgrounds and selection/search backgrounds;
2. whitespace markers;
3. source text;
4. Bracket Match decorations from the current `draw_line_text` wrapper;
5. search outlines, Diagnostic Underlines, and Line Hints;
6. Indent Guides from the current outer `draw_line_body` wrapper;
7. caret and IME overlays.

If Indent Guides are retained inside the packet, the packet needs replayable command layers so their foreground layer can still be emitted at the existing point.

## Scope

### Included in the first complete implementation

- a native Display Packet userdata and renderer API;
- native storage of text, rectangle, and rectangle-grid commands;
- relative-coordinate packet commands;
- command layers and Wrapped Visual Row ranges;
- replay into the existing rencache command stream;
- Standard Editor wrapped syntax text;
- ordinary Draw Whitespace behavior;
- ordinary normal-color Indent Guides;
- bounded per-Document-View packet caching;
- precise invalidation for text, token, wrap, font, theme, and feature-setting changes;
- fallback to the existing Lua path for unsupported presentation modes;
- diagnostics and performance counters;
- targeted native and Lua UI regression tests;
- a real capture using `VehicleModelInfo.cpp` after implementation.

### Excluded initially

- Markdown Live Preview and custom `render_line` fragments/widgets;
- custom decoration-provider text colors;
- selections, current-line backgrounds, search highlights, and Copy Feedback Highlight;
- Diagnostic Underlines and Line Hints;
- Bracket Match;
- caret and IME rendering;
- line-number gutters;
- Title Bar tabs;
- unwrapped long-line rendering;
- direct cached D3D11 glyph-instance packets;
- background-thread packet compilation;
- a user-facing packet-cache setting.

The exclusions are deliberate correctness boundaries. Unsupported lines continue through the existing renderer rather than losing behavior.

## Target architecture

### Native packet representation

Add an opaque native packet type, conceptually:

```c
typedef struct RenDisplayPacket RenDisplayPacket;
```

A packet owns:

- an immutable command buffer after sealing;
- copied text bytes used by text commands;
- per-command relative bounds and origins;
- retained Font/font-group references from the moment each text command is added;
- the tab size, tab offset, native Font generation, and surface-scale signature used to compile each text command;
- command-layer ranges;
- Wrapped Visual Row command ranges;
- total allocated bytes and command counts;
- a sealed/valid state.

Initial command types:

```text
TEXT_KNOWN_BOUNDS
RECT
RECT_GRID
```

All packet text should have known relative bounds by the time the packet is sealed. Width measurement and tab-aware advance calculation occur during cold compilation, not during every replay.

Packet replay must also make mutable Font state visible to rencache dirty hashing. Ordinary translated text commands should include the captured native Font-generation signature in their hashed bytes, or the renderer must explicitly invalidate affected rencache cells when that generation changes. Rebuilding a packet with the same Font pointer is not sufficient if the Font's glyph metrics or rasterization changed in place.

### Why packets should expand into normal rencache commands

Do not add a `DRAW_PACKET` command containing only a packet pointer to the frame command stream. The current rencache hashes command bytes and bounds to determine dirty regions. Hashing a pointer would not reflect packet content and would create lifetime hazards.

Instead, replay should append translated ordinary commands to the active `RenCache`:

```text
packet-relative command
  + draw origin
  -> ordinary translated rencache command
```

This preserves:

- dirty-cell hashing;
- clipping behavior;
- D3D11/software parity;
- existing renderer-end traversal;
- current frame statistics.

The replay loop is native, so Lua crosses the boundary once per replay rather than once per syntax or whitespace segment.

### Suggested native files

```text
src/display_packet.h
src/display_packet.c
src/rencache.h
src/rencache.c
src/api/renderer.c
src/api/api.h
```

`display_packet.h` should expose an opaque packet/builder API. `rencache.c` should remain the owner of appending actual frame commands, either through a focused internal append API or a `rencache_replay_display_packet()` entry point.

Do not duplicate the complete rencache command executor in `display_packet.c`.

### Lua renderer API

Suggested shape:

```lua
local builder = renderer.display_packet.new()

builder:add_text_known_bounds(
  layer, visual_row,
  font, text,
  relative_x, relative_y,
  bounds_x, bounds_y, bounds_w, bounds_h,
  color,
  tab_offset,
  tab_size
)

builder:add_rect(
  layer, visual_row,
  relative_x, relative_y, width, height, color
)

builder:add_rect_grid(
  layer, visual_row,
  relative_x, relative_y,
  step_x, width, height, count, color
)

local packet = builder:seal()
packet:draw(origin_x, origin_y, layer, first_visual_row, last_visual_row)
-- Later, on cache eviction or permanent disposal:
packet:release()
```

The exact argument packing may be adjusted to reduce API complexity, but these semantics are required:

- packet construction is explicit;
- sealed packets are immutable;
- draw origins are supplied at replay;
- callers can replay one layer and one visible Wrapped Visual Row range;
- packet memory usage is queryable for cache accounting;
- `release()` is idempotent, prevents future replay, and immediately frees packet command/text storage and persistent Font references once the renderer has independently pinned resources required by the active frame;
- malformed commands produce a Lua error during construction, not memory corruption;
- a packet can be garbage-collected safely without a target window.

The API should be implemented as ordinary Lua C functions. It does not need a LuaJIT FFI override: the hot operation is already one C call that processes many commands.

### Font ownership and frame lifetime

Packet commands store native `RenFont` pointers, so two distinct lifetimes must be protected:

1. **Build/retained lifetime:** the builder must retain every Lua Font or font group as soon as `add_text_known_bounds()` accepts it. The sealed packet continues to own those references while it is reusable.
2. **Active-frame lifetime:** replay copies raw `RenFont *` pointers into the rencache frame command buffer. Before replay returns, every referenced Font/font group must also be inserted into a renderer-owned active-frame reference table. That table is cleared only after `rencache_end_frame()` has synchronously consumed the commands.

The active-frame reference table is required in LuaJIT builds as well as non-JIT builds. Packet eviction, explicit `release()`, view closure, and Lua collection may all happen after replay but before frame end; none may free a Font still referenced by the frame command buffer.

Persistent packet ownership may use registry references or a userdata environment/uservalue table. Active-frame ownership should use one renderer-level table rather than pinning entire view caches.

A packet must be invalidated before replay when a retained Font's size, tab size, native generation, surface scale, or relevant metrics change. Retaining a Font prevents a dangling pointer; it does not make stale geometry correct. Replay must copy the packet's captured tab size into the ordinary rencache text command rather than reading whichever mutable tab size the shared Font currently has.

### Command layers

At minimum define:

```text
CONTENT_BEHIND_TEXT  -- whitespace markers
CONTENT_TEXT         -- syntax text
FOREGROUND_GUIDES    -- normal Indent Guides
```

The implementation may merge the first two into one ordered `CONTENT` layer because whitespace currently draws immediately before source text. Indent Guides require a separate replay range to preserve their current foreground position.

### Wrapped Visual Row indexing

A Document line can own many Wrapped Visual Rows. Every packet command must be assigned to a local row number, and the sealed packet must retain command offsets for each row.

Replay must accept a local row interval and skip commands belonging only to offscreen rows. This is essential for pathological long physical lines: compiling or replaying every wrapped row of a 100 KB line merely because one row is visible is unacceptable.

Use one of these bounded strategies:

- build row sub-packets lazily and attach them to one line entry; or
- keep one packet with an incrementally populated row-command index.

The first implementation should cap eager full-line compilation. Ordinary short lines may compile all rows, while very large lines compile only the visible row slice plus small overscan.

## Lua integration

### New core module

Create a focused module such as:

```text
data/core/docview_line_packets.lua
```

Responsibilities:

- decide whether a line is eligible;
- compute a packet cache key;
- build packet commands on a miss;
- retrieve and replay packet layers;
- maintain the per-view LRU and byte budget;
- expose diagnostics;
- invalidate affected packet entries;
- fall back cleanly when native packet APIs are unavailable.

`data/core/docview.lua` remains responsible for draw ordering and dynamic backgrounds/overlays. It should call the packet module only at the stable content seams.

### Eligibility

The first packet path should require all of the following:

- the view is a Standard Editor using ordinary `DocView` rendering;
- soft wrapping is active;
- the Document line exists;
- no custom `render_line` result is active for that line;
- no decoration provider overrides the complete text color;
- Markdown Live Preview is not active;
- the line's font/layout inputs are supported;
- each requested packet contributor is registered by its loaded plugin and currently enabled;
- the packet API exists in the running executable.

When any condition fails, use the existing Lua rendering path and emit a quiet diagnostic/counter identifying the fallback reason. Do not partially render an unsupported line.

### Syntax text compilation

On a packet miss:

1. obtain the same tokenizer sequence used by the current wrapped renderer through `Highlighter:get_line(line).tokens`/`Highlighter:each_token(line)`;
2. obtain the line's Wrapped Visual Row start/end byte columns;
3. intersect token ranges with row ranges;
4. resolve each segment's syntax color and syntax font;
5. calculate its relative x/y origin and tab offset;
6. measure nontrivial text exactly once;
7. append a known-bounds text command to the packet;
8. preserve existing newline trimming and row-continuation offsets;
9. retain the row's final advance for whitespace and test diagnostics.

The compiler must preserve:

- byte-column semantics used by the current wrapper;
- tabs and tab offsets;
- UTF-8 boundaries;
- syntax-specific fonts;
- font fallback groups;
- ligature-sensitive text;
- continuation-row indentation offsets;
- clipping at replay.

The fast ASCII monospace calculation may still be used during packet construction. It simply must not run every stable frame.

Do not switch this first implementation to `Highlighter:get_render_line()`. That API may substitute Tree-sitter/LSP render tokens, while the current wrapped renderer and ordinary wrap calculation use the tokenizer stream. Changing token sources would combine a rendering behavior migration with the performance rewrite and could produce different colors, segment boundaries, and wrap interactions. Any future semantic/render-token unification must update the legacy path, wrapping behavior, packet compiler, and parity fixtures together as a separate change.

### Draw Whitespace integration

Refactor `data/plugins/drawwhitespace.lua` so its reusable analysis and command-generation logic is callable without wrapping `DocView:draw_line_text()` for eligible packet lines.

The loaded and enabled plugin should explicitly register a first-party packet contributor with behavior equivalent to the current renderer:

- leading, middle, and trailing classification;
- `show_middle_min`;
- spaces and tabs;
- configured marker strings;
- leading/middle/trailing colors;
- wrapped-row clipping;
- tab-stop-aware placement;
- repeated-marker batching;
- rectangle-grid fallback where marker advance differs from a space;
- selected-only behavior where supported.

For the first vertical slice, `show_selected_only = true` may deliberately use the old Lua path because its result depends on live Selection State. The normal first-party default (`show_selected_only = false`) must use packets.

If the plugin is absent, disabled, or reloaded, its contributor must be absent or generation-invalidated immediately. Core packet compilation must never emit whitespace markers merely because old contributor state remains cached.

Whitespace commands belong before text commands in the packet's content layer.

Do not retain two independent line-run caches after integration. Move whitespace-run parsing into one reusable function and make the packet entry the owner, or have the existing cache provide immutable run data to the packet compiler.

### Indent Guide integration

Refactor `data/plugins/indent_guides.lua` so ordinary guide geometry can be emitted into the packet's foreground-guide layer.

Preserve:

- effective indentation for blank lines;
- indentation size and tab behavior;
- horizontal clipping;
- current guide width;
- configured normal guide color;
- rectangle-grid batching;
- closing-block and neighboring-line behavior.

`highlight_active = true` depends on the active caret and can use translucent colors for which drawing an active guide over a cached normal guide would not preserve current compositing. In the first implementation, use the complete existing dynamic Indent Guide path whenever active highlighting is enabled. Do not packetize any guides in that mode.

When `highlight_active = false`, which is the current default, all ordinary guide commands can replay from the packet. A later measured change may add an explicit guide-depth exclusion mechanism, but it is not part of this milestone.

### Plugin wrapping cleanup

The packet path should not add another chain of `DocView` monkey patches. Introduce an explicit first-party line-packet contributor seam or direct module calls from `docview_line_packets.lua`.

Contributors must have explicit registration and activation lifetime. Loading a plugin registers it, disabling/unloading it removes or deactivates it and invalidates affected entries, and reloading replaces rather than stacks its registration.

Once packet integration is complete:

- eligible lines must not execute the old Draw Whitespace or Indent Guide wrapper work;
- ineligible lines must continue to receive existing plugin behavior exactly once;
- module reload must not stack duplicate wrappers or contributors;
- remove obsolete wrapper/cache code rather than retaining compatibility aliases.

This repository owns the bundled plugins, so update all in-repo callers together.

## Packet cache design

### Ownership

Packets are owned by a Document View, not globally by a Document, because their layout depends on:

- view width and wrapping settings;
- view font role and size;
- continuation indentation;
- presentation providers;
- per-view feature state.

A Document shared by two Document Views may therefore have two packet caches.

### Cache entry

Conceptual entry:

```lua
{
  packet = native_packet,
  source_line = source_line,
  token_identity = token_table,
  tokenizer_revision = tokenizer_revision,
  line_wrap_generation = line_wrap_generation,
  font_signature = font_signature,
  style_generation = style_generation,
  whitespace_signature = whitespace_signature,
  indent_signature = indent_signature,
  built_rows = built_rows,
  bytes = packet:bytes(),
  last_used_frame = core.render_frame_id,
}
```

Do not use only `Doc:get_change_id()` as the key. That would rebuild every visible packet after every edit, even when most visible lines are unchanged.

### Invalidation inputs

A packet must rebuild when any relevant input changes:

#### Document text

- line text changes;
- lines are inserted, removed, or shifted;
- a transaction replaces the line.

Use transaction changed ranges and existing Document/Highlighter invalidation seams. Preserve unaffected entries where line mapping remains valid; splice or invalidate suffix entries when line numbers shift.

#### Tokenizer tokens

- tokenizer output changes;
- tokenizer state changes on an earlier line and retokenizes this line;
- syntax Font selection changes.

Prefer a stable per-line tokenizer revision/identity over hashing every token string every frame. If the existing highlighter cannot provide one reliably, add a per-line tokenizer revision and bump it from `Highlighter:update_notify()`. Tree-sitter/LSP render-token generations are deliberately not packet inputs in the first implementation because the existing wrapped renderer does not consume `get_render_line()`.

#### Wrapping

- row boundaries for the line change;
- continuation offset changes;
- wrapping mode/width/indent changes;
- a syntax-Font change alters wrapping when tokenization-dependent wrapping is enabled.

Add or maintain a per-line wrap generation. A global `__wrap_layout_generation` alone is too broad for incremental edits because it would invalidate every cached visible line.

When `config.plugins.linewrapping.require_tokenization` allows syntax Fonts to participate in wrap-width calculation, include the relevant syntax Font identities, sizes, and native generations in the wrap settings signature and reconstruct affected row boundaries when they change. Rebuilding only the display packet against stale `wrapped_lines` is not correct. When wrapping intentionally uses only the default Font, preserve that existing behavior rather than broadening this change into a wrap-policy redesign.

#### Font and scale

- default code Font identity;
- Font size or height;
- syntax Font identities/sizes;
- indentation/tab size;
- application scale changes.

Compute one stable font/style signature per view or render frame, not by walking every syntax Font table for every line.

#### Theme/style

- syntax colors;
- whitespace colors;
- Indent Guide colors/width;
- line height or text y offset.

Use `core.color_theme_generation` for theme reloads. If runtime style mutation can bypass that generation, add one canonical `core.render_style_generation` bump function and update the Runtime Theme Editor and other in-repo style mutation paths to call it.

#### Feature settings

- Draw Whitespace enable state and substitutions/options;
- Indent Guide enable state, width, colors, and blank-line search behavior;
- any future packet contributor's generation.

Each contributor should expose a cheap generation/signature. Compute it once per frame or only when settings are changed, not once per line.

### Bounded memory

Do not retain a packet for every line ever scrolled through.

Use an internal per-view LRU bounded by both:

- resident packet count;
- native packet bytes.

Initial internal bounds should be selected from measurements, with a starting point around several viewportfuls and 8-16 MB per view. These are implementation safeguards, not user-facing preferences.

Eviction rules:

- never evict a packet while it is being replayed;
- prefer retaining currently visible and overscan packets;
- call the packet's idempotent native `release()` on eviction so command/text memory is reclaimed immediately rather than waiting for an unspecified Lua GC cycle;
- rely on renderer-owned active-frame Font references, not the evicted packet, for any commands already copied into the current frame;
- log unusually large single packets quietly;
- allow a pathological line to bypass retention if one packet exceeds the view budget.

### Long-line safeguards

For very large physical lines:

- build only visible Wrapped Visual Rows plus bounded overscan;
- cap per-build text and command bytes;
- avoid repeated-marker strings proportional to an unbounded offscreen run;
- preserve UTF-8 boundaries;
- fall back to the existing clipped Lua path if safe packet construction cannot be guaranteed;
- report the fallback through diagnostics.

## Rencache integration details

### Replay behavior

`rencache_replay_display_packet()` should:

1. validate packet sealing and requested layer/row range;
2. calculate translated command bounds and the worst-case bytes required by the selected commands;
3. reserve the complete worst-case frame-command capacity before changing command-buffer position or statistics;
4. if reservation fails, leave the frame buffer and statistics unchanged so the caller may use the legacy path;
5. pin every referenced Font/font group in the renderer's active-frame reference table;
6. skip commands definitely outside the active clip where doing so is cheap;
7. append equivalent ordinary commands to the active frame buffer;
8. copy packet-owned text bytes into the frame command buffer;
9. preserve captured tab offsets, tab sizes, Font generations, and Font fallback arrays;
10. update ordinary and packet-specific frame statistics only for the committed replay.

Replay must be transactional from the caller's perspective. No validation or allocation failure after the preflight step may leave a partial line in rencache. If implementation constraints require a checkpoint, restore command-buffer position, `resize_issue`, and all affected statistics before returning a recoverable failure.

### Frame statistics

Extend renderer diagnostics with fields such as:

```text
display_packet_replays
display_packet_commands_replayed
display_packet_text_commands_replayed
display_packet_rect_commands_replayed
display_packet_source_bytes
display_packet_frame_bytes_copied
display_packet_replay_ms
```

Lua-side diagnostics should add:

```text
docview_line_packet_hits
docview_line_packet_misses
docview_line_packet_builds
docview_line_packet_build_ms
docview_line_packet_replay_ms
docview_line_packet_evictions
docview_line_packet_resident_packets
docview_line_packet_resident_bytes
docview_line_packet_fallback_<reason>
```

Use `core.log_quiet(...)` for native API absence, oversized packets, stale packet rejection, and fallback reasons that would help diagnose future behavior.

### Dirty-region equivalence

A packet replay must produce the same command content and translated bounds as ordinary calls. Verify that:

- an unchanged packet at an unchanged origin hashes identically across frames;
- vertical scrolling changes the appropriate dirty cells;
- theme invalidation changes command color bytes;
- an in-place Font generation or surface-scale change affects dirty hashing or explicitly invalidates the relevant rencache cells;
- packet eviction/rebuild does not leave stale pixels;
- packet commands respect nested clip rectangles.

### Error handling

Native packet construction must validate:

- integer overflow in command/text allocation sizes;
- negative command counts;
- invalid row/layer indices;
- non-finite coordinates;
- invalid bounds;
- missing Fonts;
- packet mutation after sealing.

Packet construction may return a normal Lua error or recoverable nil/error result before it submits anything. Replay allocation failure must return a recoverable result with no frame-buffer side effects; only then may the Document View log quietly and render that line through the existing path for the frame.

## Implementation phases

Every phase follows red-green development at one observable seam. Run only the specific new/affected tests unless a phase crosses enough boundaries to justify broader testing.

### Phase 0: Lock down rendering parity and baseline

Before changing rendering:

1. Preserve the current performance capture and the clean-period numbers in this plan.
2. Add focused fixtures for wrapped Standard Editor lines covering:
   - one syntax token;
   - several syntax colors;
   - token boundary exactly at a wrap boundary;
   - token spanning a wrap boundary;
   - tabs;
   - non-ASCII text;
   - ligature-sensitive ASCII;
   - syntax-specific Fonts;
   - continuation indentation;
   - leading/middle/trailing whitespace markers;
   - blank-line Indent Guides;
   - horizontally clipped markers/guides.
3. Capture normalized renderer operations from the current Lua path for those fixtures.
4. Confirm existing `linewrap.lua`, `drawwhitespace.lua`, and `indent_guides.lua` tests are green before implementation.

Do not test exact keyboard shortcuts or cosmetic preference constants.

### Phase 1: Native Display Packet primitive

#### Red test

Add a focused native or Lua-runtime test proving that the renderer cannot yet create, seal, translate, range-filter, and replay a packet.

#### Implementation

- Add `API_TYPE_DISPLAY_PACKET`.
- Implement packet builder, sealing, idempotent explicit release, `__gc`, memory accounting, persistent Font retention, and renderer-owned active-frame Font pinning under LuaJIT and non-JIT builds.
- Add text-known-bounds, rect, and rect-grid packet commands.
- Capture tab size, tab offset, native Font generation, and surface-scale state in text commands.
- Add command layers and Wrapped Visual Row indices.
- Add preflight reservation and atomic translated replay into ordinary rencache commands.
- Add diagnostics.
- Keep the Document View unchanged.

#### Green validation

Test:

- command order;
- x/y translation;
- row filtering;
- layer filtering;
- clip interaction;
- Font lifetime after caller references are dropped;
- packet eviction/release after replay but before `rencache_end_frame()`;
- two views using one shared Font with different tab sizes;
- in-place Font generation and display-scale changes;
- allocation failure without partial command emission;
- garbage collection before and after sealing;
- malformed input rejection;
- software and D3D-compatible rencache command emission.

### Phase 2: Wrapped syntax text packet vertical slice

#### Red test

Add a UI test that draws the same eligible wrapped line twice and expects:

- equivalent normalized text operations;
- one packet build on the first draw;
- a packet cache hit/replay on the second draw;
- no second token/substring reconstruction.

Confirm it fails because every draw currently traverses tokens.

#### Implementation

- Add `data/core/docview_line_packets.lua`.
- Implement eligibility and one-line cache entries.
- Compile the same tokenizer stream used by the current wrapped renderer into the packet content layer.
- Replace only the ordinary wrapped syntax-text branch in `DocView:draw_line_text()`.
- Keep all custom render-line branches on the current path.
- Add a force-enable/force-disable test seam, not a user preference.

#### Green validation

Run the targeted wrapped-text tests and verify behavior for ASCII, tabs, UTF-8, ligatures, syntax Fonts, two-view tab sizes, and wrap-boundary token splitting. Verify separately that the packet path did not silently switch to Tree-sitter/LSP `get_render_line()` tokens.

At this phase, capture a short performance run. If cache hits do not substantially reduce `wrapped_text`, stop and correct the boundary before adding more contributors.

### Phase 3: Draw Whitespace packet integration

#### Red test

Add behavior tests comparing packet and legacy marker operations for the whitespace fixtures, plus a stable-redraw test showing the second draw does not rescan whitespace runs.

#### Implementation

- Extract reusable whitespace-run analysis from the wrapper.
- Add whitespace commands before text commands in the packet.
- Add contributor generation/signature.
- Register the contributor only while the plugin is loaded and enabled; invalidate it on disable or reload.
- Keep selected-only mode on the dynamic fallback initially if necessary.
- Ensure eligible packet lines bypass the old wrapper exactly once.
- Preserve tab and repeated-marker batching.

#### Green validation

Run only:

```text
tests/lua/ui/drawwhitespace.lua
tests/lua/ui/linewrap.lua
```

plus the new packet primitive/integration tests.

Take a short capture and verify end-to-end `draw_emit_ms` falls while the `draw_whitespace` scope disappears or becomes a small packet replay scope for eligible lines. Scope disappearance alone is not a passing result.

### Phase 4: Indent Guide packet integration

#### Red test

Add packet/legacy parity fixtures and a stable redraw test showing normal guide geometry is reused.

#### Implementation

- Extract guide geometry from the method wrapper.
- Add normal guides to `FOREGROUND_GUIDES`.
- Replay that layer at the existing foreground point.
- Register the contributor only while the plugin is loaded and enabled.
- Use the complete legacy guide path when active-guide highlighting is enabled.
- Add correct invalidation for neighboring blank-line effective indentation.
- Remove duplicate wrapper work for eligible lines.

#### Green validation

Run:

```text
tests/lua/ui/indent_guides.lua
tests/lua/ui/linewrap.lua
```

plus the packet tests.

### Phase 5: Precise invalidation and bounded caching

Implement and test one invalidation source at a time:

1. edit within one line;
2. insert a line;
3. remove a line;
4. tokenizer retokenization extending to later lines;
5. wrap-width change;
6. syntax-Font metric change while tokenization-dependent wrapping is enabled;
7. Font/Zoom and display-scale change;
8. theme reload;
9. runtime style mutation;
10. whitespace option and plugin activation change;
11. Indent Guide option, active-highlight mode, and plugin activation change;
12. plugin/module reload;
13. view close;
14. LRU count eviction with immediate native release;
15. LRU byte eviction with immediate native release;
16. eviction/release after replay but before frame end;
17. oversized-line bypass.

For each case verify observable output changes correctly and unaffected visible lines remain cache hits where safe.

### Phase 6: Remove obsolete per-frame code

After packet behavior is established:

- remove wrapped-path token/substring loops that are no longer reachable for eligible lines;
- remove duplicate whitespace caches and wrapper branches;
- remove duplicate Indent Guide wrapper branches;
- keep one explicit fallback implementation for unsupported modes;
- update comments and diagnostics to describe the retained packet model;
- do not retain deprecated packet API aliases.

### Phase 7: Final performance validation

1. Close Anvil because native binaries will be replaced.
2. Run:

```text
cmd.exe //d //s //c "call C:\Projects\c_projects\anvil-editor\update-anvil-dev-build.bat"
```

3. Restart the dev portable app.
4. Open:

```text
C:\Projects\decomps\GTAV Source\src\dev_ng\game\modelinfo\VehicleModelInfo.cpp
```

5. Reproduce the clean one-pane wrapped browsing scenario without opening the Fuzzy Searcher during the comparison window.
6. Make one detailed recording with the same scope instrumentation, target refresh, and window dimensions as the baseline.
7. Make a second low-overhead cadence recording with detailed per-line scopes disabled so the headline 164.96 Hz result is not defined by instrumentation cost.
8. Compare:
   - same-mode `draw_emit_ms` and Document View draw time;
   - packet hit/miss/build/replay metrics from the detailed run;
   - Lua heap growth and collection-correlated stalls from the detailed run;
   - renderer command counts/bytes, renderer-end time, and Present time;
   - active-cadence FPS and over-budget percentage from the low-overhead run;
   - complete-frame p50 and p95 from the low-overhead run.
9. Treat the old scope reduction only as attribution. The change passes performance validation only if end-to-end draw and complete-frame metrics improve.
10. Repeat with two visible Document Views to verify near-linear scaling, independent tab/layout state, and no cache cross-contamination.
11. Repeat once with `ANVIL_RENDERER=software` for backend correctness, Font-scale invalidation, and dirty-region behavior, not headline performance.

## Testing strategy

### Native tests

Add focused native coverage for the packet container and replay translator. If practical, separate packet command storage/translation from Lua so it can be tested without launching the full app.

Test:

- allocation growth and sealing;
- text ownership;
- Font reference retention through the Lua API;
- builder Font retention before sealing;
- active-frame Font pinning after packet release and Lua GC;
- captured tab-size replay across shared Fonts and two views;
- native Font-generation/surface-scale invalidation;
- translated bounds;
- row/layer ranges;
- command order;
- integer-overflow guards;
- empty packets;
- very large text rejection/bounding;
- atomic replay failure and command/statistics rollback;
- idempotent explicit release with immediate native memory reclamation;
- cleanup after partial construction failure.

Register a dedicated Meson target if the native primitive warrants it. Do not overload the unrelated `anvil:fuzzy` test.

### Lua UI tests

Primary files:

```text
tests/lua/ui/linewrap.lua
tests/lua/ui/drawwhitespace.lua
tests/lua/ui/indent_guides.lua
```

Add a focused file such as:

```text
tests/lua/ui/docview_line_packets.lua
```

Test through Document View drawing and renderer-operation capture, not by asserting private Lua helper call counts. Cache diagnostics may be asserted where the behavior under test is specifically retained reuse/invalidation.

### Packet/legacy parity harness

Provide a test-only way to:

1. force the legacy path;
2. collect normalized draw commands;
3. force the packet compiler;
4. inspect or replay normalized packet commands;
5. compare command type, text, Font identity/generation, color, relative bounds, tab offset, tab size, row, layer, and order.

Do not expose test fixtures as user configuration.

### Existing regression coverage

At relevant phases run only affected tests, for example:

```sh
PATH=/c/msys64/mingw64/bin:$PATH /c/msys64/mingw64/bin/meson.exe test \
  -C build-windows-x86_64 anvil:lua-ui \
  --test-args ui/docview_line_packets.lua \
  --print-errorlogs
```

Also run the existing specific files through `--test-args` as each contributor changes. Run the broader Anvil suite only after the native/core/plugin integration is complete because this feature crosses renderer, core Document View, wrapping, and first-party plugin boundaries.

### Lua syntax validation

After Lua edits:

```sh
./build-windows-x86_64/subprojects/luajit/src/luajit.exe check-lua-syntax.lua \
  data/core/docview.lua \
  data/core/docview_line_packets.lua \
  data/plugins/drawwhitespace.lua \
  data/plugins/indent_guides.lua \
  tests/lua/ui/docview_line_packets.lua
```

## Correctness scenarios

The implementation is not complete until these scenarios are exercised:

### Stable redraw

A mouse move causes a redraw with unchanged Document content. Every visible eligible line is a packet hit; no token splitting or whitespace scanning occurs.

### Caret movement

The caret moves within the same line. Text and whitespace packets remain valid. Normal guide packets remain valid while active highlighting is disabled; when it is enabled, the complete legacy Indent Guide path remains dynamic. Current-line background, Bracket Match, and caret update dynamically.

### Single-line edit

Typing changes one line. That line and any later lines whose highlighting/wrapping genuinely changes rebuild. Unaffected visible lines remain reusable.

### Multiline edit

Inserting/removing lines shifts cache entries safely. No packet from the old line number is replayed for different text.

### Theme change

Syntax, whitespace, and guide colors change on the next draw. Old packet colors never survive a theme generation change.

### Zoom/Font change

All metric-dependent packets and tokenization-dependent wrap boundaries rebuild. Native Font generation and surface scale participate in validation/dirty invalidation. No packet retains stale widths or stale Font pointers.

### Resize/wrap-width change

Changed Wrapped Visual Row boundaries invalidate the right entries. Rows do not overlap or disappear during incremental reconstruction.

### Two Document Views of one Document

Each view uses its own width/layout packets. Editing invalidates both views correctly without sharing incompatible geometry. Two views using the same Font but different tab sizes replay their captured tab state independently.

### Two visible Editors

Both panes render correctly, and packet cache statistics remain attributable per Document View.

### Very long line

Only visible Wrapped Visual Rows are built/replayed. Memory and frame time remain bounded.

### Custom presentation

Markdown Live Preview, line render widgets, custom full-line text colors, and unsupported providers take the fallback path with no missing content.

### Module reload

Reloading Draw Whitespace, Indent Guides, or the packet module invalidates old contributor generations and does not stack duplicate hooks.

### Disabled or absent contributor

Disabling or unloading Draw Whitespace or Indent Guides removes/deactivates its registered contributor, invalidates affected packet entries, and never leaves stale markers or guides in rebuilt packets.

### Same-frame eviction

A packet is replayed, evicted, explicitly released, and collected before frame end. Its native packet memory is reclaimed immediately, but renderer-owned active-frame references keep every Font alive until `rencache_end_frame()` completes.

### Replay allocation failure

Forced frame-command reservation failure leaves command-buffer position, `resize_issue`, and frame statistics unchanged. The legacy renderer then draws the complete line exactly once.

## Risks and mitigations

### Stale packet invalidation

**Risk:** incorrect text, colors, or positions persist after edits/theme/layout changes.

**Mitigation:** explicit generation inputs, parity tests, changed-range tests, and a debug mode that can rebuild and compare a sampled packet against its cached version.

### Dangling Font pointers

**Risk:** a packet or builder outlives its Font userdata, or a packet is released after replay while rencache still contains raw Font pointers.

**Mitigation:** builder/packet-owned persistent references, renderer-owned active-frame references under all Lua builds, clearing only after frame end, and tests that release/collect a packet between replay and frame completion.

### Excessive packet memory

**Risk:** scrolling through a large file retains all visited lines.

**Mitigation:** count/byte LRU, visible-line pinning, idempotent explicit native release on eviction, oversized-packet bypass, and packet byte diagnostics. Dropping a Lua reference alone does not count as reclaiming the byte budget.

### Mutable tab and Font state

**Risk:** a shared Font's current tab size, native generation, or surface scale differs from the state used to compile packet bounds.

**Mitigation:** snapshot tab size/offset and native Font state in packet commands, copy them into ordinary rencache commands, include generation in dirty hashing or explicit invalidation, and test two views with different indentation settings.

### Long-line cold-build hitch

**Risk:** one huge line takes too long to compile even if replay is cheap.

**Mitigation:** row-lazy compilation, per-build byte/command limits, visible-row overscan only, and safe fallback.

### Changed visual layering

**Risk:** Indent Guides or whitespace markers move above/below diagnostics or text.

**Mitigation:** command layers and packet/legacy ordered-command comparisons.

### Tests bypass packet behavior

**Risk:** current UI tests monkeypatch `renderer.draw_text`, while native replay bypasses those monkeypatches.

**Mitigation:** legacy fallback remains default under generic test stubs, while focused packet tests use an explicit force seam and packet-command inspection/parity harness.

### Dirty-region regression

**Risk:** packet replay hashes differently or fails to invalidate moved content.

**Mitigation:** expand packets into ordinary rencache commands and test unchanged, scrolled, clipped, recolored, and evicted cases.

### Partial replay before fallback

**Risk:** command-buffer allocation failure leaves half a packet submitted and prevents the legacy path from completing the line.

**Mitigation:** preflight and reserve the complete worst-case replay allocation, commit commands/statistics only after successful reservation, and test forced failure with exact rollback.

### Cold compilation merely moves Lua work

**Risk:** stable frames improve but typing produces large rebuild hitches.

**Mitigation:** first establish retained replay, then profile packet misses. If cold builds are significant, move token/row splitting and whitespace-run generation into a native compiler as a separate measured phase.

### Packet replay still copies text into the frame buffer

**Risk:** Lua time falls but native command-buffer copy or renderer-end work becomes the next bottleneck.

**Mitigation:** measure after the first implementation. Only then consider a second-level packet command reference or cached D3D11 glyph-instance representation with content-aware rencache hashing.

## Follow-up work after the primary target

Do not mix these into the first packet milestone unless measurements require them:

1. **Bracket Match:** stop wrapping every visible line; draw the matched pair once in a Document View overlay.
2. **Line Hint/diagnostic absence fast paths:** skip per-line provider work globally when no visible provider data exists.
3. **Gutter packet:** batch retained line-number text and stable gutter decorations.
4. **Title Bar packet:** retain Pane Tab labels/icons/layout while tab state is unchanged.
5. **Unwrapped Standard Editor packets:** extend the packet compiler with horizontal visible-range slicing for long lines.
6. **Viewport packet list:** if one replay call per visible Document line remains material, add a native multi-packet replay list.
7. **Native cold compiler:** move packet construction from Lua descriptors into C if edit-time misses are measurable.
8. **Cached glyph packets:** if renderer-end becomes dominant, cache shaped glyph/quad data below rencache while preserving backend and atlas invalidation correctness.

## Definition of done

The implementation target is complete when:

- eligible wrapped Standard Editor lines use native retained packets;
- syntax text, normal whitespace markers, and normal Indent Guides are packetized;
- stable redraws do not rerun their Lua token/whitespace/guide construction;
- dynamic overlays remain correct;
- unsupported presentation modes fall back without visual loss;
- builders and packets retain Fonts safely, active frames pin Fonts through `rencache_end_frame()`, and packet release cannot create dangling frame pointers;
- text replay preserves captured tab size, Font generation, and scale-dependent invalidation;
- packet replay is atomic and can fall back without partial emission;
- packet caches are bounded by immediately reclaimed native bytes, not merely collectable Lua references;
- absent, disabled, active-highlight, and reloaded contributors preserve existing behavior;
- targeted red-green tests cover packet replay, parity, invalidation, and eviction;
- affected existing UI tests pass;
- native build/tests pass;
- the dev portable app is rebuilt through `update-anvil-dev-build.bat`;
- same-mode detailed recording demonstrates at least the planned draw-time reduction or the required 50% reduction floor;
- a low-overhead clean one-pane recording meets the active-cadence, complete-frame percentile, and over-budget targets;
- a two-pane recording confirms correct independent caches and expected scaling;
- diagnostics explain packet hits, misses, rebuilds, memory, and fallback decisions.
