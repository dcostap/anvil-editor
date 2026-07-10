# Markdown Link Interaction

Implemented July 10, 2026 as the second Phase 4 slice in `MARKDOWN_LIVE_EDITOR_PLAN.md`.

## Generic rendered-fragment input

`DocView` now hit-tests non-widget rendered fragments in wrapped and unwrapped views. A fragment may provide `cursor` and `on_mouse_pressed`; dispatch occurs before ordinary text selection and failures are isolated through quiet diagnostics. Existing widget routing remains first priority.

Semantic Markdown link fragments use the hand cursor. Left click remains normal source selection. **Ctrl+left-click** activates the link on Windows/Linux; **Command+left-click** does so on macOS. This preserves the owner decision that rendered text must not steal ordinary editing input.

## Generic Points of Interest

Attached Markdown Editors publish current semantic link/image nodes through `DocView`'s generic POI provider contract. POIs carry exact source bounds, stable semantic IDs, and activation callbacks using the same normalized resolver as mouse/command activation. Tree-sitter suppression prevents code/comment lookalikes from becoming POIs.

Generic `poi:next` / `poi:previous` navigation therefore steps through links without Markdown-specific key handling, and `poi:activate` opens the target through the ordinary link path. Whole-Document adoption is explicitly bounded at 32,768 inline captures; oversized/truncated snapshots quietly decline POI publication rather than presenting incomplete random navigation.

## Commands

- `markdown-live-preview:open-link` opens the semantic link at the primary caret.
- `markdown-live-preview:create-link-target` explicitly creates/opens a missing internal note target.

Commands are tested by name rather than by configurable key bindings.

## Resolution behavior

- Resolved notes/attachments open through `core.open_file`.
- Heading and block results move the target Editor selection and viewport.
- External targets use the system launcher.
- Pending and missing targets are never opened implicitly.
- Missing targets require the explicit create command, remain inside the owning Project, create parent directories only when absent, strip query/fragment suffixes, default extensionless targets to `.md`, and follow resolver semantics: path-like targets are source-directory-relative while bare names are Project-root-relative. Invalid normalization and parent traversal fail safely at the Project boundary.
- Resolved disk targets are revalidated as regular files at activation so stale index entries cannot implicitly create a missing file or open a replacement directory. A still-tracked open Document remains a valid overlay.
- Ambiguous targets open a deterministic, typed-input-filterable picker sorted by Project-relative path.

Before navigation, the optional first-party Navigation History integration records the origin. Link actions consume the same semantic link and index resolution already presented by the renderer; they do not rescan source text.

## Regression evidence

Focused tests cover generic fragment hover/click routing, command opening to heading locations, Ctrl/Command modifier-click, generic semantic POI navigation/activation with code suppression, source-relative and root-relative missing-note creation, existing parent directories, query stripping, traversal rejection, stale deleted/replaced targets, typed ambiguity filtering, command registration, wrapped whitespace hit rejection through source mapping, and all existing semantic link/image behavior.
