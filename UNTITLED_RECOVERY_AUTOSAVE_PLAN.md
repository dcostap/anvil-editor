# Untitled Recovery and Autosave Revamp Plan

## Purpose

Make Anvil's untitled Document preservation as robust as a first-class editor feature: users can create many untitled Documents, edit them freely, and trust that their contents are conserved quickly and recoverably without polluting Project files.

This plan uses Notepad++'s session snapshot / backup system as the strongest reference implementation. In Anvil terminology, the feature preserves untitled Documents shown by Editors / Document Views and recorded in Workspace state. Notepad++ terms such as "session" and "buffer" are used only when describing the reference implementation.

The proposed Anvil model intentionally follows the reference implementation's core design:

- untitled Documents remain semantically untitled in the editor UI/API;
- each dirty untitled Document has a managed backing file under the user data directory;
- Workspace and recovery metadata reference the managed backing file;
- backing file writes use native atomic replacement where available, and otherwise use a temp-plus-backup crash-safe discipline;
- explicit close/save operations clean up or quarantine the backing file only after the user action succeeds.

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
- Project/window switch;
- Document View / Editor close;
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
C:\Projects\c_projects\anvil-editor\data\core\doc\init.lua
C:\Projects\c_projects\anvil-editor\data\core\storage.lua
C:\Projects\c_projects\anvil-editor\data\plugins\anvil_defaults.lua
```

### Current persistence paths

- `DocView:get_state()` stores `text = self.doc.new_file and self.doc:get_text(...)` inline in Workspace state.
- `untitled_tabs.lua` adds `intellij_untitled`, `intellij_untitled_name`, and `intellij_untitled_id` to the saved Document View state.
- `workspace.lua` stores per-Project Workspace state through `core.storage` module `"ws"`.
- `workspace.lua` consumes/deletes restored Workspace storage before a later save recreates it, so recovery cannot depend on Workspace state alone.
- `storage.lua` writes data under:

```text
USERDIR\storage\<module>\<key>
```

For the dev portable app, `USERDIR` is:

```text
C:\Projects\c_projects\anvil-portable\user
```

So Workspace files live under:

```text
C:\Projects\c_projects\anvil-portable\user\storage\ws\
```

### Current autosave/recovery behavior

`autosave_fast.lua` already has untitled recovery logic:

- `RECOVERY_MODULE = "untitled_recovery"`
- it stores per-Project recovery data through `core.storage`;
- it serializes each untitled Document's full text inline;
- it restores those Documents after Workspace restoration;
- default autosave timeout is defined in `anvil_defaults.lua`:

```lua
plugin_defaults("autosave_fast", {
  enabled = true,
  timeout = 3,
  hide_dirty_markers = true,
})
```

This is useful but not robust enough for the desired target because:

- untitled contents are embedded in storage blobs rather than per-Document files;
- large untitled Documents can bloat Workspace/recovery state;
- recovery granularity is per-Project blob, not per Document;
- corruption of a single blob risks more state;
- crash recovery depends on debounce timing;
- there is no explicit per-untitled backing lifecycle comparable to Notepad++;
- current `Doc:save()` hardening is designed for named files and still writes/truncates the target path, so untitled backing files need their own temp/replace discipline.

## Proposed Anvil architecture

### Core principle

Untitled Documents should have an internal managed backing file, but the editor-facing Document should remain untitled/pathless.

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

Recovery snapshot state and user dirty state are separate concepts:

- `doc:is_dirty()` continues to mean "the user has not saved this Document to a chosen file path";
- a successful backing-file snapshot must not call `doc:clean()`;
- `doc.intellij_untitled_backing_dirty == false` only means "the recovery copy is current";
- restored untitled Documents should still appear dirty/unsaved until the user explicitly saves or discards them.

### Ownership and module boundaries

Implement untitled recovery as a dedicated first-party service/plugin rather than burying the backing-file lifecycle inside named-file autosave.

Suggested module split:

```text
data/plugins/untitled_recovery.lua       -- managed backing files for untitled Documents
data/plugins/autosave_fast.lua           -- real-file autosave policy for named Documents
data/plugins/untitled_tabs.lua           -- UI names, creation command, Workspace tagging for untitled Documents
```

`untitled_recovery.lua` should expose a small internal API used by the other first-party plugins:

```lua
ensure_doc_backing(doc)
mark_dirty(doc)
flush_doc(doc, reason)
flush_all(reason)
attach_from_workspace_state(doc, state)
state_for_doc(doc)
handle_save_as_success(doc, old_backing_metadata)
handle_confirmed_discard(doc)
```

The service owns IDs, paths, manifest IO, backing writes, orphan recovery, cleanup/quarantine, and migration from old inline Workspace/recovery data. `autosave_fast.lua` should not serialize untitled contents once the service is enabled.

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

Use a stable project key/hash because Projects can share the same basename. The manifest should still store the full Root Project path for verification/debugging.

The manifest is independent recovery state, not merely a cache of Workspace state. This matters because `workspace.lua` consumes/deletes Workspace state during restore before saving it again later. Recovery must still work if Workspace state is missing, stale, corrupt, or already consumed.

### Manifest schema

Example:

```lua
return {
  version = 1,
  project_key = "stable-project-key-hash",
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
      last_snapshot_change_id = 42,
      explicit_closed = false,
    },
  },
}
```

Keep the manifest metadata-only. Do not store full Document text in the manifest except possibly a tiny emergency preview/checksum for diagnostics and orphan triage.

### Backing file contents

Store raw Document text as Anvil would save it, preserving line endings. Start simple:

- UTF-8 text bytes;
- respect `doc.crlf` when serializing;
- no sidecar text wrapping;
- optional future encoding metadata in manifest.

### Write guarantees

For untitled Documents, use Notepad++'s atomic-write discipline and make the platform guarantees explicit.

Preferred implementation:

1. Serialize text from the current in-memory Document.
2. Write to `<id>.tmp` in the same directory as `<id>.txt`.
3. Flush and close the temp file.
4. Replace `<id>.txt` through a native helper where available, e.g. a Windows `ReplaceFile`/`MoveFileEx`-backed `system.replace_file_atomic(tmp, target, backup)`.
5. If a native helper is not yet available, use a crash-safe best-effort sequence: preserve the old target as `<id>.txt.bak`, move temp into place, and restore the backup on detected failure.
6. Only after successful replacement mark `doc.intellij_untitled_backing_dirty = false` and record the backing save time/revision.
7. Update the manifest after backing file success.

Important: never truncate/overwrite the only good backing file directly.

Startup recovery must understand the write protocol and reconcile partial states:

- valid primary `<id>.txt` wins over stale temp files;
- if primary is missing/corrupt but `<id>.txt.bak` exists, offer/restore the backup;
- if only `<id>.tmp` exists, treat it as an orphan candidate rather than deleting it silently;
- quiet-log all reconciliation decisions.

### Save timing policy

Desired user-facing guarantee: edits are conserved quickly and reliably.

Proposed policy:

- On every text-change transaction in an untitled Document:
  - assign a backing ID/path if missing;
  - mark backing dirty immediately;
  - record the Document change id/revision that needs a snapshot;
  - enqueue a coalesced snapshot.
- For small Documents, schedule a short coalesced flush, e.g. 250 ms.
- If another edit arrives before the flush, coalesce but keep pending state.
- Skip redundant writes when the Document change id/revision already matches the last successful backing snapshot.
- For large Documents, use a larger coalescing delay/backpressure policy so synchronous Lua file IO does not repeatedly stall the UI. Keep lifecycle force-flushes strict.
- Force flush immediately before or during:
  - confirmed Editor/Document View close or discard prompt handling;
  - Save As;
  - app exit, including forced exit paths;
  - `core.set_project` and same-window Project switch/restart flows;
  - Document View / active Editor switch if the previous untitled Document has pending backing changes;
  - explicit Workspace save.

This is stricter than Notepad++'s default 7-second snapshot interval while borrowing its snapshot/backing model.

### Manifest write hardening

Follow Notepad++ `NppParameters::writeSession()` in spirit:

- write manifest to temp;
- load/parse the just-written manifest to verify it;
- keep `manifest.lua.bak` before replacing;
- restore backup if validation fails;
- quiet-log all failures.

Anvil's `core.storage.save()` already has temp/backup behavior, but this feature should use a dedicated recovery-manifest writer under `USERDIR\recovery\untitled` with explicit validation, backup retention, and restore-on-failure behavior. Keep the writer small and testable; do not make recovery correctness depend on the generic storage module's replacement semantics.

### Startup recovery

On Project / Workspace load:

1. Load untitled recovery manifest for the Root Project.
2. Reconcile primary/temp/backup backing files according to the write protocol.
3. Load Workspace as today, if available.
4. For each manifest Document:
   - if a matching untitled Document already exists from Workspace state, attach backing metadata and prefer backing-file text when it is newer/current;
   - otherwise read the backing file and open an untitled Editor/Document View.
5. Scan the `docs` directory for orphaned backing files not listed in the manifest.
6. Offer/recover orphaned files as untitled Documents instead of silently deleting them.
7. Rewrite the manifest after successful restore/orphan adoption so repeated launches do not duplicate recovered Documents.
8. Quiet-log restored Documents, missing backing files, orphan files, corrupt manifest recovery, and temp/backup reconciliation.

This recovery path must work even when Workspace state has been consumed/deleted, because `workspace.lua` removes restored Workspace storage before a later exit/project-switch save recreates it.

### Workspace integration

`DocView:get_state()` should stop embedding large untitled text inline once backing files are in use.

For backed untitled Documents, Workspace state should store metadata:

```lua
state.intellij_untitled = true
state.intellij_untitled_name = doc.intellij_untitled_name
state.intellij_untitled_id = doc.intellij_untitled_id
state.intellij_untitled_backing = relative_backing_path_or_id
state.text = nil -- old inline-text compatibility only
```

During migration, keep support for old `state.text` so existing Workspace files recover correctly. Once a backing file has been successfully written for a Document, future Workspace saves should omit full inline text. A very small preview/checksum may live in recovery metadata if useful for diagnostics, but not as the primary copy.

### Save As / explicit close lifecycle

On successful Save As for an untitled Document:

1. Capture the old untitled/backing metadata before calling `Doc:save`, because existing wrappers may clear `intellij_untitled*` fields after the save succeeds.
2. Save the actual file using normal `Doc:save`.
3. Only after successful save, clear remaining `intellij_untitled*` fields as today.
4. Delete or quarantine the backing file.
5. Remove the manifest entry.
6. Save the manifest.

On explicit close of a dirty untitled Document:

1. Prompt user as today.
2. Only when this is the last Document View referencing the Document and the user confirms discard:
   - close the Document View/Editor;
   - remove the manifest entry;
   - delete or move the backing file to a short-lived trash/quarantine.
3. If the close is canceled or fails, keep the backing file and manifest entry intact.

Initial cleanup policy: move discarded backing files to:

```text
USERDIR\recovery\untitled\trash\<timestamp>\...
```

then prune by age. This protects against accidental data loss during early rollout.

### Named-file autosave revamp

Separate two concepts currently mixed in `autosave_fast.lua`:

1. **Recovery snapshots**
   - internal copies to prevent data loss;
   - applies strongly to untitled Documents;
   - can later also protect dirty named Documents without writing to their real path.

2. **Autosave to real file**
   - writes dirty named Documents to their actual filesystem path;
   - must keep conflict detection and protected-file rules.

Required refactor:

```text
data/plugins/untitled_recovery.lua       -- managed backing files for untitled Documents
data/plugins/autosave_fast.lua           -- real-file autosave policy for named Documents
data/plugins/untitled_tabs.lua           -- UI/name/Workspace tagging for untitled Documents
```

Keep wrapper ordering simple: `untitled_recovery.lua` owns untitled persistence; `autosave_fast.lua` should delegate untitled handling to it or ignore untitled Documents entirely.

### Logging / diagnostics

Per repository guidelines, use `core.log_quiet(...)` liberally for:

- backing file allocation;
- snapshot queued/flushed/skipped;
- atomic replace failures;
- manifest writes/validation;
- startup restore counts;
- orphan recovery;
- cleanup/delete/quarantine actions;
- migration from inline Workspace text;
- large-Document backpressure / delayed-flush decisions;
- Workspace-consumed-but-manifest-restored recovery paths.

Visible `core.warn/error` only when the user needs to act, e.g. backing file cannot be written and data is at risk.

## Migration plan

1. Add the dedicated recovery backing implementation behind a temporary config flag only if rollout safety needs it. The target state is mandatory first-party behavior.
2. On startup, when an old inline untitled Document is restored from Workspace state or `untitled_recovery` storage:
   - allocate id/backing file;
   - write current text through the new safe replace path;
   - record manifest entry;
   - mark the backing snapshot current without cleaning the user-visible dirty state.
3. After successful backing migration, future Workspace saves omit inline text.
4. Keep old inline restore compatibility indefinitely or until explicitly cleaned later.
5. Do not delete old recovery storage until new backing files and manifest entries are confirmed written and recoverable.

## Test plan

Use Anvil Lua tests through Meson where possible.

Relevant commands:

```sh
meson test -C build-windows-x86_64 anvil:lua-runtime --print-errorlogs
meson test -C build-windows-x86_64 anvil:lua-ui --print-errorlogs
```

Targeted tests to add:

### Runtime/helper tests

- project key/hash is stable and distinct for same-basename Projects;
- backing path generation is unique and under USERDIR;
- text serialization preserves LF/CRLF;
- native/best-effort safe replace keeps the old file if temp write/replacement fails;
- startup reconciliation handles primary + temp, missing primary + backup, and temp-only cases;
- manifest write validates and restores backup on corrupt write simulation;
- orphan scan finds unmanifested backing files;
- snapshot generation tracking skips redundant writes for unchanged Documents.

### UI/runtime integration tests

- creating an untitled Editor allocates id/backing metadata;
- editing an untitled Document writes/replaces backing file;
- backing snapshot success does not make the untitled Document clean;
- restart/Workspace restore recovers untitled content from backing file;
- consumed/deleted Workspace state plus valid manifest still restores untitled content;
- deleting Workspace state but leaving backing file still recovers orphan;
- same-window Project switch flushes recovery even when Workspace save is suppressed;
- Save As removes manifest entry/backing file after successful real-file save;
- failed Save As leaves manifest/backing intact;
- explicit close removes or quarantines backing file only after confirmation and only for the last Document View;
- multiple untitled Documents with same visible title do not collide;
- old inline `state.text` Workspace data migrates to backing files.

### Regression scenarios

- kill/restart after edit before normal Workspace save;
- kill/restart after Workspace storage is consumed but before it is recreated;
- corrupt manifest but valid `manifest.lua.bak`;
- missing manifest but valid `docs/<id>.txt`;
- missing backing file referenced by manifest;
- stale temp file beside valid primary backing file;
- missing/corrupt primary with valid `.bak`;
- very large untitled Document does not bloat Workspace storage.

## Implementation phases

### Phase 1: Extract and harden untitled recovery service

- Introduce `data/plugins/untitled_recovery.lua` with helper/service functions for ids, paths, manifests, safe replacement, and restore reconciliation.
- Decide whether a native `system.replace_file_atomic(...)` helper is needed immediately; if not, implement and test the Lua best-effort fallback with explicit backup recovery.
- Keep public Document identity pathless.
- Add quiet logs.
- Add tests for pure helpers.

### Phase 2: Back untitled Documents with managed files

- Allocate backing path on untitled creation/first edit.
- Snapshot after edits with short debounce and large-Document backpressure.
- Force flush on close/save/exit/Project switch/Document View switch.
- Keep old inline Workspace text as fallback during this phase.

### Phase 3: Workspace manifest integration

- Store backing metadata instead of full text in Workspace state.
- Restore from backing files even when Workspace state is absent or already consumed.
- Recover orphans and rewrite the manifest after adoption.
- Migrate old inline states.

### Phase 4: Cleanup and policy polish

- Delete/quarantine backing files after Save As or confirmed discard.
- Add pruning for old trash/orphans.
- Add user-facing recovery warning only when needed.
- Consider exposing a recovery manager UI later.

### Phase 5: Named-Document autosave cleanup

- Separate recovery snapshots from real-file autosave policy.
- Preserve existing conflict detection for named Documents.
- Add tests for named autosave behavior after refactor.

## Open questions

- Should snapshots happen synchronously for tiny Documents, or always through a short debounce?
- Should the first implementation add a native `system.replace_file_atomic(...)` helper, or start with the tested Lua best-effort fallback?
- Should explicitly discarded untitled backups be deleted immediately or quarantined for N days?
- Should orphaned backing files auto-open silently, or appear in a recovery prompt?
- Should managed backing files include a `.txt` extension, language-derived extension, or opaque extension?
- Should first-line title naming/renaming update the backing filename, or should backing filename remain id-based forever?

Recommended defaults:

- short debounce for small Documents, larger coalescing delay/backpressure for large Documents, and force flush on lifecycle boundaries;
- add the native atomic-replace helper if implementation cost is modest; otherwise start with tested temp/backup fallback and make startup reconciliation robust;
- quarantine explicit discards initially;
- auto-open obvious Project-owned orphans with quiet logs, prompt only for ambiguous/corrupt cases;
- use opaque id-based filenames to avoid rename/collision issues;
- never rename backing files for title changes.
