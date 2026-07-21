# Semantic Markdown Link Rendering

Implemented July 10, 2026 as the second Phase 3 slice in `MARKDOWN_LIVE_EDITOR_PLAN.md`.

## Exact semantic adoption

`core.markdown.links.from_semantic_node()` converts exact semantic node and attribute ranges into the existing normalized link target model:

- Markdown links and images use `link_text` / `image_alt` and `link_destination` ranges;
- Wikilinks and embeds use exact `target` and `alias` ranges;
- heading and block subtargets are preserved;
- image/embed bounding-box dimensions are parsed from aliases; and
- semantic identity and source ranges remain attached.

Malformed, incomplete, empty, multiline, truncated, or suppressed nodes stay raw.

## Renderer migration

`live_render.lua` no longer imports or invokes the ad hoc Markdown parser. Link/image spans are adopted from the current semantic snapshot, including deduplication of Tree-sitter image captures that overlap a native Obsidian embed capture.

Decoded links compose enclosing bold/italic/strikethrough/highlight style. Links overlapping semantic comments are suppressed. Formatting-wrapped images retain their widget behavior while their outer markers remain source-addressable.

All textual links use the first-party blue link color and underline regardless of resolved, missing, ambiguous, pending, or external status. Resolution metadata and activation behavior remain distinct, but status does not recolor link text. Inactive Wikilinks without aliases retain their complete target text, including heading or block subtargets. Revealing a link keeps that same linked text blue and underlined while presenting its exact surrounding source markers in the hidden-syntax color.

The older scanner APIs in `core.markdown.links` remain for non-Live-Preview callers until those boundaries migrate; they are no longer a rendering dependency.

## Regression evidence

Focused tests verify exact semantic target adoption, aliases, visible heading subtargets, unified active/inactive link styling across resolution states, image dimensions, formatting-wrapped decoded labels, project-local images, Wikilink embeds, pending raw fallback, wrapping, comments, and the broader Markdown Live Preview baseline.
