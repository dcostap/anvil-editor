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
The in-memory editable text for a file or untitled document.
_Avoid_: Buffer

**Document View / DocView**:
A visual editor instance showing a Document. Multiple Document Views can show the same Document while keeping separate view state such as scroll and selection.
_Avoid_: Editor tab, buffer view

**Side DocView**:
A Document View hosted in the Side Panel for the split-editor experience. Also valid: DocView in Side Panel, Side Panel DocView, Split DocView.
_Avoid_: Side editor, secondary editor

**Selection State**:
The caret and selection state owned by a Document View.
_Avoid_: Document selection, shared selection

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

**Global Prompt Bar**:
The bottom-anchored, full-width prompt used for app-wide actions such as opening files, opening projects, renaming, and command entry.
_Avoid_: Command prompt, command bar

**DocView Prompt Bar**:
A bottom-anchored prompt scoped to a specific Document View.
_Avoid_: Document find bar, local prompt, find bar

**Title Bar**:
The top application bar containing native-looking window controls and application-level chrome.
_Avoid_: TitleView

**Status Bar**:
The bottom information bar that shows state, messages, tooltips, and context for the currently focused view.
_Avoid_: StatusView, bottom bar
