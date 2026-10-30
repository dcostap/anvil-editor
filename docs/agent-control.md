# Agent control

Anvil exposes editor operations through an authenticated local MCP server. Interactive Pi sessions connect automatically. Other MCP clients can use the same tools.

Each loaded Project owns its operations. The MCP transport does not contain editor behavior. Pi remains an interactive Terminal program, not an RPC-mode agent.

## Use from Pi

Start a new Pi in an Anvil Terminal. Its extension registers the `anvil` MCP server and adds brief instructions. Existing Pi processes must restart to load the extension.

1. Call `workspace_state` to find the caller, Panes, Terminal Sessions, and loaded Projects.
2. Use stable IDs from that result. Pane numbers are navigation shortcuts, not identities.
3. Set `project` to a listed Project path when controlling another Project.
4. Use a new `request_id` for each mutation. Reuse it only to retry identical work.

The default target is the caller's Project. Operations preserve focus unless `focus: true` requests a change. Close operations use normal confirmations. A confirmation can take focus.

`pi_start` requires `cwd`, `provider`, `model`, and `thinking`. It opens an independent Pi conversation in a visible Terminal Pane. It copies no conversation or model choice from the caller. The starting directory must exist.

The result contains an `operation` ID. Poll `operation_read` until its status becomes `ready` or `failed`. Pi readiness includes its exact selected model and thinking level. An optional initial `task` starts only after this check.

Use `agent_send` with `delivery: "queue"` to wait for an idle Pi. Use `delivery: "steer"` to change active work. Messages retain their source Terminal and appear as agent messages, not human messages.

Use `agent_read` or `agent_wait` with the returned task ID. Completion follows Pi's `agent_settled` event, after retries and automatic recovery. Results include the final assistant text and a truncation flag when necessary.

A wait timeout does not cancel work. A disconnect does not mean completion. A reported question ends the wait with `waiting_for_user`. Use `agent_interrupt` to stop active work and cancel queued Anvil tasks without closing the Terminal.

Steering and interruption return `delivered` after Pi accepts them. A steering receipt can include `related_task`, the active Anvil task. Wait for that task to retrieve its final answer.

## Tools

| Tool | Operation |
| --- | --- |
| `workspace_state` | Inspect Panes, retained Terminal Views, agent identities, and Projects. |
| `pane` | Create, split, move, focus, or close a Pane. |
| `open_file` | Open a file at a line in a new Pane or split. |
| `terminal_start` | Open a shell, optionally with a structured executable and argument list. |
| `terminal` | Read terminal text, send literal input, or close a Terminal View. |
| `pi_start` | Start an independent interactive Pi with explicit model choices. |
| `operation_read` | Read launch progress and readiness. |
| `agent_send` | Queue a task or steer active work. |
| `agent_read` | Read agent status, a receipt, or a task result. |
| `agent_wait` | Wait for completion, a question, a disconnect, or a timeout. |
| `agent_interrupt` | Interrupt active work and cancel queued Anvil tasks. |

Tool schemas describe their required fields. Terminal launch currently requires Windows. Structured executable launch requires PowerShell. Literal Terminal input is not a Pi messaging API; Anvil rejects it for Pi.

For `terminal_start`, readiness describes the shell, not the optional program. Read its Terminal output to check program startup. `pi_start` also waits for Pi's control connection.

## Identity and limits

Targets include a Terminal Session ID and a Pi conversation `instance`. A replacement conversation has a new instance. Requests for an old instance fail instead of reaching another conversation.

Retry receipts belong to the running Project process. Repeating an ID with different arguments fails. After a Project restart, inspect state before submitting mutations again. Do not assume an earlier mutation failed because its response was lost.

Pi persists accepted task receipts in its session. Reload does not replay accepted tasks. An interrupted run remains interrupted. Discovery reconnects when Anvil restarts while Terminal hosts keep running.

Queues, receipts, and output have bounds. Full queues reject new tasks. Capacity errors require a new Pi conversation or Project process, as their error states. Terminal reads contain at most 32 KB. Task answers contain at most 8 KB; read the Pi session or visible Terminal for longer output.

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

`node --test tests/pi-control.test.cjs` tests delivery, steering, interruption, settlement, and reload receipts.

`ui/control_pi.lua` runs real Pi TUI processes inside real Terminal Sessions. A parent Pi uses MCP to launch a child, send work, and retrieve its answer. The test checks that the user's Pane keeps focus.

The test uses `tests/fixtures/control-model.cjs`, a local scripted model endpoint. It uses isolated Pi settings and sessions. It does not use providers, real API keys, inference, or the user's Pi data.
