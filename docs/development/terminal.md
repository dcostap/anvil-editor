# Terminal Sessions and agent integration

For Ghostty versions and local patches, see [Windows build notes](build-windows.md#ghostty).

## ConPTY, scrolling and Text Captures

Windows Terminal Sessions use bundled Microsoft ConPTY, not the system console host. `subprojects/conpty.wrap` pins the package and its SHA-256 hash. Meson installs `conpty.dll` and `OpenConsole.exe` into `data/conpty`.

The standalone runtime includes both files and their license. Keep both files together. Do not fall back to the system console host.

That host can drop Pi's mouse mode when Pi sets raw input during startup. A width change reflows wrapped lines differently in ConPTY and in the Terminal View, so their prompt rows can differ. ConPTY 1.25 and later then asks the terminal for the cursor position (DSR CPR) and moves its cursor there.

The editor answers. Do not go back to an earlier ConPTY. Typed input then appears above the visible prompt.

ConPTY asks only when the shell prints a prompt, not after a resize. A width change while a shell waits at its prompt can leave ConPTY one row away from the Terminal View. The next command line and its output then appear on the wrong row until the next prompt. A Controller handoff between Clients of different sizes causes two width changes, so shared Sessions show this more often. This is a known limitation. A fix needs Ghostty to reflow like ConPTY, or ConPTY to ask again after a resize. `ui/terminal_sessions.lua` checks that output arrives, not on which row.

Run `ui/terminal_mouse_wheel.lua`, `ui/terminal_resize_prompt.lua` and the standalone smoke test after ConPTY updates. The resize test has a known PSReadLine 2.4.5 failure. See [known test failures](../../tests/README.md#known-failures); keep it enabled.

Middle-click scrolling uses Terminal history when the active screen has history. With no history, it sends wheel input through the normal wheel route. Reaching a history boundary does not send application input.

Wheel input uses the original click position and keeps fractional movement between frames. Each frame sends a bounded number of events and discards excess whole ticks. Run `ui/middle_click_autoscroll.lua` and `ui/terminal_mouse_wheel.lua` after changes.

Use the `terminal-autoscroll-history` scenario to measure history scrolling.

Use Remote Point of Interest Source on a Terminal opens a frozen Terminal Text Capture as the Project's source. The command also accepts an existing Terminal Text Capture. Remote POI Navigation opens its file locations in the current Pane, without focusing the capture.

A worker finds paths and checks files. Relative paths use the Terminal's directory at capture time. Plain paths open at line 1; diagnostic locations keep their line and column.

Paths with spaces need quotes or backticks. New output does not change the capture. Run the source command on the live Terminal again to refresh it.

Run `ui/terminal.lua` after changes.

A Terminal Text Capture keeps the Terminal's OSC 8 links (`links` in `session:text_capture()`, one list for each line). Its links are these OSC 8 links, plain URLs, and the file locations that the worker finds when the capture opens. They do not overlap, in that order of priority.

A link shows the hand cursor, the hover background and its target, as in the Terminal View. A click opens it; a drag from it selects text. Point of Interest Activation opens the link at the caret, and Point of Interest navigation moves through all links.

Remote POI Navigation uses only the file locations. Run `ui/terminal.lua` and `runtime/terminal_native.lua` after changes.

## Startup and prepared sessions

New Terminal Sessions start their host and shell on a background thread. They return in the reconnecting state, like restored sessions. Wait for running before sending input or reading the host ID.

Startup copies the launch options and environment. Closing an unaccepted new session ends its shell, including during editor shutdown. A new host answers only after its shell starts, so a launch waits up to 30 seconds.

A stalled machine can take several seconds. A failed launch ends its host and deletes the record that the host wrote, so the Sidebar shows no lost copy. Run `ui/terminal_startup.lua` after startup changes.

Tests that need a live Terminal View use `tests/fixtures/terminal_ready.lua`.

Terminal and Pi preparation share one retention list: the last four eligible Projects visited, across Windows. Opening a new Terminal makes its loaded Project eligible for a Terminal spare. Opening a new Pi makes it eligible for a Pi spare.

Each type has its own eligibility and setting. Eligibility ends when the Project unloads; it is not saved. The visible Selected Project prepares each eligible spare after a short delay.

A hidden Project keeps its spares while it stays in the list. Revisiting an eligible Project starts preparation again if its spare is missing. Opening a matching terminal uses that shell, even while startup is in progress, then prepares a replacement.

Other launches use normal background startup. The shell command, starting directory, Project, scrollback limit, and environment must match. Unused prepared shells have no session record or saved screen.

They close when their Project leaves the retention list, unloads, or disables preparation. Eviction never closes a session that a Pane has taken. They also close when their client disconnects.

An activated shell keeps the normal detach and revival behavior. `config.plugins.terminal.prepare_session` controls preparation. It defaults to true and has a Terminal setting.

Preparation uses extra memory and runs the shell profile early. The shell owns the retention list and sends each Project its allowed spare types. Lua uses one lifecycle for both types.

Run `anvil:prepared-projects`, `anvil:hosted-routing`, `runtime/terminal_prepared.lua` and `ui/terminal_prepared.lua` after changes. New shells get their PATH from the Windows registry (system PATH, then user PATH), not from the Anvil process. A PATH change then reaches new Terminal Sessions without a restart.

A prepared shell with an older PATH is not used. Running shells keep their PATH. Run `runtime/terminal_path_environment.lua` after changes.

Copy View on a Pi Terminal opens a plain Terminal with the same directory and shell. It does not start Pi. `terminal:open_pi` starts `pi` in a new Terminal at the Project's folder, with a fresh conversation and Pi's normal defaults.

An eligible Project prepares one Pi with the same launch: the Project's folder and the configured shell. A new Pi uses the prepared Pi only when its directory, shell, Project, scrollback limit and launch environment match. Other new Pis start normally.

Normal Terminals never take a prepared Pi. The prepared Pi has no Terminal record or saved screen until a Pane takes it. Opening Pi takes its spare even while the shell or Pi starts.

It does not send the Pi command twice. Pi and plain Terminals never take each other's spares. An unused Pi must report idle within 30 seconds.

A failed preparation does not retry until its launch settings change or the Project becomes visible again. `config.plugins.terminal.prepare_pi` defaults to true and has a separate Terminal setting. It uses extra memory and runs Pi startup, including extensions, early.

Run `ui/terminal_pi_prepared.lua`, `ui/terminal_prepared.lua` and `runtime/terminal_prepared.lua` after changes.

## Busy state and shell modes

A Terminal Session is busy while its shell has a child process. A new shell is idle until its host reports busy state, so closing it during startup asks nothing. A session that attaches to an existing host counts as busy until that report, because a command can still run there.

An interactive PowerShell also runs `data/tools/shell-integration/anvil.ps1`. That script marks prompts and commands with OSC 133 and a per-session nonce. The host also reports a command that runs inside the shell, such as `Start-Sleep`, as busy.

It ignores marks without the nonce, so a nested shell or TUI cannot end a running command. Run the `Terminal busy status` tests in `ui/terminal_quit.lua` after changes.

The PowerShell prompt clears stale mouse, focus, paste, appearance report and extended keyboard modes after a crashed program. It sends control sequences through ConPTY before the custom prompt runs, and shows the cursor again. It keeps terminal text, scrollback and ConPTY's input mode.

It does not send a full terminal reset. Existing shells need a new Terminal Session to load the updated integration. Run `ui/terminal_stale_modes.lua` after changes.

## Controllers and Viewers

A Terminal host accepts up to 8 Clients. One Client is the Controller: it sets the size, sends input and answers terminal queries. The others are Viewers.

Viewers show the Controller's screen at its size. They send no query answers or mouse reports and get no clipboard writes. A desktop Terminal takes control when it gains keyboard focus. A Machine device with View access stays a Viewer. Typed input can also take control.

The client sends `TAKE` with the control generation that it saw last, then the input on the same pipe. The host refuses an old generation and drops a Viewer's input. After a grant or a resize, the host sends a `ROLE` record to each Client at that place in the output.

Each Client resizes its own screen there. A handoff sends no snapshot. A `ROLE` also counts the attached Clients.

The host sends one to the others when a Client attaches or leaves. The session status reports the count as `clients`. A CLOSE or END from one Client only detaches that Client while another Client is attached.

The last Client's close ends the shell. A control connection without a Client ID cannot end a shell while a Client is attached. New Clients request a connection ID in WELCOME.

Their final control CLOSE or END names that exact Client and its process, so a delayed disconnect cannot hide the last Close. Another Client in the same process stays attached. Older hosts reject the request flag; the Client then repeats the old handshake without an ID.

A saved host uses both its process ID and creation time. If Windows reuses the ID, revival keeps the saved Session and screen. For a process that denies access, the native system process list can prove that the creation time differs.

An identity that cannot be verified stays blocked. A failed Terminal without a native session still appears in agent workspace inspection. So Pane Close asks no question for a session that another device shows, and keeps no Reopen record for it.

When the Controller leaves, no other Client gets control until it asks. A Client on the host's own PC takes control when it attaches, if the Controller is also on this PC. A Pane move attaches before the old View's detach arrives, so the target still controls.

A background Pane does not take control from a remote Controller on attach. A Viewer whose 8 MiB queue is full is dropped. It attaches again with a snapshot, so it never stalls the Controller.

Hosts that write `shared = true` in their record accept more than one Client. Older hosts refuse a second Client and send no `ROLE`, so their one Client controls. The session status reports `viewer` and the Controller's device name.

`session:take_control()` takes control without input. Run `ui/terminal_sessions.lua`, `ui/pane_transfer.lua`, `runtime/machine_terminal.lua` and `ui/machine_terminal.lua` after changes.

## Close, End and Reopen

Pane Close skips confirmation when Pi reports `idle` or `done`, even while its shell command remains busy. Window Close asks once for its live Terminal Sessions, including idle shells and idle Pi. Keep running detaches them.

End all ends them but keeps their revival records. Cancel stops Window Close. An idle shell that only a Pane's Navigation History keeps does not count.

An accepted quit closes it and removes its history entry and record, so it does not restore. A history shell that is busy, starting or reconnecting, or that runs a program such as Pi, still counts. The shell shares the choice across that Window's Projects, not other Windows.

A later Window Close asks again. Project unload uses the Pane Close busy check. It ends idle shells, idle or finished Pi, and new shells without asking, and keeps revival records.

Shared sessions detach and keep running. Busy or reconnecting sessions still require a choice for all the Project's sessions. Direct mode asks each time.

An ended session is not closed. It revives in its Pane on the next start. The host gets `ANVIL_TERMINAL_END`.

It stops the shell, but keeps the record, the screen and the Pi report. The session keeps its ID, so its Snooze, seen time and Pi session stay. Older hosts read `END` as a disconnect and keep running.

Run `ui/terminal_quit.lua`, `ui/terminal_revival.lua` and `ui/terminal_agent_resume.lua` after changes. Pane Close keeps the normal busy check for other agent states. Reconnecting sessions still require confirmation.

The host sends the root Agent Status with its live status packet. Older hosts keep the normal busy check. Run `ui/terminal_quit.lua`, `ui/terminal_agent_status.lua`, and the `windows-close-terminals-keep` and `windows-close-terminals-end` shell probes after changes.

Pane Close ends each Terminal through the same End path when it saves the Pane for Reopen Closed Pane. A separate `terminal-sessions/<id>.closed` marker hides its retained record from session discovery and the Sidebar. Reopen removes the marker and restores the View through `from_state`, as Workspace restore does.

A Reopen during End waits on the attach worker for the old host to exit, then uses normal disk revival. The UI thread never waits. The Terminal keeps its ID and saved screen.

Pi resumes its saved conversation through normal revival. The record cleaner removes old closed records and their markers after 30 days. Run `ui/reopen_pane.lua`, `ui/terminal_revival.lua`, `ui/terminal_agent_resume.lua` and `anvil:sidebar-scan` after changes.

## Shell commands and Project moves

The PowerShell integration sets the Terminal title to the submitted command. The host records its start, finish, and exit status from the trusted OSC 133 marks. Without Agent Status, the Project Sidebar shows the command's elapsed time or completed duration.

Run `ui/terminal_command_status.lua` after changes. Existing hosts keep their loaded integration until their shells restart.

A bare `anvil` command from a focused Terminal triggers `editor:open` after its command ends. An `anvil <file> ...` command opens those files in new Panes in the same Project after its command ends. File paths resolve from the Terminal's current directory.

New files are supported. Launches with options, CLI commands, or directory arguments keep their normal behavior. The request uses the Terminal Session and its Project, even after its current directory changes.

The Terminal host confirms idle with a fresh probe before Lua runs the command. A cached idle status is not sufficient. The request does not change focus if another Pane or View has taken focus.

These rules apply only to a command at the prompt: the Terminal's shell starts the launcher, directly or through `anvil.com`. A program in the Terminal, such as a GUI app that opens a file with Anvil, gets a normal external launch. The Terminal's focus and busy state do not affect it.

New Terminal hosts set `ANVIL_TERMINAL_ID`, `ANVIL_TERMINAL_PROJECT` and `ANVIL_TERMINAL_HOST_PID`. Existing hosts need new Terminal Sessions for this feature. Their launches use the normal external launch.

Run `ui/terminal_editor_open.lua` and the `launch-terminal-editor` shell probe after changes.

A Pane with a running Terminal Session can move to another Project. The source detaches the session before the export. The target attaches it and sends `ANVIL_TERMINAL_PROJECT` to the host.

The host then saves the new Project in its record and screen file. The source releases its View only after the target confirms. A failed move attaches the session again in the source.

Only hosts that write `movable = true` in their record accept the message. Older hosts disconnect, so Lua refuses to move their sessions. The shell routes an `anvil` request to the Project whose Sidebar row lists the Terminal Session.

`ANVIL_TERMINAL_PROJECT` in the shell environment is the fallback. That fallback names the first Project, so a moved Terminal needs a Sidebar scan first. A hidden Sidebar does not scan.

Run `ui/pane_transfer.lua`, `ui/sidebar_view.lua` and the `launch-terminal-move` shell probe after changes.

## Revival and Windows shutdown

A revived Terminal Session types the interrupted command at its new prompt. It does not press Enter. The PowerShell integration sends the submitted line as `cmdline_url` in the OSC 133 C mark.

The host keeps that line in the record as `interrupted_input` until the command finishes. Without the integration, the host has no submitted line, and revival types nothing. Run `ui/terminal_revival.lua` after changes.

A revived Terminal Session resumes the Pi session that its Pi had open. Pi needs no change. The host loads `data/tools/agent-sessions/pi.cjs` into Node and Bun through `NODE_OPTIONS` and `BUN_OPTIONS`.

In Pi, the script writes `terminal-sessions/<id>.agent` with Pi's executable and the session file it writes. The record's `interrupted_pid` must match the report, so an old report cannot resume a different command. Both option parsers treat backslashes as escapes, and Bun has no quoting, so the host passes forward slashes and a short path to Bun.

Bun gets `--preload=<path>` so its `test` and `run` subcommands work. The host converts inherited space-form preload options to the same form. Existing Terminal hosts need new Terminal Sessions to get this change.

Run `ui/terminal_agent_resume.lua` after changes. It checks Bun scripts and subcommands, including inherited preloads. It also runs a fake Pi on Node and on Bun when they are installed. Compiled programs must also have the executable name `pi` or `pi.exe` before the preload checks their package.

Run `node --test tests/agent-sessions.test.cjs` to check compiled Pi and unrelated programs. It requires Bun.

Windows sign-out and shutdown are not normal Terminal exits. `src/session_end.c` receives the Windows messages on a separate thread through a hidden top-level window. Editors get an earlier shutdown priority than Terminal hosts; hosts get an earlier priority than ordinary shells.

`SM_SHUTTINGDOWN` also guards recovery. Restart Manager's application-only close does not freeze the Windows session state. The host keeps a separate recovery copy of the interrupted command, process ID, submitted input and validated Pi report.

Shutdown output can change live status, but cannot clear that copy. If Windows cancels sign-out after Pi ends, the copy stays until a live or new command replaces it. The Pi report must still match the saved process ID.

The record's `recovery_agent` holds that report beside its process ID. An empty field means no verified report. Only records without the field use the separate `.agent` file.

Each process probe checks for a changed conversation in the same Pi process. A failed record write retries while the host runs. A revived host loads this copy before its first record write.

`RESUME_AGENT` marks automatic resume input. The host keeps the copy until the new Pi reports its identity, a new command starts, or the resume ends normally. Another restart during startup can then resume the same conversation.

A revived shell that ends before a command of its own also keeps the copy. For example, a PowerShell Store update ends running `pwsh` processes when new shells start. The next revival, such as a Sidebar click, resumes Pi.

A Project permits one automatic host revival per Windows shutdown attempt, not an unlimited crash loop. A shell that ends during sign-out sends no ordinary EXITED record. Its Pane and Snooze stay.

After cancellation, its host ends without EXITED so the same View can revive. An editor also treats EXITED from an older host as an interruption while Windows ends the session. It starts no revival or prepared shell until cancellation.

Hosts keep their loaded native code across a dev update; existing hosts need an End and revival to get host changes. The notification thread checks whether the shell runs at query and cancellation. It remembers a shutdown death while the monitor stalls.

Windows can finish console termination after cancellation; its `0x40010004` status still protects that shell after a shutdown query. A normal exit after cancellation stays normal. Run `anvil:terminal-recovery`, `ui/terminal_signout.lua`, `ui/terminal_revival.lua` and `ui/terminal_agent_resume.lua` after changes.

The sign-out tests send Windows messages only to their own processes. They never sign out the user.

## Pi status and model icons

The host reads program status reports (OSC 7501) and keeps the Agent Status in the session record. A report can carry `since=<Unix seconds>` for a state that began earlier. A time in the future is ignored.

It sets `PI_PROGRAM_STATUS=1`, so Pi reports without a query. It also sets `PI_HYPERLINKS=1`, so Pi sends OSC 8 links and does not print each URL after its label. It sets `PI_IMAGE_PROTOCOL=kitty`, so Pi displays inline images without recognizing Anvil's terminal name.

A value that the user set stays in all three cases. Existing shells keep their environment. Open a new Terminal Session to get the image default.

Run `runtime/terminal_image_environment.lua` after changes to that default. In an interactive Pi, `pi.cjs` also adds `--extension` for `data/tools/agent-sessions/pi-status.cjs`. The extension only listens.

It reports Pi's current step as the `step` child record. It adds no tools, commands or session entries. `ANVIL_PI_STATUS=0` turns it off.

Pi subcommands, such as `pi update`, get no `--extension`, because they read it as a package to install. The extension uses `.cjs`, because a `package.json` with `"type": "module"` above it makes Node read `.js` as ESM. The host puts its preload first in `NODE_OPTIONS` and `BUN_OPTIONS`.

An Anvil that a Terminal Session started inherits the older preload, and the first preload claims Pi. Run `ui/terminal_agent_status.lua` and `ui/terminal_agent_resume.lua` after changes.

Terminal Tabs use the reported OSC 7501 `app` field to identify Pi. They do not infer the program from its title. Older running hosts need a new Terminal Session to report program identity.

Run `ui/terminal_icons.lua` and `ui/terminal_agent_status.lua` after icon or identity changes. The Pi extension also reports the selected model's display name, or its ID when no name exists. Model changes update the icon without a new agent turn.

GPT names use OpenAI's knot; Claude and Fable names use Claude's starburst. DeepSeek names use DeepSeek's whale. Name matching ignores case.

The icon stays while Pi is idle and ends when Pi ends. Unknown or missing models show Pi's icon. The extension reports the model again when terminal input resumes after a TUI pause, such as an SSH sudo prompt.

Show only one logo: the detected model provider or Pi as the fallback. Logos have transparent backgrounds. Run `ui/terminal_agent_resume.lua` after model-report changes.

It checks startup and model changes on Node and Bun.

## Keyboard, appearance and images

A Terminal View pairs each text key with its SDL text input. A text key has layout text and no Ctrl, Alt, or Super. The view encodes the key with the text that the OS typed, not SDL's keymap text.

Kitty mode then gets both. Run `runtime/terminal_native.lua` and `ui/terminal.lua` after key input changes.

A Terminal View reports light/dark appearance changes to programs that enable mode 2031. It sends the report after applying all new colors, so programs can query the new palette. After reconnecting, the Controller reports its current appearance once the saved screen and subscription are restored.

The program can still have colors from before the disconnect. A revived screen turns off the old program's report modes, including mode 2031, because the new shell did not ask for reports. Otherwise the report reaches the new prompt as typed text.

Run `runtime/terminal_native.lua` and `runtime/terminal_pi_appearance.lua` after changes. The Pi test uses a local scripted model and no inference. Set `ANVIL_TEST_PI` and `ANVIL_TEST_NODE` if Meson did not find them at configuration.

Terminal Views display static Kitty graphics through Ghostty's image API. Only direct image transfers are enabled. File and shared-memory transfers remain disabled.

The native bridge owns cropped image canvases and reuses them by image generation and source rectangle. Ghostty snapshots omit images, so programs must retransmit them after reconnect or restart. Run `runtime/terminal_graphics.lua` and the `terminal-images` render scenario after image changes.

See [inline terminal images](../../tools/TERMINAL_IMAGES.md) for supported features and limits.

## Agent control

`core.control` owns editor operations. `core.control_server` exposes them through authenticated loopback MCP. `core.control_runtime` publishes private discovery files and follows Terminal ownership.

Cross-Project discovery runs in a worker. It uses a Project's discovery file only while its process runs with the file's `pid` and `created` time (`system.process_state`). It deletes the files of ended processes, which a crash or a Windows shutdown leaves.

`src/process_identity.c` owns that check for Terminal hosts too. Do not move editor behavior into the transport or Pi extension.

Interactive Pi gets `data/tools/agent-sessions/pi-control.cjs` through the existing preload. It registers Anvil's MCP server and handles attributed messages, steering, interruption, and settled results. Pi remains a TUI.

Pi launches require explicit provider, model, and thinking choices.

`agent_send` steers active work or starts a turn when Pi is idle. Steering does not cancel running tools. An idle start has a task result.

Steering reports delivery and names the active Anvil task when one exists.

`agent_transcript` reads the current Pi branch through bounded, read-only exchange requests. `pi-inspection.cjs` extracts text and tracks live activity without starting model turns or writing session entries. History pages use entry IDs; truncated messages use UTF-16 offsets.

Reads give compact text by default, which the MCP reply sends without JSON escaping; `format: "json"` gives fields. Thinking text appears only with `include_thinking`. System prompts stay excluded.

Reads may omit `instance` and then use the Terminal's current conversation; sends and interrupts require it. `agent_read` reports parallel tools, start times, observation freshness, and the session file. Active tool calls are not a background process registry.

Keep empty protocol arrays as arrays through local and cross-Project responses.

Keep focus by default. A `pane` or `terminal` close request approves only the calling agent's own running Terminal Session, identified by its credential. Other Views and reconnecting sessions keep normal close checks.

Self-close can stop the agent before the reply arrives. Use stable Pane, Terminal, and conversation IDs, not navigation numbers. A wait timeout never cancels a task.

Retry keys last for the Project process; Pi persists accepted delivery receipts separately.

The `snooze` control tool sets or removes a Terminal's Snooze. Without a target, it uses the calling agent's Terminal Session. The Sidebar owns the saved times.

Requests use the shell's Sidebar route, then normal Project Snooze requests. A reply reports acceptance, not completed delivery. Run `ui/agent_control.lua` and the `terminal-focus` shell probe after changes.

The `project` tool opens or unloads a Project in the caller's Window. Open sends `system.load_project`: the shell starts the Project and the Window keeps its Selected Project. `focus: true` selects the Project instead.

Unload keeps the normal close questions. It refuses Scratch and the Project that serves the call. `pane` move with `target_project` exports the Pane through `core.pane_transfer`.

An export detaches the Pane's Terminals, so the transport first checks that the target has a control endpoint. Without focus, the import goes through the direct route, and the target stays unselected. A background Project has no first frame, so the shell keeps it Starting.

The direct route also delivers to a Starting Project whose runtime is ready. Run `ui/agent_control.lua`, `ui/pane_transfer.lua` and the `agent-projects` and `launch-terminal-move` shell probes after changes.

The `diff_open` tool opens a Commit Diff View of a revision range (`git_view.open_diff`) with Diff Notes. The notes go in the Diff View request beside the patch, never inside it, so the patch stays valid. The Git tab keeps them by file path and saves them in its state.

`plugins.diff.notes` places each note's card below its range in both layouts, keeps the other side level with a spacer row, and keeps noted lines out of folds. Range markers move the notes with edits. `core.markdown.note_card` draws the card for both Footnotes and Diff Notes.

Run `ui/diffview_notes.lua`, `ui/agent_control.lua`, `ui/markdown_footnotes.lua` and `runtime/git_view_model.lua` after changes. Check the `markdown-footnotes*` render scenarios after changes to the card.

`code_open` opens a Code Tour (`core.code_tour`) of editable file ranges with optional notes. The list and Point of Interest navigation follow the supplied order across files. Each file uses its real Buffer, including unsaved edits.

The Tour's Editors fold gaps between the ranges and share the Diff Note card renderer. Their folds and notes do not affect other Editors of the same Buffer. New Buffers load through the file worker.

A failed load opens no Pane. Workspace state keeps paths, line ranges, notes and the selected entry. Removed ranges stay marked and navigation skips them.

Run `ui/code_tour.lua` after changes. Check the `code-tour` render scenario after visual changes.

See [agent control](../agent-control.md) for tools, discovery, security, and limits. Run `runtime/net_server.lua`, `ui/agent_control.lua`, `ui/control_transport.lua`, and `ui/control_pi.lua` after changes. Also run `node --test tests/pi-control.test.cjs tests/agent-sessions.test.cjs`.

`ui/control_pi.lua` runs real Pi TUI sessions against a local scripted model server. It uses no provider, API key, or inference. Keep these checks isolated from user sessions and settings.
