# Markdown Live Editor Plan

## Purpose

Build an Obsidian-style Markdown editing experience inside Anvil's normal `DocView` editing surface.

The goal is **not** a separate rendered preview. A Markdown file should open as an ordinary editable Document View, but Markdown-specific lines, spans, links, embeds, and images should be rendered with a polished reading appearance while the underlying file remains plain Markdown text.

This plan uses the working name **Markdown Live Editor** for the feature.

## Product goals

- Markdown files remain normal editable text documents.
- The raw Markdown document is the only source of truth for save, undo, redo, selections, copy, search, find/replace, and external-tool round trips.
- The view renders Markdown nicely in-place:
  - headings use heading-sized fonts
  - emphasis/code/link styling reads naturally
  - image syntax can render the image inline in the editor
  - blockquotes, rules, lists, task items, tables, footnotes, and code fences can be progressively upgraded
- Obsidian-style links are parsed and resolved:
  - `[[Note]]`
  - `[[Note|Alias]]`
  - `[[Note#Heading]]`
  - `[[Note#^block-id]]`
  - `[[#Heading in current note]]`
  - `[[^block in current note]]` / cross-vault block search where feasible
  - `![[Note]]` note embeds
  - `![[image.png]]` attachment embeds
  - `![[image.png|640x480]]` and `![[image.png|100]]` resize syntax
  - standard Markdown links/images, including local project files and remote URLs
- Markdown-specific rendering is opt-in for Markdown documents and should not alter normal `DocView` behavior for code or plain text.
- The implementation should be a clean extension of existing `DocView` rendering/editing primitives, not a preview-view hack.

## Non-goals for the first implementation pass

- Full Obsidian application parity: graph view, backlinks pane, sync, plugin ecosystem, Canvas, or properties UI are out of scope.
- A ProseMirror-style rich document model is out of scope. The document remains plain text.
- A separate mandatory Markdown preview is not the primary user experience. Existing `MarkdownView` may remain as a rendered preview/tool during migration, but the target path is live editing in `DocView`.
- Audio/video/PDF inline players are not required for the first image-focused milestone. Their link/embed syntax should be parsed and represented, then opened externally or as attachment chips until renderers exist.

## Research summary

### Obsidian behavior

Sources reviewed:

- `https://obsidian.md/help/edit-and-read`
- `https://obsidian.md/help/syntax`
- `https://obsidian.md/help/links`
- `https://obsidian.md/help/How+to/Embed+files`
- `https://obsidian.md/help/file-formats`
- `https://obsidian.md/help/attachments`

Relevant observations:

- Obsidian has Reading view and Editing view.
- Editing view has two modes:
  - **Live Preview**: formatted text appears inline and most Markdown syntax is hidden; raw syntax is revealed when the cursor is in the formatted area.
  - **Source mode**: raw Markdown syntax is visible at all times.
- Internal links support both wikilink and Markdown syntax:
  - `[[Three laws of motion]]`
  - `[Three laws of motion](Three%20laws%20of%20motion.md)`
- Wikilink aliases use `|`, for example `[[Three laws of motion|laws]]`.
- Heading links use `#`, for example `[[About Obsidian#Links are first-class citizens]]`.
- Block links use `#^`, for example `[[Note#^quote-of-the-day]]`.
- Obsidian-specific block IDs use letters, numbers, and dashes.
- Embeds are internal links prefixed with `!`, for example `![[Document.pdf]]` or `![[Engelbart.jpg]]`.
- Image resize syntax is accepted in both wikilink embeds and Markdown images:
  - `![[Engelbart.jpg|640x480]]`
  - `![[Engelbart.jpg|100]]`
  - `![Engelbart|100x145](https://...)`
- PDF embeds can include fragment options such as `#page=3` or `#height=400`.
- Accepted Obsidian file formats include Markdown, Canvas/Base files, images (`avif`, `bmp`, `gif`, `jpeg`, `jpg`, `png`, `svg`, `webp`), audio, video, and PDF.
- Attachments are ordinary files in the vault. Obsidian can store them at the vault root, in a configured folder, beside the current note, or in a subfolder under the current note.

### Open-source / adjacent implementations

Sources reviewed:

- Atomic Editor (`https://github.com/kenforthewin/atomic-editor` and cached `docs/architecture.md`)
- `codemirror-markdown-hybrid` (`https://github.com/markdowneditors/codemirror-markdown-hybrid`)
- CodeMirror forum discussion: `Hybrid markdown editing (preview for unfocused lines, raw for active line)`
- VS Code `Clean Markdown Live Preview` extension listing

Important lessons:

- Keep raw Markdown as the source of truth. Rendered appearance should be view-only decorations/widgets.
- Prefer active-line or active-block raw reveal. It makes the inactive document pleasant to read while preserving precise text editing when the caret is on a construct.
- Avoid layout shifts. If a line becomes active and raw syntax appears, the line's height and major geometry should not change.
- Rebuild rendering narrowly around changed lines/blocks instead of reparsing the whole document on every keystroke.
- Use a freeze/deferral guard around mouse clicks if decoration rebuilds could move text under the pointer between pointer-down and pointer-up.
- Inline images and tables are the hardest cases because they are not just colored text; they need widgets with stable document-position mapping.
- CodeMirror-style solutions rely on incremental syntax trees/decorations. Anvil will need equivalent `DocView` primitives because its renderer is not DOM/CodeMirror-based.

## Current Anvil state

Relevant files:

```text
data/core/docview.lua
data/core/linewrapping.lua
data/core/markdownview.lua
data/core/imageview.lua
data/core/commands/markdown.lua
data/plugins/language_md.lua
data/colors/default.lua
tests/lua/ui/markdownview.lua
tests/lua/ui/docview_decorations.lua
```

### `DocView`

`DocView` already owns the normal editable text surface:

- file-backed `Document` editing
- selections/carets/IME
- syntax highlighting through `doc.highlighter`
- line wrapping through `core.linewrapping`
- folding and composed visual rows
- decoration providers for line backgrounds, inline range backgrounds, and text-color overrides
- visual row providers for extra provider-owned rows
- Point of Interest providers for navigation targets

However, the current rendering model assumes:

- one global line height from `DocView:get_line_height()`
- text width/position mapping is primarily `doc.highlighter` token text + `style.syntax_fonts`
- syntax tokens are drawn as raw text, not hidden/replaced by rendered widgets
- inline decorations cannot currently replace source spans with zero-width hidden syntax or image widgets while preserving source-position hit testing

### `MarkdownView`

`MarkdownView` is a separate rendered preview view. It already contains useful code that should be reused or extracted:

- Markdown block parser
- inline parser for emphasis, links, footnotes, images, reference links
- table parsing/render layout
- local/remote image loading and cache
- Markdown link opening for project-local files and anchors
- heading-sized font sets
- rendered command-list layout

But `MarkdownView` is not the final UX because it is not a `DocView` editor. It has its own selection/copy/render model and commands such as `markdown-view:preview` / `markdown-view:view-raw`.

### `language_md.lua`

The Markdown syntax plugin provides raw syntax highlighting and Markdown-specific font overrides for bold/italic tokens. This can remain useful as a fallback/source-mode layer, but it is not enough for live preview because it cannot hide syntax or render images/widgets.

## Core design principles

1. **Raw text is authoritative.**
   All rendering objects are projections of `Doc` text. Editing operations mutate only the `Doc`.

2. **Markdown rendering is view-local.**
   A Markdown Live Editor attaches providers/renderers to Markdown `DocView` instances only.

3. **Active-line raw reveal.**
   Inactive lines can hide Markdown syntax and show rendered content. Lines intersecting any caret/selection show raw syntax or a hybrid raw form so editing stays precise.

4. **No major layout shifts on activation.**
   A heading line keeps the same line height whether its `#` marker is hidden or visible. Image/widget rows should not appear/disappear merely because the caret enters the source line unless the row is deliberately replaced by an equivalently sized placeholder.

5. **Reusable core primitives, Markdown-owned policy.**
   `DocView` should gain generic render-extension hooks. Markdown-specific parsing, styling, and link resolution live in a Markdown module/plugin.

6. **Incremental by default.**
   Cache parsed Markdown blocks/spans by document change id and dirty line range. Recompute changed neighborhoods, not the whole file, once the basic implementation is stable.

## Proposed architecture

### New module layout

```text
data/core/markdown/
  init.lua                 -- Markdown Live Editor attach/detach entry point
  parser.lua               -- extracted/reworked parser from MarkdownView
  live_render.lua          -- DocView render providers and active-line reveal logic
  links.lua                -- Obsidian/wiki/Markdown link parser and resolver
  vault_index.lua          -- project/vault note + attachment index
  images.lua               -- image loading/cache/reuse from MarkdownView
  anchors.lua              -- heading slugs, block IDs, footnotes
  embeds.lua               -- embed classification/render plans
```

`data/core/markdownview.lua` should eventually use `core.markdown.parser`, `core.markdown.links`, and `core.markdown.images` instead of owning duplicate parsing/image logic.

### Activation

Markdown Live Editor should attach automatically when a `DocView` represents a Markdown file.

Possible detection:

- filename extension `.md`, `.markdown`, `.mdown`
- or syntax name contains `markdown`

Attach point options:

- in `core.root_panel:open_doc(...)` / `file_context.mark_editor_view(...)` after `DocView` creation
- or a small first-party plugin/thread that observes new `DocView` instances and attaches once

Preferred: explicit attach in the editor creation path so tests can instantiate and opt in deterministically, plus an idempotent lifecycle check that can attach/detach after an existing `DocView` changes filename or syntax.

Lifecycle requirements:

- Add a first-class `Doc` metadata/syntax change notification, or patch/wrap `Doc:set_filename(...)` and `Doc:reset_syntax(...)` in one well-owned core location, so existing views can re-run Markdown eligibility checks.
- Saving an untitled/plain document as `*.md` should attach Markdown Live Editor without recreating the view.
- Direct `doc:set_filename(...)`, save-as flows, project/file-tree rename flows, and syntax-only reset paths should all hit the same lifecycle check.
- Renaming/saving a Markdown document as a non-Markdown file should detach Markdown providers and clear Markdown caches.
- Attach/detach must be safe to call repeatedly and should log quietly when state changes.

### New `DocView` core primitives

The feature needs several generic `DocView` extensions. These should be implemented as normal no-op-by-default hooks so non-Markdown editing remains unchanged.

#### 1. Variable visual row metrics

Current `DocView` assumes a constant `lh = self:get_line_height()` in scrolling, drawing, hit testing, selections, and overlay positioning.

Markdown headings and widgets need per-row heights.

Add a generic visual row metric layer:

```lua
view:add_visual_metric_provider(id, provider, opts)
```

Provider methods:

```lua
provider:line_height(view, line, row_entry) -> height?
provider:baseline_offset(view, line, row_entry) -> offset?
provider:font_for_line(view, line, row_entry) -> font?
```

Core changes:

- Add a visual row layout cache with prefix y offsets.
- Update `get_scrollable_size()`, `get_visible_line_range()`, `iter_visible_visual_rows()`, `get_line_screen_position()`, and `resolve_screen_position()` to use row metrics when providers exist.
- Preserve the old constant-height fast path when there are no metric providers.
- Ensure folded rows and existing visual row providers default to normal line height.

This is the foundational change for heading-sized fonts.

#### 2. Render fragments / source-to-screen mapping

Current text rendering iterates `doc.highlighter` tokens and uses raw text widths.

Markdown Live Editor needs a render model that can say:

- source columns 1-3 (`## `) are hidden on inactive lines
- source columns 4-20 are drawn with heading font
- source columns 10-12 (`**`) are hidden while inner text is bold
- source columns 25-45 (`![[image.png]]`) are replaced with an image widget or attachment chip
- active lines fall back to raw source rendering

Add a generic line render provider:

```lua
view:add_line_render_provider(id, provider, opts)
```

Provider method:

```lua
provider:render_line(view, line, context) -> render_line?
```

Possible `render_line` shape:

```lua
{
  source_text = view.doc.lines[line],
  active = boolean,
  height = number?,
  fragments = {
    {
      source_col1 = 1,
      source_col2 = 4,
      text = "",
      hidden = true,
      width = 0,
    },
    {
      source_col1 = 4,
      source_col2 = 20,
      text = "Heading",
      font = heading_font,
      color = style.text,
    },
    {
      source_col1 = 21,
      source_col2 = 36,
      widget = { type = "image", image = canvas, width = 320, height = 180 },
    },
  }
}
```

Core changes:

- Route `draw_line_text()`, `get_col_x_offset()`, `get_x_offset_col()`, wrapped drawing, caret placement, selection rectangles, IME location, and hit testing through the render fragments when a provider supplies them.
- Preserve the existing highlighter path when no provider supplies a render line.
- Add fragment caches keyed by doc change id, line text, active-line state, style/font generation, image load generation, and wrap width.
- Support `raw_passthrough = true` for active lines to use the old rendering path.

Important mapping rules:

- Every source byte column must map to a stable x position.
- Hidden syntax maps to either the previous visible x or a small editable reveal gutter; clicking hidden syntax on an inactive line should place the caret near the related source span and reveal the raw line.
- Selection rectangles must cover the raw source span even if some syntax is hidden. Hidden spans can draw a minimal caret/selection affordance when selected.

#### 3. Inline widget fragments

Add a draw/hit-test contract for non-text fragments:

```lua
fragment.widget = {
  type = "image" | "checkbox" | "attachment" | "embed" | ...,
  width = number,
  height = number,
  draw = function(view, fragment, x, y, row_height) end,
  hit_test = function(view, fragment, x, y) end,
  on_click = function(view, fragment, button, x, y, clicks) end,
}
```

Initial widgets:

- rendered image canvas
- missing-image/error chip
- attachment/link chip for unsupported embedded file types
- checkbox widget for task list items later

#### 4. Provider-aware wrapping

`core.linewrapping` currently measures raw highlighter tokens. If Markdown render fragments hide or replace syntax, wrapping should use the rendered widths for inactive lines and raw widths for active lines.

Add a wrap measurement hook:

```lua
provider:measure_fragments_for_wrap(view, line, context) -> fragments?
```

Implementation steps:

1. First milestone: add a safety gate. If a Markdown line is wrapped and fragment-aware wrapping is not available, render that wrapped line with the raw `DocView` path instead of hidden/replaced fragments.
2. Second milestone: teach `linewrapping.compute_line_breaks_from_col(...)` to consume render fragments and maintain source column row starts.
3. Third milestone: include active-line/reveal state in wrap cache invalidation. Moving the caret into or out of a line can change rendered width and row count without changing document text, so the old and new active/revealed lines must invalidate or recompute their wrap rows on selection/focus changes.
4. Fourth milestone: support image/widget fragments as unbreakable units.

This must be in place before enabling hidden syntax for normal Markdown editing because line wrapping is enabled by default in the dev Anvil defaults. Raw wrapping plus rendered aliases/hidden syntax would otherwise make caret movement, selections, clicks, and IME coordinates wrong on wrapped lines.

Until active-line wrap invalidation exists, all wrapped Markdown lines whose rendered fragments can differ from raw source must stay on the raw fallback path.

Do not silently break normal code wrapping; keep the old path unless a render provider is active.

#### 5. Click freeze / reveal deferral

Add a small `DocView` interaction state that can defer render-state changes during mouse down/up. This avoids moving hidden/revealed syntax under the pointer mid-click.

Markdown can use it to:

- freeze active-line reveal until after pointer-up
- still place the caret correctly
- avoid accidental drag selections caused by text shifting under the cursor

## Markdown parser and render model

### Parser strategy

Start by extracting the current `MarkdownView` parser into `data/core/markdown/parser.lua`, then evolve it for editor use.

The live editor needs both block-level and inline source ranges:

```lua
block = {
  type = "heading",
  line1 = 10,
  col1 = 1,
  line2 = 10,
  col2 = 24,
  level = 2,
  content_col1 = 4,
  content_col2 = 24,
  inline = {...}
}

span = {
  type = "strong",
  line = 12,
  col1 = 5,
  col2 = 14,
  marker_ranges = {{5, 7}, {12, 14}},
  content_ranges = {{7, 12}}
}
```

The current preview parser often stores normalized text rather than exact source ranges. For live editing, source ranges are mandatory.

### Incremental parsing plan

Milestone 1 can parse the whole document after each edit for correctness.

Milestone 2 should add dirty-neighborhood parsing:

- line-level dirty range from `Doc:apply_edits(...)` transaction data
- expand to nearest block boundary before/after the changed range
- reparse only that region
- preserve stable block IDs/cache entries outside the region
- invalidate link/image/layout cache only for affected lines

Use `core.log_quiet(...)` for parse timing, dirty range size, cache hit/miss counts, and fallback-to-full-parse decisions.

## Obsidian link support

### Syntax to support

#### Wikilinks

```text
[[target]]
[[target|alias]]
[[target#heading]]
[[target#heading|alias]]
[[target#^block-id]]
[[#heading]]
[[^block-id]]
```

#### Embeds

```text
![[target]]
![[target#heading]]
![[target#^block-id]]
![[image.png]]
![[image.png|640x480]]
![[image.png|100]]
![[Document.pdf#page=3]]
![[Document.pdf#height=400]]
```

#### Markdown links/images

```text
[alias](target.md)
[alias](target.md#heading)
![alt](image.png)
![alt|100x145](image.png)
![alt](https://example.com/image.png)
```

### Link parse model

```lua
{
  kind = "wiki" | "markdown" | "image" | "embed",
  source_line = line,
  source_col1 = col1,
  source_col2 = col2,
  raw_target = "Note#Heading",
  path = "Note",
  subtarget = { type = "heading", text = "Heading" },
  alias = "display text",
  resize = { width = 640, height = 480 },
  is_embed = true,
}
```

### Vault/project resolution

Create `data/core/markdown/vault_index.lua`.

Responsibilities:

- choose vault root from `core.current_project(current_note_path)` by default, not from whichever project is currently active globally
- maintain indexes per project/vault root so multi-project workspaces do not cross-resolve unrelated notes
- index Markdown files by:
  - absolute path only as internal metadata, with opening still bounded by the owning vault/project unless explicit config later allows outside-vault links
  - project-relative path with and without `.md`
  - basename without extension
  - normalized display name
  - aliases from YAML frontmatter (`aliases`, `alias`) when implemented
- index attachments by project-relative path and basename with extension
- index headings per note using Obsidian-compatible anchors
- index block IDs matching `^id`
- maintain generation counters for cache invalidation
- bump or update generations from concrete events:
  - open-document text transactions for heading/block ID/frontmatter alias edits
  - `Doc:set_filename(...)` / save-as / project rename flows
  - file create/delete/rename events from project directory watching when available
  - explicit fallback full rebuild when event coverage is uncertain or a cache invariant fails

Resolution order proposal:

1. Explicit relative path from current note directory.
2. Absolute path only if it belongs to the owning project/vault; otherwise treat it as an external file/link unless a future config explicitly permits outside-vault internal links.
3. Exact project-relative path.
4. Exact basename/note name match.
5. Case-insensitive match if there is a single unambiguous candidate.
6. Alias match if there is a single unambiguous candidate.
7. Missing-link result with a styled unresolved link.

When ambiguous, render a warning style and log quietly with candidates.

### Opening links

Add commands / behavior:

- `markdown-live:open-link-at-caret`
- ctrl/cmd-click link opens target
- normal click in text still edits unless modifier/click area is link-specific
- status bar tooltip shows resolved target or missing-link reason

Opening behavior:

- note target: open as `DocView`, not separate preview
- heading target: open note and scroll to heading line
- block target: open note and scroll/select block ID line or block content
- image/attachment target: use `core.open_file` / `core.open_image` / sidepanel as appropriate
- external URL: `common.open_in_system(url)`

## Image rendering plan

### Reuse/extract current image code

Extract from `MarkdownView`:

- `get_image_cache_path(...)`
- local project link resolution
- remote image download to `USERDIR/cache`
- canvas loading/scaling
- SVG resizing path

Move into `data/core/markdown/images.lua` so both `MarkdownView` and Markdown Live Editor share it.

Remote image policy must be part of this extraction, not a later afterthought. The shared module should accept a policy option and the live editor should default remote downloads off. When disabled, `http(s)` images render as a disabled/remote-image chip with an explicit open/download action rather than calling `http.download(...)` during document rendering. Existing preview behavior can either keep its current eager download policy behind an explicit preview option or migrate to the same safer policy deliberately.

### Image placement policy

Support two rendered forms:

1. **Inline image fragment** for small images or images embedded inside paragraph/table text.
2. **Block image row** for image-only lines or large images.

Initial milestone can render all image embeds as a block row immediately below the source line if inline mapping is not ready. The long-term target is true inline/widget fragments.

### Obsidian resize rules

- `|100` means width 100, keep aspect ratio.
- `|640x480` means fit or force rendered width/height according to configured behavior.
- Clamp to available editor content width.
- Do not upscale above natural size unless a config option later asks for it.

### Failure states

- missing file: render unresolved attachment chip
- unsupported file: render attachment chip with open action
- remote pending: render loading chip and invalidate line when ready
- load error: render error chip with alt text/path

Use quiet logs for load attempts, cache paths, failures, and async completion.

## Styling/defaults

Add first-party defaults to `data/colors/default.lua` and behavior defaults to `data/plugins/anvil_defaults.lua` or a dedicated first-party defaults module.

Candidate style keys:

```lua
style.markdown_live_heading = { ... }
style.markdown_live_heading_marker = style.dim
style.markdown_live_link = style.syntax.function
style.markdown_live_unresolved_link = style.warn
style.markdown_live_inline_code_bg = style.background2
style.markdown_live_quote_bar = style.accent
style.markdown_live_image_background = style.background2
style.markdown_live_attachment_bg = style.background2
style.markdown_live_hidden_syntax = style.dim
```

Do not hardcode fallback defaults in first-party Markdown modules for style/config keys they require. Keep base theme schema complete.

## User-facing configuration

Candidate config keys:

```lua
config.markdown_live_editor = false -- development default until wrapping/mapping gates are complete; target default is true when promoted
config.markdown_live_reveal_mode = "active_line" -- future: active_block/source
config.markdown_live_render_images = true
config.markdown_live_download_remote_images = false -- safer default if desired
config.markdown_live_open_links_with_modifier = true
config.markdown_live_vault_root = "owning_project" -- future explicit path
config.markdown_live_attachment_search = { "same_folder", "project" }
```

Only promote settings that are clearly user-facing. Avoid over-parameterizing visual constants until there is a reason.

## Implementation phases

### Phase 1: Shared Markdown parser/link/image modules

- Extract parser pieces from `MarkdownView` into `data/core/markdown/parser.lua`.
- Add source ranges to parsed blocks/spans.
- Extract local/remote image loading into `data/core/markdown/images.lua` with an explicit remote-download policy parameter; live editing defaults to no automatic network access.
- Implement `data/core/markdown/links.lua` for Obsidian wikilinks/embed syntax.
- Implement `data/core/markdown/anchors.lua` for heading anchors and block IDs.
- Keep `MarkdownView` passing current tests by routing it through the new shared modules gradually.

Tests:

- parser recognizes headings, emphasis, Markdown images, and wikilinks with exact ranges
- link parser covers all Obsidian syntaxes listed above
- image size syntax parses correctly
- remote images disabled in live-editor policy does not invoke `http.download(...)`
- existing `tests/lua/ui/markdownview.lua` remains green

### Phase 2: Markdown link resolver and vault index

- Add `data/core/markdown/vault_index.lua`.
- Index project Markdown files, attachments, headings, and block IDs.
- Wire index invalidation/update triggers from document text transactions, filename changes, save-as/rename/delete flows, and project file watcher events where available.
- Resolve note links with extension omission.
- Resolve attachment links requiring extension.
- Resolve heading/block subtargets.
- Render missing/ambiguous result metadata.

Tests:

- `[[Note]]` resolves to `Note.md`
- `[[folder/Note]]` resolves project-relative/relative paths
- links resolve against the source note's owning project in a multi-project workspace
- absolute/outside-project internal links are rejected or externalized according to policy instead of treated as vault links
- `[[Note#Heading]]` resolves heading line
- `[[Note#^block-id]]` resolves block line
- ambiguous note names are reported as ambiguous instead of opening arbitrary files
- attachment links require/handle explicit extensions
- editing a heading or block ID updates the resolver without a manual full restart
- saving a new note, renaming a note, and deleting a note update or invalidate the index predictably

### Phase 3: Core `DocView` row metrics

- Add visual metric provider API.
- Add visual row y-offset cache and default fast path.
- Update scroll size, visible row iteration, line screen position, mouse position resolution, gutter/body drawing, overlay/caret, and selection geometry for provider metrics.
- Add tests around variable-height rows independent of Markdown.

Tests:

- a metric provider can make one line taller without corrupting click hit testing
- caret y position and selection rectangles align on variable-height rows
- scrolling to a variable-height line lands correctly
- normal `DocView` behavior is unchanged without providers

### Phase 4: Core `DocView` render fragments

- Add line render provider API.
- Implement text fragment drawing with fonts/colors/backgrounds.
- Implement source column to x mapping and inverse x to source column mapping.
- Wire fragment mapping into selections, carets, IME, `get_col_x_offset`, `get_x_offset_col`, and mouse hit testing.
- Preserve existing raw highlighter path when no provider supplies fragments.

Tests:

- hidden source markers map to stable caret positions
- visible content maps back to correct source columns
- selections over hidden and visible fragments draw predictably
- active line can switch to raw passthrough without changing row height
- normal non-Markdown long-line rendering still uses existing fast path

### Phase 4.5: Provider-aware wrapping safety gate

- Add the raw-render fallback for wrapped Markdown lines before any default hidden-syntax rendering is enabled.
- Add fragment-aware wrap measurement for text fragments as soon as possible after the fallback.
- Add selection/focus-driven wrap invalidation for old/new active lines before active-line raw reveal can affect wrapped row counts.
- Keep image/widget fragments raw or row-based until unbreakable widget wrapping is implemented.
- Add tests that demonstrate a long `[[Very Long Note Name|short alias]]` line is not mis-hit-tested when wrapping is enabled.

Tests:

- wrapped lines with hidden syntax either render raw or use fragment-aware mapping; they never mix raw wrap breaks with shortened rendered text
- click, caret, selection, and IME x positions remain source-correct on wrapped Markdown lines
- moving the caret into a long inactive alias line that becomes wider in raw mode invalidates/recomputes wrap rows and preserves hit testing
- non-Markdown wrapped files still use the old wrapping path

### Phase 5: First live Markdown rendering milestone

Attach Markdown Live Editor to Markdown `DocView` instances, subject to the development feature flag and wrapping safety gate.

Initial features:

- heading font sizes for H1-H6
- inactive-line hiding of heading markers
- bold/italic/strikethrough/code styling
- link styling for Markdown links and wikilinks
- unresolved link styling
- active-line raw reveal
- status bar tooltip for links under mouse
- command/click to open resolved links

Tests:

- Markdown file opens as `DocView`
- untitled/plain `DocView` saved as `*.md` attaches live Markdown providers
- direct `doc:set_filename(...)`, save-as, rename, and syntax reset paths all re-run attach/detach eligibility
- Markdown `DocView` saved/renamed to a non-Markdown filename detaches live Markdown providers
- heading line uses heading metric/font while remaining editable raw text
- moving caret into a rendered heading reveals raw marker
- `[[Note|Alias]]` displays alias inactive and raw syntax active
- link open command opens target note as `DocView`

### Phase 6: Image embeds in the editor

- Render `![[image.png]]` and `![alt](image.png)` in the editor.
- Support Obsidian resize syntax.
- Cache/scaling via shared image module.
- Use provider rows first if inline widgets are not ready; migrate to inline widget fragments for images embedded inside paragraph text.
- Add missing/error/loading states.

Tests:

- project-local image link loads expected path
- image row/widget has expected dimensions after resize syntax
- missing image renders error chip and remains editable
- remote image download updates the rendered line when finished if remote images are enabled
- active source line remains raw/editable

### Phase 7: Embeds beyond images

- `![[Note]]`: render an embedded-note block/card with a bounded preview of the target note.
- `![[Note#Heading]]`: render only the target heading section when feasible.
- `![[Note#^block-id]]`: render target block when feasible.
- PDFs/audio/video/unknown files: render attachment chips with open action unless native viewers are added.
- Avoid recursive embed explosions with max depth and cycle detection.

Tests:

- note embed resolves and renders bounded target preview
- recursive embeds stop with a cycle chip/log
- PDF/audio/video attachment chips open the file rather than failing silently

### Phase 8: Polish beyond the wrapping safety gate

- Complete fragment-aware wrapping for remaining widget/image/table cases.
- Keep active-line reveal layout stable.
- Add task checkbox widget rendering/toggling.
- Add blockquotes/rules/list marker polish.
- Add table rendering strategy, potentially borrowing from `MarkdownView` table layout.
- Add keyboard/navigation affordances for link creation and note creation if desired.

Tests:

- rendered heading/link/image lines wrap predictably
- switching active line does not cause scroll jumps
- table/image/list cases preserve source text after edits
- broad `meson test -C build-windows-x86_64 --suite anvil --print-errorlogs` passes

## Compatibility / migration plan

- Keep `markdown-view:preview` initially.
- During core primitive work, keep Markdown Live Editor behind `config.markdown_live_editor = false` so raw Markdown editing remains the safe default.
- Promote Markdown Live Editor to the default Markdown file editing experience only after row metrics, render fragments, and wrapped-line safety are implemented and tested.
- `core.open_file("note.md")` should continue returning a `DocView`; when the feature is enabled and the view passes the attach lifecycle check, it should have Markdown live providers attached.
- `core.open_markdown(...)` can remain for explicit preview use until the old preview is no longer needed.
- Once live editing is mature, consider renaming commands from `markdown-view:*` to `markdown-live:*` or adding new live-editor commands and retiring preview-centric defaults.
- Update all in-repo callers/tests rather than preserving deprecated internal aliases unless an external boundary needs them.

## Risk areas

- **Source-to-screen mapping:** hiding syntax while keeping byte-accurate editing is the core hard problem.
- **Variable-height rows:** current `DocView` code has many constant-line-height assumptions.
- **Wrapping:** rendered fragments and widgets can invalidate current raw-token wrap caches. Because wrapping is enabled by default in Anvil's current dev defaults, hidden syntax must be gated behind raw fallback or fragment-aware wrapping. Active-line reveal can also change wrap row count without a text edit, so selection/focus changes must participate in wrap invalidation.
- **Mouse interaction:** revealing syntax during click can move text under the pointer unless frozen/deferred.
- **Async images:** image load completion changes layout; must invalidate predictably without jank.
- **Remote image privacy:** live editing must not fetch tracking URLs just because a Markdown file was opened; automatic remote downloads stay disabled unless explicitly enabled.
- **Ambiguous/stale Obsidian links:** basename links can map to multiple project files; must not open random targets, and the vault index must update after heading/block/file changes.
- **Performance:** full-document parsing on every keystroke is acceptable only as an early milestone.

## Diagnostics and logging

Add quiet logs for:

- live editor attach/detach and filename/syntax lifecycle decisions
- parser full/incremental timing
- dirty range and fallback-to-full-parse reasons
- vault index rebuilds, incremental updates, invalidation reasons, and file counts
- ambiguous/missing link resolution
- image load/download decisions, remote-download policy skips, start/done/error
- render fragment provider failures
- slow line render/layout cases

Use visible `core.warn`/`core.error` only when the user needs to act.

## Test strategy

Follow red-green regression workflow for each behavior-changing bugfix.

Preferred test locations:

```text
tests/lua/runtime/markdown_parser.lua
tests/lua/runtime/markdown_links.lua
tests/lua/ui/docview_render_fragments.lua
tests/lua/ui/docview_variable_rows.lua
tests/lua/ui/markdown_live_editor.lua
```

Run targeted tests through Meson, for example:

```sh
PATH=/c/msys64/mingw64/bin:$PATH /c/msys64/mingw64/bin/meson.exe test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/markdown_links.lua --print-errorlogs
PATH=/c/msys64/mingw64/bin:$PATH /c/msys64/mingw64/bin/meson.exe test -C build-windows-x86_64 anvil:lua-ui --test-args ui/markdown_live_editor.lua --print-errorlogs
```

Run the Anvil suite before finalizing broad changes:

```sh
PATH=/c/msys64/mingw64/bin:$PATH /c/msys64/mingw64/bin/meson.exe test -C build-windows-x86_64 --suite anvil --print-errorlogs
```

## Open questions

- After the feature is promoted from development-flagged to default-on, should Source mode remain a per-file/session command toggle or only a global config option?
- Should remote image downloads be enabled by default, prompted, or disabled until explicitly opted in?
- What should the user-facing canonical name be: **Markdown Live Editor**, **Live Markdown Editor**, or another term?
- How closely should Anvil emulate Obsidian's exact heading-anchor normalization and alias/frontmatter rules?
- Should ambiguous wikilinks offer a picker, create a missing note, or remain unresolved until explicit?
- Should image embeds render on the same source line, below it, or choose based on image-only vs paragraph context?
