# Native File Tree Git Status and Markdown Vault Index Plan

## Goal

Eliminate the startup and recurring UI stalls caused by Project-scale Git status processing and Markdown vault indexing.

The durable architecture is:

- Lua remains the control plane for visibility, requests, generations, cancellation intent, publication, and UI behavior.
- Repository-scale and Project-scale data processing runs in native C jobs on Anvil's existing `core.worker_pool` native threads.
- Native jobs return immutable, reference-counted snapshot handles rather than large Lua tables.
- The UI Lua state performs only bounded worker-pool draining, generation checks, handle swaps, open-Document overlay coordination, and small result lookups.
- No operation proportional to the number of Git records, Project files, or vault notes runs synchronously in the UI Lua state.

This plan has two workstreams:

1. **File Tree Git status** — remove duplicate and hidden work, collapse ignored/untracked output, parse and aggregate Git output natively, and publish a native status snapshot.
2. **Markdown vault index** — move recursive filesystem discovery and ultimately vault fact construction/querying into native workers backed by immutable manifest and vault snapshots.

The work should proceed in red-green vertical slices. Each slice must establish one stable behavior seam, demonstrate the old failure or missing behavior, implement the smallest coherent architecture change, and run only the targeted tests for that slice.

## Evidence and motivating failures

The startup performance recording was:

```text
C:\Users\DARIOC~1\AppData\Local\Temp\anvil_perf_20260730_114909_summary.txt
```

The raw frame recording contains two non-redraw stalls:

```text
t+4.37s   approximately 1,279.5 ms
t+10.80s  approximately 1,267.9 ms
```

The expensive File Tree command was:

```text
git status --porcelain=v1 --ignored -uall -z
```

Measured against `D:\Projects\GLP4`:

| Mode | Output bytes | Records | Parent propagations |
|---|---:|---:|---:|
| Current `--ignored -uall` | 1,275,413 | 12,178 | 84,723 |
| Collapsed `--ignored --untracked-files=normal` | 3,431 | 81 | 162 |

Of the 12,178 current records, 12,172 were ignored files and only six were modified files. The Git process itself took roughly 100–180 ms; the observed 1.27-second stalls were dominated by Lua parsing, absolute-path construction, normalization, comparison-key construction, parent propagation, and allocation.

The scan was requested twice during startup:

1. `FileTreeView:new()` called `refresh()`.
2. Workspace restoration refreshed Project Path consumers.
3. Every File Tree refresh force-requested Git status.
4. The cooperative worker loop therefore performed a second complete scan.

The saved Workspace had the Right Pane hidden, so both scans were unnecessary for visible UI.

The same recording also contained an approximately 86 ms Markdown vault-index hitch and showed Project-scale filesystem amplification in `data/core/markdown/vault_index.lua`, including tens of thousands of `system.get_file_info()` calls and thousands of `system.absolute_path()` calls. Current cold rebuild, subtree adoption, watcher reconciliation, and degraded rescans all retain substantial traversal and fact-building work in UI Lua coroutines.

## Architectural decision

Do not solve these problems by only adding more `coroutine.yield()` calls.

`core.add_thread()` is cooperative main-thread scheduling. Yielding can bound one loop iteration, but it does not provide real background execution, prevent aggregate allocation in the UI Lua state, or guarantee that native snapshot construction/destruction is off-thread.

Use the existing architecture:

```text
data/core/worker_pool.lua
src/worker_pool.c
src/worker_pool.h
src/api/worker_pool.c
worker_pool_native
```

The Tree-sitter Project index established the relevant ownership and responsiveness rules:

- expensive construction runs on native workers;
- jobs carry cancellation and generation identity;
- completed immutable snapshots cross the boundary as typed native handles;
- Lua callbacks do not reconstruct the large dataset;
- stale results are rejected before adoption;
- destruction of large retired snapshots is not allowed to become a UI-thread spike;
- the UI drains bounded messages under `config.worker_pool_drain_budget_ms`.

The new systems should follow those rules rather than creating private thread/channel/process frameworks.

## Control plane versus data plane

### Lua control-plane responsibilities

Lua should own:

- whether the File Tree is actually presented;
- whether a refresh is dirty, deferred, forced, or throttled;
- request generation and Root Project identity;
- Git subprocess orchestration through `plugins.git.backend`;
- worker submission and cancellation requests;
- stale-result predicates;
- atomic snapshot-handle publication;
- Workspace and Project Path coordination;
- File Tree row presentation and colors;
- Markdown index consumer acquisition/release;
- watcher event coalescing into dirty path scopes;
- open-Document identity and overlay generation;
- user-facing loading, stale, error, and ready states.

### Native data-plane responsibilities

Native worker jobs should own:

- NUL-delimited Git status and numstat parsing;
- repository-relative path validation and canonicalization;
- exact status, parent status, subtree status, and numstat aggregation;
- recursive Project directory enumeration and stat collection;
- file classification and manifest diffing;
- scoped manifest updates;
- Markdown file reads for disk snapshots;
- Markdown vault fact construction;
- compact native indexes for note, alias, attachment, heading, block, and outbound-link lookup;
- deterministic native completion and rename queries;
- cancellation checks inside all long loops;
- immutable snapshot construction;
- large snapshot retirement and destruction.

## Shared native ownership contract

Each native snapshot introduced by this plan must be:

- immutable after publication;
- reference-counted;
- safe to query from the UI thread through short, bounded C API calls;
- owned by exactly one Lua userdata reference after being stolen from a worker result;
- explicitly closable and GC-safe;
- generation-neutral internally, with request generation enforced by the Lua facade and worker-pool message identity;
- able to report a small summary without materializing its contents;
- destructible without requiring an unbounded UI callback.

The worker result must transfer, not copy, the completed snapshot. `AnvilWorkerResult` should gain typed result fields and steal functions analogous to:

```text
anvil_worker_result_steal_treesitter_index_result
anvil_worker_result_steal_project_snapshot
```

Large snapshot replacement should use a native release job or another O(1) UI-side release mechanism if direct reference release would recursively free substantial storage on the UI thread.

Do not send a native snapshot through Lua worker channels or serialize it into Lua tables.

---

# Workstream A: File Tree Git status

## Required behavior contract

Before replacing the implementation, preserve and test these behaviors:

- The File Tree displays tracked modification, addition, deletion, rename/copy/type-change/unmerged, untracked, and ignored status with the existing strength ordering.
- A directory displays the strongest relevant descendant status.
- File and directory line additions/deletions retain current `git diff --numstat` behavior.
- A collapsed ignored directory record such as `!! build/` marks the directory and all visible descendants as ignored.
- A collapsed untracked directory record such as `?? scratch/` marks the directory and all visible descendants as untracked.
- An exact or aggregated stronger status overrides a weaker inherited subtree status.
- Paths with spaces and unusual non-NUL bytes remain valid.
- Porcelain-v1 `-z` rename/copy ordering remains correct.
- A Project rooted inside a larger Git repository is indexed relative to the discovered repository root.
- A non-repository Project publishes an empty current snapshot.
- Disabling Git integration publishes or retains the documented empty state without repeated retries.
- Status failure does not destroy the last valid snapshot or wedge the scheduler.
- Numstat failure may publish current status kinds without stale line totals.
- Manual refresh bypasses normal throttling.
- Automatic refreshes coalesce.
- A hidden or unselected File Tree performs no Git status work.
- Showing a dirty File Tree starts exactly one current refresh.
- A Root Project switch, newer request, cancellation, or hidden transition prevents stale publication.
- Workspace Project Path restoration remains correct and does not imply a second forced Git scan.

The current scope is the Root Project's containing Git repository. This plan does not silently expand File Tree Git decoration to every External Project Directory or nested repository; that would require a separate user-facing behavior decision.

## Immediate algorithmic correction

Change the status command from:

```text
git status --porcelain=v1 --ignored -uall -z
```

to:

```text
git status --porcelain=v1 --ignored --untracked-files=normal -z
```

The explicit mode must not depend on user Git configuration. Directory summary records must be interpreted as subtree status, not merely exact directory status.

This change is required even after native offload. Native code must not be used to accelerate output that should never have been requested.

## Target pipeline

```text
File Tree refresh/change/show
  -> Lua marks Git status dirty
  -> presented-state and throttle check
  -> asynchronous repository discovery through plugins.git.backend
  -> asynchronous Git status and numstat subprocesses
  -> both raw byte outputs complete
  -> native filetree_git_status_index worker job
       parse status bytes
       parse numstat bytes
       canonicalize repository-relative keys
       aggregate exact/parent/subtree status
       aggregate exact/parent stats
       build immutable native snapshot
  -> bounded worker-pool result
  -> Lua generation/root/presentation check
  -> atomic snapshot handle swap
  -> redraw
```

The Git subprocesses may run concurrently after repository discovery. Publication should be atomic so File Tree rows do not briefly combine new status kinds with old numstat values.

## Native Git status data model

Introduce a native component, tentatively:

```text
src/git_status_index.c
src/git_status_index.h
```

### Status enum

Use a compact native enum with the same ranking as `plugins.path_tree.stronger_kind()`:

```text
deleted
added
modified family: modified, renamed, copied, typechange, unmerged
untracked
ignored
none
```

The binding may preserve the specific exact kind where useful, while parent aggregation follows the existing strength contract. Keep one authoritative rank table in native code and test it against the Lua-visible behavior.

### Canonical path storage

Store repository-relative paths only:

- separators canonicalized to `/`;
- leading `./` removed;
- trailing directory summary slash recorded semantically and removed from the key;
- absolute paths rejected;
- empty path and `..` traversal segments rejected;
- Windows comparison keys ASCII-folded consistently with current Anvil path identity behavior;
- display/original path bytes retained only where a caller needs them.

Use a native string arena plus either a compact open-addressed hash index or sorted key arrays with binary search. Do not allocate one heap object per path component.

### Immutable snapshot

Tentative structure:

```text
AnvilFileTreeGitStatusSnapshot
  refcount
  repository root identity
  canonical path arena
  exact status index
  aggregate directory status index
  inherited subtree status index
  exact numstat index
  aggregate directory numstat index
  status byte/record counters
  numstat byte/record counters
  parent edge count
  rejected record count
  build duration
```

The native builder should parse directly from the two byte buffers and update indexes in one pass per buffer. It must not first construct an array equivalent to Lua record tables.

### Lookup semantics

A lookup for a file combines:

1. exact status;
2. nearest inherited untracked/ignored subtree status.

A lookup for a directory combines:

1. exact status;
2. aggregate descendant status;
3. nearest inherited subtree status.

The strongest applicable kind wins. Exact file numstat or aggregate directory numstat is returned independently.

## Native worker job

Add a native worker kind:

```text
filetree_git_status_index
```

The submission payload should have explicit binary-safe fields:

```text
repository_root
status_text + status_text_len
numstat_text + numstat_text_len
case_insensitive_paths
```

Do not overload C-string-only fields for NUL-delimited data. Extend `AnvilWorkerJobSpec`, the copied `AnvilWorkerJob`, and `src/api/worker_pool.c` with explicit length-carrying payload fields. Submission must deep-copy the bytes before returning to Lua.

The worker should:

- check cancellation before parsing;
- check cancellation periodically by bytes/records and during parent propagation;
- free partial builders on cancellation or failure;
- enqueue one typed result followed by terminal completion;
- expose no partially built snapshot;
- report structured error text and counters.

## Native Lua handle

Expose a userdata such as:

```text
NativeFileTreeGitStatusSnapshot
```

Required methods:

```lua
snapshot:summary()
snapshot:lookup(relative_path, is_directory)
snapshot:close()
```

`lookup()` returns only a tiny value:

```lua
{
  kind = "modified",
  additions = 5,
  deletions = 2,
}
```

No method should materialize every status record as a Lua table in normal editor operation. A bounded diagnostic page may exist only for tests/debugging if necessary.

File Tree entry snapshots should cache the repository-relative lookup key once per File Tree entry generation. Rendering should cache the tiny lookup result by native snapshot generation so icon, text, gutter, and line-hint paths do not independently cross the C boundary for the same row.

## Lua status controller

Extract scheduling from `data/plugins/filetree/init.lua` into a focused module, tentatively:

```text
data/plugins/filetree/git_status.lua
```

This module is a control-plane facade, not the data index. It should own:

```text
requested generation
published generation
dirty state
pending reason
last start/success time
positive repository cache
repository-discovery job
status process job
numstat process job
native worker handle
current native snapshot
presented-state transition
```

### Presented predicate

Git work is allowed only when:

```lua
panes.right_visible()
  and panes.selected_view("right") == filetree
  and filetree.visible
```

When hidden or replaced by another Right Pane Selected View:

- retain dirty intent;
- cancel unnecessary active jobs;
- publish no stale completion;
- perform no new repository discovery, Git command, or native build.

`FileTreeView:update()` can detect transition to presented state without adding special handling to every `panes.show()` caller.

### Request behavior

Every refresh request records intent but does not immediately force work:

- automatic request: mark dirty and obey the real refresh interval;
- manual File Tree refresh: mark dirty and bypass interval;
- request while hidden: defer;
- duplicate request before start: coalesce;
- newer request during repository/Git/native work: increment generation and cancel or supersede old jobs;
- status completion from a stale generation: discard before submitting native parsing;
- native completion from a stale generation: close result without publication.

The old `git_status_worker_running`/`git_status_refresh_requested` loop and always-`force=true` behavior should be removed.

### Failure behavior

- Git disabled: publish an empty current snapshot or explicit empty singleton and become idle.
- Not a repository: publish empty and cache only as appropriate; a later forced refresh must allow discovery after `git init`.
- Repository discovery failure: preserve previous status and become retryable.
- Status failure/output cap: preserve previous valid snapshot, log quietly, become retryable.
- Numstat failure: submit status with empty current stats and log quietly.
- Native submission/build failure: preserve previous snapshot, clear active state, become retryable.
- Cancellation/staleness: publish nothing and release all results.

All terminal paths must clear the relevant active handles. No exception may leave the controller permanently running.

## Shared Git backend cleanup

Use `plugins.git.backend` for:

- repository discovery;
- Git executable/config handling;
- asynchronous process capture;
- cancellation;
- configurable output caps;
- diagnostics.

Delete File Tree's private:

```text
run_process_capture
split_nul status parsing
git_abs parent aggregation
hard-coded 2 MiB status process cap
```

The generic Lua parsers in `plugins.git.backend` may remain for other bounded callers, but File Tree must use the native snapshot path and must not call `parse_status_z()` for repository-scale output.

## Workspace and startup coordination

Keep the legitimate Workspace responsibility of restoring Project Paths. Decouple it from immediate Git execution.

Startup should behave as follows:

1. File Tree construction builds its filesystem presentation and marks Git status dirty.
2. Workspace restoration loads effective Project Paths.
3. File Tree presentation refreshes only if required.
4. Git status requests remain coalesced dirty intent.
5. If the File Tree remains hidden, zero Git jobs run.
6. If Workspace restores the File Tree as the Selected View in a shown Right Pane, one current Git pipeline starts after restoration settles.

As a secondary cleanup, let `project_paths.load_workspace_state()` report whether the effective Project Path set changed. Root Project identity must be part of that comparison. `workspace.lua` should skip an empty-to-empty consumer refresh, but must still refresh when saved External Project Directories, Vendored Project Directories, Excluded Project Paths, labels, or roles changed.

## File Tree phases and red-green seams

### A0 — Freeze evidence and behavior fixtures

Red/characterization work:

- capture current command count and status record count on a fixture with a large ignored directory;
- add observable File Tree tests for ignored/untracked subtree inheritance;
- add tests for parent strength and numstat;
- add tests for hidden defer and duplicate request coalescing;
- add tests for stale Root Project completion and retry after failure.

Exit gate:

- failures demonstrate missing subtree behavior, duplicate/hidden scheduling, stale publication risk, and current Lua aggregation seam for the expected reason.

### A1 — Correct query and Lua control lifecycle

Implement:

- collapsed status command;
- subtree semantics in the temporary path if required to make the first behavior slice green;
- dirty/deferred/coalesced controller;
- real manual-force versus automatic throttle behavior;
- shared Git backend process use;
- generation and cancellation checks.

Exit gate:

- measured fixture output is directory-collapsed;
- hidden startup launches zero scans;
- visible startup launches one scan;
- all controller regression tests pass;
- reported freezes are substantially reduced before native migration.

### A2 — Native parser and snapshot library

Red tests first in native C:

- exact status parsing;
- directory summary classification;
- rename/copy NUL ordering;
- parent status ranking;
- inherited subtree lookup;
- numstat aggregation;
- malformed path rejection;
- case-insensitive lookup mode;
- cancellation during synthetic large input;
- immutable snapshot lifetime.

Implement `git_status_index.[ch]` independent of Lua bindings where possible.

Exit gate:

- native library tests pass and no Lua runtime is required to validate core parsing/index semantics.

### A3 — Native worker and Lua userdata

Red tests:

- native worker accepts binary NUL payloads;
- cancellation returns exactly one terminal cancellation;
- typed snapshot ownership transfers through `AnvilWorkerResult`;
- lookup/summary methods work after worker completion;
- closing and GC are safe.

Implement worker job, result stealing, userdata, and bounded API.

Exit gate:

- `core.worker_pool` can submit/cancel the native Git status job and receive one snapshot handle without materializing records.

### A4 — File Tree native adoption

Replace temporary Lua aggregation with native submission and handle publication.

Red-green tests through the File Tree seam should verify displayed/queryable entry behavior, not native helper call counts. Fakes are appropriate only at the Git process and native-worker boundaries.

Delete superseded Lua record/parent aggregation once parity is proven. Do not keep both authoritative implementations.

Exit gate:

- no loop proportional to Git record count runs in UI Lua;
- File Tree stores a native snapshot handle rather than `files`, `dirs`, `stats`, and `dir_stats` repository-scale Lua maps;
- stale native results are closed without publication;
- targeted UI tests pass.

### A5 — Performance validation and cleanup

Record the same startup scenario and compare raw frame CSV data.

Exit gate:

- no approximately 1.27-second File Tree stalls;
- hidden File Tree performs zero Git pipelines;
- visible File Tree performs one startup pipeline;
- status command returns collapsed output;
- worker callback/drain time remains bounded;
- native build timing is visible in diagnostics;
- obsolete private process/parser/scheduler code is deleted.

---

# Workstream B: Markdown vault index

## Required behavior contract

The current `tests/lua/runtime/markdown_vault_index.lua` suite captures substantial behavior. Preserve:

- note and attachment discovery beneath the Root Project used as the vault root;
- supported Markdown extensions and attachment extensions;
- `.git`, `.obsidian`, and `.run-meson-tests` traversal exclusions unless deliberately refined with tests;
- note lookup by explicit path, basename, extensionless path, and alias;
- deterministic ambiguity reporting;
- heading lookup by normalized text, slug, and heading path;
- block lookup;
- standard links, wikilinks, embeds, percent-decoded targets, and subtargets;
- deterministic note, alias, heading, block, and attachment completion;
- frontmatter aliases, tags, and values;
- embed preview construction;
- outbound-link facts used by rename maintenance;
- rename planning and stale rename protection;
- open-Document overlays replacing disk facts;
- overlays surviving disk deletion while the Document remains open;
- correct movement of tracked Documents across vault roots;
- oversized-note shallow behavior and completeness markers;
- consumer-based watcher start/stop lifecycle;
- filesystem creation, modification, deletion, rename, and new-subtree reconciliation;
- indexing/ready/error state and listener notifications;
- generation changes only for current published state;
- deterministic results regardless of worker completion order.

Before replacing direct public-looking map access such as `notes_by_abs`, introduce explicit stable methods such as `note(path)` and update tests/callers. Native migration should not force callers to inspect snapshot internals.

## Target architecture

```text
Markdown consumer/open Document
  -> Lua Index facade acquires vault root
  -> native Project file manifest job
       recursive enumerate/stat/classify
       build or update immutable manifest
  -> native Markdown vault index job consumes manifest
       read eligible changed notes
       parse/extract note facts
       reuse unchanged facts from previous vault snapshot
       build immutable lookup/query indexes
  -> Lua generation/root check
  -> atomic NativeMarkdownVaultSnapshot handle swap
  -> listeners receive bounded state notification

Watcher events
  -> Lua coalesces dirty directories/paths
  -> native scoped manifest update
  -> native scoped vault snapshot update
  -> current-generation publication

Open Documents
  -> Lua snapshots current text/revision
  -> native single-note overlay job
  -> native note-fact handle
  -> overlay handle replaces disk note for bounded queries
```

No recursive traversal, whole-vault table rebuild, whole-vault completion scan, or whole-vault rename scan should remain in UI Lua.

## Phase-one native Project file manifest

Extract reusable native enumeration from the existing Tree-sitter Project-run walker in `src/worker_pool.c` rather than creating another traversal implementation.

Tentative components:

```text
src/project_file_manifest.c
src/project_file_manifest.h
```

### Manifest record

```text
canonical absolute path
canonical vault-relative path
entry type
classification: markdown / attachment / other directory/file
size
modified time or platform fingerprint
parent/directory identity
```

The manifest must preserve enough identity to determine added, removed, changed, and unchanged files without restatting every previous record in Lua.

### Manifest snapshot

```text
AnvilProjectFileManifestSnapshot
  refcount
  root identity
  compact path arena
  deterministic path-sorted records
  path lookup index
  directory hierarchy/index
  scan/exclusion counters
  total bytes/files/directories
  scan duration
```

### Full and scoped builds

Support:

- full root scan;
- scoped dirty-directory scan based on a previous manifest;
- explicit removed path scopes where the watcher supplies them;
- cancellation;
- deterministic merge into a new immutable snapshot.

Do not mutate a published snapshot. A scoped update should share or copy immutable unchanged storage using a clear ownership model; choose correctness and simple ownership before introducing structural sharing complexity.

### Traversal rules

- Reuse SDL/native directory enumeration already used by native Project indexing.
- Avoid following directory cycles and unsafe symlink/reparse-point recursion.
- Preserve current explicit exclusions.
- Record inaccessible directories/files as bounded diagnostics rather than failing the entire vault when current behavior skips them.
- Check cancellation during directory enumeration and merge.
- Never call Lua callbacks per file.

## Native manifest worker and API

Add a native worker kind:

```text
project_file_manifest
```

Payload:

```text
root
previous manifest handle optional
scoped scan paths optional
remove paths optional
extension/classification policy
explicit exclusions
```

Result: a typed `NativeProjectFileManifestSnapshot` handle.

Required bounded methods:

```lua
manifest:summary()
manifest:lookup(path)
manifest:page(offset, limit) -- diagnostics/tests only
manifest:close()
```

The final vault path must consume the native manifest handle directly in another native job. It must not page every manifest record into UI Lua as the normal handoff.

A bounded-page transitional adopter is acceptable only while establishing parity; it must not become the final authoritative pipeline.

## Native Markdown vault snapshot

Tentative components:

```text
src/markdown_vault_index.c
src/markdown_vault_index.h
```

Reuse Anvil's native Markdown parser and Tree-sitter query/cache primitives rather than creating a second Markdown grammar implementation.

### Native note facts

For each note, retain compact equivalents of:

```text
absolute and relative path
display name
size/modified fingerprint
aliases
tags
frontmatter key/value facts
outbound links and parsed target/subtarget information
headings: text, normalized text, slug, path slug, line/range
blocks: id, line/range
bounded embed previews
shallow/completeness state
fact signature
```

Strings should live in compact arenas and records should use offsets/indices rather than individually allocated duplicate strings.

Frontmatter behavior must be characterized before porting. Preserve currently supported scalar/list parsing exactly; do not broaden YAML semantics as part of the performance migration.

### Native indexes

Build native indexes for:

- exact absolute/relative path;
- extensionless path;
- basename and display name;
- aliases;
- attachments;
- per-note heading slug/text/path;
- per-note block id;
- outbound destination/source relationships;
- deterministic completion search text/order.

Ambiguous lookup must retain all candidates necessary for the existing user-facing result.

### Previous-snapshot reuse

A native vault build receives:

- current manifest snapshot;
- optional previous vault snapshot;
- changed/removed scopes;
- current indexing policy.

Unchanged note facts may be retained/reused by fingerprint and parser-policy fingerprint. Changed notes are reread and reparsed. Removed paths disappear. Snapshot publication occurs only after all current-generation updates are assembled.

Policy fingerprints must include anything that changes facts, including Markdown query/parser behavior, supported extension policy, and shallow-note limits.

### Oversized notes

Preserve bounded shallow indexing. The worker may retain note identity, top-level heading information, and explicit completeness flags without fully indexing expensive subtargets beyond configured safety limits. Exact existing behavior must remain test-backed.

## Native vault worker jobs

Add native job kinds such as:

```text
markdown_vault_index
markdown_vault_overlay
markdown_vault_snapshot_release
```

`markdown_vault_index` consumes a manifest handle and optional previous vault snapshot directly. Handle submission must retain the inputs for the duration of the worker job.

`markdown_vault_overlay` consumes one Document text snapshot and produces one immutable native note-fact handle. It must carry Document revision and Lua request generation through the control-plane handle metadata.

Cancellation checks are required:

- between files;
- during large file reads;
- during Markdown parse/query work through existing cancel-token support;
- during fact/index construction;
- during final snapshot construction.

Partial snapshots are not required initially. A previous ready snapshot may remain available as stale state while a current build runs. If partial publication is later desired, it needs a separate behavior contract.

## Native vault Lua facade

Keep `data/core/markdown/vault_index.lua` as the public control-plane facade, but replace repository-scale Lua maps with native snapshot handles.

Target bounded API:

```lua
index:ensure(reason)
index:status()
index:note_count()
index:attachment_count()
index:note(path)
index:resolve(link_or_target, source_path)
index:completion_candidates(mode, partial, source_path, limit)
index:plan_note_rename(old_path, new_path)
index:track_doc(doc)
index:untrack_doc(doc)
index:acquire(id)
index:release(id)
```

`resolve`, `note`, and completion methods may materialize only the bounded result records needed by the caller. Do not expose a method that reconstructs all notes by default.

### Open-Document overlays

Lua keeps a small map:

```text
Document identity -> overlay request generation -> native note-fact handle
```

Queries receive the relevant overlay handles or the native vault facade performs an overlay-aware merge. Disk facts for an overlaid path are suppressed. Closing or moving a Document cancels stale overlay work and releases the old handle.

Overlay parsing must not remain synchronous in `track_doc()` or `schedule_doc_update()`. Debounce remains a Lua policy, but parsing/fact construction runs natively.

### Rename planning

Current rename planning scans every Lua note and outbound link. Move the query to the native vault snapshot:

```lua
snapshot:plan_note_rename(old_path, new_path, options)
```

The result may be proportional to the number of affected files/edits because the user explicitly requested the operation, but it must not materialize unrelated vault records. Preserve stale-plan validation before applying edits.

### Completion

Current completion loops and sorts the full vault in Lua. Native completion should accept mode, partial text, source path, and limit, and return deterministic bounded candidates plus optional total/truncated metadata.

## Watcher and degraded reconciliation

The current watcher remains the event source initially. Replace traversal behavior:

- watcher callbacks only add normalized dirty directory/path intent;
- overlapping scopes coalesce;
- an active scoped update is not repeatedly cancelled for every event; queued intent follows it in one merged generation where appropriate;
- full degraded reconciliation submits a background native manifest job;
- no five-second whole-root traversal runs in UI Lua;
- only one full degraded reconciliation per vault may be active;
- newer dirty scopes are merged into the next update rather than spawning parallel scans;
- consumer release cancels or invalidates unnecessary work and stops watching.

The degraded rescan interval is an internal policy unless a clear user-facing customization need emerges. Tests should verify bounded/coalesced behavior, not an exact interval value.

## Markdown phases and red-green seams

### B0 — Freeze behavior and introduce stable public seams

Characterize existing behavior in `tests/lua/runtime/markdown_vault_index.lua`.

Add/update public methods so tests and callers no longer require direct inspection of `notes_by_abs` or `attachments_by_abs` for ordinary behavior. Preserve direct internal inspection only where a test truly validates a native-independent fact contract.

Add diagnostics for:

- active vault roots;
- concurrent rebuild/subtree/reconcile jobs;
- directories/files visited;
- filesystem API calls where still Lua;
- elapsed time per UI coroutine resume;
- degraded full reconciliations;
- note facts reused/rebuilt;
- stale/cancelled publications.

Exit gate:

- behavior contract is represented through stable APIs;
- the 86 ms startup event can be attributed to a concrete vault root and job generation.

### B1 — Native manifest library

Red native tests for:

- deterministic recursive discovery;
- Markdown/attachment classification;
- exclusions;
- inaccessible entry handling;
- path normalization;
- cancellation;
- full snapshot lifetime;
- scoped add/change/delete/rename update;
- no cycle traversal.

Implement reusable native manifest component.

Exit gate:

- full/scoped manifest snapshots are correct without Lua traversal.

### B2 — Manifest native worker and vault traversal migration

Add worker/result/userdata support. Submit cold scans and reconciliations through `core.worker_pool`.

During this slice, existing Lua fact construction may consume bounded manifest pages under the worker-pool/UI budget only as a temporary parity bridge. Track and cap adoption work explicitly.

Exit gate:

- no `system.list_dir()` recursive vault walk runs in UI Lua;
- no Project-scale stat/absolute-path amplification remains in UI Lua;
- watcher and degraded reconciliation submit native scans;
- current vault tests remain green.

### B3 — Native note-fact construction

Red tests should use worked Markdown fixtures for:

- aliases/tags/frontmatter;
- links/wikilinks/embeds;
- heading text/slug/path;
- blocks;
- previews;
- shallow notes;
- malformed or unsupported input;
- deterministic fact signatures.

Implement native per-note fact extraction using existing Markdown parser/query primitives.

Exit gate:

- native facts match current Lua behavior fixture-for-fixture;
- changed note parsing occurs off the UI thread.

### B4 — Native vault snapshot and bounded queries

Red tests for:

- exact and ambiguous note resolution;
- heading/block subtargets;
- attachments;
- deterministic completion;
- outbound-link/rename planning;
- previous-snapshot reuse and removal;
- snapshot cancellation/lifetime.

Implement immutable vault snapshot and native lookup indexes.

Exit gate:

- repository-scale note maps and completion/rename scans no longer run in UI Lua;
- the native snapshot is authoritative for disk facts.

### B5 — Native open-Document overlays

Red behavior tests:

- unsaved text overrides disk;
- disk deletion does not remove an open overlay;
- rapid edits publish only current revision;
- close restores current disk state if present;
- cross-root rename removes old overlay and publishes only to the new vault;
- stale overlay result is released.

Implement native single-note overlay jobs and overlay-aware queries.

Exit gate:

- `track_doc()` and debounced updates perform no synchronous full note parsing/fact construction in UI Lua.

### B6 — Delete superseded Lua indexing machinery

Remove:

- recursive `scan_dir()` data path;
- cooperative full-vault rebuild loops;
- cooperative subtree scan data path;
- UI-side whole-vault Lua maps as authoritative storage;
- UI-side whole-vault completion sorting;
- UI-side outbound-link rename scan;
- repeated `absolute_path`/`file_exists`/`get_file_info` amplification;
- compatibility adapters that have no external boundary.

Keep the Lua facade and user-facing API names where they remain the correct domain seams.

Exit gate:

- one native disk snapshot plus bounded native overlay handles are authoritative;
- no duplicate fallback index silently continues doing work.

### B7 — Performance validation

Record startup, cold vault build, watcher update, degraded reconciliation, completion, and rename-plan scenarios.

Exit gate:

- no approximately 86 ms vault-index startup hitch;
- no UI Lua slice proportional to vault size;
- worker-pool callback/drain remains within its configured budget;
- full scan and scoped update timing is visible as native worker diagnostics;
- completion and resolution remain responsive while a stale ready snapshot is available;
- current behavior tests remain green.

---

# Shared implementation sequence

The workstreams should not be implemented as one giant rewrite. Recommended commit/vertical-slice order:

1. Add File Tree Git behavior/scheduling regressions and baseline diagnostics.
2. Correct Git command, hidden deferral, coalescing, and generation lifecycle.
3. Add native Git status index library and native tests.
4. Add native Git worker/result/userdata contract.
5. Adopt native Git snapshot in File Tree and delete Lua aggregation.
6. Validate File Tree startup recording.
7. Add Markdown stable public seams and vault-job diagnostics.
8. Extract/add native Project file manifest with native tests.
9. Move vault filesystem traversal and reconciliation to native manifest jobs.
10. Add native Markdown note-fact extraction parity fixtures.
11. Add native vault snapshot and bounded resolution/completion/rename queries.
12. Add native open-Document overlays.
13. Delete superseded Lua vault indexing paths.
14. Validate startup and recurring vault performance.

Each commit should leave one authoritative path. Temporary migration paths must be named and deleted in a scheduled later slice, not retained indefinitely.

## Interaction between workstreams

The two workstreams share infrastructure but should not share domain snapshots:

- both use `core.worker_pool` native jobs, cancellation, stale predicates, bounded draining, and typed result handles;
- Markdown reuses a general native Project manifest walker;
- File Tree Git status consumes Git output and does not require a filesystem manifest;
- Git status and Markdown vault snapshots have independent generations and lifecycles;
- background priority must prevent either from occupying Anvil's interactive native worker lane needed by active-Document Markdown/Tree-sitter parsing.

Use `priority = "background"` for cold/degraded vault work. File Tree status requested by a visible File Tree may use an interactive or normal lane, but hidden work is deferred rather than merely deprioritized.

## UI drain and callback rules

Worker callbacks must remain O(1) or bounded by the displayed result size:

Allowed:

- generation comparison;
- state/counter update;
- snapshot handle swap;
- close stale handle;
- enqueue one follow-up request;
- notify a bounded listener set;
- mark redraw.

Forbidden:

- native snapshot construction/finalization;
- iterating all snapshot records;
- reconstructing large Lua maps;
- sorting all candidates;
- scanning all open views/files;
- freeing a large object graph synchronously.

Use existing worker-pool diagnostics to record callback and dispatch times. Add domain-native build times to snapshot summaries and perf details.

# Testing strategy

## File Tree Git tests

### Native

Tentative files:

```text
tests/native/git_status_index_test.c
tests/native/worker_pool_test.c
```

Cover parser/index/cancellation/ownership independently of the editor UI.

### Lua runtime/UI

Tentative files:

```text
tests/lua/runtime/git_backend.lua
tests/lua/runtime/workspace.lua
tests/lua/ui/filetree_git_status.lua
```

Drive public File Tree methods/commands and pane presentation. Fake Git/native jobs only at true external/nondeterministic boundaries. Do not assert keyboard shortcuts.

## Markdown tests

### Native

Tentative files:

```text
tests/native/project_file_manifest_test.c
tests/native/markdown_vault_index_test.c
tests/native/worker_pool_test.c
```

Use small deterministic fixtures and synthetic large/cancellation inputs.

### Lua runtime

Primary behavior suite:

```text
tests/lua/runtime/markdown_vault_index.lua
```

Continue testing resolution, completion, rename, watcher reconciliation, and overlays through the public vault-index facade. Replace direct private-map expectations with public note/fact methods when those maps cease to be authoritative.

## Red-green requirements

For every user-reported discrepancy or non-trivial migration slice:

1. Add or identify the targeted test at the chosen public/native contract seam.
2. Run it against the current implementation and confirm the expected failure.
3. Implement the smallest vertical slice.
4. Re-run the targeted test and confirm green.
5. Run only directly relevant neighboring test files/targets.

When a migration is behavior-preserving and the old implementation already passes the behavior test, add a contract test for the new native boundary and use the performance recording/diagnostic counter as the red evidence. Do not fabricate fragile millisecond assertions in ordinary unit tests.

# Diagnostics and performance evidence

## File Tree Git quiet logs

Record:

```text
request generation/root/reason/forced
hidden deferral
coalesced request count
repository discovery start/result
status and numstat job ids/durations/bytes
native job id/duration
status/numstat record counts
parent edges/subtree summaries/rejected records
cancellation/stale result
published snapshot generation
retired snapshot release
```

## Markdown vault quiet logs

Record:

```text
vault root and generation
manifest full/scoped mode
scan paths and coalesced scope count
directories/files/notes/attachments
reused/rebuilt/removed note facts
bytes read and skipped oversized notes
manifest/vault native durations
watcher mode and degraded reconciliation
cancellation/stale result
published disk snapshot
open-Document overlay generation/publication/release
```

Use `core.log_quiet()` for state transitions and background diagnostics. Surface visible errors only when the user must act.

## Perf acceptance process

For each workstream:

1. Retain the original recording as baseline.
2. Capture the same Project/startup duration and visibility state.
3. Inspect raw `*_frames.csv`, not only slow redraw summaries.
4. Inspect worker-pool drain/callback metrics.
5. Inspect domain snapshot summaries and command counts.
6. Verify that no hidden work was launched.
7. Repeat with the relevant tool visible.
8. Exercise cancellation by refreshing/switching roots during active work.
9. Exercise a genuinely large changed-file/vault fixture.

Do not declare success solely because total completion became faster. Responsiveness requires bounded UI-thread work even when background completion takes longer.

# Expected files

Likely new native components:

```text
src/git_status_index.c
src/git_status_index.h
src/project_file_manifest.c
src/project_file_manifest.h
src/markdown_vault_index.c
src/markdown_vault_index.h
```

Likely modified native infrastructure:

```text
src/worker_pool.c
src/worker_pool.h
src/api/worker_pool.c
src/meson.build
```

Likely modified Lua control plane:

```text
data/plugins/filetree/init.lua
data/plugins/filetree/git_status.lua
data/plugins/git/backend.lua
data/plugins/workspace.lua
data/core/project_paths.lua
data/core/markdown/vault_index.lua
data/core/worker_pool.lua          # only if generic facade support is required
```

Likely tests:

```text
tests/native/git_status_index_test.c
tests/native/project_file_manifest_test.c
tests/native/markdown_vault_index_test.c
tests/native/worker_pool_test.c
tests/lua/ui/filetree_git_status.lua
tests/lua/runtime/git_backend.lua
tests/lua/runtime/workspace.lua
tests/lua/runtime/markdown_vault_index.lua
```

Avoid modifying unrelated dirty line-wrapping, fuzzy-search, DocView, and Tree-sitter files unless a shared worker-pool contract genuinely requires it. Do not overwrite or revert existing uncommitted work.

# Build and validation workflow

Because this plan includes C and build-system changes, each completed native slice requires rebuilding. Close Anvil before replacing binaries.

Targeted native tests should be registered in Meson under the Anvil suite/environment. Run the smallest relevant targets first. Examples after targets are added:

```sh
PATH=/c/msys64/mingw64/bin:$PATH /c/msys64/mingw64/bin/meson.exe test \
  -C build-windows-x86_64 anvil:git-status-index --print-errorlogs

PATH=/c/msys64/mingw64/bin:$PATH /c/msys64/mingw64/bin/meson.exe test \
  -C build-windows-x86_64 anvil:project-file-manifest --print-errorlogs

PATH=/c/msys64/mingw64/bin:$PATH /c/msys64/mingw64/bin/meson.exe test \
  -C build-windows-x86_64 anvil:markdown-vault-index --print-errorlogs
```

Existing relevant targets/files:

```sh
PATH=/c/msys64/mingw64/bin:$PATH /c/msys64/mingw64/bin/meson.exe test \
  -C build-windows-x86_64 anvil:worker_pool --print-errorlogs

PATH=/c/msys64/mingw64/bin:$PATH /c/msys64/mingw64/bin/meson.exe test \
  -C build-windows-x86_64 anvil:lua-ui --test-args ui/filetree_git_status.lua --print-errorlogs

PATH=/c/msys64/mingw64/bin:$PATH /c/msys64/mingw64/bin/meson.exe test \
  -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/markdown_vault_index.lua --print-errorlogs
```

Validate changed Lua files with the repo-local LuaJIT syntax checker.

When a native slice is finished, update the dev portable app from the repo root:

```sh
cmd.exe //d //s //c "call C:\Projects\c_projects\anvil-editor\update-anvil-dev-build.bat"
```

# Risks and mitigations

## Native code accelerates the wrong workload

Risk: native parsing makes `-uall` tolerable and hides duplicate scheduling without fixing it.

Mitigation: collapsed Git output, visibility defer, and coalescing are Phase A1 gates before native adoption.

## Native callback still blocks the UI

Risk: snapshot finalization or destruction is accidentally called from `on_result` or userdata GC.

Mitigation: worker jobs return already-finalized immutable handles; large release is worker-backed; perf captures include callback timing.

## Lua materialization recreates the stall

Risk: native jobs finish quickly but Lua callbacks convert snapshots into large maps.

Mitigation: bounded lookup/query APIs only; no full materialization in normal operation; code review and perf diagnostics enforce this.

## Path semantics diverge

Risk: native Windows folding, separators, repository-relative paths, symlinks, or rename records differ from current behavior.

Mitigation: characterize path behavior, reuse lexical identity rules, reject unsafe Git paths, and add cross-platform fixture tests.

## Markdown behavior port drifts

Risk: frontmatter, heading slugs, blocks, previews, aliases, or link ambiguity change during the C migration.

Mitigation: fixture-for-fixture parity tests before deleting Lua implementation; port only currently supported semantics.

## Snapshot ownership leaks or double-frees

Risk: worker result, Lua userdata, previous snapshot, or overlay retains inconsistent ownership.

Mitigation: explicit retain/steal/release APIs; moved-from userdata becomes harmless; cancellation tests; native lifecycle counters where useful.

## Cancellation is too coarse

Risk: cancellation is requested but one large file or final index build still runs for a long time.

Mitigation: cancellation checks by bytes/records, directory/file boundaries, parser progress callbacks, merge loops, and snapshot construction phases.

## Background work starves interactive parsing

Risk: vault cold scans occupy all native workers and delay active-Document parsing.

Mitigation: use existing worker lanes/priorities; background vault work avoids the interactive lane; cap concurrent Project-scale native runs.

## Watch events cause restart thrashing

Risk: every event cancels a nearly complete native update.

Mitigation: coalesce dirty scopes; queue intent during active work; cancel immediately only for root/generation invalidation or hidden File Tree work.

## Large rewrite becomes unreviewable

Risk: Git, manifest, vault facts, overlays, and cleanup land together.

Mitigation: follow the stated vertical slices and keep each commit independently testable and usable.

# Definition of done

## Workstream A

- File Tree uses collapsed ignored/untracked Git status output.
- Hidden/unselected File Tree launches no Git status work.
- Visible startup launches exactly one current pipeline.
- Git parsing, path canonicalization, parent/subtree aggregation, and numstat aggregation run in native worker C.
- File Tree publishes an immutable native status snapshot handle.
- No repository-scale status maps or record arrays are built in UI Lua.
- Cancellation, stale generation, Root Project switch, non-repository, Git-disabled, output-cap, and failure/retry behavior are test-backed.
- The two approximately 1.27-second startup stalls are absent from raw frame recordings.

## Workstream B

- Recursive vault discovery/stat/classification runs in a native Project manifest worker.
- Full and scoped manifest updates are immutable, cancellable, and generation-safe.
- Disk note fact construction and vault lookup indexes run in native worker C.
- Resolution, completion, and rename planning query bounded native APIs.
- Open-Document overlays are parsed/indexed off the UI thread and suppress disk facts correctly.
- No full-vault traversal, table rebuild, completion sort, or rename scan runs in UI Lua.
- Existing Markdown vault behavior remains test-backed.
- The approximately 86 ms startup hitch and recurring degraded-rescan UI bursts are absent from raw frame recordings.

## Shared

- Worker-pool callbacks remain bounded.
- Large snapshot construction and retirement do not run on the UI thread.
- Native ownership and cancellation tests pass.
- Relevant targeted Lua UI/runtime tests pass.
- Quiet logs and perf summaries make future regressions attributable.
- Superseded Lua implementations and temporary migration adapters are removed.
- The dev portable app is rebuilt and updated after native changes.
