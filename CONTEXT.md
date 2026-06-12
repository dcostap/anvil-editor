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

**Workspace**:
The per-project editor state that restores open views, tabs, splits, scroll positions, selection state, extra project directories, and recently visited files.
_Avoid_: Session, app state

**Document / Doc**:
The in-memory editable text for a file or untitled document in the existing Anvil editor model.
_Avoid_: Buffer when discussing the existing editor model

**Buffer**:
The shared editable text state in the new Fred-style editor core.
_Avoid_: Document, Doc when discussing the new Fred-style editor core

**Buffer Manager**:
The coordinator for shared Buffer state in the new Fred-style editor core.
_Avoid_: Document manager, Doc manager

**Document View / DocView**:
A visual surface showing a Document. A Document View can be an Editor or a document-backed tool panel.
_Avoid_: Editor tab, buffer view

**Line Hint**:
Non-interactive text visually anchored to a Document View line that is not part of the Document.
_Avoid_: Buffer hint, phantom text, inlay hint

**Column Guide**:
A non-interactive vertical visual marker at a configured character column in a Document View.
_Avoid_: Line guide, ruler

**Editor**:
A Document View used to edit a file or untitled Document in the existing Anvil editor model; in the new Fred-style editor core, the per-view editing state over a Buffer.
_Avoid_: editor tab

**Main Editor**:
An Editor hosted in the Main Panel.
_Avoid_: Main DocView, primary editor

**Side Editor**:
An Editor hosted in the Side Panel for the split-editor experience.
_Avoid_: Side DocView, Side Panel DocView, Split DocView, side buffer

**Selection State**:
The caret and selection state owned by a Document View.
_Avoid_: Document selection, shared selection

**Current Line Highlight**:
A background highlight that marks the visual row containing the active caret in a Document View.
_Avoid_: Line highlighting, active line highlight

**Decoration**:
A non-text visual annotation anchored to editor content or editor view space, such as a search result highlight, diff marker, diagnostic marker, or line hint.
_Avoid_: DocView monkey patch, overlay hack

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

**Main Panel**:
The main document-editing area where ordinary Document Views open by default.
_Avoid_: Primary node, primary panel, main view

**Side Panel**:
The right-side UI panel that appears when needed, takes a substantial portion of the window width, and hosts auxiliary views such as the file tree.
_Avoid_: Side node, secondary panel

**File Tree**:
A Side Panel tool for viewing and editing Project files and directories.
_Avoid_: old file tree

**File Tree Sort Mode**:
The user-facing ordering applied to File Tree entries. Folder entries remain grouped before file entries.
_Avoid_: filetree sorting

**Global Prompt Bar**:
The bottom-anchored, full-width prompt used for app-wide actions such as opening files, opening projects, renaming, and command entry.
_Avoid_: Command prompt, command bar

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
