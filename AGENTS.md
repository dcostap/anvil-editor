# Anvil editor development notes

This repository is the source for the personal Anvil editor fork.

## Layout

- Source repo: any folder, for example `D:\Projects\c_projects\anvil-editor`
- Dev portable app: `anvil-portable` beside the repo, for example `D:\Projects\c_projects\anvil-portable`
- Build dir: `build-windows-x86_64` in the repo
- Source built-in plugins: `data\plugins`
- Source core Lua: `data\core`

## Build outputs

Compiling produces binaries in:

- `build-windows-x86_64\src\anvil.exe`
- `build-windows-x86_64\src\anvil.com`

These build-directory binaries retain native debug information. The dev
portable app strips its executable so it starts quickly.

Dev builds load Lua/data files beside the exe. A runnable dev app is produced by `meson install` into `..\anvil-portable`.

## Standalone Windows release

Run `build.bat` to create and test `dist\anvil.exe`. This is the build for other users.
`scripts\msys2-env.cmd` finds MSYS2 at `MSYS2_ROOT` or `C:\msys64`. It installs MSYS2 with winget when it is missing.
It installs missing build packages with pacman. All BAT files use it, so none of them hardcode a folder.

The release exe contains a compressed copy of the runtime data. On first run,
it extracts that data to `%LOCALAPPDATA%\Anvil\runtime\<build-id>\data`.
Later runs reuse the same complete runtime. Users only distribute `anvil.exe`.
The standalone build runs `tests\gui\smoke\standalone-runtime-test.ps1`.

Keep the dev build external-data workflow. Do not embed source data in the
dev portable app's executable. The standalone build uses its own
`build-windows-x86_64-standalone` directory.

The standalone build needs MSYS2, MinGW64 GCC, Ninja, CMake, Python, Meson,
and Zig. `scripts\ensure-zig.sh` downloads the pinned Zig release into
`%LOCALAPPDATA%\anvil-build-tools` when it is missing. The build needs network
access for this download and for Meson subprojects on a clean machine.
Zig's own HTTP and Git clients fail on some Windows machines. `subprojects/packagefiles/ghostty/build-vt.sh` then gets each missing Ghostty dependency with curl or git and gives Zig the unpacked folder.

Windows Terminal Sessions use bundled Microsoft ConPTY, not the system console host.
`subprojects/conpty.wrap` pins the package and its SHA-256 hash.
Meson installs `conpty.dll` and `OpenConsole.exe` into `data/conpty`.
The standalone runtime includes both files and their license.
Keep both files together. Do not fall back to the system console host.
That host can drop Pi's mouse mode when Pi sets raw input during startup.
A width change reflows wrapped lines differently in ConPTY and in the Terminal View, so their prompt rows can differ.
ConPTY 1.25 and later then asks the terminal for the cursor position (DSR CPR) and moves its cursor there. The editor answers.
Do not go back to an earlier ConPTY. Typed input then appears above the visible prompt.
Run `ui/terminal_mouse_wheel.lua`, `ui/terminal_resize_prompt.lua` and the standalone smoke test after ConPTY updates.
The resize test has a known PSReadLine 2.4.5 failure. See [known test failures](tests/README.md#known-failures); keep it enabled.

Middle-click scrolling uses Terminal history when the active screen has history. With no history, it sends wheel input through the normal wheel route. Reaching a history boundary does not send application input. Wheel input uses the original click position and keeps fractional movement between frames. Each frame sends a bounded number of events and discards excess whole ticks. Run `ui/middle_click_autoscroll.lua` and `ui/terminal_mouse_wheel.lua` after changes. Use the `terminal-autoscroll-history` scenario to measure history scrolling.

Use Remote Point of Interest Source on a Terminal opens a frozen Terminal Text Capture as the Project's source. The command also accepts an existing Terminal Text Capture. Remote POI Navigation opens its file locations in the current Pane, without focusing the capture. A worker finds paths and checks files. Relative paths use the Terminal's directory at capture time. Plain paths open at line 1; diagnostic locations keep their line and column. Paths with spaces need quotes or backticks. New output does not change the capture. Run the source command on the live Terminal again to refresh it. Run `ui/terminal.lua` after changes.

New Terminal Sessions start their host and shell on a background thread.
They return in the reconnecting state, like restored sessions. Wait for running before sending input or reading the host ID.
Startup copies the launch options and environment. Closing an unaccepted new session ends its shell, including during editor shutdown.
A new host answers only after its shell starts, so a launch waits up to 30 seconds. A stalled machine can take several seconds.
A failed launch ends its host and deletes the record that the host wrote, so the Sidebar shows no lost copy.
Run `ui/terminal_startup.lua` after startup changes. Tests that need a live Terminal View use `tests/fixtures/terminal_ready.lua`.

The visible Selected Project prepares one unused Terminal Session after a short delay.
Opening a matching terminal uses that shell, then prepares a replacement. Other launches use normal background startup.
The shell command, starting directory, Project, scrollback limit, and environment must match.
Unused prepared shells have no session record or saved screen. They close when their Project becomes hidden or closes.
They also close when their client disconnects. An activated shell keeps the normal detach and revival behavior.
`config.plugins.terminal.prepare_session` controls preparation. It defaults to true and has a Terminal setting.
Preparation uses extra memory and runs the shell profile early.
Run `runtime/terminal_prepared.lua` and `ui/terminal_prepared.lua` after changes.
New shells get their PATH from the Windows registry (system PATH, then user PATH), not from the Anvil process. A PATH change then reaches new Terminal Sessions without a restart. A prepared shell with an older PATH is not used. Running shells keep their PATH. Run `runtime/terminal_path_environment.lua` after changes.

Copy View on a running Pi Terminal starts `pi` in a new Terminal with the same directory and shell. It starts a fresh conversation with Pi's normal defaults, not the source conversation or its command arguments.
The visible Selected Project also prepares one Pi while at least one of its Panes runs Pi. The focused Pi supplies the directory and shell. Other Views keep the last Pi's choice while that Pi runs.
A copy uses the prepared Pi only when its directory, shell, Project, scrollback limit and launch environment match. Other copies start normally. Normal Terminals never take a prepared Pi.
The prepared Pi has no Terminal record or saved screen until a Pane takes it. It closes when its Project becomes hidden, its last Pi ends, or preparation is disabled. Startup must report Pi idle within 30 seconds. A failed preparation does not retry until its launch settings change or the Project becomes visible again.
`config.plugins.terminal.prepare_pi` defaults to true and has a separate Terminal setting. It runs Pi startup, including extensions, early. It does not copy live model or thinking changes from the source Pi.
Run `ui/terminal_pi_prepared.lua`, `ui/terminal_prepared.lua` and `runtime/terminal_prepared.lua` after changes.

A Terminal Session is busy while its shell has a child process.
A new shell is idle until its host reports busy state, so closing it during startup asks nothing.
A session that attaches to an existing host counts as busy until that report, because a command can still run there.
An interactive PowerShell also runs `data/tools/shell-integration/anvil.ps1`.
That script marks prompts and commands with OSC 133 and a per-session nonce.
The host also reports a command that runs inside the shell, such as `Start-Sleep`, as busy.
It ignores marks without the nonce, so a nested shell or TUI cannot end a running command.
Run the `Terminal busy status` tests in `ui/terminal_quit.lua` after changes.

The PowerShell prompt clears stale mouse, focus, paste and extended keyboard modes after a crashed program.
It sends control sequences through ConPTY before the custom prompt runs, and shows the cursor again.
It keeps terminal text, scrollback and ConPTY's input mode. It does not send a full terminal reset.
Existing shells need a new Terminal Session to load the updated integration.
Run `ui/terminal_stale_modes.lua` after changes.

A Terminal host accepts up to 8 Clients. One Client is the Controller: it sets the size, sends input and answers terminal queries. The others are Viewers.
Viewers show the Controller's screen at its size. They send no query answers, focus reports or mouse reports, and get no clipboard writes.
Typed input in a Viewer takes control. The client sends `TAKE` with the control generation that it saw last, then the input on the same pipe. The host refuses an old generation and drops a Viewer's input.
After a grant or a resize, the host sends a `ROLE` record to each Client at that place in the output. Each Client resizes its own screen there. A handoff sends no snapshot.
A `ROLE` also counts the attached Clients. The host sends one to the others when a Client attaches or leaves. The session status reports the count as `clients`.
A CLOSE or END from one Client only detaches that Client while another Client is attached. The last Client's close ends the shell. A control connection's CLOSE or END does nothing while a Client is attached.
So Pane Close asks no question for a session that another device shows, and keeps no Reopen record for it. When the Controller leaves, no other Client gets control until it asks.
A Client on the host's own PC takes control when it attaches, if the Controller is also on this PC. A Pane move attaches before the old View's detach arrives, so the target still controls. A remote Controller keeps control.
A Viewer whose 8 MiB queue is full is dropped. It attaches again with a snapshot, so it never stalls the Controller.
Hosts that write `shared = true` in their record accept more than one Client. Older hosts refuse a second Client and send no `ROLE`, so their one Client controls.
The session status reports `viewer` and the Controller's device name. `session:take_control()` takes control without input.
Run `ui/terminal_sessions.lua`, `ui/pane_transfer.lua`, `runtime/machine_terminal.lua` and `ui/machine_terminal.lua` after changes.

Pane Close skips confirmation when Pi reports `idle` or `done`, even while its shell command remains busy.
Window Close asks once for its live Terminal Sessions, including idle shells and idle Pi.
Keep running detaches them. End all ends them but keeps their revival records. Cancel stops Window Close.
An idle shell that only a Pane's Navigation History keeps does not count. An accepted quit closes it and removes its history entry and record, so it does not restore.
A history shell that is busy, starting or reconnecting, or that runs a program such as Pi, still counts.
The shell shares the choice across that Window's Projects, not other Windows. A later Window Close asks again.
Project unload and direct mode ask each time.
An ended session is not closed. It revives in its Pane on the next start.
The host gets `ANVIL_TERMINAL_END`. It stops the shell, but keeps the record, the screen and the Pi report.
The session keeps its ID, so its Snooze, seen time and Pi session stay.
Older hosts read `END` as a disconnect and keep running. Run `ui/terminal_quit.lua`, `ui/terminal_revival.lua` and `ui/terminal_agent_resume.lua` after changes.
Pane Close keeps the normal busy check for other agent states. Reconnecting sessions still require confirmation.
The host sends the root Agent Status with its live status packet. Older hosts keep the normal busy check.
Run `ui/terminal_quit.lua`, `ui/terminal_agent_status.lua`, and the `windows-close-terminals-keep` and `windows-close-terminals-end` shell probes after changes.

Pane Close ends each Terminal through the same End path when it saves the Pane for Reopen Closed Pane.
A separate `terminal-sessions/<id>.closed` marker hides its retained record from session discovery and the Sidebar.
Reopen removes the marker and restores the View through `from_state`, as Workspace restore does.
A Reopen during End waits on the attach worker for the old host to exit, then uses normal disk revival.
The UI thread never waits.
The Terminal keeps its ID and saved screen. Pi resumes its saved conversation through normal revival.
The record cleaner removes old closed records and their markers after 30 days.
Run `ui/reopen_pane.lua`, `ui/terminal_revival.lua`, `ui/terminal_agent_resume.lua` and `anvil:sidebar-scan` after changes.

The PowerShell integration sets the Terminal title to the submitted command.
The host records its start, finish, and exit status from the trusted OSC 133 marks.
Without Agent Status, the Project Sidebar shows the command's elapsed time or completed duration.
Run `ui/terminal_command_status.lua` after changes. Existing hosts keep their loaded integration until their shells restart.

A bare `anvil` command from a focused Terminal triggers `editor:open` after its command ends.
An `anvil <file> ...` command opens those files in new Panes in the same Project after its command ends.
File paths resolve from the Terminal's current directory. New files are supported.
Launches with options, CLI commands, or directory arguments keep their normal behavior.
The request uses the Terminal Session and its Project, even after its current directory changes.
The Terminal host confirms idle with a fresh probe before Lua runs the command. A cached idle status is not sufficient.
The request does not change focus if another Pane or View has taken focus.
New Terminal hosts set `ANVIL_TERMINAL_ID` and `ANVIL_TERMINAL_PROJECT`. Existing hosts need new Terminal Sessions for this feature.
Run `ui/terminal_editor_open.lua` and the `launch-terminal-editor` shell probe after changes.

A Pane with a running Terminal Session can move to another Project. The source detaches the session before the export.
The target attaches it and sends `ANVIL_TERMINAL_PROJECT` to the host. The host then saves the new Project in its record and screen file.
The source releases its View only after the target confirms. A failed move attaches the session again in the source.
Only hosts that write `movable = true` in their record accept the message. Older hosts disconnect, so Lua refuses to move their sessions.
The shell routes an `anvil` request to the Project whose Sidebar row lists the Terminal Session. `ANVIL_TERMINAL_PROJECT` in the shell environment is the fallback.
That fallback names the first Project, so a moved Terminal needs a Sidebar scan first. A hidden Sidebar does not scan.
Run `ui/pane_transfer.lua`, `ui/sidebar_view.lua` and the `launch-terminal-move` shell probe after changes.

A revived Terminal Session types the interrupted command at its new prompt. It does not press Enter.
The PowerShell integration sends the submitted line as `cmdline_url` in the OSC 133 C mark.
The host keeps that line in the record as `interrupted_input` until the command finishes.
Without the integration, the host has no submitted line, and revival types nothing.
Run `ui/terminal_revival.lua` after changes.

A revived Terminal Session resumes the Pi session that its Pi had open. Pi needs no change.
The host loads `data/tools/agent-sessions/pi.cjs` into Node and Bun through `NODE_OPTIONS` and `BUN_OPTIONS`.
In Pi, the script writes `terminal-sessions/<id>.agent` with Pi's executable and the session file it writes.
The record's `interrupted_pid` must match the report, so an old report cannot resume a different command.
Both option parsers treat backslashes as escapes, and Bun has no quoting, so the host passes forward slashes and a short path to Bun.
Run `ui/terminal_agent_resume.lua` after changes. It runs a fake Pi on Node and on Bun when they are installed.
Compiled programs must also have the executable name `pi` or `pi.exe` before the preload checks their package.
Run `node --test tests/agent-sessions.test.cjs` to check compiled Pi and unrelated programs. It requires Bun.

The host reads program status reports (OSC 7501) and keeps the Agent Status in the session record.
A report can carry `since=<Unix seconds>` for a state that began earlier. A time in the future is ignored.
It sets `PI_PROGRAM_STATUS=1`, so Pi reports without a query.
It also sets `PI_HYPERLINKS=1`, so Pi sends OSC 8 links and does not print each URL after its label.
It sets `PI_IMAGE_PROTOCOL=kitty`, so Pi displays inline images without recognizing Anvil's terminal name.
A value that the user set stays in all three cases.
Existing shells keep their environment. Open a new Terminal Session to get the image default.
Run `runtime/terminal_image_environment.lua` after changes to that default.
In an interactive Pi, `pi.cjs` also adds `--extension` for `data/tools/agent-sessions/pi-status.cjs`.
The extension only listens. It reports Pi's current step as the `step` child record.
It adds no tools, commands or session entries. `ANVIL_PI_STATUS=0` turns it off.
Pi subcommands, such as `pi update`, get no `--extension`, because they read it as a package to install.
The extension uses `.cjs`, because a `package.json` with `"type": "module"` above it makes Node read `.js` as ESM.
The host puts its preload first in `NODE_OPTIONS` and `BUN_OPTIONS`.
An Anvil that a Terminal Session started inherits the older preload, and the first preload claims Pi.
Run `ui/terminal_agent_status.lua` and `ui/terminal_agent_resume.lua` after changes.

Terminal Tabs use the reported OSC 7501 `app` field to identify Pi.
They do not infer the program from its title. Older running hosts need a new Terminal Session to report program identity.
Run `ui/terminal_icons.lua` and `ui/terminal_agent_status.lua` after icon or identity changes.
The Pi extension also reports the selected model's display name, or its ID when no name exists.
Model changes update the icon without a new agent turn. GPT names use OpenAI's knot; Claude and Fable names use Claude's starburst.
DeepSeek names use DeepSeek's whale. Name matching ignores case.
The icon stays while Pi is idle and ends when Pi ends. Unknown or missing models show Pi's icon.
The extension reports the model again when terminal input resumes after a TUI pause, such as an SSH sudo prompt.
Show only one logo: the detected model provider or Pi as the fallback. Logos have transparent backgrounds.
Run `ui/terminal_agent_resume.lua` after model-report changes. It checks startup and model changes on Node and Bun.

A Terminal without that icon shows the Terminal View's icon. Terminal Tabs have no status dot.
The Project Sidebar marks only an Unread Result or an agent that waits for an answer.
The mark is a dot, a bold name, and a coloured stripe that fades out to the right.
It saves when the user last looked at each Terminal Session. Run `ui/sidebar_view.lua` after changes.

A right-click on a Sidebar row opens its Context Menu. The Context Menu key opens the cursor row's menu.
The Sidebar draws it with `core.context_menu`, the same menu as in the editor. Its items are `sidebar:` commands.
The Sidebar surface covers the whole Window. Its strip ends at `content_x`, so a menu can extend over the Project.
The Sidebar reports the menu's rectangles as raised areas. The shell draws them above the Project.
While they show, the shell sends all pointer and keyboard input to the Sidebar.
Project rows offer New Terminal, New Pi, Move, Unload or Open in New Window, Copy Path and Show in File Explorer. A loaded Project also offers Reopen Closed Pane.
The Scratch Project offers only New Terminal, New Pi and Reopen Closed Pane. The Sidebar does not unload it.
Tabs offer Duplicate and Close. Terminal Tabs also offer Snooze, and Mark as Read for an Unread Result.
New items, Reopen, Duplicate and Close go through the select route, so the user sees the result or a close question.
The `perform` Pane request runs a named command in its Pane, or in the Project. A View that it opens takes a new Pane.
Run `ui/sidebar_view.lua`, `ui/context_menu.lua` and the `project-menu`, `project-menu-background`, `terminal-focus` and `windows-move` shell probes after changes.

A right-click on a Terminal Tab in the Sidebar sets or removes a Snooze.
The Sidebar saves each Snooze as a Unix time in `storage/sidebar/snoozes`, beside the seen times.
`tab.attention` holds a Terminal's attention until that time. The Sidebar wakes at the next Snooze time.
A Snooze whose time has not come stays saved, even when the model does not list its Terminal Session.
The Sidebar then sends `snooze` or `unsnooze` to the Pane's Project through the direct route.
The Project moves a Snoozed Pane into its own Pane Group with the `snoozed` flag, saved in the Workspace.
Pane navigation, Pane numbers, the Title Bar and the close fallback skip it. A focus request still shows it.
The Pane report marks it, and the Sidebar lists it in the collapsed Snoozed fold at the end of its Project.
The fold shows the mark of a Snoozed Pane that needs the user, also in a collapsed Project.
Collapsed Projects and Dormant Projects show a coloured count of Terminals that need the user. Collapsed age groups show their total.
A Pi question counts during a Snooze. Other attention stays hidden until the Snooze ends.
Each Project checks the saved times every 5 seconds (`core.snoozed_panes`). It does not change focus.
Due Panes wake into new Pane Groups at the end, at most three side by side, oldest Snooze first. A shown Pane wakes in place.
Run `ui/snoozed_panes.lua`, `ui/sidebar_view.lua`, `ui/pending_panes.lua` and the `terminal-focus` shell probe after changes.

Tabs show shared Pane numbers, not Tab positions. `core.numbered_panes` selects `core.pending_panes`.
Unread Results and agents waiting for an answer get numbers 1 to 5, oldest pending event first.
The Sidebar passes its shared seen times. Projects read the persisted seen times with a short cache.
Recent Panes fill unused numbers after Pending Panes, without duplicates. The current Pane gets no focus-history slot.
`core.recent_panes` supplies the focus history. There is no numbering setting.
Each Project stamps its active Pane when the Pane takes keyboard focus. The Pane report sends the stamps.
A Pane that loses focus within 1 second, without typed text, gets its previous stamp again (`recent_panes.VISIT`).
So a Pane cycle, or a Project's old Pane in the frame before a Pane request, adds no Recent Pane.
A Project fetches the reports when it takes keyboard focus. Focus-history numbering ranks these stamps across Projects.
The shell also notifies each Window's Selected Project when the Sidebar model changes.
Selected Projects fetch the changed state, so Pending Pane commands work without a keyboard focus change.
`system.get_time()` reads one clock for all processes, so stamps from different Projects compare.
A Title Bar in a Window without focus can show old numbers until its Window takes focus.
Run `ui/pending_panes.lua`, `ui/recent_panes.lua`, `ui/titlebar.lua` and `ui/sidebar_view.lua` after changes.

The Sidebar process has no Buffer or Text View. Its search field uses `core.line_input`.
The Sidebar reads the user's bindings for the editor's line commands, such as `core:select_to_start_of_indentation`.
The Sidebar keeps list navigation, search-field editing, Sidebar focus, and Numbered Panes.
Copy (`core:copy`'s keys) copies the cursor row's name: a file Tab's path as File Search shows it, absolute outside the Project Paths, a Terminal's shown title, or a Project's path. The search field's copy goes first while it has a query.
It sends each other key with Ctrl or Alt, and each function key, to the cursor row's Pane, or else to its Project.
A row without a Project sends the key to the Selected Project. Do not add Sidebar copies of editor commands.
A sent key gives the keyboard to the Project. The keys of Close Pane, Close Others and Reopen Closed Pane keep it in the Sidebar.
The Project takes it when such a key asks a question, such as a close of an unsaved file.
A Snooze hours field opened from the focused Sidebar keeps the keyboard there when it closes.
A Move of the Selected Project to another Window keeps the source Window's focused Sidebar, as an unload does. A Close choice takes the keyboard from the Sidebar.
Run the `windows-move` and `windows-move-close` shell probes after changes to these rules.
Run `ui/sidebar_view.lua` and `ui/sidebar_navigation.lua` after changes.

Path Search lists Projects from the Project Sidebar model: Scratch, loaded Projects, then Dormant Projects by age.
`core.project_look` draws a Project's name, badge and note for both, so a Project looks the same in each.
Run `ui/fuzzy_searcher_path_search.lua` and `ui/sidebar_view.lua` after changes.

The Fuzzy Searcher shows this Project's badge and name at the left of the query, with the same `core.project_look`.
Path Search searches beyond this Project, so it does not show it. Pickers with their own list, such as the file picker, do not show it either. Run `ui/fuzzy_searcher_project_chip.lua` after changes.

Project File Search and Text Search also show Other Project Results. Each query goes to the other ready Projects as a `project_search` Pane request.
Its `mode` is `files` or `text`. A path or line number in a Text Search query keeps the search in this Project.
Each Project searches itself and answers with up to 20 rows in a `project_results` request. `more = true` tells that more rows match. A Project that cannot search, or has no match, does not answer.
This Project's rows come first and are never cut. Each other group shows all its rows. It ends with a More row when its Project has more rows.
A More row sends `search` with the same query through the select route.
Without other rows, this Project's list is not cut.
File Search uses the Project's file index. Text Search runs ripgrep in the Project's roots and searches its Terminal Sessions.
A Terminal row carries the lines near its match for the preview, at most 4 KB.
The picker ignores answers to an earlier query. Opening a file row sends `open_file` to its Project through the select route. A Terminal row sends `terminal_find`.
Open in File Tree on a file row sends `open_file` with `filetree = true`. That Project shows the file in its own File Tree. Show in Explorer refuses a file on a Machine, because Explorer shows only this PC's folders.
This Project's "No matches" status is hidden while other Projects show rows.
Run `ui/fuzzy_searcher_other_projects.lua`, `ui/fuzzy_searcher_terminals.lua` and the `launch-file-search` shell probe after changes. The probe reports the answer times of both modes.
Each group has a divider and a small, dim header. Check the `fuzzy-picker-other-projects` and `fuzzy-picker-other-text` render scenarios after visual changes.

File Search shows all its rows at once. Paged lists load the next page one screen before their end. A refresh keeps the selected row.
Each non-empty query keeps a Saved Screen: its rows down to the bottom of the screen and its selected row. The picker saves it at close and when the prompt history moves away from the query, but not while a search runs, because its rows can belong to the previous query. It keeps the newest 50 in memory. An empty File Search starts at its first row.
A picker that opens a query with a Saved Screen, or that the prompt history moves to, shows that screen in its first frame. It does not wait for the search.
While the Saved Screen shows, searches keep their rows back (`holds_saved_screen`). Their last rows replace it, and `restore_position` selects the saved row at its place on the screen. Text Search keeps the found rows of the Saved Screen first, in their order, as rows that the user saw.
A move during the Saved Screen changes the row that the restore selects. Pages do not load until the search ends.
A typed path that does not exist gets a Create Path Result at the top. It is not the default selection: the next row is, if one exists (`skip_create_path_row`). The user selects it with a move, and a refresh keeps that choice.
Each typed character makes a new path, which a worker reads. While the top row is a Create Path Result, the new path's Create Path Result takes its place during the read, so the rows do not move. The read's result then replaces it. Enter during the read reads the path first, so it never creates an existing path. Run `ui/fuzzy_searcher_path_search.lua` after changes.
Each query makes new rows. A row's size and edited time come from a worker, which remembers the last answer for each path (`fuzzy_searcher.file_infos`). A new row of the same file shows that answer at once, and the worker reads the file again.
Run `ui/fuzzy_searcher_scrolling.lua` after changes.

Text Search also searches the Terminal Sessions of this Project. Other Projects search their own Terminals.
A Terminal that this Project shows gives its live text. Other Terminals give the screen that their host saved last.
That screen can be up to about 20 seconds old. A worker reads it (`terminal_snapshot_text`).
Terminal lines rank with file lines. On equal scores, the file line goes first. A path or line number in the query skips Terminals.
Confirm shows the Terminal and opens its find card at the line. Another Project gets a `terminal_find` Pane request.
Run `ui/fuzzy_searcher_terminals.lua` after changes.

The standalone option is `-Dembedded_runtime=true`. It is off by default.
`scripts\build-standalone-windows.sh` enables it, strips the executable, runs
the standalone smoke test, and promotes the result only after the test passes.

The Windows runtime excludes source artwork, platform app icons, icon compiler inputs, and the unused `fd.exe`. Keep these files in the source tree. Runtime UI icons, fonts, licenses, and `rg.exe` stay packaged. Run `anvil:embedded-runtime` after packaging changes.

### GitHub releases

The only active GitHub workflow is `.github\workflows\release.yml`. It builds
one Windows x86_64 standalone executable and uploads `dist\anvil.exe` to a
GitHub Release. A tag that starts with `v` starts the workflow:

```sh
git tag -a v1.0.1 -m "Anvil 1.0.1"
git push origin master
git push origin v1.0.1
```

Versions use `MAJOR.MINOR.PATCH`. Set the version in `meson.build` before you tag.
The plugin API version (`mod_version` in `meson.build`) is separate. Plugins declare it in their
`mod-version` header. Change it only when the plugin API changes.

The workflow also supports manual dispatch. Pass an existing release tag when
you retry a build. Do not commit release executables; `*.exe` is ignored.

The workflow uses the same standalone script as the local build. Keep these
paths and the smoke test aligned when changing release packaging. The release
asset is unsigned, so Windows SmartScreen can show a warning.

### Release updates

Windows standalone builds check `dcostap/anvil-editor` for a newer stable GitHub release. `updater:check` opens the Updates Dialog. Background checks share a daily cache across Projects. `config.plugins.updater.check_automatically` controls them.
The Dialog offers Update and Restart. Development builds and direct mode do not install release updates.
The release needs an uploaded `anvil.exe` and its GitHub SHA-256 digest. The updater checks its size and digest before asking Anvil to close. HTTPS and the GitHub repository are the trust boundary; the digest is not a publisher signature.
The bundled `data/tools/updater.ps1` starts through Windows Explorer, outside the caller's process group. It uses `--prepare-update` to save Workspaces and detach Terminal Sessions. It never force-closes the editor. A refused or timed-out close leaves the executable unchanged.
The helper takes a per-executable file lock, downloads beside the executable, and keeps the previous executable in `<executable>.updates`. Locked previous images belong to running Terminal hosts and stay there. Extracted runtime folders stay because old hosts can still use their files.
A replacement or immediate startup failure restores the previous executable and starts it again. This is not a health check for later crashes. Requests, progress, and logs stay under `USERDIR/updates`. A recovery error appears after restart.
The release workflow checks out the requested tag and rejects an asset whose build version differs from that tag.
Run `runtime/update_release.lua`, `ui/updater.lua`, `anvil:release-update` and `anvil:release-update-launch` after changes. Tests use private executables and a fake download, not the installed editor. Check the `update-dialog` render scenario after visual changes.

The native Project symbol index accepts a bounded explicit path list. A very
large Project can exceed that bound. The editor reports the submission error
and stays open, but it does not index that complete Project.

## App logo and icons

The source artwork is `resources\icons\logo-source.png`.
To replace the app logo:

1. Replace `resources\icons\logo-source.png` with the new PNG.
2. Run this command from the repo root:

   ```sh
   python tools/update_anvil_icon.py
   ```

3. Check the generated icons at small sizes on light and dark backgrounds.
4. Run `update-anvil-dev-build.bat` to rebuild, install, and restart the dev portable app.

The generator needs Python and Pillow. It crops transparent outer padding and adds no inset.
It updates the Linux PNG, Windows ICO, macOS ICNS, and native window icon.
Linux packages use the generated PNG.
Do not edit generated icons separately. Commit the source PNG and all generated files together.
Normal builds use these files and do not need the generator's tools.
Keep the Windows resource dependency on `resources\icons\icon.ico` in `src\meson.build`.
This dependency makes ICO changes rebuild the executable's icon resource.
Toolbar and file-type icons are separate from the app logo.

## Dev portable workflow

Use the BAT files in the repo root
- `setup-anvil-dev.bat`
  - first-time setup
  - builds the editor
  - installs the dev portable app to `..\anvil-portable`
  - creates Windows junctions for editable data directories, including `data\core`, `data\plugins`, `data\colors`, and `data\widget`
  - launches the app

- `update-anvil-dev-build.bat`
  - default finalization step only when non-Lua files were edited
  - use after C/C++, build-system, asset, or other non-Lua source/default-data changes so the dev portable app is refreshed consistently
  - skip for edits under junctioned data directories; reload or restart Anvil instead
  - rebuilds and updates the dev portable app
  - restores the source-data junctions
  - builds first, then asks the running editor to save its Workspaces and detach Terminal Sessions
  - Terminal Session hosts and their shells keep running; the restarted editor reconnects to them
  - restarts through Windows Explorer, outside the updating Terminal's process group
  - uses the desktop environment for the restarted app; closing the updating Terminal cannot kill that app
  - moves the old `anvil.exe` and ConPTY files into `anvil-portable\retired`, because running hosts lock them
  - stops if the editor does not close, for example at an unsaved-file prompt; it never force-stops a process

- `launch-anvil-debug.bat`
  - explicitly launches the unstripped `build-windows-x86_64\src\anvil.exe`
  - uses the data and user folders of the dev portable app
  - use this only when native debugger/symbol information is needed

`scripts/start-dev-anvil.ps1` starts the app after setup and updates. Do not replace it with `Start-Process` or CMD `start`.
Those calls keep the caller's Windows job. A later Terminal Close can then kill the restarted editor.
Run `anvil:dev-update-launch` after changes. It uses a windowless test app, not the dev portable app.

The dev portable app's executable:

```text
..\anvil-portable\anvil.exe
```

It is the stripped executable. Do not switch it back to the
unstripped build output; use `launch-anvil-debug.bat` for native debugging.

## Launch mode

On Windows, Anvil starts the native shell by default. The shell owns the
Windows, the Project Sidebar, and one hosted process for each loaded Project.
`--shell` is still accepted.

These launches run the Lua application without a shell:

- `--direct`, which is removed before the Lua command line is parsed
- CLI commands such as `test`, `help`, `list`, `repl`, `run`, and `edit`
- `serve`, the Machine server
- `--help`, `-h`, `--version`, and `-v`
- the shell's own Project and Sidebar processes

`src/launch_mode.h` owns this rule. `anvil:launch-mode` tests it.
Tools that measure the Lua application alone pass `--direct`.
Other platforms have no shell and always run the Lua application.

One shell runs for each executable and user folder. The shell key uses resolved paths.
A launch through `C:\Projects`, a link to `D:\Projects`, reaches the same shell.
A different executable with the same user folder, such as `launch-anvil-debug.bat`, starts a second shell.
If a Project is open in another instance, selecting it raises that instance.
The Window keeps its other Projects. The `launch-link` and `launch-handoff` shell launch probes cover this.

An external launch selects its Project in the Window that the user activated last, as a Sidebar click does.
A folder argument names the Project. File arguments open in new Panes of the deepest known Project that contains them all.
Known Projects are the Sidebar list, loaded or Dormant. Other files open in the Scratch Project.
A launch with files waits up to 5 seconds for the first Sidebar list. A Terminal launch keeps its Terminal's Project.
A cold start without saved Windows still opens a file's own folder.
Run the `launch-files`, `launch-forward` and `restore-argument` shell probes after changes.

The Scratch Project's folder is `USERDIR/scratch`. The shell makes it at startup and again before a launch uses it.
The shell marks its Sidebar row with `scratch`. The list bound never removes that row.
The status scan reads its Terminal Sessions while it is Dormant.
The Sidebar View lists it first in every Window, also when another Window holds it. It draws it as a section header named "Scratch", like the age groups, with no badge. Its Tabs show below the header. Its new Terminals start in `HOME`.
Scratch follows the selection. Selecting it in a Window that does not hold it moves it there, through the normal Project Move.
New Window selects Scratch the same way. The Window that loses Scratch stays open, and shows its Sidebar if it has no other Project.
An external launch into Scratch also moves it, to the Window that the user activated last.
Lua finds it with `core.is_scratch_project`, which compares paths and does not resolve links.
Run `ui/sidebar_view.lua`, `ui/terminal.lua` and the `launch-files` and `windows-move` shell probes after changes.

Shell App State keeps each Window's loaded Projects and Selected Project.
Shutdown captures their paths before closing the hosted processes. Dormant Projects stay dormant.
Restore starts Selected Projects first, then the other loaded Projects through the existing staggered startup.
Run `anvil:shell-state` and the `restore-loaded` shell launch probe after changes.

Window Close (`core:close_current_window`, the Close button, Alt+F4) closes one Window. Its Projects become Dormant.
The last Window's Close ends the shell, and App State keeps that Window. Other Windows go on the closed-Window list.
Close All Windows (`core:close_all_windows`) saves every Window first, then turns off App State saves. The next start opens them all.
It closes one Window at a time, front Window first. The next Window closes after each Project of the previous Window has decided.
It asks once about the Terminal Sessions of all Windows (`ask_all`). Later Windows reuse that choice.
A Cancel stops Close All and turns saves on again. Windows that closed before the Cancel go on the closed-Window list.
The shell's quit event uses Close All. Taskbar "Close all windows" sends one Window Close to each Window.
Reopen Closed Window (`core:reopen_closed_window`) opens the newest closed Window with its ID, bounds, Selected Project and other loaded Projects.
App State keeps 10 closed Windows. A Window without a Project does not go on the list. A Project that another Window shows stays there.
Run `anvil:shell-state` and the `windows-close-all-terminals`, `windows-close-all-cancel` and `windows-close-reopen` shell probes after changes.

Alt Navigation copies the user's AutoHotkey script (`alt_navigation.ahk`) for a PC without it. `core:toggle_alt_navigation` turns it on or off.
The shell owns it, because all keys pass through the shell. Shell App State saves it. The default is off.
`src/alt_navigation.c` turns one Alt chord into key events, such as Alt+J into Ctrl+Left. Chords match physical keys, so the Ñ key is `;` on a US layout.
Like AutoHotkey's Send, the events release Alt, press the result's modifiers, then restore Alt. Lua's modifier state stays correct, so a later click is not a Ctrl+Click.
The shell drops the release of a replaced key. Alt+Space also sends a text-input space.
Run `anvil:alt-navigation`, `anvil:shell-state` and the `alt-navigation` shell probe after changes.

Project Sidebar visibility belongs to each Window. The first Window and each New Window start expanded. A Window that opens for one Project, such as Open Project in New Window or Move to New Window, starts collapsed.
Restored Windows use their saved visibility, including a lone Window saved with its Sidebar hidden.
Focus slides a hidden Sidebar open until the Sidebar loses focus. The Window still saves it as hidden.
The toggle closes a visible Sidebar, also a hidden Sidebar that focus shows.
A slide shows one step at each display refresh. A docked Sidebar keeps its space in the Project during its whole slide, so it slides over the Project's backdrop and wallpaper.
A Sidebar that focus shows floats: it slides opaque over the Project, and the Project keeps its layout. The toggle docks it.
The shell moves the Project's last frame to a docked Sidebar's edge, so a Project that has not drawn its new width shows no content under the Sidebar.
Sidebar width and the Project list remain shared. Each Window saves its own Project and group folds.
Clicking a loaded Project row in this Window expands or collapses it without selecting it. An empty Project selects itself and opens its initial File Tree Pane. Clicking a Tab selects its Project.
Dormant Projects and Projects in other Windows open when their rows are clicked.
Loaded Projects start expanded unless this Window has a saved manual fold.
Another Window's Project stays collapsed. It ignores this Window's saved fold. A search still lists its Tabs.
Other Windows' Projects use 50% opacity and sit above the age groups in the Sidebar's bottom area. Their visible children stay with them. The Scratch Project is not one of them: it stays first in the main list at full opacity.
Selecting a Project expands it and saves that state. It stays expanded after it loses the selection. The first selection in a restored Window keeps its saved fold.
Window IDs persist across restart. The saved allocation sequence prevents reuse of a closed Window's folding state.
Run `anvil:shell-state`, `ui/sidebar_view.lua`, and the `windows-sidebar-layout`, `windows-sidebar-folding`, and `toggle-sidebar` shell probes after changes.

An unload of a Window's last Project leaves the Window without a Project. Its Project area shows only the wallpaper, with no card or button.
No Project process draws that Window, so the shell sets `backdrop` in the Sidebar's configuration and shows the Sidebar's whole frame.
The Sidebar draws the wallpaper with `core.wallpapers`, as a Project without Panes does, then its strip over it. It reads the wallpaper choice from the user settings when a Window loses its Project.
Until that frame arrives, the shell shows the plain background. The Sidebar opens there without a slide.
The "Starting" text and the failed card stay on the plain background.
A Window without a Project, or with a failed Selected Project, has no process to take keys. Its Window's Sidebar then takes the keyboard and keeps it.
Escape and the Sidebar focus command do not release it. A hidden Sidebar slides open.
The keyboard goes back to the Project when the user selects a Project that can take keys, or restarts the failed Project.
Run the `dormant-last`, `shell-empty`, `recovery` and `navigate-sidebar` shell probes after changes. `shell-empty` checks the wallpaper's pixels.

The shell draws its own text, such as the failed card and the Title Bar name, in Fira Sans, the Sidebar's typeface.
The executable carries the font as a resource (`resources/windows/ui_font.rc`), so the shell needs no data folder.
The failed card looks like the editor's dialogs (`core.nagview`): same sizes, card colours, shadow and buttons.
`color_theme.shell_colors` sends those colours. Over a failed Project's last frame, the shell blends the card with its shadow.
The card names the failed Project. The shell logs the card's button rects, and the `recovery` probe reads them.

The shell draws the Window controls with the Windows caption glyphs: Segoe Fluent Icons, or Segoe MDL2 Assets on Windows 10.
Its hit test reports the Maximize button as `HTMAXBUTTON`, so Windows 11 shows Snap Layouts there.
The shell handles that button's non-client press itself. Windows' own button tracking would draw its hidden button.
Run the `maximize-button`, `theme-global` and `theme-empty` shell probes after changes to the Window controls.

Shell process-exit monitoring must survive a Project pipe failure.
Only runtime teardown cancels that wait. A requested Close completes when the Project exits, even without exit intent.
Update retries resume unfinished Window Close requests without replacing the first saved Window layout.
Run the `windows-close-update-disconnect` shell probe after changes to shutdown recovery.

The Project Sidebar reports a Project ready after Lua startup and Workspace restore finish.
Hosted processes report this separately from their first frame and repeat the report after adoption.
Background Projects do not render. Keep the shell's first-frame guards separate from this status.
A Project's 30-second first-frame deadline starts again when the shell first shows it. Run the `restore-select-late` shell probe after changes.
The `restore-loaded` probe checks readiness without selecting the restored background Project.

A Sidebar Pane selection keeps the previous Project's frame until the requested Pane has rendered.
Pane deliveries carry request IDs. Lua completes each request, including a rejected request, before the next redraw.
Both renderers report the completed ID. The shell rejects frames that precede the requested ID.
Pane reports also carry the completed ID. The shell's Sidebar model keeps the previous selection until that report arrives.
The shell then publishes the destination Project and its requested Pane together, without highlighting its previous Pane.
Meanwhile the Sidebar View highlights the row that the user chose, so the highlight does not go back to the old Pane.
A chosen Terminal Session keeps the highlight until the Tab that shows it is active.
Runtime readiness permits delivery before the first frame, so selection cannot block a new Project's startup.
Run `anvil:hosted-routing`, `ui/pane_requests.lua`, and the `select-hold` shell probe after changes.

The shell waits for swapchain capacity without blocking its event loop. It collects input and new surfaces during that wait.
Each Window has one pending presentation and one one-shot readiness wait. Idle Windows have no readiness wait.
The shell composes the latest surfaces when capacity becomes available. Vsync stays enabled outside live resize.
Window destruction cancels and joins its wait before releasing its renderer.
Run the Sidebar-hover latency probe and focused shell rendering, resize, GPU-failure, and Window-close probes after changes.

A lost GPU device, for example during a driver update, does not fail a Project or the Sidebar.
The shell rebuilds the Window's presentation after 1 second. Repeated failures double the delay, up to 60 seconds.
After the rebuild, the shell sends a new configuration epoch, so each visible surface draws a complete frame.
A hosted process that loses its own device creates a new device and a new shared texture on its next frame.
Run the `fault-present`, `fault-resize`, `fault-release`, `fault-device`, `sidebar-gpu` and `windows-close-gpu` shell probes after changes.

## Display scale and Zoom

On Windows, shell and direct mode read the monitor's content scale through `src/display_scale.h`. Do not multiply it by SDL's window pixel-density ratio. A minimized Window can give a temporary ratio of 1/16 during lock or wake. Invalid native scale reports keep the previous scale, or use 1 at startup.

`plugins.scale` keeps the chosen interface and text Zoom ratios separate from the applied size limits. Display changes apply those ratios again; they do not derive Zoom from limited font sizes. Display events do not save Zoom. Explicit scale configuration takes priority over display changes.

Run `anvil:display-scale`, `ui/scale_fonts.lua` and the `zoom-global` shell probe after changes.

## Renderer selection

The dev portable app defaults to the D3D11 command renderer on Windows. Do not use the old two-flag test setup (`ANVIL_D3D11` plus `ANVIL_D3D11_COMMANDS`) for normal launches.

Use one runtime switch only when needed:

```text
ANVIL_RENDERER=software
```

Unset `ANVIL_RENDERER`, or set it to `d3d11`, to use the default D3D11 path. D3D stats are still opt-in with `ANVIL_D3D11_STATS=1` and `ANVIL_D3D11_STATS_FILE=...`.

## Bundled Anvil defaults/plugins

The old personal `~\.config\anvil` workflow has been promoted into the fork:

- bundled plugins: `data\plugins`
- bundled default theme/style schema: `data\colors\default.lua`
- first-party startup defaults: `data\plugins\anvil_defaults.lua`

`anvil_defaults.lua` replaces the old user `init.lua` for the default Anvil experience. It is mandatory first-party code and is loaded outside the normal plugin-disabling flow. The core/mandatory first-party plugin list is owned by `data\plugins\anvil_defaults.lua` through `core.first_party_core_plugins`; those plugins are part of this editor fork's core experience and should not be disabled through settings/plugin-disable flows.

Keep personal machine-only state out of the repo, such as app state, workspace data, logs, caches, and fuzzy-search recent command history.

### DATADIR vs USERDIR in the dev portable app

`DATADIR` is the bundled app data root. In the dev portable app, the editable data directories are Windows junctions back to this repo:

- `anvil-portable\data\core    -> anvil-editor\data\core`
- `anvil-portable\data\plugins -> anvil-editor\data\plugins`
- `anvil-portable\data\colors  -> anvil-editor\data\colors`
- `anvil-portable\data\widget  -> anvil-editor\data\widget`
- `anvil-portable\data\treesitter -> anvil-editor\data\treesitter`

`USERDIR` is the portable/user state and local-config root:

- `..\anvil-portable\user`

User plugins and machine-local state belong under `USERDIR`. First-party core/default behavior, bundled plugins, and bundled theme/style schema belong under `DATADIR` in the repo.

### First-party defaults policy

Bundled Anvil plugins are first-party code in this fork. Since this is a personal customized editor, most plugins developed as part of the fork should be treated as core or mandatory unless there is a clear reason for them to be optional/user-owned. Do not hardcode fallback defaults inside first-party plugin modules for config/style keys they use. Put first-party defaults in the defaults layer instead:

- style/color defaults belong in `data\colors\default.lua`; theme-specific overrides belong in other theme files under `data\colors`
- behavior/config defaults belong in `data\plugins\anvil_defaults.lua` or another explicit first-party defaults file if one is introduced

First-party plugin code may assume its required first-party config/style keys exist after the defaults layer has loaded. Third-party/user plugins may still define their own fallback defaults for keys they own, because those keys are outside the first-party schema.

When adding or changing first-party plugin behavior, do not parameterize every constant by default. Promote a value into config/style only when it has a clear user-facing purpose and effect, and when it makes sense as something customizable now or likely to be changed on the fly/future-tuned. Once promoted, keep its default in the appropriate defaults file rather than in the plugin implementation.

When adding a new first-party style key, ensure the base style schema remains complete so switching themes does not leave missing keys. Themes should override keys, not be the only place where required first-party keys are defined.

## Machine server

`anvil serve [<project>...]` is the Machine server from [Machines](docs/machines.md). It runs Anvil's Lua (`core.serve`) without a window. It does not forward its launch to a running editor.
The shell starts `anvil serve --owner <shell pid>` at startup. That server ends within 1 second after its shell ends.
One server runs for each user folder: a server keeps `USERDIR/machine/server.lock` open (`machine.claim`). A second `anvil serve` fails. A server with `--owner` waits until the other server ends, then takes over. A dev update needs this, because the old server ends after the new shell starts.
Without Projects, the server serves the Sidebar's Projects: `USERDIR/scratch` and the `recents` of `USERDIR/appstate.lua`. It reads the file again when its time or size changes. `projects.list` gives `{path, scratch}` for each Project.
The server listens on port 7690 when it can, and takes another port when that port is in use. `--port 0` takes any free port. Tests use it.
On Windows, `net.create_server` binds without `SO_REUSEADDR`. With it, a second server got the same port, and the two servers shared the clients. Do not use `SO_EXCLUSIVEADDRUSE` either: it refuses the port while old connections are in TIME_WAIT, so a restarted server would lose 7690. Run `runtime/net_server.lua` after changes.
The server has a small headless runtime: `package.loaded.core` is the server's `core`, with `add_thread`, `try` and quiet logs. Each step runs the due threads and drains the worker pools. So shared modules, such as `core.project_files`, run in the server unchanged.
Each service is a module that returns its methods, such as `core.serve_files`. The JSON part of a frame is limited to 1 MiB, so large answers put JSON or NUL-separated text in the bytes.
`files.list {root}` gives the Project's scan from `core.project_files`: files, then folders, relative to the root and separated by NUL bytes. `files` counts the files. Ignore rules apply as in a local Project.
The first list of a root starts its folder watcher. `files.changes {root, since}` waits until a change after the sequence `since`, then gives the changed relative paths. `reset = true` means: list again. The server keeps the last 64 change batches.
`files.stat {paths}` gives `{type, size, modified}` or false for each path. `files.list_dir {path}` gives the entries of one folder. Both send JSON in the bytes.
`search.start {args, cwd}` runs the server's own ripgrep, not `args[1]`. `core.serve_search` accepts only the options on its list, and each path must be in `cwd`, which must be in a Project. Add an option there only when it cannot run programs or write files.
The server sets `--max-columns` to at most 64 KiB, also when the Client gives none or 0. ripgrep then omits a longer line, so one line cannot fill the server's memory.
A path argument is absolute or relative to `cwd`. The server refuses `\x` and `C:x`, because Windows reads them from another folder.
The folders `USERDIR/machine` and `USERDIR/machines` hold credentials. The token in `server.json` gives Full control. A Project can hold the user folder, so each path check refuses these folders (`private`), and each search excludes them with a ripgrep `--glob`. The glob names a path from `cwd`, so it holds only for paths in `cwd`. Each `[ ] { } * ?` in the path goes in a character class, because a backslash does not escape on Windows.
Each request runs protected: an error replies `internal_error` and does not stop the server. Above 64 MiB of unsent replies, the server reads no more requests from that Client. It closes the Client after 30 seconds without progress. After the stall, the requests that it already received run before it reads again.
`core.json` encodes text after `json.number_flag` as a raw number only when the text is a complete JSON number. `+1`, `01` and `1.` stay text. Machine replies carry untrusted names and paths.
`json.decode` stops at the first error. The server decodes a request before its login, so incomplete JSON must not stop the server.
`search.read {id}` waits for output and gives up to 1 MiB of records in the bytes. `done = true` gives ripgrep's exit `code`. A search ends after `search.cancel`, when its Client disconnects, or after 30 seconds without a read. The server keeps at most 16 searches. A new search ends the oldest. A read that waits for an ended search gets `not_found`.
Run `runtime/machine_serve.lua` and the `launch-machine-server` shell probe after changes.
It listens on loopback only. At start it writes `USERDIR/machine/server.json` with its port, token, process ID, Machine ID and epoch. The folder is private.
The Machine ID is in `USERDIR/machine/id` and stays across restarts. Each start gets a new epoch and a new token.
`src/machine_frame.c` is the frame codec. It has no Lua or SDL headers, because the Companion uses it too. `src/api/machine.c` exposes it to Lua as `machine`.
A frame has a 13-byte header: the type (1 request, 2 reply), then the request ID, the JSON length and the byte length, each 4 bytes big-endian. The JSON body follows, then the raw bytes.
The first request must be `hello` with `protocol` and credentials. The server checks the version first. A wrong version or wrong credentials get an error reply, then the server closes the connection.
There are three kinds of credentials. The local owner sends `token` from the discovery file. A paired device sends `device` and its own `token`. A new device sends `pair`, a pairing code, and `name`.
The `hello` reply gives the `level`: `view` or `full`. A View device only reads. `files.write`, `pairing.start`, `devices.list` and `devices.revoke` need Full control and give `forbidden` otherwise.
`pairing.start {level}` makes a 6-digit code. It works one time, for 5 minutes, and ends after 5 wrong attempts. A new code replaces the old one. A `pair` without an active code gets `pairing_ended`, so the user knows to make a new code. A wrong code gets `unauthorized`. A pairing `hello` reply also carries `device = {id, token}`.
`USERDIR/machine/devices.json` keeps the paired devices with the SHA-256 of each token, not the token. `devices.revoke {device}` deletes the device and closes its connections at once.
`--port <number>` before the Projects makes the server listen on that port. Tailscale Serve and other forwarders need a port that stays the same. The server still listens on loopback only.
`anvil machine code full|view`, `anvil machine devices` and `anvil machine revoke <device>` manage the server that runs with the same user folder. `core.machine_cli` runs them without a window, like `anvil serve`, and exits.
On a Client, the `machine:pair` command asks for `host:port` and the pairing code, then calls `MachineClient.pair`.
`files.read` takes an absolute `path` in one of the server's Projects. Its reply has `size` and `version` in the JSON and the file's bytes after it. The version is the SHA-256 of the bytes.
`files.write` takes `path`, `base` and the new bytes. It replaces the whole file only while the file has the version `base`. Without `base`, it only creates a file.
Otherwise it sends a `conflict` error with the current `version` and bytes. Request bodies can hold bytes only after `hello`. Both limits are 16 MiB.
A write can carry a `save` ID. `files.save_result {save}` gives the version that the save wrote. The server keeps the last 1024 results in memory, so a restarted server answers `unknown_save`.
An error reply is `{"error": {"code": ..., "message": ...}}`. The server ignores unknown fields.
The server polls its sockets. A link inside a Project can point outside it, as in a local Project.
`--test-root <folder>` before the Projects maps each Machine path into that folder: `C:\a\b` is `<folder>\C\a\b`. Only tests use it, so one PC can hold a Client copy and a different Machine copy at the same path.
`--test-lose-reply <method>` does the first request of that method, then closes the connection without its reply. Only tests use it.
`core.machine_client` is the Client. A scheduler thread connects through a Machine file and sends `hello`. `request` holds other requests until `hello` succeeds, and it never blocks the UI thread.
The connect and the `hello` reply must finish in 10 seconds. Then the Client fails the connection and tries again, because a forwarder can accept a connection that no server answers.
A Machine file is the local discovery file or the record of a paired Machine. After a disconnect, the Client connects again with a growing delay, up to 5 seconds. It reads the Machine file each time, because a restarted local server has a new port and token.
`MachineClient.pair(host, port, code, name, on_done)` sends a pairing code one time and saves the record in `USERDIR/machines/<machine id>.json`. The folder is private. A wrong code saves nothing and does not try again, because each attempt counts.
The record keeps the host, the port, the device ID and the token, protected with `machine.protect`. On Windows that is DPAPI for the current user. Other platforms keep the token as it is and rely on the private folder.
A request that was not sent fails with `offline`. A request whose reply did not arrive fails with `disconnected`: the Machine can have done it.
`core.fs` holds the Project content of a Project process. `fs.use_machine(discovery, roots)` makes the process use a Machine. `roots` lists the Project's paths. Only tests call it until Projects on other Machines exist.
It also turns on the Machine guard (`core.machine_guard`). The raw file functions then refuse relative paths and paths inside the roots. Other absolute paths are local state, because a Machine serves only paths inside its Projects.
A root can hold this PC's own folders: `USERDIR`, `DATADIR`, `EXEDIR` and the temp folder. An example is a Project at `C:\` or at the home folder. The guard does not refuse paths in those folders, so the Client keeps its state and credentials there. `fs.on_machine` still names them Machine files.
`fs.machine_file(path)` tells if a Buffer of the path reads and saves through the Machine. A file in this PC's own folders and outside the guarded Project paths, such as the User Module, stays on this PC. Other paths go to the Machine, which refuses paths outside its Projects.
Worker jobs whose payload names a Project path are refused at submit. The `bytes` and `text` fields hold file text, so the guard does not check them. Do not send a path that the worker does not read. A new raw function that takes a path needs a wrapper in the guard.
A Project at a drive root, such as `D:\`, owns all paths on that drive.
On a Machine, `core.project_files` fills its normal entry from `files.list`, `files.stat` and a `files.changes` loop. Its subscribers see the same change batches as for a local Project.
After an error, the loop scans the Project again. A scan that fails, for example while the Machine is away, runs again each second, because only a scan gives the loop its sequence.
`fs.on_machine(path)` tells if a path names a Machine file. `project_files.info(path)` is `system.get_file_info` for local paths. For a Machine file it gives only `{type}` from the file list, without a wait. The file list leaves out ignored files, so `info` then reads the folder listings of `core.machine_folders`.
`core.text_search.start` starts ripgrep like `core.process_stream.start`. In a Project on a Machine, it gives a stream with the same methods that reads from `search.read`. Text Search uses it for each ripgrep run.
The Machine stream stops asking for output while 2 MiB waits unread. `read_until` reports the bytes that it takes through the stream's `ack`, as for a local process. The stream then asks again. The server ends a search after 30 seconds without a read.
A stream that fails, such as while the Machine is away, makes Text Search show "Text Search failed", not "No matches". The next query searches again.
File Search uses `project_files.info` for its path checks. On a Machine, it skips the local probe before a preview, and its create row makes the file through `core.file_ops`. `core.open_file` opens a Machine file as text.
A line number in a File Search query does not filter a Machine's files, because their lines are not counted here. With Include Ignored Files, a path query searches the Machine's file list, not this PC's folders or Everything.
Other Project rows show no preview when this Project or the row's Project is on a Machine. Their Machine and this process's Machine can differ. Opening a row goes to its own Project.
`core.machine_folders` keeps folder listings from `files.list_dir` for code that lists folders without a wait. `list(path)` gives nil while a listing loads. Its `watch()` has the methods of `core.dirwatch` and reports a folder when its listing arrives or changes.
The File Tree uses it on a Machine, so it shows each folder after its listing arrives. Folder counts use the same listings.
`core.file_ops` creates, moves, copies and deletes files and folders, also to the Recycle Bin. For a Machine path each call is a request (`files.mkdir`, `files.move`, `files.copy`, `files.delete`, or `files.write` to create), and the calling coroutine waits. `file_ops.run(path, fn)` runs `fn` in a thread for a Machine path. The server uses the same functions on its own disk.
These methods need Full control. Their paths must be in a Project. A Project root, or a folder that holds a Project root, cannot move or be deleted. A move or copy fails when its target exists.
A Client waits on `files.changes` once for each Project. A new wait ends the earlier wait with `replaced`.
On a Machine the File Tree applies its changes in a thread. It then lists the changed folders again (`machine_folders.reload`), without a wait for the change notices.
While the changes run, the tree takes no edits and no second apply, because the new list replaces its text.
A restored File Tree on a Machine waits for the listings of its saved folders, then restores them. No metadata tells that a saved folder is gone, so a gone root shows an empty tree. The tree takes no edits until the restore ends.
Up Directory and other folder changes stay in the Machine's Project. The folder above it is a folder of this PC. `sync_path` does not resolve a Machine path on this PC.
Rename (`editor:rename`) moves a Machine file with `file_ops.move`, then saves the Buffer's unsaved text. Delete and New Directory also use `core.file_ops`. New Directory starts a relative name at the Project.
Save As of a new Buffer checks the target with `file_ops.info`, so it asks before it writes over a Machine file. A File Tree delete that cannot reach the Machine shows an error and keeps the edit.
`common.path_suggest` lists Machine folders through `common.machine_listing`, which `fs.use_machine` sets. The listings arrive later, so the first suggestions can be empty.
A Markdown attachment on a Machine uploads the file from this PC into the note's attachment folder. The Obsidian attachment setting comes from the Machine. A file URI link to this PC is refused.
The link goes at the selection of the paste. An edit, a close or a new note name during the upload inserts no link, and a warning names the uploaded file.
Live Preview binds no vault index on a Machine, and link completion offers no note names. Both wait for the Index service. The vault index also ignores the load and rename of a Machine Buffer.
An Image View of a Machine file reads its bytes through `core.fs` and loads them with `canvas.load_image_data`. A restored Image View loads the same way, then applies its saved pan. Autoreload does not watch Machine files, and focus does not change the process's folder to a Machine Project.
An image in a Machine note loads in a thread (`markdown/images.lua`). It finds the path with Machine stats, in the same order as locally, then reads the bytes. Its subscribers hear when it is ready. A Machine file has no local file ID, so the Git changes baseline keeps none.
A Machine image has no local file to check, and a Machine note has no vault index. So `markdown/images.lua` subscribes to the Project's file changes. A change loads each failed Machine image again, and each image whose file changed. A reconnect loads all Machine images again. Their subscribers hear the result.
Run `runtime/machine_files.lua`, `ui/machine_file_search.lua` and `ui/machine_filetree.lua` after changes.

A Project on another Machine has a key: `anvil-machine://<Machine ID>/<path on the Machine>` (`core.machine_project`). The Sidebar, Shell App State, recent Projects and Workspaces use the key as the Project's path. Windows file functions reject it.
The shell uses the key as the Project's identity and passes it to the Project process with `--project`. That process connects with `fs.use_machine`: to this PC's own server when the ID is its own, or else to the paired Machine's record in `USERDIR/machines`. Inside the process, paths are native paths.
Code that names this Project to the Sidebar or to other Projects uses `machine_project.root_key(path)`: Workspaces, Untitled recovery, recent Projects, Numbered Panes, Sidebar Tab drags, Pane transfers and Other Project search. Pane requests accept a key in their Project fields. Path normalization would change a key's separators, so Path Search and other code do not normalize a key.
`core.open_project_in_same_window` and `core.open_project_in_new_window` give a folder of this process's Machine its key (`machine_project.folder_key`).
A Pane moves only between Projects of the same Machine, or between Projects of this PC. On a Machine, the target Project must hold each file of the Pane: each Buffer's file, each Image View's image and each File Tree's folder.
A Project on a Machine adds only its own folders as Project Paths, so they are Vendored. External folders are refused.
`machine:open_project` lists the paired Machines, then the chosen Machine's Projects (`projects.list`).
A Project on a Machine skips its Project module, Git, Git file changes and the symbol index until their services exist. The guard would show an error for each.
Run the `launch-machine-project` shell probe after changes. It opens this PC's own Scratch through its server, opens a file, and checks that no guard refusal shows. The test server's owner is the test process, so a crashed test does not leave a server.
[The file seam](docs/machines.md#the-file-seam-corefs) lists the Project content sites by feature. Run `runtime/machine_guard.lua` and `runtime/machine_buffer.lua` after changes. The Buffer tests run with the guard on. Test helpers that stand for the Machine keep the raw functions from load time.
On a Machine, `core.open_buffer` loads each file in the background. The Machine sends the bytes, and the `buffer_read` worker decodes them from its payload. A missing file opens as a new file.
`Buffer:save` sends the whole file with the version that the Buffer loaded or saved last. The Buffer stays dirty until the Machine confirms. A save during another save waits, with its file, and sends after the reply. A waiting plain Save saves the Buffer's file at its turn, which a Save As before it can change. It sends also when the text looks saved, because an encoding or line ending change does not change the text. A closed Buffer sends nothing more.
`MachineClient:request` refuses more than 16 MiB of bytes with `too_large`, because the server closes the connection of a larger request. A larger Buffer shows an error and sends nothing.
A Save As over an existing file sends again with that file's version, as a local Save As replaces the file. A file that changes again stops the Save As with an error, not the conflict choice, because that choice acts on the Buffer's own file.
A refused save records the Machine's version in `buffer.machine_conflict` and calls `Buffer:on_machine_conflict`. Autosave shows its normal conflict choice there, without Save Copy. Overwrite and Save as New File first call `Buffer:accept_machine_version`.
Each save has a save ID. When its reply is lost, the Buffer stays dirty. After the reconnect it asks `files.save_result`. On `unknown_save` the file's version decides: the sent bytes mean saved, the base means not saved, other bytes mean a conflict. The Buffer never sends the old bytes again. A save that did not happen sends the current text to its file, also for a Save As of a clean Buffer, and the saves that wait behind it run after it.
After each reconnect, each open Buffer reads its file again. A clean Buffer whose file changed reloads through edits. A dirty Buffer keeps its text and gets a conflict. A save that went `offline` runs again, to the file that it named. So an offline Save As writes the new file, not the old one.
A save result that the Client finds after a reconnect also gets this check, because another program can have changed the file after the save.
A successful Save As drops the old file's conflict. A reply marks only the sent text as saved. After an edit or undo during the save, the Buffer is clean only when its text is the sent text, because the history can hold other text at the sent undo position.
A reload from the Machine is ignored when the user typed during the read. The next save then meets any change on the Machine as a conflict.
Autosave keeps no local disk state for Machine files. Its disk state is the last conflict.
Each dirty Machine Buffer has a recovery record in `core.storage` (`machine_recovery`, one key for each Machine and path). It holds the text, encoding, line endings, base version and the sent version of the open save.
An edit writes it after 0.5 seconds. A save writes it before the request leaves. A clean Buffer deletes it, except while a save is unresolved: the Machine can have its bytes. For the same reason, the Buffer registry keeps a Buffer with an unresolved save after its last View closes. Records are written on the UI thread, as Untitled recovery is.
When a Machine file loads and has a record, the Buffer takes the record's text as one edit. The Machine's version decides: the same bytes mean clean, the base or the sent version mean dirty, other bytes mean a conflict.
A Buffer that the user closes without a save deletes its record, and no due write or later reply writes it again. A rename moves the record to the new name.
On Windows, the server has a Terminal service (`core.serve_terminal`). `terminal.list {project}` gives the running Terminal Sessions of a Project, newest first, with the record fields that the Sidebar shows. A session with a `.closed` marker is not listed.
`terminal.attach {id, cols, rows, cell_width, cell_height}` connects the server to the session's host as one more Client (`terminal_link.connect`). The reply gives the `link`, the `session_id`, the `shell_pid` and the host's size.
`terminal.start {project, cwd, shell, scrollback_lines, cols, rows, cell_width, cell_height}` starts a new host in a Project folder and attaches the device as its Controller (`terminal_link.launch`). Only Full control devices can start a shell. Its reply is the reply of `terminal.attach`.
A new shell ends when its link ends before the device reads it, for example after a lost reply. Nothing else knows its ID.
`terminal.read {link}` waits for the host's framed records and gives up to 1 MiB of whole records in the bytes. `terminal.write {link}` sends records to the host. `terminal.detach {link}` ends the link. The host keeps the session.
The link checks each record that a Client writes, in C. A Full control device can send input, resize, take control, clear, detach, close and end. A View device attaches view-only and can only detach. Its other writes get `forbidden`.
The host shows the paired device's name as the Controller's name. A full write buffer gives `busy`, and the Client sends again.
The server closes a Client's links when the Client disconnects. Each Client has at most 32 links.
On a Client, `terminal_native.new {remote = true}` makes a session without a host. `core.machine_terminal.connect(client, session, id, start)` attaches it through `terminal.attach`, then `session:attach_remote(result)` connects it.
With a nil `id`, it starts a shell through `terminal.start`. A first attach that gets `not_found` also starts a shell, with the same `start` options.
`attach_remote` gives the session one end of an in-process pipe pair (`terminal_link.c`). The session's reader and writer use it as a host pipe. Lua carries the other end's records through `terminal.read` and `terminal.write`.
After a disconnect, `core.machine_terminal` closes the pipe pair. The session then waits in the reconnecting state, with no time limit, and attaches again with a new snapshot when the Machine returns.
A closed session sends its last record, such as CLOSE or DETACH, through the link after its pipe closes. The Client then sends `terminal.detach`. A later `not_found` attach means the session ended on the Machine.
The attach ROLE comes before the snapshot. The Client applies it with the snapshot, so a key that the user types when the screen shows goes out with its role.
In a Project on a Machine (`fs.machine`), each Terminal View runs its shell on the Machine. The View keeps no session record on this PC and uses no prepared shell.
Workspace restore attaches the saved session ID. When the Machine no longer has it, a new shell starts in the saved folder, as a local restore does. Reopen Closed Pane does the same, because the Machine keeps no closed sessions.
A shell that ended while this PC was away closes its View, as after an exit. A failed start shows its error in the View.
These Terminals cannot move to another Project. Programs in them reach the Machine's Anvil, so the View publishes no control endpoint.
The shell's scan reads only this PC's records. So the Project process lists its Machine's sessions every 2 seconds (`machine_terminal.sessions`), and its Pane report sends them as `terminals`.
The Sidebar model adds them to the Project's Terminal Sessions, so they show agent status, age groups and attention as local sessions do. A Dormant Project on a Machine lists none.
A Sidebar click opens a listed session through the Machine. It does not start a new shell, as a local click does not.
Run `runtime/machine_terminal.lua`, `ui/machine_terminal.lua` and `ui/project_sidebar.lua` after changes. The runtime test uses a real host and a real server that shares the test's user folder. The UI test gives the server its own user folder.
Run `runtime/machine_serve.lua`, `runtime/machine_client.lua`, `runtime/machine_buffer.lua`, `anvil:machine-frame` and `anvil:launch-mode` after changes. Tests that need a fixed port must try ports until one opens: Windows reserves whole port ranges, and `get_port()` returns the requested port. Pass one file to each `--test-args`: the runner reads only the first path.

## Companion (Android)

`android/` is the Companion's Gradle project (`io.github.dcostap.anvil`). It is a Client of the Machine server. See [Machines](docs/machines.md).
The app opens to the paired Machines with their connection state. "Pair a Machine" takes the host, the port (default 7690) and a code from `anvil machine code`. It sends `hello` with the code and `Build.MODEL` as the device name.
`machines.json` in the app's private storage keeps each Machine's ID, host, port and device ID. The device token is encrypted with an AES/GCM key in Android Keystore. Pairing the same Machine again replaces its record.
A Machine screen lists its Projects and their Terminal Sessions, with the Agent Status as the desktop Sidebar says it, such as "Waiting for you". It sends `projects.list` and `terminal.list` again every 2 seconds while it shows.
Connections run only while the app shows. A lost connection retries with a growing delay, up to 5 seconds.
A Project row opens its folders and Markdown notes (`files.list_dir`). Dot entries do not show. A note opens in a text field with Live Preview.
`markdown_styles.c` parses the note with the desktop's `markdown_parser.c` and `markdown_extensions.c` and returns styled ranges in UTF-16 units. Kotlin applies them as styles only, so the keyboard sees the real text. Syntax markers hide unless the focused field's selection is in their element.
The Companion keeps the note's CRLF and BOM, and refuses text that is not UTF-8. A note saves 1 second after the last edit, with `files.write` and the version that it read as `base`.
A conflict asks the user: Keep mine or Use theirs. A save whose answer was lost compares the file's version with the SHA-256 of the sent text after the reconnect.
Each unsaved note has a recovery record in `files/recovery`. A recovered note saves when its Machine connects. A clean open note checks `files.stat` every 2 seconds and reads the file again when it changed.
Without Full access, notes are read only. Wikilinks do not open notes yet.
The frames use the desktop's codec, `src/machine_frame.c`, through the JNI binding `machine_frames.c`. CMake compiles it from `src/` and copies no files. Kotlin owns the socket, the JSON and the screens.
Tools: the Android SDK in `%LOCALAPPDATA%\Android\Sdk`, NDK 30.0.16248370, CMake 4.1.2, platform 37 and JDK 17 or later in `JAVA_HOME`. Set `sdk.dir` in the ignored `android/local.properties`. The Gradle wrapper checks the distribution's SHA-256.
Build with `./gradlew assembleDebug` in `android/`. Test on the emulator, not on the user's phone. Start the AVD `anvil-test-36` with `emulator -avd anvil-test-36 -no-window`.
Install the app and its test APK with `./gradlew installDebug installDebugAndroidTest`. Then run `tests/lua/companion/machines.lua` through `anvil:lua-runtime --test-args`. It starts a real server and a Terminal with a waiting agent, and runs `MachinesTest` and `NotesTest` on the emulator through `adb`. `MarkdownStylesTest` needs no server: run it with `am instrument`. The emulator reaches the PC's loopback address as `10.0.2.2`.
The default suites do not run it. It skips when no emulator has both APKs. Run it after changes to the app or to `hello`, `projects.list`, `terminal.list` or the `files` methods.
The connection logs with the tag `AnvilMachine`. Read them with `adb logcat -s AnvilMachine`.

## Agent control

`core.control` owns editor operations. `core.control_server` exposes them through authenticated loopback MCP. `core.control_runtime` publishes private discovery files and follows Terminal ownership. Cross-Project discovery runs in a worker. Do not move editor behavior into the transport or Pi extension.

Interactive Pi gets `data/tools/agent-sessions/pi-control.cjs` through the existing preload. It registers Anvil's MCP server and handles attributed messages, steering, interruption, and settled results. Pi remains a TUI. Pi launches require explicit provider, model, and thinking choices.

`agent_transcript` reads the current Pi branch through bounded, read-only exchange requests. `pi-inspection.cjs` extracts text and tracks live activity without starting model turns or writing session entries. History pages use entry IDs; truncated messages use UTF-16 offsets. System and thinking blocks stay excluded. `agent_read` reports parallel tools, start times, and observation freshness. Active tool calls are not a background process registry. Keep empty protocol arrays as arrays through local and cross-Project responses.

Keep focus by default. Keep normal close confirmations. Use stable Pane, Terminal, and conversation IDs, not navigation numbers. A wait timeout never cancels a task. Retry keys last for the Project process; Pi persists accepted delivery receipts separately.

The `snooze` control tool sets or removes a Terminal's Snooze. Without a target, it uses the calling agent's Terminal Session. The Sidebar owns the saved times. Requests use the shell's Sidebar route, then normal Project Snooze requests. A reply reports acceptance, not completed delivery. Run `ui/agent_control.lua` and the `terminal-focus` shell probe after changes.

The `project` tool opens or unloads a Project in the caller's Window. Open sends `system.load_project`: the shell starts the Project and the Window keeps its Selected Project. `focus: true` selects the Project instead. Unload keeps the normal close questions. It refuses Scratch and the Project that serves the call.
`pane` move with `target_project` exports the Pane through `core.pane_transfer`. An export detaches the Pane's Terminals, so the transport first checks that the target has a control endpoint. Without focus, the import goes through the direct route, and the target stays unselected.
A background Project has no first frame, so the shell keeps it Starting. The direct route also delivers to a Starting Project whose runtime is ready.
Run `ui/agent_control.lua`, `ui/pane_transfer.lua` and the `agent-projects` and `launch-terminal-move` shell probes after changes.

See [agent control](docs/agent-control.md) for tools, discovery, security, and limits. Run `runtime/net_server.lua`, `ui/agent_control.lua`, `ui/control_transport.lua`, and `ui/control_pi.lua` after changes. Also run `node --test tests/pi-control.test.cjs tests/agent-sessions.test.cjs`.

`ui/control_pi.lua` runs real Pi TUI sessions against a local scripted model server. It uses no provider, API key, or inference. Keep these checks isolated from user sessions and settings.

## Logging / diagnostics

Anvil writes persistent session logs to:

```text
..\anvil-portable\user\logs\anvil-*.log
```

Start with the newest logs when you investigate a crash or unexpected behavior. Then find the affected process and incident time. These logs are machine-local state and must stay outside the repo.

For Project failures, disconnects, startup failures, timeouts, or unexpected exits, read [native failure diagnostics](tools/NATIVE_DIAGNOSTICS.md) first. Match shell and Project or Sidebar records by process ID and connection ID. Read the first failure before cancellation and recovery records. Include the rotated native log when needed. A broken pipe does not prove a crash; exit code zero does not prove an expected exit. Check save records separately before claiming that unsaved text survived.

Windows also writes native diagnostics before Lua starts. These logs are always on:

`USERDIR/logs/anvil-<date>-<time>-p<pid>-native.log`

Check the shell and hosted process logs for connection failures, rendering failures, and shell loss.
The `D3D11 device:` line names the adapter. A frame that falls back to the software renderer logs `D3D11 frame failed: <reason>` once for each reason.
Each record includes local time, elapsed time, process ID, thread ID, and priority.
Each process keeps two parts, with up to 10 MiB per part.
The session log cleaner removes Lua, shutdown and native logs that are older than 7 days.
It keeps all logs to 100 MiB in total and removes the oldest logs above that limit.
It does not limit the number of logs, because one launch writes logs for several processes.
`ANVIL_SURFACE_LOG` selects an explicit shared file for probes. It does not control normal logging.

Keyboard events include an always-on `Input trace:` diagnostic. See [keyboard input trace](tools/INPUT_TRACE.md) for stages and limits.

Accepted exits also write `anvil-<date>-<time>-p<pid>-shutdown.log` beside the matching session log.
Use both files when you investigate a slow close. See [shutdown diagnostics](tools/SHUTDOWN_DIAGNOSTICS.md).

When adding new functionality, use `core.log_quiet(...)` liberally for diagnostics that could help debug future bugs or unexpected behavior. Prefer quiet logs for feature probes, optional integrations, state transitions, fallback decisions, and background task results. Quiet logs are useful in pasted logs without annoying the user. Use visible `core.log`, `core.warn`, or `core.error` only when the user should actively notice something.

## Refactoring / compatibility policy

This is a personal fork with first-party ownership of the whole codebase, including bundled Lua plugins and defaults. Prefer clean refactors over compatibility adapters: when renaming concepts, APIs, fields, commands, or behavior, update all in-repo callers/configs/plugins/tests instead of leaving deprecated aliases, dead code, or compatibility slop. Only keep backward compatibility when the user explicitly asks for it or there is a concrete external boundary that cannot be migrated in the same change.

AGENTS.md and docs describe what exists now. When you remove a feature, remove its text. Do not write that it is gone. Put that history in the commit message.

## Dialogs

A Dialog is a modal card over the app, for management tasks that need more than a prompt. `core.ui.dialog` owns it. Only one Dialog is open at a time.
Its controls are in `data/core/ui`: Button, Text Field, Segmented Control and List. Use them for new management UIs. Do not use the old `data/widget` library for new UIs.
The Dialog takes modal input. A text field gets typed text and the user's bindings for the editor's line commands. Other `core:` commands go to the focused control. Tab, Enter and Escape run `dialog:` commands.
Each change applies at once. There is no Save or Cancel. Escape first reverts an unsubmitted field edit, then closes the Dialog.
The Context Menu and confirmations draw above a Dialog.
Style keys for Dialogs and buttons are in `data/colors/default.lua`. `config.disabled_transitions.dialog` turns off its animation.
The Project Paths Dialog (`plugins.project_paths`) is the first Dialog. `project_paths:manage` opens it. `project_paths:add` and `filetree:add_to_project_paths` add a folder.
Run `ui/dialog.lua`, `ui/project_paths_dialog.lua` and `ui/filetree_project_paths.lua` after changes. Check the `project-paths-dialog` render scenario after visual changes.

## File Types

The File Types Dialog (`plugins.file_types`, `file_types:manage`) lists the file types in `config.plugins.file_types.types`. It is on Windows only.
A check registers the type's extensions for this `anvil.exe` at once. A clear removes them. A type that another `anvil.exe` opens shows "Another Anvil". A check takes it over.
All keys are under `HKEY_CURRENT_USER`: one `Anvil.<ext>` ProgID for each extension, its `OpenWithProgids` value, and Anvil's `Capabilities` and `RegisteredApplications` entry. The entry exists while Anvil opens at least one extension.
Windows does not let an app make itself the default. "Set as Default" opens Anvil's page in Windows Settings, where the user does that.
The registry stores the executable's path. After a move, the user checks the types again.
`system.get_registry_values`, `set_registry_value`, `delete_registry_value` and `delete_registry_key` read and write `HKEY_CURRENT_USER` only.
Tests set `plugins.file_types.root` to a private key, so they never change the user's file types.
Run `ui/file_types_dialog.lua` after changes. Check the `file-types-dialog` render scenario after visual changes. It uses fixed rows and does not read the registry.

## Heading Outline

Markdown Live Preview lists the headings left of the reading lane when the free space can hold the list.
It reads the tree-sitter outline, the same list as Current Buffer Symbol Search.
The top heading level and two levels below it show. The current section is the last heading above the top quarter of the view.
After the caret moves, the current section is the caret's section instead, until the user scrolls with the wheel or the scrollbar.
Each Pane's outline follows its own caret. The Buffer's selection belongs to the focused Pane, so the outline uses a selection listener on its Text View.
A click moves the caret to the heading and scrolls it near the top with `scroll_to_line`'s `top_margin`. That heading is then the caret's section.
The selection marker stays in the visible column while a long heading list scrolls. Sections in the middle share one marker position.
Run `ui/markdown_heading_outline.lua` after changes. Check the `markdown-heading-outline` render scenario after visual changes.

## Binary files

`core.open_file` asks how to open a binary file: with the default app, as text, or not at all. It returns `false` while the dialog asks.
`common.is_binary` uses Git's rule: a NUL byte in the first 8000 bytes. Text with a UTF-16 or UTF-32 BOM is not binary.
The File Search preview uses the same rule. `opts.as_text` skips the dialog.
Run `ui/binary_file_open.lua` after changes.

## Table images

A table cell that holds only an image link draws the image, scaled to its column. A cell with text and an image keeps the link label.
An image cell never reveals its source in Live Preview. A click, Up or Down selects the whole cell, so Delete and Copy act on the whole image.
Image cells have no resize controls yet. Edit the source in Source mode.
A Wikilink reads `\|` as its alias separator, because a table needs it: `![[image.png\|200]]`.
Run `ui/markdown_interactive_tables.lua` after changes. Check the `markdown-table-images` render scenario after visual changes.

## Wallpapers

A native worker decodes the wallpaper (`image_decode` job, `src/image_decode.c`). The UI thread never decodes it. A Window shows its plain background until the image arrives. The `imagedecoded` event wakes the event loop.
The decoder uses libjpeg-turbo with its SIMD code, which needs NASM. It decodes at 1/2, 1/4 or 1/8 scale when the result still covers 80% of the drawn size. A larger Window decodes again, and the smaller image shows until then.
Wallpapers are baseline JPEGs. A progressive JPEG decodes about three times slower, and PNG does not decode. Convert a new image with `jpegtran -copy none -optimize`, which does not change its pixels.
Meson's NASM check finds MSVC's `cl.exe` when Visual Studio is on `PATH`, then fails on Git's `link.exe`. The BAT files use a clean MSYS2 `PATH`. An agent shell must remove Visual Studio from `PATH` before it builds.
Run `ui/wallpaper.lua`, `anvil:image-decode` and the `shell-empty` shell probe after changes.

## Shared storage

`core.storage` reads generated Lua data through `system.load_file`. Windows readers share deletion, so a replacement can leave them reading the old file.
`system.replace_file` uses Windows POSIX rename semantics to publish the new file while those readers stay open. Do not replace this with `MoveFileExW` alone: it refuses an open target, even when the reader shares deletion.
Filesystems without POSIX rename support keep the previous, bounded-retry rename behavior. The native log reports that fallback once. They do not have the same concurrent-reader guarantee.
Run `runtime/storage.lua` after changes. It checks concurrent reads and saves, and replacement while a reader keeps the old data.

## Reload from disk

`Buffer:reload()` applies the file's text as edits through `Buffer:apply_lines`. It does not replace the Buffer.
Selections, the visible text, bookmarks and other text positions move with the text. One undo reverts the reload.
`Buffer:undo()` and `Buffer:redo()` return the type of the step they applied. A reload step does not merge with other steps.
Autoreload flashes the lines and shows a status message when an undo or redo applies a reload, because Autosave then writes it to disk.
A reload does not call `Buffer:load`. Plugins that track the disk state hook `Buffer.reload` as well.
A Text View without row measurements keeps its top line when lines change above it, like a measured view.
See [shared editing](docs/shared-editing.md) for the plan: dirty-Buffer merges and Disk Conflicts.
Run `ui/buffer_reload.lua` and `runtime/buffer_apply_lines.lua` after changes.

## Shown Indentation

An empty line holds no whitespace. Its caret shows at the indentation that Enter at the end of the line above writes (`core.empty_line_indent`).
The Buffer keeps the caret at column 1. Only the drawn caret, the Up/Down goal column and the next edit use the Shown Indentation.
Tab, Shift+Tab, End and Backspace on an empty line only change the caret's level. The level stays until the caret leaves the line or the text changes. Enter carries it to the new line.
Typing and paste first write the Shown Indentation. One undo reverts it with the edit (`Buffer:join_undo_since`).
The module tracks the lines that user edits leave holding only whitespace. It moves them through later edits with `changed_ranges`.
A tracked line becomes empty when no selection touches it. With the caret at its end, it becomes empty at once, and its whitespace becomes the caret's level, so the caret does not move.
The cleanup undoes with the edit before it. It waits while redo is available. Undo, redo, load and reload add no tracked lines.
Whitespace-only lines that no edit touches stay. `config.keep_newline_whitespace` turns the cleanup off.
Caches use `buffer.text_revision`. `get_change_id()` is the undo position, which repeats after an undo and a new edit.
In Markdown, a blank line after a list item or a quote shows at the margin.
Keep `newline_indent` in step with `core:newline`. Run `ui/empty_line_indent.lua` and `ui/smart_indent.lua` after changes.

## Paste and move indentation

The lines after the first line of a multi-line paste start at the caret's indentation. They keep their shape relative to the first line.
Parts copied from several carets and pasted at one caret go on separate lines. Each part starts at the caret's indentation.
Whole lines, and complete lines pasted at column 1, go where a new line belongs there: the brace block's indentation (`block_indent`), or else the Shown Indentation of a new empty line. Lines copied together keep their shape.
After pasted complete lines, the rest of the caret's line keeps its indentation.
Markdown keeps the indentation of pasted whole lines, because lists and quotes own it.
Text from outside this process with one line for each caret pastes one line at each caret, in document order. A last newline does not count as a line.
Move Lines shifts the moved lines, and the line that they pass, by the change of their brace block indentation (`block_indent`). A move inside one block changes no indentation, so hanging indentation keeps its offset. Languages without brace blocks keep their indentation. One undo reverts the move and the shift.
Auto-Indent Lines (`editor:auto_indent_lines`) moves the lines of each selection as a paste of them would go: the first line with text takes the indentation of its place, and the other lines keep their shape. Markdown keeps its indentation.
Paste as Plain Text (`core:paste_as_plain_text`) pastes like Paste, but changes no indentation and escapes nothing in a string.
Run `ui/smart_indent.lua` after changes.

## Autocomplete searches

Autocomplete runs Project symbol searches through `workspace_symbols_async`. It submits only the last input context in each frame. A new Buffer edit, caret position, View, Project Paths generation, or close cancels the old requests. Parse refresh reuses the current requests. Results request a redraw even when normal frame pacing leaves the UI idle. Local symbols and matching visible suggestions remain available while Project searches run.

Native Project queries prepare their fuzzy query once and check path and language rules once per file. Keep their matching, ranking, scope filters, and cancellation behavior unchanged. `autocomplete.is_pending()` reports unfinished completion work, including an empty-result search.

Run `ui/autocomplete_batch.lua`, `ui/autocomplete_parse_refresh.lua`, `ui/autocomplete_matching.lua`, `ui/autocomplete_layout.lua`, `runtime/worker_pool_native.lua`, `runtime/fuzzy.lua`, `runtime/symbol_search_case.lua`, and `runtime/treesitter_global_symbols.lua` after changes. Run the `autocomplete` scenario suite for timing checks. Its no-match actions must wait for search completion, not only an empty popup.

Changes Baseline checks file identity once before a pending diff, not on each key. Patch export and Revert also check any pending identity before using the baseline. Run `ui/file_changes_baseline.lua` after changes.

## Panes behind the Fuzzy Searcher

While the Fuzzy Searcher is open, each Pane View draws a Draw Capture of its last draw.
A Draw Capture is a copy of the View's renderer commands (`renderer.begin_capture`, `renderer.end_capture`).
The View draws again when its rectangle, scroll, text, Color Theme or scale changes.
Other changes, such as new Git colors in the File Tree, show when the picker closes.
Terminal Views set `draws_while_covered`, because programs write to them while they are covered.
A replay stops after any Font or canvas is freed, or after a captured Font changes size.
Run `ui/draw_capture.lua`, `ui/covered_panes.lua` and the `fuzzy-picker-*` render scenarios after changes.

## Background work infrastructure

`core.add_thread` schedules a Lua coroutine on the UI thread. It is not an OS thread.
It yields only when the code calls `coroutine.yield`. A long operation between yields blocks the UI.

Anvil already has real worker threads in `data/core/worker_pool.lua`.
Lua jobs run in separate Lua states through `thread.create` and channels.
Add Lua job handlers under `data/core/workers`.
The same pool supports native C jobs through `src/worker_pool.c` and `src/api/worker_pool.c`.
Native jobs need a supported job kind; they do not run arbitrary Lua code.

Use the worker pool for scans or other work that can exceed one UI frame.
Send a copy of the input, then check its revision before applying results on the UI thread.
Do not read live Editor or UI objects from a worker.
The pool returns results to the UI during its budgeted frame drain.

A busy disk or a virus scan can make one file call take seconds. Do not open, read, write or stat files on the UI thread in code that runs while the user works.
Use the `file_info`, `file_read`, `storage_load` and `storage_save` workers. The Session Log writes on its own thread.
The fuzzy navigate scenarios allow 0 UI-thread file calls. See [UI-thread blocking calls](tools/SCENARIOS.md#ui-thread-blocking-calls).

Starting a child process can block for hundreds of milliseconds on Windows.
Do not call `process.start` on the UI thread for recurring work.
Submit a `process_capture` job instead. Git uses `worker_pool.named("git")` through `plugins.git.backend.run_git`.
For output that must stream while the process runs, such as ripgrep, use `core.process_stream`.
Cancel each stream you stop reading; an unread stream holds its worker once its output window fills.
The UI loop drains named pools and shuts them down with the system pool.

## C and Lua

C is the target language for editor logic. Lua is legacy.

- Write new logic in C when it does not need Lua objects.
- Keep existing Lua in Lua until a clean port is possible. Do not start a port that pulls in unrelated modules.
- A port is clean when the code has a clear seam: plain data in, plain data out, and tests that cover the behavior.
- Port a module when your task makes a large change to it and it has a clean seam. Otherwise, name it as a port candidate in your report. Do not grow a small task into a port.
- Lua stays for glue: commands, config, keymaps, plugins, and the wiring between C modules.

### C module shape

Put the logic in a C module that includes no Lua headers, such as `src/markdown_parser.c`. A thin binding in `src/api` exposes it to Lua with the portable Lua C API, not FFI. The PUC Lua build must still work. Another binding can then use the same module.

The module takes plain data and returns plain data, such as text, a parse tree, positions, edits, or styled ranges. It does not know about Buffers, Views, or Lua tables.

A Lua error is caught. A crash in C ends the editor. Give each C module tests that cover its edge cases, such as empty input, invalid UTF-8, and very long lines.

The Lua side calls C once for each edit, batch, or frame. A LuaJIT trace stops at each C call, so a call for each item can be slower than Lua. Values that go back to Lua still make garbage, so return results in bulk.

### Speed work: measure first

Some ports are for speed. For these, do not port code because it looks slow. Measure it first.

1. Run the scenario that shows the problem with `--diagnose`. It writes a sampled profile and timers by phase. See [scenario runs](tools/SCENARIOS.md).
2. Find where the time goes in the attribution `details.csv` and profile stacks. Use `--heap` to measure retained Lua objects.
3. Ask if the work is necessary. Work that is not necessary is the largest win, in any language. Examples:
   - The Heading Outline ran the outline query on the whole note for each key. The worker's parse already had the headings.
   - Two callers joined the whole note into a Lua string for each edit, only to give it to C.
4. Port the work that is necessary.

These costs move to C first:

- Hot loops over plain data, such as rows, heights, or text positions.
- Work for each line or item of a document, where the count grows with the document.
- Large data that stays in memory, such as line layouts, token arrays, or document models.
  LuaJIT's GC has no generations. Each GC cycle marks all live Lua objects again, also data that does not change.
  Data in C memory adds no GC work.
- High GC or interpreter time in the profile for that code.

Code that runs in each frame, such as `update`, `draw`, and caret moves, must not make new tables, closures, or strings when old ones can be used again.

In the commit message of a speed port, give the measurement before and after the change.

### How to port

Port in small slices. Do not rewrite a module at once. For each slice:

1. For a speed port, measure the slice before the change.
2. Keep the old Lua path until the new path gives the same output. Compare both outputs on many real documents and edits. Use the repo's Markdown files and the scenario fixtures.
3. For a slice that changes what the editor draws or where, also compare pixels. Before the change, record golden images with the [render gate](tools/RENDER_PERF_GATE.md) (`--update-baseline --update-goldens`). After the change, the same scenes must match exactly. Add scenes when the existing ones do not show the changed line kinds.
4. Add tests that fail on the old code (red-green).
5. Run the full `lua-runtime` and `lua-ui` suites. Compare their failures with a baseline worktree, because some tests are flaky.
6. Run A/B scenarios against the baseline. Alternate the two versions, so machine load affects both. Give the numbers in the commit message.

### Known target: the document layout pipeline

Measured on the 19,185-line gallery note (`markdown-gallery-open`):

- Building Markdown render lines in Lua took 3.8 s. Cache lookups and fragment preparation took about 0.9 s more.
- The full row-height rebuild in Lua took 0.65 s. One rebuild took 465 ms in one frame.
- The C wrap call (`renderer.wrap_fragment_lines`) took 0.08 s.

The cost is Lua work for each line, spread over many functions. No single loop is hot. So port the pipeline in slices:

- C keeps the data for each line: style runs, wrap breaks, row heights, and line metrics. A worker thread can make them from the Buffer text and the tree-sitter parse.
- C also takes the presentation decisions: given the text, the parse tree, and the caret, which ranges to hide and which to style. Keep these decisions separate from wrapping and row heights, which depend on the renderer.
- Lua keeps widgets, clicks, and command wiring until they have clean seams. Lua reads results with a few calls for each frame.
- Before each slice, measure which line kinds cost the most, such as prose, headings, lists, tables, or code. Port the most costly kind first.

### Frame-time check

Run scenarios before and after each change to code that runs in each frame. This includes `update`, `draw`, scrolling, caret moves, the File Tree and the Fuzzy Searcher.

1. Before the change, run the smoke scenarios that use the changed code, for example `python tools/run_scenarios.py --scenario fuzzy-symbols-navigate-filetree-large --runs 1 --no-build`.
2. Run `--suite smoke` for changes to shared drawing code, such as `data/core/textview.lua`. The suite takes about 40 minutes.
3. After the change, run the same scenarios again.
4. In the commit message, give the p95 frame work, the maximum frame and the Lua heap size from both reports.

Do not commit a change that makes one of these numbers worse, unless the commit message explains why.
Many scenarios are over budget now. A change must not move them further over.
See [scenario runs](tools/SCENARIOS.md) for the budgets.

Do not stop garbage collection to measure allocations. The removed allocation profiler exhausted system memory and crashed other programs. `--allocation` is disabled. The shared Windows launcher limits each benchmark process tree to 4 GiB of committed memory. A `memory_limit` failure is not a passing measurement. Keep this protection in baseline worktrees too.

## Tree-sitter language support

Read [Tree-sitter language maps](data/treesitter/languages/README.md) before adding a language or changing symbol selection.
Review its outline and usage queries.
Update the language review and focused symbol tests when coverage changes.
Keep grammar-specific work in that language's folder.
Do not add a separate query pattern for each pointer depth or similar syntax nesting.

## Lua/plugin development

Built-in plugins live in this repo under `data\plugins`.

The dev portable app uses junctions:

- `anvil-portable\data\core    -> anvil-editor\data\core`
- `anvil-portable\data\plugins -> anvil-editor\data\plugins`
- `anvil-portable\data\colors  -> anvil-editor\data\colors`
- `anvil-portable\data\widget  -> anvil-editor\data\widget`
- `anvil-portable\data\treesitter -> anvil-editor\data\treesitter`

Edit these directories in the repo. Reload or restart Anvil without reinstalling the portable app.

### Lua syntax validation

After editing Lua files, validate syntax without executing the files using the root checker:

```sh
luajit check-lua-syntax.lua data/plugins/example.lua
```

For several changed files, pass all of them as arguments:

```sh
luajit check-lua-syntax.lua data/plugins/autosave_fast.lua data/core/docview.lua
```

To check all bundled Lua files:

```sh
find data -name '*.lua' -print0 | xargs -0 luajit check-lua-syntax.lua
```

Use LuaJIT for this because Anvil runs LuaJIT in the normal dev build, so it is the closest parser/runtime match. On this repo, use the Meson-built LuaJIT executable directly instead of relying on a global `PATH` entry:

```sh
./build-windows-x86_64/subprojects/luajit/src/luajit.exe check-lua-syntax.lua data/plugins/example.lua
```

A normal Meson build generates this executable. The dev setup/update BAT files also run `scripts/ensure-luajit-cli.sh`, which builds that CLI and refreshes a stale LuaJIT subproject checkout if needed. If the repo-local executable is still missing and cannot be built, ask the user before installing anything globally. On this PC the expected install command is:

```powershell
winget install --id DEVCOM.LuaJIT -e
```

### Automated tests

Anvil has a first-party Lua runtime test framework in `data/core/test.lua`. Tests use `test.describe`, `test.it` / `test.test`, hooks, coroutine yields, and assertion helpers such as `test.equal`, `test.same`, and `test.ok`.

Never test exact keyboard shortcuts or keymap bindings. Shortcuts are user-configurable workflow choices and may change freely. Test commands and behavior instead, usually by invoking `command.perform(...)` or direct view/model methods.

#### Test quality bar

Tests should verify observable behavior through stable public seams, not implementation details. Prefer seams such as commands, public Document/View/model methods, UI event handlers, parser/indexer APIs, fixture-backed integration boundaries, and Meson test targets. A test should keep passing across an internal refactor when the user-visible or caller-visible behavior is unchanged.

Before adding a non-trivial test, identify the seam being tested. If the right seam is unclear, clarify it instead of defaulting to private state or helper-level assertions.

Good Anvil tests usually:

- describe the behavior in the test name, not the implementation mechanism
- drive behavior through public APIs such as `command.perform(...)`, `core.on_event(...)`, public view/model methods, or widget/event handlers
- assert observable results such as document text, selections, focus, command status, layout/render model state, persisted data, diagnostics, emitted results, or return values
- use independent expected values: literals, worked examples, fixtures, or documented behavior
- cover one meaningful behavior per test, with enough assertions to prove that behavior without checking unrelated details

Avoid tests that:

- assert internal helper calls, call counts, or incidental ordering
- mock internal collaborators when a real Document/View/model can be used
- duplicate the implementation algorithm to compute the expected value
- inspect private fields when a public behavior/state assertion is available
- lock in cosmetic constants or tweakable preferences without testing a durable rule
- add broad speculative coverage for behavior that is not part of the current change

Use fakes/mocks mainly at true external or nondeterministic boundaries: filesystem temp roots, LSP transports/servers, processes, network/http, timers/threads, renderer/window boundaries, and platform integrations.

Give each test its own temp folder under `USERDIR`, and remove it with `test.ok(test.remove_tree(path))`. Child processes, folder watchers and virus scanners can hold a new folder for a moment; the helper retries until they let go.

When a test waits for a real process or background work, give the wait a generous deadline that ends as soon as the condition holds. A loaded machine can take several times longer than an idle one.

#### Durable behavior vs. implementation and tuning details

A user-requested value is not automatically a testable contract. Before adding a
test, classify the requirement as either:

- **Durable behavior**: observable semantics that users or callers rely on.
- **Implementation or tuning detail**: internal mechanisms, cosmetic values,
  thresholds, ordering, timing, or preferences that may change without changing
  the intended behavior.

Test durable behavior through stable public seams. Do not test implementation or
tuning details merely because they are easy to assert. If a change only retunes
presentation or preference, use focused manual or visual verification and avoid
creating a brittle automated test.

Test exact values only when they are externally documented, required for
interoperability, persisted user data, or otherwise necessary for correctness.

#### What to test and what not to test

Prefer tests for stable user-facing behavior and bug-prone logic:

- command behavior
- input/event routing
- focus changes
- selection state
- layout rules with durable semantics
- parsing, matching, indexing, persistence, and edge cases

Avoid tests that only restate tweakable constants or personal visual preferences:

- exact pixel values for cosmetic spacing
- exact width/height breakpoints chosen by taste
- exact keyboard shortcuts
- theme colors
- default UI tuning values

If a visual/layout test is needed, test the durable behavior rather than a magic number. For example, test that a panel clamps to minimum padding when below its configured breakpoint, not that a hard-coded breakpoint is exactly `1200 * SCALE`.

A test should generally fail when there is a bug, not merely because a preference was intentionally retuned. Tests should encode intent, not duplicate implementation/configuration.

#### Keep the suite small

Each test costs run time and upkeep. Add the fewest tests that prove the change.

- Before you add a test, find the test that covers the nearest behavior. Extend it when you can. Add a new test only for a new durable rule.
- When you remove a feature, delete its tests, fixtures and setup. Do not add a test to prove that the feature is gone.
- A test of old behavior, a private detail, or a cosmetic order is a defect. Delete or merge it when you work in its file.
- Each assertion must be able to fail on a real bug. Remove assertions that only repeat the setup.

#### Bugfix regression tests

For user-reported bugs, behavior discrepancies, and new behavior, use a red-green regression workflow by default. Red-green does not apply to a removal. Work in vertical slices: one chosen seam, one targeted failing test, the smallest implementation needed to pass it, then repeat if more behavior is needed. Do not write a broad speculative suite up front for imagined behavior.

Red-green applies after identifying a durable behavioral contract; it does not
turn implementation details or preference tuning into regression requirements.

1. Add or identify a targeted test/repro that demonstrates the missing or broken behavior.
2. Run it before changing the implementation and confirm it fails for the expected reason.
3. Apply the smallest appropriate fix or feature slice.
4. Re-run the same targeted test and confirm it passes.
5. Run the relevant broader suite when appropriate.

Do not skip the red step just because the implementation gap seems obvious. If the fix was already applied before the red step, temporarily revert or disable only the implementation change while keeping the regression test, then run the targeted test to confirm it goes red before committing. If red-first verification is impractical or too costly, call that out before or during the work and mention it explicitly in the final summary.

When reporting a bugfix, summarize the red-green evidence: which targeted test failed before the fix, what failure it showed, and which test/suite passed after the fix.

Current first-party tests live in:

- `tests/lua/runtime` — Anvil-runtime Lua tests for non-visual APIs and behavior.
- `tests/lua/ui` — in-process UI tests for views, widgets, layout, focus routing, rendering helpers, and panel behavior.
- `tests/native` — native C/C++ tests wired into Meson, currently `anvil:fuzzy`.
- `tests/gui/smoke` — actual GUI smoke tests that launch the real app window.

IF THE FEATURE YOU IMPLEMENTED IS SMALL TO MEDIUM-SIZED, ONLY RUN THE SPECIFIC NEW TESTS.
THE WHOLE TEST SUITE SHOULD ONLY BE RAN IF THE FEATURE YOU IMPLEMENTED IS VERY VERY BIG AND CROSSES A LOT OF BOUNDARIES.

Run tests through Meson by default. The full Meson test command now includes Anvil's native fuzzy test plus the Lua runtime and in-process UI suites:

```sh
meson test -C build-windows-x86_64 --print-errorlogs
```

Use the Anvil suite filter when you want to skip third-party subproject tests:

```sh
meson test -C build-windows-x86_64 --suite anvil --print-errorlogs
```

If `meson` is not on `PATH` in the agent/MSYS shell on this PC, call it explicitly and prefix MinGW's bin directory so Meson can find `ninja` for rebuilds:

```sh
PATH=/c/msys64/mingw64/bin:$PATH /c/msys64/mingw64/bin/meson.exe test -C build-windows-x86_64 --print-errorlogs
```

Individual Anvil Meson test targets:

```sh
meson test -C build-windows-x86_64 anvil:fuzzy
meson test -C build-windows-x86_64 anvil:lua-runtime
meson test -C build-windows-x86_64 anvil:lua-ui
```

The Lua Meson tests use `tests/run-lua-tests.sh`, which prepares an isolated app/user/test tree in `%TEMP%/anvil-lua-tests/<suite>.XXXXXX`, sets `SDL_VIDEO_DRIVER=dummy`, and runs `anvil test` internally. This avoids source-tree test pollution and means agents usually do not need to call `./scripts/run-local ... test ...` directly.

Each test file runs in its own editor process with its own user folder, so state that one file leaves behind cannot break a later file. Four files run at once by default. Set `ANVIL_TEST_JOBS` to change that. A file that runs longer than `ANVIL_TEST_FILE_TIMEOUT` seconds (default 300) is stopped and reported as failed.

Each run gets its own folder, so several agents can run the same suite at once. The folder is outside the repo because editors and tools that watch the repo can hold new files open. The runner deletes the folder when the run ends. Set `ANVIL_TEST_KEEP_RUN=1` to keep it for inspection; the runner prints its path. Set `ANVIL_TEST_RUNS_ROOT` to use another parent folder. Each run also deletes folders older than 12 hours.

With `--verbose` on Windows, set `PYTHONIOENCODING=utf-8`. Otherwise Meson crashes when it prints a test name that has non-ASCII characters.

On Windows, Anvil Meson test targets use `anvil_test_env` with a sanitized `PATH` so Meson can print failure logs reliably even if the inherited user environment contains non-ASCII/hidden characters. Add future Anvil Meson tests to this environment unless they explicitly need something else.

To run a specific Lua file or subdirectory without registering another Meson target, pass the path through Meson's `--test-args` to the relevant Lua suite target:

```sh
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args tests/lua/runtime/tokenizer.lua
meson test -C build-windows-x86_64 anvil:lua-ui --test-args tests/lua/ui/markdown_live_editor.lua
```

Short paths under `tests/lua` are also accepted:

```sh
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/tokenizer.lua
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/markdown_live_editor.lua
```

Use `--no-rebuild` only when the build artifacts are known to be current.

#### Test layers

There is not a separate Lua framework for in-process UI tests: they are ordinary Lua runtime tests executed by Meson's `anvil:lua-ui` target through `anvil test`. The difference is the test style:

- **Headless/runtime tests** instantiate non-visual objects such as Documents, commands, fuzzy indexes, processes, threads, and pure helper modules, then assert their state.
- **In-process UI tests** instantiate or reuse Anvil UI objects such as Document Views, panels, prompt bars, widgets, tabs/nodes, fuzzy pickers, and settings views. They drive behavior by calling methods/event handlers programmatically, such as `core.on_event(...)`, `core.root_panel:on_mouse_pressed(...)`, `view:on_mouse_moved(...)`, `node:set_active_view(...)`, or widget `on_change(...)`, then assert Lua state/layout/focus directly. These are the preferred layer for TDD of editor UI behavior.
- **Isolated renderer checks** run the real renderer on a private desktop. Use the [render performance gate](tools/RENDER_PERF_GATE.md) for pixel checks and renderer diagnostics.
- **Scenario runs** measure editor workflows on generated codebases, including large Git repositories, folders outside Git, and background file churn. Run [`tools/run_scenarios.py`](tools/SCENARIOS.md) after changes that can affect frame time. Scenes in `tests/scenes` are shared with Lua tests.
- **Native window tests** check platform behavior through `tools/run_anvil_hidden_desktop.ps1`, such as `tools/run_surface_latency_probe.py` for the shell compositor. Use these only for changes that require native window behavior.

When adding or changing runtime/editor behavior, prefer adding or adjusting Lua tests in `tests/lua/runtime` or `tests/lua/ui` alongside the implementation. Use in-process UI tests for focus, layout, panel, widget, Document View, prompt bar, fuzzy picker, and command-routing behavior whenever possible.

### Non-invasive visual verification

Read [tools/RENDER_PERF_GATE.md](tools/RENDER_PERF_GATE.md) before checking rendered pixels.
The existing runner uses a private desktop, isolated app data, and internal actions.
It captures the D3D11 backbuffer or software surface, not the interactive desktop.
It does not use the dev portable app or its user state.

Use a relevant scenario:

```sh
python tools/run_render_perf_gate.py --scenario renderer-primitives --renderer software --no-build
```

Use `--no-build` only when the build outputs are current.
For a new UI scene, add a focused scenario to this runner instead of creating another capture system.
If no suitable scenario exists, use in-process UI tests until you add one.

Do not capture the screen with `CopyFromScreen`, `PrintWindow`, or an ad hoc OS script.
Do not find, focus, move, close, or reuse the user's windows for verification.
Do not launch the dev portable app as an isolated test process.
Its adjacent `user` directory takes priority over `ANVIL_USERDIR`.
### README screenshots

Run `python tools/showcase/run_showcase.py --no-build` to make `docs/screenshots/workspace.png` and `themes.png`.
It uses the same private desktop with fake Projects from `tools/showcase/projects`. It needs Pi on `PATH`.
The real Pi runs the scenarios in `tools/showcase/agents.json` against a canned model server in the script.
It calls no real model. Pi gets a private agent folder, so no user settings, sessions or extensions appear.
`tools/showcase/pi/showcase.cjs` repeats Pi's status with OSC 7501 `since`, so agent times look real.
Shell command times are real. `themes.png` stacks one Markdown note in each Color Theme.

## Git commits

Agents may commit their changes without separate approval. Create a commit after each complete milestone.

Also create a commit when you fully implement a feature.

Run the applicable checks before each commit. Commit only files that belong to the current task.

Do not include unrelated working-tree changes.

Use one clear commit message for each milestone. Report each new commit hash in the final response.

## Worktree cleanup

After your branch is in `master`, remove your worktree, your branch and your scratch folders. Do not wait for the user to ask.
Remove only what you made. Other agents can still use their worktrees.

A worktree's `subprojects` folder can hold directory symlinks into the main repo's `subprojects`.
A delete that follows a link deletes the main repo's dependencies. Before `git worktree remove --force`, remove the links:

```sh
python -I -c "import os, sys; d = sys.argv[1]; [os.rmdir(p) for p in (os.path.join(d, n) for n in os.listdir(d)) if os.path.islink(p) or os.path.isjunction(p)]" D:/path/to/worktree/subprojects
```

`cmd rmdir` from Git Bash failed on these links. Then remove the worktree, delete the branch with `git branch -d`, and check that the main repo's `subprojects` is unchanged.

## Finalizing changes / updating the dev portable app

The dev portable app runs the main checkout. Its Lua shows after a reload. Its native code shows after `update-anvil-dev-build.bat`.

In a worktree, build and test in the worktree's own build folder. Do not run the portable app's update there.

After you merge to master, run the update from the main checkout if your change has non-Lua files.

The update closes and restarts the user's dev portable app. If it stops at an unsaved-file prompt, report it and do not retry. If the build fails in code that you did not change, report it and do not fix it.

From the agent/MSYS bash, use the `cmd.exe` double-slash form documented below.


### Running BAT files from the agent/MSYS bash

The coding-agent shell runs under MSYS2/MinGW bash in this repo. If you need to invoke a Windows BAT file through `cmd.exe`, use double-slash CMD switches so MSYS does not path-convert `/c`, `/d`, or `/s`:

```sh
cmd.exe //d //s //c "call D:\Projects\c_projects\anvil-editor\update-anvil-dev-build.bat"
```

Do **not** use plain `cmd /c ...` or `cmd.exe /c ...` from this shell; it may only print the CMD banner/prompt and not run the command. The double-slash form was verified to build, install to `..\anvil-portable`, restore junctions, and restart Anvil.

## Vendored/Meson subprojects

Meson refreshes cached Git subprojects before it loads them when their checked-in inputs change.
`scripts/sync-git-subprojects.py` tracks wrap files, local patches, and package files.
The first configure also refreshes existing Git checkouts. Missing checkouts use normal Meson downloads.
A refresh puts local dependency edits in that checkout's Git stash. It does not apply them again.
Line endings do not count as a change. A worktree can link to the main repo's checkouts and copy its state, and gets the same state.
Ignored build caches, such as Zig's, stay in place.
State stays under the ignored `subprojects/.anvil-wrap-state` directory.
Custom library targets must depend on their input state and expose the library as a build output.
Run `anvil:subproject-sync` after changes to this path. Its fixtures use local Git repositories and real Meson builds.

SDL3 is brought in through Meson's wrap system, not as a top-level git submodule:

- wrap file: `subprojects/sdl3.wrap`
- local checkout/build input: `subprojects/sdl3`
- Anvil-owned wrap patches/files: `subprojects/packagefiles/sdl3*`

If changing SDL3 behavior for Anvil, do not rely only on committing inside the local `subprojects/sdl3` checkout. Fresh clones rebuild SDL3 from the wrap, so reproducible changes must be represented in the top-level repo, usually with a patch listed in `subprojects/sdl3.wrap` via `diff_files` or files under `subprojects/packagefiles/sdl3`.

Current Anvil SDL3 patch:

- `subprojects/packagefiles/sdl3-titlebar-mousemove-opt-in.patch`
- listed by `diff_files` in `subprojects/sdl3.wrap`
- makes SDL3's Win32 titlebar synthetic `WM_MOUSEMOVE` workaround opt-in with `ANVIL_SDL3_TITLEBAR_MOUSEMOVE_FIX=1`
- default keeps the workaround disabled because it causes a one-frame cursor blink on normal titlebar clicks

When updating SDL3 upstream, verify this patch still applies. If it fails, rebase/regenerate the patch against the new SDL3 revision and keep it tracked in the top-level Anvil repo.

SDL3 text-drop patch:

- `subprojects/packagefiles/sdl3-complete-text-drop.patch`
- listed by `diff_files` in `subprojects/sdl3.wrap`
- keeps each Windows text drop complete, including blank lines and trailing newlines
- leaves file URI lists unchanged

Keep this patch when updating SDL3 unless upstream preserves complete text drops.
Title Bar drops open files, images, folders, and text in new Panes.
Folders open File Trees, not Projects. Native window controls are not drop targets.
Run `anvil:drop-events` and `ui/external_drop.lua` for focused checks.

SDL3 virtual-file drop patch:

- `subprojects/packagefiles/sdl3-virtual-file-drop.patch`
- listed by `diff_files` in `subprojects/sdl3.wrap`
- reads the `FileGroupDescriptorW` and `FileContents` formats on Windows
- writes each virtual file to `%TEMP%\AnvilDrop-*` and reports a normal file drop
- Outlook attachments and browser download drags use these formats
- virtual files have no file system path, so these drops did nothing before this patch

The materialized copy stays on disk for the session. An edit writes to that copy.
Use Save As to keep a separate version. Keep this patch when updating SDL3 unless
upstream materializes virtual files itself.

SDL3 dead-key reset patch:

- `subprojects/packagefiles/sdl3-dead-key-reset.patch`
- listed by `diff_files` in `subprojects/sdl3.wrap`
- SDL builds its keymap when the input language changes, often while Ctrl+Shift is held
- the build presses each dead key, then presses Space to clear it
- SDL pressed Space with the live modifiers. With Ctrl held, Space types nothing
- the next key then got two characters, and SDL cached U+FFFD for it, such as Spanish `+`
- the patch presses Space without modifiers

Run `anvil:keymap-layout` after SDL3 updates. Keep this patch unless upstream clears dead keys the same way.

A Terminal View pairs each text key with its SDL text input. A text key has layout text and no Ctrl, Alt, or Super.
The view encodes the key with the text that the OS typed, not SDL's keymap text. Kitty mode then gets both.
Run `runtime/terminal_native.lua` and `ui/terminal.lua` after key input changes.

A Terminal View reports light/dark appearance changes to programs that enable mode 2031.
It sends the report after applying all new colors, so programs can query the new palette.
Run `runtime/terminal_native.lua` after changes.

Terminal Views display static Kitty graphics through Ghostty's image API.
Only direct image transfers are enabled. File and shared-memory transfers remain disabled.
The native bridge owns cropped image canvases and reuses them by image generation and source rectangle.
Ghostty snapshots omit images, so programs must retransmit them after reconnect or restart.
Run `runtime/terminal_graphics.lua` and the `terminal-images` render scenario after image changes.
See [inline terminal images](tools/TERMINAL_IMAGES.md) for supported features and limits.

Current Anvil Ghostty patch:

- `subprojects/packagefiles/ghostty-semantic-prompt-fresh-line-option.patch`
- listed by `diff_files` in `subprojects/ghostty.wrap`
- adds a libghostty-vt option for OSC 133 A during synchronized output
- Anvil disables A's fresh-line action only inside synchronized output
- this prevents Pi's differential renderer and Ghostty from tracking different cursor rows
- normal OSC 133 shell behavior remains active outside synchronized output
- `tests/fixtures/terminal_semantic_prompt_repaint.ps1` covers the original Pi sequence

Pi emits OSC 133 A as a zero-width marker during synchronized TUI repaints. Ghostty treats A as a fresh-line command. If Pi emits A outside the first column, Ghostty moves down one row while Pi does not. Pi can then erase the displaced message during a later repaint. Pi issue `#2971` reported the same Ghostty-only problem.

When updating Ghostty, verify this patch still applies. Remove it only after Pi and Ghostty agree on OSC 133 A behavior during TUI repaints.

Anvil sets Ghostty's `GHOSTTY_TERMINAL_OPT_RESIZE_PULL_SCROLLBACK` to false. ConPTY keeps no history, so a resize must not pull history into the live screen.
A height change then adds blank rows at the bottom. A width change keeps the top of the live screen on the same text.
Saved history stays available for scrolling. Run `ui/terminal_revival.lua` and `ui/terminal_resize_prompt.lua` after changes.

Current Anvil Tree-sitter Markdown patch:

- `subprojects/packagefiles/tree-sitter-markdown-scanner-state-bounds.patch`
- listed by `diff_files` in `subprojects/tree-sitter-markdown.wrap`
- prevents the external scanner from closing an empty block stack
- keeps serialized scanner state within Tree-sitter's fixed buffer

When updating Tree-sitter Markdown, verify this patch still applies. Remove it only after upstream includes equivalent scanner bounds.

The LuaJIT wrap pins a commit, not the `v2.1` branch. A branch refresh can pull an untested compiler change.
Upstream commit `b310887` miscompiles some table stores on x64. The JIT then writes through a tagged value, and the editor crashes.
The crash showed as status 139 in `runtime/treesitter_rust.lua` and `runtime/treesitter_parse_followup.lua` under load.
Move the pin past `b310887` only after upstream fixes `asm_ahustore` in `src/lj_asm_x86.h`. Then run those two files in parallel many times.
Use the pinned Zig from `scripts/ensure-zig.sh` when a wrap change reconfigures the build. Another Zig on `PATH` fails the Ghostty build.

## Why not Program Files for dev?

Do not use `C:\Program Files` for this dev install. It causes admin/write-permission issues and makes junction/rebuild workflows annoying. Use the writable folder of the dev portable app instead.

A real installer for `C:\Program Files\Anvil` can be created later for deployment.

## Optional reference source caches

Only consult these external reference sources if the user explicitly mentions them or asks for comparisons/inspiration involving them:

- Fred editor dump:
  - `C:\Projects\my_decomps\fred_src_dump`
  - source root: `C:\Projects\my_decomps\fred_src_dump\D_\git_projects\fred`
- IntelliJ IDEA Community cache:
  - `C:\Users\Darius\AppData\Local\pi-web-smart-fetch\github-cache\JetBrains\intellij-community`

# Domain awareness

During codebase exploration, also look for existing documentation:

### File structure

Most repos have a single context: CONTEXT.md

## During the session

### Challenge against the glossary

When the user uses a term that conflicts with the existing language in `CONTEXT.md`, call it out immediately. "Your glossary defines 'cancellation' as X, but you seem to mean Y — which is it?"

### Sharpen fuzzy language

When the user uses vague or overloaded terms, propose a precise canonical term. "You're saying 'account' — do you mean the Customer or the User? Those are different things."

### Discuss concrete scenarios

When domain relationships are being discussed, stress-test them with specific scenarios. Invent scenarios that probe edge cases and force the user to be precise about the boundaries between concepts.

### Cross-reference with code

When the user states how something works, check whether the code agrees. If you find a contradiction, surface it: "Your code cancels entire Orders, but you just said partial cancellation is possible — which is right?"

### Update CONTEXT.md inline

When a term is resolved, update `CONTEXT.md` right there. Don't batch these up — capture them as they happen. Use the format in [CONTEXT-FORMAT.md](./CONTEXT-FORMAT.md).

Before renaming an existing glossary/context term, always ask the user for explicit confirmation. Do not rename established context language on your own, even if a new name seems clearer.

`CONTEXT.md` should be totally devoid of implementation details. Do not treat `CONTEXT.md` as a spec, a scratch pad, or a repository for implementation decisions. It is a glossary and nothing else.
