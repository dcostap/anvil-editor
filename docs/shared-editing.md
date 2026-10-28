# Shared editing: seamless reload, Disk Conflicts, and collaboration

This document is the plan for external changes, Disk Conflicts, and collaborative editing in Anvil. Step 1 of the order of work is shipped. The rest is a plan, not a description of shipped behavior.

## Goal

A file can change on disk while it is open in Anvil. An agent can rewrite it, or Nextcloud sync can deliver a colleague's change. Anvil must take that change into the open Buffer without friction:

- Nothing jumps. The caret, the selections, and the visible text stay in place.
- Changes that do not touch the user's unsaved edits merge without a prompt.
- True conflicts are rare. When they occur, Anvil shows them clearly and does not lose text.

Later, people must also be able to edit the same note at the same time with the same smoothness.

Out of scope: special integration for agents. Agents keep editing files on disk. Anvil treats their writes like any other external change.

## Rejected options

An earlier investigation proposed a web-editor stack: Nextcloud, Yjs, a Hocuspocus server, an agent editing API, and Git. These parts do not fit Anvil, which is a native editor with its own renderer and no webview:

- **Embed Nextcloud Text.** Anvil has no webview. It would also replace Anvil's own Markdown Live Preview.
- **Yjs editor bindings.** They are for JavaScript editors. The only in-process path is Yrs (Rust) through a Lua C module, which adds a Rust toolchain and a Hocuspocus protocol adapter.
- **An agent editing API.** Agents keep editing files.
- **Permission bridge, audit log, edit journal, change sets across notes.** Build each one only when live editing needs it.

## The reload engine

### Main rule

A reload is an edit, not a replacement. Anvil compares texts and applies only the changed parts through `Buffer:apply_edits`, as one undo step.

All code that already follows normal edits then follows reloads too: selections, the Text View scroll shift, incremental syntax and Markdown updates, folds, and bookmarks.

This is shipped for clean Buffers. `Buffer:reload()` compares lines, then words inside changed lines (`data/core/buffer/text_edits.lua`), and applies the result through `Buffer:apply_lines`. `data/plugins/reload_diff_flash.lua` flashes the changed lines. Dirty Buffers still get the Autoreload prompt, and Autosave still shows its prompt when the disk changed before a save.

### The three texts

- **Base:** the newest text that Anvil knows is on disk. It is the text of the last load, save, or reload, or the Disk text of the last merge.
- **Mine:** the current Buffer text.
- **Disk:** the new file, decoded with the same steps as a normal load.

Anvil stores the base in Buffer form (UTF-8, LF lines), not as file bytes. Line endings and encodings then cannot cause false changes. The base is a copy of the Buffer's lines table. Lua shares strings, so the copy costs one reference for each line, not a copy of the text. Autosave's 5 MiB text limit then does not apply, and Autosave can use the base instead of its own text copy.

One rule for the base covers all cases, also open conflicts: after each merge, the base is the Disk text, even where a conflict block is still open.

### Cases

1. **The Buffer is clean.** This is the usual case, because Autosave saves after 3 seconds. Anvil applies the differences between Mine and Disk. The Buffer stays clean. This is shipped.
2. **The Buffer is dirty, and the changes do not overlap.** Anvil merges the three texts. It applies the Disk changes that do not touch the user's edits. The user's edits stay unsaved, and Autosave writes the merged text.
3. **The changes overlap.** This is a Disk Conflict. See below.

### Details that prevent jumps

- First compare lines. Then compare words inside the lines that changed. A caret inside a changed line stays at its word.
- A caret inside deleted text moves to the start of the new text.
- The reload flash shows the incoming text.
- One undo reverts the whole reload. This brings back text when an agent damages a file with a large rewrite.

### Undo and the clean state

`Buffer:is_dirty()` compares `clean_change_id` with the undo stack index.

- **Clean reload:** apply the edits as one undo step, then mark the Buffer clean. Undo then makes it dirty again, and Autosave writes the old text back.
- **Dirty merge:** the old clean index no longer describes a text that matches the disk. If the user undoes back to that index, the Buffer would show as clean while its text differs from the disk. After a dirty merge, the Buffer must stay dirty until the next save.

The reload engine needs no change to how undo stores edits. The history stays one line: the reload is a normal entry in the stack.

### Undo across a reload

Undo of a reload is useful, but it can also surprise the user. Example:

1. The user types, and Autosave saves.
2. An agent rewrites the file. Anvil reloads it.
3. The user presses undo a few times to remove a typo.
4. The first undo reverts the agent's work. Autosave writes that revert to disk 3 seconds later.

Keep the behavior, and make it visible. When an undo or redo applies a reload entry, flash the changed lines and show "Undid reload from disk" in the status. Nothing else changes.

### Known limit

An agent can read the file before Anvil's last save and then write back its whole old copy. Anvil cannot tell that from a deliberate revert, so the user's last few seconds of typing disappear. One undo brings them back. Pi's `edit` tool reads and writes in milliseconds, so this happens mostly with whole-file writes.

## Disk Conflicts

Proposed term: **Disk Conflict**. Unsaved Buffer edits and a newer file on disk changed the same text. Today, `CONTEXT.md` uses "disk conflict" for any disk change under unsaved edits. When the dirty merge ships, add the term to `CONTEXT.md` with the narrow meaning, and update the Autosave and Run entries.

### When a conflict exists

A conflict exists only when the disk and the unsaved edits changed the same words:

- Changes in other paragraphs merge without UI.
- Changes on adjacent lines merge without UI.
- The same change on both sides merges without UI.
- Changes to different words of the same line merge without UI. In Markdown, one paragraph is often one long line, so a line-only merge would make too many conflicts.

A word merge can join two edits into a sentence that makes no sense. The reload flash shows the merged lines, so the user can see this.

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

While Autosave stops, the user's other edits in that file are not saved either. Anvil has no recovery for unsaved text after a crash. Keep the signals clear, so that conflicts do not stay open for a long time.

Signals:

- The Pane Status Bar shows "2 disk conflicts" in the warning colour. A click goes to the next conflict.
- Each conflict is a Point of Interest, so POI navigation moves between conflicts.
- The scrollbar marks conflicts outside the visible area.

Closing the file or quitting Anvil while a conflict is open asks one question: Keep Mine for All, Use Disk for All, or Cancel. This is the only dialog in the design.

### The disk changes again during a conflict

The base rule handles this case. The base is the Disk text of the last merge, so each open conflict holds the disk text that the user saw:

- New changes in other places merge without UI.
- An open block shows the newest disk text.
- A resolved conflict stays resolved. It comes back only if the disk changes the same words again.

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
             │                                                  │
             └──────────────────► Nextcloud server ◄────────────┘
```

1. A user shares a folder in the Nextcloud web UI.
2. The Nextcloud desktop client on each laptop syncs it to a local folder.
3. Each user opens that folder in Anvil as a Project.
4. When sync writes a colleague's change, the reload engine merges it into the open Buffer.

Anvil makes no network connection. It sees a file that changed, as when an agent writes it.

What Anvil knows at level 1:

- **What changed:** yes, from the text difference.
- **When:** yes, the time of the disk change.
- **Who:** no. The sync client writes the file. Anvil could ask Nextcloud for the author of the newest version, but that needs a Nextcloud login in Anvil. Check that the versions API returns the author first.
- **Where others are:** no. Files hold no cursors. Cursor files that sync through the folder are rejected: they would show old positions and cause sync traffic and conflict copies.

#### Sync conflict copies

This is the main risk of level 1, and the shipped clean reload already meets it:

1. Alice types. Autosave saves within 3 seconds, so her Buffer is clean again.
2. Bob's change reaches the server first. The sync client keeps Bob's version at the original path and moves Alice's version to `name (conflicted copy …).md`.
3. Anvil sees a changed file and a clean Buffer. It reloads Bob's version.
4. Alice's last edits leave her screen. Only the reload flash shows a change.

Autosave saves faster than sync delivers, so this is the normal result when two people edit one note within the sync delay. The dirty merge does not see it, because the Buffer is clean.

Rules:

- When a conflict copy of an open file appears, Anvil warns at once and names the copy. This comes before the full merge.
- The full merge treats the copy as Mine and the original path as Disk. Overlaps show as Disk Conflict blocks. Anvil deletes the copy when the user resolves them.
- The merge needs the common ancestor: the last version that synced. Anvil cannot know it. Anvil uses the last text that it read from disk through a load or reload. That text can be older than the true ancestor. That is safe: the user's edits that already synced are in both versions, and the same change on both sides merges without UI.

Other limits:

- Changes arrive after the sync delay, from a few seconds to about a minute.
- Read-only shares: the sync client should mark those files read-only on disk, so Anvil opens them as read-only Buffers. Check this.

### Level 2: live editing

Level 2 is a sketch. Do not design it in detail before the questions at the end of this document have answers.

```
 Alice's laptop                                      Bob's laptop
 ┌──────────────────────────┐                       ┌──────────────────────────┐
 │ Anvil ───────────────────┼─────► Edit server ◄───┼──────────────────── Anvil │
 │                          │            │          │                          │
 │ Nextcloud desktop client─┼─────► Nextcloud ◄─────┼─ Nextcloud desktop client│
 └──────────────────────────┘                       └──────────────────────────┘
```

- Each Anvil connects to a small edit server while a shared note is open. It sends edits and cursor positions.
- The server gives each edit the next version number and sends it to the other clients. Each Anvil applies it as a small edit, about one network round trip later.
- Anvil logs in to Nextcloud once, through Nextcloud's login page for desktop apps. The server checks the key with Nextcloud and writes the user ID on each message, so a client cannot claim another name.
- While online, edits do not conflict: the server orders them. After a long offline time, the client merges like a reload, with the server text in the place of the Disk text.
- Remote carets and selections show in each person's colour.

#### Who writes the file

This is the central open question. During a live session, a note can have several writers: the Autosave of each client, through its sync client, and the edit server.

- **Each Anvil keeps saving.** Local agents read fresh text. But several clients upload the same note, which can make conflict copies. Check whether the Nextcloud client resolves uploads with identical content without a conflict copy.
- **Only the server writes.** No upload races. But local agents read an old file until the server's save syncs back. A whole-file write from an agent then reverts other people's typing.

In all cases, while a note is live, the session owns the text. Anvil ignores disk versions that it knows are copies of the session. It takes any other disk change, such as a local agent's write, into the session through the reload merge.

#### Central ordering or a CRDT

A CRDT is best without a central authority, for example peer to peer or long offline editing. This design has a central server anyway, because Nextcloud must check permissions. A server that orders edits removes CRDT-specific storage. It still needs rebase, selective undo, cursor mapping, duplicate detection, and recovery.

Options:

| Option | Effect on Anvil |
|---|---|
| Our own small server | Uses the same Lua rules as Anvil for edit order and position mapping. Recommended |
| Hocuspocus (Node.js, Yjs) | Anvil needs Yrs (Rust) and the Hocuspocus protocol. Less server code, much more client code |
| Nextcloud Text's sync | No documented API for other editors. Not an option |

Choose between our own ordering and Yrs only when level 2 starts, after the Anvil side is tested. Anvil's native `net` module already has TCP client and server sockets (`src/api/net.c`).

#### Undo in live mode

The reload engine needs no change to undo. Live editing does:

- A remote edit must not go into the local undo stack. Undo must never revert another person's typing.
- Each undo and redo entry must therefore move past each remote edit, like a cursor. An entry that a remote edit overlaps becomes shorter or goes away.
- `Buffer:is_dirty()` uses the undo stack index. Remote edits change the text without changing that index, so the clean state needs another rule in live mode.

This change stays in the undo and dirty-state code of `data/core/buffer/init.lua`. It can be tested without a network: two Buffers in one process, joined by a fake server in memory.

## Risks to keep in mind

- **Two Project processes.** Each loaded Project has its own process, and Buffer reuse works only inside one process. Two Projects can open the same note and both write it. The reload engine lets them converge through the disk, but each one sees the other's saves as external changes.
- **Autosave timing.** Autosave saves 3 seconds after typing stops, at the latest after 30 seconds, and when focus moves. An external writer can still save between Anvil's read and write.
- **Line endings and encodings.** Loading converts text to UTF-8 with LF lines, and saving converts it back. Compare texts in Buffer form only.
- **Rename and delete.** An external delete marks the Buffer's file missing. Anvil cannot tell a rename from a delete.

## Order of work

1. **Reload engine, clean Buffers.** Reload as small edits with no jump, one undo step, and the Buffer stays clean. Done. Not checked: Standard Editors with line wrapping turned on.
2. **Safety for the shipped reload.** Make undo across a reload visible. Warn when a sync conflict copy of an open file appears.
3. **Reload engine, dirty Buffers.** Keep the base as described above. A three-way merge with words compared inside lines. Until step 4 exists, true conflicts keep today's prompt. Add Disk Conflict to `CONTEXT.md`.
4. **Disk Conflict blocks.** The inline block, the choices, the status, POI navigation, and the close question.
5. **Sync conflict copies** (level 1): merge a conflict copy into its Buffer and show overlaps as Disk Conflict blocks.
6. **Live editing inside Anvil, with no network:** selective undo, remote cursors, an edit feed into and out of the Buffer, and a fake server in tests.
7. **The edit server** (level 2).

Before step 6, answer these questions:

- How many people type in the same note at the same time?
- Are they on one office network or on the internet?
- Can the company host one small service beside Nextcloud?
- Who writes the file during a live session?
