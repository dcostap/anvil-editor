# LSP Integration Plan

## Purpose

Add Language Server Protocol support to Anvil as a first-party semantic language-intelligence layer. LSP should build on the Tree-sitter foundation that now exists, not replace it wholesale.

Tree-sitter remains the fast syntactic/current-document fallback. LSP adds semantic project-aware features such as diagnostics, semantic document symbols, go-to-definition/references, completion, and later semantic tokens.

The target experience is:

```text
Open/edit code -> Tree-sitter provides immediate local syntax/structure -> LSP starts in background -> semantic features appear when ready.
```

Not:

```text
Open/edit code -> editor blocks waiting for server startup/indexing.
```

## Current architecture to build on

The Tree-sitter integration is complete through the planned syntactic feature set:

- async native Tree-sitter service
- C/C++ syntax highlighting
- `outline.scm` document outline
- syntax-node selection expansion/shrink
- syntactic symbol navigation
- local current-document definition/reference fallback
- `core.language_intelligence` provider abstraction

Relevant current modules:

```text
data/core/language_intelligence.lua

data/core/treesitter/init.lua
data/core/treesitter/highlight.lua
data/core/treesitter/outline.lua
data/core/treesitter/selection.lua
data/core/treesitter/navigation.lua
data/core/treesitter/locals.lua

data/core/doc/highlighter.lua
```

Current provider model:

- Providers register with `core.language_intelligence.register_provider`.
- Higher `priority` providers are tried first.
- Tree-sitter registers as:

```lua
id = "treesitter"
priority = 10
kind = "syntactic-local-fallback"
```

LSP should register with a higher priority for semantic features it actually implements, for example:

```lua
id = "lsp"
priority = 100
kind = "semantic-project"
```

Tree-sitter must remain registered and available as fallback when:

- no server is configured
- server startup fails
- server is still initializing
- server does not advertise a capability
- request times out or errors
- cached LSP data is stale or pending
- document/language is unsupported

## Reference-project lessons

This plan should be implemented with explicit lessons from mature editors, especially Zed. Fred does not appear to implement LSP, but still reinforces keeping Tree-sitter/local syntax independent from any future semantic layer.

### Zed LSP architecture lessons

Local reference repo:

```text
C:\Users\Darius\AppData\Local\pi-web-smart-fetch\github-cache\zed-industries\zed
```

Useful files and observed lessons:

```text
crates/lsp/src/input_handler.rs
crates/lsp/src/lsp.rs
crates/project/src/lsp_store.rs
crates/project/src/lsp_store/document_symbols.rs
crates/project/src/lsp_store/semantic_tokens.rs
crates/project/src/lsp_command.rs
crates/language/src/language.rs
crates/language/src/language_registry.rs
crates/project/src/manifest_tree/server_tree.rs
crates/project/src/trusted_worktrees.rs
crates/editor/src/diagnostics.rs
crates/diagnostics/src/buffer_diagnostics.rs
```

Concrete takeaways for Anvil:

- **Framing and backpressure:** Zed parses `Content-Length` framing incrementally and uses a bounded incoming queue. Anvil should not use a blocking read helper that waits to fill a large requested byte count before returning LSP chunks.
- **Lifecycle:** Zed starts servers with piped stdio, captures stderr, stores response handlers by ID, initializes, sends `initialized`, shuts down with timeout, sends `exit`, then kills if necessary.
- **Capability negotiation:** Initialize params include root URI/path, workspace folders, client capabilities, and explicit position encoding. Dynamic registrations are handled via `client/registerCapability` / `client/unregisterCapability`.
- **Document sync:** Zed tracks per-buffer/per-server snapshots and sends full or incremental sync depending on capability. Anvil should start with full sync but still track per-client document state and versions.
- **Position encoding:** Zed uses UTF-16 points in LSP-facing paths and clips server ranges into buffers. Anvil byte columns make this a major hidden complexity.
- **Diagnostics:** Zed stores diagnostics separately from UI, per worktree/path/server, remaps or discards stale diagnostics, and only later displays/navigation them.
- **Document symbols:** Zed caches document symbols by buffer version and deduplicates in-flight requests. LSP outline must not block synchronously.
- **Definition/references:** Zed handles scalar/array/link responses and cross-file buffers. Multiple results are a real UX case; silently selecting the first is not acceptable.
- **Semantic tokens:** Zed keeps Tree-sitter/base syntax and overlays semantic token styles with versioned caches. Anvil should defer semantic tokens until style/overlay policy is explicit.
- **Server identity/root reuse:** Zed keys language servers by worktree/manifest root/language/server and reuses/rebases them across settings changes. Anvil needs a simpler but explicit client identity key.
- **Testing:** Zed has fake language servers/pipes and fake adapters. Anvil tests must use fake/mock servers, not installed `clangd`.

### Fred recovered source

Local reference:

```text
C:\Projects\my_decomps\fred_src_dump\D_\git_projects\fred
```

Relevant files:

```text
src/tree-sitter-bridge.cpp
src/ed.cpp
```

I do not see evidence of LSP/JSON-RPC/language-server architecture in Fred. Its main useful lesson is architectural separation: keep fast local syntax/Tree-sitter behavior independent from any external semantic service.

## Guiding principles

1. **No UI blocking.** LSP process startup, initialization, requests, indexing, and result conversion must not block rendering or editing.
2. **Capability-driven.** Only expose/use features the server advertises, including dynamic capabilities if/when supported.
3. **Tree-sitter fallback stays intact.** LSP failure must not make syntax highlighting/navigation worse.
4. **Small milestones.** LSP is large; implement as separately reviewable milestones.
5. **Fake-server tests first.** Automated tests must not require `clangd` or any installed external language server.
6. **Manual gates for visible behavior.** Diagnostics, completion, semantic tokens, and navigation should have manual app testing before commit.
7. **Keep machine-local config out of repo.** Bundled defaults can include server definitions, but user paths/state/logs remain in `USERDIR`.
8. **Prefer clear fallback behavior over clever partial semantics.** If semantic truth is uncertain, fall back or label as local/syntactic.
9. **Async/cache provider contract.** LSP-backed provider methods must return cached/fallback/pending status, not synchronously wait for server responses.
10. **No arbitrary first-result jumps.** Multiple definitions/references must return a structured list and use a picker/result UI when available.

## Non-goals for the first LSP landing

- No one-shot implementation of the entire LSP feature set.
- No dependency on `clangd` being installed for tests.
- No package manager / server installer in the first pass.
- No remote development support.
- No LSP marketplace.
- No attempt to make Tree-sitter semantic.
- No removal of regex/native-tokenizer fallback.
- No semantic tokens/completion/diagnostic UI in the foundation milestone.

## Core design

### Module layout

Initial Lua-first structure:

```text
data/core/lsp/init.lua             -- public facade, client registry, commands later
data/core/lsp/jsonrpc.lua          -- Content-Length framing, encode/decode, ids
data/core/lsp/transport.lua        -- transport interface + queues/backpressure
data/core/lsp/client.lua           -- client state machine, request dispatch, lifecycle
data/core/lsp/process.lua          -- process wrapper / stdio transport
data/core/lsp/protocol.lua         -- protocol helpers/constants/capability probes
data/core/lsp/uri.lua              -- path <-> file URI helpers
data/core/lsp/position.lua         -- Anvil byte positions <-> LSP positions
data/core/lsp/documents.lua        -- textDocument sync bookkeeping
data/core/lsp/config.lua           -- server config/root detection/client identity
data/core/lsp/diagnostics.lua      -- storage-only diagnostics model
data/core/lsp/provider.lua         -- language_intelligence provider bridge
```

Tests:

```text
tests/lua/runtime/lsp_jsonrpc.lua
tests/lua/runtime/lsp_transport.lua
tests/lua/runtime/lsp_position.lua
tests/lua/runtime/lsp_uri.lua
tests/lua/runtime/lsp_client.lua
tests/lua/runtime/lsp_documents.lua
tests/lua/runtime/lsp_diagnostics.lua
tests/lua/ui/lsp_provider.lua
```

Fake servers/scripts:

```text
tests/fixtures/lsp/fake_server.lua
```

Do not add native code unless Lua process/pipe APIs prove insufficient. If current process APIs are insufficient, first improve generic process APIs in a small milestone.

### Async provider/cache model

Current `core.language_intelligence` provider calls are synchronous and work well for Tree-sitter. LSP cannot follow that model for server requests.

LSP provider methods must not block waiting for a response. A provider may:

1. return fresh cached data;
2. return stale cached data and schedule a refresh;
3. return no data with reason/status `pending` after scheduling a request;
4. return no data with reason/status `unavailable`, allowing Tree-sitter fallback.

`core.language_intelligence` should gain enough status information before the first LSP-backed feature lands. Suggested return shape for LSP-capable methods:

```lua
value, reason, provider_id, status
```

Where `status` can be:

```text
fresh
stale
pending
unavailable
error
```

Fallback rule:

- If a higher-priority LSP provider returns `fresh`, use it.
- If it returns `pending`, `unavailable`, or `error`, call lower-priority providers such as Tree-sitter unless the caller explicitly asked for LSP-only.
- If it returns `stale`, the caller may use stale data if the UX allows, but should still refresh in background.

### JSON-RPC / stdio framing

Implement strict LSP framing:

```text
Content-Length: <bytes>\r\n
[other headers]\r\n
\r\n
<JSON body>
```

Requirements:

- Parse arbitrary chunk boundaries.
- Support multiple messages in one read.
- Support partial headers/body across reads.
- Use byte length, not character count.
- Unknown headers ignored.
- Invalid framing logs quietly and fails the client safely.
- Incoming queue should be bounded to prevent memory growth if the server floods messages.
- Outgoing writes should include correct byte-length header.

Message types:

- Request: `{ jsonrpc="2.0", id, method, params }`
- Response: `{ jsonrpc="2.0", id, result }` or `{ id, error }`
- Notification: `{ jsonrpc="2.0", method, params }`

Request bookkeeping:

- monotonic numeric IDs
- pending request table by ID
- request method/name for logging
- callback or coroutine continuation
- timeout support
- cancellation support via `$/cancelRequest` before completion/semantic-token milestones
- generation/client ID checks to drop responses from dead/restarted clients

### Transport and process I/O viability

Before real client lifecycle, verify Anvil can read available stdout/stderr chunks without waiting to fill a requested byte count.

Known risk:

- Lua `process.stream:read(n)` may try to fill `n` bytes in a coroutine. That is bad for event-style LSP chunk reads.

Phase 8.2 must answer:

- Can current APIs read whatever bytes are currently available?
- Can stderr be drained independently without blocking stdout?
- Can stdin writes handle backpressure/failure?
- Can process exit be detected promptly?

If not, add a generic process API such as:

```lua
stream:read_available(max_bytes) -> string | nil, err
stream:write_all(bytes) -> true | nil, err
process:on_exit(callback) or pollable returncode
```

This must be generic process infrastructure, not LSP-only native hacks.

### Client lifecycle

Client states should be explicit:

```text
new -> starting -> initializing -> ready -> shutting_down -> exited
                         \-> failed
```

Minimum lifecycle:

1. Spawn server process.
2. Start stdout reader, stderr reader, and outbound writer.
3. Send `initialize` request.
4. Receive capabilities/server info.
5. Record negotiated position encoding.
6. Send `initialized` notification.
7. Become `ready`.
8. On quit/project close/server restart:
   - send `shutdown`
   - wait bounded time
   - send `exit`
   - close queues
   - kill process if needed

Lifecycle must be restartable after failure.

Add:

- startup generation ID to prevent stale startup from resurrecting a stopped client;
- restart count/backoff;
- stderr tail capture with size/rate cap;
- quiet logs for state transitions;
- cleanup of caches/doc state/diagnostics when a server exits.

### Server-initiated requests, dynamic registrations, progress, and messages

Even early clients must safely handle server-to-client requests/notifications.

Minimum safe behavior:

- Unknown server requests: respond with `MethodNotFound` or a safe error.
- Unknown notifications: quiet log at most.
- `window/logMessage`: quiet log with rate/size cap.
- `window/showMessage`: initially quiet log or visible warning only for severe messages.
- `window/workDoneProgress/create`, `$/progress`: store/log minimal progress later; ignore safely at first.
- `client/registerCapability` and `client/unregisterCapability`: log and ignore safely at first, then implement selected registrations later.
- `workspace/configuration`: respond with configured server settings when implemented, safe default earlier.

Dynamic registration is not required in the first lifecycle milestone, but the protocol dispatcher must not crash or hang when servers send these messages.

### Server configuration, discovery, root detection, and client identity

Start with bundled config schema, not auto-installation.

Example first-party defaults could live in a future defaults file or LSP module:

```lua
config.lsp = {
  enabled = true,
  servers = {
    clangd = {
      command = { "clangd", "--background-index" },
      file_patterns = { "%.c$", "%.h$", "%.cc$", "%.cpp$", "%.cxx$", "%.hpp$", "%.hxx$" },
      root_markers = { "compile_commands.json", ".clangd", ".git" },
    },
  },
}
```

Rules:

- Missing executable: quiet log and no provider for that language.
- No server auto-install in initial milestones.
- User/local server overrides belong in `USERDIR` config, not repo state.
- Tests use fake server path, not real server discovery.

Root URI should be based on active project/document.

Priority for C/C++:

1. nearest `compile_commands.json`
2. nearest `.clangd`
3. nearest `.git`
4. current Anvil project root
5. document directory

A running client identity key should include at least:

```text
server id/config fingerprint
root URI / workspace folder set
language/toolchain if applicable
settings generation
```

Opening another compatible document should reuse an existing client instead of spawning one server per document.

### URI/path handling

Add `core.lsp.uri` helpers for:

- Windows path -> `file:///C:/...` URI
- URI -> Windows path
- UTF-8 path escaping/unescaping
- normalized comparison keys
- rejecting unsupported URI schemes for file operations

Never compare raw URI strings when path identity is intended.

### Position encoding

Add `core.lsp.position` before any real document sync/provider feature.

Anvil positions:

- 1-based line
- 1-based byte column into UTF-8 Lua strings
- LF-normalized live text

LSP positions:

- 0-based line
- `character` in negotiated encoding, commonly UTF-16

Required helpers:

```lua
position.doc_to_lsp(doc, line, col, encoding) -> { line, character }
position.lsp_to_doc(doc, lsp_position, encoding, bias) -> line, col
position.range_doc_to_lsp(doc, range, encoding)
position.range_lsp_to_doc(doc, range, encoding, bias)
```

Tests must cover:

- ASCII
- multibyte UTF-8
- astral codepoints needing UTF-16 surrogate pairs
- positions inside/outside line bounds
- invalid/out-of-range server positions
- LF internal text regardless of CRLF save mode

Default to UTF-16 unless a server clearly negotiates UTF-8. For clangd, handle `offsetEncoding`/position encoding negotiation explicitly.

## Document synchronization

LSP document sync is its own milestone after lifecycle/config/position basics.

Required model:

- One `DocumentState` per `(client, document URI)`.
- Send `textDocument/didOpen` when a supported doc is opened and client ready.
- Send `textDocument/didChange` after edits.
- Send `textDocument/didClose` when doc closes.
- Send `textDocument/didSave` only if server capability/config wants it.

Suggested `DocumentState` fields:

```lua
{
  doc = doc,
  uri = uri,
  language_id = language_id,
  lsp_version = 1,
  last_synced_change_id = doc:get_change_id(),
  pending_full_sync = false,
  opened = true,
  closing = false,
}
```

Versioning:

- Maintain monotonically increasing integer document version per LSP-opened doc.
- Increment on every text change sent to LSP.
- Include version in didChange.
- Track `doc_change_id -> lsp_version` mapping where needed to discard stale results.

Sync kind:

- Support `TextDocumentSyncKind.Full` first.
- Incremental sync can be added later using Anvil transactions.
- Full sync is simpler and safer for the first semantic features.

Debounce:

- Edits should not spam server for every keystroke if full sync is used.
- Use a short debounce, e.g. 100-300ms.
- Flush immediately before requests that need current content.

Large-file guard:

- Full sync should have a max document size threshold.
- If exceeded, do not sync and quietly fall back to Tree-sitter/local behavior.

Line endings:

- Anvil stores LF-normalized lines internally.
- Send LF text to LSP.
- Preserve save CRLF behavior separately; LSP sync is based on live text.

Stale responses:

- Each response should be checked against client generation and relevant document version/change id.
- Stale responses must not overwrite fresh caches or diagnostics.

## Language-intelligence provider mapping

LSP provider should register only implemented capabilities and should never block.

### Outline / document symbols

LSP source:

- `textDocument/documentSymbol`

Mapping:

- `DocumentSymbol[]` hierarchical response -> outline symbols with children/depth.
- `SymbolInformation[]` flat response -> sorted flat outline symbols.
- Cache per `(client, uri, lsp_version)`.
- Deduplicate in-flight requests.
- Return fresh cached LSP symbols if available.
- If stale/missing, schedule async request and return `pending`/`stale` so Tree-sitter can be fallback.

Provider method:

```lua
document_outline(doc, opts) -> symbols | {}, reason, status
```

### Definition/declaration

LSP source:

- `textDocument/definition`
- `textDocument/declaration`

Mapping:

- Same-document single location: select/jump directly.
- Cross-file single location: open target file and select range.
- Multiple locations: return structured result list and use a picker/result UI when available.
- Until picker/list UI exists, do not silently jump to the first result. Surface a non-destructive multiple-results response.

Important API point:

- Existing Tree-sitter APIs are explicitly local syntactic fallback.
- LSP semantic definitions should use generic language-intelligence names such as `definitions`, `declarations`, and `references`, not `local_definition`.
- Phase 7 abstraction likely needs API extensions before this lands.

Suggested generic result:

```lua
{
  uri = uri,
  path = path,
  range = range,
  selection_range = selection_range,
  server_id = server_id,
  origin = "lsp",
}
```

### References

LSP source:

- `textDocument/references`

Mapping:

- Current-document references can become multi-selection.
- Cross-file references need structured result list and picker/list UX.
- First milestone can expose API and test data without full UI picker, but commands must not jump arbitrarily.

### Diagnostics

LSP source:

- `textDocument/publishDiagnostics`

Split diagnostics into two milestones:

1. storage-only;
2. UI/render/navigation.

Storage model:

```lua
DiagnosticStore[server_id][uri] = {
  version = version_or_nil,
  diagnostics = diagnostics,
  received_at = system.get_time(),
}
```

Initial display/apply rule:

- Use diagnostics whose version is nil or matches the current synced document version.
- Stale diagnostics may be retained for summary/debugging but must be marked stale or hidden from UI.

UI later:

- underline/squiggle or gutter marks
- status summary
- diagnostic panel/list
- next/previous diagnostic commands

### Semantic tokens

LSP source:

- `textDocument/semanticTokens/full`
- `textDocument/semanticTokens/range`
- optional delta later

Strategy:

- Keep Tree-sitter as base syntax highlight provider.
- LSP semantic tokens should overlay or replace selected token categories only after a clear style/color mapping exists.
- Cache by document version and server legend.
- Define overlap/precedence rules.
- Do not implement in the foundation milestone.

### Completion

LSP source:

- `textDocument/completion`
- `completionItem/resolve`

Strategy:

- Integrate with existing prompt/completion UI later.
- Needs cancellation/debounce and trigger character handling.
- Do not begin completion until request cancellation and document sync are solid.

## Error handling and logging

Use `core.log_quiet` heavily for:

- server discovery decisions
- client identity/root selection
- server start/exit/restart
- initialization capability summary
- request timeout/error
- malformed JSON-RPC
- dropped stale responses
- document sync transitions
- dynamic registration ignored/handled
- server stderr tail summary

Visible `core.warn/error` only when the user needs to act, e.g. a manually configured server command is invalid and a command explicitly requested LSP.

## Testing strategy

### Fake server

A fake server is mandatory for automation. It should:

- read/write LSP stdio framing
- respond to `initialize`
- record notifications
- optionally send diagnostics
- support scripted responses for document symbols/definition/references
- simulate errors, timeouts, partial writes, malformed messages, stderr output, and process exit
- optionally send dynamic registration requests and progress/log/showMessage notifications

Tests must not require clangd.

### Runtime tests

Test pure/protocol pieces:

- header parsing with partial chunks
- multiple messages in one chunk
- invalid header/body handling
- bounded queue/backpressure behavior
- request ID dispatch
- timeout/cancel behavior
- initialize/shutdown lifecycle with fake server
- server crash/restart/generation handling
- stderr draining/rate limiting
- path/URI conversions
- position encoding conversion
- root detection/client identity reuse
- document versioning and didOpen/didChange/didClose payloads
- stale response discard
- dynamic capability request safe handling
- diagnostics storage and stale-version behavior

### UI/in-process tests

Test behavior through Anvil APIs:

- provider registration and precedence over Tree-sitter where capability exists
- fallback to Tree-sitter when LSP provider unavailable/pending/error
- no-op behavior when neither provider exists
- commands do not test exact keybindings
- cross-file result representation before picker UI

### Manual tests

Manual gates should be required for visible features:

- document sync with real clangd on C/C++ project
- LSP outline replacing/falling back to Tree-sitter
- go-to-definition across files
- references picker/selections
- diagnostics UI
- semantic tokens/highlighting
- completion

## Milestone breakdown

### Phase 8.0: LSP plan

This document. No implementation.

Exit criteria:

- Plan reviewed and committed.
- Reference-project lessons are represented.
- Milestones are small enough for individual implementation agents.

### Phase 8.1: JSON-RPC codec and transport interface

Deliverables:

- JSON-RPC framing parser/encoder.
- Request/response/notification type helpers.
- Request ID bookkeeping independent of process.
- Transport interface abstraction.
- Bounded incoming queue/backpressure policy.
- Pure runtime tests for partial/multiple/malformed messages and response dispatch.

No real clangd integration.
No document sync.
No language-intelligence provider behavior.

Exit criteria:

- Runtime tests cover framing and dispatch thoroughly.
- No external server dependency.

### Phase 8.2: Process I/O viability and stdio transport

Deliverables:

- Verify or extend Anvil process APIs for nonblocking/read-available stdout/stderr.
- Stdio transport implementation over process APIs.
- Fake server process fixture.
- Tests for chunked output, stderr drain, process exit, write failure, and timeout.

Exit criteria:

- LSP transport can read arbitrary available chunks without blocking for a target byte count.
- If process APIs needed changes, those are generic and tested.

### Phase 8.3: URI/path and position helpers

Deliverables:

- `core.lsp.uri`.
- `core.lsp.position`.
- UTF-16 default conversion and UTF-8 option support.
- Tests for Windows paths, escaping, multibyte text, astral codepoints, out-of-range server positions, and LF normalization.

Exit criteria:

- Helpers are standalone and do not require a real LSP server.

### Phase 8.4: Client lifecycle with fake stdio server

Deliverables:

- Spawn stdio fake server process.
- Initialize/initialized/shutdown/exit lifecycle.
- Client state machine.
- Capability storage and negotiated position encoding.
- Server-initiated request safe handling.
- Quiet logging/stderr tail.
- Crash/timeout/restart generation handling.

Exit criteria:

- Client reaches ready against fake server.
- Shutdown is graceful and bounded.
- Server crash transitions client to failed/exited without editor crash.

### Phase 8.5: Server config, root detection, and client identity

Deliverables:

- Config schema for server definitions.
- Root marker detection.
- Client identity key and reuse/restart rules.
- Missing executable fallback behavior.
- Tests with temporary project roots and fake server configs.

Exit criteria:

- No real server required.
- clangd config can be represented but tests use fake server.

### Phase 8.6: Document synchronization

Deliverables:

- didOpen/didChange/didClose/didSave support.
- Full sync first.
- DocumentState with version/change-id mapping.
- Debounced change flushing.
- Flush-before-request hook.
- Large-file guard.
- Tests with fake server validating payloads and stale version handling.

Exit criteria:

- Editing a supported doc sends correct versioned full-content changes.
- Closing docs sends didClose.
- No sync for unsupported/too-large docs.

### Phase 8.7: `core.language_intelligence` async/cache API extension

Deliverables:

- Extend provider dispatch to represent `fresh`, `stale`, `pending`, `unavailable`, `error`.
- Add generic semantic APIs needed by LSP, e.g. `definitions`, `declarations`, `references`, `diagnostics`.
- Preserve Tree-sitter provider behavior and fallback.
- Tests for provider precedence and fallback with pending/error LSP provider.

Exit criteria:

- No LSP feature has to block synchronously.
- Tree-sitter remains fallback.

### Phase 8.8: Diagnostics storage only

Deliverables:

- Handle `textDocument/publishDiagnostics` notifications.
- Store diagnostics by server and URI with version.
- Mark or hide stale diagnostics.
- Clear diagnostics on server exit/doc close as appropriate.
- Tests with fake server diagnostics.

No visible diagnostics UI yet.

Exit criteria:

- Storage behavior is correct and version-aware.

### Phase 8.9: LSP document symbols provider

Deliverables:

- `textDocument/documentSymbol` request.
- Cache per document version and dedupe in-flight requests.
- Map flat and nested responses to `core.language_intelligence.document_outline` result format.
- Higher priority than Tree-sitter only when server supports document symbols and fresh cached data exists.
- Tests for LSP outline, pending fallback to Tree-sitter, stale discard.

Manual gate:

- Optional first real clangd outline test on C/C++ file.

### Phase 8.10: LSP definition/declaration/references provider and result UX

Deliverables:

- `textDocument/definition`, `declaration`, and `references` requests.
- Same-file and cross-file result data conversion.
- Structured result list API.
- Exactly one result: jump/open/select.
- Multiple results: picker/list UX if available; otherwise non-destructive multiple-results response.
- Fallback to Tree-sitter local syntactic fallback when unavailable/pending/error.
- Tests with fake server for scalar/array/location-link/cross-file responses.

Manual gate:

- Real clangd go-to-definition/references in C/C++ project.

### Phase 8.11: Diagnostics UI and navigation

Deliverables:

- Decide first UI surface before implementation: status/log-only, gutter marks, underline, diagnostics panel, or a small combination.
- Render only current/fresh diagnostics initially.
- Next/previous diagnostic commands if UI exists.
- Tests for command behavior, not keybindings.

Manual gate required.

### Phase 8.12: Semantic tokens strategy/prototype

Deliverables:

- Decide overlay vs replacement behavior.
- Map LSP token types/modifiers to Anvil style keys.
- Cache by document version and server legend.
- Define overlap precedence with Tree-sitter tokens.
- Prototype on one language only if safe.
- Preserve Tree-sitter and tokenizer fallback.

Manual gate required.

### Phase 8.13: Completion later

Deliverables:

- Completion request/cancel/resolve model.
- Trigger characters and manual invoke.
- Integrate with Anvil completion UI.
- Debounce/cancel stale requests.

Manual gate required.

## Open decisions before implementation

1. What exact status tuple should `core.language_intelligence` return for async providers?
2. Should generic semantic provider APIs be added before any LSP feature, or alongside Phase 8.7?
3. What is the first real server target: `clangd` only, or generic config with clangd as first bundled default?
4. What picker/list UI should multiple definition/reference results use?
5. What UI should diagnostics use first: log/status-only, gutter marks, underline, or diagnostics panel?
6. Should document sync start automatically for all supported docs or only after first LSP feature request?
7. What timeout defaults should requests use by feature?
8. How should server stderr be surfaced when debugging LSP issues?
9. What max file size should disable full sync?
10. How aggressively should clients restart after crashes?

## Suggested first implementation task

After this plan is accepted, give the next agent only Phase 8.1:

```text
Implement Phase 8.1 only: JSON-RPC codec and transport interface. Do not implement real clangd integration, client lifecycle, document sync, diagnostics, or language-intelligence provider behavior yet.
```
