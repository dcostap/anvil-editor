# Markdown Reveal Units

Implemented July 10, 2026 as the fourth Phase 3 slice in `MARKDOWN_LIVE_EDITOR_PLAN.md`.

## Construct selection

With `config.markdown_live_reveal_mode = "construct"`, each collapsed caret selects the smallest complete semantic construct containing its source column. Supported units include headings, formatting, inline code, escapes, comments, links, images, Wikilinks, and embeds.

Only markers/replacements belonging to that unit are revealed. Examples:

- entering one of two bold spans reveals only that span;
- entering one Wikilink exposes its exact source while another Wikilink remains decoded;
- entering nested bold inside a heading keeps the heading marker hidden; and
- entering a multiline comment reveals the full comment construct across its lines.

Equal-range overlapping semantic nodes, such as Tree-sitter image plus native embed captures, reveal together. A heading unit acts as a safe parent and reveals descendants when the caret is in plain heading content.

## Conservative fallback

A non-empty selection reveals every touched source line. If no supported semantic construct contains a collapsed caret, the caret line is revealed as the safe fallback. Setting `markdown_live_reveal_mode = "line"` explicitly retains whole-line reveal behavior.

Cold, pending, failed, truncated, and stale semantic states still use raw rendering, independent of reveal policy.

## View-local interaction

Reveal units are computed from the `DocView` selection owner, including all cursors. Mouse drag and IME composition continue to use the frozen interaction selection snapshot. Moving into or out of a multiline unit invalidates every dependency line, while ordinary construct movement targets only affected lines.

Provider cache generations encode the selected semantic units rather than a coarse active/inactive line flag. Source Mode bypasses Reveal Units entirely.

## Regression evidence

Focused tests cover isolated formatting and link reveal, nested heading formatting, multiline comment reveal/re-hide, multi-cursor headings, line fallback, pointer freeze, IME lifetime, Source Mode, wrapping, semantic links/images, and pending raw fallback.
