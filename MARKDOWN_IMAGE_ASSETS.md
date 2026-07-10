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

Editors subscribe weakly to shared entries. Async completion notifies every attached consumer, and each Editor invalidates every source line using that asset. Metadata changes and detach/release unsubscribe deterministically.

Remote loading remains disabled by default. This slice preserves the existing explicit global opt-in; one-shot and trusted-Project policy UI remains a later Phase 5 slice.

## Dimensions

Decoded image identity is independent from reference dimensions. Each fragment computes its own display size. Width-only sizing preserves aspect ratio, and `WIDTHxHEIGHT` is now an aspect-preserving bounding box rather than a distortion request, matching the owner decision.

## Regression evidence

Runtime tests cover source-context isolation, sharing one decoded local source across different notes, missing-file retry, shared remote requests, multi-consumer completion, remote-disabled behavior, and aspect-preserving bounding boxes. UI tests cover policy rekeying, multi-line completion invalidation, local/Obsidian resolution, per-reference rendering, wrapping, and deterministic subscription cleanup through lifecycle tests.
