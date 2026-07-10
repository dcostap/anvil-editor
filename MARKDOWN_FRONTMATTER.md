# Markdown frontmatter baseline

Markdown Live Preview treats only parser-confirmed top-of-file `---` or `+++` metadata blocks as frontmatter.

## Editor presentation

Baseline mode preserves every source character and source column. Inactive blocks receive a first-party background, delimiter styling, and key/separator styling. Unsupported, nested, duplicate, or incomplete values remain ordinary styled source rather than being interpreted as property widgets. Touching a line reveals the ordinary raw Editor path, and Source Mode remains the whole-view escape hatch.

This milestone deliberately does not provide typed property controls. Rich property rows require a source-preserving YAML parser and the widget focus/editing contract described in `MARKDOWN_LIVE_EDITOR_PLAN.md`.

## Index metadata

The Project Markdown index reads a conservative metadata subset without executing YAML:

- scalar and bracket/list forms of `alias` / `aliases`;
- scalar and bracket/list forms of `tag` / `tags`;
- simple top-level scalar values for consumers that need metadata.

Quotes and surrounding whitespace are normalized. Leading `#` is removed from indexed tags. Nested mappings and unsupported YAML syntax are retained in the document but are not guessed by the index.

Open-Document overlays use the same extraction path as disk notes, so unsaved frontmatter remains authoritative while tracked.
