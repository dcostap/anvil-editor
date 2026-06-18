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

Useful files and observed lessons. Line numbers are from the local cached checkout and are included so future agents do not need to rediscover the same evidence from scratch:

```text
crates/lsp/src/input_handler.rs
  - around 22-27: bounded incoming queue/backpressure comments
  - around 35-99: incremental Content-Length header/body parsing
  - around 146-188: tests for not buffering unlimited messages
crates/lsp/src/lsp.rs
  - around 421-438: spawn with piped stdin/stdout/stderr
  - around 535-545: stderr drain task
  - around 734-740: outbound Content-Length framing
  - around 772-787: root URI/path and UTF-16 position encoding
  - around 789-999: advertised capabilities/dynamic registrations
  - around 1055-1082: initialize, capabilities, initialized
  - around 1086-1141: shutdown timeout, exit, kill
  - around 1715-1733: didOpen/didClose
  - around 1822-2020: `FakeLanguageServer` test support
  - around 2248-2270: tests preserve numeric/string request IDs
crates/project/src/lsp_store.rs
  - around 626-665: startup failure and stderr reporting
  - around 875-907: publishDiagnostics handling
  - around 910-970: workspace/configuration handling
  - around 998-1019: window/workDoneProgress/create handling
  - around 1023-1079: client/registerCapability and unregisterCapability
  - around 2708-2785: diagnostics sorting/remap/clipping
  - around 3104-3140: retained snapshots by LSP version
  - around 8272-8343: full/incremental didChange and version increment
  - around 11308-11367: clear diagnostics on server stop
  - around 11859-11977: insert running server/capabilities/open buffers
  - around 12040-12066: initial per-server buffer snapshot and didOpen
crates/project/src/lsp_store/document_symbols.rs
  - around 38-97: versioned cache and in-flight request dedupe
  - around 139-163: only update cache when versions match
  - around 245-285: flatten hierarchical symbols
crates/project/src/lsp_store/semantic_tokens.rs
  - around 32-52: stylizers/rules per server/language
  - around 544-599: chunked token conversion
  - around 621-625: multi-server overlap precedence
crates/project/src/lsp_command.rs
  - around 1182-1256: scalar/array/link definition responses and cross-file targets
  - around 1417-1445: references across files/buffers
crates/language/src/language.rs
  - around 1478-1500: UTF-16/LSP position conversion
crates/text/src/text.rs
  - around 2225-2262: UTF-16 point/offset conversion
  - around 2685-2687: clipping UTF-16 points into buffer bounds
crates/project/src/manifest_tree/server_tree.rs
  - around 1-7, 151-163, 305-314: server root/reuse tree
crates/project/src/trusted_worktrees.rs
  - around 19-35: trust gate rationale for starting servers
crates/editor/src/diagnostics.rs
  - around 70-95 and 203-251: diagnostic navigation
crates/diagnostics/src/buffer_diagnostics.rs
  - around 45-79: diagnostics panel separated from storage
```

Concrete takeaways for Anvil:

- **Framing and backpressure:** Zed parses `Content-Length` framing incrementally and uses a bounded incoming queue. Anvil should not use a blocking read helper that waits to fill a large requested byte count before returning LSP chunks, and should enforce max header/body sizes.
- **Lifecycle:** Zed starts servers with piped stdio, captures stderr, stores response handlers by ID, initializes, sends `initialized`, shuts down with timeout, sends `exit`, then kills if necessary.
- **Capability negotiation:** Initialize params include root URI/path, workspace folders, client capabilities, and explicit position encoding. Dynamic registrations are handled via `client/registerCapability` / `client/unregisterCapability`. Do not advertise dynamic/config/progress capabilities until Anvil actually handles them.
- **Document sync:** Zed tracks per-buffer/per-server snapshots and sends full or incremental sync depending on capability. Anvil should start with full sync but still track per-client document state and versions.
- **Position encoding:** Zed uses UTF-16 points in LSP-facing paths and clips server ranges into buffers. Anvil byte columns make this a major hidden complexity.
- **Diagnostics:** Zed stores diagnostics separately from UI, per worktree/path/server, remaps or discards stale diagnostics, and only later displays/navigation them.
- **Document symbols:** Zed caches document symbols by buffer version and deduplicates in-flight requests. LSP outline must not block synchronously.
- **Definition/references:** Zed handles scalar/array/link responses and cross-file buffers. Multiple results are a real UX case; silently selecting the first is not acceptable.
- **Semantic tokens:** Zed keeps Tree-sitter/base syntax and overlays semantic token styles with versioned caches. Anvil should defer semantic tokens until style/overlay policy is explicit.
- **Server identity/root reuse:** Zed keys language servers by worktree/manifest root/language/server and reuses/rebases them across settings changes. Anvil needs a simpler but explicit client identity key.
- **Testing:** Zed has fake language servers/pipes and fake adapters. Anvil tests must use fake/mock servers, not installed `clangd`. Use an in-memory scripted transport for protocol/client-state tests and a separate fake process server for stdio/process tests.

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
11. **Truthful capability advertisement.** Do not set LSP dynamic-registration/configuration/progress capability flags to true until matching handlers exist.
12. **Trust before executable project config.** Bundled server commands are fine; workspace-provided executable commands need explicit trust/opt-in before launch.
13. **JSON correctness before LSP messages.** LSP needs explicit empty arrays and explicit `null`; Anvil's current generic JSON module is not safe enough unchanged.
14. **Empty results are real results.** A fresh empty LSP outline/reference list is authoritative and must not be treated as provider failure.

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
data/core/lsp/json.lua             -- LSP-safe JSON wrappers/sentinels if core.json is not extended
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
tests/lua/runtime/lsp_json.lua
tests/lua/runtime/lsp_jsonrpc.lua
tests/lua/runtime/lsp_transport.lua
tests/lua/runtime/lsp_position.lua
tests/lua/runtime/lsp_uri.lua
tests/lua/runtime/lsp_client.lua
tests/lua/runtime/lsp_documents.lua
tests/lua/runtime/lsp_diagnostics.lua
tests/lua/ui/lsp_provider.lua
```

Fake transports and servers:

```text
tests/fixtures/lsp/fake_transport.lua -- in-memory scripted transport for protocol/client tests
tests/fixtures/lsp/fake_server.lua    -- subprocess stdio fixture for process/lifecycle tests
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

Or, if the API is refactored more aggressively:

```lua
{
  value = {},
  status = "fresh" | "stale" | "pending" | "unavailable" | "error",
  provider_id = "lsp",
  reason = nil,
}
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

- If a higher-priority LSP provider returns `fresh`, use it, even if the value is an empty table.
- If it returns `pending`, `unavailable`, or `error`, call lower-priority providers such as Tree-sitter unless the caller explicitly asked for LSP-only.
- If it returns `stale`, the caller may use stale data if the UX allows, but should still refresh in background.

Current `core.language_intelligence.first_value` skips empty tables, which is correct for current Tree-sitter fallback probing but wrong for LSP. A `fresh` empty outline/reference/diagnostic-related result is an authoritative server answer. Fallback should depend on status, not `#value > 0` or `next(value) ~= nil`.

### JSON codec constraints

Before implementing JSON-RPC, audit Anvil's existing `core.json`.

Known current issues:

- Empty Lua tables encode as `{}`, not `[]`.
- JSON `null` decodes to Lua `nil`, losing the distinction between a missing field and an explicit `null` result.
- `json.null` exists for encoding, but decode preservation and empty-array/object control are not sufficient for LSP without additional helpers.

LSP requires explicit empty arrays, explicit null values, and preserving string/numeric request IDs. Phase 8.1 must either extend `core.json` or introduce `core.lsp.json` with LSP-safe sentinels such as:

```lua
lsp_json.array({})
lsp_json.object({})
lsp_json.null
```

Do not build JSON-RPC on the current generic JSON behavior unchanged.

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
- Enforce configurable maximum header bytes and maximum body bytes; oversized messages fail the client safely.
- Incoming queue should be bounded to prevent memory growth if the server floods messages.
- Outgoing writes should include correct byte-length header.

Message types:

- Request: `{ jsonrpc="2.0", id, method, params }`
- Response: `{ jsonrpc="2.0", id, result }` or `{ jsonrpc="2.0", id, error = { code, message, data? } }`
- Notification: `{ jsonrpc="2.0", method, params }`

Outbound request IDs may be numeric, but inbound server request IDs may be string or number. Responses to server requests must preserve the original ID type.

Suggested normalized message shape:

```lua
{
  kind = "request" | "response" | "notification",
  id = number_or_string_or_nil,
  method = method_or_nil,
  params = params_or_nil,
  result = result_or_nil,
  error = { code = number, message = string, data = any_or_nil } or nil,
}
```

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

Known local evidence:

- Native `proc:read(fd, max)` drains available stdout/stderr chunks and returns up to the requested size.
- Lua `process.stream:read(n)` waits toward a target byte count in yieldable coroutines. That wrapper behavior is bad for event-style LSP chunk reads.

Phase 8.2 should prefer native `proc:read_stdout/read_stderr` or a thin `read_available(max_bytes)` wrapper, not `process.stream:read(n)`. Still test the behavior explicitly so future process API changes do not silently break LSP.

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
- `window/workDoneProgress/create`, `$/progress`: do not advertise support until handled; still respond safely if received.
- `client/registerCapability` and `client/unregisterCapability`: do not advertise dynamic registration support until handled; still respond safely if received.
- `workspace/applyEdit`: do not advertise until implemented; if received anyway, return failure safely.
- `workspace/configuration`: do not advertise `workspace.configuration = true` until configured responses exist.
- File watching/file operations: do not advertise until Anvil has handlers and policy.
- Completion resolve, semantic tokens, diagnostics pull, and other feature-specific dynamic registrations: advertise only when the corresponding implementation exists.

Dynamic registration is not required in the first lifecycle milestone, but the protocol dispatcher must not crash or hang when servers send these messages. Safe unknown-request handling is necessary; truthful capability advertisement is mandatory.

### Server configuration, discovery, root detection, and client identity

Start with bundled config schema, not auto-installation.

Example first-party defaults could live in a future defaults file or LSP module:

```lua
config.lsp = {
  enabled = true,
  servers = {
    clangd = {
      command = { "clangd", "--background-index" },
      language_id = "cpp",
      file_patterns = { "%.c$", "%.h$", "%.cc$", "%.cpp$", "%.cxx$", "%.hpp$", "%.hxx$" },
      root_markers = { "compile_commands.json", ".clangd", ".git" },
      initialization_options = {},
      settings = {},
      env = {},
      cwd_policy = "root",
      request_timeout = 10,
    },
  },
}
```

Rules:

- Missing executable: quiet log and no provider for that language.
- No server auto-install in initial milestones.
- User/local server overrides belong in `USERDIR` config, not repo state.
- Tests use fake server path, not real server discovery.
- If project-local config is ever allowed to define executable commands, add a trust/opt-in gate before launching them. Bundled first-party server definitions are safe defaults; arbitrary workspace-provided commands are not.

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

- Centralize LSP document lifecycle hooks in one module. Use the same core extension points Tree-sitter already uses: filename/load/reset_syntax for attach/update, `Doc:on_text_transaction` for changes, and `Doc:on_close` for didClose/cleanup. Do not let each LSP feature patch `Doc` independently.
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
  lsp_version = 0,
  last_synced_change_id = doc:get_change_id(),
  snapshots = {}, -- bounded doc_change_id/lsp_version/text metadata
  pending_full_sync = false,
  opened = false,
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

Diagnostic = {
  uri = uri,
  path = path_or_nil,
  lsp_range = raw_lsp_range,
  doc_range = converted_range_or_nil,
  severity = severity,
  code = code,
  code_description = code_description,
  source = source,
  message = message,
  tags = tags,
  related_information = related_information,
  data = data,
  version = version_or_nil,
  server_id = server_id,
  stale = boolean,
}
```

Store raw URI/LSP ranges and normalized metadata first. Convert to Anvil byte-range `doc_range` lazily only when a matching `Doc` is open or a UI needs rendering/navigation. This is required for diagnostics on unopened files and workspace-wide diagnostics. Keep summaries by URI/path separate from render/navigation state.

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

### Fake transports and servers

Two fake-server layers are mandatory for automation:

1. **In-memory scripted transport** for JSON-RPC dispatch, request bookkeeping, client state, and server-request policy tests. These tests should not launch subprocesses.
2. **Process stdio fake server** for pipe/framing/lifecycle tests. These tests verify Anvil's process APIs and stdio behavior.

Fake layers should:

- read/write LSP framing where relevant
- respond to `initialize`
- record notifications
- optionally send diagnostics
- support scripted responses for document symbols/definition/references
- simulate errors, timeouts, partial writes, malformed messages, stderr output, and process exit
- optionally send dynamic registration requests and progress/log/showMessage notifications

Tests must not require clangd.

### Runtime tests

Test pure/protocol pieces:

- LSP-safe JSON encoding/decoding for empty arrays, objects, explicit nulls, and request ID preservation
- header parsing with partial chunks
- multiple messages in one chunk
- invalid header/body handling and max header/body size rejection
- bounded queue/backpressure behavior
- request ID dispatch, including numeric outbound IDs and string/numeric inbound server request IDs
- timeout/cancel behavior
- initialize/shutdown lifecycle with in-memory fake transport first, then process fake server
- server crash/restart/generation handling
- stderr draining/rate limiting
- path/URI conversions
- position encoding conversion
- root detection/client identity reuse
- document versioning and didOpen/didChange/didClose payloads
- stale response discard
- dynamic capability request safe handling
- diagnostics storage and stale-version behavior, including unopened-file diagnostics with raw URI/LSP ranges

### UI/in-process tests

Test behavior through Anvil APIs:

- provider registration and precedence over Tree-sitter where capability exists
- fresh empty LSP results are authoritative and do not fall through accidentally
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

- LSP-safe JSON codec or wrappers for empty arrays, objects, explicit nulls, and request ID preservation.
- JSON-RPC framing parser/encoder.
- Request/response/notification type helpers.
- Request ID bookkeeping independent of process.
- Transport interface abstraction.
- In-memory scripted transport fixture for protocol/client tests.
- Bounded incoming queue/backpressure policy.
- Pure runtime tests for JSON codec behavior, partial/multiple/malformed messages, bounded queues, and response dispatch.

No real clangd integration.
No document sync.
No language-intelligence provider behavior.

Exit criteria:

- Runtime tests cover framing and dispatch thoroughly.
- No external server dependency.

### Phase 8.2: Process I/O viability and stdio transport

Deliverables:

- Verify native `proc:read(fd, max)` drains available chunks and returns up to requested size.
- Avoid `process.stream:read(n)` for event-style LSP reads.
- Extend Anvil process APIs with a thin `read_available(max_bytes)` wrapper if needed.
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
- Truthful client capability policy: do not advertise dynamicRegistration/workspace.configuration/workDoneProgress until handled.
- Quiet logging/stderr tail.
- Crash/timeout/restart generation handling.

Exit criteria:

- Client reaches ready against fake server.
- Shutdown is graceful and bounded.
- Server crash transitions client to failed/exited without editor crash.

### Phase 8.5: Server config, root detection, and client identity

Deliverables:

- Config schema for server definitions including command, language_id, file patterns, root markers, initialization_options, settings, env, cwd/root policy, and request timeout defaults.
- Trust/opt-in policy for any future project-local executable server commands.
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
- Centralized Doc lifecycle hooks modeled after Tree-sitter's Doc patching.
- DocumentState with version/change-id/snapshot mapping.
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
- Define empty-result semantics: `fresh` with `{}` is a real answer, not provider failure.
- Add generic semantic APIs needed by LSP, e.g. `definitions`, `declarations`, `references`, `diagnostics`.
- Preserve Tree-sitter provider behavior and fallback.
- Tests for provider precedence, fresh empty results, and fallback with pending/error LSP provider.

Exit criteria:

- No LSP feature has to block synchronously.
- Tree-sitter remains fallback.

### Phase 8.8: Diagnostics storage only

Deliverables:

- Handle `textDocument/publishDiagnostics` notifications.
- Store diagnostics by server and URI with version.
- Preserve raw URI/LSP ranges for unopened files and convert to doc byte ranges lazily for open docs/UI.
- Preserve normalized diagnostic metadata: severity, source, code/codeDescription, tags, relatedInformation, data, server_id, URI, version, received_at, stale/current state.
- Mark or hide stale diagnostics.
- Clear diagnostics on server exit/doc close as appropriate.
- Tests with fake server diagnostics, including diagnostics for unopened files.

No visible diagnostics UI yet.

Exit criteria:

- Storage behavior is correct, version-aware, and supports unopened-file diagnostics.

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

### Phase 8.14: Hover provider/prototype

Deliverables:

- Manual `textDocument/hover` request path and command.
- Normalize conservative Hover content forms into plain/markdown text.
- Cache/discard hover responses by document version, position, and client generation.
- Use a small existing UI surface such as status/log output; no mouse-hover popup yet.
- Preserve no-op/fallback behavior when LSP is unavailable or pending.

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
11. Should `core.json` be extended globally, or should LSP use a narrow `core.lsp.json` wrapper with array/object/null sentinels?

## Suggested first implementation task

After this plan is accepted, give the next agent only Phase 8.1:

```text
Implement Phase 8.1 only: JSON-RPC codec and transport interface. Do not implement real clangd integration, client lifecycle, document sync, diagnostics, or language-intelligence provider behavior yet.
```
