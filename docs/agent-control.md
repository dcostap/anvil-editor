# Agent control

Anvil exposes editor operations through an authenticated local MCP server. Interactive Pi sessions connect automatically. Other MCP clients can use the same tools.

Each loaded Project owns its operations. The MCP transport does not contain editor behavior. Pi remains an interactive Terminal program, not an RPC-mode agent.

## Use from Pi

Start a new Pi in an Anvil Terminal. Its extension registers the `anvil` MCP server and adds brief instructions. Existing Pi processes must restart to load the extension.

1. Call `workspace_state` to find the caller, Panes, Terminal Sessions, and loaded Projects.
2. Use stable IDs from that result. Pane numbers are navigation shortcuts, not identities.
3. Set `project` to a listed Project path when controlling another Project.
4. Use a new `request_id` for each mutation. Reuse it only to retry identical work.

Right-click a running Pi's Tab and choose **Copy Agent Address**. This works in the Project Sidebar and Title Bar. It copies JSON with the `project`, `pane`, and `terminal` IDs, not a navigation number or credentials. Paste it into another agent's conversation to identify the target.

The receiving agent calls `workspace_state` for that `project` and finds the copied `terminal`. It uses that Terminal's current `agent_instance` as `instance` for `agent_send`. The address identifies the Terminal, not a fixed Pi conversation. Inspect state again after a Project move.

The default target is the caller's Project. Operations preserve focus unless `focus: true` requests a change. Close operations use normal confirmations. A confirmation can take focus. Snooze hides its Pane through the normal Snooze behavior.

“Anvil integration” means these editor operations. A request such as “snooze for 5 hours” means Anvil's Snooze, not a timer or delayed message.

Call `snooze` with `action: "set"`, `seconds: 18000`, and a new `request_id` for five hours. Omit `pane` and `terminal` to use the calling agent's own Terminal Session. To target another Terminal, supply either its `pane` or its `terminal` ID, not both. A client without a Terminal credential must name a target.

Call `snooze` with `action: "remove"` and a new `request_id` to remove it. Do not supply `seconds` for removal. A duration must be a whole number of seconds, from one second through one year. The target must belong to a loaded Project and have a Terminal View. A retained Terminal cannot set Snooze when its Pane shows another Terminal.

The result reports `accepted` when Anvil queues the request to the Project Sidebar. It includes the target IDs and `until_time` in Unix seconds for a set. The Sidebar saves the time and applies normal Snooze behavior. `workspace_state` reports each Pane's `snoozed` flag. Snooze does not stop the agent's work or send a message later. Retrying the same request does not extend its time.

`pi_start` requires `cwd`, `provider`, `model`, and `thinking`. It opens an independent Pi conversation in a visible Terminal Pane. It copies no conversation or model choice from the caller. The starting directory must exist.

The result contains an `operation` ID. Poll `operation_read` until its status becomes `ready` or `failed`. Pi readiness includes its exact selected model and thinking level. An optional initial `task` starts only after this check.

Use `agent_send` with `delivery: "queue"` to wait for an idle Pi. Use `delivery: "steer"` to change active work. Messages retain their source Terminal and appear as agent messages, not human messages.

Use `agent_read` or `agent_wait` with the returned task ID. Completion follows Pi's `agent_settled` event, after retries and automatic recovery. Results include the final assistant text and a truncation flag when necessary.

### Read another Pi

Use `agent_read` for status and live activity. Use `agent_transcript` for conversation text. Neither read starts a model turn, changes focus, or adds session entries. Both require the Terminal ID and current conversation `instance` from `workspace_state`.

`workspace_state` includes a compact `agent_activity` for connected Pi sessions: `phase`, `since`, `tool_count`, and `stale`. Call `agent_read` for details:

```json
{
  "terminal": "<terminal ID>",
  "instance": "<conversation instance>"
}
```

The result includes `connected`, `activity_stale`, and the Pi's supported `capabilities`. `observation_age_ms` gives the observation age when available. `activity` contains its phase, phase start time, and active tools. Each tool has an ID, name, start time, and a command or path detail when available. Nested tools also name their parent. Times use Unix milliseconds. Details have explicit truncation flags. The list contains at most 32 tools; `tool_count` gives the full count and `tools_truncated` reports omitted tools.

Phases are `idle`, `waiting_model`, `thinking`, `writing`, `preparing_tool`, `running_tools`, `waiting_user`, and `compacting`. Activity updates through Pi's control exchange, normally every 500 milliseconds. After 10 seconds without an exchange, Anvil marks the activity stale. Stale activity describes the last observation, not current work. Set `include_activity: false` to omit tool details.

A tool call can finish while its background command continues. Activity lists active tool calls, not a complete process registry. It does not prove that background work finished. A thinking phase reveals no thinking text.

Read the latest conversation entries:

```json
{
  "terminal": "<terminal ID>",
  "instance": "<conversation instance>",
  "limit": 5
}
```

`agent_transcript` returns `messages` in chronological order. Each entry has `id`, `timestamp`, `role`, and `text`. User, assistant, custom messages, and summaries are included. Custom messages retain their type; Anvil messages also retain their source Terminal. They are not human instructions. System messages, thinking blocks, credentials in extension state, and image bytes are excluded. Images appear as `[image]`. Conversation text and tool arguments can still contain sensitive user data. Apply the same trust rules as local file access.

The read uses the current branch's recorded history, including messages from before compaction. It does not reproduce the model's edited or compacted context. A recorded message can belong to a turn that is still active; `active_turn` reports this. The result also includes the leaf ID and session name when available.

| Argument | Behavior |
| --- | --- |
| `limit` | Return the latest 1–100 eligible entries. Default: 10. Summaries count as entries. |
| `before` | Return entries before this ID. Pass the previous result's `next_before` for older pages. |
| `include_summaries` | Include compaction and branch summaries. Default: true. |
| `include_tools` | Include assistant tool calls and tool-result messages. Default: false. |
| `max_chars` | Share a 256–32000 character budget across the page's text. Default: 12000. |
| `entry_id` | Read one entry instead of a history page. Keep the same content filters. |
| `offset` | Start within `entry_id` text. Default: 0. Offsets use UTF-16 code units. |
| `include_partial` | Add a separate streaming `partial_message` preview, up to 1000 characters. Default: false. |

Long entries include `truncated`, `total_chars`, `offset`, and `next_offset`. To read the rest, pass their ID as `entry_id` and `next_offset` as `offset`. Text chunks never split a surrogate pair. Use `next_before` for older entries, not for the rest of a long entry. An absent `next_before` means no older eligible entries remain. `partial_message` is unstable and has no history cursor; it does not replace a finalized message.

Reads fail when a cursor ID is not on the current branch, the conversation instance changes, or Pi disconnects. A read times out after 10 seconds without a reply. It never interrupts work. Pending reads are bounded and are not agent tasks. `capabilities.transcript` identifies Pi sessions that support these reads. Existing Pi sessions need `/reload` after the updated extension is installed.

Each transcript reply has a 256 KiB limit, including metadata and JSON escaping. An oversized reply fails that read without blocking status reports or commands.

A wait timeout does not cancel work. A disconnect does not mean completion. A reported question ends the wait with `waiting_for_user`. Use `agent_interrupt` to stop active work and cancel queued Anvil tasks without closing the Terminal.

Steering and interruption return `delivered` after Pi accepts them. A steering receipt can include `related_task`, the active Anvil task. Wait for that task to retrieve its final answer.

## Tools

| Tool | Operation |
| --- | --- |
| `workspace_state` | Inspect Panes, retained Terminal Views, agent identities, and Projects. |
| `pane` | Create, split, move, focus, or close a Pane. |
| `snooze` | Set or remove Snooze for a Terminal's Pane; default to the caller's Terminal. |
| `open_file` | Open a file at a line in a new Pane or split. |
| `terminal_start` | Open a shell, optionally with a structured executable and argument list. |
| `terminal` | Read terminal text, send literal input, or close a Terminal View. |
| `pi_start` | Start an independent interactive Pi with explicit model choices. |
| `operation_read` | Read launch progress and readiness. |
| `agent_send` | Queue a task or steer active work. |
| `agent_read` | Read agent status, live activity, a receipt, or a task result. |
| `agent_transcript` | Read paged conversation text, summaries, and optional tool messages. |
| `agent_wait` | Wait for completion, a question, a disconnect, or a timeout. |
| `agent_interrupt` | Interrupt active work and cancel queued Anvil tasks. |

Tool schemas describe their required fields. Terminal launch currently requires Windows. Structured executable launch requires PowerShell. Literal Terminal input is not a Pi messaging API; Anvil rejects it for Pi.

For `terminal_start`, readiness describes the shell, not the optional program. Read its Terminal output to check program startup. `pi_start` also waits for Pi's control connection.

## Identity and limits

Targets include a Terminal Session ID and a Pi conversation `instance`. A replacement conversation has a new instance. Requests for an old instance fail instead of reaching another conversation.

Retry receipts belong to the running Project process. Repeating an ID with different arguments fails. After a Project restart, inspect state before submitting mutations again. Do not assume an earlier mutation failed because its response was lost.

Pi persists accepted task receipts in its session. Reload does not replay accepted tasks. An interrupted run remains interrupted. Discovery reconnects when Anvil restarts while Terminal hosts keep running.

Queues, receipts, and output have bounds. Full queues reject new tasks. Capacity errors require a new Pi conversation or Project process, as their error states. Terminal reads contain at most 32 KB. Task answers contain at most 8 KB; use `agent_transcript` to read longer answers.

Only loaded Projects accept operations. Cross-Project calls do not load, select, or move Projects. Discovery is limited to the same executable and user folder. A stale endpoint after a crash returns an availability error.

## Other MCP clients

Read `USERDIR/control/<pid>.json` for a loaded Project. It contains `url`, `token`, `project`, and `executable`. Connect to `<url>/mcp` through Streamable HTTP. Send `Authorization: Bearer <token>`.

The server supports initialization, tool discovery, tool calls, and ping. It returns JSON responses and supports notifications. It does not provide SSE streams or an arbitrary Lua evaluation tool.

Terminal discovery lives in `USERDIR/control/terminals/<session-id>.json`. Credentials follow Terminal ownership and are revoked on detach or close. They are not printed in model instructions or logs.

## Security

The server binds only to `127.0.0.1`. It rejects browser origins, incorrect Host headers, and missing credentials. Tokens use cryptographic randomness. The discovery directory grants access only to the current OS user, including in a shared portable-app folder.

This is trusted local automation, not a sandbox. A credential permits file access, program launch, and editor operations under the user's account. Treat it like a local shell credential. Do not publish discovery files or forward this port.

Set `ANVIL_CONTROL=0` before starting Anvil to disable its server. Set `ANVIL_PI_CONTROL=0` to disable automatic Pi integration. Pi's `--no-extensions` also prevents automatic injection.

## Checks

`ui/agent_control.lua` tests editor operations and retry behavior. `ui/control_transport.lua` tests MCP authorization and Project routing. `runtime/net_server.lua` tests socket lifecycle and private credential directories.

`node --test tests/pi-control.test.cjs` tests delivery, steering, interruption, settlement, reload receipts, conversation pages, and live activity.

`ui/control_pi.lua` runs real Pi TUI processes inside real Terminal Sessions. A parent Pi uses MCP to launch a child, send work, and retrieve its answer and conversation. The test checks that the user's Pane keeps focus.

The `terminal-focus` shell probe checks agent Snooze requests through the real shell and Sidebar, including persistence and removal.

The test uses `tests/fixtures/control-model.cjs`, a local scripted model endpoint. It uses isolated Pi settings and sessions. It does not use providers, real API keys, inference, or the user's Pi data.

Meson finds Pi and Node on `PATH` before it restricts the test environment. Configure again after installing or moving either program. On Windows, the Pi UI test skips only when Meson did not find a required program.
