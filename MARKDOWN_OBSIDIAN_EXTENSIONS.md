# Obsidian Syntax Semantic Layer

Implemented July 10, 2026 for the Phase 1 Markdown Live Preview semantic model.

## Supported extension nodes

The worker-backed semantic snapshot adds exact source-ranged captures for:

- `[[target|alias]]` as `wiki_link`;
- `![[target|alias]]` as `embed`;
- `==content==` as `highlight`; and
- `%%content%%` as `comment`, including multiline comments.

Each complete construct publishes a parent range, separate opening/closing marker ranges, and content ranges. Wikilinks and embeds publish separate `target` and optional `alias` attributes. Image dimensions remain serialized in the alias portion at this layer; the image/embed layer interprets width and width×height forms later.

## Composition with CommonMark/GFM

Tree-sitter Markdown remains authoritative for CommonMark/GFM blocks and inlines. A small cancellable native scanner runs in the same worker job after the composite parse and appends Obsidian-only captures to the same refcounted, revision-checked result.

Tree-sitter ranges suppress extension scanning inside:

- fenced and indented code blocks;
- inline code;
- frontmatter;
- raw HTML blocks/tags; and
- math spans.

Comments suppress CommonMark inline captures inside their range. Wikilink/embed parents suppress Tree-sitter's shortcut-reference interpretation of the inner bracket pair. Highlights retain confidently parsed nested inline Markdown, such as bold text.

## Conservative fallback

The scanner publishes only complete delimiter pairs. Escaped openers, incomplete Wikilinks, incomplete highlights, and empty content remain source. Wikilinks/highlights do not cross source lines; comments may cross lines. Delimiter and escape processing are bounded linearly even for large unmatched-delimiter or backslash-heavy input. The scan checks both cancellation and its worker deadline during preprocessing and delimiter/content searches.

## Publication and performance

Extension captures use the same native capture limits, stable-ID reconciliation, interval line index, cancellation token, stale-generation rejection, and bounded Lua line query as grammar captures. No Document-wide extension scan occurs on the UI thread.

Repeatable benchmark:

```sh
meson test -C build-windows-x86_64 anvil:lua-runtime \
  --test-args tests/lua/benchmarks/markdown_semantic_model.lua \
  --print-errorlogs --verbose
```

July 10, 2026 debugoptimized measurements on the development machine, using a representative prose fixture with sparse rich syntax:

| Fixture | Full native parse | Incremental native parse | Incremental native total | Visible semantic query |
| --- | ---: | ---: | ---: | ---: |
| 100 KiB / 1,136 lines | 42–48 ms | 14–16 ms | 19–20 ms | 0.02–0.05 ms |
| 1 MiB / 11,632 lines | 421–432 ms | 166–173 ms | 200–202 ms | 0.01–0.03 ms |

The 100 KiB parser work is near the initial 16 ms target but total background publication is still slightly above it. The 1 MiB path remains background/cancellable and bounded at adoption, but incremental native work remains a Phase 2 optimization target. These are recorded measurements rather than timing assertions in Meson.
