# Markdown Live Preview Prototype Baseline

Captured July 10, 2026 before the Markdown Live Preview rebuild.

This is a temporary comparison record for Phase 0 of `MARKDOWN_LIVE_EDITOR_PLAN.md`. The characterization tests named below intentionally describe prototype limitations. Later milestones must replace those assertions with tests for the required behavior rather than preserve the limitations.

## Product state

- The bundled default is now honestly opt-in: `config.markdown_live_editor = false` when not explicitly configured; a `USERDIR` or Project module can set it to `true` before first-party defaults load.
- The selected reveal-policy default is recorded as `construct`; the prototype does not yet implement it.
- The existing rendered `MarkdownView` remains available as Reading view.
- Remote image downloads remain disabled by default.

## Deterministic prototype gaps

`tests/lua/ui/markdown_live_preview_baseline.lua` demonstrates that the current product path:

1. does not attach or detach automatically after direct filename/syntax lifecycle changes;
2. has no `markdown-live-preview:open-link` command;
3. gives resolved, missing, and ambiguous Wikilinks the same presentation;
4. recomputes metrics for all 80 fixture lines after each ordinary caret move;
5. invokes the inline parser independently from source/x mapping and drawing paths (at least three parses for one unchanged line in the fixture);
6. keeps missing and remote-disabled image cache entries stale after the file appears or remote policy changes; and
7. sends an actually wrapped alias line through raw rendering instead of a provider-aware wrapped render plan.

`tests/lua/runtime/markdown_live_preview_baseline.lua` demonstrates that first use of the prototype vault index does not scan its owning Project: an existing note is reported missing until an explicit rebuild.

These are characterization seams only. The rebuild should migrate them to stable public behavior tests as each gap is fixed.

## Existing behavior retained for comparison

The pre-rebuild focused suites already cover:

- headings, emphasis, hidden-source mapping, drag-selection freezing, and raw code-block fallback;
- local images, attachment-folder lookup, image-row culling, image hover/click behavior, and the full-window image viewer;
- parser/link/image helper behavior; and
- manual vault-index rebuild, aliases, headings, block IDs, ambiguity, tracked Documents, and multiple Projects.

## Validation baseline

Commands were run from the repository root using the Meson-built Anvil and LuaJIT binaries.

- Lua syntax check for the Phase 0 Lua files: passed.
- `anvil:lua-runtime` full suite after adding the runtime characterization: 583 tests in 68 files; 581 passed, 2 skipped, 0 failed.
- `anvil:lua-ui` full suite: timed out at 180 seconds before reporting test results, after repeated SDL event-queue saturation warnings and `core/node.lua:562: attempt to index field 'b' (a nil value)`. This is recorded as a pre-existing full-suite harness/UI failure, not as a Markdown assertion failure.
- Focused `ui/markdown_live_editor.lua`: passed.
- Focused `runtime/markdown_vault_index.lua`: passed.
- Focused `runtime/markdown_images.lua`: passed.
- New focused runtime baseline characterization: passed.
- New focused UI baseline characterization: passed.

Do not treat the full UI timeout as approved permanent debt. Phase 8 still requires a complete full-suite run or an explicit owner decision if an unrelated failure remains.
