# Text editing and Markdown

## Heading Outline

Markdown Live Preview lists the headings left of the reading lane when the free space can hold the list. It reads the tree-sitter outline, the same list as Current Buffer Symbol Search. The top heading level and two levels below it show.

The current section is the last heading above the top quarter of the view. After the caret moves, the current section is the caret's section instead, until the user scrolls with the wheel or the scrollbar. Each Pane's outline follows its own caret.

The Buffer's selection belongs to the focused Pane, so the outline uses a selection listener on its Text View. A click moves the caret to the heading and scrolls it near the top with `scroll_to_line`'s `top_margin`. That heading is then the caret's section.

The selection marker stays in the visible column while a long heading list scrolls. Sections in the middle share one marker position. Run `ui/markdown_heading_outline.lua` after changes.

Check the `markdown-heading-outline` render scenario after visual changes.

## Binary files

`core.open_file` asks how to open a binary file: with the default app, as text, or not at all. It returns `false` while the dialog asks. `common.is_binary` uses Git's rule: a NUL byte in the first 8000 bytes.

Text with a UTF-16 or UTF-32 BOM is not binary. The File Search preview uses the same rule. `opts.as_text` skips the dialog.

A binary Buffer does not keep its bytes exactly, so Autosave does not save it. Only an explicit save writes it. `core.open_file` refuses a missing image path.

A new image cannot start as text. Run `ui/binary_file_open.lua` after changes.

## Link activation

Markdown and Terminal links share the URI scheme rule in `core.system_link`: only `http`, `https`, `mailto` and `file` are allowed. Markdown attachments and absolute file links use the same system-opening check, inside or outside the vault. File URIs are decoded before the check.

System opening asks before known program, script, installer and shortcut file types. Cancel is the default, and approval applies only to that activation. This check is not a sandbox for external apps or custom file associations. Terminal file links still open through the editor, including its binary-file dialog.

Live Preview resolves the destination file again on activation. Heading and block positions come from the loaded Buffer, not the disk index. Activation waits for loading to finish and retains the Buffer during resolution. It reuses complete current Buffer facts or parses that note on a native worker. Vault indexing size limits do not limit explicit navigation.

The wait stops if the user edits the source, changes its selection, scrolls, leaves the View, or activates another link. Live Preview keeps the source open until it finds the target. A missing heading or block does not open the destination View. Terminal links and Terminal Text Captures use the same Buffer resolver after opening their destination View. A later caret move, scroll, or focus change cancels that jump.

The existing Text View line anchor keeps the destination visible through layout changes. User scrolling, selection changes, and edits end that anchor.

Run `ui/markdown_open_at_line.lua`, `ui/markdown_live_editor.lua`, `ui/terminal.lua` and `ui/binary_file_open.lua` after changes.

## Recycle Bin

Windows Recycle Bin operations run through the `file_trash` worker. `src/file_trash.c` owns the blocking shell call. The File Tree keeps its edit guard until the worker finishes. Machine requests use the same worker without blocking other requests.

`file_ops.delete(paths, true)` yields on Windows. Use a coroutine, or `file_ops.run(path, fn, true)`, when calling it. Other local operations keep their synchronous behavior. A failed Recycle Bin operation reports an error; it does not retry through another shell command. Once the shell call starts, it can finish even if its caller disconnects.

Run `runtime/system.lua`, `runtime/machine_guard.lua`, `runtime/machine_serve.lua` and `ui/filetree_context_menu.lua` after changes.

## Markdown images

In Live Preview, an image starts at the text indent of its link's line, after any list marker. If the image does not fit at that indent, it starts at the left margin without changing size. Run `ui/markdown_image_resize.lua` after changes.

## Table images

A table cell that holds only an image link shows the attachment link above the image, scaled to its column. A cell with text and an image keeps the link label. Table images use the same Image Controls as prose: hover buttons, Image Overlay, link editing, corner resize and Context Menu.

Editing reveals the source above the image. Resizing escapes the size separator so it cannot split the table cell. A Wikilink reads `\|` as its alias separator, because a table needs it: `![[image.png\|200]]`.

Run `ui/markdown_interactive_tables.lua` and `ui/markdown_image_resize.lua` after changes. Check the `markdown-table-images` render scenario after visual changes.

## Selection backgrounds

A selection over several lines covers the screen in reading order. Its start row fills from the start to the right edge. Each row after it fills the full width, and its end row fills from the left edge to the end.

So block spacing, wrap indentation and tables between the two ends show no gaps. A selection in one line fills only its text. An end in a Live Preview table row keeps the cell rule.

Run `ui/selection_background.lua` and `ui/markdown_selection_background.lua` after changes. Check the `markdown-selection` render scenario after visual changes.

## Shared storage

`core.storage` reads generated Lua data through `system.load_file`. Windows readers share deletion, so a replacement can leave them reading the old file. `system.replace_file` uses Windows POSIX rename semantics to publish the new file while those readers stay open.

Do not replace this with `MoveFileExW` alone: it refuses an open target, even when the reader shares deletion. Windows can briefly hide the target name during that rename. `src/shared_file.c` gives each canonical path a named mutex.

Writers hold it through publication. A reader that gets not found takes the same mutex and opens again. Existing files stay lock-free; missing keys have no fixed delay.

A lock timeout is a read failure, not a missing key. Filesystems without POSIX rename support keep the previous, bounded-retry rename behavior. The native log reports that fallback once.

They do not have the same concurrent-reader guarantee. Run `anvil:shared-file` and `runtime/storage.lua` after changes. They check a missing-name interval, concurrent reads and saves, and replacement while a reader keeps the old data.

## Reload from disk

`Buffer:reload()` applies the file's text as edits through `Buffer:apply_lines`. It does not replace the Buffer. Selections, the visible text, bookmarks and other text positions move with the text.

One undo reverts the reload. `Buffer:undo()` and `Buffer:redo()` return the type of the step they applied. A reload step does not merge with other steps.

Autoreload flashes the lines and shows a status message when an undo or redo applies a reload, because Autosave then writes it to disk. A reload does not call `Buffer:load`. Plugins that track the disk state hook `Buffer.reload` as well.

A Text View without row measurements keeps its top line when lines change above it, like a measured view. See [shared editing](../shared-editing.md) for the plan: dirty-Buffer merges and Disk Conflicts. Run `ui/buffer_reload.lua` and `runtime/buffer_apply_lines.lua` after changes.

## Shown Indentation

An empty line holds no whitespace. Its caret initially shows at the indentation that Enter at the end of the line above writes (`core.empty_line_indent`). The Buffer keeps the caret at column 1.

Each Text View keeps its own chosen position within the Shown Indentation. Left and Right move through its spaces and tabs without editing. At either edge, they continue onto the adjacent line.

A click chooses the nearest position within the indentation; a click farther right stops at its end. The drawn caret, the Up/Down goal column and the next edit use that chosen position. Markdown Live Preview uses the same indentation width for drawing and pointer placement.

Tab, Shift+Tab, Backspace and typed whitespace change the Shown Indentation's extent. The level stays until the caret leaves the line or the text changes. Enter carries it to the new line.

Move to Start of Line and Move to Start of Indentation move to the margin without changing that extent. End moves to its end. Home followed by End restores the same indentation, including a level the user chose.

These moves edit no text. Typing and paste first write only the indentation up to the chosen position. One undo reverts it with the edit (`Buffer:join_undo_since`).

Text selections cover actual text, not the unwritten indentation. Collapsing a selection onto an empty line keeps its endpoint at column 1. The module tracks the lines that user edits leave holding only whitespace.

It moves them through later edits with `changed_ranges`. A tracked line becomes empty when no selection touches it. With the caret at its end, it becomes empty at once, and its whitespace becomes the caret's level, so the caret does not move.

The cleanup undoes with the edit before it. It waits while redo is available. Undo, redo, load and reload add no tracked lines.

Whitespace-only lines that no edit touches stay. `config.keep_newline_whitespace` turns the cleanup off. Caches use `buffer.text_revision`.

`get_change_id()` is the undo position, which repeats after an undo and a new edit. In Markdown, a blank line after a list item or a quote shows at the margin. Keep `newline_indent` in step with `core:newline`.

Run `ui/empty_line_indent.lua` and `ui/smart_indent.lua` after changes.

## Paste and move indentation

The lines after the first line of a multi-line paste start at the caret's indentation. They keep their shape relative to the first line. Parts copied from several carets and pasted at one caret go on separate lines.

Each part starts at the caret's indentation. Whole lines, and complete lines pasted at column 1, go where a new line belongs there: the brace block's indentation (`block_indent`), or else the Shown Indentation of a new empty line. Lines copied together keep their shape.

After pasted complete lines, the rest of the caret's line keeps its indentation. Markdown keeps the indentation of pasted whole lines, because lists and quotes own it. Text from outside this process with one line for each caret pastes one line at each caret, in document order.

A last newline does not count as a line. In a switch block, `block_indent` puts a case label at the previous label's indentation, and other lines one level inside the label above them. In Go and Odin, the first label goes at the switch's indentation.

Smart Backspace, paste and Move Lines use this rule. Move Lines shifts the moved lines, and the line that they pass, by the change of their brace block indentation (`block_indent`). A move inside one block changes no indentation, so hanging indentation keeps its offset.

Languages without brace blocks keep their indentation. One undo reverts the move and the shift. Auto-Indent Lines (`editor:auto_indent_lines`) moves the lines of each selection as a paste of them would go: the first line with text takes the indentation of its place, and the other lines keep their shape.

Markdown keeps its indentation. Paste as Plain Text (`core:paste_as_plain_text`) pastes like Paste, but changes no indentation and escapes nothing in a string. Run `ui/smart_indent.lua` after changes.

## Changes Baseline

Changes Baseline checks file identity once before a pending diff, not on each key. Patch export and Revert also check any pending identity before using the baseline. Run `ui/file_changes_baseline.lua` after changes.

## Machine file changes

Selecting an open Machine file or returning to the Window checks the active Buffer against its saved version. The host omits unchanged bytes from the reply. A clean Buffer takes the host's changes. A dirty Buffer keeps its edits, including text typed while the check was pending. Compare Changes shows the two versions without saving either. Return to the file and choose Save to resolve the conflict. Saving still checks the version on the Machine.
