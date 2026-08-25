# Pane, View, and Buffer Redesign Plan

## Status and authority

This is the authoritative product and implementation plan for Anvil's main work-area redesign.

It records the accepted design from the voice-design discussion. `CONTEXT.md` contains the canonical user-facing language.

When this plan conflicts with the current implementation, this plan defines the intended behavior.

The current Command Palette design supersedes every Pane Command Bar section in this plan. Registered commands open Views and collect arguments through dedicated Fuzzy Searcher modes. Shell execution requires explicit Shell Command Mode. External Anvil clients use structured actions instead of this removed internal command syntax.

When this plan conflicts with an older plan, this plan controls these subjects:

- Buffer and Text View terminology;
- Pane and Tab identity;
- Pane Groups and split presentation;
- View replacement and suspension;
- removal of Left Pane and Right Pane behavior;
- File Tree placement and identity;
- Terminal placement and lifetime;
- Command Output placement;
- Command Slot placement and shell execution;
- Workspace persistence for the new Pane model.

The following older plans remain authoritative for their feature-specific behavior. Interpret their old layout language through this plan:

- `GIT_DIFF_WORKFLOW_PLAN.md`;
- `POINT_OF_INTEREST_PLAN.md`;
- `UNTITLED_RECOVERY_AUTOSAVE_PLAN.md`;
- `MARKDOWN_LIVE_EDITOR_PLAN.md`;
- `SOFT_WRAP_CORE_PLAN.md`;
- `TEXT_FOLDING_PLAN.md`.

For example, an older reference to a “Left Pane tab” now means a View opened through the target Pane API. It does not preserve a Left Pane.

This plan has no open product questions. Small implementation choices must follow the invariants below.

## Product goal

Replace the special two-pane editor shell with a small set of general primitives.

The final model must feel direct:

- every Tab represents one Pane;
- every Pane has one Current View;
- every Pane owns independent Navigation History;
- contiguous Panes can appear together in one Pane Group;
- every open Pane remains visible in the Title Bar;
- Views can replace one another in a Pane;
- replaced Views can suspend without closing;
- Untitled Editors never suspend;
- File Trees, Terminals, Editors, and Command Output Views use the same placement rules;
- Overlays remain independent from the Pane layout;
- no feature depends on a Left Pane or Right Pane.

The redesign must remove old concepts instead of wrapping them in compatibility code.

## Design principles

### Keep the domain model small

The main work area uses these concepts:

1. Buffer
2. View
3. Text View
4. Editor
5. Pane
6. Pane Group
7. Tab
8. Navigation Place
9. Navigation History
10. Overlay

Do not introduce a second tab system inside a Pane.

Do not call a View an application or app. Anvil is the application.

Do not use “panel” as a synonym for Pane or View.

### Separate models from presentations

A Buffer is text. It is not a rectangle and it is not a tab.

A View presents behavior and state. It can use a Buffer, a terminal grid, an image, or a compound model.

A Pane presents one Current View. A Pane remains identifiable when its Pane Group is hidden.

A Tab presents one Pane in the Title Bar. A Tab is not a View identity.

### Preserve live resources intentionally

Switching away from a Terminal must not kill its shell.

Switching away from a file-backed Editor must not lose its Buffer or location.

Switching away from a File Tree must preserve its root and selection.

Untitled Editors are the exception. They must close instead of suspending when replaced.

### Prefer one general placement API

Every feature must open through one Pane service.

Do not add feature-specific placement fields such as:

- `pane = "left"`;
- `pane = "right"`;
- `open_right`;
- `show_side_panel`;
- `hide_right_pane`;
- `opposite_pane`.

Use a Pane object, Pane identifier, or explicit placement request.

### Make invalid states difficult to represent

A Pane belongs to exactly one Pane Group.

A Pane appears exactly once in the global Tab order.

A Pane Group contains a contiguous range of Tabs.

A Pane has exactly one Current View.

A Pane Group has at least one Pane.

A split layout leaf references exactly one Pane.

A split layout never contains a Pane from another Pane Group.

## Explicit non-goals

These items are not required for the first complete redesign:

- arbitrary non-contiguous Pane Groups;
- a tmux Window abstraction above Pane Groups;
- nested View tabs inside a Pane;
- persistence of live terminal processes across Anvil restarts;
- persistence of complete Pane Navigation History across restarts;
- terminal command interception through `!`;
- an editor IPC client such as `anvil edit file.lua`;
- remote-shell integration;
- arbitrary shell graph or task orchestration;
- a settings page for every Pane constant;
- pixel-exact tests for group decoration;
- compatibility aliases for old Left Pane or Right Pane APIs;
- compatibility aliases for `Doc`, `DocView`, or `doc:*` first-party names.

The future `anvil edit` and `anvil tree` client remains deferred. The Pane Command Bar provides the initial internal launcher.

## Accepted product decisions

### Tab and Pane identity

Each Tab represents one Pane.

Tab order gives every Pane a one-based number.

The first Pane is Pane 1. There is no Pane 0.

Pane numbers are positional. Closing or moving a Pane can change later numbers.

Internal Pane identifiers are stable and opaque. They are not user-facing numbers.

### Pane Groups

A Pane Group contains one or more contiguous Panes.

Only one Pane Group is presented in the main work area at a time.

A one-Pane group fills the available work area.

A multi-Pane group presents every member through a split layout.

Selecting any Tab presents its complete Pane Group and focuses that Pane.

Example:

```text
Tabs:        1  2  3  4  5
Pane Groups: [1 2] [3] [4 5]
```

Selecting Tab 1 presents Panes 1 and 2. Pane 1 receives focus.

Selecting Tab 2 presents the same group. Pane 2 receives focus.

Selecting Tab 3 presents Pane 3 alone.

Selecting Tab 5 presents Panes 4 and 5. Pane 5 receives focus.

### New Pane behavior

`Ctrl+T` invokes the new-Pane command.

The command appends a Pane after every existing Pane.

The new Pane receives number `N + 1`.

The new Pane starts as a one-Pane group.

Its Current View is an Editor with a new Untitled Buffer.

If no Panes exist, the command creates Pane 1.

### Split behavior

A split command creates a Pane in the active Pane Group.

The new Pane is inserted next to the active Pane in layout order.

The global Tab order is rebuilt from Pane Group order and split-leaf order.

A split never creates a non-contiguous group.

The first implementation supports left, right, up, and down splits.

A split starts at an equal ratio unless an existing durable layout rule requires another ratio.

### Current View

Each Pane presents exactly one Current View.

A Pane can retain prior Views through Navigation History.

Retained Views are not Pane tabs. They do not appear as separate Title Bar items.

### View Suspension

Replacing a suspendable Current View records its Navigation Place and suspends it.

Suspension does not call `try_close`.

Suspension does not release owned features.

Suspension does not kill a running Terminal.

Suspension removes the View from drawing and direct event routing.

A suspended View can keep background resources alive through an explicit lifecycle hook.

Restoring a suspended View returns the same live instance when it remains retained.

### Untitled Editor exception

An Untitled Editor cannot suspend.

Before another View replaces it, Anvil runs its normal close flow.

A blank Untitled Editor closes without a prompt.

A content-bearing Untitled Editor shows the normal discard confirmation when closing its last reference.

Canceling the close cancels the requested View change.

Confirming discard closes the Editor and removes its recovery state.

The discarded Untitled Editor does not enter Navigation History.

Saving the Untitled Buffer makes its Editor file-backed and suspendable.

Switching to another Pane Group does not replace a Pane's Current View. Therefore, a current Untitled Editor can remain in a hidden Pane Group. Its Tab remains visible.

### Startup behavior

A new Project with no saved Pane state opens with zero Panes and zero Tabs.

The work area draws an intentional blank background.

Anvil does not create a placeholder Editor.

Anvil does not automatically open the File Tree.

If valid Workspace Pane state exists, Anvil restores it.

Untitled Recovery remains independent and can restore lost Untitled Buffers when Workspace state is unavailable.

### File Tree behavior

A File Tree is an ordinary Text View.

A File Tree is not an Editor.

Several File Tree instances can exist.

A File Tree has its own root, current directory, expansion state, selection, and filesystem watches.

No File Tree is permanent or globally privileged.

### Terminal behavior

A Terminal is an ordinary View.

Opening a Terminal in the current Pane replaces or suspends the Current View through the common placement flow.

A suspended or hidden Terminal keeps its shell alive.

`Ctrl+Alt+T` opens Anvil's internal Terminal View.

The existing external OS-terminal action remains available through an explicit command. It loses the `Ctrl+Alt+T` binding.

### Command output behavior

A one-time shell command creates a new Pane at the end.

That Pane starts as a one-Pane group.

Its Current View is a Command Output View.

A Command Output View uses a read-only Buffer.

The first lines show the command and working directory.

The final lines show exit state and elapsed time.

The output remains selectable and copyable.

File locations remain navigable Points of Interest.

### Command Slot behavior

The existing A, S, D, and F slots remain.

Each Command Slot reuses one Command Output View and one output Pane.

Running a slot creates its Pane only when required.

Later runs reuse the same Pane and View.

Each run adds one Command Output History entry.

The old singleton Right Pane Command Output Panel is removed.

### Internal command syntax

The Pane Command Bar accepts internal commands with a `:` prefix.

Initial commands are:

```text
:edit [path]
:tree [path]
:terminal
```

Input without `:` runs as a shell command.

The Terminal View does not intercept `!` commands.

## Canonical domain model

### Buffer

A Buffer owns in-memory text and text mutation state.

A Buffer can be:

- untitled;
- file-backed;
- editable;
- read-only;
- private to a Text View;
- shared by several Text Views.

File-backed Editors use canonical shared Buffers.

File Trees use private Buffers as their textual projection.

Command Output Views use private read-only Buffers.

Prompt inputs use private short-lived Buffers.

A Terminal does not use a Buffer for its terminal grid.

### Text View

A Text View presents a Buffer through common text behavior.

It owns presentation state such as:

- Selection State;
- scroll position;
- wrapping state;
- folding state;
- line decorations;
- owned presentation features.

A Text View can restrict or reinterpret mutation commands.

An Editor is a Text View.

A File Tree is a Text View with filesystem mutation semantics.

A Command Output View is a read-only Text View.

A Diff Side can use Text View mechanics without becoming an Editor.

### Editor

Create an explicit `Editor` class.

Do not continue to identify Editors through ad hoc marker fields.

An Editor presents a file-backed or Untitled Buffer for ordinary editing.

The class provides the stable seam for:

- Untitled Editor detection;
- Workspace state;
- file context;
- language behavior;
- editor-only commands;
- Markdown Live Preview ownership;
- suspendability rules.

### View

A View is the base presentation object.

Add a small lifecycle protocol:

```lua
function View:can_suspend(reason)
  return true
end

function View:on_suspend(reason)
end

function View:on_resume(reason)
end

function View:update_suspended()
end

function View:capture_navigation_state()
  return nil
end

function View:restore_navigation_state(state)
  return true
end

function View:get_navigation_identity()
  return self
end
```

The exact method names can change during implementation. The responsibilities must remain.

Do not add methods that duplicate `try_close`, `get_state`, or `from_state`.

`try_close` handles permanent removal.

Suspension handles temporary replacement.

Workspace state handles process restart.

Navigation state handles back and forward movement.

### Pane

Suggested structure:

```lua
{
  id = "opaque-pane-id",
  group = pane_group,
  current_view = view,
  position = { x = 0, y = 0 },
  size = { x = 0, y = 0 },
}
```

A Pane must not own an array of tabbed Views.

A Pane can own or reference its Navigation History service state.

A Pane exposes computed properties:

- one-based number;
- visible state;
- focused state;
- Tab title;
- dirty or attention state from its Current View.

### Pane layout node

Replace the current mixed `Node` class with a layout-only tree.

Suggested shape:

```lua
-- Leaf
{
  kind = "pane",
  pane = pane,
}

-- Split
{
  kind = "split",
  axis = "x" or "y",
  ratio = 0.5,
  a = child,
  b = child,
}
```

The layout tree must not own:

- View arrays;
- active Views;
- local tab bars;
- Empty Views;
- locked chrome Views;
- Title Bar state;
- Right Pane width rules.

Required operations:

```lua
layout.leaves(root)
layout.find(root, pane)
layout.pane_at(root, x, y)
layout.divider_at(root, x, y)
layout.split(root, pane, direction, new_pane)
layout.remove(root, pane)
layout.resize(node, pointer_position)
layout.update_rects(root, rect)
layout.serialize(root)
layout.deserialize(state, panes_by_id)
layout.validate(root)
```

Every traversal uses deterministic visual order.

For a horizontal split, `a` precedes `b` in Tab order.

For a vertical split, `a` also precedes `b` in Tab order.

This rule keeps numbering independent from screen coordinates.

### Pane Group

Suggested structure:

```lua
{
  id = "opaque-group-id",
  root = pane_layout_node,
}
```

The manager computes group members from `layout.leaves(group.root)`.

Do not store a second mutable member array.

Required behavior:

- a new group starts with one Pane leaf;
- splitting replaces one leaf with one split node;
- removing a leaf collapses its parent;
- removing the last Pane removes the group;
- group order remains stable until explicit movement;
- group membership remains contiguous in global Tab order.

### Pane manager

Rewrite `data/core/panes.lua` as the authoritative manager.

Suggested state:

```lua
{
  groups = {},
  active_pane = nil,
  visible_group = nil,
  panes_by_id = {},
  groups_by_id = {},
}
```

The global Pane sequence is derived by flattening `groups` in order.

Do not maintain a separate mutable `panes` array unless profiling proves it necessary.

If cached, rebuild and validate it after every structural mutation.

Required manager operations:

```lua
panes.count()
panes.ordered()
panes.number(pane)
panes.find(id)
panes.active()
panes.visible_group()
panes.contains(pane)
panes.is_visible(pane)
panes.pane_for_view(view)
panes.create(opts)
panes.split(pane, direction, opts)
panes.focus(pane)
panes.focus_index(index)
panes.focus_direction(direction)
panes.replace_view(pane, factory, opts)
panes.restore_place(pane, place, opts)
panes.close_view(pane, opts)
panes.close(pane, opts)
panes.close_all(opts)
panes.move(pane, target, opts)
panes.save_workspace_state(save_view)
panes.restore_workspace_state(state, load_view)
panes.reset_for_tests()
```

Every public mutation must finish with invariant validation in debug and test builds.

## Pane ordering and structural operations

### Creating a Pane

`panes.create()` performs these steps:

1. Allocate a stable Pane identifier.
2. Build the initial Current View through a factory.
3. Create a one-leaf Pane Group.
4. Append the group after existing groups.
5. Set the new Pane as active.
6. Set its group as visible.
7. update Title Bar geometry.
8. focus the View's preferred focus target.
9. request layout and redraw.
10. emit a quiet diagnostic.

If View construction fails, no Pane or group remains.

### Splitting a Pane

`panes.split()` performs these steps:

1. Resolve the target Pane.
2. Build the new Current View.
3. Create a new Pane identity.
4. replace the target leaf with a split node.
5. place the new leaf according to direction.
6. preserve the target Pane's Current View and history.
7. focus the new Pane unless the caller disables focus.
8. rebuild the global order.
9. validate contiguity and uniqueness.
10. update layout and Title Bar state.

A split command does not replace the source View. Therefore, it does not trigger the Untitled Editor close rule.

### Closing a Pane

Closing a Pane permanently closes all resources owned only by that Pane.

The close is transactional.

1. Collect the Current View and retained live Views.
2. collect Buffers that would lose their final View.
3. run dirty-close confirmation before releasing anything.
4. cancel the whole operation if confirmation is canceled.
5. close live terminals and other resources.
6. release View-owned features exactly once.
7. remove Navigation History for the Pane.
8. remove the Pane leaf and collapse its layout.
9. remove an empty Pane Group.
10. select the nearest surviving Pane.
11. permit zero Panes.

Do not partially close a Pane before a later View cancels.

### Closing the Current View

Provide a separate `view:close` command.

If Navigation History can restore a previous View, close the Current View and restore the nearest valid place.

If no place remains, close the Pane.

The Title Bar close action closes the Pane because the Tab represents the Pane.

The default tab-close shortcut also closes the Pane.

Tests must invoke commands and must not assert shortcuts.

### Moving and dragging Panes

The first complete version supports these rules:

- moving a Pane within its group changes leaf order;
- moving a Pane out of a multi-Pane group collapses the source layout;
- a Title Bar drop between Pane Groups creates a one-Pane group at that boundary;
- a work-area edge drop joins the visible target group through a split;
- a work-area center drop focuses the target Pane and does not create hidden View tabs;
- a drop cannot create a non-contiguous group;
- dragging a Pane cannot duplicate or lose it.

When reordering inside one group, swap Pane references between ordered leaves. Keep split ratios attached to geometry.

When a Title Bar drop occurs inside another group's tab range, show only valid drop targets:

- before the group;
- after the group;
- or an explicit join-group target.

Do not silently split a target group into two groups.

Implement mouse drag after command-driven movement and splitting are stable.

## View replacement transaction

### Why replacement needs a transaction

Opening a Terminal can fail.

Opening a file can fail.

An Untitled Editor close can be canceled.

A target View can allocate processes or filesystem watches.

The old Current View must remain valid until replacement can commit.

### Required flow

Use a lazy target factory rather than requiring a preconstructed View.

Suggested API:

```lua
panes.replace_view(pane, function()
  return TerminalView(options)
end, {
  reason = "terminal-open",
  focus = true,
})
```

Replacement performs these steps:

1. Resolve the Pane and old Current View.
2. reject another pending replacement for the same Pane.
3. determine whether the old View can suspend.
4. if it cannot suspend, start its normal close flow.
5. stop when the close is canceled.
6. construct the target View after close approval.
7. if construction fails, keep or restore the old View when possible.
8. capture the old Navigation Place only for suspension.
9. record the place without crossing Pane boundaries.
10. call `old:on_suspend(reason)`.
11. assign the new Current View.
12. call `new:on_resume(reason)`.
13. update focus ownership and visible state.
14. clear invalid forward history according to protected-resource rules.
15. request layout and redraw.

For an Untitled Editor, do not record a place before confirmation.

If the last Untitled Buffer is discarded, its recovery cleanup completes before the target becomes current.

### Opening the same View again

If the requested View instance is already current, update its requested state and focus it.

If it exists in the same Pane's retained history, reactivate the same instance.

If it is current in another Pane, do not steal it. Create or focus according to feature identity rules.

A View object must not be Current in two Panes.

A shared Buffer can have several Text Views.

## Navigation History redesign

### Scope

Each Pane owns one independent Navigation History.

Replace the current `"left"` and `"right"` history keys with stable Pane identifiers.

Navigation never crosses into another Pane.

### Place model

A Navigation Place records:

```lua
{
  pane_id = "opaque-pane-id",
  view = view_or_nil,
  identity = stable_identity,
  state = view_navigation_state,
  timestamp = number,
}
```

Editor state includes:

- Buffer identity;
- file path when available;
- Selection State;
- scroll position;
- mode-owned state needed for exact return.

File Tree state includes:

- root path;
- current directory;
- selected path ranges;
- expansion state or a stable expansion checkpoint;
- scroll position.

Command Output state includes:

- slot identity when applicable;
- output entry identity;
- selection and scroll.

Terminal state uses the live Terminal View identity. Do not pretend that a running terminal can be reconstructed from text.

Git and Diff Views expose state through a general View navigation protocol. Remove hardcoded owner-field tests where a public seam can replace them.

### Composite View focus

Replace fields such as these where practical:

- `__pane_focus_owner`;
- `git_owner_view`;
- `diff_view_parent`;
- special Left Pane fallback logic.

Use one focus-owner registration seam:

```lua
panes.register_focus_target(owner_view, child_view)
panes.unregister_focus_target(child_view)
panes.owner_for_view(child_view)
```

A composite View can expose:

```lua
function View:get_focus_view()
  return self
end
```

The Pane manager always maps a focus target back to one owner View and one Pane.

### Back and forward behavior

`navigation:back` captures the departing place, restores the prior place, and keeps all movement inside the active Pane.

`navigation:forward` behaves symmetrically.

Movement inside one Editor can add locations without creating duplicate Editor instances.

Opening another View adds a place for the suspended View.

Restoring a retained View calls `on_resume` and suspends the departing suspendable View.

An Untitled Editor cannot be restored from suspended history because it never enters history.

### History limits and protected resources

The current maximum entry setting remains a soft limit for recreatable places.

Automatic trimming must never silently destroy:

- a running Terminal;
- a dirty file-backed Buffer with no other View;
- another View that reports non-discardable live state.

Add a public discard check:

```lua
function View:can_discard_suspended()
  return true
end
```

A running Terminal returns false.

A View owning the last dirty Buffer reference returns false.

Protected places can make history temporarily exceed its soft limit.

When a new navigation branch clears forward history, retain protected places in reachable order. One acceptable rule is:

1. clear recreatable forward places;
2. keep protected forward places after the new current place;
3. preserve their relative order;
4. quiet-log the retention decision.

Do not move protected resources into an unreachable hidden registry.

When a Terminal exits, it becomes discardable after its normal output and state remain captured.

### Workspace boundary

Do not persist full Navigation History in Workspace state during this redesign.

Persist each Pane's Current View only.

A restored Terminal starts a new shell from saved launch options. It is not the old process.

Suspended Views are process-lifetime state.

## Buffer and Text View source rename

### Rename scope

The accepted glossary rename must reach first-party source code.

Use clean names in modules, classes, fields, commands, tests, diagnostics, and comments.

Canonical rename table:

| Old | New |
|---|---|
| Document | Buffer |
| Doc | Buffer |
| `doc` field | `buffer` field |
| `core.doc` | `core.buffer` |
| `data/core/doc/` | `data/core/buffer/` |
| DocView | TextView |
| `core.docview` | `core.textview` |
| `data/core/docview.lua` | `data/core/textview.lua` |
| `docview_*` helper files | `textview_*` helper files |
| `core.docs` | `core.buffers` |
| `core.open_doc` | `core.open_buffer` |
| `core.get_views_referencing_doc` | `core.get_views_referencing_buffer` |
| `doc:*` command namespace | `text:*` |
| `data/core/commands/doc.lua` | `data/core/commands/text.lua` |
| Historical Document | Historical Buffer |
| `historical_document.lua` | `historical_buffer.lua` |

Use `Editor` for ordinary file-backed and Untitled editing Views.

Do not rename external protocol fields.

These names must remain exact:

- LSP method names such as `textDocument/didOpen`;
- LSP JSON fields named `textDocument`;
- external API structures whose names come from a standard;
- ordinary English words such as documentation;
- third-party subproject identifiers.

Review Anvil-owned native names separately. Rename Anvil-owned “Document” types when they represent the renamed Buffer model. Keep protocol-standard names.

### Command namespace

Text editing commands move from `doc:*` to `text:*`.

Examples:

```text
doc:go-to-line       -> text:go-to-line
doc:copy             -> text:copy
doc:move-to-next-char -> text:move-to-next-char
```

Update all in-repo callers, keymaps, command predicates, plugin wrappers, tests, and documentation in the same change.

Do not keep command aliases.

Commands that are truly Editor-only can use `editor:*`.

Commands that mutate a Buffer without a Text View can use `buffer:*`.

Do not rename every command to `editor:*`. File Trees and Command Output Views rely on common Text View behavior.

### File and test names

Rename first-party test files when the old name describes the replaced concept.

Examples:

```text
tests/lua/runtime/doc_save.lua
  -> tests/lua/runtime/buffer_save.lua

tests/lua/ui/docview_scroll.lua
  -> tests/lua/ui/textview_scroll.lua

tests/lua/ui/doc_selection_state_characterization.lua
  -> tests/lua/ui/textview_selection_state_characterization.lua
```

Do not rename a file merely because it contains one protocol-standard `document` token.

### Mechanical rename validation

After the rename, use focused searches for obsolete first-party language:

```sh
rg -n --glob '*.lua' '\bDoc\b|\bDocView\b|core\.doc\b|core\.docs\b|open_doc\b|\.doc\b|"doc:' data tests
rg -n 'Document View|Left Pane|Right Pane|Pane Tab' --glob '*.md' --glob '!subprojects/**'
```

Every remaining match must have a documented reason.

## Root Panel and rendering architecture

### Remove chrome from the split tree

The current root `Node` tree also contains locked Title Bar, Nag View, Global Prompt Bar, and Status Bar leaves.

Remove this coupling.

The Root Panel lays out application chrome directly:

```text
+---------------------------------------------------+
| Title Bar                                         |
+---------------------------------------------------+
| Nag View, when visible                            |
+---------------------------------------------------+
| visible Pane Group work area                      |
+---------------------------------------------------+
| Prompt Bar, when window-scoped and visible        |
+---------------------------------------------------+
| Status Bar                                        |
+---------------------------------------------------+
```

A Pane Group layout receives only the computed work-area rectangle.

Do not represent chrome as locked Panes.

Do not use placeholder Views to keep a split tree valid.

### Zero-Pane draw

When there are zero Panes:

- draw the normal work-area background;
- draw no Editor placeholder;
- draw no Tab;
- keep overlays, prompts, Status Bar, and Title Bar functional;
- allow `Ctrl+T`, command search, project changes, and dropped files.

A dropped file with zero Panes creates Pane 1 with an Editor for that file.

### Update order

Suggested frame order:

1. update application overlays;
2. calculate chrome rectangles;
3. calculate visible Pane Group layout;
4. synchronize Current View geometry;
5. update visible Current Views;
6. update required background resources for hidden or suspended Views;
7. recalculate layout if a View changed a durable requested size;
8. synchronize scrollbars once with final geometry;
9. update Title Bar tab geometry;
10. request the correct cursor.

Do not update every suspended Text View each frame.

Use `update_suspended` only for resources that require servicing.

### Draw order

Suggested draw order:

1. work-area background;
2. visible Pane Group Current Views;
3. split dividers;
4. application attention overlay;
5. floating Overlays;
6. deferred draws and tooltips;
7. application chrome where its current layering requires it;
8. drag feedback.

Keep the existing app-overlay ownership and fade behavior unless the new host requires a small adaptation.

### Event routing

Route events through this order:

1. modal Nag View;
2. active Overlay;
3. active Prompt Bar;
4. Title Bar Tab interaction;
5. split divider drag;
6. visible Pane under the pointer;
7. focused Current View for keyboard and text input;
8. Status Bar where applicable.

Hidden Pane Groups never receive pointer events.

Suspended Views never receive direct input.

The active Pane's preferred focus target receives keyboard input.

Maintain mouse grab behavior for selection and scrollbars.

## Title Bar redesign

### One global Tab sequence

The Title Bar reads the Pane manager's complete ordered Pane sequence.

Remove separate left and right Tab collections.

Each Tab label starts with the one-based Pane number.

Recommended form:

```text
1: main.c
2: Terminal
3: File Tree: src
```

The Current View supplies the title after the number.

### Tab visual states

The Title Bar distinguishes:

- focused Pane;
- visible sibling Pane in the same Pane Group;
- Pane in a hidden group;
- hovered Pane;
- attention or dirty state supplied by the Current View.

The first version can use existing colors and a small group boundary treatment.

Do not add theme keys unless existing colors cannot express the states clearly.

If new style keys are necessary, define them in `data/colors/default.lua` before use.

### Group rendering

Tabs in one Pane Group remain adjacent.

Render a visible boundary between groups.

A future richer connected shape can replace the first treatment.

The durable rule is grouping visibility, not exact pixels.

Do not write automated tests for exact border widths or colors.

### Tab interaction

Clicking a Tab:

1. sets its Pane Group as visible;
2. sets its Pane active;
3. focuses the Current View's preferred focus target;
4. scrolls the Tab into view;
5. does not replace or suspend any Current View.

Middle-click and the close affordance close the Pane.

Mouse wheel over the Tab lane pages the global Tab sequence.

Number-based commands focus the Pane at that current position.

### Native hit testing

Update borderless-window hit testing for one interactive Tab region.

Keep a usable window-drag region after or around the Tab lane.

The old two-region native call can receive one real region and one empty region if its API remains adequate.

Change native code only when the current API cannot represent the required region safely.

### Title Bar drag

A dragged Tab carries a Pane, not a View.

The drag preview uses the Pane's current title.

A short pointer movement remains a click. The click focuses the Pane on release.

After the drag threshold, use a hand pointer and keep a floating Tab preview under the pointer.

Show the exact work-area split region or Title Bar insertion boundary before the user drops.

When hidden Tabs exist, dragging near either end of the Tab lane pages the lane.

Releasing outside a valid target cancels the drag without changing Pane order or focus.

Drop feedback must distinguish:

- reorder between Pane Groups;
- reorder inside one group;
- join the visible group through a work-area split;
- invalid non-contiguous placement.

Pane dragging is local to one Anvil window. Do not convert a Pane into a file-only IPC drag.

## General View placement API

### Placement request

Use one options shape:

```lua
{
  pane = pane_or_id,
  placement = "current" | "new" | "split",
  direction = "left" | "right" | "up" | "down",
  focus = true,
  preserve_focus = false,
  reason = "feature-name",
}
```

Rules:

- `current` targets the active Pane;
- `new` appends a one-Pane group;
- `split` inserts into the target Pane Group;
- no existing Pane plus `current` behaves as `new`;
- an explicit invalid Pane fails instead of guessing;
- `preserve_focus` restores the starting focus after opening;
- View construction remains lazy and transactional.

### File opening

Opening a file uses an Editor and the canonical file-backed Buffer.

Default placement is the current Pane.

If no Pane exists, create one.

Opening another file suspends the current suspendable View.

Opening from an Untitled Editor runs its close flow first.

Opening the same Buffer in the same Pane restores or updates its Editor place.

Opening the same Buffer in another Pane creates another Editor with independent Selection State.

### Image opening

Image View follows the same placement request.

Remove assumptions that image tabs belong to Left or Right Pane lists.

### Point of Interest activation

POI activation accepts an explicit target Pane when a workflow has one.

Without an explicit target, activation replaces the source Pane's Current View. Navigation Back returns to the source View.

Feature commands that formerly meant “activate from Right Pane into Left Pane” must be renamed around their actual source and target behavior.

Do not preserve Right Pane names.

## File Tree migration

### Module shape

Change `plugins.filetree` from a constructed singleton into a factory and instance service.

Suggested exports:

```lua
FileTreeView
filetree.open(options)
filetree.instances()
filetree.for_pane(pane)
filetree.resolve_target(target, context)
```

Requiring the module must not construct a File Tree.

### Instance state

Each File Tree owns:

- `root_path`;
- `current_dir`;
- private Buffer;
- path-row snapshot;
- expansion state;
- selection state;
- sort mode;
- filesystem watch set;
- Git status controller;
- pending edits.

`up-dir` clamps at `root_path`, not the Root Project.

A default Root Project File Tree can include configured Project path sections.

An arbitrary scoped File Tree does not append unrelated Project roots by default.

### Target resolution

Use these exact rules:

1. no target uses the Root Project;
2. a directory target becomes `root_path`;
3. a file target uses its parent as `root_path` and selects the file;
4. an absolute path is normalized directly;
5. a relative path resolves against source context;
6. Terminal source context uses terminal working directory;
7. Editor source context uses the active file directory;
8. another source uses the Root Project;
9. `.` always means the context directory;
10. a no-target Root Project tree can still select the active file when it belongs to that tree.

Do not give `.` a special file meaning.

### Editing semantics

File Tree remains a Text View.

Normal movement, selection, copy, cut, and text-edit interaction can apply.

Applying File Tree edits mutates the filesystem through File Tree commands.

Do not classify the File Tree as an Editor merely because it uses a Buffer.

### Commands

Replace toggle and side-specific commands with direct commands:

```text
filetree:open
filetree:open_at_project_root
filetree:open_at_path
filetree:open_at_current_file
filetree:refresh
filetree:apply_changes
filetree:up_dir
filetree:select_all
```

A generic `view:close` or Navigation Back replaces hide-and-focus-left behavior.

Remove:

- permanent registration;
- `filetree:toggle` side visibility semantics;
- `filetree:focus-editor-and-hide`;
- `filetree:focus-and-show`;
- `open-right` naming;
- `last_left_pane_view`;
- `visible` as Right Pane state;
- fixed side width updates.

### Persistence

File Tree View state stores lightweight instance identity and UI state.

Do not persist generated Buffer text as the authority.

On restore, rebuild from filesystem state and reapply valid expansion and selection paths.

Missing roots cause that View restore to fail quietly with a clear diagnostic.

## Terminal migration

### Placement

`terminal:open` replaces the active Pane's Current View.

If no Pane exists, it creates Pane 1.

Add explicit placement variants only when a workflow needs them:

```text
terminal:open
terminal:open-project-directory
terminal:open-buffer-directory
terminal:open-new-pane
terminal:open-split
```

The internal API takes placement options rather than separate Left or Right functions.

### Suspension

A running Terminal returns true from `can_suspend`.

It returns false from `can_discard_suspended` while its process runs.

Its shell session must keep draining output while its View is hidden or suspended.

Do not depend on visible `TerminalView:update()` calls to prevent PTY blockage.

Move required session servicing into one of these small seams:

- a terminal service thread;
- a session controller owned outside the View;
- `update_suspended` with adaptive scheduling.

Prefer a service/controller when it also simplifies capture-mode shell execution.

### Workspace restore

Add `TerminalView:get_state()` and `TerminalView.from_state()`.

Persist only:

- shell launch choice;
- last known working directory;
- terminal title fallback where useful;
- configuration needed to start a replacement session.

On restart, create a new shell.

Do not claim to restore scrollback or child process state.

### External OS terminal

Rename the existing external action to a clear command such as:

```text
system-terminal:open-at-current-buffer
```

Keep it available through command search.

Do not bind it to `Ctrl+Alt+T`.

## Shared shell execution service

### Purpose

Terminal and Command Output have different presentation models.

They still share shell launch policy and process lifecycle concepts.

Create one small shell service. Do not force Command Output through terminal-grid rendering.

Suggested module:

```text
data/core/shell.lua
```

### Responsibilities

The shell service owns:

- shell selection;
- shell kind detection;
- working directory resolution;
- environment preparation;
- interactive launch specification;
- capture launch specification;
- command quoting or script payload construction;
- cancellation;
- exit-state normalization;
- common quiet diagnostics.

### Modes

```text
interactive mode -> native PTY / Terminal session
capture mode     -> redirected process / linear output stream
```

Interactive mode preserves:

- ANSI terminal state;
- cursor behavior;
- alternate screens;
- mouse protocols;
- interactive input.

Capture mode preserves:

- stdout and stderr bytes;
- deterministic completion;
- exit code;
- cancellation;
- output caps;
- plain-text conversion policy.

### Shell adapters

Use a small adapter per shell family when command invocation differs:

- PowerShell;
- `cmd.exe`;
- POSIX-like shells.

Do not spread PowerShell JSON controller construction across Command Slots.

Do not add shell abstractions for shells that Anvil cannot launch or test.

### Prewarming

The old Command Slot implementation starts four prewarmed PowerShell workers.

Remove prewarming in the first shared service unless a focused measurement proves a user-visible regression.

Starting one process per run is simpler and isolates slot failures.

If measurements require reuse later, add pooling behind the capture service. Do not put worker ownership back into Command Slot Views.

### Capture record

Suggested event stream:

```lua
on_output(bytes)
on_exit({ code = number, elapsed = number })
on_error({ kind = string, message = string })
```

Every run has a generation or token.

Stale output from a canceled run must not enter a newer output entry.

## Command Output redesign

### Buffer model

Rename `CommandOutputDoc` to `CommandOutputBuffer`.

Keep it read-only through public mutation paths.

Internal append and replacement use an explicit controlled mutation scope.

Do not make it an Editor Buffer.

### View model

`CommandOutputView` extends Text View.

It owns or selects one output entry.

It keeps:

- read-only text behavior;
- POI parsing and cache;
- output selection;
- scroll position;
- follow-end behavior;
- copy support.

Remove `CommandOutputPanel`.

Remove its nested A/S/D/F Tab strip.

### One-time command runs

The Pane Command Bar starts a capture run.

It creates a new end Pane with one Command Output View.

The header format must identify:

- shell or prompt marker;
- working directory;
- exact command.

The footer identifies:

- exit code or start failure;
- cancellation;
- elapsed time;
- truncation when applicable.

### Output conversion

Keep output as linear text.

ANSI handling can start with the existing bounded stripping behavior.

Do not duplicate a second full terminal parser in Lua.

If the native terminal backend later exposes a safe stream-to-plain-text helper, evaluate it behind the shell service.

### Output Points of Interest

Retain the current pattern families and path resolution behavior.

Relative paths resolve against the run's recorded working directory, not always the Root Project.

This fixes a current limitation and aligns output with contextual command execution.

POI identity includes the output entry and matched source range.

## Command Slot migration

### Slot state

Each Project keeps four slot records.

Suggested shape:

```lua
{
  index = 1,
  key = "a",
  label = "A",
  command = "...",
  output_history = {},
  output_index = 0,
  output_view = nil,
  pane_id = nil,
  running = nil,
}
```

### Running a slot

1. Resolve the Project slot.
2. prompt when no command exists.
3. cancel the old run when rerunning the same slot.
4. create a new output entry.
5. find the slot Pane by stable identifier.
6. create a new end Pane when missing.
7. restore the retained output View when it is suspended in that Pane.
8. replace another Current View through normal suspension when required.
9. start capture through `core.shell`.
10. stream output into the selected entry.
11. update POIs incrementally or invalidate their bounded cache.
12. finalize the entry and run state.

Running one slot must not kill another slot.

Closing a slot Pane cancels its active run only after Pane close commits.

Replacing the output View in its Pane suspends it. The active capture can continue in the background.

### Output Pane reuse

Persist `pane_id` only as Workspace-local identity.

If the Pane no longer exists, clear the reference and create another on the next run.

If the Pane exists but another View is current, running the slot restores the output View through Navigation History or direct retained identity.

Do not create duplicate output Views for one slot.

### History integration

Command Output History stores run results.

Pane Navigation History stores View and location transitions.

Navigating between run results can record Navigation Places for the same Command Output View.

Do not store a second copy of output text inside Pane Navigation History.

## Pane Command Bar

### Scope

The Pane Command Bar appears at the bottom of the active Pane.

It is temporary and receives focus while open.

Only one Pane Command Bar needs to be active at a time.

It is not a Pane View and does not get a Tab.

### Reuse

Extract or reuse the existing prompt editing and suggestion behavior.

Do not copy Global Prompt Bar logic into a second large module.

A shared Prompt Bar implementation can render in either:

- window scope;
- Pane scope;
- Text View scope where current find behavior requires it.

Keep the public concepts distinct when their behavior differs.

### Parsing

Trim surrounding input but preserve command content.

For `:` commands, parse one command name followed by shell-like quoted arguments.

Initial grammar:

```text
internal-command := ':' name arguments?
name             := 'edit' | 'tree' | 'terminal'
```

Reject unknown internal commands with concise Status Bar feedback.

Do not send an unknown `:` command to the shell by accident.

Input without `:` is a capture-mode shell command.

### Internal commands

`:edit`:

- no argument opens a new Untitled Editor in the current Pane;
- a file argument opens that file in an Editor;
- a directory argument fails with clear feedback;
- relative paths use source context.

`:tree`:

- applies the File Tree target rules;
- replaces the Current View in the same Pane;
- uses no argument for the Root Project and contextual selection.

`:terminal`:

- opens a Terminal in the same Pane;
- uses the source context for working directory;
- later arguments can be added only with a real use case.

### Shell command context

Resolve working directory from the View that owned the Pane before the bar opened:

1. Terminal working directory;
2. Editor file directory;
3. File Tree current directory;
4. Command Output run directory;
5. Root Project;
6. process working directory as final fallback.

Record the resolved directory in the output entry.

## Overlay behavior

Overlays remain outside Pane Groups.

The Fuzzy Searcher, command search, file search, symbol search, and similar pickers can open from any Pane.

An Overlay records its source Pane before taking focus.

Confirming an Overlay result uses that Pane unless the result requests new or split placement.

Canceling returns focus to the source Pane's Current View.

An Overlay does not create Navigation History merely by opening and closing.

The Runtime Theme Editor can remain an Overlay.

Modal Nag View behavior remains app-wide.

## Workspace persistence

### New schema

Use an explicit new layout version.

Suggested state:

```lua
{
  version = 1,
  visible_group_id = "group-2",
  focused_pane_id = "pane-4",
  groups = {
    {
      id = "group-1",
      layout = { kind = "pane", pane_id = "pane-1" },
    },
    {
      id = "group-2",
      layout = {
        kind = "split",
        axis = "x",
        ratio = 0.5,
        a = { kind = "pane", pane_id = "pane-2" },
        b = { kind = "pane", pane_id = "pane-3" },
      },
    },
  },
  panes = {
    {
      id = "pane-1",
      view = { module = "core.editor", state = {} },
    },
  },
}
```

Group order and layout leaf order define global Tab order.

Do not store computed Pane numbers.

### Save rules

Persist only Current Views.

Do not persist suspended Navigation History.

Save each View through `get_state()` and `get_module()`.

Skip a View that cannot restore.

If skipping a View would leave a Pane without a Current View, skip that Pane.

After skipping Panes, prune empty layout leaves and groups.

If all Panes are skipped, save valid zero-Pane state.

Flush Untitled Recovery before Workspace save.

### Restore rules

1. Validate the schema version.
2. load Pane records without attaching them.
3. restore each Current View.
4. discard invalid View records with quiet logs.
5. rebuild groups from valid Pane identifiers.
6. collapse missing layout leaves.
7. remove empty groups.
8. validate uniqueness and contiguity.
9. restore the visible group when valid.
10. restore focused Pane when valid and visible.
11. otherwise focus the first Pane in the visible group.
12. allow zero Panes.
13. restore Untitled Recovery without duplicating a Workspace-restored Buffer.

### Legacy state

Do not keep a runtime adapter for the old Left/Right Pane schema.

Use the new version boundary.

When old layout state is found:

- quiet-log that the obsolete layout was ignored;
- keep Project Paths, language modes, Recent Files, and other independent Workspace data;
- rely on Untitled Recovery for unsaved Untitled Buffers;
- start with zero Panes if no recoverable current Views remain.

A one-time migration helper is acceptable only if it remains isolated and is removed in the same development cycle.

Do not keep old fields in the target schema.

### Terminal restore

A current Terminal View restores as a new shell using its launch state.

A suspended Terminal does not restore because suspended history is process-local.

### Command Slot restore

Persist slot commands and output history through their Project state service.

Persist the slot output Pane only when that Pane is current Workspace state.

A missing slot Pane reference is normal and is repaired on the next run.

## Command contract

### Pane commands

Canonical commands:

```text
pane:new
pane:close
pane:close-all
pane:split-left
pane:split-right
pane:split-up
pane:split-down
pane:focus-previous
pane:focus-next
pane:focus-left
pane:focus-right
pane:focus-up
pane:focus-down
pane:focus-1 ... pane:focus-9
pane:move-previous
pane:move-next
```

Use generated index commands where practical.

### View commands

```text
view:close
view:open-command-bar
```

### Navigation commands

Keep:

```text
navigation:back
navigation:forward
```

They now operate strictly within the active Pane.

### Text commands

Rename `doc:*` to `text:*`.

Update every in-repo caller without aliases.

### File Tree commands

Use the direct instance commands listed in the File Tree section.

### Terminal commands

Keep terminal-local interaction commands.

Change placement names that mention document or right-side behavior.

### Removed command concepts

Remove or replace:

```text
pane:focus-left-and-hide-right
pane:toggle-focus
pane:open-current-file-opposite
pane:move-current-file-opposite
root:switch-to-tab-*
root:switch-to-next-tab
root:switch-to-previous-tab
filetree:toggle
filetree:focus-editor-and-hide
filetree:focus-and-show
```

Do not preserve deprecated aliases.

## First-party plugin migration

### `data/plugins/anvil_defaults.lua`

- register new mandatory modules;
- remove Right Pane defaults;
- remove File Tree visibility and side-size defaults;
- remove Command Slot prewarm unless measurements retain it;
- rename terminal `cwd_mode = "document"` to `"buffer"`;
- rename `doc:*` keymap command targets to `text:*`;
- bind the internal Terminal command to the accepted shortcut;
- ensure every new style key has a base default.

### Autocomplete and language navigation

- rename Document concepts to Buffer;
- replace Left/Right placement options with explicit Pane placement;
- keep Project symbol and Buffer symbol semantics;
- ensure preview Views do not become Pane Current Views unless confirmed.

### Fuzzy Searcher

- record the source Pane when opening;
- confirm into that Pane by default;
- remove Left Pane and Right Pane assumptions;
- update File Tree preview/focus behavior for several instances;
- prefer the source Pane's File Tree or create one according to command intent;
- retain Overlay identity and focus return behavior.

### Git and Diff Views

- open through the general Pane placement API;
- remove Left Pane tab terminology and fields;
- migrate composite focus ownership to the common seam;
- preserve feature-specific model behavior from `GIT_DIFF_WORKFLOW_PLAN.md`;
- remove `core.tool_window` after Git no longer uses it;
- update Historical Document to Historical Buffer;
- replace opposite-side actions with explicit split or target Pane requests.

### Project Tool Window

Current first-party use is Git-only.

After Git migrates to ordinary Views:

- remove `data/core/tool_window.lua` if no first-party use remains;
- remove event routing for secondary tool windows;
- remove Workspace `tool_windows` state;
- remove performance counters;
- remove tests and glossary entries that become obsolete.

Do not keep an unused framework for possible future use.

### IntelliJ Find and local prompts

- rename Text View references;
- mount local find UI against the Current Text View;
- ensure View replacement closes local prompt state safely;
- do not record prompt focus as a Navigation Place.

### POI

- resolve the source Pane through the common owner seam;
- remove Right Pane navigation commands or rename them around actual Command Output Pane behavior;
- open target Editors through explicit placement;
- resolve output paths against each run's working directory.

### Find File and file prompts

- use Buffer file context;
- open into the source Pane;
- create Pane 1 when the app has zero Panes;
- do not depend on a permanent Editor placeholder.

## Configuration and style cleanup

Remove behavior defaults that only support the old two-pane model.

Expected removals include:

- Right Pane initial visibility;
- Right Pane width ratio;
- File Tree side width;
- side-specific tab allocation;
- side focus shortcuts as commands;
- two-lane Title Bar safe-zone calculations.

Retain general Tab width limits and pagination settings where still useful.

Do not add configuration for:

- Pane number start;
- group contiguity;
- default one-Pane group behavior;
- Untitled Editor suspendability;
- whether Terminal survives suspension.

Those are product rules, not preferences.

## Logging and diagnostics

Use `core.log_quiet(...)` for:

- Pane creation, split, move, and close;
- group creation and removal;
- global order rebuilds;
- invariant failures before raising;
- View replacement requests;
- suspension and resume;
- Untitled Editor replacement approval or cancellation;
- protected history retention;
- terminal background servicing;
- File Tree root resolution;
- shell launch mode and adapter choice;
- Command Slot Pane reuse;
- Workspace pruning and restore fallback;
- ignored legacy layout state;
- Overlay source Pane resolution.

Keep log records concise and include stable Pane identifiers plus current numbers where useful.

Use visible errors only when the user must act.

Examples include:

- a target file cannot open;
- a shell cannot start;
- an Untitled Buffer is at risk because recovery failed;
- a File Tree root no longer exists.

## Performance requirements

### Layout

Layout cost must scale with visible Pane count, not all suspended Views.

Flattening all Panes for Title Bar order is acceptable for normal counts.

Cache only after measurements show a need.

### Drawing

Draw only the visible Pane Group.

Do not draw hidden Current Views or suspended Views.

### Updates

Visible Views update normally.

Hidden Terminal sessions continue required process servicing without full rendering work.

Suspended Text Views do no frame work unless an owned background service requires it.

### Title Bar

Reuse width measurement caches by Pane and Current View title token.

Invalidate when:

- Pane order changes;
- group membership changes;
- Current View changes;
- View title or dirty state changes;
- scale or font changes;
- available width changes.

### Command output

Keep output caps.

Use generation checks.

Avoid reparsing all output each frame.

Parse POIs per changed entry or appended range where practical.

### File Trees

Each instance owns only required watchers.

Hidden and suspended File Trees can coalesce refresh work.

Do not poll every instance each frame.

## Invariant validation

Add a development validator for the Pane manager.

It checks:

1. every group has a valid root;
2. every layout leaf has one Pane;
3. every Pane appears in one leaf;
4. no Pane appears in two groups;
5. every Pane points back to its group;
6. every Pane has one Current View;
7. every Current View belongs to one Pane;
8. every focus target resolves to one owner View;
9. active Pane belongs to visible group;
10. visible group belongs to the manager;
11. zero Panes implies no active Pane and no visible group;
12. flattened group leaves equal global Tab order;
13. Pane numbers are exactly `1..N`;
14. no layout split has a missing child;
15. split ratios are finite and clamped;
16. suspended Views are not Current elsewhere;
17. Untitled Editors do not exist in suspended history.

Run this validator after every structural mutation in tests.

In normal builds, use assertions for impossible internal states and quiet logs around recoverable state input.

## Test strategy

This redesign is very large and crosses many boundaries.

Use red-green tests for each durable behavior slice.

Do not write broad speculative tests before a slice starts.

Pure source renames do not need a fake red failure. They need syntax and behavior preservation checks.

Use public seams:

- Pane commands;
- Pane manager methods;
- Root Panel events;
- Title Bar clicks;
- View lifecycle methods;
- Navigation commands;
- File Tree commands;
- Terminal commands;
- Pane Command Bar submission;
- Workspace save and restore.

Do not test exact shortcuts.

Do not assert private helper call counts.

Do not test exact cosmetic pixels.

### New focused test files

Suggested files:

```text
tests/lua/runtime/pane_layout.lua
tests/lua/runtime/shell.lua
tests/lua/ui/panes.lua
tests/lua/ui/pane_groups.lua
tests/lua/ui/pane_view_lifecycle.lua
tests/lua/ui/pane_navigation_history.lua
tests/lua/ui/pane_command_bar.lua
tests/lua/ui/titlebar.lua
tests/lua/ui/filetree_instances.lua
tests/lua/ui/terminal.lua
tests/lua/ui/command_slots.lua
tests/lua/runtime/workspace.lua
```

Reuse existing files when they already own the stable public seam.

## Implementation sequence

Use the sequence below. Finish each slice before starting the next.

### Phase 0: Baseline and authority cleanup

Purpose: establish a known starting point before the structural cut.

Tasks:

1. commit or preserve the accepted `CONTEXT.md` changes;
2. add this plan;
3. mark older layout statements as superseded where they can mislead active work;
4. record the current focused test results;
5. record current Pane, Workspace, Terminal, and Command Slot logs for comparison;
6. ensure the working tree contains no unrelated edits.

Because the redesign is very large, run the Anvil suite once for the baseline:

```sh
PATH=/c/msys64/mingw64/bin:$PATH /c/msys64/mingw64/bin/meson.exe test \
  -C build-windows-x86_64 --suite anvil --print-errorlogs
```

Do not use this full command after every slice.

### Phase 1: Buffer, Text View, and Editor naming cut

Purpose: remove old domain names before building new architecture.

Work:

1. move `data/core/doc` to `data/core/buffer`;
2. rename class `Doc` to `Buffer`;
3. move `data/core/docview.lua` to `data/core/textview.lua`;
4. rename class `DocView` to `TextView`;
5. create `data/core/editor.lua` as the ordinary Editor class;
6. replace editor marker fields with the Editor class;
7. rename `.doc` fields to `.buffer` in first-party code;
8. rename `core.docs` and Buffer registry APIs;
9. rename `doc:*` to `text:*`;
10. move tests and helper files whose names use the old concepts;
11. update diagnostics, annotations, and plan references;
12. preserve LSP protocol names.

Validation:

- run Lua syntax for every changed Lua file;
- run Buffer runtime tests;
- run Text View UI tests;
- run LSP tests affected by internal field renames;
- run the Anvil suite once after the naming cut because it touches most files.

This phase is mechanical. Do not mix Pane behavior changes into it.

### Phase 2: Pure Pane layout model

Seam: public layout functions with plain fake Panes.

Red tests:

- one leaf returns one Pane;
- each split direction produces expected leaf order;
- nested splits keep deterministic order;
- removing a leaf collapses the parent;
- removing the final leaf returns an empty result;
- hit testing returns the correct Pane;
- divider hit testing uses final rectangles;
- resizing clamps ratios;
- serialization round-trips shape and ratios;
- invalid duplicate Pane state is rejected.

Implementation:

- create the layout-only module;
- copy only useful split geometry from `core.node`;
- omit tabs, Views, locks, and Empty View behavior.

Run only the new layout test.

### Phase 3: Pane manager and Pane Groups

Seam: public Pane manager methods and computed order.

Red tests:

- zero Pane state is valid;
- creating first Pane yields Pane 1 and one group;
- new Pane appends as `N + 1` in a new group;
- splitting inserts next to the source;
- selecting any group member presents the full group;
- number lookup follows flattened order;
- closing renumbers later Panes;
- closing the last Pane returns to zero state;
- no operation creates a non-contiguous group;
- validator catches duplicate and missing membership.

Implementation:

- rewrite `core.panes` around groups;
- add stable identifiers;
- add focus-independent structural methods;
- keep Root Panel integration minimal until Phase 4.

Run only Pane manager tests.

### Phase 4: Root Panel work-area host

Seam: Root Panel update, draw, hit test, and zero-Pane behavior.

Red tests:

- zero Panes draw safely and accept `pane:new`;
- only visible group Views update and draw normally;
- hidden group Views receive no pointer events;
- clicking each visible split area focuses its Pane;
- divider drag changes only target layout ratio;
- final scrollbar geometry matches final Pane rectangles;
- dropped file with zero Panes creates an Editor Pane;
- overlays still receive events before Panes.

Implementation:

- remove work-area Views from locked Node chrome;
- directly lay out Title Bar, Nag View, prompts, work area, and Status Bar;
- route events through Pane manager;
- keep app overlays and deferred draws.

Run `ui/rootpanel.lua` and new Pane Group tests.

### Phase 5: Global Title Bar Tabs

Seam: Title Bar geometry and trusted click behavior.

Red tests:

- one Tab appears per Pane;
- Tabs show one-based numbers;
- group members remain adjacent;
- clicking a hidden-group Tab presents its group;
- clicking a visible sibling focuses without hiding siblings;
- number commands focus current positions;
- pagination keeps the focused Pane visible;
- closing a Tab closes its Pane;
- title state follows Current View replacement;
- borderless hit-test receives a usable drag region.

Implementation:

- adapt `core.tabs` to a Pane item source;
- remove left/right geometry allocation;
- add group boundaries;
- update title cache tokens;
- postpone complex drag until Phase 17.

Run only Title Bar and Pane UI tests.

### Phase 6: General View replacement and suspension

Seam: `panes.replace_view`, lifecycle hooks, and observable live identity.

Red tests:

- replacing a normal View suspends it without closing;
- Back restores the same View instance;
- Forward restores the replacement;
- replacement construction failure keeps the old Current View;
- focus targets map back to the owner Pane;
- a View cannot become Current in two Panes;
- releasing an unreferenced suspended View happens exactly once;
- a protected suspended View survives soft history trimming.

Implementation:

- add lazy replacement transaction;
- add lifecycle hooks;
- add focus-target registration;
- integrate basic Navigation Place capture.

Run only lifecycle and navigation tests.

### Phase 7: Untitled Editor non-suspension

Seam: opening another View through a Pane containing an Untitled Editor.

Red tests:

- blank Untitled Editor closes without history;
- content-bearing Untitled Editor prompts;
- cancel leaves the same Current View and does not construct the target;
- confirm discards recovery and opens the target;
- Save As makes the Editor suspendable;
- another live Editor for the same Untitled Buffer prevents false data-loss wording;
- switching Pane Groups does not prompt or replace;
- splitting does not prompt or replace;
- closing Pane uses existing Untitled recovery guarantees.

Implementation:

- override Editor suspendability from Buffer identity;
- reuse `try_close` and recovery cleanup;
- keep replacement transaction pending until callback.

Run Untitled lifecycle and recovery tests only.

### Phase 8: Editor and file opening migration

Seam: open-file commands and shared Buffer behavior.

Red tests:

- opening a file replaces the active suspendable View;
- opening with zero Panes creates Pane 1;
- Back restores source View and exact location;
- same Buffer in two Panes has independent Selection State;
- image opening follows placement options;
- file drop targets the Pane under the pointer;
- file drop on blank work area creates Pane 1.

Implementation:

- replace `RootPanel:open_doc` and `panes.open_doc` with Buffer and Editor APIs;
- remove singleton left/right Editor fields;
- migrate file-context helpers.

### Phase 9: Navigation History generalization

Seam: `navigation:back` and `navigation:forward` across View types.

Red tests:

- Editor locations stay inside one Pane;
- File Tree state restores in the same Pane;
- Command Output entries restore in the same Pane;
- running Terminal restores as the same live instance;
- histories in two Panes remain independent;
- a new branch clears recreatable forward places;
- protected forward Terminals remain reachable;
- invalid filesystem places trim without harming valid resources;
- composite Git and Diff focus targets map to owner View.

Implementation:

- key histories by Pane ID;
- replace hardcoded kind selection with View protocols;
- keep specific state adapters only where the View owns real domain state;
- remove retired-left/right editor machinery.

Run Navigation History tests only.

### Phase 10: Workspace schema cut

Seam: Workspace save and restore through Pane manager.

Red tests:

- zero Pane Workspace round-trips;
- one Pane Editor round-trips;
- multi-group split layout round-trips;
- Pane numbers derive from restored order;
- focused Pane and visible group restore;
- invalid View state prunes its Pane and layout leaf;
- invalid group state cannot duplicate a Pane;
- legacy Left/Right state is ignored without losing Project Paths;
- Untitled Recovery does not duplicate Workspace-restored Buffers;
- same-window Project switch saves source before destination restart.

Implementation:

- add versioned schema;
- remove old `documents`/left/right layout shape in target state;
- update count and duplicate-workspace logic;
- keep independent Workspace fields.

Run runtime Workspace and focused Untitled tests.

### Phase 11: Multi-instance File Tree

Seam: File Tree commands and observable instance state.

Red tests:

- requiring plugin creates no File Tree;
- two instances keep independent roots and selections;
- no target uses Root Project;
- directory target becomes root;
- file target selects file under parent root;
- relative paths use Editor, Terminal, File Tree, and Root Project contexts;
- dot always means context directory;
- up-dir clamps at instance root;
- replacing File Tree suspends it;
- Back restores same instance and state;
- Workspace restores current File Tree state;
- missing root drops only that View.

Implementation:

- convert singleton module to factory;
- remove permanent/right registration;
- move all singleton closures to instance methods;
- isolate watchers and Git controllers;
- update callers to select or create an instance explicitly.

Run File Tree instance tests and existing focused File Tree files.

### Phase 12: Terminal placement and suspension

Seam: Terminal commands, Pane lifecycle, and native session identity.

Red tests:

- terminal opens in current Pane;
- zero Pane state creates Pane 1;
- replacing Editor suspends it;
- Back restores Editor without closing Terminal;
- Forward restores the exact terminal session;
- hiding its Pane Group keeps session alive;
- background output is drained while hidden;
- closing Terminal View closes session;
- closing Pane closes every retained terminal after close commit;
- Workspace restore starts a new shell with saved launch state;
- internal shortcut command differs from external OS terminal command.

Implementation:

- remove Right Pane placement;
- add lifecycle and state methods;
- move required native session servicing outside visible draw work;
- rename document-directory configuration to buffer-directory.

Run Terminal UI and native runtime tests.

### Phase 13: Shared shell capture service

Seam: public capture run and event stream.

Red tests:

- PowerShell capture returns output and exit code;
- cancellation rejects stale output;
- working directory applies exactly;
- stdout and stderr merge according to policy;
- output cap drains the process without unbounded memory;
- start failure reports one normalized error;
- shell adapters build independent expected argument lists;
- two runs do not share mutable process state.

Implementation:

- extract shell policy;
- keep interactive and capture backends separate;
- remove per-slot process ownership;
- remove prewarming unless measured.

Run shell and process runtime tests.

### Phase 14: Command Output Views

Seam: one-time shell command from a public command function.

Red tests:

- one run creates an end Pane and one-Pane group;
- output header contains command and working directory;
- output streams into a read-only Buffer;
- selection remains usable while output appends;
- footer reports exit and elapsed time;
- truncation remains bounded;
- POIs resolve relative to run directory;
- closing output Pane cancels an active run safely;
- replacing output View suspends it while run continues.

Implementation:

- rename output Buffer class;
- remove Command Output Panel;
- connect capture service;
- retain POI and history behavior.

### Phase 15: Command Slots

Seam: slot commands and reusable output Pane identity.

Red tests:

- first Slot A run creates one Pane;
- second run reuses Pane and View;
- each run adds history;
- slots A and S run independently;
- rerunning A cancels only A's old run;
- replacing Slot A output View and running again restores it;
- closing its Pane clears stale Pane identity;
- next run recreates the Pane;
- output Navigation History and run history remain distinct;
- Project switch keeps commands scoped correctly.

Implementation:

- retain useful slot model and parser code;
- delete nested panel tabs and side placement;
- delegate process work to shell capture service.

### Phase 16: Pane Command Bar

Seam: open bar, submit text, and observe Pane/View results.

Red tests:

- bar anchors to active Pane;
- cancel restores source focus;
- `:edit` opens Untitled Editor;
- `:edit path` resolves context and opens file;
- `:tree` applies target rules;
- `:terminal` opens terminal in current Pane;
- unknown colon command does not execute a shell;
- plain command creates end output Pane;
- shell command working directory follows source context;
- Untitled Editor replacement can cancel the command;
- Overlay opening does not create a Navigation Place.

Implementation:

- extract reusable prompt behavior;
- add scoped geometry;
- add small parser and dispatcher;
- avoid terminal input interception.

### Phase 17: Remaining feature migrations

Migrate one feature family at a time:

1. Fuzzy Searcher and previews;
2. POI activation;
3. language navigation;
4. autocomplete previews;
5. Git Views;
6. Diff Views;
7. Project Paths View;
8. settings and theme tools;
9. image and log Views;
10. examples that compile in test runs.

For each family:

- add or update one focused behavior test;
- remove Left/Right calls;
- use Pane placement;
- update Buffer/Text View names;
- remove old owner fields when migrated;
- run only that feature's focused tests.

### Phase 18: Tab drag, Pane movement, and split polish

Seam: trusted mouse events and command behavior.

Red tests:

- reorder inside group preserves one membership;
- extraction from group collapses source tree;
- drop between groups creates singleton group;
- edge drop joins target group;
- invalid drop changes nothing;
- dragging Current Untitled Editor moves its Pane without close prompt;
- active Pane and focus remain valid after movement;
- numbering updates after every move.

Implementation:

- replace View-tab dragging with Pane dragging;
- add global Title Bar drop geometry;
- reuse existing overlay animation where useful.

### Phase 19: Remove obsolete architecture

Delete after all callers migrate:

- old mixed `data/core/node.lua`;
- old Left/Right implementation in `data/core/panes.lua` history;
- Empty View work-area placeholder paths;
- two-lane Title Bar code;
- old `root:*` tab commands;
- side-specific File Tree commands;
- Command Output Panel;
- Right Pane command wrappers;
- deprecated `core.root_view`, `core.command_view`, `core.status_view`, and `core.title_view` aliases if no external boundary was explicitly retained;
- `core.tool_window` when Git no longer uses it;
- old Workspace layout fields;
- old tests that only characterize removed behavior.

Search for stale concepts and remove all in-repo callers.

### Phase 20: Final validation and performance pass

Run:

- all Lua syntax checks;
- focused Pane, Workspace, File Tree, Terminal, Command Output, Git, Diff, and Overlay tests;
- native Terminal tests if native code changed;
- full Anvil suite once;
- manual GUI scenarios;
- D3D11 diagnostics when layout drawing changes;
- Workspace restart checks in the dev portable app.

Then run `update-anvil-dev-build.bat` because non-Lua files or installed default data will likely change.

Close Anvil first when replacing binaries.

## Red-green evidence required during implementation

For each behavioral slice, record:

- exact test file;
- test name;
- expected red failure;
- smallest implementation change;
- green result;
- broader focused tests run.

Examples:

```text
RED: ui/pane_view_lifecycle.lua
     “keeps a running Terminal alive when another View becomes current”
     failed because TerminalView:try_close closed the native session.

GREEN: same test passed after View Suspension used on replacement.
```

Do not claim red-green for mechanical file renames.

## Validation commands

### Lua syntax

For a focused set:

```sh
./build-windows-x86_64/subprojects/luajit/src/luajit.exe check-lua-syntax.lua \
  data/core/panes.lua \
  data/core/pane_layout.lua \
  data/core/rootpanel.lua \
  data/core/titlebar.lua
```

For all bundled Lua files after the naming cut:

```sh
find data -name '*.lua' -print0 | \
  xargs -0 ./build-windows-x86_64/subprojects/luajit/src/luajit.exe check-lua-syntax.lua
```

### Focused tests

Examples:

```sh
PATH=/c/msys64/mingw64/bin:$PATH /c/msys64/mingw64/bin/meson.exe test \
  -C build-windows-x86_64 anvil:lua-runtime \
  --test-args runtime/pane_layout.lua --print-errorlogs

PATH=/c/msys64/mingw64/bin:$PATH /c/msys64/mingw64/bin/meson.exe test \
  -C build-windows-x86_64 anvil:lua-ui \
  --test-args ui/pane_view_lifecycle.lua --print-errorlogs

PATH=/c/msys64/mingw64/bin:$PATH /c/msys64/mingw64/bin/meson.exe test \
  -C build-windows-x86_64 anvil:lua-ui \
  --test-args ui/terminal.lua --print-errorlogs
```

### Full Anvil suite

Use only at major cut points and final completion:

```sh
PATH=/c/msys64/mingw64/bin:$PATH /c/msys64/mingw64/bin/meson.exe test \
  -C build-windows-x86_64 --suite anvil --print-errorlogs
```

### Dev portable update

After non-Lua changes:

```sh
cmd.exe //d //s //c "call C:\Projects\c_projects\anvil-editor\update-anvil-dev-build.bat"
```

Lua-only edits use the existing junctions and do not need reinstall.

## Manual scenario matrix

### Empty launch

1. Start a Project with no Pane Workspace state.
2. verify no Tabs appear.
3. verify blank work area renders correctly.
4. open command search.
5. press the new-Pane shortcut.
6. verify Pane 1 contains an Untitled Editor.

### Pane creation and groups

1. create Panes 1, 2, and 3.
2. split Pane 1 to create a neighbor.
3. verify all Tabs remain visible.
4. verify group members are adjacent.
5. select each group member.
6. verify the group remains visible and focus changes.
7. select a singleton group.
8. verify the split group hides without closing Views.

### Terminal lifetime

1. open a Terminal in a file-backed Editor Pane.
2. run a long command.
3. navigate Back to the Editor.
4. wait for terminal output.
5. navigate Forward.
6. verify the same shell and output remain.
7. hide the Pane Group.
8. return and verify the shell remained alive.
9. close the Pane and verify the process closes.

### Untitled replacement

1. create a blank Untitled Editor.
2. open a Terminal in the same Pane.
3. verify no prompt.
4. return to an Untitled Editor and enter text.
5. request File Tree in the same Pane.
6. cancel the discard prompt.
7. verify File Tree was not constructed or opened.
8. request again and confirm.
9. verify the Untitled Editor is absent from Back history.

### File Tree instances

1. open Root Project File Tree.
2. open another File Tree rooted at a subdirectory.
3. split them into one group.
4. change expansion and selection independently.
5. navigate away and back in each Pane.
6. restart Anvil.
7. verify current File Tree instances restore.

### Command output

1. open Pane Command Bar from an Editor.
2. run a command that prints stdout, stderr, and a file location.
3. verify a new end Pane appears.
4. select and copy output.
5. activate the file POI.
6. navigate Back to output.
7. verify the run working directory controlled relative path resolution.

### Command Slots

1. configure Slot A.
2. run Slot A.
3. replace its output View with a Terminal.
4. run Slot A again.
5. verify the same output Pane and View return.
6. move through output run history.
7. run Slot S concurrently.
8. verify independent cancellation and output.

### Workspace

1. create several Pane Groups and splits.
2. include Editor, File Tree, Terminal, and Command Output Current Views.
3. restart Anvil.
4. verify group shape and Pane order.
5. verify Terminal starts a new shell.
6. verify no suspended history falsely restores.
7. close all Panes and restart.
8. verify zero-Pane state restores.

### Drag and reorder

1. reorder singleton groups.
2. extract one Pane from a split group.
3. join it to another group with an edge drop.
4. verify numbering and Tab grouping after each action.
5. verify no View closes during Pane movement.

## File-by-file migration guide

### Core layout and shell

`data/core/init.lua`

- initialize the new Pane manager;
- remove locked chrome Node construction;
- remove Left Pane setup;
- remove obsolete compatibility aliases;
- update event routing for removed Tool Windows when applicable;
- rename Buffer APIs and registries.

`data/core/node.lua`

- extract split geometry into `data/core/pane_layout.lua`;
- delete after all work-area callers migrate.

`data/core/panes.lua`

- complete rewrite around Pane Groups;
- no Left/Right fields;
- own structural mutations and Workspace state.

`data/core/rootpanel.lua`

- host application chrome directly;
- render one visible Pane Group;
- route events to Panes and Overlays;
- remove local View-tab dragging.

`data/core/titlebar.lua`

- use global Pane Tabs;
- draw numbers and group state;
- remove dual-lane allocation.

`data/core/tabs.lua`

- retain generic measurement and paging where useful;
- adapt item owner from Node Views to Panes;
- remove assumptions that active item is a View.

`data/core/view.lua`

- add suspension and navigation hooks;
- keep permanent close and Workspace protocols distinct.

`data/core/emptyview.lua`

- remove if no internal feature requires it after zero-Pane migration.

`data/core/file_context.lua`

- rename Document fields to Buffer;
- remove left fallback;
- resolve context from source Pane and Current View.

`data/core/commands/root.lua`

- replace with Pane commands or move to `commands/pane.lua`;
- remove View-tab operations.

`data/core/keymap.lua` and `keymap-macos.lua`

- point existing workflow shortcuts to new commands;
- do not preserve old command aliases.

`data/core/global_prompt_bar.lua`

- extract reusable scoped prompt behavior;
- remove Root Panel monkey patches when direct routing can replace them.

`data/core/tool_window.lua`

- delete after Git migration if no first-party use remains.

`data/core/poi.lua`

- replace Right Pane targeting with explicit Pane targeting.

`data/core/shell.lua`

- new shared shell launch and capture policy.

### Buffer and Text View

`data/core/doc/*`

- move to `data/core/buffer/*`;
- rename classes and annotations.

`data/core/docview.lua`

- move to `data/core/textview.lua`;
- rename fields and methods;
- keep Text View presentation behavior.

`data/core/docview_line_packets.lua`

- move to `data/core/textview_line_packets.lua`.

`data/core/editor.lua`

- new explicit Editor class;
- own ordinary Buffer Workspace state and Untitled suspendability.

`data/core/commands/doc.lua`

- move to `data/core/commands/text.lua`;
- rename command namespace.

### Plugins

`data/plugins/workspace.lua`

- save new Pane schema;
- preserve independent Project state;
- remove tool-window state after deletion.

`data/plugins/navigation_history.lua`

- key by Pane ID;
- use general View state protocol;
- protect running Terminals;
- enforce no Untitled Editor suspension.

`data/plugins/untitled_tabs.lua`

- rename around Untitled Editors and Buffers;
- replace tab-title patching with Pane Tab title contribution;
- keep creation and close behavior.

`data/plugins/untitled_recovery.lua`

- rename model terms;
- integrate replacement close transaction;
- remain independent from Pane history.

`data/plugins/filetree/init.lua`

- factory, multi-instance state, arbitrary roots;
- no permanent registration;
- no side visibility.

`data/plugins/terminal.lua`

- current-Pane placement;
- suspend/resume;
- shared shell policy;
- Workspace launch state.

`data/plugins/command_slots.lua`

- remove Command Output Panel;
- use shared capture service;
- one output Pane per slot.

`data/plugins/fuzzy_searcher/init.lua`

- source Pane ownership;
- no Left/Right result placement;
- multi-instance File Tree integration.

`data/plugins/git_view.lua`, `data/plugins/git/view.lua`

- ordinary Pane Views;
- no Tool Window or side assumptions.

`data/plugins/diffview.lua`

- explicit Pane targets;
- Text View and Buffer names;
- composite focus registration.

`data/plugins/autocomplete.lua`

- Buffer terminology;
- preview Overlay behavior;
- source Pane restoration.

`data/plugins/intellij_find.lua`

- Text View terminology;
- scoped prompt routing.

`data/plugins/intellij_actions.lua`

- internal Terminal command binding;
- clear external OS terminal command name;
- Pane and text command namespaces.

`data/plugins/findfile.lua`

- current Pane default;
- zero-Pane creation.

`data/plugins/anvil_defaults.lua`

- mandatory modules, defaults, and command names;
- remove side-specific defaults.

### Tests

`tests/lua/ui/panes.lua`

- replace two-pane tests with Pane manager and group behavior.

`tests/lua/ui/node_tabs.lua`

- split into pure Pane layout and Title Bar tests;
- remove local Node View-tab behavior.

`tests/lua/ui/rootpanel.lua`

- zero Pane, visible group routing, final geometry.

`tests/lua/ui/titlebar.lua`

- one global Pane sequence and group selection.

`tests/lua/ui/navigation_history.lua`

- Pane-scoped history across all applicable Views.

`tests/lua/runtime/workspace.lua`

- new versioned schema and legacy rejection.

`tests/lua/ui/filetree_*.lua`

- create explicit instances;
- remove singleton/right assumptions.

`tests/lua/ui/terminal.lua`

- current Pane placement and suspension.

`tests/lua/ui/command_slots.lua`

- reusable output Pane and shared execution.

`tests/lua/ui/git_view.lua` and `tool_window.lua`

- migrate Git to Pane Views;
- delete Tool Window tests if framework is removed.

## Risk register

### Risk: mixed terminology survives

Impact: future code recreates old conceptual confusion.

Control:

- isolated naming phase;
- no aliases;
- final repository searches;
- update tests and plans.

### Risk: Pane and group order drift

Impact: Tabs show wrong numbers or groups become non-contiguous.

Control:

- derive order from group layout trees;
- avoid duplicate mutable order sources;
- validate every mutation.

### Risk: View replacement loses state

Impact: user loses location, terminal process, or unsaved content.

Control:

- lazy transactional replacement;
- explicit suspend protocol;
- targeted failure tests;
- Untitled close gate before target construction.

### Risk: suspended Terminal stops draining output

Impact: child process blocks or output disappears.

Control:

- session controller independent from visible rendering;
- hidden-output integration test;
- quiet state diagnostics.

### Risk: protected resources become unreachable

Impact: hidden running processes consume resources with no return path.

Control:

- protected history places remain reachable;
- no unreachable resource registry;
- explicit close and Pane close controls.

### Risk: Workspace migration loses Untitled text

Impact: data loss.

Control:

- flush Untitled Recovery first;
- preserve recovery manifest independently;
- ignore old layout only after recovery is durable;
- targeted consumed-workspace tests.

### Risk: File Tree singleton closures leak across instances

Impact: commands mutate the wrong tree.

Control:

- move every closure to instance methods;
- command predicates return active instance;
- multi-instance tests.

### Risk: shell abstraction becomes too large

Impact: architecture grows without user value.

Control:

- support only interactive and capture modes;
- use small shell-family adapters;
- keep presentation outside service;
- remove prewarming first.

### Risk: code rename hides behavior regressions

Impact: failures become hard to localize.

Control:

- perform naming cut separately;
- no behavior work in that phase;
- full suite at the cut boundary.

### Risk: old plans direct later work incorrectly

Impact: Left/Right behavior returns.

Control:

- authority statement in this plan;
- update old plans after migration;
- rely on `CONTEXT.md` terms.

## Completion criteria

The redesign is complete only when all conditions below hold.

### Domain language

- first-party source uses Buffer, Text View, Editor, Pane, Pane Group, and Tab correctly;
- no first-party user-facing Document or DocView language remains;
- protocol-required `textDocument` names remain exact;
- `CONTEXT.md` matches behavior.

### Pane model

- zero Panes is valid;
- each Tab represents one Pane;
- Pane numbering starts at 1;
- every Pane belongs to one contiguous Pane Group;
- selecting a group member shows the full group;
- every Pane has one Current View;
- no local View tab strip remains.

### Lifecycle

- normal replacement suspends;
- Terminal sessions survive replacement and hidden groups;
- Untitled Editors never suspend;
- canceling Untitled close cancels replacement;
- explicit Pane close releases all owned resources exactly once;
- protected resources remain reachable.

### Views

- Editors, File Trees, Terminals, Images, Git Views, Diff Views, and Command Output Views open through general placement;
- several File Trees can coexist;
- File Trees support arbitrary roots;
- no feature uses permanent Right Pane registration.

### Command workflow

- `Ctrl+T` behavior creates an end Pane with Untitled Editor;
- internal Terminal command opens in current Pane;
- Pane Command Bar runs `:edit`, `:tree`, and `:terminal`;
- plain Pane Command Bar input creates Command Output Pane;
- Command Slots reuse output Panes and Views;
- command output keeps text, history, copy, and POI behavior.

### Persistence

- Workspace restores Pane Groups, splits, Current Views, visible group, and focus;
- zero-Pane Workspace state restores;
- legacy Left/Right layout is not retained in target state;
- Untitled Recovery remains safe;
- current Terminal restores as a new process with saved launch state;
- suspended history does not falsely persist.

### Cleanup

- no Left Pane or Right Pane implementation remains;
- no Blank Editor Placeholder remains;
- no Command Output Panel remains;
- no File Tree singleton remains;
- no local Node View tabs remain;
- no obsolete compatibility aliases remain;
- Tool Window framework is removed when unused;
- stale tests and plan language are updated or removed.

### Validation

- focused red-green tests pass for every behavioral slice;
- all bundled Lua files pass LuaJIT syntax validation;
- relevant native tests pass;
- full Anvil suite passes at final cutover;
- manual scenario matrix passes in the dev portable app;
- the updated portable app launches with the intended default renderer.
