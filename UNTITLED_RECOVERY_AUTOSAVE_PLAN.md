# Untitled Recovery and Autosave Revamp Plan

## Purpose

Make Anvil's untitled-document preservation as robust as a first-class editor feature: users can create many untitled documents, edit them freely, and trust that their contents are conserved quickly and recoverably without polluting the project tree.

This plan uses Notepad++'s session snapshot / backup system as the strongest reference implementation. The proposed Anvil model intentionally follows its core design:

- untitled tabs remain semantically untitled in the editor UI/API;
- each dirty untitled document has a managed backing file under the user data directory;
- session/workspace metadata references the managed backing file;
- backing file writes are atomic and treated as the only physical copy of an untitled document;
- explicit close/save operations clean up the backing file.

## Notepad++ reference source

Repository cache inspected at:

```text
C:\Users\Darius\AppData\Local\pi-web-smart-fetch\github-cache\notepad-plus-plus\notepad-plus-plus
```

Key files:

```text
C:\Users\Darius\AppData\Local\pi-web-smart-fetch\github-cache\notepad-plus-plus\notepad-plus-plus\PowerEditor\src\ScintillaComponent\Buffer.cpp
C:\Users\Darius\AppData\Local\pi-web-smart-fetch\github-cache\notepad-plus-plus\notepad-plus-plus\PowerEditor\src\ScintillaComponent\Buffer.h
C:\Users\Darius\AppData\Local\pi-web-smart-fetch\github-cache\notepad-plus-plus\notepad-plus-plus\PowerEditor\src\Notepad_plus.cpp
C:\Users\Darius\AppData\Local\pi-web-smart-fetch\github-cache\notepad-plus-plus\notepad-plus-plus\PowerEditor\src\NppIO.cpp
C:\Users\Darius\AppData\Local\pi-web-smart-fetch\github-cache\notepad-plus-plus\notepad-plus-plus\PowerEditor\src\NppBigSwitch.cpp
C:\Users\Darius\AppData\Local\pi-web-smart-fetch\github-cache\notepad-plus-plus\notepad-plus-plus\PowerEditor\src\NppNotification.cpp
C:\Users\Darius\AppData\Local\pi-web-smart-fetch\github-cache\notepad-plus-plus\notepad-plus-plus\PowerEditor\src\Parameters.cpp
C:\Users\Darius\AppData\Local\pi-web-smart-fetch\github-cache\notepad-plus-plus\notepad-plus-plus\PowerEditor\src\Parameters.h
C:\Users\Darius\AppData\Local\pi-web-smart-fetch\github-cache\notepad-plus-plus\notepad-plus-plus\PowerEditor\src\WinControls\Preference\preferenceDlg.cpp
```

### Notepad++ behavior to copy conceptually

#### Per-untitled managed backing file

In `Buffer.cpp`, the Notepad++ source comments describe the model for untitled docs such as `new 4`:

```text
C:\Users\Darius\AppData\Local\pi-web-smart-fetch\github-cache\notepad-plus-plus\notepad-plus-plus\PowerEditor\src\ScintillaComponent\Buffer.cpp
```

The comment says that when an untitled document is modified, a backup file is created with a name like:

```text
backup\new 4@198776
```

The buffer tracks that path and session state later stores it. On restart, Notepad++ opens the backup file content while restoring the tab label as `new 4` and marking the document dirty.

#### Backing file creation and association

`FileManager::backupCurrentBuffer()` creates the backing path if the buffer does not already have one:

```text
C:\Users\Darius\AppData\Local\pi-web-smart-fetch\github-cache\notepad-plus-plus\notepad-plus-plus\PowerEditor\src\ScintillaComponent\Buffer.cpp
```

Important details from that function:

- it uses `NppParameters::getInstance().getUserPath() + "\\backup\\"`;
- it creates the directory if missing;
- it appends the visible untitled name and a timestamp;
- it records the path on the buffer with `buffer->setBackupFileName(backupFilePath)`.

#### Atomic write for untitled content

In `FileManager::backupCurrentBuffer()`, Notepad++ writes untitled content to a temporary file first:

```cpp
std::wstring fullpathTemp = fullpath;
fullpathTemp += L".tmp";
UnicodeConvertor.openFile(buffer->isUntitled() ? fullpathTemp.c_str() : fullpath)
```

After successful write, it replaces/moves the temp file into place:

```cpp
if (buffer->isUntitled())
{
    if (doesFileExist(fullpath))
        ::ReplaceFile(fullpath, fullpathTemp.c_str(), nullptr, ...);
    else
        ::MoveFileEx(fullpathTemp.c_str(), fullpath, MOVEFILE_REPLACE_EXISTING);
}
```

The comment says this is because an untitled document has no original physical file; the backup is its only physical existence. This is one of the most important details to copy.

#### Modified flag and periodic snapshot loop

`NppNotification.cpp` marks the current buffer as modified after text changes / undo / redo:

```text
C:\Users\Darius\AppData\Local\pi-web-smart-fetch\github-cache\notepad-plus-plus\notepad-plus-plus\PowerEditor\src\NppNotification.cpp
```

`Notepad_plus.cpp` launches a backup thread:

```text
C:\Users\Darius\AppData\Local\pi-web-smart-fetch\github-cache\notepad-plus-plus\notepad-plus-plus\PowerEditor\src\Notepad_plus.cpp
```

`Notepad_plus::backupDocument()` sleeps for `_snapshotBackupTiming` and sends `NPPM_INTERNAL_SAVEBACKUP`. Defaults are in:

```text
C:\Users\Darius\AppData\Local\pi-web-smart-fetch\github-cache\notepad-plus-plus\notepad-plus-plus\PowerEditor\src\Parameters.h
```

Relevant defaults:

```cpp
bool _isSnapshotMode = true;
size_t _snapshotBackupTiming = 7000;
```

Anvil should be stricter than Notepad++ for the desired UX: use immediate/short-delay snapshots after edit rather than a 7-second default, while still coalescing bursts of edits safely.

#### Force snapshot on tab/view switch and exit

`NppNotification.cpp` calls `MainFileManager.backupCurrentBuffer()` before switching edit views when snapshot mode is active.

`NppBigSwitch.cpp` calls `MainFileManager.backupCurrentBuffer()` during shutdown before saving the session:

```text
C:\Users\Darius\AppData\Local\pi-web-smart-fetch\github-cache\notepad-plus-plus\notepad-plus-plus\PowerEditor\src\NppBigSwitch.cpp
```

Anvil should similarly force-flush pending untitled snapshots on:

- app exit;
- project/window switch;
- tab close;
- Save As;
- active-view switch if a snapshot is pending;
- any other destructive close path.

#### Session metadata references backing files

Notepad++ writes `backupFilePath` into session XML in:

```text
C:\Users\Darius\AppData\Local\pi-web-smart-fetch\github-cache\notepad-plus-plus\notepad-plus-plus\PowerEditor\src\Parameters.cpp
```

`NppParameters::writeSession()` writes attributes including:

```xml
filename="new 4"
backupFilePath="...\\backup\\new 4@timestamp"
originalFileLastModifTimestamp="..."
```

The session metadata contains view state and the backup file path; the document text lives in the backup file.

#### Session file write hardening

Also in `NppParameters::writeSession()`:

- remove read-only flag from session file;
- copy existing session file to a backup path;
- write new XML;
- load/parse the written XML to validate it;
- restore backup if validation fails;
- keep the backup around in some failure cases.

This is a strong reference for hardening Anvil's workspace/recovery manifest writes.

#### Load snapshot-backed untitled docs

`NppIO.cpp` and `Buffer.cpp` handle snapshot load:

```text
C:\Users\Darius\AppData\Local\pi-web-smart-fetch\github-cache\notepad-plus-plus\notepad-plus-plus\PowerEditor\src\NppIO.cpp
C:\Users\Darius\AppData\Local\pi-web-smart-fetch\github-cache\notepad-plus-plus\notepad-plus-plus\PowerEditor\src\ScintillaComponent\Buffer.cpp
```

If a normal file path does not exist but `backupFilePath` exists, Notepad++ loads from the backup file and treats the buffer as untitled/dirty.

#### Cleanup on save/close

`FileManager::saveBuffer()` deletes `buffer->getBackupFileName()` after a successful save.

`FileManager::deleteBufferBackup()` deletes backup files when closing/discarding.

These are in:

```text
C:\Users\Darius\AppData\Local\pi-web-smart-fetch\github-cache\notepad-plus-plus\notepad-plus-plus\PowerEditor\src\ScintillaComponent\Buffer.cpp
```

## Current Anvil behavior

Relevant Anvil files:

```text
C:\Projects\c_projects\anvil-editor\data\plugins\untitled_tabs.lua
C:\Projects\c_projects\anvil-editor\data\plugins\autosave_fast.lua
C:\Projects\c_projects\anvil-editor\data\plugins\workspace.lua
C:\Projects\c_projects\anvil-editor\data\core\docview.lua
C:\Projects\c_projects\anvil-editor\data\core\storage.lua
C:\Projects\c_projects\anvil-editor\data\plugins\anvil_defaults.lua
```

### Current persistence paths

- `DocView:get_state()` stores `text = self.doc.new_file and self.doc:get_text(...)` inline in workspace state.
- `untitled_tabs.lua` adds `intellij_untitled`, `intellij_untitled_name`, and `intellij_untitled_id` to the saved view state.
- `workspace.lua` stores project workspace state through `core.storage` module `"ws"`.
- `storage.lua` writes data under:

```text
USERDIR\storage\<module>\<key>
```

For the dev portable app, `USERDIR` is:

```text
C:\Projects\c_projects\anvil-portable\user
```

So workspace files live under:

```text
C:\Projects\c_projects\anvil-portable\user\storage\ws\
```

### Current autosave/recovery behavior

`autosave_fast.lua` already has untitled recovery logic:

- `RECOVERY_MODULE = "untitled_recovery"`
- it stores per-project recovery data through `core.storage`;
- it serializes each untitled document's full text inline;
- it restores those docs after workspace restoration;
- default autosave timeout is defined in `anvil_defaults.lua`:

```lua
plugin_defaults("autosave_fast", {
  enabled = true,
  timeout = 3,
  hide_dirty_markers = true,
})
```

This is useful but not robust enough for the desired target because:

- untitled contents are embedded in storage blobs rather than per-doc files;
- large untitled docs can bloat workspace/recovery state;
- recovery granularity is per-project blob, not per document;
- corruption of a single blob risks more state;
- crash recovery depends on debounce timing;
- there is no explicit per-untitled backing lifecycle comparable to Notepad++.

## Proposed Anvil architecture

### Core principle

Untitled documents should have an internal managed backing file, but the editor-facing document should remain untitled/pathless.

Keep true for user-facing/API-facing identity:

```lua
doc.filename == nil
doc.abs_filename == nil
doc.new_file == true
doc.intellij_untitled == true
```

Add internal recovery fields:

```lua
doc.intellij_untitled_id              -- durable id
doc.intellij_untitled_name            -- visible Untitled-N label
doc.intellij_untitled_backing_path    -- internal USERDIR backing file
doc.intellij_untitled_backing_dirty   -- snapshot pending
doc.intellij_untitled_backing_saved_at
```

The backing path must never be treated as `doc.filename` or `doc.abs_filename`.

### Storage layout

Suggested layout:

```text
USERDIR\recovery\untitled\
  projects\
    <project-key-hash>\
      manifest.lua
      manifest.lua.bak
      docs\
        <doc-id>.txt
        <doc-id>.txt.bak
        <doc-id>.tmp
```

For the dev portable install this expands to:

```text
C:\Projects\c_projects\anvil-portable\user\recovery\untitled\projects\<project-key-hash>\...
```

Use a project key/hash because projects can share the same basename. The manifest should still store the full project path for verification/debugging.

### Manifest schema

Example:

```lua
return {
  version = 1,
  project = "C:\\Projects\\c_projects\\anvil-editor",
  saved_at = 1782012345,
  docs = {
    {
      id = "pid-time-counter-random",
      name = "Untitled-1",
      backing = "docs/pid-time-counter-random.txt",
      crlf = false,
      encoding = nil,
      language = nil,
      created_at = 1782010000,
      updated_at = 1782012345,
      explicit_closed = false,
    },
  },
}
```

Keep the manifest metadata-only. Do not store full document text in the manifest except possibly a tiny emergency preview/checksum.

### Backing file contents

Store raw document text as Anvil would save it, preserving line endings. Start simple:

- UTF-8 text bytes;
- respect `doc.crlf` when serializing;
- no sidecar text wrapping;
- optional future encoding metadata in manifest.

### Write guarantees

For untitled docs, use Notepad++'s atomic-write discipline:

1. Serialize text from the current in-memory doc.
2. Write to `<id>.tmp`.
3. Flush and close.
4. Replace `<id>.txt` atomically where possible.
5. Keep `<id>.txt.bak` or use storage-style backup if replace fails.
6. Only after successful replace mark `doc.intellij_untitled_backing_dirty = false`.
7. Update manifest after backing file success.

Important: never truncate/overwrite the only good backing file directly.

### Save timing policy

Desired user-facing guarantee: edits are conserved quickly and reliably.

Proposed policy:

- On every text-change transaction in an untitled doc:
  - mark backing dirty;
  - enqueue snapshot;
  - schedule a short coalesced flush, e.g. 250 ms.
- If another edit arrives before the flush, coalesce but keep pending state.
- Force flush immediately on:
  - tab close/discard prompt;
  - Save As;
  - app exit;
  - project switch;
  - active view/tab switch if current untitled doc has pending backing changes;
  - explicit workspace save.
- For very large untitled documents, allow a larger coalescing delay but show/log pending state.

This is stricter than Notepad++'s default 7-second snapshot interval while borrowing its snapshot/backing model.

### Manifest write hardening

Follow Notepad++ `NppParameters::writeSession()` in spirit:

- write manifest to temp;
- load/parse the just-written manifest to verify it;
- keep `manifest.lua.bak` before replacing;
- restore backup if validation fails;
- quiet-log all failures.

Anvil's `core.storage.save()` already has temp/backup behavior. The new system may either:

- use `core.storage` for manifest after improving validation; or
- use a dedicated recovery-manifest writer under `USERDIR\recovery\untitled`.

Given this feature's importance, prefer a dedicated writer with explicit validation and backup retention.

### Startup recovery

On project/workspace load:

1. Load workspace as today.
2. Load untitled recovery manifest for the project.
3. For each manifest doc:
   - if matching untitled doc already exists from workspace state, attach backing metadata;
   - otherwise read backing file and restore an untitled tab.
4. Scan the `docs` directory for orphaned backing files not listed in manifest.
5. Offer/recover orphaned files as untitled docs instead of silently deleting them.
6. Quiet-log restored docs, missing backing files, orphan files, and corrupt manifest recovery.

This is intentionally more robust than relying only on workspace state.

### Workspace integration

`DocView:get_state()` should stop embedding large untitled text inline once backing files are in use.

For backed untitled docs, workspace state should store metadata:

```lua
state.intellij_untitled = true
state.intellij_untitled_name = doc.intellij_untitled_name
state.intellij_untitled_id = doc.intellij_untitled_id
state.intellij_untitled_backing = relative_backing_path_or_id
state.text = nil -- or only tiny migration fallback
```

During migration, keep support for old `state.text` so existing workspaces recover correctly.

### Save As / explicit close lifecycle

On successful Save As for an untitled doc:

1. Save actual file using normal `Doc:save`.
2. Clear `intellij_untitled*` fields as today.
3. Delete or quarantine backing file.
4. Remove manifest entry.
5. Save manifest.

On explicit close of dirty untitled doc:

1. Prompt user as today.
2. If confirmed discard:
   - remove manifest entry;
   - delete or move backing file to a short-lived trash/quarantine;
   - close doc.

Consider a conservative initial policy: move discarded backing files to:

```text
USERDIR\recovery\untitled\trash\<timestamp>\...
```

then prune by age. This protects against accidental data loss during early rollout.

### Named-file autosave revamp

Separate two concepts currently mixed in `autosave_fast.lua`:

1. **Recovery snapshots**
   - internal copies to prevent data loss;
   - applies strongly to untitled docs;
   - can later also protect dirty named docs without writing to their real path.

2. **Autosave to real file**
   - writes dirty named documents to their actual filesystem path;
   - must keep conflict detection and protected-file rules.

Suggested refactor:

```text
data/plugins/untitled_recovery.lua       -- managed backing files for untitled docs
data/plugins/autosave_fast.lua           -- real-file autosave policy for named docs
data/plugins/untitled_tabs.lua           -- UI/name/session tagging for untitled docs
```

Or keep one plugin initially but internally split modules/functions clearly.

### Logging / diagnostics

Per repository guidelines, use `core.log_quiet(...)` liberally for:

- backing file allocation;
- snapshot queued/flushed/skipped;
- atomic replace failures;
- manifest writes/validation;
- startup restore counts;
- orphan recovery;
- cleanup/delete/quarantine actions;
- migration from inline workspace text.

Visible `core.warn/error` only when the user needs to act, e.g. backing file cannot be written and data is at risk.

## Migration plan

1. Add new recovery backing implementation disabled behind a config flag if desired.
2. On startup, when an old inline untitled doc is restored from workspace or `untitled_recovery` storage:
   - allocate id/backing file;
   - write current text atomically;
   - record manifest entry.
3. After successful backing migration, future workspace saves omit inline text.
4. Keep old inline restore compatibility indefinitely or until explicitly cleaned later.
5. Do not delete old recovery storage until new backing files are confirmed written.

## Test plan

Use Anvil Lua tests through Meson where possible.

Relevant commands:

```sh
meson test -C build-windows-x86_64 anvil:lua-runtime --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-ui --print-errorlogs
```

Targeted tests to add:

### Runtime/helper tests

- project key/hash is stable and distinct for same-basename projects;
- backing path generation is unique and under USERDIR;
- text serialization preserves LF/CRLF;
- atomic write keeps old file if temp write fails;
- manifest write validates and restores backup on corrupt write simulation;
- orphan scan finds unmanifested backing files.

### UI/runtime integration tests

- creating an untitled tab allocates id/backing metadata;
- editing untitled doc writes/replaces backing file;
- restart/workspace restore recovers untitled content from backing file;
- deleting workspace state but leaving backing file still recovers orphan;
- Save As removes manifest entry/backing file;
- explicit close removes or quarantines backing file only after confirmation;
- multiple untitled docs with same visible title do not collide;
- old inline `state.text` workspace data migrates to backing files.

### Regression scenarios

- kill/restart after edit before normal workspace save;
- corrupt manifest but valid `manifest.lua.bak`;
- missing manifest but valid `docs/<id>.txt`;
- missing backing file referenced by manifest;
- very large untitled doc does not bloat workspace storage.

## Implementation phases

### Phase 1: Extract and harden untitled recovery service

- Introduce helper/service functions for ids, paths, manifests, and atomic writes.
- Keep public doc identity pathless.
- Add quiet logs.
- Add tests for pure helpers.

### Phase 2: Back untitled docs with managed files

- Allocate backing path on untitled creation/first edit.
- Snapshot after edits with short debounce.
- Force flush on close/save/exit/switch.
- Keep old inline workspace text as fallback during this phase.

### Phase 3: Workspace manifest integration

- Store backing metadata instead of full text in workspace state.
- Restore from backing files.
- Recover orphans.
- Migrate old inline states.

### Phase 4: Cleanup and policy polish

- Delete/quarantine backing files after Save As or confirmed discard.
- Add pruning for old trash/orphans.
- Add user-facing recovery warning only when needed.
- Consider exposing a recovery manager UI later.

### Phase 5: Named-doc autosave cleanup

- Separate recovery snapshots from real-file autosave policy.
- Preserve existing conflict detection for named docs.
- Add tests for named autosave behavior after refactor.

## Open questions

- Should snapshots happen on every edit synchronously for tiny docs, or always through a short debounce?
- Should explicitly discarded untitled backups be deleted immediately or quarantined for N days?
- Should orphaned backing files auto-open silently, or appear in a recovery prompt?
- Should managed backing files include a `.txt` extension, language-derived extension, or opaque extension?
- Should first-line tab naming/renaming update the backing filename, or should backing filename remain id-based forever?

Recommended defaults:

- short debounce, force flush on lifecycle boundaries;
- quarantine explicit discards initially;
- auto-open obvious project-owned orphans with quiet logs, prompt only for ambiguous/corrupt cases;
- use opaque id-based filenames to avoid rename/collision issues;
- never rename backing files for tab-title changes.
