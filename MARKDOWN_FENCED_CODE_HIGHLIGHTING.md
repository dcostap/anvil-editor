# Markdown Live Preview Fenced-Code Highlighting Plan

Status: implemented July 27, 2026.

## Goal

Markdown Live Preview should syntax-highlight fenced code by reusing Anvil's loaded syntax definitions, native/Lua tokenizer, syntax colors, and syntax fonts. The language identifier in a fence info string should select the same base syntax used when editing a file of that language in a Standard Editor.

For example, these fences should resolve through one shared language-resolution path rather than through Markdown-only pattern tables:

````markdown
```js
const value = 1
```

```python title="example"
def greet(name):
    return f"Hello, {name}"
```
````

The implementation must remain responsive for large Markdown Documents, large individual fences, many fences, multiline language constructs, and edits near the beginning of a fence.

## User-visible contract

1. A recognized fenced-code language identifier selects a loaded Anvil syntax.
2. The code body uses the selected syntax's token types, `style.syntax` colors, and `style.syntax_fonts`, matching Standard Editor base highlighting.
3. Common aliases such as `js`, `javascript`, `ts`, `typescript`, `py`, `python`, `c++`, and `cpp` resolve consistently everywhere Markdown is rendered.
4. Language identifiers are matched case-insensitively after trimming and normalization.
5. `language-` and `lang-` prefixes are accepted.
6. Only the first info-string word selects the language. Remaining metadata does not become code.
7. An unknown, absent, or empty language identifier produces plain code text without errors or misleading partial highlighting.
8. Fenced code remains source-oriented and directly editable. Markdown constructs inside it are never live-rendered.
9. Indented code remains plain unless a future semantic feature gives it an explicit language; this change must not guess from surrounding prose or the Document filename.
10. Source Mode retains its existing Markdown syntax-highlighting behavior. This feature changes Markdown Live Preview and the shared resolver without regressing Source Mode.

## Meaning of highlighting parity

The first implementation targets **base syntax-highlighting parity**:

- the same loaded `core.syntax` definitions;
- the same native tokenizer, with the Lua tokenizer remaining a supported fallback;
- the same token type names;
- the same syntax colors and syntax-specific fonts; and
- the same multiline tokenizer semantics used by a Standard Editor's fallback highlighter.

LSP semantic tokens, diagnostics, completion, references, and other language intelligence are not part of fenced-code highlighting. A Markdown fence is not a standalone project file, and creating fake files or language-server sessions would be expensive and semantically misleading.

Tree-sitter highlighting currently operates through Document-bound language-intelligence providers. It should not be invoked by constructing hidden Documents per fence. A later provider API may add explicit embedded-source support, but the initial feature must not block on that refactor. For languages whose Standard Editor currently uses Tree-sitter, fence highlighting will use the same registered fallback syntax/tokenizer and style schema rather than starting a second parser per fence.

## Current behavior and problem

### Markdown Live Preview

`data/core/markdown/live_render.lua` currently handles fenced content in `fenced_code_content_render_line`. It asks the Markdown Document's `doc.highlighter` for tokens and copies those token types into rendered fragments.

That path has several limitations:

- it highlights through the Markdown syntax's current subsyntax state rather than resolving the semantic fence's info string directly;
- `data/plugins/language_md.lua` contains a fixed list of exact fence openers;
- aliases such as `js`, `ts`, and `py` are absent even when their corresponding syntax is loaded;
- the hardcoded patterns are case-sensitive and do not form a general plugin-facing language registry;
- requesting a body line before the Markdown highlighter has processed its opening delimiter can temporarily return Markdown/plain tokens; and
- Live Preview has no focused regression test proving language selection and token colors.

### Rendered MarkdownView

`data/core/markdownview.lua` already has a more capable fence resolver and tokenizes code using the selected syntax. Its alias table and resolver are local to that view, however, so Markdown Live Preview cannot reuse them. Its existing fenced-code test covers MarkdownView, not the editable Live Preview path.

### Available semantic data

The Markdown block query already captures `(info_string) @content.code_info` in `data/core/markdown/queries.lua`. `core.markdown.model` attaches that range to the containing `code_fenced` node as `node.attributes.code_info` when the bounded capture query includes the opening line. No parser change or second Markdown parser is needed.

A body-line query is not sufficient by itself: `nodes_for_lines(body_line, body_line)` can return the enclosing `code_fenced` block capture without the non-overlapping opening-line `info_string` capture. Add a bounded model/service lookup that completes fenced-block metadata from `node.source.line1`, then cache that complete metadata by semantic node ID. This lookup must not scan the Document or depend on the opening row being visible.

## Architectural decision

Introduce two reusable layers:

1. a central syntax-language resolver in `core.syntax`; and
2. a shared, Document-scoped fenced-code token cache in a new Markdown module.

Markdown Live Preview will query the fenced-code cache instead of relying on the Markdown Document highlighter's subsyntax state. MarkdownView will migrate to the central resolver so aliases and loaded-language discovery have one owner.

The fenced-code cache will store token types and text, not resolved theme colors or font objects. Rendering will resolve current `style.syntax` and `style.syntax_fonts` values, allowing theme changes to use the existing render invalidation path without retokenizing code.

## Central language resolution

### Proposed API

Extend `data/core/syntax.lua` with an API shaped like:

```lua
local resolved, metadata = syntax.resolve_language(info_or_id, {
  source = "markdown-fence",
})
```

`resolved` is a loaded syntax table or `nil`. `metadata` should contain stable diagnostic information such as:

```lua
{
  requested = "js",
  normalized = "js",
  canonical_id = "javascript",
  reason = "alias" -- alias, extension, syntax-name, missing, empty
}
```

Callers choose their fallback. Markdown callers use `syntax.plain_text_syntax` when `resolved` is nil.

### Resolution order

1. Trim the info string.
2. Extract its first non-whitespace token.
3. Remove an optional `language-` or `lang-` prefix.
4. Lowercase and normalize the identifier without changing meaningful language punctuation such as `c++` and `c#` before alias lookup.
5. Resolve a registered alias to a canonical identifier.
6. Find a loaded syntax through a synthetic extension/path match, without converting failure into `plain_text_syntax` too early.
7. Fall back to a normalized comparison against `syntax.items[*].name`.
8. Return `nil` with `reason = "missing"` when no loaded syntax matches.

The resolver must not cache misses indefinitely because plugins can register syntaxes later. Add a monotonically increasing syntax-registry generation changed by `syntax.add` and alias registration. Resolver cache entries include that generation.

Generation checks alone are insufficient for already-cached render output. Add a lightweight syntax-registry listener API. Fenced-code services and live `MarkdownView` instances subscribe while active, re-resolve affected missing/resolved languages after a registry change, invalidate only changed consumers, and unsubscribe on disposal. A syntax or alias registered after a fence first rendered plain must cause that fence to become eligible for highlighting without requiring a text edit or semantic republication.

### Alias ownership

Move the useful aliases from `data/core/markdownview.lua` into the shared syntax-resolution layer. Provide a small registration API so first- or third-party language plugins can add aliases without editing Markdown code:

```lua
syntax.add_language_alias("js", "javascript")
```

Alias registration should reject an empty alias, normalize both sides, increment the registry generation, and log conflicting re-registration quietly. One deterministic precedence rule must be documented and tested; later registrations should not silently hijack an existing alias unless an explicit replacement option is passed.

Do not require immediate edits to every vendored language plugin. Existing syntax file patterns and normalized syntax names provide broad fallback coverage, while the central alias set covers common ecosystem identifiers.

### `syntax.get` compatibility

Keep `syntax.get(filename, header)` behavior unchanged for existing callers. If necessary, add an internal/public `syntax.find` variant that returns `nil` instead of `plain_text_syntax`; do not infer resolution failure by comparing arbitrary syntax tables after the fact.

## Fenced-code highlighter service

### Module and ownership

Add `data/core/markdown/fence_highlight.lua`.

The module owns one weakly Document-keyed service instance per Markdown Document. Multiple Markdown Live Preview Editors showing the same Document share tokenization results. Each attached view acquires the service with a listener identity and releases it on detach; the service must not retain a closed Document or view.

The service registers one uniquely named Document metadata listener and handles `event.kind == "close"` directly. Closing a Document increments the service generation, cancels queued/resumable work, removes syntax/tokenizer listeners, clears token/checkpoint storage, drops callbacks, and marks the service closed before `Doc:on_close` discards metadata listeners. The cooperative worker holds only a weak Document reference and checks the closed/generation state before each batch and publication. Detaching the last view stops queued work and releases heavy caches even if the weak service shell remains reachable temporarily.

Suggested public seam:

```lua
local service = fence_highlight.get(doc)
service:reconcile(model)
service:on_text_transaction(transaction)
service:request(node, line, priority)
service:line_tokens(node, line)
service:peek_line_tokens(node, line)
service:add_listener(id, callback)
service:remove_listener(id)
service:close(reason)
service:get_diagnostics()
```

Exact names may change during implementation, but rendering must consume the service through a narrow public API rather than inspecting private cache tables.

### Block identity

Use the semantic `code_fenced` node ID as the primary cache identity. Node IDs are edit-mapped by the semantic model when a construct survives an edit. Also retain a defensive fingerprint:

- normalized language identifier;
- resolved syntax identity;
- body start/end relative to the node;
- opening delimiter kind/length; and
- relevant source text/revision metadata.

If an ID is reused with incompatible structure, discard that block cache rather than risking stale tokens.

Line entries should be relative to the fence body, not keyed only by absolute Document line. An unchanged fence shifted by edits before it can then retain its cache.

### Body boundaries

Derive the opening/info and closing delimiter rows from semantic marker/content ranges and the semantically confirmed fenced block. If a body-line node lacks `attributes.code_info`, perform one bounded opening-line semantic lookup and match the same fenced node by stable ID plus source range. Cache the resulting complete metadata. Preserve the existing conservative handling of unclosed fences and malformed captures.

Do not highlight:

- opening or closing delimiter text;
- the info string;
- fenced-looking text inside semantic comments; or
- a range whose semantic capture exceeds safety/query bounds.

When exact body boundaries cannot be established, return plain/raw code presentation for the affected block.

### Tokenization state

Each body-line entry mirrors the stable part of `core.doc.highlighter` state:

```lua
{
  text = "...\n",
  init_state = previous_state,
  tokens = { "keyword", "local", ... },
  state = resulting_state,
  complete = true,
}
```

Tokenize using:

```lua
tokenizer.tokenize(resolved_syntax, line_text, previous_state, resume)
```

The opening fence does not become part of the selected language's tokenizer input. The first body line begins with a nil/empty state. Each subsequent line receives the prior body line's resulting state. This preserves multiline comments, strings, heredocs, and nested subsyntax states supported by the selected syntax.

Keep token arrays in the standard `{ type, text, ... }` representation and consume them with `tokenizer.each_token`. Validate that concatenated token text exactly equals the current source line before publishing it. On mismatch, drop the result and use plain code for that line.

### Tokenizer backend identity

Fence cache validity includes the active tokenizer backend and a tokenizer-backend generation. Extend `core.tokenizer` with a read-only generation/identity API incremented when `set_use_native` changes the active backend and when a global tokenizer-cache reset invalidates imported syntax state.

The fenced-code service listens for or checks that generation before every request/publication. A backend switch cancels queued work, discards tokenizer states and token arrays, and invalidates ready fenced lines. The Native Tokenizer setting must invalidate fence services alongside Standard Editor highlighters; programmatic backend switches must receive the same protection rather than relying only on the Settings view's current `doc.highlighter:soft_reset()` loop.

### Cooperative scheduling

No unbounded tokenization may happen from drawing, hit testing, wrapping, or coordinate mapping.

`line_tokens` is a cache lookup. If a requested line is unavailable, it queues work and returns a pending/plain result immediately. Work runs through a cooperative `core.add_thread` owned by the service because syntax definitions and tokenizer caches are currently Lua/UI-runtime objects, not immutable worker payloads.

The scheduler should:

1. prioritize requested visible lines and their nearest missing predecessor state;
2. tokenize sequentially from the closest valid checkpoint;
3. use the tokenizer's existing resume mechanism for very long lines;
4. respect Anvil's cooperative time budget and yield between bounded batches;
5. check Document/service generation before and after each batch;
6. cancel superseded block work when the language or semantic identity changes;
7. coalesce ready-line notifications into contiguous ranges; and
8. request one redraw after a batch rather than one redraw per tokenized line.

A line deep inside a large fence cannot be highlighted correctly until the tokenizer state leading to it is known. The correct fallback during that interval is plain code, not speculative state and not a synchronous scan from the fence start.

After a line has been reached, retain sparse complete tokenizer-state checkpoints separately from render token arrays. Evicting offscreen token arrays must not force every repeated deep-line request to replay from the opening fence. A request resumes from the nearest valid preceding checkpoint and reconstructs only the missing interval. Checkpoints after an edit are invalidated by the same state-dependency rules as tokens and remain subject to a separate bounded per-block/global budget.

### Visibility and demand

Do not eagerly tokenize every fenced block after every semantic publication.

- Materialize metadata cheaply when a semantic fence is encountered.
- Queue code lines when Live Preview requests their render plans.
- Allow a small viewport-adjacent prefetch window through the same scheduler.
- Prioritize the active/visible fence over offscreen work.
- Do not scan a Document merely to discover all fences; use semantic line/node queries already performed by Live Preview.

If a block is small and visible, sequential scheduling should make the complete block appear highlighted quickly. A Document containing thousands of untouched/offscreen fences should incur metadata and semantic-model cost, not tokenizer cost for every body.

## Incremental edits and cache convergence

### Immediate transaction invalidation

Publication-time reconciliation is too late to protect multiline tokenizer state. Register one Document-level text-transaction handler for active fenced-code services (using the existing batch-aware transaction seam) and process changed ranges immediately after text is applied.

For every cached fence intersecting an ordinary body edit:

1. map the first affected old/new body line conservatively;
2. retain only the known-safe prefix before that line;
3. mark the affected suffix token-state-unsafe;
4. increment line/block generations and notify attached views immediately;
5. cancel queued work based on the superseded source generation; and
6. queue replacement work only after current source and sufficient fence metadata are available.

If delimiter/info text, line structure, or block membership may have changed, mark the complete affected cached fence structurally unsafe until semantic publication reconciles it. Unchanged line text is not evidence that its multiline tokenizer state is still valid.

This immediate path must run once per Document transaction, not once per attached view.

### Ordinary body edit

When an edit changes a body line without changing the fence or language:

1. retain valid entries before the first changed relative body line;
2. invalidate the changed line and following state-dependent entries;
3. retokenize forward;
4. compare each new line's text, initial state, token output, and resulting state with an edit-mapped old entry; and
5. once state and source converge, reuse the unaffected suffix rather than retokenizing to the closing fence.

The implementation may stop at state/text convergence even when token array identity differs, provided the newly published line is retained and the untouched suffix is known to have the same initial state.

### Language/info edit

Changing the normalized language identifier or resolved syntax invalidates the complete body cache. Changing unrelated trailing info-string metadata does not retokenize when the normalized language and syntax identity are unchanged.

### Structural edit

Opening/closing delimiter edits, fence splitting/merging, changing backticks to tildes, or turning a fence into ordinary text are structural changes. Reconcile against the next ready semantic publication. Until then, retain only lines the semantic model explicitly allows from the previous publication; otherwise use existing raw/plain fallback.

Removed blocks cancel queued work and release token arrays. New blocks start cold.

### Full-snapshot reload

A `full_snapshot` transaction is a hard revision boundary, not an incremental
structural edit. Discard every cached fence descriptor, token/checkpoint entry,
queued request, and active worker generation immediately. Do not map old fence
bounds onto the replacement source and never widen an uncertain block to the
whole Document.

Until a ready semantic model for the loaded Document revision is reconciled,
the fence service reports no authoritative block membership and rejects token
requests. Live Preview uses its current-source provisional topology during this
interval. Structurally unsafe, stale-revision, and stale-service-generation
blocks must never satisfy membership queries. Worker publications retain the
same Document/service generation checks so pre-reload work cannot repopulate
the reset cache.

### Edits before a fence

If semantic identity survives and body text is unchanged, shifting a fence by inserting/removing lines before it should update absolute coordinates while retaining relative line entries and tokenizer states.

### Pending safety

Never display tokens whose concatenated text differs from the current Document line. Never use a stale language selection after an info-string edit. Plain code is the safe pending state.

The plain pending state also applies to unchanged-text suffix lines invalidated by a preceding multiline-state edit. Source equality alone does not make those lines safe.

### Optimistic-render interaction

`live_render.lua` currently considers optimistic cached rows before its semantic fence path. Fenced-code safety must take precedence:

- immediately discard optimistic rows for a cached/semantically known fence suffix invalidated by a transaction;
- consult the fenced-code service's unsafe/pending range before returning an optimistic render;
- render source-faithful plain code with the existing code inset/background while token state is unavailable; and
- use raw fallback when structural edits make even fence membership uncertain.

An optimistic render captured before an edit must never republish old token types for a line whose tokenizer state depends on that edit. Add tests that inspect rendering before the replacement Markdown semantic publication completes.

## Render integration

Replace the `doc.highlighter:each_render_token(line)` dependency inside `fenced_code_content_render_line` with fenced-code service tokens.

For each token fragment:

- preserve exact source columns;
- resolve `style.syntax[token_type]` with the normal-color fallback;
- use `style.syntax_fonts[token_type]` when present;
- retain the existing code inset, background, selection, caret, tab, wrapping, and source mapping behavior; and
- preserve ordinary code text even when highlighting is pending or unavailable.

The service publishes a per-line token generation. Include that generation in `provider:line_generation(view, line)` for fenced body lines, or explicitly invalidate the provider's line cache when a line becomes ready. Prefer both a generation check and targeted invalidation as a correctness guard.

When a token type changes font, invalidate both:

- the line render cache; and
- that line's visual metrics/wrapping.

Batch adjacent lines into one invalidation range. Do not invalidate prose lines or unrelated fences.

Invalidation alone is not enough: `compute_line_height` currently returns the ordinary/raw fallback for fenced blocks. Add a fenced-body metric path that computes row height from the maximum ready token font height using the same line-height rule as Document rendering. Pending/plain lines use the code/base font height. The metric path uses `peek_line_tokens` and must never queue tokenization while a full-Document metric index is being built. When ready token fonts change the required height, targeted publication invalidates that row's metrics and wrapping so larger syntax fonts cannot be clipped.

Fence delimiter reveal behavior remains selection-dependent and separate from token generation. Moving the caret into a fence must not retokenize its body.

## Semantic-model integration

The service should subscribe once per shared Markdown model or be reconciled once per model publication through a shared generation guard. It must not perform duplicate reconciliation once for every view. Do not rely on `Model:close` to notify the service: that method currently clears listeners. The Document metadata close event is the authoritative shutdown signal.

On a ready publication:

1. consume the model generation and changed ranges;
2. reconcile only cached/active fences intersecting those ranges, plus structurally affected neighbors;
3. update shifted source coordinates for surviving node IDs;
4. cancel entries for removed/incompatible nodes; and
5. notify attached views only for code lines whose published token state changed.

On pending/error/detached/closed states, follow the semantic model's existing conservative render policy and cancel work that can no longer publish safely. Immediate transaction-invalidated suffixes remain unsafe even when the model allows an unchanged line from its previous publication.

Syntax-registry and tokenizer-backend generations are independent of the Markdown semantic generation. Changes to either must re-resolve/invalidate cached fences without waiting for a semantic publication.

## Cache bounds and memory

Token caching should be lazy and bounded without introducing user-facing configuration prematurely.

Track at least:

- cached block count;
- cached line count;
- cached source bytes;
- cached token-pair count;
- queued blocks/lines;
- lines tokenized and reused;
- convergence stops;
- cancellations; and
- evictions.

Track checkpoint count/bytes and replayed lines separately from render-token cache entries. This makes repeated deep-fence replay and checkpoint pressure visible rather than hiding them inside generic misses.

Establish default cache limits after measuring representative Documents rather than encoding an arbitrary preference in tests. Eviction policy should favor:

1. active/visible blocks;
2. recently requested blocks; and
3. inexpensive retention of metadata while dropping token arrays for least-recently-used offscreen blocks.

Within a retained block, evict render token arrays before sparse tokenizer-state checkpoints. Bound checkpoints separately so memory remains finite. If a checkpoint is evicted, correctness is unchanged; the scheduler may replay from an earlier checkpoint, with that replay reported in diagnostics.

Eviction must never affect correctness. An evicted block simply returns to pending/plain presentation and can be rebuilt on demand.

Do not test exact cache-size constants. Test that the configured/internal budget is honored and that eviction preserves visible behavior.

## Diagnostics and logging

Add quiet diagnostics for:

- requested and normalized fence language;
- resolution source and missing-language fallback;
- syntax-registry generation changes;
- service creation/disposal;
- block language changes;
- work cancellation and stale publication rejection;
- token/source length mismatches;
- cache eviction; and
- unusually large fences or repeatedly resumed lines.

Use `core.log_quiet(...)`; unknown languages are normal Markdown content and must not produce visible warnings.

Expose counters through `service:get_diagnostics()` for deterministic tests and optional future performance HUD integration. Timing values may be recorded for manual measurement but must not be correctness assertions.

## Migration and cleanup

### `core.syntax`

- Add nil-preserving syntax lookup if needed.
- Add shared language normalization/resolution.
- Add alias registration and syntax-registry generation.
- Add registry listeners so active consumers can invalidate cached misses/layouts.
- Add focused API documentation/comments.

### `core.tokenizer`

- Expose backend identity/generation.
- Invalidate listeners/caches when backend state changes.
- Preserve existing `set_use_native` and native-cache-clearing behavior for callers.

### `core.markdown.model`

- Add or expose a bounded way to complete fenced-node opening/info metadata when a body-line query omitted the opening capture.
- Keep this as indexed semantic retrieval; do not add source scanning or another parser.

### `core.markdownview`

- Remove its private `CODE_FENCE_ALIASES`, normalization, and resolver cache.
- Call the shared resolver.
- Subscribe to syntax-registry changes while alive so a cached layout can adopt newly loaded syntax.
- Preserve existing rendered MarkdownView behavior and tests.

### `core.markdown.live_render`

- Replace Markdown Document token consumption for fenced body lines.
- Bind/unbind the shared fenced-code service with view lifecycle.
- Integrate immediate text transactions, optimistic-render safety, semantic publication, targeted invalidation, and line generations.
- Compute fenced-body metrics from ready syntax fonts without scheduling work from metric queries.

### `plugins.language_md`

Do not remove the existing code-fence subsyntax patterns in the same slice unless Source Mode has an equivalent replacement. They remain a Source Mode/ordinary Markdown-highlighter compatibility path, but Markdown Live Preview must no longer depend on them.

A later cleanup may generate Source Mode subsyntax patterns from the shared registry or add dynamic subsyntax selection to the tokenizer. That is outside this feature unless separately regression-tested.

### No compatibility aliases in Markdown modules

Once MarkdownView and Live Preview use the central resolver, delete their duplicate private alias/resolution code. Do not leave deprecated Markdown-only resolver wrappers.

## Test strategy

Use red-green vertical slices. The stable seams are `core.syntax` resolution, the fenced-code service's public token API/diagnostics, and observable Markdown Live Preview render fragments.

### Slice 1: shared resolver

Add focused runtime tests, likely in `tests/lua/runtime/syntax_hierarchy.lua` or a dedicated `syntax_language_resolution.lua`.

Red cases:

- `js`, `ts`, and `py` do not currently resolve through a shared API;
- case/prefix normalization is absent;
- unknown identifiers cannot be distinguished cleanly from plain-text fallback; and
- MarkdownView owns duplicate behavior.

Passing behavior:

- common aliases resolve to the expected loaded syntax;
- canonical names and extension-like IDs resolve;
- `language-lua`/`lang-lua` resolve;
- trailing info metadata is ignored for language selection;
- unknown and empty identifiers return nil plus a reason;
- alias conflicts follow the documented precedence; and
- syntax-registry generation invalidates resolver misses.

Also verify an active MarkdownView and Live Preview fence rendered before a relevant syntax/alias registration are invalidated and re-resolved after registration. Resolver-only cache tests are not sufficient.

Do not assert every alias in one broad table merely to freeze a preference list. Cover representative punctuation, abbreviation, canonical-name, and missing cases.

### Slice 2: correct Live Preview highlighting

Add tests to `tests/lua/ui/markdown_live_editor.lua` that create a real Markdown Document and DocView, wait for the semantic publication and fence token publication, then inspect public render fragments.

Red case first: a ```` ```js ```` fence currently renders `const` as ordinary Markdown/plain text.

Passing behavior:

- `js` highlights JavaScript using syntax colors;
- `lua` highlights a keyword, operator, and number correctly;
- ordinary identifiers retain normal syntax style;
- alias and canonical forms produce equivalent token types;
- a visible body line resolves its language when the opening fence is offscreen and was not previously rendered;
- unknown language produces plain code;
- delimiter/info rows retain existing hidden/revealed behavior;
- Markdown markers inside code remain raw code text; and
- syntax-specific fonts are honored without breaking source-column mapping.

Compare fragment colors/fonts to `style.syntax` and `style.syntax_fonts` references, not literal theme RGBA values or exact keyboard bindings.

### Slice 3: multiline state and edits

Add behavior tests for:

- multiline comments/strings across body lines;
- two adjacent fences with different languages and independent state;
- changing the info identifier retokenizes the complete body;
- changing trailing info metadata does not retokenize the body;
- editing a multiline opener retokenizes until state convergence;
- rendering before replacement semantic publication never exposes a stale multiline suffix or optimistic token row;
- an edit before a fence retains its shifted cache;
- splitting/removing/closing a fence cancels stale work;
- an unterminated fence remains safe and editable;
- closing a Document with queued/resumable work cancels it without later publication; and
- detaching the final view releases heavy service caches.

Assert observable fragments and service diagnostics. Do not assert private helper calls or incidental coroutine batch sizes.

### Slice 4: scheduling and cache behavior

Use deterministic counters, not wall-clock thresholds.

Tests should prove:

- drawing/mapping a warm line performs no new tokenization;
- requesting an unresolved deep line returns promptly with a pending/plain result and queues work;
- cooperative processing eventually publishes correct tokens;
- a long line can resume across yields;
- only demanded/visible fences are tokenized;
- one body edit retains the unchanged prefix and can reuse a converged suffix;
- evicted deep-line token arrays can resume from bounded sparse checkpoints rather than replaying from the fence start;
- superseded language work cannot publish; and
- two views of one Document share the same token work while both receive targeted invalidation.

Add a warm-cache backend-switch case: switching native/Lua tokenizers invalidates old states/tokens, republishes through the selected backend, and restores the original backend even if the assertion fails. Add a syntax-font metric case with a deliberately taller token font and assert the fenced row is not clipped; do not assert a cosmetic pixel constant.

Add or extend `tests/lua/benchmarks/markdown_live_render.lua` for repeatable measurements, but keep timing output informational.

### Backend coverage

Run core fence-state behavior once with the configured native tokenizer. Add a narrowly scoped parity case that temporarily selects the Lua tokenizer and restores the previous setting even on failure. Existing tokenizer suites remain responsible for broad native/Lua equivalence.

## Performance measurement scenarios

Measure before and after implementation using diagnostics and the existing benchmark harness:

1. **Typical note:** 20 fences × 20 lines, mixed loaded languages.
2. **Many fences:** 2,000 small fences with only a handful visible.
3. **Large fence:** one 100,000-line fence opened near its beginning and near its end.
4. **Long line:** one code line large enough to trigger tokenizer resume.
5. **Stateful edit:** edit the start of a multiline comment near the top of a 10,000-line fence.
6. **Convergent edit:** change an ordinary identifier in the middle of a large fence.
7. **Language switch:** change `js` to `python` on a large visible fence.
8. **Split views:** two Editors showing the same Markdown Document and fence.
9. **Theme change:** switch themes after warming tokens and confirm no retokenization.
10. **Alias miss then plugin load:** resolve a previously missing identifier after syntax-registry generation changes.
11. **Checkpoint pressure:** repeatedly request a deep line after render-token eviction and measure checkpoint replay distance.
12. **Backend switch:** warm fences, switch native/Lua tokenizer backends, and verify bounded invalidation/rebuild.
13. **Close during work:** close the Document while a long/deep request is queued and verify cancellation with no later publication.

Record:

- synchronous render-path tokenization calls (target: zero);
- lines and bytes tokenized;
- lines reused after edits;
- yields/resumes;
- cache hits/misses/evictions;
- checkpoints retained/evicted and replayed lines;
- targeted render/metric invalidation line counts; and
- peak cached lines/bytes/token pairs.

Performance acceptance is behavioral rather than tied to one machine's milliseconds:

- no whole-Document eager fence tokenization;
- no unbounded synchronous scan to a requested line;
- warm rendering is cache-only;
- ordinary convergent edits do not retokenize the remaining fence;
- offscreen fences are not tokenized merely because the semantic model published;
- stale/superseded/closed-Document work is cancellable and cannot invalidate unrelated lines;
- repeated deep requests can reuse bounded checkpoints after token-array eviction; and
- registry/backend changes invalidate affected consumers without a text edit.

## Implementation sequence

1. Add resolver tests and confirm they fail because no shared resolver exists.
2. Implement `core.syntax` language resolution and migrate MarkdownView; run focused runtime and MarkdownView tests.
3. Add a Live Preview `js` regression and confirm it renders plain before the new service.
4. Implement the smallest fenced-code service path for one fully available small block.
5. Integrate render fragments and confirm the `js` regression passes.
6. Add multiline state tests, then implement sequential state caching.
7. Add immediate pending/optimistic edit tests, then bind the Document transaction seam before implementing publication reconciliation and convergence.
8. Add edit/language-switch tests, then implement semantic reconciliation and state convergence.
9. Add offscreen-opener and pending/deep-line tests, then add bounded metadata completion, cooperative scheduling, and sparse checkpoints.
10. Add shared-view, close-during-work, registry/backend-switch, and targeted-invalidation tests, then complete lifecycle/listener integration.
11. Add syntax-font metric and deterministic cache-bound tests, diagnostics, and benchmark scenarios.
12. Run Lua syntax validation for every changed Lua file.
13. Run only the focused runtime/UI targets and benchmark commands relevant to this medium-sized feature.

## Expected files

Likely changed or added:

- `data/core/syntax.lua`
- `data/core/tokenizer.lua`
- `data/core/markdown/model.lua`
- `data/core/markdown/fence_highlight.lua` (new)
- `data/core/markdown/live_render.lua`
- `data/core/markdownview.lua`
- `tests/lua/runtime/syntax_language_resolution.lua` (new, or focused additions to `syntax_hierarchy.lua`)
- `tests/lua/runtime/markdown_fence_highlight.lua` (new if service behavior is cleaner outside UI)
- `tests/lua/runtime/markdown_model.lua` (if the bounded metadata API is added there)
- `tests/lua/ui/markdown_live_editor.lua`
- `tests/lua/ui/markdownview.lua`
- `tests/lua/benchmarks/markdown_live_render.lua`
- this plan/status document

`data/plugins/language_md.lua` should change only if required for shared resolver registration or a separately tested Source Mode improvement.

No native or build-system changes should be necessary for the base implementation. `core.tokenizer` changes are Lua-side backend generation/lifecycle plumbing, not changes to the native tokenizer implementation.

## Focused validation commands

Syntax validation after final filenames are known:

```sh
./build-windows-x86_64/subprojects/luajit/src/luajit.exe check-lua-syntax.lua \
  data/core/syntax.lua \
  data/core/tokenizer.lua \
  data/core/markdown/model.lua \
  data/core/markdown/fence_highlight.lua \
  data/core/markdown/live_render.lua \
  data/core/markdownview.lua \
  tests/lua/runtime/syntax_language_resolution.lua \
  tests/lua/runtime/markdown_fence_highlight.lua \
  tests/lua/runtime/markdown_model.lua \
  tests/lua/ui/markdown_live_editor.lua \
  tests/lua/ui/markdownview.lua \
  tests/lua/benchmarks/markdown_live_render.lua
```

The list above is illustrative because resolver/service tests may be added to existing files instead of the proposed new files. Before validation, replace it with the actual changed Lua file list; do not invoke the checker on optional files that were not created. Include any changed benchmark Lua file.

Focused tests, adjusted to the final test filenames:

```sh
PATH=/c/msys64/mingw64/bin:$PATH /c/msys64/mingw64/bin/meson.exe test \
  -C build-windows-x86_64 anvil:lua-runtime \
  --test-args runtime/syntax_language_resolution.lua \
  --print-errorlogs

PATH=/c/msys64/mingw64/bin:$PATH /c/msys64/mingw64/bin/meson.exe test \
  -C build-windows-x86_64 anvil:lua-runtime \
  --test-args runtime/markdown_fence_highlight.lua \
  --print-errorlogs

PATH=/c/msys64/mingw64/bin:$PATH /c/msys64/mingw64/bin/meson.exe test \
  -C build-windows-x86_64 anvil:lua-ui \
  --test-args ui/markdown_live_editor.lua \
  --print-errorlogs

PATH=/c/msys64/mingw64/bin:$PATH /c/msys64/mingw64/bin/meson.exe test \
  -C build-windows-x86_64 anvil:lua-ui \
  --test-args ui/markdownview.lua \
  --print-errorlogs
```

Do not run the full test suite unless implementation expands into shared native tokenizer, Tree-sitter, or broad Document lifecycle changes.

Lua-only changes are junctioned into the development portable app, so no portable rebuild is required. Reload/restart Anvil after implementation to exercise the feature interactively.

## Completion criteria

The feature is complete when:

- Markdown Live Preview resolves fence languages through `core.syntax` rather than Markdown-specific opener patterns;
- common aliases and loaded syntax names work consistently in Live Preview and MarkdownView;
- body lines use correct Standard Editor base syntax tokens, colors, and fonts;
- multiline tokenizer state remains correct across edits;
- unknown/pending languages safely render plain code;
- body lines resolve complete fence metadata even when their opener is offscreen;
- pending transactions immediately suppress stale multiline and optimistic token state;
- rendering and coordinate mapping perform cache lookups rather than unbounded tokenization;
- edits invalidate only the affected fence suffix until state convergence;
- offscreen fences are lazy, cache memory is bounded, and sparse checkpoints bound repeated deep-line replay;
- multiple views share Document-scoped token work;
- Document close/final-detach lifecycle cancellation prevents stale publication and retention;
- syntax-registry and tokenizer-backend changes invalidate warm consumers without requiring text edits;
- ready syntax fonts contribute to fenced row metrics without scheduling tokenization from metric scans;
- focused red-green runtime/UI tests pass under the configured tokenizer, with narrow Lua-backend coverage; and
- benchmark diagnostics show no eager whole-Document fence tokenization or broad unrelated render invalidation.
