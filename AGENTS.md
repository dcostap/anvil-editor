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
portable install strips its executable so the daily launcher starts quickly.

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
daily dev executable. The standalone build uses its own
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

Middle-click scrolling uses Terminal history when the active screen has history. With no history, it sends wheel input through the normal wheel route. Reaching a history boundary does not send application input. Wheel input uses the original click position and keeps fractional movement between frames. Each frame sends a bounded number of events and discards excess whole ticks. Run `ui/middle_click_autoscroll.lua` and `ui/terminal_mouse_wheel.lua` after changes. Use the `terminal-autoscroll-history` scenario to measure history scrolling.

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

Pane Close skips confirmation when Pi reports `idle` or `done`, even while its shell command remains busy.
Window Close asks once for its live Terminal Sessions, including idle shells and idle Pi.
Keep running detaches them. End all ends them but keeps their revival records. Cancel stops Window Close.
An idle shell that only a Pane's Navigation History keeps does not count. An accepted quit closes it and removes its history entry and record, so it does not restore.
A history shell that is busy, starting or reconnecting, or that runs a program such as Pi, still counts.
The shell shares the choice across that Window's Projects, not other Windows. A later Window Close asks again.
Project unload and direct mode ask each time.
An ended session is not closed. It revives in its Pane on the next start.
The host gets `ANVIL_TERMINAL_END`. It stops the shell, but keeps the record, the screen and the Pi report.
The session keeps its ID, so its Snooze, seen time and Pi session stay. Only a Pane close removes them.
Older hosts read `END` as a disconnect and keep running. Run `ui/terminal_quit.lua`, `ui/terminal_revival.lua` and `ui/terminal_agent_resume.lua` after changes.
Pane Close keeps the normal busy check for other agent states. Reconnecting sessions still require confirmation.
The host sends the root Agent Status with its live status packet. Older hosts keep the normal busy check.
Run `ui/terminal_quit.lua`, `ui/terminal_agent_status.lua`, and the `windows-close-terminals-keep` and `windows-close-terminals-end` shell probes after changes.

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
Project rows offer Move, Unload or Open in New Window, Copy Path and Show in File Explorer. Terminal Tabs offer Snooze.
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
This Project's "No matches" status is hidden while other Projects show rows.
Run `ui/fuzzy_searcher_other_projects.lua`, `ui/fuzzy_searcher_terminals.lua` and the `launch-file-search` shell probe after changes. The probe reports the answer times of both modes.
Each group has a divider and a small, dim header. Check the `fuzzy-picker-other-projects` and `fuzzy-picker-other-text` render scenarios after visual changes.

File Search shows all its rows at once. Paged lists load the next page one screen before their end. A refresh keeps the selected row.
A picker that opens with the same non-empty query as at its last close selects the same row again, at the same place on the screen. An empty File Search starts at its first row.
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
It updates the welcome logo, Windows ICO, macOS ICNS, and native window icon.
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
  - installs a dev portable app to `..\anvil-portable`
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
  - uses the normal dev portable data and user directory
  - use this only when native debugger/symbol information is needed

`scripts/start-dev-anvil.ps1` starts the app after setup and updates. Do not replace it with `Start-Process` or CMD `start`.
Those calls keep the caller's Windows job. A later Terminal Close can then kill the restarted editor.
Run `anvil:dev-update-launch` after changes. It uses a windowless test app, not the daily editor.

Daily launcher target:

```text
..\anvil-portable\anvil.exe
```

The daily launcher is the stripped executable. Do not switch it back to the
unstripped build output; use `launch-anvil-debug.bat` for native debugging.

## Launch mode

On Windows, Anvil starts the native shell by default. The shell owns the
Windows, the Project Sidebar, and one hosted process for each loaded Project.
`--shell` is still accepted.

These launches run the Lua application without a shell:

- `--direct`, which is removed before the Lua command line is parsed
- CLI commands such as `test`, `help`, `list`, `repl`, `run`, and `edit`
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
The Sidebar View lists it first and names it "Scratch". Its new Terminals start in `HOME`.
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
Sidebar width and the Project list remain shared. Each Window saves its own Project and group folds.
Loaded Projects start expanded unless this Window has a saved manual fold.
Selecting a Project expands it and saves that state. It stays expanded after it loses the selection. The first selection in a restored Window keeps its saved fold.
Window IDs persist across restart. The saved allocation sequence prevents reuse of a closed Window's folding state.
Run `anvil:shell-state`, `ui/sidebar_view.lua`, and the `windows-sidebar-layout`, `windows-sidebar-folding`, and `toggle-sidebar` shell probes after changes.

A Dormant, failed or absent Selected Project has no process to take keys. Its Window's Sidebar then takes the keyboard and keeps it.
Escape and the Sidebar focus command do not release it. A hidden Sidebar slides open.
The keyboard goes back to the Project when the user selects a Project that can take keys, or restarts the failed Project.
Run the `dormant-last`, `recovery` and `navigate-sidebar` shell probes after changes.

The shell draws its own text, such as the Dormant card and the Title Bar name, in Fira Sans, the Sidebar's typeface.
The executable carries the font as a resource (`resources/windows/ui_font.rc`), so the shell needs no data folder.
The Dormant and failed cards look like the editor's dialogs (`core.nagview`): same sizes, card colours, shadow and buttons.
`color_theme.shell_colors` sends those colours. Over a failed Project's last frame, the shell blends the card with its shadow.
The card names the Project and its state. The shell logs the card's button rects, and the `recovery` probe reads them.

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

## Renderer selection

The dev portable build defaults to the D3D11 command renderer on Windows. Do not use the old two-flag test setup (`ANVIL_D3D11` plus `ANVIL_D3D11_COMMANDS`) for normal launches.

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

### DATADIR vs USERDIR in the dev portable install

`DATADIR` is the bundled app data root. In the dev portable install, the editable data directories are Windows junctions back to this repo:

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

## Heading Outline

Markdown Live Preview lists the headings left of the reading lane when the free space can hold the list.
It reads the tree-sitter outline, the same list as Current Buffer Symbol Search.
The top heading level and two levels below it show. The current section is the last heading above the top quarter of the view.
After the caret moves, the current section is the caret's section instead, until the user scrolls with the wheel or the scrollbar.
Each Pane's outline follows its own caret. The Buffer's selection belongs to the focused Pane, so the outline uses a selection listener on its Text View.
A click moves the caret to the heading and scrolls it near the top with `scroll_to_line`'s `top_margin`. That heading is then the caret's section.
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

## Reload from disk

`Buffer:reload()` applies the file's text as edits through `Buffer:apply_lines`. It does not replace the Buffer.
Selections, the visible text, bookmarks and other text positions move with the text. One undo reverts the reload.
`Buffer:undo()` and `Buffer:redo()` return the type of the step they applied. A reload step does not merge with other steps.
Autoreload flashes the lines and shows a status message when an undo or redo applies a reload, because Autosave then writes it to disk.
A reload does not call `Buffer:load`. Plugins that track the disk state hook `Buffer.reload` as well.
A Text View without row measurements keeps its top line when lines change above it, like a measured view.
See [shared editing](docs/shared-editing.md) for the plan: dirty-Buffer merges and Disk Conflicts.
Run `ui/buffer_reload.lua` and `runtime/buffer_apply_lines.lua` after changes.

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

Starting a child process can block for hundreds of milliseconds on Windows.
Do not call `process.start` on the UI thread for recurring work.
Submit a `process_capture` job instead. Git uses `worker_pool.named("git")` through `plugins.git.backend.run_git`.
For output that must stream while the process runs, such as ripgrep, use `core.process_stream`.
Cancel each stream you stop reading; an unread stream holds its worker once its output window fills.
The UI loop drains named pools and shuts them down with the system pool.

## Native code and Lua garbage

Lua must not limit the editor's speed. We port slow Lua to C, but only where a measurement shows that the port is worth it.

### Measure first

Do not port code to C because it looks slow. Measure it first.

1. Run the scenario that shows the problem with `--diagnose`. It writes a sampled profile and timers by phase. See [scenario runs](tools/SCENARIOS.md).
2. Find where the time goes in the attribution `details.csv` and profile stacks. Use `--heap` to measure retained Lua objects.
3. Ask if the work is necessary. Work that is not necessary is the largest win, in any language. Examples:
   - The Heading Outline ran the outline query on the whole note for each key. The worker's parse already had the headings.
   - Two callers joined the whole note into a Lua string for each edit, only to give it to C.
4. Port to C only work that is necessary and slow in Lua.

A port is worth it when the measurement shows one of these:

- A hot loop over plain data, such as rows, heights, or text positions.
- Work for each line or item of a document, where the count grows with the document.
- Large data that stays in memory, as a heap census shows.
- High GC or interpreter time in the profile for that code.

A port is not worth it when the profile shows the time elsewhere, or when the code is glue, decisions, or behavior that changes often. A Lua error is caught. A crash in C ends the editor.

Move these to C:

- Hot loops over plain data, such as arrays of rows, heights, or text positions.
- Large data that stays in memory, such as line layouts, token arrays, or document models.
  LuaJIT's GC has no generations. Each GC cycle marks all live Lua objects again, also data that does not change.
  Data in C memory adds no GC work.

Keep glue code, plugin logic, and editor behavior in Lua.
C does not remove garbage from glue code, because the values still go back to Lua.
Lua calls the C code once for each edit, batch, or frame.
A LuaJIT trace stops at each C call, so a call for each item can be slower than Lua.

Code that runs in each frame, such as `update`, `draw`, and caret moves, must not make new tables, closures, or strings when old ones can be used again.

In the commit message, give the measurement before and after the change.

### How to port

Port in small slices. Do not rewrite a module at once. For each slice:

1. Measure the slice before the change.
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

The cost is Lua work for each line, spread over many functions. No single loop is hot. So port the pipeline, not the editor:

- C keeps the data for each line: style runs, wrap breaks, row heights, and line metrics. A worker thread can make them from the Buffer text and the tree-sitter parse.
- Lua keeps the decisions: what shows at the caret, widgets, clicks, and editing behavior. Lua reads results with a few calls for each frame.
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

Add native modules under `src/api` with the portable Lua C API, not FFI. The PUC Lua build must still work.

## Tree-sitter language support

Read [Tree-sitter language maps](data/treesitter/languages/README.md) before adding a language or changing symbol selection.
Review its outline and usage queries.
Update the language review and focused symbol tests when coverage changes.
Keep grammar-specific work in that language's folder.
Do not add a separate query pattern for each pointer depth or similar syntax nesting.

## Lua/plugin development

Built-in plugins live in this repo under `data\plugins`.

The dev portable install uses junctions:

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
It does not use the daily portable app or its user state.

Use a relevant scenario:

```sh
python tools/run_render_perf_gate.py --scenario renderer-primitives --renderer software --no-build
```

Use `--no-build` only when the build outputs are current.
For a new UI scene, add a focused scenario to this runner instead of creating another capture system.
If no suitable scenario exists, use in-process UI tests until you add one.

Do not capture the screen with `CopyFromScreen`, `PrintWindow`, or an ad hoc OS script.
Do not find, focus, move, close, or reuse the user's windows for verification.
Do not launch the daily portable app as an isolated test process.
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

When a change or feature is finished and non-Lua files were edited, run the relevant BAT file from the repo root so `..\anvil-portable` is updated. For non-Lua changes, usually run:

```text
.\update-anvil-dev-build.bat
```

From the agent/MSYS bash, use the `cmd.exe` double-slash form documented below.

C/C++ edits require a rebuild and restart. For edits under junctioned data directories, validate syntax and reload or restart Anvil.


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

## Why not Program Files for dev?

Do not use `C:\Program Files` for this dev install. It causes admin/write-permission issues and makes junction/rebuild workflows annoying. Use the writable dev portable folder instead.

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
