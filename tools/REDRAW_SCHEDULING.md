# Redraw ownership

A visible state change needs a pending redraw request. Waiting for a frame must not consume that request.
The main loop consumes it when drawing starts. Requests made during drawing remain pending for the next frame.

Native input and successful commands request redraws centrally.
Background result handlers must request a redraw, or call a publication API that requests one.
Worker completion alone does not imply a visible change. Do not redraw after every worker message.

## Background publication audit

The audit traced these first-party publication paths to their redraw owners:

| Publication | Redraw owner or result |
| --- | --- |
| Background Buffer load | `Buffer:load_async` completion |
| Background Buffer save | Fixed `Buffer:save`; the clean state previously waited for another redraw |
| Inferred Language Mode | Fixed `Buffer:set_syntax`; syntax changes previously omitted the request |
| LSP diagnostics, including clearing | Fixed the diagnostics publication generation update |
| LSP semantic tokens | Fixed accepted semantic-token responses in `core.lsp.provider` |
| Autocomplete LSP results | `set_lsp_completion_items` updates suggestions and requests a redraw |
| LSP progress, hover, and signature help | Progress requests a redraw; hover and signature help use visible logging |
| Git status and Git View results | Status publication and the View's `on_update` callback |
| File Tree directory changes | Filesystem synchronization changes the Buffer; Git metadata uses status publication |
| Folder counts | The accepted count requests a redraw |
| Fuzzy Searcher files, text, and Everything results | Result publication calls `schedule_update` |
| Project symbol snapshots and progress | Scan completion and progress request redraws |
| Markdown parses, vault updates, and fence highlighting | Model publication and Live Preview listeners |
| Markdown image downloads | The subscribed View invalidates image rows and requests a redraw |
| Terminal output and held screen updates | Snapshot publication and `render_pending` |
| Bookmark recovery and Editor file locations | Accepted changes request redraws |
| Process streams and raw Project file scans | Data-only delivery; their visible consumers own redraws |

This was a source audit, not a proof of every callback or failure path.
Only the four confirmed omissions received new regression tests and fixes.
No blanket worker redraw was added.

## Regression evidence

`tests/lua/ui/redraw_cadence.lua` drives the real scheduler with controlled native timing and input.
Its save and Language Mode cases failed before their fixes and passed afterward.
They disable unrelated animation and wait for startup feedback to finish.

`tests/lua/runtime/lsp_diagnostics.lua` and `lsp_semantic_tokens.lua` use fake server responses at the transport boundary.
Their new tests failed because accepted results did not set the public `core.redraw` request.
They pass after the publication fixes. Diagnostics clearing also requests a redraw.

The existing autocomplete and scroll cadence tests cover deferred input and animation frames.
The response harness has separate tests for missing requests, pending results, frame deadlines, and unchanged uncapped behavior.

See [scenario runs](SCENARIOS.md#response-latency) for the paced performance check.
