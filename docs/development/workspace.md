# Panes, Sidebar and Windows

The native Windows shell owns single-instance launch routing. Set `config.single_instance = false` to disable the direct editor's native handoff. No Lua IPC service runs alongside it. Run the `launch-forward`, `launch-files`, and `windows-new` shell probes after launch changes.

## Pane History and focus replacement

Pane History is the order of the Panes that the user visited across Projects in one Window. Each Window has its own history. `pane:history_back` and `pane:history_forward` move through it; `pane:history_oldest` and `pane:history_newest` go to its ends.

Each observed Pane focus counts as a visit. A history move adds no visit. When the user leaves a Pane that a move showed, that Pane goes again at the end, so no visit is lost.

Returning to the same Pane after another Window had focus keeps the history position, including its Forward entries. The Panes of one Pane Group are one place. Consecutive visits to one Pane Group make one entry, for the last Pane that the user visited there.

A focus change inside the current entry's Pane Group keeps the history position. Moves skip entries in the current Pane's group. The combined history compresses repeated consecutive Pane sequences, such as A → B → A → B, into their later copy.

It preserves the current position. Pane identity includes its Project, so equal IDs in different Projects stay distinct. Each Project keeps its last 40 visits (`core.pane_history`) and sends them as `history` in its Pane report.

Each entry has the Pane ID and the time in milliseconds. A move entry also names the entry that it showed (`to`). A move to another Project sends that name in its `focus` Pane request.

Moves skip closed, Snoozed and Dormant Panes. Visits are not saved across restarts. Run `ui/global_pane_history.lua`, `ui/recent_panes.lua` and `ui/pane_requests.lua` after changes.

Automatic Pane focus replacement returns to the most recently focused eligible Pane in the same Project. It skips Snoozed Panes and attention marks outside the old Pane Group. A marked Pane in that group remains eligible because it already showed beside the removed Pane.

Without recorded focus, it prefers the nearest eligible Pane in the same Pane Group, then another group. It does not switch Projects. Closing a background Pane keeps the current focus.

It checks all marks, not only numbered Panes. When the Current View closes and its history reveals a marked Terminal, that Pane does not take focus. With none, the Project shows its Project Launcher.

Close, Snooze, Terminal exit and completed cross-Project Pane transfers use this rule. Closing a Current View also uses it when its history reveals a marked Terminal. Workspace restore uses it when the saved selection cannot restore.

Explicit selection, navigation, View moves and valid saved selections keep their targets. Alt+Left reopens the last closed Pane. Close keeps the keyboard in the Project or Sidebar that has it.

Run `ui/panes.lua`, `ui/recent_panes.lua`, `ui/snoozed_panes.lua`, `ui/pane_requests.lua` and `ui/pane_workspace.lua` after changes.

## Project Launcher

The Project Launcher (`core.project_launcher`) shows while no Pane Group shows. A new Project starts empty, with the Launcher. The Root Panel draws it over the wallpaper: the Project's badge and name (only the name for Scratch), and a row of buttons: File Tree, Terminal, Pi and Open in OS File Explorer.

Each button runs its command in a new Pane. Open in OS File Explorer opens the Project's folder. The Scratch Project has no folder buttons, and a Project on a Machine has no Open in OS File Explorer button.

With no View to take keys, the Root Panel sends unused keys to the Launcher. It uses the bindings of Dialog focus, confirmation, Point of Interest Activation, prompt submission and caret moves. The Launcher starts with no keyboard selection.

The first move key selects the first button, and confirmation does nothing until then. Keyboard activation of a Sidebar Project row selects the first button immediately. A forwarded Sidebar key also selects it if the key gives the Project the keyboard and leaves its Launcher showing.

Mouse entry does not select a button. Run `ui/project_launcher.lua` after changes. Check the `project-launcher` render scenario after visual changes.

## Sidebar rows and menus

A Terminal without that icon shows the Terminal View's icon. Terminal Tabs have no status dot. A Sidebar Tab's name that does not fit wraps onto a second line, which ends with an ellipsis when the name is still too long.

The icon, the attention dot and the note stay on the first line. The row grows by one line. The Project Sidebar marks only an Unread Result or an agent that waits for an answer.

The mark is a dot, a bold name, and a coloured stripe that fades out to the right. It saves when the user last looked at each Terminal Session. Run `ui/sidebar_view.lua` after changes.

A marked row that the scroll hides shows in an Attention Pill at that edge of its list. A click on the pill scrolls to the nearest hidden row. A collapsed loaded Project's count does not count, because its marked Terminals keep their rows.

The list scrolls by itself only for a new selected row or a keyboard cursor move. Model updates keep the user's scroll. The hover highlight stays under the pointer while the list scrolls.

Run `ui/sidebar_view.lua` after changes. Check the `project-sidebar-pills` render scenario after visual changes.

A right-click on a Sidebar row opens its Context Menu. The Context Menu key opens the cursor row's menu. The Sidebar draws it with `core.context_menu`, the same menu as in the editor.

Its items are `sidebar:` commands. The Sidebar surface covers the whole Window. Its strip ends at `content_x`, so a menu can extend over the Project.

The Sidebar reports the menu's rectangles as raised areas. The shell draws them above the Project. While they show, the shell sends all pointer and keyboard input to the Sidebar.

Project rows offer New Terminal, New Pi, Move, Unload or Open in New Window, Copy Path and Show in File Explorer. A loaded Project also offers Reopen Closed Pane. The Scratch Project offers only New Terminal, New Pi and Reopen Closed Pane.

The Sidebar does not unload it. Tabs offer Duplicate and Close. Terminal Tabs also offer Snooze, and Mark as Read for an Unread Result.

New items, Reopen, Duplicate and Close go through the select route, so the user sees the result or a close question. The `perform` Pane request runs a named command in its Pane, or in the Project. A View that it opens takes a new Pane.

Run `ui/sidebar_view.lua`, `ui/context_menu.lua` and the `project-menu`, `project-menu-background`, `terminal-focus` and `windows-move` shell probes after changes.

## Simple Mode

Simple Mode (`config.simple_mode`, `core:toggle_simple_mode`) adds the Menu Bar to the Title Bar: the Sidebar toggle, the Project name, the Menu Bar, then the Tabs. A gap on each side keeps the Menu Bar apart. It is for users who edit text and Markdown files and do not use the Command Palette.

Help > Exit Simple Mode turns it off. The Title Bar shows the Menu Bar while the Sidebar shows and while it is hidden. The Menu Bar and the Tabs share the Title Bar's first client region, so a press on a label does not drag the Window.

The Project name still drags it. The toggle saves `simple_mode` in `user_settings.lua`. It sends `ANVIL_SURFACE_MSG_SIMPLE_MODE_SAVED`, and the shell sends `simplemodechanged` to the other Projects and the Sidebar.

The Sidebar reads the saved value at startup, as it does for `sidebar_peek`. `core.simple_menu` defines the menus. Each item names one command and runs in its own Project.

A label opens its menu with `core.context_menu`. Items with `show_disabled` show dim when their command cannot run. A View toggle that is on shows a check.

While a menu shows, the pointer on another label opens that label's menu (`on_mouse_moved` of `context_menu.open`). The menus read command state only when they open. Do not put menu state in the Pane report: a change there makes the Sidebar rebuild its model, also during a Sidebar slide.

Simple Mode also hides New Terminal and New Pi in the Project menu, and puts a New File button in place of the Terminal and Pi buttons in the Project Launcher. Run `ui/simple_mode.lua`, `ui/titlebar.lua`, `ui/context_menu.lua` and `ui/project_launcher.lua` after changes. Check the `titlebar-simple-menu` render scenario after visual changes.

## Snooze

A right-click on a Terminal Tab in the Sidebar sets or removes a Snooze. The Sidebar saves each Snooze as a Unix time in `storage/sidebar/snoozes`, beside the seen times. `tab.attention` holds a Terminal's attention until that time.

The Sidebar wakes at the next Snooze time. A Snooze whose time has not come stays saved, even when the model does not list its Terminal Session. The Sidebar then sends `snooze` or `unsnooze` to the Pane's Project through the direct route.

The Project moves a Snoozed Pane into its own Pane Group with the `snoozed` flag, saved in the Workspace. Pane navigation, Pane numbers and the Title Bar skip it. A focus request still shows it.

A Sidebar drop cannot snooze a Pane. The Snoozed fold takes a drop after the Project's other Tabs. A Snoozed Tab that the user drops, in the Sidebar or on the Project's Panes, wakes.

The Sidebar removes its saved time first, and the Project wakes it before a drop on its Panes, because the two requests take different routes. The Pane report marks it, and the Sidebar lists it in the collapsed Snoozed fold at the end of its Project. Snooze uses the shared automatic Pane focus replacement rule.

Saved Snooze recovery keeps the shown Pane. The fold shows the mark of a Snoozed Pane that needs the user, also in a collapsed Project. Collapsed Projects and Dormant Projects show a coloured count of Terminals that need the user.

Collapsed age groups show their total. A Pi question counts during a Snooze. Other attention stays hidden until the Snooze ends.

Each Project checks the saved times every 5 seconds (`core.snoozed_panes`). It does not change focus. Saved times repair a current Terminal View's missing Snooze flag, also after Workspace restore.

A Terminal in Navigation History cannot hide the current View. A failed or invalid read wakes nothing. The Sidebar applies a Snooze change only after its save succeeds; a failed save keeps the previous time and sends no Pane change.

Due Panes wake into new Pane Groups at the end, at most three side by side, oldest Snooze first. A shown Pane wakes in place. The Sidebar also saves each Snooze's start and end in `storage/sidebar/snooze_spans`.

A new time for a Snooze that has not ended keeps its start. Only the Sidebar reads this file, and a failed save of it does not fail the Snooze. After the wake, the Terminal's row shows the clock, the Snooze's length and the time since the wake, such as `12h · 12m ago`, in the place of the time left.

A tooltip on it gives the sentence. Looking at the Terminal ends the attention mark, but not this note. The note ends when the Sidebar model shows new work after the wake: an agent turn that started after it, or a shell command that started after it.

A turn that ran at the wake and ends later is not new work. A turn that starts and ends between two models does not count. Remove Snooze and a new Snooze also end the note.

Run `ui/snoozed_panes.lua`, `ui/sidebar_view.lua`, `ui/pending_panes.lua` and the `terminal-focus` shell probe after changes.

## Pane numbers

Tabs show Pane numbers shared by the Projects in their Window, not Tab positions. Each Window has its own numbers. `core.numbered_panes` selects `core.pending_panes`.

Unread Results and agents waiting for an answer get numbers 1 to 3, newest pending event first. A new event takes its number after `pending_panes.HOLD` (0.25 s), so a number key still reaches the Pane that the user saw. The Sidebar and the Title Bar draw again at that time.

The Sidebar passes its shared seen times. Projects read the persisted seen times with a short cache. Recent Panes fill unused numbers after Pending Panes, without duplicates.

The current Pane gets no focus-history slot. `core.recent_panes` supplies the focus history. There is no numbering setting.

Each Project stamps its active Pane when the Pane takes keyboard focus. The Pane report sends the stamps. The report's `navigation_window` identifies the Window of its focus stamps and history.

Readers ignore those fields after a move until the Project reports its new Window. A Project fetches the reports when it takes keyboard focus. Focus-history numbering ranks these stamps across Projects in the same Window.

Moving a Project to another Window clears its focus stamps and Pane History. Pending Panes join the destination Window's numbers. Other Windows' Tabs have no numbers in this Window's Sidebar, also during a search.

The shell also notifies each Window's Selected Project when the Sidebar model changes. Selected Projects fetch the changed state, so Pending Pane commands work without a keyboard focus change. `system.get_time()` reads one clock for all processes, so stamps from different Projects compare.

A Title Bar in a Window without focus can show old numbers until its Window takes focus. Run `ui/pending_panes.lua`, `ui/recent_panes.lua`, `ui/titlebar.lua` and `ui/sidebar_view.lua` after changes.

## Sidebar keyboard routing

The Sidebar process has no Buffer or Text View. Its search field uses `core.line_input`. The Sidebar reads the user's bindings for the editor's line commands, such as `core:select_to_start_of_indentation`.

The Sidebar keeps list navigation, search-field editing, Sidebar focus, Numbered Panes and Pane History. Pane History commands run in this Window's Selected Project, not the cursor row's Project. Copy (`core:copy`'s keys) copies the cursor row's name: a file Tab's path as File Search shows it, absolute outside the Project Paths, a Terminal's shown title, or a Project's path.

The search field's copy goes first while it has a query. It sends each other key with Ctrl or Alt, and each function key, to the cursor row's Pane, or else to its Project. A row without a Project sends the key to the Selected Project.

Do not add Sidebar copies of editor commands. A sent key gives the keyboard to the Project. The keys of Close Pane, Close Others and Reopen Closed Pane keep it in the Sidebar.

The Project takes it when such a key asks a question, such as a close of an unsaved file. A Snooze hours field opened from the focused Sidebar keeps the keyboard there when it closes. When only the Window loses focus, such as for Alt+Tab, the Sidebar keeps the keyboard.

The shell sends `ANVIL_SURFACE_FOCUS_INACTIVE`, so the cursor, the search and the hours field stay. A new keyboard focus starts at the selected row with an empty search. A Move of the Selected Project to another Window keeps the source Window's focused Sidebar, as an unload does.

A Close choice takes the keyboard from the Sidebar. Run the `windows-move` and `windows-move-close` shell probes after changes to these rules. Run `ui/sidebar_view.lua` and `ui/sidebar_navigation.lua` after changes.

## Peek

A Peek shows the Sidebar cursor row's content in the Project area while the Sidebar has the keyboard (`SIDEBAR_PEEK`). Cursor moves closer together than 90 ms show only the row where the cursor stops. `config.sidebar_peek` turns Peek on.

It defaults to false. The Sidebar process reads it from `user_settings.lua` at startup. The `peek` probe turns it on.

The Sidebar sends the Project ID, the Pane number (0 for a Project row) and its cursor highlight's place in each frame of its glide. A Dormant Project, or a Project in another Window, gets `0xffffffff`: the shell dims the current frame. The shell configures the target with `render_enabled` and `peek_pane`.

The target draws the Peek Pane's group (`panes.shown_group`) and changes no state: no focus, Current View, Pane History, focus stamp, seen time, Workspace save or Terminal resize. A Terminal does not resize while its Pane is hidden. The shell keeps the target's frames in `peek_presentation`, so the Selected Project's frame stays ready and the end of a Peek is immediate.

It draws a dim (`veil`) for a row without content, or for a target that has not drawn in 250 ms. It also draws a crossfade with a drift against the cursor's direction, an accent lens and a bead beside the cursor highlight. The lens frames the Project area.

When the Peek Pane's group has other Panes, the frame names the Pane's rect (`peek`); the lens frames that Pane and the other Panes dim. The Sidebar extends the highlight to its edge. The pointer does not reach a Peek.

A press ends it and gives the keyboard to the Selected Project. Losing the keyboard or a selection ends the Peek. Enter on the peeked row sends a commit first.

The selection then keeps the peeked frame as its held frame, so no other frame shows. The Sidebar sends no further Peek message for that row, because one would cancel the commit. Without a selection in 1.5 s, the Peek ends.

Run `ui/sidebar_view.lua` and the `peek`, `select-hold`, `select-terminal-hold` and `navigate-sidebar` shell probes after changes.

## Launch mode

On Windows, Anvil starts the native shell by default. The shell owns the Windows, the Project Sidebar, and one hosted process for each loaded Project. `--shell` is still accepted.

These launches run the Lua application without a shell:

- `--direct`, which is removed before the Lua command line is parsed
- CLI commands such as `test`, `help`, `list`, `repl`, `run`, and `edit`
- `serve`, the Machine server
- `--help`, `-h`, `--version`, and `-v`
- the shell's own Project and Sidebar processes

`src/launch_mode.h` owns this rule. `anvil:launch-mode` tests it. Tools that measure the Lua application alone pass `--direct`.

Other platforms have no shell and always run the Lua application.

One shell runs for each executable and user folder. The shell key uses resolved paths. A launch through `C:\Projects`, a link to `D:\Projects`, reaches the same shell.

A different executable with the same user folder, such as `launch-anvil-debug.bat`, starts a second shell. If a Project is open in another instance, selecting it raises that instance. The Window keeps its other Projects.

The `launch-link` and `launch-handoff` shell launch probes cover this.

## External launch and Scratch

An external launch selects its Project in the Window that the user activated last, as a Sidebar click does. A folder argument names the Project. File arguments open in new Panes of the deepest known Project that contains them all.

Known Projects are the Sidebar list, loaded or Dormant. Other files open in the Scratch Project. A launch with files waits up to 5 seconds for the first Sidebar list.

Inside Anvil, confirming one file in Open File, Path Search, or Project File Search also checks the known local Projects. With no match it keeps the current Project, not Scratch. Multiple file selections keep their existing destination.

A Terminal launch keeps its Terminal's Project. A cold start without saved Windows still opens a file's own folder. Run the `launch-files`, `launch-forward` and `restore-argument` shell probes after changes.

The Scratch Project's folder is `USERDIR/scratch`. The shell makes it at startup and again before a launch uses it. The shell marks its Sidebar row with `scratch`.

The list bound never removes that row. The status scan reads its Terminal Sessions while it is Dormant. The Sidebar View lists it first in every Window, also when another Window holds it.

It draws it as a section header named "Scratch", like the age groups, with no badge. Its Tabs show below the header. Its new Terminals start in `HOME`.

Scratch follows the selection. Selecting it in a Window that does not hold it moves it there, through the normal Project Move. New Window selects Scratch the same way.

The Window that loses Scratch stays open, and shows its Sidebar if it has no other Project. An external launch into Scratch also moves it, to the Window that the user activated last. Lua finds it with `core.is_scratch_project`, which compares paths and does not resolve links.

Run `ui/sidebar_view.lua`, `ui/terminal.lua` and the `launch-files` and `windows-move` shell probes after changes.

## Window state and Close

Shell App State keeps each Window's loaded Projects and Selected Project. Shutdown captures their paths before closing the hosted processes. Dormant Projects stay dormant.

Restore starts Selected Projects first, then the other loaded Projects through the existing staggered startup. Run `anvil:shell-state` and the `restore-loaded` shell launch probe after changes.

Window Close (`core:close_current_window`, the Close button, Alt+F4) closes one Window. Its Projects become Dormant. The last Window's Close ends the shell, and App State keeps that Window.

Other Windows go on the closed-Window list. Close All Windows (`core:close_all_windows`) saves every Window first, then turns off App State saves. The next start opens them all.

It closes one Window at a time, front Window first. The next Window closes after each Project of the previous Window has decided. It asks once about the Terminal Sessions of all Windows (`ask_all`).

Later Windows reuse that choice. A Cancel stops Close All and turns saves on again. Windows that closed before the Cancel go on the closed-Window list.

The shell's quit event uses Close All. Taskbar "Close all windows" sends one Window Close to each Window. Reopen Closed Window (`core:reopen_closed_window`) opens the newest closed Window with its ID, bounds, Selected Project and other loaded Projects.

App State keeps 10 closed Windows. A Window without a Project does not go on the list. A Project that another Window shows stays there.

Run `anvil:shell-state` and the `windows-close-all-terminals`, `windows-close-all-cancel` and `windows-close-reopen` shell probes after changes.

## Alt Navigation

Alt Navigation copies the user's AutoHotkey script (`alt_navigation.ahk`) for a PC without it. `core:toggle_alt_navigation` turns it on or off. The shell owns it, because all keys pass through the shell.

Shell App State saves it. The default is off. `src/alt_navigation.c` turns one Alt chord into key events, such as Alt+J into Ctrl+Left.

Chords match physical keys, so the Ñ key is `;` on a US layout. Like AutoHotkey's Send, the events release Alt, press the result's modifiers, then restore Alt. Lua's modifier state stays correct, so a later click is not a Ctrl+Click.

The shell drops the release of a replaced key. Alt+Space also sends a text-input space. Run `anvil:alt-navigation`, `anvil:shell-state` and the `alt-navigation` shell probe after changes.

## Sidebar visibility, order and folds

Project Sidebar visibility belongs to each Window. The first Window and each New Window start expanded. A Window that opens for one Project, such as Open Project in New Window or Move to New Window, starts collapsed.

Restored Windows use their saved visibility, including a lone Window saved with its Sidebar hidden. Focus slides a hidden Sidebar open until the Sidebar loses focus. The Window still saves it as hidden.

The toggle closes a visible Sidebar, also a hidden Sidebar that focus shows. A slide shows one step at each display refresh. A docked Sidebar keeps its space in the Project during its whole slide, so it slides over the Project's backdrop and wallpaper.

A Sidebar that focus shows floats: it slides opaque over the Project, and the Project keeps its layout. The toggle docks it. The shell moves the Project's last frame to a docked Sidebar's edge, so a Project that has not drawn its new width shows no content under the Sidebar.

Sidebar width and the Project list remain shared. Each Window saves its own Project and group folds. A click on a Project row acts when the button is released on the same row.

Clicking a loaded Project row in this Window expands or collapses it without selecting it. An empty Project selects itself and takes the keyboard for its Project Launcher. Clicking a Tab selects its Project.

A drag of a loaded Project row in the main list moves that Project. The other Projects slide out of its way, and the dragged Project lifts on a card. The drop sends `reorder` with the row, its new neighbour, and before or after.

The Sidebar keeps the new order until the shell's model shows it. The shell keeps one Project order for all Windows (`anvil_sidebar_move`). The `project` lines of Shell App State are in Sidebar order.

At startup, `anvil_sidebar_apply_order` applies that order after the first recents merge. A Project that the saved order does not name goes first. Scratch stays first and Dormant Projects stay in their age groups.

Run `anvil:project-sidebar`, `anvil:shell-state`, `ui/sidebar_view.lua` and the `restore-order` and `project-reorder` shell probes after changes. Check the `project-sidebar-reorder` render scenario after visual changes. Dormant Projects and Projects in other Windows open when their rows are clicked.

Loaded Projects start expanded unless this Window has a saved manual fold. Another Window's Project stays collapsed. It ignores this Window's saved fold.

A search still lists its Tabs. Other Windows' Projects use 50% opacity and sit above the age groups in the Sidebar's bottom area. Their visible children stay with them.

The Scratch Project is not one of them: it stays first in the main list at full opacity. Selecting a Project expands it and saves that state. It stays expanded after it loses the selection.

The first selection in a restored Window keeps its saved fold. Window IDs persist across restart. The saved allocation sequence prevents reuse of a closed Window's folding state.

Run `anvil:shell-state`, `ui/sidebar_view.lua`, and the `windows-sidebar-layout`, `windows-sidebar-folding`, and `toggle-sidebar` shell probes after changes.

## Empty and failed Projects

An unload of a Window's last Project leaves the Window without a Project. Its Project area shows only the wallpaper, with no card or button. No Project process draws that Window, so the shell sets `backdrop` in the Sidebar's configuration and shows the Sidebar's whole frame.

The Sidebar draws the wallpaper with `core.wallpapers`, as a Project without Panes does, then its strip over it. It reads the wallpaper choice from the user settings when a Window loses its Project. Until that frame arrives, the shell shows the plain background.

The Sidebar opens there without a slide. The "Starting" text and the failed card stay on the plain background. A Window without a Project, or with a failed Selected Project, has no process to take keys.

Its Window's Sidebar then takes the keyboard and keeps it. Escape and the Sidebar focus command do not release it. A hidden Sidebar slides open.

The keyboard goes back to the Project when the user selects a Project that can take keys, or restarts the failed Project. Run the `dormant-last`, `shell-empty`, `recovery` and `navigate-sidebar` shell probes after changes. `shell-empty` checks the wallpaper's pixels.

The shell draws its own text, such as the failed card and the Title Bar name, in Fira Sans, the Sidebar's typeface. The executable carries the font as a resource (`resources/windows/ui_font.rc`), so the shell needs no data folder. The failed card looks like the editor's dialogs (`core.nagview`): same sizes, card colours, shadow and buttons.

`color_theme.shell_colors` sends those colours. Over a failed Project's last frame, the shell blends the card with its shadow. The card names the failed Project.

The shell logs the card's button rects, and the `recovery` probe reads them.

## Window controls and shutdown

The shell draws the Window controls with the Windows caption glyphs: Segoe Fluent Icons, or Segoe MDL2 Assets on Windows 10. Its hit test reports the Maximize button as `HTMAXBUTTON`, so Windows 11 shows Snap Layouts there. The shell handles that button's non-client press itself.

Windows' own button tracking would draw its hidden button. Run the `maximize-button`, `theme-global` and `theme-empty` shell probes after changes to the Window controls.

Shell process-exit monitoring must survive a Project pipe failure. Only runtime teardown cancels that wait. A requested Close completes when the Project exits, even without exit intent.

Update retries resume unfinished Window Close requests without replacing the first saved Window layout. Run the `windows-close-update-disconnect` shell probe after changes to shutdown recovery.

## Readiness and Pane delivery

The Project Sidebar reports a Project ready after Lua startup and Workspace restore finish. Hosted processes report this separately from their first frame and repeat the report after adoption. Background Projects do not render.

Keep the shell's first-frame guards separate from this status. A Project's 30-second first-frame deadline starts again when the shell first shows it. Run the `restore-select-late` shell probe after changes.

The `restore-loaded` probe checks readiness without selecting the restored background Project.

A Sidebar Pane or Terminal Session selection keeps the previous Project's frame until the requested Pane has rendered. Keyboard focus waits until the requested Pane is applied, so Pane History records no visit to the Project's old Pane. Pane deliveries carry request IDs.

Lua completes each request, including a rejected request, before the next redraw. Both renderers report the completed ID. The shell rejects frames that precede the requested ID.

Pane reports also carry the completed ID. The shell's Sidebar model keeps the previous selection until that report arrives. The shell then publishes the destination Project and its requested Pane together, without highlighting its previous Pane.

Meanwhile the Sidebar View highlights the row that the user chose, so the highlight does not go back to the old Pane. A chosen Terminal Session keeps the highlight until the Tab that shows it is active. Runtime readiness permits delivery before the first frame, so selection cannot block a new Project's startup.

Terminal Session selections use the same Pane request, including when the Project starts or opens the session's View. Run `anvil:hosted-routing`, `ui/pane_requests.lua`, and the `select-hold`, `select-terminal-hold` and `terminal-focus` shell probes after changes.

## Presentation and GPU recovery

The shell waits for swapchain capacity without blocking its event loop. It collects input and new surfaces during that wait. Each Window has one pending presentation and one one-shot readiness wait.

Idle Windows have no readiness wait. The shell composes the latest surfaces when capacity becomes available. Vsync stays enabled outside live resize.

Window destruction cancels and joins its wait before releasing its renderer. Run the Sidebar-hover latency probe and focused shell rendering, resize, GPU-failure, and Window-close probes after changes.

A lost GPU device, for example during a driver update, does not fail a Project or the Sidebar. The shell rebuilds the Window's presentation after 1 second. Repeated failures double the delay, up to 60 seconds.

After the rebuild, the shell sends a new configuration epoch, so each visible surface draws a complete frame. A hosted process that loses its own device creates a new device and a new shared texture on its next frame. Run the `fault-present`, `fault-resize`, `fault-release`, `fault-device`, `sidebar-gpu` and `windows-close-gpu` shell probes after changes.
