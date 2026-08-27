# Long Line and Horizontal Scroll Plan

## Status

This plan reflects the current Text View and Display Packet code.

Stages 1 through 5 are the required work. Stage 6 is optional.

Each stage is one red-green slice. Do not implement all stages before running tests.

## Goal

Keep very long unwrapped lines correct and responsive.

The completed work must provide these results:

- horizontal drawing does not process a complete huge line;
- horizontal scrolling shows the correct source text;
- a pending width scan exposes one bounded scroll range;
- find and navigation reveal requests survive a pending scan;
- the final scrollbar range equals the exact Buffer width;
- common huge-line measurement yields within one Buffer line;
- common far-right hit testing does not scan every prior character;
- revealed ranges stay outside the fixed gutter;
- wrapped Display Packets keep their current behavior;
- custom Text View presentations keep their current fallback behavior.

## Non-goals

Do not include these changes:

- changes to Buffer storage;
- changes to soft-wrap behavior;
- a new user preference;
- a new worker process;
- persisted approximate widths;
- direct cached D3D11 glyph packets;
- exact timing assertions in automated tests;
- unwrapped Display Packets without measured evidence.

## Current faults

### Unwrapped lines enter the Display Packet path

`data/core/textview_line_packets.lua` does not require `view.wrapped_settings` in `eligible()`.

An unwrapped Buffer line has one visual row. `compile_syntax()` therefore compiles the complete line.

This behavior conflicts with `NATIVE_LINE_DISPLAY_PACKET_PLAN.md`. That plan excludes unwrapped long-line rendering.

The normal renderer already limits unwrapped drawing to a visible source range. The packet path runs before that renderer.

### Horizontal movement rebuilds the packet

The packet base signature includes `screen_x` and the active clip geometry.

Horizontal animation changes `screen_x`. Each animation step can discard and rebuild the complete packet.

The byte limit applies after packet construction. It does not protect the cold-build frame.

### Width discovery has an incomplete pending state

`get_max_unwrapped_line_width()` returns `nil` while its scan runs.

`get_h_scrollable_size()` then reports the viewport width. The horizontal scrollbar can disappear during the scan.

`clamp_scroll_position()` removes the horizontal upper bound during this period. Manual input can move without a known limit.

The scan checks its budget only after each complete line measurement. One expensive line can block the UI.

### Far-right hit testing can scan the complete prefix

`TextView:get_x_offset_col()` walks every UTF-8 position on a long line.

The plain ASCII forward mapping already has a constant-time monospace path. The inverse mapping does not use it.

### Range reveal uses inconsistent gutter coordinates

Single-caret and same-line range reveal calculate their left edges differently.

The current tests compare against the viewport edge. They do not compare against the fixed gutter edge.

## Design rules

### Keep the first fix small

Restore the documented packet boundary first. Do not design unwrapped packet slices in Stage 1.

### Use one horizontal extent state

Keep one state for exact, provisional, scanned, and required widths.

Do not add independent caches for the same scroll decision.

### Keep exact final results

A pending scan can use a provisional width. A completed scan must publish an exact width.

Never persist an approximate width.

### Separate programmatic reveal from manual input

A reveal can increase its required extent before it changes the scroll target.

Manual wheel, touch, and scrollbar input must not increase the extent.

### Treat stale width as provisional

A previous exact width can overestimate after an edit. It is not a safe upper bound.

This temporary overestimate is acceptable. The completed scan must replace it.

### Do not promise sublinear general text measurement

Exact shaping can require an atomic Font run.

Optimize common ASCII lines first. Add general indexes only when measurements justify them.

## Stage 0: Add focused test support

Use a Standard Editor with wrapping disabled.

Add only the fixtures needed by each stage. Useful fixtures include:

- a huge plain ASCII line;
- a syntax-tokenized ASCII line;
- ASCII with tabs;
- multibyte UTF-8 text;
- a short line after the huge line;
- a unique suffix near the huge line end.

Generic tests disable Display Packets. Set `view.__test_force_line_packets` only in focused packet tests.

Use renderer capture or packet inspection only at the renderer boundary.

Do not add frame-duration assertions.

## Stage 1: Restore the packet eligibility boundary

### Red test

Add one focused unwrapped drawing test.

1. Open a huge unwrapped ASCII line with a unique suffix.
2. Force the production packet path through the existing test seam.
3. Draw at the left edge.
4. Draw again with the suffix in the viewport.
5. Capture the submitted source ranges.

The test must show these results:

- no unwrapped Display Packet is built;
- the fallback reason is `unwrapped`;
- the left draw excludes the distant suffix;
- the far-right draw includes the suffix;
- neither draw submits the complete line.

Before the fix, the test must fail because packet construction consumes the complete line.

### Implementation

Make packet eligibility require an active wrapped layout.

Return the explicit fallback reason `unwrapped` when `view.wrapped_settings` is absent.

Place this check before contributor work and packet construction.

Do not change packet keys or contributor code in this stage.

### Green tests

Add one wrapped control case. It must still build and reuse a Display Packet.

Add focused far-right cases for tabs and UTF-8 text if current capture support can verify them.

Do not test animated rebuild counts after the unwrapped build count is already zero.

## Stage 2: Fix reveal coordinates

This stage is independent of width scanning. Complete it before recording reveal extents.

### Red test

Use line numbers and wrapping disabled.

1. Put a same-line target far to the right.
2. Reveal the complete target range.
3. Convert both target edges to screen coordinates.
4. Compare them with the visible text edges.

The target start must be at or right of the fixed gutter edge.

The target end must be at or left of the vertical scrollbar edge.

The current test only checks the viewport edge. Replace that weak assertion.

### Implementation

Use one content-coordinate model for caret and range reveal.

Name these edges in the code:

- viewport left;
- fixed gutter right;
- text origin;
- vertical scrollbar left.

Do not add a find-only correction.

### Green tests

Test direct range reveal and Text View Prompt Bar find navigation.

Use screen coordinates for the final assertions.

## Stage 3: Define one pending horizontal extent

Extend the existing completed cache and pending scan token. Do not create a second width system.

### State

The state must contain these values:

- measurement key;
- Buffer text revision;
- exact width for the current revision, when available;
- previous exact width for the same measurement key;
- width measured by the current scan;
- temporary width required by programmatic reveal;
- scan position and completion state.

The measurement key must cover every input that changes pixel width.

It must include these inputs:

- default Font identity, size, and native generation;
- applicable syntax Font identities, sizes, and native generations;
- surface scale;
- indentation and tab size;
- highlighter or render-token reset generation;
- line-render generation and invalidation generation.

Reuse a previous width only when this key still matches. A Font or scale change invalidates the old pixel width.

### Effective width

When an exact current width exists, use it.

During a scan, use the maximum of these provisional sources:

- width measured by completed scan work;
- previous exact width with the same measurement key;
- current programmatic reveal requirement;
- specialized presentation extents.

Do not synchronously measure selection lines from `get_h_scrollable_size()`.

A reveal already measures its target edge. Record that edge before changing `scroll.to.x`.

Manual input must clamp to the current effective width. It must not expand the reveal requirement.

A stale previous width can expose temporary empty space after a large deletion. The range remains finite.

### Scan completion

On completion:

1. verify the token, Buffer identity, revision, and measurement key;
2. publish the exact width;
3. clear the provisional reveal requirement;
4. clamp the target to the exact range;
5. keep a valid target unchanged;
6. update scrollbar geometry;
7. request one redraw.

Let normal scroll animation settle a small invalid target. Do not force a jump without evidence.

### Red-green tests

Add one focused test for each durable result:

- the previous width remains provisional during an edit scan;
- manual input stays within that finite provisional range;
- find reveal expands the pending range before it scrolls;
- completion clamps an invalid target;
- completion keeps a valid target unchanged;
- an edit prevents stale scan publication;
- a Font or Zoom change starts a new scan and publishes the new range.

Use deterministic test scan limits. Do not depend on wall-clock delays.

## Stage 4: Yield within common huge-line measurement

The scheduler must stop within common huge-line cases.

Do not replace exact widths with estimates.

### Reuse the existing fast path

`get_fast_ascii_monospace_x_offset()` already measures plain ASCII without tabs in constant time.

Use that path for exact width scans. Do not add another formula or duplicate cache.

The unused `cached_fast_ascii_monospace_width()` helper should not become a second width cache.

Remove it if no caller needs it after this work.

### Resumable measurement

Use a small cursor for lines that cannot use the constant-time path.

The cursor can contain:

- source line and current render token;
- byte position within that token;
- horizontal advance;
- tab offset;
- active Font;
- cancellation identity.

Process bounded source chunks. Check cancellation before and after each chunk.

Preserve tab offset across chunks.

Split UTF-8 only at valid byte boundaries.

Use the same shaping-boundary policy as unwrapped drawing for safe ASCII chunks.

Do not keep two shaping-sensitive ASCII tables in `textview.lua`.

Keep a shaping-sensitive run atomic when no exact split exists.

Record one quiet diagnostic when such a run exceeds the normal chunk size.

Token production can also be atomic. Record that cost separately if it causes a measured stall.

### Red-green tests

Test these results:

- completed ASCII width equals direct Font measurement;
- tabs preserve exact tab stops across chunks;
- multibyte text keeps the same exact width as unsplit measurement;
- cancellation prevents stale publication;
- a huge ASCII-with-tabs line yields before completion.

The yield test must use a deterministic chunk limit. Do not assert milliseconds.

## Stage 5: Make common far-right hit testing constant-time

Start with the common source-preserving monospace case.

### Plain ASCII path

For a line with one applicable monospace Font and no tabs:

1. divide the target x-coordinate by the cell width;
2. apply the half-cell nearest-caret rule;
3. clamp to valid Buffer columns;
4. handle the stored newline with existing Buffer rules.

This path must not fill a per-column cache.

### General path

Keep the token-aware path as the correctness fallback.

Do not add a binary search that calls the current `get_col_x_offset()` unchanged.

That function finds prior sparse cache entries with a reverse integer scan. A binary caller would not guarantee bounded work.

First measure the general fallback after the ASCII fix.

If tabs or complex text still stalls, reuse resumable width checkpoints from Stage 4.

Do not add a separate hit-test width index unless measurements require it.

### Red-green tests

Assert returned Buffer columns for these cases:

- first caret;
- middle caret;
- final caret;
- each side of a half-cell boundary;
- far-right plain ASCII;
- tabs near the target;
- multibyte text near the target;
- mixed syntax Fonts when a stable fixture exists.

Do not assert helper calls or cache size.

## Stage 6: Consider sliced unwrapped Display Packets

This stage is optional.

Start it only when a capture shows the bounded legacy path is still a material cost.

The Stage 1 fallback is an acceptable final design.

### Slice model

A packet must contain one bounded horizontal content slice.

Use viewport-sized content plus measured overscan.

Store these values:

- source byte bounds;
- exact advance before the first source byte;
- stable content-space slice identity;
- stable clip width.

The cache must support more than one slice for one Buffer line.

Do not key a slice by exact animated `screen_x`.

Scrolling inside one slice must replay the same packet at a new origin.

### Contributors

Whitespace markers and Indent Guides use horizontal clipping.

Compile them against the same content-space bounds.

Remove exact origin and clip position from signatures only after all contributors use slice coordinates.

### Build limits

Bound source bytes before packet construction.

Also let the builder reject excess command or text bytes during construction.

A rejected slice must use the bounded legacy renderer.

Never build the complete huge line before checking the limit.

### Red-green tests

Test these results:

- movement inside one slice reuses its packet;
- crossing a slice boundary selects another packet;
- both source edges draw the correct text;
- a tab can start before the slice and expand inside it;
- UTF-8 text is not cut at an invalid byte boundary;
- whitespace markers and Indent Guides use the slice clip;
- an oversized slice uses the legacy renderer;
- two Editors showing one Buffer own independent slices.

Visible text remains the primary contract. Packet diagnostics provide supporting evidence.

## Diagnostics

Use `core.log_quiet(...)` for rare state changes.

Useful events include:

- unwrapped packet fallback;
- scan start, cancellation, and exact publication;
- provisional previous-width reuse;
- programmatic reveal growth;
- expensive atomic Font or token run;
- longest line-measurement chunk;
- optional packet slice rejection.

Do not log each frame or scroll step.

Extend existing performance counters. Do not add another reporting system.

## Files

Primary files:

- `data/core/textview.lua`
- `data/core/textview_line_packets.lua`
- `tests/lua/ui/textview_scroll.lua`

Use `tests/lua/ui/textview_line_packets.lua` only if packet integration tests outgrow the scroll file.

Stage 6 can also change these contributors:

- `data/plugins/drawwhitespace.lua`
- `data/plugins/indent_guides.lua`

Stages 1 through 5 should not need native changes.

## Test commands

Run syntax checks for each changed Lua file.

```sh
./build-windows-x86_64/subprojects/luajit/src/luajit.exe check-lua-syntax.lua \
  data/core/textview.lua \
  data/core/textview_line_packets.lua \
  tests/lua/ui/textview_scroll.lua
```

Run the focused scroll tests.

```sh
PATH=/c/msys64/mingw64/bin:$PATH \
  /c/msys64/mingw64/bin/meson.exe test \
  -C build-windows-x86_64 anvil:lua-ui \
  --test-args ui/textview_scroll.lua \
  --print-errorlogs
```

Run a separate packet test only when that file exists.

```sh
PATH=/c/msys64/mingw64/bin:$PATH \
  /c/msys64/mingw64/bin/meson.exe test \
  -C build-windows-x86_64 anvil:lua-ui \
  --test-args ui/textview_line_packets.lua \
  --print-errorlogs
```

Do not run the complete suite for each stage.

## Manual verification

Use a file with one huge unwrapped line.

Include ASCII, tabs, UTF-8, and a searchable suffix near the end.

Verify these actions:

1. Drag the horizontal scrollbar slowly.
2. Use horizontal wheel input.
3. Hold horizontal caret navigation.
4. Click near the far-right text.
5. Find the suffix.
6. Edit the longest line while scrolled right.
7. Remove most of that line.
8. Switch away and return during a scan.
9. Repeat with two Editors showing one Buffer.

Confirm these results:

- no long freeze occurs;
- visible text stays correct during movement;
- the pending scrollbar range stays finite;
- find keeps the complete range outside the gutter;
- far-right clicks select the expected column;
- the completed range equals the actual widest content;
- the newest Anvil log has no packet build error.

## Performance verification

Capture before Stage 1 and after each measured optimization.

Compare these values:

- packet builds and source bytes for the huge line;
- unwrapped text draw time;
- width-scan work and longest chunk;
- far-right hit-test time;
- frame failures and packet fallbacks.

Do not set an automated frame-time threshold.

The important rule is bounded common-case work, not one machine-specific duration.

## Completion criteria

Stages 1 through 5 are complete when all these statements are true:

- unwrapped lines never enter complete-line packet construction;
- horizontal scrolling draws the correct visible source range;
- pending scans expose one finite provisional extent;
- reveal requests expand that extent before scrolling;
- exact scan completion replaces every provisional width;
- common huge-line measurement can yield within one line;
- common far-right hit testing avoids a complete prefix scan;
- find ranges remain outside the fixed gutter;
- wrapped packet behavior remains unchanged;
- focused Lua tests and syntax checks pass;
- manual verification shows no renderer error.

Stage 6 is complete only when sliced packets outperform the bounded legacy path.

If they do not, keep the Stage 1 fallback and remove unused slice code.
