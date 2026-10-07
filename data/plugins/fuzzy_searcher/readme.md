# Bookmark Search

Use `º` or run `fuzzy:open_bookmarks` from the Command Palette.
This mode shows Bookmarks from the Selected Project, across all Panes.

```text
ºparser
ºreturn value
```

Search matches Bookmark names, file paths, and line text.
Search Modifiers and other mode markers remain literal text after `º`.
Enter opens the selected location in the source Pane.

Use Ctrl+B in an Editor to add a Bookmark at the caret line.
The Global Prompt Bar accepts an optional name. Blank Enter creates an unnamed Bookmark. Escape cancels.
Ctrl+B on a bookmarked line asks for removal confirmation.
Use `bookmark:rename` to change or clear its name.
A gutter icon marks the line beside its number.

Missing files and locations remain visible and searchable.
Enter does not create a missing file or choose an uncertain location.
Right-click a result to rename, remove, or attach it to the source Editor's caret.
Open Bookmark Search from the desired Editor before using that attachment action.

Bookmarks follow ordinary edits, Move Lines, undo, and redo.
Anvil updates paths after its own file and directory moves.
Reload recovery uses saved line text and nearby context. It does not choose between equally plausible matches.
Closed-file recovery reads files up to 8 MiB. Larger files retain their Bookmark records without automatic disk recovery.
External renames can appear as missing files. Use the attachment action to repair their Bookmarks.

# Navigation History Search

Use `^` or run `fuzzy:open_navigation_history` from the Command Palette.
The default shortcut is Ctrl+H.

```text
^parser
^return value
```

This mode searches Navigation Places in the source Pane only.
With no query, it shows reverse history order, including forward entries.
It selects the current entry and brings that row into view.
Repeated visits remain separate results.

Editor rows show the file location, enclosing Tree-sitter symbol, and code line.
Text comes from the current Buffer, including unsaved edits.
Symbol labels appear when the Tree-sitter index is ready.
Other Views show their names and icons. File Trees also show their saved directories.

Search matches file paths, code text, symbol names, and View labels.
Search Modifiers and other mode markers remain literal query text after `^`.

Preview does not change the source Pane or its history.
Activation restores the exact entry, including its selection and scroll position.
It does not open another file or create another Pane.
Large or binary Buffers can remain selectable without a text preview.

# Search Modifiers

Add `modifier:value` tokens to File Search or Text Search.
Tokens can appear before or after the search text.
Valid tokens use a different text color.

```text
size:>=10k size:<20k config
src/ #error size:<1m sort:name
commit:abcdef12 #error sort:name
@report size:>=20mb sort:size
```

## File size

Size means the file's byte count, not its allocated disk space.
Text Search uses the size of the containing file.

Units use powers of 1024. Names are case-insensitive.
Use `b`, `k`/`kb`, `m`/`mb`, `g`/`gb`, or `t`/`tb`.
Without a unit, the number means bytes. Use whole numbers.

| Modifier | Files included |
| --- | --- |
| `size:20m` or `size:20mb` | At least 20 MB, but less than 21 MB |
| `size:>=20mb` | At least 20 MB |
| `size:<10k` | Less than 10 KB |
| `size:>10k` | More than 10 KB |
| `size:<=10k` | At most 10 KB |
| `size:=10k` | Exactly 10240 bytes |

Repeated size filters all apply. Size filters exclude folders.

## Result order

- `sort:date`: most recently modified first.
- `sort:size`: largest first. This order excludes folders.
- `sort:name`: filename order, A–Z. Paths break ties.

An explicit order replaces fuzzy ranking and the Recent File section.
Text Search orders file groups first, then their matching lines.
Search considers all matching Project files before applying the result limit.
Results can move while the search runs.

Metadata searches read file information when needed and reuse it between query edits.
The first search can take longer than an ordinary name search.
Everything-backed Path Search applies filters and ordering before it returns a result page.
Without Everything, Path Search can filter and order a folder's direct contents.

## Commit Search

Use `commit:` with a complete or abbreviated hexadecimal commit ID.
The commit must exist in the repository containing the Selected Project.
Branch names are not commit IDs.

Commit Search includes all files recorded in that commit, including tracked hidden and ignored files.
It does not restrict results to files changed by that commit.
It excludes files added later and ignores local edits.
It does not search unrelated External Project Directories.

File size comes from the committed blob.
Preview and activation use historical content. Opened Historical Buffers are read-only.
Commit Search does not change your checkout or working files.

Git does not store per-file modification dates. `commit:` cannot combine with `sort:date`.
Commit Search does not support Path Search, historical folder activation, or binary previews.
It does not fetch missing commits, submodule contents, or Git LFS objects.

## Literal text and errors

Quote text that looks like a modifier to search for it literally:

```text
#"size:20m" sort:name
```

Unknown modifier names remain ordinary search text.
Incomplete or invalid values show a message instead of running a different search.
Conflicting `sort:` or `commit:` values also show a message.

Shell Command Mode and the Command Palette keep their text literal.
Symbol searches do not support Search Modifiers.
File Pickers keep their fixed path input rules.
