# Markdown Link Completion and Serialization

Implemented July 10, 2026 as a Phase 4 Markdown Live Preview slice in `plans/done/MARKDOWN_LIVE_EDITOR_PLAN.md`.

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

- `shortest_unique` (the first-party default, Obsidian's "shortest") — the file name when no other file has that name, otherwise the Project-root path;
- `relative` — source-note-relative paths; Anvil adds `./` unless the path starts with `../`, so a path inside the note's folder never matches a root path first; and
- `root` (Obsidian's "absolute") — Project-root paths.

Note targets drop `.md`; attachment targets keep their extension. A vault's
`.obsidian/app.json` `newLinkFormat` selects the policy unless Project
configuration sets one.

Project configuration can call:

```lua
require("core.markdown.vault_index").set_link_path_policy(project_root, "relative")
```

The policy is retained for that normalized link root and updates any live index generation. Every generated target resolves back to its own file. Alias suggestions serialize canonical destination plus alias (`[[Canonical|Alias]]`) instead of treating the alias as the destination.

## Regression evidence

Runtime tests cover notes with colliding basenames, canonical aliases, attachments, local/global and structurally nested headings, local/global blocks, all three path policies, and root-path resolution. UI tests cover provider registration/automatic force-open, all five prefix states, explicit command invocation, and source-preserving selection replacement.
