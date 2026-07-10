# Markdown Link Completion and Serialization

Implemented July 10, 2026 as a Phase 4 Markdown Live Preview slice in `MARKDOWN_LIVE_EDITOR_PLAN.md`.

## Completion states

The first-party Autocomplete plugin now exposes generic dynamic-provider registration. Providers are refreshed before ordinary automatic/manual suggestion calculation and may request opening even when the generic partial-symbol minimum has not been reached.

Markdown Live Preview registers one provider while attached. It recognizes an unclosed Wikilink at the primary caret and publishes bounded, deterministic candidates for:

- `[[` — notes, canonical alias forms, and supported attachments;
- `[[#` — headings in the current note, serialized with structural ancestor paths when nested;
- `[[##` — headings across the owning Project/link root, likewise preserving nested paths;
- `[[^` — block IDs in the current note; and
- `[[^^` — block IDs across the owning Project/link root.

Matching is case-insensitive substring search over display text, serialized target, and Project-relative detail. Results are sorted by display text/path and bounded to 200. Pending indexes start their cooperative build and do not publish stale completion candidates.

`markdown-live-preview:complete-link` explicitly opens the same provider. Selecting a result replaces the whole incomplete construct (including an existing closing `]]`) in one ordinary Document text-input transaction. Multi-cursor and selected-range contexts intentionally decline completion until a deliberate multi-cursor contract is designed.

## Serialization policy

Generated note targets use a per-link-root policy:

- `shortest_unique` (the first-party default) — basename when unique, otherwise the shortest unique Project-relative form, retaining the Markdown extension only when needed to distinguish a root note;
- `relative` — explicit source-note-relative paths (`./` is retained for same-directory targets); and
- `root` — extensionless Project-root-relative paths.

Project configuration can call:

```lua
require("core.markdown.vault_index").set_link_path_policy(project_root, "relative")
```

The policy is retained for that normalized link root and updates any live index generation. Resolution remains syntax-compatible with all policies and gives an exact root note precedence over ambiguous nested basenames. Alias suggestions serialize canonical destination plus alias (`[[Canonical|Alias]]`) instead of treating the alias as the destination.

## Regression evidence

Runtime tests cover notes with colliding basenames, canonical aliases, attachments, local/global and structurally nested headings, local/global blocks, all three path policies, and root-path resolution. UI tests cover provider registration/automatic force-open, all five prefix states, explicit command invocation, and source-preserving selection replacement.
