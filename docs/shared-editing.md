# Shared editing: seamless reload, Disk Conflicts, and collaboration

This document records the design discussion about shared Markdown vaults, external changes, and collaborative editing in Anvil. It is a plan, not a description of shipped behavior.

## Goal

A file can change on disk while it is open in Anvil. An agent can rewrite it, or Nextcloud sync can deliver a colleague's change. Anvil must take that change into the open Buffer without friction:

- Nothing jumps. The caret, the selections, and the visible text stay in place.
- Changes that do not touch the user's unsaved edits merge without a prompt.
- True conflicts are rare. When they occur, Anvil shows them clearly and does not lose text.

Later, people must also be able to edit the same note at the same time with the same smoothness.

Out of scope: special integration for agents. Agents keep editing files on disk. Anvil treats their writes like any other external change.

## Starting point: the investigation report

An investigation agent proposed this stack for a company vault: Nextcloud for files and permissions, Yjs (a CRDT) for live text, a Hocuspocus collaboration server, an agent editing API, and Git for large changes.

That report assumed a web editor. Anvil is a native editor in C and LuaJIT with its own renderer and no webview. These parts of the report do not fit Anvil:

- **Embed Nextcloud Text.** Anvil has no webview. It would also replace Anvil's own Markdown Live Preview.
- **Yjs editor bindings.** The CodeMirror and Monaco bindings are for JavaScript editors. The only in-process Yjs path is Yrs (Rust) through a Lua C module. That adds a Rust toolchain to the build, plus an adapter for the Hocuspocus protocol.
- **An agent editing API.** The user does not want agent integration. Agents keep editing files.
- **Permission bridge, audit log, edit journal, change sets across notes.** Each one is too much for now. Build them only when the live mode needs them.

A second reviewer (GPT-6 Astra) checked both the report and the first response against the code. Its corrections are part of this design:

- Nextcloud sync conflicts can hide a saved local change in a conflict copy. A merge on reload cannot recover it from the original path.
- The expected-text check in Pi's `edit` tool does not make the read and the write one step.
- A central server does not by itself make live editing simple. Rebase, selective undo, cursor mapping, and recovery are still necessary.
- Other risks: the same file open in two Project processes, Autosave timing, line endings and encodings, and renamed or deleted notes.

## How reload works today

- `data/plugins/autoreload.lua` watches open files. When a clean Buffer's file changes, it calls `Buffer:reload()`. When the Buffer is dirty, it asks the user whether to reload.
- `Buffer:reload()` loads the file and publishes a full snapshot (`publish_snapshot` in `data/core/buffer/init.lua`). That replaces all lines, clears undo and redo, and keeps selections only as clamped line and column numbers.
- Selections therefore keep their numbers, not their text. If 50 lines appear above the caret, the caret lands on other text.
- The Text View already shifts its scroll for incremental edits above the visible area (`data/core/textview.lua`, `anchor_delta`). A full snapshot skips that step, so the view jumps.
- `data/plugins/autosave_fast.lua` keeps the disk state from the last load or save, including the file text up to 5 MiB. Before a save, it checks that the disk did not change. If the disk changed, it shows a prompt: Overwrite Disk, Reload From Disk, Save Copy, or Cancel.
- `data/plugins/reload_diff_flash.lua` flashes the lines that a reload changed.
- `src/api/diff.c` gives a native line diff (`diff.diff_iter`) and a word diff (`diff.inline_diff`).

## The reload engine

### Main rule

A reload is an edit, not a replacement. Anvil compares texts and applies only the changed parts through `Buffer:apply_edits`, as one undo step.

All code that already follows normal edits then follows reloads too: selections, the Text View scroll shift, incremental syntax and Markdown updates, folds, and bookmarks.

### The three texts

- **Base:** the Buffer text at the last load, save, or merge. Anvil stores it in Buffer form (UTF-8, LF lines), not as file bytes. Line endings and encodings then cannot cause false changes, and Autosave's 5 MiB limit does not apply.
- **Mine:** the current Buffer text.
- **Disk:** the new file, decoded with the same steps as a normal load.

### Cases

1. **The Buffer is clean.** This is the usual case, because Autosave saves after 3 seconds. Anvil compares Mine with Disk and applies the differences. The Buffer stays clean.
2. **The Buffer is dirty, and the changes do not overlap.** Anvil merges the three texts. It applies the Disk changes that do not touch the user's edits. The user's edits stay unsaved, and Autosave writes the merged text. The base becomes the Disk text.
3. **The changes overlap.** This is a Disk Conflict. See below.

### Details that prevent jumps

- First compare lines. Then compare words inside the lines that changed. A caret inside a changed line stays at its word.
- A caret inside deleted text moves to the start of the new text.
- The reload flash shows the incoming text.
- One undo reverts the whole reload. This is the safety net when an agent damages a file with a large rewrite.

### Undo and the clean state

`Buffer:is_dirty()` compares `clean_change_id` with the undo stack index.

- **Clean reload:** apply the edits as one undo step, then mark the Buffer clean. Undo then makes it dirty again, and Autosave writes the old text back. That is correct, because the user chose to undo.
- **Dirty merge:** the old clean index no longer describes a text that matches the disk. If the user undoes back to that index, the Buffer would show as clean while its text differs from the disk. After a dirty merge, the Buffer must stay dirty until the next save.

The reload engine needs no change to how undo stores edits. The history stays one line: the reload is a normal entry in the stack.

### Known limit

An agent can read the file before Anvil's last save and then write back its whole old copy. Anvil cannot tell that from a deliberate revert, so the user's last few seconds of typing disappear. One undo brings them back. Pi's `edit` tool reads and writes in milliseconds, so this happens mostly with whole-file writes.

## Disk Conflicts

Proposed term: **Disk Conflict**. Unsaved Buffer edits and a newer file on disk changed the same text.

### When a conflict exists

A conflict exists only when the disk and the unsaved edits changed the same words:

- Changes in other paragraphs merge without UI.
- Changes on adjacent lines merge without UI.
- The same change on both sides merges without UI.
- Changes to different words of the same line merge without UI. In Markdown, one paragraph is often one long line, so a line-only merge would make too many conflicts.

### What the user sees

Nothing takes focus, and no dialog opens. The user can keep typing.

```
 12   ## Delivery
 13 ▌ The delivery date is Monday, pending approval.
    ┌ Disk ─────────────────────── Keep Mine   Use Disk ┐
    │ The delivery date is Friday 14 November.          │
    └───────────────────────────────────────────────────┘
 14   The courier is DHL.
```

- The user's text stays in place as normal editable text. A conflict stripe in the gutter and a light tint mark it.
- The disk text shows in a block directly below it. The block uses the frame of the Point of Interest Preview. It is not part of the Buffer.
- The block shows the disk text as source, also in Markdown Live Preview. Words that differ from the user's text use the Diff View's colours.
- The user can select and copy text in the block.
- The block header shows only "Disk" and the two actions.

Special shapes:

- **The disk deleted the user's edited text.** The block is empty and says "Deleted on disk". Use Disk removes the user's text.
- **The user deleted text that the disk changed.** The block shows between the two lines where the text was. Keep Mine leaves it deleted.

### Choices

| Choice | Buffer | What Autosave writes |
|---|---|---|
| Keep Mine | No change | The user's text. It replaces the disk text for this conflict |
| Use Disk | The disk text replaces the user's text | The disk text |

- Each choice is one undo step. Undo brings the block back.
- Each choice is a command on the conflict at the caret. The command palette also has Keep Mine for All and Use Disk for All. No default shortcuts are part of this design.
- If the user edits their text until it matches the disk text, the conflict ends.
- Use Both is not in the first version. Copying from the block covers the same need.

### Saving during a conflict

Autosave stops for that file until every conflict is resolved. A save would choose Keep Mine without telling the user, and the disk change would be lost.

Signals:

- The Pane Status Bar shows "2 disk conflicts" in the warning colour. A click goes to the next conflict.
- Each conflict is a Point of Interest, so POI navigation moves between conflicts.
- The scrollbar marks conflicts outside the visible area.

Closing the file or quitting Anvil while a conflict is open asks one question: Keep Mine for All, Use Disk for All, or Cancel. This is the only dialog in the design.

### The disk changes again during a conflict

- New changes in other places merge without UI.
- An open block shows the newest disk text.
- A resolved conflict stays resolved, unless the disk changes the same words again.

Rule: Anvil remembers the disk text that the user already saw. Keep Mine means "I saw this disk text and I reject it". The base for that region becomes the disk text that the user rejected.

### Why not conflict markers or the Diff View

- Git-style conflict markers would go into the text. Autosave would save them, agents would read them, and Markdown Live Preview would show broken text.
- The Diff View cannot apply single changes.

## Collaboration levels

### Who does what

| Job | Nextcloud | Anvil |
|---|---|---|
| User accounts and login | ✔ | |
| Folder sharing, edit or read-only access | ✔ | |
| File storage, backups, version history | ✔ | |
| Access from a phone or a browser | ✔ | |
| Editing, Markdown preview, agents | | ✔ |
| Merge of changes that arrive during editing | | ✔ |
| Live typing and cursors (level 2) | | ✔ and the edit server |

### Level 1: file sync

```
 Alice's laptop                                      Bob's laptop
 ┌──────────────────────────┐                       ┌──────────────────────────┐
 │ Anvil                    │                       │ Anvil                    │
 │   ↕ reads/writes files   │                       │   ↕ reads/writes files   │
 │ Nextcloud folder         │                       │ Nextcloud folder         │
 │   ↕                      │                       │   ↕                      │
 │ Nextcloud desktop client │                       │ Nextcloud desktop client │
 └───────────┬──────────────┘                       └───────────┬──────────────┘
             │ ①                                                │ ①
             └──────────────────► Nextcloud server ◄────────────┘
```

1. A user shares a folder in the Nextcloud web UI.
2. The Nextcloud desktop client on each laptop syncs it to a local folder.
3. Each user opens that folder in Anvil as a Project.
4. When sync writes a colleague's change, the reload engine merges it into the open Buffer.

Anvil makes no network connection. It sees a file that changed, as when an agent writes it. The reload engine is the whole Anvil part of level 1.

What Anvil knows at level 1:

- **What changed:** yes, from the text difference.
- **When:** yes, the time of the disk change.
- **Who:** no. The sync client writes the file. Anvil could ask Nextcloud for the author of the newest version, but that needs a Nextcloud login in Anvil. Check that the versions API returns the author first.
- **Where others are:** no. Files hold no cursors. Cursor files that sync through the folder are rejected: they would show old positions and cause sync traffic and conflict copies.

Limits:

- Changes arrive after the sync delay, from a few seconds to about a minute.
- **Sync conflict copies.** If two users save the same note within the sync delay, the Nextcloud client keeps one version in the file and writes the other to `name (conflicted copy …).md`. Anvil can detect that copy, show the difference as Disk Conflict blocks, and delete the copy when the user resolves them. Anvil must keep the earlier common text to merge correctly.
- Read-only shares: the sync client should mark those files read-only on disk, so Anvil opens them as read-only Buffers. Check this.

### Level 2: live editing

```
 Alice's laptop                                      Bob's laptop
 ┌──────────────────────────┐                       ┌──────────────────────────┐
 │ Anvil ───────────────────┼──② ──► Edit server ◄──┼──② ────────────── Anvil │
 │                          │            │ ③        │                          │
 │ Nextcloud desktop client─┼──① ──► Nextcloud ◄──① ┼─ Nextcloud desktop client│
 └──────────────────────────┘                       └──────────────────────────┘
```

| | Between | Contents | When |
|---|---|---|---|
| ① | Desktop client and Nextcloud | Whole files | As before, for all files |
| ② | Anvil and the edit server | Edits and cursor positions | Open while a shared note is open |
| ③ | Edit server and Nextcloud | Login checks, permission checks, note saves | On join, and a few seconds after typing stops |

One keystroke:

1. Alice types `M`.
2. Her Anvil sends "insert `M` at position 120 of version 41" on connection ②.
3. The edit server gives the edit the next version number and sends it to each other Anvil in the note.
4. Bob's Anvil applies it as a small edit. The delay is about one network round trip.

The edit server saves the note to Nextcloud a few seconds after typing stops. Sync then delivers that file on ①. Anvil recognizes the file as a saved copy of the session and ignores it.

#### Identity

Anvil logs in to Nextcloud once, through Nextcloud's normal login page for desktop apps. It sends that key when it joins a note. The edit server checks the key with Nextcloud and gets the user ID and display name. The server writes the user ID on each message from that connection, so a client cannot claim another name.

#### Messages

| Message | Contents | Stored |
|---|---|---|
| Edit | Position, removed length, inserted text, base version, author | Yes |
| Cursor | Caret and selection at a version, author | No. The server only forwards it |

- Anvil sends a cursor message when the caret moves, at most about 20 times a second.
- A cursor goes away when its connection closes, or after some seconds without messages.
- A received cursor refers to a version. The receiving Anvil moves it past the edits that it applied after that version, with the same rules that move its own selections.

#### What the user sees

- A caret and selection in each person's colour. The colour comes from the user ID, so it does not change.
- A name tag over the caret while that person types, or while the user points at it.
- Scrollbar marks for people outside the visible area.
- A short-lived gutter stripe in the author's colour for recent remote text. Pointing at the line shows the author and the time.
- Conflict blocks after a reconnect name the person instead of "Disk".

#### Conflicts in live mode

- While online, edits do not conflict. The server orders them and both sides apply. Each user sees the other type and can react.
- After a long offline time, the client merges like a reload. The server text takes the place of the disk text, and Disk Conflict blocks show overlaps. Rule: online, merge each edit at once. After a long offline time, merge like a reload.

#### Sync and the live session

A live note reaches a laptop by two paths: the edit session and file sync. Example of the risk: the server saves a copy, Bob types three more words, then sync delivers the older copy. A plain reload merge would read that as a deletion of Bob's words.

Rule: while a note is live, the session owns the text and the file is only a saved copy.

- Anvil ignores disk versions that it knows are copies from the session.
- Anvil takes any other disk change into the session through the reload merge, for example a local agent's write. It goes out as normal edits under the local user's name, marked as an external change. Anvil does not try to identify the agent.

#### History

When the edit server saves into Nextcloud, Nextcloud records the server account as the author. The edit server therefore keeps its own log of who changed which note and when.

### The edit server

The edit server is a separate program. The company hosts it internally beside Nextcloud.

Options:

| Option | Effect on Anvil | Assessment |
|---|---|---|
| Our own small server | Uses the same Lua rules as Anvil for edit order and position mapping | Recommended |
| Hocuspocus (Node.js, Yjs) | Anvil needs Yrs (Rust) and the Hocuspocus protocol | Less server code, much more client code |
| Nextcloud Text's sync | No documented API for other editors | Not an option |

The server does five things:

1. Accept connections from Anvil.
2. Check logins and read or edit access with Nextcloud.
3. Order the edits for each open note and send them to all clients.
4. Forward cursor messages.
5. Save each note to Nextcloud after typing stops, and log authors.

Hosting:

- The same machine as Nextcloud, or a container beside it. It needs little memory or CPU.
- Behind the same reverse proxy as Nextcloud, for example `https://cloud.company.com/anvil-edit`. It shares the address, the TLS certificate, and the firewall rule.
- No user accounts of its own. Nextcloud is the only user database.
- No backup. Notes live in Nextcloud. If the server stops, Anvil falls back to level 1.
- Later option: package it as a Nextcloud AppAPI external app. This is not checked.

Anvil's native `net` module already has TCP client and server sockets (`src/api/net.c`).

### Why central ordering instead of a CRDT

A CRDT is best without a central authority, for example peer to peer or long offline editing. This design has a central server anyway, because Nextcloud must check permissions. A server that orders edits removes CRDT-specific storage, such as binary document state. It still needs rebase, selective undo, cursor mapping, duplicate detection, and recovery. Choose between our own ordering and Yrs only when level 2 starts, after the Anvil side is tested.

## Undo in live mode

The reload engine needs no change to undo. Live editing does.

- Undo entries store edits by line and column: inverse edits plus the selections before and after (`push_batch_undo` in `data/core/buffer/init.lua`).
- A remote edit must not go into the local undo stack. Undo must never revert another person's typing.
- Each undo and redo entry must therefore move past each remote edit, like a cursor. An entry that a remote edit overlaps becomes shorter or goes away. The stored selections move in the same way.
- `Buffer:is_dirty()` uses the undo stack index. Remote edits change the text without changing that index, so the clean state needs another rule in live mode.

This change stays in the undo and dirty-state code of `data/core/buffer/init.lua`. It does not change how the rest of the editor makes edits. It can be tested without a network: two Buffers in one process, joined by a fake server in memory.

## Risks to keep in mind

- **Two Project processes.** Each loaded Project has its own process, and Buffer reuse works only inside one process. Two Projects can open the same note and both write it. The reload engine lets them converge through the disk, but each one sees the other's saves as external changes.
- **Autosave timing.** Autosave saves 3 seconds after typing stops, at the latest after 30 seconds, and when focus moves. An external writer can still save between Anvil's read and write.
- **Line endings and encodings.** Loading converts text to UTF-8 with LF lines, and saving converts it back. Compare texts in Buffer form only.
- **Rename and delete.** An external delete marks the Buffer's file missing. Anvil cannot tell a rename from a delete.
- **Large files.** Autosave keeps disk text only up to 5 MiB. The base must come from the Buffer, not from that copy.

## Order of work

1. **Reload engine, clean Buffers.** Reload as small edits with no jump, one undo step, and the Buffer stays clean.
2. **Reload engine, dirty Buffers.** A three-way merge with words compared inside lines. Until step 3 exists, true conflicts keep today's prompt.
3. **Disk Conflict blocks.** The inline block, the choices, the status, POI navigation, and the close question.
4. **Nextcloud sync conflict copies** (level 1): detect a conflict copy and show it as Disk Conflict blocks.
5. **Live editing inside Anvil, with no network:** selective undo, remote cursors, an edit feed into and out of the Buffer, and a fake server in tests.
6. **The edit server** (level 2), and the rules for sync and the live session.

Before step 6, answer these questions:

- How many people type in the same note at the same time?
- Are they on one office network or on the internet?
- Can the company host one small service beside Nextcloud?
