# Search and autocomplete

## Project rows

Path Search lists Projects from the Project Sidebar model: Scratch, loaded Projects, then Dormant Projects by age. `core.project_look` draws a Project's name, badge and note for both, so a Project looks the same in each. Run `ui/fuzzy_searcher_path_search.lua` and `ui/sidebar_view.lua` after changes.

The Fuzzy Searcher shows this Project's badge and name at the left of the query, with the same `core.project_look`. Path Search searches beyond this Project, so it does not show it. Pickers with their own list, such as the file picker, do not show it either.

Confirming one file in Path Search or Project File Search opens it in the deepest known local Project folder that contains it. This includes Dormant Projects. The shell selects the Project in its own Window if loaded. If no Project matches, the file opens where the search started. Previews and opens with a specific destination do not switch Projects.

Run `ui/fuzzy_searcher_project_chip.lua` and the `launch-path-search` shell probe after changes.

## Other Projects and language providers

Project File Search and Text Search also show Other Project Results. Each query goes to the other ready Projects as a `project_search` Pane request. Its `mode` is `files` or `text`.

A path or line number in a Text Search query keeps the search in this Project. Each Project searches itself and answers with up to 20 rows in a `project_results` request. `more = true` tells that more rows match.

A Project that cannot search, or has no match, does not answer. This Project's rows come first and are never cut. Each other group shows all its rows.

It ends with a More row when its Project has more rows. A More row sends `search` with the same query through the select route. Without other rows, this Project's list is not cut.

File Search uses the Project's file index. Text Search runs ripgrep in the Project's roots and searches its Terminal Sessions. A Terminal row carries the lines near its match for the preview, at most 4 KB.

The picker ignores answers to an earlier query. Opening a file row sends `open_file` to its Project through the select route. A Terminal row sends `terminal_find`.

Open in File Tree on a file row sends `open_file` with `filetree = true`. That Project shows the file in its own File Tree. Show in Explorer refuses a file on a Machine, because Explorer shows only this PC's folders.

This Project's "No matches" status is hidden while other Projects show rows. Run `ui/fuzzy_searcher_other_projects.lua`, `ui/fuzzy_searcher_terminals.lua` and the `launch-file-search` shell probe after changes. The probe reports the answer times of both modes.

Each group has a divider and a small, dim header. Check the `fuzzy-picker-other-projects` and `fuzzy-picker-other-text` render scenarios after visual changes.

Language providers add groups to File Search with `project_file_groups` and to Project Symbol Search with `project_symbol_groups`. `plugins.fuzzy_searcher.item_rows` draws File Search item rows and shows the `preview()` of any row that has one. The SQL Server plugin lists database objects in File Search and columns in Symbol Search.

These groups go after this Project's rows and before Other Project Results. Run `ui/sql_server.lua` after changes. Check the `sql-files` and `sql-symbols` render scenarios after visual changes.

## Saved Screens and path creation

File Search shows all its rows at once. Paged lists load the next page one screen before their end. Until the user moves the selection, the first row stays selected while rows arrive or a refresh reorders them. After a move, a refresh keeps the selected row, wherever it moves.

Each non-empty query keeps a Saved Screen: its rows down to the bottom of the screen and its selected row. The picker saves it at close and when the prompt history moves away from the query, but not while a search runs, because its rows can belong to the previous query. It keeps the newest 50 in memory.

An empty File Search starts at its first row. A picker that opens a query with a Saved Screen, or that the prompt history moves to, shows that screen in its first frame. It does not wait for the search.

While the Saved Screen shows, searches keep their rows back (`holds_saved_screen`). Their last rows replace it, and `restore_position` selects the saved row at its place on the screen. Text Search keeps the found rows of the Saved Screen first, in their order, as rows that the user saw.

A move during the Saved Screen changes the row that the restore selects. Pages do not load until the search ends. A typed path that does not exist gets a Create Path Result at the top.

It is not the default selection: the next row is, if one exists (`skip_create_path_row`). The user selects it with a move, and a refresh keeps that choice. Each typed character makes a new path, which a worker reads.

While the top row is a Create Path Result, the new path's Create Path Result takes its place during the read, so the rows do not move. The read's result then replaces it. Enter during the read reads the path first, so it never creates an existing path.

Run `ui/fuzzy_searcher_path_search.lua` after changes. Each query makes new rows. A row's size and edited time come from a worker, which remembers the last answer for each path (`fuzzy_searcher.file_infos`).

A new row of the same file shows that answer at once, and the worker reads the file again. Run `ui/fuzzy_searcher_scrolling.lua` after changes.

## File drag

A Fuzzy Searcher row or a File Tree row with a file or folder drags out to other programs, as from Windows Explorer. The drag starts when the pointer moves 6 px from the press. It takes the selected rows when it starts on one of them, or else only its row.

A click on a row of a multi-row selection selects only that row at the release. The picker stays open. Files on another Machine stay out. File Tree rows that are not on disk yet stay out, and a drop back on the same File Tree does nothing.

`system.drag_files` starts it. In the shell, the Project sends `ANVIL_SURFACE_MSG_FILE_DRAG`. The shell checks that the left button is still down on the Selected Project, sends the Project its release, and runs the Windows drag loop from its service window (`src/file_drag.c`).

A timer runs the shell's events and steps during that loop, so all Windows stay live. Direct mode runs the drag loop in the editor and then sends itself the release. A test cannot press the real mouse, so check a real drop by hand after native changes.

Run `ui/fuzzy_searcher_multi_selection.lua`, `ui/filetree_entries.lua` and `anvil:file-drag` after changes.

## Terminal results

Text Search also searches the Terminal Sessions of this Project. Other Projects search their own Terminals. A Terminal that this Project shows gives its live text.

Other Terminals give the screen that their host saved last. That screen can be up to about 20 seconds old. A worker reads it (`terminal_snapshot_text`).

Terminal lines rank with file lines. On equal scores, the file line goes first. A path or line number in the query skips Terminals.

Confirm shows the Terminal and opens its find card at the line. Another Project gets a `terminal_find` Pane request. Run `ui/fuzzy_searcher_terminals.lua` after changes.

## Symbol index limits

The native Project symbol index accepts a bounded explicit path list. A very large Project can exceed that bound. The editor reports the submission error and stays open, but it does not index that complete Project.

## Autocomplete searches

Autocomplete runs Project symbol searches through `workspace_symbols_async`. It submits only the last input context in each frame. A new Buffer edit, caret position, View, Project Paths generation, or close cancels the old requests.

Parse refresh reuses the current requests. Results request a redraw even when normal frame pacing leaves the UI idle. Local symbols and matching visible suggestions remain available while Project searches run.

Native Project queries prepare their fuzzy query once and check path and language rules once per file. Keep their matching, ranking, scope filters, and cancellation behavior unchanged. `autocomplete.is_pending()` reports unfinished completion work, including an empty-result search.

Run `ui/autocomplete_batch.lua`, `ui/autocomplete_parse_refresh.lua`, `ui/autocomplete_matching.lua`, `ui/autocomplete_layout.lua`, `runtime/worker_pool_native.lua`, `runtime/fuzzy.lua`, `runtime/symbol_search_case.lua`, and `runtime/treesitter_global_symbols.lua` after changes. Run the `autocomplete` scenario suite for timing checks. Its no-match actions must wait for search completion, not only an empty popup.

## Panes behind the Fuzzy Searcher

While the Fuzzy Searcher is open, each Pane View draws a Draw Capture of its last draw. A Draw Capture is a copy of the View's renderer commands (`renderer.begin_capture`, `renderer.end_capture`). The View draws again when its rectangle, scroll, text, Color Theme or scale changes.

Other changes, such as new Git colors in the File Tree, show when the picker closes. Terminal Views set `draws_while_covered`, because programs write to them while they are covered. A replay stops after any Font or canvas is freed, or after a captured Font changes size.

Run `ui/draw_capture.lua`, `ui/covered_panes.lua` and the `fuzzy-picker-*` render scenarios after changes.
