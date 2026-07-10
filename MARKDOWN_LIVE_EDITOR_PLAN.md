# Markdown Live Preview Rebuild Plan

## Status

This document replaces the original greenfield plan with a plan based on:

- the Markdown Live Preview code that is already in the repository
- the implementation and follow-up commit history from July 4–5, 2026
- current Anvil `DocView`, wrapping, selection, rendering, Project, and directory-watching architecture
- current official Obsidian Help documentation
- observed Obsidian Live Preview behavior where the official documentation is intentionally high-level
- open-source implementations of the same editing model

The canonical user-facing name is **Markdown Live Preview**, as recorded in `CONTEXT.md`.

This is a rebuild and completion plan, not a promise to preserve every current Markdown Live Preview internal API. Keep sound generic core primitives, replace brittle or incomplete feature code, and update all in-repo callers and tests in the same change when concepts are renamed.

## Purpose

Make a Markdown file opened in an ordinary Anvil Editor feel like Obsidian's **Live Preview** mode:

- the Document remains plain editable Markdown
- formatted content is presented inline in the Editor
- Markdown syntax is hidden when it is not being edited and revealed when the caret enters the relevant construct
- headings, emphasis, code, links, lists, images, callouts, tables, and other supported constructs look intentional rather than like lightly recolored source
- Obsidian-style internal links and embeds work naturally inside an Anvil Project
- all ordinary editing behavior—undo, redo, selections, multi-cursor, copy, find, replace, IME, wrapping, folding, save, external edits, and navigation history—continues to work
- malformed, incomplete, or unsupported Markdown always falls back safely to editable source

The target is not a separate preview surface and not a rich-text document model. The target is a robust text Editor whose visual projection can differ from its source without ever losing control of the source.

## Terminology

- **Markdown Live Preview**: the formatted-in-place editing mode described by this plan.
- **Source Mode**: an Editor mode in which all Markdown source syntax is shown normally.
- **Reveal Unit**: the smallest parsed construct whose hidden syntax becomes visible for editing, such as one emphasis span, one link, or one block marker region.
- **Markdown Render Model**: the immutable, source-ranged description of what an Editor should draw for a Document revision.
- **Markdown Link Index**: Anvil's Project-scoped index of notes, aliases, headings, block IDs, and attachments. This avoids treating the entire Anvil Workspace as one Obsidian vault.
- **Obsidian vault**: an external Obsidian concept. An Anvil Project is the default link-resolution boundary; a Project may explicitly opt into using the nearest ancestor containing `.obsidian`, and External Project Directories participate only when explicitly included.

The canonical feature name is recorded in `CONTEXT.md`, and the Project/vault boundary is resolved in the owner decisions below.

## Executive diagnosis of the current implementation

The existing implementation is a useful prototype with substantial generic `DocView` work, but it is not an end-to-end Live Preview feature.

### What exists and is worth preserving

- Generic `DocView` visual metric providers.
- Generic line render providers and source-column/x-coordinate mapping.
- Text fragments with custom fonts, colors, hidden ranges, backgrounds, and widgets.
- A raw-render fallback for actually wrapped Markdown lines.
- Interaction freezing during drag selection.
- Heading sizing and inactive heading-marker hiding.
- Bold, italic, combined emphasis, and strikethrough rendering.
- Wikilink/Markdown-link parsing sufficient for the current prototype.
- Local image rendering, Obsidian attachment-folder lookup, resize syntax, and a full-window image overlay.
- Remote image downloads disabled by default in the live editor.
- A standalone Project-scoped note/attachment index with tests for aliases, headings, block IDs, ambiguity, and multiple Projects.
- Focused runtime and in-process UI tests around the above behavior.

### What is incomplete or incorrect

1. **The link index is not part of the product path.**
   `data/core/markdown/vault_index.lua` is exported, but the live renderer does not use it. Internal links do not resolve, distinguish missing/ambiguous targets, navigate, or show useful hover state.

2. **The index does not initialize or stay current automatically.**
   It does not perform an initial rebuild on demand, has no active Project directory watcher, and tracks open Documents only when explicitly asked.

3. **Attach/detach lifecycle is incomplete.**
   Live Preview is refreshed when an Editor is marked or activated. Direct filename changes, save-as, rename, syntax changes, and reload paths do not have one first-class lifecycle notification. The existing rename test manually calls `refresh_view()` and therefore does not prove automatic behavior.

4. **Rendering and metrics are too expensive.**
   Selection state participates in the visual metric generation. A caret move can rebuild metrics across the entire Document. Rendering reparses inline Markdown from draw and coordinate-mapping paths, and the nominal line-render cache is not actually used.

5. **Wrapping is only protected, not integrated.**
   Long wrapped Markdown lines fall back to raw source. That avoids corrupt coordinates, but it is not finished Live Preview behavior.

6. **The parser is a prototype parser.**
   It is line-oriented, incomplete relative to CommonMark/GFM/Obsidian Flavored Markdown, inconsistent with `MarkdownView` in places, and unsuitable as the semantic foundation for tables, nested blocks, references, comments, Unicode edge cases, or robust incremental invalidation.

7. **The old `MarkdownView` parser remains mostly separate.**
   `MarkdownView` still owns a much broader parser and renderer. The new shared parser did not become a common semantic layer.

8. **Image cache identity and invalidation are incomplete.**
   Missing, failed, and remote-disabled entries can stay cached forever. Relative image identity does not include the source note/Project context. Moving a note or changing remote-image policy can leave stale results.

9. **Configuration is contradictory.**
   The defaults comment calls the feature development-flagged, while `config.markdown_live_editor` is `true`. `config.markdown_live_reveal_mode` exists but is unused.

10. **Integration relies on global monkey patches.**
    Markdown wraps `file_context.mark_editor_view`, `core.set_active_view`, `DocView` mouse methods, `RootPanel` draw/input methods, and key handling. The render providers are a sound extension model; the lifecycle and interaction wrapping is order-sensitive and lacks ownership/uninstall semantics.

11. **Most of the intended experience is absent.**
    There is no complete inline-code treatment, task widget, list presentation, blockquote/callout rendering, rules, tables, properties UI, math, note embeds, attachment chips, link autocomplete, missing-note creation, or rename-link maintenance.

### What the Git history says

- The plan was committed on July 4, 2026 at 22:07.
- Six implementation milestone commits landed between 22:24 and 23:21.
- Twenty-two follow-up commits landed by July 5, mostly stabilizing heading editing, emphasis, hit testing, drag selection, images, and the image overlay.
- The feature added roughly 5,100 lines across 27 files.
- No dedicated Markdown Live Preview implementation commit landed after July 5.
- The original plan was never updated to record actual completion or remaining acceptance failures.

The history shows a broad, very fast scaffolding pass followed by reactive stabilization. The rebuild must use narrow vertical slices with explicit acceptance gates instead of declaring whole phases complete after modules exist.

## Target user experience

### Opening a Markdown file

- A file recognized as Markdown opens in the normal Main Editor.
- Live Preview is the default editing mode once the release gates in this plan pass.
- There is no duplicate Document and no hidden rendered copy.
- A Source Mode command can reveal ordinary Markdown source without replacing the Editor or losing selection/scroll state.
- Non-Markdown Editors do not pay Markdown parsing, metric, or rendering costs.

### Reading while editing

- Headings have durable H1–H6 hierarchy.
- Body text remains comfortable and consistent.
- Emphasis, highlight, strikethrough, inline code, links, tags, lists, quotes, and code blocks look rendered even though the source remains editable.
- Hidden source syntax reappears only around the construct being edited, with containing-line or block raw fallback where precise reveal is unsafe.
- Moving the caret must not cause vertical scroll jumps. Horizontal movement caused by revealing source must not corrupt pointer placement or selection.
- Invalid or half-typed constructs remain readable source until they parse confidently.

### Internal links

- `[[Note]]`, aliases, heading links, block links, and standard Markdown note links resolve within the owning link boundary.
- Existing links are visually distinct from missing and ambiguous links.
- The status bar explains the resolved destination or failure reason.
- The open-link command and the selected mouse gesture open notes as Editors, jump to headings/blocks, open attachments, or launch external URLs.
- Editing text normally is never blocked by link hit regions.

### Images and attachments

- Local images render without leaving the Editor.
- Image dimensions follow Obsidian syntax and clamp to available content width.
- Missing, disabled-remote, loading, and failed images have explicit, useful states.
- Clicking an image can open the existing image overlay without making source editing impossible.
- Paste and drag/drop can eventually copy an attachment to the configured location and insert the selected link format.

### Large and difficult Documents

- Caret movement does not scan every line.
- Draw and hit-test paths consume cached render models and never parse Markdown.
- A one-megabyte note remains editable while parsing/indexing catches up.
- Broken Markdown, deep nesting, pathological delimiter input, very long lines, Unicode, CRLF, tabs, multi-cursor editing, IME, and external reloads degrade to source rather than crashing or misplacing edits.

## Product invariants

1. **Raw Markdown is authoritative.**
   Decorations and widgets never become a second document model. Save, copy, undo, redo, search, replace, diff, LSP-like consumers, and external tools see source text.

2. **Source ranges are exact byte ranges.**
   Every rendered construct maps to the same UTF-8 byte-column convention used by `Doc`. No normalized display text may stand in for editing coordinates.

3. **No parse work in drawing or hit testing.**
   Drawing, selection geometry, caret positioning, IME positioning, and x/column mapping consume a cached render model for a known Document revision.

4. **No whole-Document work on ordinary caret movement.**
   Selection changes invalidate old and new Reveal Units/lines only. They do not regenerate metrics for every visual row.

5. **Conservative fallback is always valid.**
   Parser errors, stale async results, unsupported constructs, unsafe wrapping, missing assets, and provider failures produce raw source or an explicit chip—not incorrect hidden syntax.

6. **Vertical geometry is anchored.**
   Entering/leaving a construct preserves its semantic row style. If wrapping or a widget changes row count, keep the caret/viewport anchor stable and defer pointer-sensitive changes until interaction ends.

7. **No implicit network access.**
   Opening a note never downloads remote images or embeds unless the user has explicitly selected that policy.

8. **Project isolation is deterministic.**
   A note resolves against its own Project/link root, not whichever Project or view happens to be active.

9. **Normal Editors retain their fast path.**
   Generic `DocView` hooks remain no-op and allocation-light without providers.

10. **Feature state is view-local; semantic state is Document-local.**
    Two Editors for one Document may use different editing modes without duplicating parse/index state.

11. **All async publication is revision-checked.**
    Parse, image, and index results calculated for an old Document revision or old filename/root are discarded.

12. **First-party defaults are centralized.**
    Behavior defaults live in `data/plugins/anvil_defaults.lua`; required style schema lives in `data/colors/default.lua`.

## Obsidian research findings

### Authoritative Live Preview behavior

Official Obsidian Help defines three related states:

- Reading view: rendered, non-editing presentation.
- Editing view / Live Preview: formatted text inline, with most Markdown syntax hidden; source syntax becomes visible when the cursor enters formatted content.
- Editing view / Source mode: all Markdown syntax is visible exactly as written.

Obsidian defaults Editing view to Live Preview and offers a command to toggle Live Preview/Source mode. The official language is **formatted content**, not necessarily an entire active line.

Community observation of current Obsidian behavior shows construct-sensitive reveal in important cases—for example, inline-code delimiters appear when the caret enters that inline-code span and remain hidden when the caret is elsewhere on the same line. This observation is useful inspiration, but official Help remains the compatibility authority.

Implementation implication: model reveal at construct granularity, with line/block fallback for constructs that cannot safely reveal independently. Do not hard-code the current prototype's whole-active-line policy into core APIs.

### Obsidian Flavored Markdown baseline

Obsidian states that it supports CommonMark, GitHub Flavored Markdown, and LaTeX, plus extensions including:

- wikilinks and embeds
- heading and block references
- footnotes
- `%%` comments
- `==highlight==`
- strikethrough
- task lists
- callouts
- tables

Obsidian intentionally does not render Markdown nested inside raw HTML elements. Anvil adopts the same conservative rule: raw HTML remains source-only, and Markdown nested inside it is not rendered.

### Formatting behavior relevant to Live Preview

The official syntax set includes:

- paragraphs and soft/hard line breaks
- ATX H1–H6 headings
- bold, italic, bold+italic, highlight, and strikethrough
- escaped Markdown syntax
- internal and external links
- local and external images
- blockquotes
- ordered, unordered, nested, and task lists
- horizontal rules
- inline code and fenced/indented code blocks
- reference and inline footnotes
- inline and block comments
- GFM tables
- inline and display MathJax/LaTeX
- Mermaid code blocks

Known Obsidian caveats worth matching rather than accidentally exceeding:

- inline footnotes render only in Reading view, not Live Preview
- PrismJS is not used in Editing views; editing-mode code highlighting may differ
- Markdown inside HTML is not rendered
- comments remain an Editing-view concept

### Internal-link details

Supported persisted link forms include:

```text
[[Note]]
[[Note.md]]
[[Note|Display text]]
[[Note#Heading]]
[[Note#Heading|Display text]]
[[Note#Parent heading#Subheading]]
[[Note#^block-id]]
[[#Heading in this note]]
[Display text](Note%20name.md)
[Display text](Note%20name.md#Heading)
```

Important details:

- Non-Markdown attachments require an extension.
- Markdown destinations require percent-encoding unless wrapped in angle brackets where applicable.
- Heading search input `[[## query]]` and block search input `[[^^query]]` are suggestion workflows, not ordinary persisted target semantics. The editor should recognize them as an in-progress autocomplete state.
- Block IDs may contain Latin letters, numbers, and dashes.
- A simple paragraph block ID can be at line end after a space.
- Structured blocks such as lists, quotes, callouts, and tables use a separate block-ID line with blank-line boundaries.
- Obsidian does not support links to arbitrary subparts of quotes, callouts, and tables.
- Aliases come from the `aliases` YAML list. Obsidian treats them as reusable names in link workflows, and selecting one generates `[[Canonical note|Alias]]` rather than serializing the alias as the destination. For predictable imported-vault behavior, Anvil will also resolve a manually persisted `[[Alias]]` when the alias uniquely identifies one note; serialization/autocomplete should still prefer the canonical target plus alias.
- Alias resolution must report ambiguity when an alias collides with another alias, note basename, or explicit path candidate; it must not silently outrank an exact path/name match.
- Obsidian can automatically update internal links after file rename, or prompt when automatic update is disabled.

Obsidian's generated-link path policies are:

- shortest unique path
- path relative to the current file
- absolute path from the vault root

These are serialization policies for newly inserted/updated links. Resolution must still understand all supported forms.

### Embeds and accepted files

Obsidian embeds any supported file by prefixing an internal link with `!`.

Documented forms include:

```text
![[Note]]
![[Note#Heading]]
![[Note#^block-id]]
![[image.png]]
![[image.png|100]]
![[image.png|640x480]]
![250](https://example/image.png)
![alt|100x145](https://example/image.png)
![[audio.ogg]]
![[Document.pdf]]
![[Document.pdf#page=3]]
![[Document.pdf#height=400]]
![[My canvas.canvas]]
```

Accepted Obsidian formats currently include:

- Markdown: `.md`
- Bases: `.base`
- Canvas: `.canvas`
- images: `.avif`, `.bmp`, `.gif`, `.jpeg`, `.jpg`, `.png`, `.svg`, `.webp`
- audio: `.flac`, `.m4a`, `.mp3`, `.ogg`, `.wav`, `.webm`, `.3gp`
- video: `.mkv`, `.mov`, `.mp4`, `.ogv`, `.webm`
- PDF: `.pdf`

Official Obsidian Help currently shows two external Markdown-image sizing forms on different pages: numeric label as width (`![250](url)`) and alt text with a pipe suffix (`![alt|100x145](url)`). Anvil should fixture and support both forms deliberately. Numeric-label sizing has no separate descriptive alt text; the pipe form preserves the text before `|` as alt text. Width-only keeps aspect ratio; width×height defines a bounding box and preserves aspect ratio.

Anvil does not need native playback/viewers for every type to support the syntax correctly. Unsupported inline media can initially render an attachment chip with an open action.

### Attachments and drag/drop

Obsidian attachment location policies are:

- Project/vault root
- one configured folder
- same folder as the current note
- a named subfolder under the current note's folder

Pasting an attachment creates a file in that location and inserts an embed. Dragging an external file copies it into the attachment location and inserts a link/embed; a modifier can choose an absolute `file:///` link instead. Dragging an existing vault file into an editor inserts a link according to path and Wikilink/Markdown-link preferences.

The current Anvil implementation only reads one `.obsidian/app.json` attachment-folder form. A robust implementation needs fixtures for every supported policy and must not infer policy from nonexistent or malformed settings.

### Properties, callouts, tables, and math

Obsidian Live Preview presents YAML properties as editable rows. Supported property types include text, list, number, checkbox, date, date-time, and tags. `aliases`, `tags`, and `cssclasses` are special list properties. Nested properties and Markdown rendering inside properties are intentionally unsupported.

Callouts use a blockquote beginning with `> [!type]`, support custom titles, fold defaults with `+`/`-`, nesting, Markdown, links, and embeds. Unknown types fall back to the `note` appearance.

Tables support inline formatting, links, escaped pipes, alignment, and Live Preview context actions for rows/columns/sorting/moving.

Math uses `$...$` and `$$...$$` with MathJax/LaTeX semantics.

These are materially larger UI projects than basic inline syntax and must be staged rather than hidden inside a generic “polish” milestone.

## Open-source implementation lessons

### Atomic Editor / CodeMirror 6

Atomic Editor is inspiration, not an Obsidian compatibility authority. Its architecture validates several decisions relevant to Anvil:

- raw Markdown remains the only document
- syntax decorations are view-only
- heading/block line style is independent of reveal state
- pointer-down freezes decoration changes until after pointer-up
- image decorations invalidate only when changes overlap images or add image syntax
- large Documents depend on narrow invalidation and viewport rendering
- interactive tables need stable widget identity across edits
- wide tables need contained horizontal scrolling rather than forcing the Editor width
- wiki-link resolution is debounced/cached and draft links stay editable
- the regression suite explicitly probes cumulative layout shift, click freeze, late-document rendering, source-copy fidelity, and each widget type

The current Anvil prototype adopted some of these ideas, but not the narrow invalidation or cached render-model architecture.

### Parser candidates

The rebuild must not continue extending the current ad hoc parser without first selecting a tested semantic foundation.

**MD4C** is the leading native candidate for a spike:

- MIT licensed, current, compact C implementation
- CommonMark 0.31 compliant
- designed for near-linear performance on pathological input
- supports tables, tasks, footnotes, strikethrough, highlight, math, wikilinks, and admonitions via flags
- push callbacks avoid requiring a full DOM
- not incremental, but full native parsing may be fast enough if source-range extraction and Lua publication are bounded

Risk: editor-quality exact delimiter/source ranges are not its primary public API. Anvil may need a small maintained patch or adapter that exposes exact byte offsets for block/span enter/leave events.

**tree-sitter-markdown** is an alternate candidate:

- MIT licensed and actively maintained
- block and inline grammars produce source-ranged syntax trees
- supports GFM, YAML metadata, optional tags, and optional wikilinks
- incremental parsing aligns with Anvil's Tree-sitter infrastructure

Risks: upstream explicitly says it has known inaccuracies and is not recommended where correctness is critical; it requires coordinated block and inline parses with included ranges; Anvil's current Tree-sitter service is not built around this split-parser model.

**cmark-gfm** is accurate and robust but builds a full AST, lacks Obsidian extensions, and does not solve exact inline editing ranges or incremental publication by itself.

**Current `MarkdownView` parser** remains a migration reference and fallback source of rendering behavior, not the target semantic authority. It covers more constructs than `data/core/markdown/parser.lua` but normalizes source and was designed for a separate preview.

The parser spike must decide by evidence, not preference.

### Parser execution and publication path

The spike must prove a real Anvil integration, not compare upstream libraries in isolation. Neither candidate is currently a drop-in Lua module:

- MD4C would need a pinned Meson subproject/package, an Anvil-owned native API, exact source-range extraction, and native tests.
- `tree-sitter-markdown` would need pinned block and inline grammars, registry/build integration, included-range coordination, and changes to the current one-grammar Document service.

Before backend selection, each viable candidate must compile in the normal Windows build and publish one tiny source-ranged fixture through the proposed Anvil API.

The selected execution path must define:

- ownership and lifetime of source snapshots and native parse results
- compact result representation so a full native tree is not copied into large Lua tables after every edit
- request coalescing by Document, cancellation or supersession, and backpressure
- worker/native-job protocol when parsing or publication can exceed the synchronous frame budget
- revision, filename, syntax, and link-root checks before publication
- stale-result disposal without touching closed Documents/Editors
- behavior while a fresh parse is pending: retain unaffected old ranges, show changed/uncertain ranges raw, and never hide syntax from a stale snapshot
- shutdown and test isolation

`core.add_thread()` is cooperative and cannot preempt a long native parser call. A synchronous native path is acceptable only if end-to-end parse **and publication** stay within the measured hard budget for the selected maximum synchronous input. Larger/slow inputs must use a worker/native job or immediately remain raw while background reconciliation completes.

## Supported-feature tiers

### Tier 0: release-blocking Editor correctness

- source/caret/x mapping
- wrapping
- selection and drag selection
- multi-cursor
- IME
- undo/redo
- find/replace
- folding/composed rows
- reload and filename/syntax lifecycle
- viewport anchoring
- large-document performance
- no-network default
- raw fallback

No formatting feature may ship default-on if Tier 0 is unreliable.

### Tier 1: core Live Preview experience

- H1–H6
- bold, italic, bold+italic
- strikethrough and highlight
- inline code
- escapes
- external links
- Markdown links
- wikilinks, aliases, heading links, and block links
- local images and explicit image states
- paragraphs and line-break presentation
- ordered/unordered/nested lists
- task checkboxes
- blockquotes
- fenced/indented code blocks
- horizontal rules
- `%%` comments
- YAML frontmatter shown safely, at least as styled source

### Tier 2: rich block editing

- callouts
- GFM tables
- reference links and footnotes
- tags
- note/heading/block embeds
- attachment chips
- paste/drop attachment import
- properties presentation
- styled-source math presentation; rendered math is deferred until a safe native renderer is selected

### Tier 3: optional media and advanced integrations

- PDF preview
- audio/video players
- Mermaid rendering
- Canvas/Base previews
- hover page previews
- advanced cross-Project knowledge tools beyond the core link autocomplete/open flow

The resolved owner decisions at the end require note/heading/block embeds and generic attachment chips in Tier 2 before the selected core scope is complete. Rich property rows, rendered math, and native media viewers remain deferred.

## Target architecture

### Layer 1: parser service

Produce source-ranged Markdown events/nodes for a specific Document revision. The parser must not know about fonts, colors, Editors, Projects, or link destinations.

Required node contract:

```lua
{
  id = stable_id,
  type = "heading" | "strong" | "wiki_link" | ...,
  source = { line1, col1, line2, col2 },
  marker_ranges = { ... },
  content_ranges = { ... },
  attributes = { ... },
  parent_id = optional,
  children = optional_compact_ids,
  confidence = "complete" | "incomplete" | "error",
}
```

Rules:

- ranges use `Doc` UTF-8 byte columns
- delimiters and content have separate ranges
- incomplete constructs remain represented only when doing so helps editing; they never hide source
- raw HTML suppresses nested Markdown parsing, matching Obsidian
- parser output is immutable for its revision
- publication rejects stale revisions

### Layer 2: Document semantic model

One model per Markdown Document, shared by every Editor showing that Document.

Responsibilities:

- own parser snapshot/revision
- map source lines to containing blocks/spans
- track dirty line/block neighborhoods from `Doc` text-change transactions
- provide heading, block ID, alias, outgoing-link, image, and attachment facts to the link index
- expose query methods for visible/revealed lines without constructing a full Lua object graph every frame
- publish parse generation and changed source ranges

Do not put caret state in this layer.

### Layer 3: view-local reveal and render model

One state object per Markdown Editor.

Responsibilities:

- Live Preview versus Source Mode
- caret/selection-driven Reveal Units
- pointer freeze state
- line render cache
- visual metric cache entries for affected rows
- widget instances and hover state
- wrap measurement fragments
- generation dependencies: Document parse generation, style/font generation, content width, link-index generation, image generation, reveal generation

A cached line render result must be reusable by drawing, hit testing, selection geometry, caret/IME geometry, and wrapping.

### Layer 4: generic `DocView` contracts

Keep and harden the existing generic providers rather than adding Markdown branches throughout `DocView`.

Required improvements:

1. **Line render cache ownership**
   - cache provider results by line and provider generation
   - allow targeted line/range invalidation
   - never call a provider parser repeatedly from one frame's draw/mapping paths

2. **Targeted visual metric invalidation**
   - invalidate old/new affected visual rows, not the whole prefix table on every selection move
   - update prefix offsets from the earliest changed row
   - keep the no-provider constant-height path unchanged

3. **Provider-aware wrapping**
   - wrapping consumes the same visible fragments used to draw
   - wrap rows retain source-column boundaries
   - widgets are unbreakable units or explicit block rows
   - reveal changes invalidate only affected line wrap entries
   - old/new caret lines preserve viewport anchor when row count changes

4. **Widget interaction contract**
   - standard draw, hit test, hover cursor, click, context action, and accessibility text hooks
   - no feature-specific wrapping of `DocView:on_mouse_*`

5. **Interaction transaction/freeze**
   - generic begin/end pointer interaction state
   - freeze render-state changes through click/drag completion
   - exclude scrollbar interactions

6. **Source mapping contract**
   - every source column maps deterministically to x
   - hidden ranges map to a documented affinity
   - replacement widgets map left/right halves to source boundaries
   - grapheme/UTF-8 and tabs are covered

7. **Provider failure isolation**
   - quiet log once per failure signature
   - raw fallback for that line/frame

### Layer 5: Markdown Link Index

Replace the disconnected vault-index prototype with a product-owned service.

Responsibilities:

- index notes, aliases, headings, block IDs, and supported attachments per link root
- start an initial cooperative/background scan on first use
- expose readiness (`cold`, `scanning`, `ready`, `stale`, `error`)
- resolve immediately from available data without choosing arbitrary ambiguous targets
- overlay unsaved open-Document facts over disk facts
- consume filename changes and Document close events
- watch directories for create/delete/rename/change and reconcile dirty directories
- enforce a watcher budget: recursively register only while within capacity, coalesce to root/subtree watches where the backend supports it, and stop adding watches after a deterministic limit or registration failure
- fall back to bounded periodic/coalesced directory reconciliation when watcher events are imprecise **or native watch capacity is unavailable/exhausted**
- expose degraded watcher mode in quiet diagnostics and readiness state without treating the index as permanently correct
- exclude `.git`, Anvil test/runtime state, ignored paths as appropriate, and optionally Obsidian excluded files later
- retain deterministic behavior across multiple Projects

Resolution result:

```lua
{
  status = "resolved" | "missing" | "ambiguous" | "external" | "pending" | "invalid",
  kind = "note" | "heading" | "block" | "attachment" | "url",
  path = optional_absolute_path,
  line = optional_line,
  candidates = optional_candidates,
  reason = optional_reason,
  index_generation = generation,
}
```

The renderer styles this result. The interaction layer decides what opening/creation action is allowed.

### Layer 6: assets and embeds

`images.lua` should become a context-aware asset service rather than a permanent table keyed only by target text.

Cache identity includes:

- source note path or resolved absolute target
- owning link root
- normalized URL/path
- remote policy
- requested decode characteristics where relevant

States:

- unresolved
- remote-disabled
- queued
- loading
- ready
- missing
- decode-error
- stale/retryable

Invalidation triggers:

- source filename/root change
- file watcher event
- remote policy change
- explicit retry
- cache-file completion
- renderer scale/theme changes only when they affect derived resources

Never repeatedly resample one shared image between two requested dimensions every frame. Cache source canvas separately from bounded derived canvases, or use renderer scaling where quality/performance permits.

### Layer 7: lifecycle and commands

Add first-class core lifecycle seams instead of stacking global wrappers:

- `Doc` metadata listener for filename and syntax changes
- Document close listener
- Editor feature attach/detach registry or explicit Markdown feature hook in the Editor creation path
- view-local Live Preview/Source Mode override persisted with the Editor in Workspace state
- commands registered through ordinary command predicates
- widget/POI activation through generic `DocView` seams

Lifecycle scenarios that must converge on the same code path:

- open existing `.md`
- restore Workspace
- save untitled Document as `.md`
- save/rename `.md` to non-Markdown
- move note within one Project
- move note across Projects/link roots
- direct `Doc:set_filename(...)`
- `Doc:reset_syntax()` without filename change
- external file replacement/reload
- close one of several Editors sharing a Document
- toggle feature/config while Editors are open

## Proposed module layout

The final names may change during the parser spike, but responsibilities should be separated as follows:

```text
data/core/markdown/
  init.lua                 lifecycle registration and public facade
  model.lua                per-Document semantic snapshot/cache
  parser.lua               Lua adapter to selected native/parser backend
  obsidian_syntax.lua      Obsidian-only syntax and serialization rules
  render.lua               source-ranged line/block render plans
  reveal.lua               view-local Reveal Unit policy
  interactions.lua         links/widgets/status/commands
  link_index.lua           Project/link-root note and attachment index
  links.lua                link parse/normalize/serialize helpers
  anchors.lua              heading paths/slugs and block IDs
  assets.lua               shared local/remote asset resolution/cache
  images.lua               image decode/size/render plans
  embeds.lua               note/attachment/embed classification
  attachments.lua          attachment location/import/link insertion
  diagnostics.lua          counters and quiet diagnostics
```

Migration rules:

- Remove `vault_index.lua` after callers/tests move to `link_index.lua`; do not leave a deprecated internal alias.
- Remove parser duplication only after `MarkdownView` tests pass through the shared semantic layer or `MarkdownView` is deliberately retained with an isolated parser.
- Remove Markdown method wrappers once lifecycle/widget seams exist.
- Preserve the full-window image viewer, including smooth zoom, pan, and click-outside close behavior, but move its input interception behind a root overlay/modal contract rather than ad hoc method wrapping.

## Reveal behavior design

### Recommended model

Use construct-sensitive reveal as the target because it most closely matches Obsidian's documented “cursor enters formatted content” behavior.

Examples:

- caret inside `**bold**` reveals that emphasis construct, not unrelated links on the line
- caret inside a wikilink reveals the whole wikilink source
- caret in heading content reveals heading markers and inline construct markers needed for editing
- caret in list text may keep the rendered bullet/checkbox while revealing the source marker when the caret approaches it or the line is edited
- caret inside a code fence keeps the code body source-like; fence markers reveal at their own lines
- a selection intersecting hidden syntax reveals every intersected construct or uses raw fallback for the containing block
- multi-cursor reveals the union of relevant constructs

Where construct reveal is unsafe or confusing, use a containing-line/block raw fallback. The policy must be represented in `reveal.lua`, not spread through parser and drawing code.

### Pointer and keyboard stability

- Freeze the pre-click render layout from pointer-down through pointer-up plus one deferred update.
- Record the Document identity and `text_revision` in the frozen snapshot.
- Resolve the source position against the frozen layout only while that revision is still current.
- If text changes, reloads, filename/syntax detach occurs, or the Editor closes while frozen, cancel the interaction or fall back immediately to current raw mapping; never apply an old source position to a new revision.
- Apply the selection only after the revision check.
- Recompute reveal state after the click completes.
- During drag selection, keep one same-revision render layout until release.
- Keyboard movement can update reveal immediately, but preserve the caret's visual/viewport anchor if wrapping changes.
- IME composition locks the affected Reveal Unit raw until composition ends.

### Source Mode

Source Mode removes Markdown replacement/hiding fragments while retaining normal Markdown syntax highlighting and Editor behavior. It does not create a new view or Document. Live Preview is the global default after its release gates pass; a temporary per-Editor Source Mode override is persisted in Workspace state.

## Wrapping and layout plan

The current raw fallback is an acceptable safety mechanism during development, not the target.

Required algorithm:

1. Build one cached render plan for the line.
2. Expose measurement fragments from that same plan.
3. Compute wrap boundaries in source-column space using visible widths.
4. Treat hidden markers as zero-width with deterministic source affinity.
5. Treat inline widgets as unbreakable measured fragments.
6. Treat block images/tables/embeds as composed visual rows rather than pretending they are text height.
7. Draw, hit-test, select, and place IME from the same wrap result.
8. On reveal change, recompute only old/new affected lines.
9. Preserve a stable viewport anchor: preferably the primary caret row when visible, otherwise the first visible source position.
10. Keep raw fallback for a line whenever its render and wrap generations disagree.

Tests must include an alias whose raw target is much longer than its display text, nested emphasis near a wrap boundary, tabs, Unicode, an image in text, and entering/leaving a construct that changes row count.

## Link behavior plan

### Parse and normalize

Support persisted Wikilink and Markdown-link forms, current-note headings/blocks, nested heading paths, percent encoding, angle-bracket destinations, aliases, and embeds.

Keep these distinct:

- parsed raw target
- decoded filesystem/link target
- display text
- canonical resolved identity
- serialized form chosen for insertion/update

Never rewrite a link merely because it was displayed.

### Resolve

Recommended precedence, subject to fixtures against actual Obsidian behavior:

1. Current-note heading/block target when path is empty.
2. Explicit relative path from the source note.
3. Explicit root-relative path within the owning link root.
4. Exact indexed Project-relative path, with Markdown extension omission.
5. Exact unique note basename.
6. Exact unique alias, provided it does not conflict with a higher-precedence path/name candidate. This supports manually persisted/imported `[[Alias]]` links, while insertion still serializes `[[Canonical note|Alias]]`.
7. Case-insensitive unique match where the filesystem/platform policy permits.
8. Ambiguous/missing result; never choose an arbitrary candidate.

Add explicit fixtures for unique persisted aliases, unsaved alias edits, alias-versus-basename collisions, two notes sharing one alias, and canonical serialization after alias autocomplete.

Absolute paths outside the link root are external file links, not internal notes.

### Present and interact

- resolved internal link: normal link style
- missing link: unresolved style and creation affordance if enabled
- ambiguous link: warning style and candidate picker action
- pending index: neutral/pending style, not falsely missing
- invalid syntax: raw source
- external URL: external-link style

Interaction seams:

- canonical `markdown-live-preview:open-link` command to open the link at the primary caret
- selected modifier-click behavior
- optional click-specific icon/region for touch-like use
- status-bar text with destination/reason
- context actions: open, open beside, copy target, copy resolved path, reveal in File Tree, create missing note, choose ambiguous target
- heading/block open uses normal Editor navigation and records Navigation History

### Rename and serialization

If automatic link maintenance is enabled:

- gather affected files from the index
- parse links semantically rather than text-replacing names
- calculate new target text using the selected path policy
- preserve alias/display text and Wikilink versus Markdown syntax where possible
- preview or log the operation
- write through safe-write paths
- update open Documents through normal transactions
- avoid rewriting links that happen to contain the same text but resolve elsewhere
- define recovery behavior if only part of a multi-file update succeeds

This is a separate feature slice, not an incidental file-tree rename hook.

## Image and attachment plan

### Rendering policy

For each parsed image:

- resolve against source note directory, owning link root, and configured Obsidian attachment policy
- distinguish image-only block, inline image, and image inside table/callout
- clamp to available content width
- preserve aspect ratio for width-only syntax
- treat explicit width×height as a bounding box and preserve aspect ratio
- do not upscale by default
- use high-quality scaling for ordinary images; nearest-neighbor only when explicitly appropriate
- retain alt/path text for accessibility/status/failure display

### Active editing

The source remains visible and reachable without opening Source Mode:

- render images inline while retaining their actual Markdown link/source line as visible, editable text
- present inactive image source intentionally rather than as undifferentiated raw text
- entering the image link's Reveal Unit exposes the exact Markdown needed for editing without removing the rendered image
- inline images remain inline only below a sensible size; large images become block rows without hiding their source line
- clicking the rendered image opens the full-window viewer; ordinary source-text clicks place the caret
- the viewer supports smooth zoom and pan, and clicking outside the image closes it

### Failure/retry behavior

- missing local file: missing-image chip with retry/open-folder actions
- remote disabled: remote-image chip with one-shot load/open actions
- loading: bounded placeholder, no layout collapse
- decode failure: error chip with path and retry
- file appears or changes: watcher invalidates the entry
- policy/source-root changes: re-resolve rather than reuse stale entries
- async completion checks Editor/Document lifetime and generation

### Attachment insertion

After core rendering is stable:

- paste an image file into the Editor
- drag an external image file into the Editor
- choose destination from configured policy
- sanitize and deconflict filename deterministically
- copy/write atomically
- insert selected Wikilink/Markdown embed syntax in one undoable text transaction
- if file copy succeeds but insertion fails, report and offer cleanup
- if insertion succeeds only after copy, never leave a link to a nonexistent destination silently

## Block feature plans

### Lists and tasks

- render bullet glyphs without losing marker source mapping
- preserve ordered-list number source
- support nesting and continuation lines
- render task marker as a checkbox widget
- clicking checkbox changes only the marker character in one undoable command
- support Obsidian's non-space completion markers without assuming only `x`
- add list continuation/dedent editing behavior only through separately tested commands; do not mix it into rendering

### Blockquotes and callouts

- use block-level ranges, nesting depth, and composed backgrounds/rails
- callout header parses type, optional fold sign, and title
- unknown type uses default note styling
- folding uses the existing Fold Region model where possible
- links/images inside callouts use ordinary nested render plans
- raw fallback applies to the whole callout if nested mapping becomes inconsistent

### Code

- inline code gets a monospace font/background and construct reveal
- fenced/indented blocks remain source-oriented editing surfaces with block background/padding
- fence/info markers can dim/hide only when safe
- reuse existing syntax/subsyntax highlighting rather than introducing Prism
- never parse Markdown constructs inside code

### Tables

Tables require a dedicated decision and vertical slice.

Minimum robust mode:

- preserve source rows
- style delimiters/header/alignment
- keep horizontal overflow contained
- provide row/column commands operating on parsed source ranges

Optional rich mode:

- replace the table block with an interactive grid when inactive
- give each cell a source range and stable widget identity
- edit a focused cell without serializing unrelated text incorrectly
- Tab/Shift-Tab navigation
- insert/delete/move rows/columns through commands
- reveal/fallback the source block whenever mapping is uncertain

Do not attempt rich tables until generic block-widget focus, selection, wrapping, and undo semantics are tested.

### Properties

Baseline mode styles frontmatter as structured source and indexes `aliases`, `tags`, and related metadata.

Optional Obsidian-like mode replaces valid top-of-file frontmatter with property rows while inactive. This requires:

- YAML parser with source preservation
- stable key/value ranges
- duplicate/unsupported/nested-property fallback
- typed controls
- keyboard navigation into/out of the property widget
- undoable source edits
- Source Mode escape hatch

This is a separate product feature, not a parser side effect.

### Math and diagrams

- Math rendering requires a native or bundled TeX layout strategy; do not fetch a web renderer at runtime.
- Mermaid requires a renderer/runtime and security policy and belongs in Tier 3 unless explicitly prioritized.
- Until supported, both remain well-styled source/code blocks.

## Performance design and budgets

### Required counters

Add quiet/performance counters for:

- parser time, publication time, and bytes/lines parsed
- full versus dirty-block parse reason
- render-model cache hits/misses
- lines whose metrics/wraps were invalidated
- lines parsed/rendered during one caret move
- link-index scan/update counts and durations
- image resolve/decode/scale durations and cache state
- stale async results discarded
- raw-fallback reasons

### Initial budgets to validate during the parser spike

These are engineering gates, not permanent user configuration:

- ordinary caret move in a parsed note: no Document-wide iteration
- ordinary draw frame: no parser call
- 100 KB note single-line edit: parser/model publication should normally fit within one 16 ms frame, preferably below 4 ms on the dev machine
- 1 MB note: Editor remains responsive; expensive reconciliation may yield, but changed/visible content updates promptly
- link-index startup: never block the UI for a full Project scan
- image decode/scale: off the critical typing path; layout placeholder is stable

Use existing performance capture infrastructure and add a Markdown stress fixture/tool if necessary. Do not encode exact timing as a flaky Meson unit test; encode counters/invariants and maintain a repeatable benchmark command.

## Implementation phases

Each phase is a vertical slice with a red-green acceptance test. A module existing is not completion.

### Phase 0: decision recording, quarantine, and baseline characterization

**Completed July 10, 2026.** The reproducible baseline and known full-suite issue are recorded in `MARKDOWN_LIVE_PREVIEW_BASELINE.md`.

- Record the resolved owner decisions at the end of this plan.
- Record the canonical feature name in `CONTEXT.md`.
- Keep current Live Preview available for comparison, but set the development default honestly until release gates pass.
- Add focused repro tests for every known gap before replacing code:
  - direct filename/syntax lifecycle
  - no initial link-index build
  - link cannot open
  - missing/ambiguous link style
  - whole-Document metric rebuild on caret move
  - repeated parser calls from draw/mapping
  - stale missing/remote-disabled image cache
  - wrapped alias behavior
- Capture current Markdown UI/performance baseline.
- Document which full-suite failures are unrelated before feature work proceeds.

Exit gate: known gaps reproduce deterministically and the current prototype can be compared without relying on memory.

### Phase 1: parser and semantic-model spike

**Completed July 10, 2026.** Tree-sitter Markdown 0.5.3 was selected and the evidence is recorded in `MARKDOWN_PARSER_BACKEND.md`. The worker-backed composite parser, revision-checked per-Document semantic model, exact-range compatibility fixtures, request coalescing/cancellation, pending raw fallback, persistent incremental block/inline and block-capture reuse, edit-mapped stable semantic IDs, coalesced changed-line publication, indexed bounded line queries, and native Wikilink/embed/highlight/comment layer are implemented. Repeatable 100 KiB/1 MiB measurements are recorded in `MARKDOWN_OBSIDIAN_EXTENSIONS.md`; final correctness-gated 100 KiB runs produced a 17–18 ms native total, slightly above the provisional 16 ms latency target. Phase 1 therefore calibrates the accepted budget to a 20 ms background publication: no parser/adoption work runs synchronously, visible-result queries remain below 0.05 ms, and the 1 MiB path stays background/cancellable and bounded at adoption.

- Build an independent compatibility fixture corpus from CommonMark/GFM/official Obsidian syntax examples without copying large documentation bodies.
- Pin/vendor and compile the smallest viable MD4C integration through Meson; publish one exact source-ranged fixture through an Anvil native API and native test.
- Prototype tree-sitter-markdown only far enough to compile both grammars in Anvil and compare exact ranges, malformed input, split-parser/included-range integration, and update cost through the same kind of publication boundary.
- Define native result memory ownership, compact snapshot serialization/querying, worker job protocol, request coalescing, cancellation/supersession, and stale-result disposal.
- Measure native parse plus publication, not parser time alone, synchronously and through the worker path.
- Select one backend and document why; remove the losing experimental integration rather than retaining two parser stacks.
- Implement Document semantic model with revision checking, pending-state raw fallback, and bounded adoption work.
- Cover CommonMark delimiter edge cases, nesting, escapes, code suppression, tables, frontmatter, Unicode, CRLF, and incomplete typing.

Exit gate: the selected parser is reproducibly built by Meson, passes native plus Lua-facing compatibility tests, exposes exact source ranges, survives pathological fixtures, coalesces/cancels stale work, publishes a compact revision-checked snapshot without unbounded UI adoption, and meets the measured synchronous/background budgets.

### Phase 2: core lifecycle, render caching, and wrapping

**Lifecycle slice completed July 10, 2026.** `Doc` now publishes batched filename/syntax/close events; the shared semantic model follows eligibility and closes automatically; and each split `DocView` owns independent automatic Live Preview attach/detach lifecycle. The contract and red-green evidence are recorded in `MARKDOWN_LIFECYCLE.md`. Render caching, range-based metrics, wrapping, reveal/IME, and generic widget/POI work remain.

- Add first-class `Doc` metadata/syntax listeners.
- Add owned Editor feature attach/detach lifecycle.
- Make line render provider output cached and target-invalidatable.
- Make metric invalidation range-based.
- Integrate render fragments into wrapping.
- Complete pointer freeze, multi-cursor reveal, IME, and viewport anchoring.
- Replace Markdown mouse/global wrappers with generic widget/POI contracts.
- Keep Markdown rendering minimal during this phase: one synthetic provider plus headings/one inline span are enough to prove core behavior.

Exit gate: direct save-as/rename/syntax changes work automatically; wrapped source mapping is correct; caret movement touches only old/new affected lines; all generic `DocView` tests and non-Markdown fast-path tests pass.

### Phase 3: robust core Live Preview vertical slice

Implement through the new semantic/render model:

- headings
- bold/italic/bold+italic
- strikethrough/highlight
- inline code
- escapes
- Markdown and external link presentation
- comments
- Source Mode
- construct-sensitive Reveal Unit policy with safe line/block fallback

Delete corresponding ad hoc parsing from `live_render.lua` as each slice lands.

Exit gate: a representative prose note can be edited entirely in Live Preview with wrapping, selections, multi-cursor, IME, find/replace, undo/redo, and no raw-fallback surprises for supported inline syntax.

### Phase 4: internal links end to end

- Build asynchronous/cooperative Markdown Link Index.
- Add watcher reconciliation and open-Document overlay.
- Resolve notes, aliases, headings, nested heading paths, blocks, attachments, URLs, pending, missing, and ambiguity.
- Add status, command, mouse gesture, context actions, and Navigation History integration.
- Add an explicit create-note action for missing links and a picker for ambiguous links.
- Add autocomplete/search states for `[[`, `[[#`, `[[##`, `[[^`, and `[[^^`.
- Add the per-Project generated-link serialization policy, defaulting to shortest unique Wikilinks.
- Implement rename-link maintenance with an affected-file preview and confirmation; automatic updates remain a later opt-in per-Project setting.

Exit gate: links work after cold startup, unsaved edits, create/delete/rename, multiple Projects, ambiguity, and Project moves without manual rebuild or random target selection.

### Phase 5: images and attachment workflow

- Replace image cache with context-aware retryable asset service.
- Render local/remote-policy Markdown images and Wikilink image embeds.
- Support both officially documented external sizing forms (`![250](url)` and `![alt|100x145](url)`) plus Wikilink width and width×height syntax, with explicit alt-text semantics.
- Integrate images with wrapping/composed rows while keeping intentionally styled source visible and revealing exact Markdown inside the active image link.
- Preserve or refactor image overlay through generic overlay/input contracts.
- Add remote-disabled/load-once policy.
- Implement image paste/drop attachment import for core completion, including supported `.obsidian` attachment-folder policies.

Exit gate: image references and both documented external sizing forms remain correct across note rename/move, file appearance/change, Project change, policy toggles, two sizes of one image, wrapping, and async completion; paste/drag import copies images to the selected attachment location and inserts source-preserving links in one undoable transaction.

### Phase 6: block-level core experience

- paragraphs/line breaks
- ordered/unordered/nested lists
- task widgets
- blockquotes
- callouts
- fenced/indented code
- horizontal rules
- frontmatter baseline
- tags
- reference links and footnotes to the selected support level

Exit gate: normal note-taking no longer drops to raw presentation for common block constructs, and all widget edits are source-preserving and undoable.

### Phase 7: selected advanced blocks and embeds

Implement separate vertical slices for the required selected scope:

- styled editable tables with reliable row/column commands
- styled-source math presentation
- note, heading, and block embeds
- generic clickable attachment chips, including PDF/audio/video files

Keep rich table grids, editable property-row UI, rendered math, native PDF previews, media players, and Canvas/Base previews as deferred follow-up slices.

Each implemented slice needs its own public behavior tests, mapping tests, focus/keyboard tests, wrapping tests, malformed-source fallback, and performance check.

### Phase 8: promotion and cleanup

- Run targeted and full Anvil suites.
- Run GUI smoke and manual scenario matrix under D3D11 and software rendering where relevant.
- Run large-note and large-Project benchmarks.
- Remove superseded parser/render/index code and obsolete config keys.
- Update `MarkdownView` to shared services or explicitly document it as independent Reading view.
- Make Live Preview default only after the Tier 0 correctness and Tier 1 experience gates pass; do not declare the selected core scope complete until required Tier 2 embeds/chips and image attachment import also pass.
- Update user-facing docs and command names.
- Update this plan with final status instead of leaving milestone names as the only record.

## Test strategy

### Parser/model tests

Use table-driven fixtures for:

- all CommonMark/GFM constructs Anvil claims
- all selected Obsidian extensions
- exact marker/content/source ranges
- nested and adjacent spans
- escapes and entities
- Unicode and combining characters
- tabs and CRLF
- malformed and half-typed constructs
- raw HTML suppression
- code suppression
- pathological delimiters/nesting
- frontmatter and property edge cases

Expected values must be independent literals/fixtures, not output recomputed with the parser's own algorithm.

### Runtime link/index tests

- cold initial scan and readiness
- owning Project/link root
- multiple Projects with duplicate names
- exact/relative/root-relative/basename resolution
- nested heading paths
- block-ID placement rules
- aliases and canonical serialization
- missing/ambiguous/pending states
- open unsaved Document overlay
- heading/block/alias edits
- file create/delete/rename/move
- watcher coarse-directory event reconciliation
- forced watcher-budget/capacity failure enters degraded reconciliation mode and still discovers later changes
- ignored/outside-root files
- generated link path policies
- safe rename updates if enabled

### In-process UI tests

Drive public seams:

- attach/detach through real filename/syntax events
- command-performed Source Mode toggle
- caret and selection entering/leaving Reveal Units
- pointer-down/up freeze and drag selection
- text transaction, reload, detach, and Editor close while pointer freeze is active never reuse stale source mapping
- multi-cursor and IME state
- wrap-boundary caret/hit testing
- viewport anchor after reveal row-count change
- headings, inline spans, code, lists, tasks, links, images, callouts, and selected widgets
- link open through command/widget activation
- status tooltip state
- Source Mode preserves selection/scroll
- non-Markdown Editor unaffected

Avoid exact keyboard shortcuts and cosmetic pixel constants. Assert durable mapping, state, source text, focus, navigation, and bounded layout behavior.

### Property/fuzz testing

Generate source fragments and assert invariants:

- every source column maps to a finite x and inverse mapping stays within a valid affinity range
- edits never change unrelated source bytes
- render fragments are ordered, non-overlapping, and within source bounds
- parser/model never hangs or throws on arbitrary bytes accepted by `Doc`
- toggling mode cannot change Document text
- stale async generations cannot publish

### Performance tests and tools

- counter assertion: caret movement invalidates bounded lines
- counter assertion: draw performs zero parses
- counter assertion: plain non-Markdown Editor uses no Markdown model
- repeatable 10 KB, 100 KB, 1 MB note benchmark
- Project index benchmark with duplicate basenames and many attachments
- image stress note with mixed local/missing/remote/two-size images

### Full validation

Targeted commands remain Meson-based. Before promotion:

```sh
PATH=/c/msys64/mingw64/bin:$PATH /c/msys64/mingw64/bin/meson.exe test -C build-windows-x86_64 --suite anvil --print-errorlogs
```

The full suite must complete—not merely print Markdown passes before a later timeout. If unrelated failures exist, isolate and resolve or obtain explicit owner approval before calling promotion complete.

## Diagnostics

Use `core.log_quiet(...)` for:

- attach/detach and mode transitions
- filename/syntax/root lifecycle decisions
- parser backend/version and fallback reason
- parse/index/image timing summaries
- stale generation rejection
- link pending/missing/ambiguous resolution
- watcher loss and bounded-rescan reason
- remote policy decisions
- image retry/decode failure
- raw-render fallback reason
- provider exception signature

Visible warnings are reserved for actionable operations such as failed attachment import, failed multi-file rename update, or an explicit user-requested remote load failure.

## Rollout policy

- During Phases 0–2, default to Source Mode/current raw behavior unless explicitly enabled for development.
- During Phases 3–6, allow Live Preview opt-in and preserve a one-command Source Mode escape hatch.
- Promote Live Preview to the global default only when Tier 1 completion criteria and all Tier 0 gates pass.
- Treat default-on promotion and completion of the broader selected core scope as separate gates: image attachment import, note/heading/block embeds, and generic attachment chips must also pass before the selected core scope is declared complete.
- Keep remote downloads disabled by default, with one-shot loading and an optional trusted-Project policy.
- Do not preserve deprecated internal Markdown aliases after all in-repo callers migrate.
- Retain the separate `MarkdownView` as optional Reading view during the rebuild; reconsider retirement only after parity and shared parser migration.

## Definition of “it just works”

The feature is complete for the selected scope when all of these are true:

- Markdown files automatically enter the selected default mode through every open/restore/save-as/rename path.
- Source Mode is always available without replacing the Editor.
- Supported syntax renders consistently and reveals predictably.
- Wrapping, pointer selection, keyboard selection, multi-cursor, IME, find/replace, folding, undo/redo, reload, and copy all operate on correct source positions.
- Link state is useful from cold start and remains current after unsaved edits and filesystem changes.
- Link opening, heading/block navigation, ambiguity, and missing targets have deterministic behavior.
- Images resolve, retry, resize, and update without stale context or implicit network access.
- Image paste/drag import follows the selected attachment policy and inserts a source-preserving link transactionally.
- Note, heading, and block embeds resolve through the owning link boundary; unsupported non-image media remains available through generic attachment chips.
- Normal note-taking constructs do not unexpectedly drop to raw source.
- Unsupported/malformed constructs remain safely editable raw source.
- Ordinary caret motion and draw do not perform Document-wide Markdown work.
- Large notes and Projects remain responsive.
- Non-Markdown Editors retain normal behavior/performance.
- The selected targeted, full, GUI, and benchmark validation passes.
- This plan and user documentation accurately state what is supported.

## Research sources

Official/current sources consulted:

- Obsidian Help, Views and editing mode: `https://help.obsidian.md/edit-and-read`
- Obsidian Help, Basic formatting syntax: `https://help.obsidian.md/syntax`
- Obsidian Help, Advanced formatting syntax: `https://help.obsidian.md/advanced-syntax`
- Obsidian Help, Obsidian Flavored Markdown: `https://help.obsidian.md/obsidian-flavored-markdown`
- Obsidian Help, Internal links: `https://help.obsidian.md/links`
- Obsidian Help, Embed files: `https://help.obsidian.md/embeds`
- Obsidian Help, Attachments: `https://help.obsidian.md/attachments`
- Obsidian Help, Properties: `https://help.obsidian.md/properties`
- Obsidian Help, Aliases: `https://help.obsidian.md/aliases`
- Obsidian Help, Callouts: `https://help.obsidian.md/callouts`
- Obsidian Help, Tags: `https://help.obsidian.md/tags`
- Obsidian Help, Accepted file formats: `https://help.obsidian.md/file-formats`
- Official help source repository: `https://github.com/obsidianmd/obsidian-help`

Observed/inspiration sources:

- Obsidian Forum, Markdown formatting characters in Live Preview: `https://forum.obsidian.md/t/markdown-formatting-characters-in-live-preview/50439`
- Atomic Editor: `https://github.com/kenforthewin/atomic-editor`
- CodeMirror hybrid Markdown discussion: `https://discuss.codemirror.net/t/hybrid-markdown-editing-preview-for-unfocused-lines-raw-for-active-line/9660`
- MD4C: `https://github.com/mity/md4c`
- tree-sitter-markdown: `https://github.com/tree-sitter-grammars/tree-sitter-markdown`
- cmark-gfm: `https://github.com/github/cmark-gfm`

Official Help is the syntax/behavior authority. Forum reports and open-source editors are implementation inspiration and must not be presented as exact Obsidian guarantees.

## Owner decisions

Resolved by the owner on July 10, 2026. These decisions define the target product scope; later changes require an explicit owner decision and a corresponding plan update.

### 1. Reveal behavior

Use Obsidian-like construct reveal: reveal only the formatted construct entered by the caret, with a containing-line or block raw fallback where precise reveal is unsafe.

### 2. Default mode and persistence

After the release gates pass, Markdown Live Preview is the global default. Each Editor can temporarily switch to Source Mode, and that per-Editor override is persisted in Workspace state.

### 3. Reading view / existing `MarkdownView`

Retain the existing `MarkdownView` as an optional Reading view during the rebuild. Reconsider retirement only after Live Preview reaches feature parity and shared parser migration is complete.

### 4. Typography

Use the proportional UI/text font for body text and headings, monospace for inline and fenced code, and the normal code font in Source Mode.

### 5. Link activation

Use Ctrl+click on Windows/Linux and Cmd+click on macOS, plus a keyboard command, to open links. An ordinary click places the caret for editing.

### 6. Missing and ambiguous links

Offer an explicit create-note action for a missing link. Show a picker for an ambiguous link. Never create or choose a target silently when its identity is uncertain.

### 7. Link root boundary

Resolve links against the owning Anvil Project by default. Allow an explicit per-Project option to use the nearest ancestor containing `.obsidian`. Exclude External Project Directories unless the Project explicitly includes them in its Markdown link index.

### 8. Generated link format

Make generated-link format configurable per Project and default to the shortest unique Wikilink.

### 9. Automatic link updates on rename

Initially show an affected-file preview and ask before rewriting links. After the operation is proven safe, allow automatic updates as an optional per-Project setting.

### 10. Remote images

Keep remote images disabled by default. Offer a one-shot load action and an optional trusted-Project policy.

### 11. Image editing presentation

Render images inline while keeping their actual Markdown link/source line visible and editable. When inactive, present that source intentionally rather than as undifferentiated raw text; when the caret enters the image-link contents, reveal the exact Markdown needed for editing. The source remains authoritative and reachable without switching the entire Editor to Source Mode.

Clicking the rendered image opens a full-window image viewer with smooth zooming and panning. Clicking outside the image closes the viewer. Preserve the existing overlay behavior where sound, and move it behind the generic overlay/input contract during the rebuild.

Treat explicit width×height dimensions such as `|640x480` as a bounding box and preserve aspect ratio rather than distorting the image.

### 12. Attachments workflow

Include image paste and drag/drop import in the core release, including the supported `.obsidian` attachment-folder policies. Non-image media import may follow later.

### 13. Note and non-image embeds

Include note, heading, and block embeds plus generic clickable attachment chips in Tier 2. Defer native PDF previews, audio/video players, and Canvas/Base previews.

### 14. Tables

Ship styled editable table source with reliable row/column commands first. Treat a full interactive visual grid as a later dedicated feature slice.

### 15. Properties/frontmatter

Show raw but styled YAML in the core release and index aliases and tags from it. Add editable property-row UI later.

### 16. Math and HTML

Show math as styled source until a safe native renderer is selected. Keep raw HTML source-only and do not parse Markdown nested inside HTML.

### 17. Canonical user-facing name

Use **Markdown Live Preview** in commands, settings, documentation, and the project glossary.
