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

**Excluded Project Path**:
A Project path that remains visible as part of the Project context but is intentionally left out of project-wide search and navigation.
_Avoid_: ignored folder, hidden folder

**Project Path Role**:
The user-facing classification assigned to a Project path, such as Root Project content, External Project Directory content, or Excluded Project Path content.
_Avoid_: path marker, folder marker, special folder

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

**Container-Owned Member Symbol**:
A named code symbol that belongs to a containing type or similar named container and is generally not valid as an unqualified completion outside that container, such as a field, method, or scoped enum member.
_Avoid_: self-scoped symbol

**Current Document Symbol Search**:
A search over named code symbols in the active Document only.
_Avoid_: local symbol search, file symbol search

**Recent File**:
A file in Anvil's navigation history, ordered by last visit for returning to previously viewed files.
_Avoid_: recent tab, file tab history

**Navigation Place**:
A focusable place the user can return to through the current Navigation Scope's Navigation History, including editor locations and tool views with their own cursor or selection.
_Avoid_: editor-only location, browser page

**Navigation Scope**:
A top-level pane that owns one independent Navigation History shared by all of its Pane Views.
_Avoid_: tool-specific history, global history, focus group

**Navigation History**:
A Navigation Scope's back/forward sequence of Navigation Places used to return through recent focus and location changes without crossing into another scope.
_Avoid_: file history, tab history

**Document / Doc**:
The in-memory editable text for a file or untitled document.
_Avoid_: Buffer

**Document View / DocView**:
A visual surface showing a Document. A Document View can be an Editor or a document-backed tool panel.
_Avoid_: Editor tab, buffer view

**Line Hint**:
Non-interactive text visually anchored to a Document View line that is not part of the Document.
_Avoid_: Buffer hint, phantom text, inlay hint

**Fold Region**:
A range of Document text that a Document View can visually hide while keeping the text part of the Document.
_Avoid_: collapsed block, hidden lines

**Fold Widget Row**:
The visible row in a Document View that represents a collapsed Fold Region and is not part of the Document text.
_Avoid_: fake line, synthetic line, placeholder line

**Fold Target**:
The Document range chosen when the user asks Anvil to fold at the caret or selection.
_Avoid_: block-info, fold candidate

**Diagnostic Underline**:
A non-interactive underline marking a diagnostic range in a Document View.
_Avoid_: Squiggle, lint underline

**Column Guide**:
A non-interactive vertical visual marker at a configured character column in a Document View.
_Avoid_: Line guide, ruler

**Editor**:
A Document View used to edit a file or untitled Document. Document-backed tool panels are not Editors, even when they use Document View mechanics.
_Avoid_: Buffer, editor tab

**Standard Editor**:
An Editor that presents ordinary Document source without a specialized presentation mode such as Markdown Live Preview.
_Avoid_: Standard Editor DocView, normal Editor, plain Editor

**Markdown Live Preview**:
An Editor mode that presents formatted Markdown inline while keeping the underlying Markdown source directly editable.
_Avoid_: Live Markdown Editor, Markdown Live Editor

**Blank Editor Placeholder**:
The tabless blank editing surface shown when the Left Pane has no Open Views. It keeps the Left Pane present without representing a real open tab.
_Avoid_: Empty tab, welcome tab

**Zoom**:
The user-facing way to make Anvil's interface and document text larger or smaller without changing Document contents.
_Avoid_: Scale in user-facing command names

**Editing Surface**:
A Pane View whose primary purpose is editing or navigating a Document.
_Avoid_: Code context, editor context

**Surface Focus Target**:
A focusable sub-area inside a Pane View, such as a Git list pane or Git diff text pane.
_Avoid_: listener, split

**Selection State**:
The caret and selection state owned by a Document View.
_Avoid_: Document selection, shared selection

**Selection Surrounding**:
An editing action that keeps selected text selected while placing matching delimiters around it. A multiline line-content selection may become an indented delimiter block.
_Avoid_: auto-pairing, wrapper conversion

**Current Line Highlight**:
A background highlight that marks the visual row containing the active caret in a Document View.
_Avoid_: Line highlighting, active line highlight

**Wrapped Visual Row**:
A visual row produced when one Document line wraps; it is not a separate Document line.
_Avoid_: Fake line, wrapped file line

**Selection Mirror**:
A compatibility copy of one Document View's Selection State exposed through the Document for older command and plugin code.
_Avoid_: Source selection, canonical selection

**Selection Owner**:
The Document View identity attached to selection undo/redo records and temporary selection bindings.
_Avoid_: Selection session

**Root Panel**:
The top-level UI container for the editor window.
_Avoid_: App shell, main panel

**Left Pane**:
The permanent left-side top-level view container. It cannot be hidden and shows the Blank Editor Placeholder when it has no Open Views.
_Avoid_: Main Panel, primary pane, left split

**Right Pane**:
The hideable right-side top-level view container. It owns right-side tools such as the File Tree as well as Editors opened on the right.
_Avoid_: Side Panel, Side Editor Slot, right split

**Pane View**:
A top-level work surface belonging to the Left Pane or Right Pane.
_Avoid_: Main Surface, pane content

**Open View**:
A Pane View retained by its pane and represented by a Pane Tab.
_Avoid_: Active View, loaded tab

**Selected View**:
The Open View selected for presentation in its pane. It is visible whenever its pane is shown.
_Avoid_: Active View, visible active view

**Focused View**:
The Selected View whose focus scope currently receives input, including input received by one of its Surface Focus Targets.
_Avoid_: Focused active view, globally active view

**Pane Tab**:
A Title Bar tab representing one Open View in either the Left Pane or Right Pane.
_Avoid_: Main Tab, file tab, buffer tab, Node tab

**Title Bar Safe Zone**:
A deliberately tab-free region between the Left Pane Tabs and Right Pane Tabs that remains available for moving and otherwise interacting with the application window.
_Avoid_: tab gap, unused tab space

**File Tree**:
A permanent, singleton Right Pane tool for viewing and editing Project files and directories.
_Avoid_: old file tree

**Project Paths View**:
A Project tool for reviewing and changing Project Path Roles, labels, locations, and storage scope.
_Avoid_: external folder manager, path rules dialog

**File Tree Sort Mode**:
The user-facing ordering applied to File Tree entries. Folder entries remain grouped before file entries.
_Avoid_: filetree sorting

**Global Prompt Bar**:
The bottom-anchored, full-width prompt used for app-wide actions such as opening files, opening projects, renaming, and command entry.
_Avoid_: Command prompt, command bar

**Fuzzy Searcher**:
The floating picker used for fuzzy navigation and search modes, such as files, projects, grep, symbols, and commands.
_Avoid_: fuzzy searcher popup

**Copy Feedback Highlight**:
A brief visual highlight marking the text most recently copied by the user.
_Avoid_: Copy flash, copy animation

**Command Slot**:
A project-scoped shortcut slot that stores one shell command for quick reruns.
_Avoid_: Command preset, command macro

**Command Output View**:
A read-only Document View showing the text output from a command run.
_Avoid_: Command buffer, terminal buffer, output buffer

**Command Output History**:
The per-Command Slot sequence of Command Output View contents from command runs, navigated within that slot.
_Avoid_: terminal scrollback, output buffer history

**DocView Prompt Bar**:
A bottom-anchored prompt scoped to a specific Document View.
_Avoid_: Document find bar, local prompt, find bar

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
The family of top-level Git-related Pane Views for a Project, including the Git Log, Commit Diff Views, File History Views, Directory History Views, and Combined Path History Views. It is not a visible container with nested tabs.
_Avoid_: Git popup, Git panel, Git tab container

**Git Log**:
The singleton Left Pane tab for browsing commits from one selected Git repository in a Project and opening commit-focused views. Closing its visible tab hides it so the same Git Log can be restored later.
_Avoid_: commit browser, main Git View

**Selected Git Repository**:
The repository whose commits the Project's singleton Git Log currently displays.
_Avoid_: active repository, current repo

**Commit Diff View**:
A closable Left Pane tab for browsing all files changed by a commit or working-tree state and comparing them against another Git state.
_Avoid_: commit diff tab

**File History View**:
A closable Left Pane tab showing revisions affecting one project file or a selection within that file.
_Avoid_: file log, selection log

**Directory History View**:
A closable Left Pane tab showing revisions that affected paths beneath one project directory.
_Avoid_: folder log, directory log

**Combined Path History View**:
A closable Left Pane tab showing revisions that affected any path in a selected set of project files or directories.
_Avoid_: multi-file log, combined log

**Local Changes Revision**:
The newest revision in a File History View, representing the current Document including unsaved and uncommitted changes.
_Avoid_: dirty revision, working copy snapshot

**Historical Document**:
A read-only Document containing file text from a past Git revision.
_Avoid_: historical buffer, snapshot buffer

**Diff View**:
A visual comparison of two text sources, presented through two Diff Sides.
_Avoid_: diffviewer

**Diff Side**:
One document surface in a Diff View, representing one of the compared text sources. A file-backed Diff Side presents the same Document as that file's Editors so edits remain synchronized.
_Avoid_: diff pane, side view

**Text Diff View**:
A Left Pane tab comparing arbitrary text selections or generated text, independent of whether the text came from Git.
_Avoid_: string comparison

**Blank Diff View**:
A Text Diff View with two initially blank, editable untitled Documents for live arbitrary comparison.
_Avoid_: empty diff popup

**Clipboard Comparison**:
A Text Diff View with editable clipboard text on the left and the current file or selected file fragment on the right. A project-file side remains connected to that file's Document.
_Avoid_: clipboard snapshot diff
