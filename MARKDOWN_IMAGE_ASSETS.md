# Markdown Image Asset Service

Implemented July 10, 2026 as the first Phase 5 slice in `MARKDOWN_LIVE_EDITOR_PLAN.md`.

## Context-aware identity

Image loading now uses a shared asset service instead of per-Editor URL-only entries.

- Existing local files are keyed by normalized resolved absolute path, so two references that resolve to the same file share one decoded source while retaining independent render sizes.
- Missing relative references include source-note and Project context, preventing identical relative text in different notes from poisoning one another.
- Remote assets include URL, cache root, and download-policy state; changing disabled/enabled policy rekeys immediately instead of leaving a stale disabled entry.

The service bounds retained assets to 256 least-recently-used entries when they are neither loading nor actively subscribed.

## Retry and publication

Entries carry a link-index retry generation and local file metadata. Missing/error assets retry after relevant Project index generations; newly appearing files naturally move from a context-missing key to their resolved absolute-file key. Changed local files are decoded again. Concurrent remote requests for the same context share one download.

Editors subscribe weakly to shared entries. Async completion notifies every attached consumer, and each Editor invalidates every source line using that asset. Metadata changes and detach/release unsubscribe deterministically. Non-ready references render explicit, alt-aware `loading image`, `remote image blocked`, or `image unavailable` states with distinct first-party style keys instead of a single ambiguous placeholder.

Remote loading remains disabled by default. `markdown-live-preview:load-remote-image` grants the current Editor a one-asset permission for the remote image at its caret. `markdown-live-preview:trust-project-remote-images` and `markdown-live-preview:untrust-project-remote-images` manage an optional normalized-Project-root trust policy and invalidate every attached Project view through the shared index generation. The global first-party switch remains available for users who deliberately want all remote images. One-shot permissions are view-local and do not silently promote Project trust.

## Dimensions

Decoded image identity is independent from reference dimensions. Each fragment computes its own display size. Wikilink `|WIDTH` / `|WIDTHxHEIGHT`, external `![WIDTH](url)`, and external `![alt|WIDTHxHEIGHT](url)` forms are normalized semantically. A wholly numeric external label is size syntax and does not become alt text; the `alt|size` form preserves explicit alt text. Width-only sizing preserves aspect ratio, and `WIDTHxHEIGHT` is an aspect-preserving bounding box rather than a distortion request, matching the owner decision.

## Regression evidence

Runtime tests cover source-context isolation, sharing one decoded local source across different notes, missing-file retry, shared remote requests, multi-consumer completion, remote-disabled behavior, and aspect-preserving bounding boxes. UI tests cover policy rekeying, view-local one-shot permission, shared Project trust/revocation, multi-line completion invalidation, local/Obsidian resolution, per-reference rendering, wrapping, and deterministic subscription cleanup through lifecycle tests.
