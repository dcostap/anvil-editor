# Anvil Editor

Shared domain language for the Anvil editor fork. This glossary records user-facing concepts and preferred names, not implementation details.

## Language

**Anvil**:
The editor application developed in this repository.
_Avoid_: Pragtical, Lite XL

**App State**:
Global editor state that persists across launches, such as recent projects, window placement, and previous find/replace text.
_Avoid_: Session

**Project**:
A loaded directory root in Anvil. A project is not the whole visible editor state.
_Avoid_: Workspace, session, folder

**Root Project**:
The first project loaded into Anvil, used as the default base for relative paths and project-level behavior.
_Avoid_: Primary project, main project

**External Project Directory**:
An additional directory made available to a Project for browsing and project-wide navigation while remaining distinct from the Root Project.
_Avoid_: external folder, linked folder, library folder

**Vendored Project Directory**:
A directory in or attached to a Project that contains third-party or dependency source code and is presented as a distinct named source area.
_Avoid_: vendor marker, special folder, library folder

**Project Path Role**:
The user-facing classification assigned to Root Project content, an External Project Directory, or a Vendored Project Directory.
_Avoid_: path marker, folder marker, special folder

**Project Search Scope**:
The files available to Project-wide search and indexing. Project ignore rules and hidden-path rules define the default scope.
_Avoid_: file catalog, search database

**Include Ignored Files**:
A temporary File Search or Text Search option that adds ignored files to that search. Hidden paths stay excluded.
_Avoid_: disable ignores, index ignored files

**Search Modifier**:
A temporary option that changes the current search without changing its query text.
_Avoid_: search modification, search mode

**Workspace**:
The per-project editor state that restores open views, tabs, splits, scroll positions, selection state, extra project directories, and recently visited files.
_Avoid_: Session, app state

**Project Symbol Search**:
A search over named code symbols across a loaded Project.
_Avoid_: global symbol search

**Project Usage Search**:
A search for syntactic usages of a named code symbol across a loaded Project.
_Avoid_: semantic references, global references

**Contextual Member Completion**:
Autocomplete suggestions prioritized for the named container immediately before a member-access separator, such as enum members after `Color.` or class members after `Widget.`. It does not imply resolving the runtime type of an instance expression.
_Avoid_: semantic instance completion, dot autocomplete

**Buffer Word Completion**:
Autocomplete suggestions learned from ordinary word-like text in Buffers rather than from language-aware code sources.
_Avoid_: dictionary autocomplete, normal-word autocomplete

**Container-Owned Member Symbol**:
A named code symbol that belongs to a containing type or similar named container and is generally not valid as an unqualified completion outside that container, such as a field, method, or scoped enum member.
_Avoid_: self-scoped symbol

**Current Buffer Symbol Search**:
A search over named code symbols in the active Buffer only.
_Avoid_: local symbol search, file symbol search

**Recent File**:
A file in Anvil's navigation history, ordered by last view for returning to previously viewed files. It retains when it was last viewed and last edited.
_Avoid_: recent tab, file tab history

**Navigation Place**:
A place in a Pane that the user can return to through Navigation History, including Buffer locations and stateful Views.
_Avoid_: editor-only location, browser page

**Navigation History**:
A Pane's back/forward sequence of Navigation Places. Navigation History never crosses into another Pane.
_Avoid_: file history, tab history, global history

**Buffer**:
In-memory text that can be untitled, file-backed, editable, or read-only.
_Avoid_: Document, Doc

**Autosave**:
The default behavior that saves edits to file-backed Buffers without a manual save action. Save failures and disk conflicts remain visible.
_Avoid_: background save, auto-save

**Untitled Buffer**:
An editable Buffer that is not linked to a filesystem file.
_Avoid_: scratch buffer, unnamed file

**Language Mode**:
The language Anvil uses to interpret a Buffer for syntax highlighting and other language-aware behavior. It is normally detected from the file name or content, but a Buffer may have an explicit Language Mode override.
_Avoid_: File type, syntax mode

**Text View**:
A View that presents a Buffer through text navigation and selection behavior. It can allow edits with specialized effects.
_Avoid_: Document View, DocView, buffer view

**Line Hint**:
Non-interactive text visually anchored to a Text View line that is not part of the Buffer.
_Avoid_: Buffer hint, phantom text, inlay hint

**Fold Region**:
A range of Buffer text that a Text View can visually hide while keeping the text part of the Buffer.
_Avoid_: collapsed block, hidden lines

**Fold Widget Row**:
The visible row in a Text View that represents a collapsed Fold Region and is not part of the Buffer text.
_Avoid_: fake line, synthetic line, placeholder line

**Fold Target**:
The Buffer range chosen when the user asks Anvil to fold at the caret or selection.
_Avoid_: block-info, fold candidate

**Diagnostic Underline**:
A non-interactive underline marking a diagnostic range in a Text View.
_Avoid_: Squiggle, lint underline

**Column Guide**:
A non-interactive vertical visual marker at a configured character column in a Text View.
_Avoid_: Line guide, ruler

**Editor**:
A Text View used to edit a file-backed or untitled Buffer. Text-backed tools are not Editors, even when they use text editing behavior.
_Avoid_: Buffer, editor tab, Text View

**Standard Editor**:
An Editor that presents ordinary Buffer source without a specialized presentation mode such as Markdown Live Preview.
_Avoid_: Standard Editor Text View, normal Editor, plain Editor

**Markdown Live Preview**:
An Editor mode that presents formatted Markdown inline while keeping the underlying Markdown source directly editable.
_Avoid_: Live Markdown Editor, Markdown Live Editor

**Markdown Callout**:
A blockquote whose first line contains a case-insensitive `[!type]` marker, with an optional custom title and Markdown-formatted body.
_Avoid_: admonition, alert block

**Foldable Callout**:
A Markdown Callout whose type marker is followed by `+` or `-`, declaring whether its body starts expanded or collapsed while its header remains visible.
_Avoid_: collapsible callout, folded blockquote

**Markdown Source Mode**:
An Editor mode that shows all Markdown source syntax normally instead of presenting formatted Markdown inline.
_Avoid_: Raw rendering mode

**Interactive Table Editing**:
A Markdown Live Preview behavior that keeps a Markdown table presented as an editable grid while its cells are navigated, selected, structurally changed, and edited. Hover Insertion Controls provide direct row and column insertion at table boundaries.
_Avoid_: Table Source Mode, raw table editing

**Table Cell Selection**:
A selection of one table cell's complete editable contents in Interactive Table Editing. Dragging within one cell creates an ordinary text selection; dragging across cell boundaries creates a rectangular group represented as multiple Table Cell Selections. A selected cell, including an empty selected cell, is visually distinguished from a partial text selection.
_Avoid_: Grid cursor, table highlight

**Hover Insertion Control**:
A temporary table-edge control that appears on hover and inserts a row or column at the indicated boundary.
_Avoid_: permanent table toolbar, table context menu

**Markdown Reveal Unit**:
The smallest formatted Markdown construct whose source syntax becomes visible while it is being edited in Markdown Live Preview.
_Avoid_: Raw rendering mode

**Zoom**:
The user-facing way to make Anvil's interface and Buffer text larger or smaller without changing Buffer contents.
_Avoid_: Scale in user-facing command names

**Typography Role**:
A globally configurable text style for a semantic use such as interface text, source code, prose, emphasis, or headings.
_Avoid_: Global font, Markdown font

**Editing Surface**:
A View whose primary purpose is editing or navigating a Buffer.
_Avoid_: Code context, editor context

**Surface Focus Target**:
A focusable sub-area inside a View, such as a Git list or Git diff text area.
_Avoid_: listener, split

**Selection State**:
The caret and selection state owned by a Text View.
_Avoid_: Buffer selection, shared selection

**Selection Surrounding**:
An editing action that keeps selected text selected while placing matching delimiters around it. A multiline line-content selection may become an indented delimiter block.
_Avoid_: auto-pairing, wrapper conversion

**Current Line Highlight**:
A background highlight that marks the visual row containing the active caret in a Text View.
_Avoid_: Line highlighting, active line highlight

**Wrapped Visual Row**:
A visual row produced when one Buffer line wraps; it is not a separate Buffer line.
_Avoid_: Fake line, wrapped file line

**Soft-Wrap Indicator**:
A visual prefix marking a Wrapped Visual Row that continues the same Buffer line.
_Avoid_: Continuation arrow, wrapped-line marker

**Selection Mirror**:
A compatibility copy of one Text View's Selection State exposed through the Buffer for older command and plugin code.
_Avoid_: Source selection, canonical selection

**Selection Owner**:
The Text View identity attached to selection undo/redo records and temporary selection bindings.
_Avoid_: Selection session

**Root Panel**:
The top-level UI container for the editor window.
_Avoid_: App shell, main panel

**Modal Input Owner**:
The top interaction that receives all user input until it closes. Owners form a stack when one interaction covers another.
_Avoid_: priority interaction, modal popup, input-stealing View

**Pane**:
A numbered work area that shows one Current View and owns one Navigation History. Each Pane belongs to one Pane Group.
_Avoid_: Left Pane, Right Pane, panel, split

**Pane Number Marker**:
A Fuzzy Searcher result marker that identifies each Pane whose Current View shows the file.
_Avoid_: open file badge, tab number

**Pane Group**:
A contiguous sequence of one or more Panes shown together. A one-Pane group fills the available work area.
_Avoid_: tab group, split group, workspace

**View**:
The content that a Pane can show, such as an Editor, File Tree, Terminal View, or Command Output View.
_Avoid_: Pane View, app, pane content

**Current View**:
The View that a Pane currently shows.
_Avoid_: Selected View, Active View, Open View

**View Suspension**:
The retention of a non-current View through Pane Navigation History without closing it. An Untitled Editor cannot be suspended.
_Avoid_: hidden tab, background tab

**Untitled Editor**:
An Editor showing an Untitled Buffer. It must close instead of entering View Suspension when another View replaces it.
_Avoid_: scratch Editor, unnamed Editor

**Focused View**:
The Current View whose focus scope receives input, including input received by one of its Surface Focus Targets.
_Avoid_: Focused active view, globally active view

**Tab**:
A Title Bar item representing one Pane. Tab order gives each Pane its one-based number, including Panes shown in a Pane Group.
_Avoid_: Pane Tab, file tab, buffer tab, View tab, Node tab

**File Tree**:
A Text View for viewing and editing files and directories beneath one selected root. Several File Trees can exist at the same time.
_Avoid_: file panel, singleton file tree

**Path Tree**:
A hierarchical presentation of a scoped set of file and directory paths, such as files changed by a Git revision.
_Avoid_: file list, mini File Tree

**Compacted Directory Chain**:
A Path Tree row that presents consecutive single-child directories as one slash-separated directory path. Its visible children are one hierarchy level below the compacted row regardless of how many directory names it contains.
_Avoid_: merged folder

**Project Paths View**:
A Project tool for reviewing and changing Project Path Roles, labels, locations, and storage scope.
_Avoid_: external folder manager, path rules dialog

**File Tree Sort Mode**:
The user-facing ordering applied to File Tree entries. Folder entries remain grouped before file entries.
_Avoid_: filetree sorting

**Global Prompt Bar**:
The bottom-anchored, full-width prompt used for app-wide actions such as opening files, opening projects, renaming, and command entry.
_Avoid_: Command prompt, command bar

**Command Palette**:
The Fuzzy Searcher mode used to find and run curated Anvil commands available to its source View. A command can continue into another input mode when it needs an argument.
_Avoid_: Pane Command Bar, command prompt

**Command Identifier**:
The raw Command Palette name of a command, written as `prefix:snake_case_action`. A View owns its prefix. Commands not owned by one View use `core`.
_Avoid_: command title, display name

**Command Keyword**:
An additional hidden search term that helps a Command Palette query match a Command Identifier.
_Avoid_: command alias, command title

**View Icon**:
The icon shared by a View, its Tab, and Command Palette commands that use the View's prefix. Standard Editors omit the icon from their Tabs. Markdown Live Preview shows the Markdown View Icon only in Live Preview mode.
_Avoid_: command icon, tab icon

**View Opener**:
A command that creates a View. Its Command Palette result adds a green plus badge to the View Icon.
_Avoid_: constructor command, open badge

**Shell Command Mode**:
The explicit Fuzzy Searcher mode that runs entered shell text and opens its output in a Command Output View.
_Avoid_: Pane Command Bar, Terminal View input

**Fuzzy Searcher**:
The floating picker used for fuzzy navigation and search modes, such as files, projects, grep, symbols, and commands.
_Avoid_: fuzzy searcher popup

**Project File Search**:
A Fuzzy Searcher search for files and folders under loaded Project Paths. Files follow Project Search Scope. Empty folders appear. Ignored folder roots appear, but Project File Search does not enter them.
_Avoid_: fuzzy file searcher, file picker

**Project Folder Result**:
A Project File Search result for a folder. Activating it opens a File Tree rooted at that folder.
_Avoid_: directory action, Project result

**Path Search**:
A Fuzzy Searcher search for recent Projects, folders, and files outside the current Project Search Scope.
_Avoid_: external mode, system search

**Exact Path Result**:
The first Fuzzy Searcher result when the entered path identifies an existing file or folder.
_Avoid_: direct path match, forced result

**Create Path Result**:
A first-position Fuzzy Searcher action that creates a missing explicit file or folder path.
_Avoid_: new path suggestion, create match

**Copy Feedback Highlight**:
A brief visual highlight marking the text most recently copied by the user.
_Avoid_: Copy flash, copy animation

**Command Slot**:
A project-scoped shortcut slot that stores one shell command for quick reruns.
_Avoid_: Command preset, command macro

**Command Output View**:
A read-only Text View showing the text output from a command run.
_Avoid_: Command buffer, terminal buffer, output buffer

**Terminal View**:
An interactive View connected to a running shell or terminal application.
_Avoid_: Terminal panel, terminal buffer, console

**Command Output History**:
The per-Command Slot sequence of Command Output View contents from command runs, navigated within that slot.
_Avoid_: terminal scrollback, output buffer history

**Text View Prompt Bar**:
A bottom-anchored prompt scoped to a specific Text View.
_Avoid_: DocView Prompt Bar, Buffer find bar, local prompt, find bar

**Title Bar**:
The top application bar containing native-looking window controls and application-level chrome.
_Avoid_: TitleView

**Status Bar**:
The bottom information bar that shows state, messages, tooltips, and context for the currently focused view.
_Avoid_: StatusView, bottom bar

**Navigation Boundary Feedback**:
A brief user-facing message shown when directional navigation reaches the boundary of its current scope. In a multi-file Diff View, it can announce that repeating the command will continue into the adjacent file.
_Avoid_: wraparound feedback, no-op warning

**Point of Interest / POI**:
A navigable target within a view, such as a Git change in an Editor or a file/line reference in a Command Output View. A Point of Interest may also be activatable.
_Avoid_: diff region, link, target

**Text Point of Interest / Text POI**:
A Point of Interest tied to a concrete text range that can be presented as link-like text, such as an underlined file-location reference in a Command Output View.
_Avoid_: link, text link

**Point of Interest Activation**:
The action taken for an activatable Point of Interest, such as opening the referenced file location.
_Avoid_: trigger, click action

**Project Tool Window**:
A separate project-owned window for a large singleton tool that should stay available without taking over the main editing layout.
_Avoid_: popup, modal, detached panel

**Runtime Theme Editor**:
A floating in-window tool for inspecting and temporarily changing the current theme's colors during a running Anvil session.
_Avoid_: Theme popup, color config

**Git View**:
The family of top-level Git-related Views for a Project, including the Git Log, Commit Diff Views, File History Views, Directory History Views, and Combined Path History Views. It is not a visible container with nested tabs.
_Avoid_: Git popup, Git panel, Git tab container

**Git Log**:
The singleton View for browsing commits from one selected Git repository in a Project and opening commit-focused Views.
_Avoid_: commit browser, main Git View

**Selected Git Repository**:
The repository whose commits the Project's singleton Git Log currently displays.
_Avoid_: active repository, current repo

**Commit Diff View**:
A closable View for browsing all files changed by a commit or working-tree state and comparing them against another Git state.
_Avoid_: commit diff tab

**File History View**:
A closable View showing revisions affecting one Project file or a selection within that file.
_Avoid_: file log, selection log

**Directory History View**:
A closable View showing revisions that affected paths beneath one Project directory.
_Avoid_: folder log, directory log

**Combined Path History View**:
A closable View showing revisions that affected any path in a selected set of Project files or directories.
_Avoid_: multi-file log, combined log

**Local Changes Revision**:
The newest revision in a File History View, representing the current Buffer including unsaved and uncommitted changes.
_Avoid_: dirty revision, working copy snapshot

**Historical Buffer**:
A read-only Buffer containing file text from a past Git revision.
_Avoid_: Historical Document, snapshot buffer

**Diff View**:
A visual comparison of two text sources, presented through two Diff Sides.
_Avoid_: diffviewer

**Diff Side**:
One text surface in a Diff View, representing one of the compared sources. A file-backed Diff Side presents the same Buffer as that file's Editors.
_Avoid_: diff pane, side view

**Text Diff View**:
A View comparing arbitrary text selections or generated text, independent of whether the text came from Git.
_Avoid_: string comparison

**Blank Diff View**:
A Text Diff View with two initially blank, editable untitled Buffers for live arbitrary comparison.
_Avoid_: empty diff popup

**Clipboard Comparison**:
A Text Diff View with editable clipboard text on the left and the current file or selected file fragment on the right. A Project-file side remains connected to that file's Buffer.
_Avoid_: clipboard snapshot diff
