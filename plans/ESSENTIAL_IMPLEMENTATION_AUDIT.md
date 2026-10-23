# Essential implementation audit

Date: 2026-10-23

Source baseline: `9df5a67d42b2940a0b6f3ada634fc4aa69e3cdd3`

## Main result

The shell presentation fix addresses a real scheduling problem. It does not remove work from the hosted Editor's UI thread.

This audit reproduced six defects or resource-retention problems. It also measured blocking large-file opening and several smaller editing costs.

The most urgent work concerns file safety, failed-save recovery, and completed-job retention. These need focused changes, not a new architecture.

No production code changed during this audit. The daily application was not restarted. Tests used isolated state and temporary files.

## Scope and evidence

The audit followed essential paths through the Windows application, bundled plugins, native APIs, and dev update scripts.

It examined input, presentation, editing, persistence, file operations, watching, indexing, search, Markdown, images, subprocesses, Terminal Sessions, and shutdown.

This is a broad source audit with targeted experiments. It is not proof that every path is correct.

The audit did not validate Linux, macOS, every GPU, network filesystems, every grammar, or optional LSP behavior.

The older [performance audit](PERFORMANCE_AUDIT.md) supplied leads. Its conclusions were not accepted without checking current code.

Evidence labels:

- **Reproduced:** an isolated probe demonstrated the behavior.
- **Measured:** an existing isolated performance scenario recorded the cost.
- **Source-confirmed:** the code establishes the mechanism; practical impact was not measured here.
- **Needs measurement:** a plausible limit or failure mode needs a targeted workload.

Priority labels:

- **P1:** protect files or recoverable state first.
- **P2:** fix correctness, resource growth, or material blocking next.
- **Measure:** establish practical impact before changing the design.

## Reproduced findings

### 1. P1: recursive deletion follows directory junctions

**Evidence: reproduced.**

[`common.rm`](../data/core/common.lua), around line 1140, treats a directory junction as a directory to traverse.
It does not stop at the exposed `symlink` flag.

The probe created `tree/link -> target`, then removed `tree` recursively.
Removal returned success, but it also deleted `target/keep.txt` outside `tree`.
Both locations were inside the isolated test folder.

The File Tree's permanent-delete path calls this helper.
Windows uses the Recycle Bin by default, so ordinary trash operations do not take this path.
This finding does not establish a defect in the native Recycle Bin operation.

The File Tree's recursive copy also follows directory links. A link back to an ancestor can cause repeated traversal.
That copy-loop case was inspected, not reproduced.

**Smallest correction:** remove a link itself without traversing its target.
Give recursive copy an explicit link policy. Do not treat every directory-shaped entry as an ordinary directory.

### 2. P1: File Tree copy reports success after a read error

**Evidence: reproduced through `FileTreeView:apply_plan`.**

[`copy_file`](../data/plugins/filetree/init.lua), around line 406, treats every `nil` read as end-of-file.
It discards the read error and ignores output-close errors.
Directory copy also treats a failed directory listing as an empty list.

The probe injected a source read error at the I/O boundary.
`apply_plan` returned `true` and left a zero-byte destination for a nonempty source.

This corrupts the copy, not the original source. A user can subsequently delete the original because Anvil reported success.

**Smallest correction:** check read, directory-listing, write, and close results.
Do not report success for incomplete output. Remove a failed new destination or identify it clearly as incomplete.

### 3. P1: a failed Workspace save suppresses unchanged retries

**Evidence: reproduced through `core.request_workspace_save`.**

[`save_workspace`](../data/plugins/workspace.lua), around lines 324–327, ignores `storage.save` failure.
It still updates `last_saved_key` and `last_saved_text`.
The next background save can then skip the same state as already saved.

The probe blocked one temporary-file open, restored I/O, and requested another save without changing the Workspace.
The saved Workspace still lacked the new file.

An unconditional save during a clean exit can retry. The risk concerns the interval before that save, including a crash.

**Smallest correction:** advance the saved-state cache only after successful persistence.
Retain a pending save after failure. Keep diagnostics for the failed attempt and later recovery.

### 4. P2: completed worker jobs remain in the Lua pool

**Evidence: reproduced, with diagnostic instrumentation.**

[`release_terminal_job`](../data/core/worker_pool.lua), around line 56, releases specs and native handles.
It does not remove the job record from `self.jobs`.
Long-lived pools therefore retain one record and handle for each completed job.

| Completed jobs | Retained records | Active jobs | Retained specs | Lua memory |
|---:|---:|---:|---:|---:|
| 1,000 | 1,000 | 0 | 0 | 12,115.4 KiB |
| 3,000 | 3,000 | 0 | 0 | 13,992.2 KiB |

These are process-wide Lua memory readings after collection, not an exact object-size measurement.
The retained-record count is the direct evidence.
This is not a claim that completed jobs retain their full input or output payloads.

Cleanup and shutdown also iterate this growing history.

**Smallest correction:** retain terminal status on caller-owned handles, or keep a bounded completion history.
Remove completed records from the active pool. Preserve the public status contract while doing so.

### 5. P2: directory watching confuses name prefixes with ancestry

**Evidence: reproduced through `DirWatch:watch` and `DirWatch:check`.**

[`DirWatch:watch`](../data/core/dirwatch.lua), around line 80, uses raw string prefixes for the single-root backend.
It treats `notes-extra` as a child of `notes`.

The probe watched both sibling directories and changed one file in each.
The change under `notes` arrived. The change under `notes-extra` did not arrive within five seconds.
The positive control rules out a completely inactive monitor.

This affects callers that share one `DirWatch` across such roots.
It does not prove that a normal single-root Project watcher misses those directories.

**Smallest correction:** use normalized, path-component-aware ancestry checks.
Handle unrelated filesystem roots explicitly instead of repeatedly taking parents until a string prefix matches.

### 6. P2: bracket navigation counts string contents as syntax

**Evidence: reproduced through the registered navigation command.**

[`get_matching_bracket`](../data/plugins/bracketmatch.lua), around line 66, excludes comments but not strings.
The enclosing-bracket search uses the same assumption.

For Lua `print(")")`, navigation from column 6 stopped at column 8, inside the string.
The matching call delimiter is at column 10.

The search also scans individual bytes and repeatedly obtains token information.
Command navigation can scan without a finite line limit. The performance impact needs a separate measurement.

**Smallest correction:** use syntax-aware delimiter eligibility, with language-specific handling where strings contain interpolation.
Do not fix this with a universal quote-character counter.

## Measured blocking and scaling

### 7. P2: large-file opening still blocks the Editor

**Evidence: measured and source-confirmed.**

[`Buffer:load`](../data/core/buffer/init.lua), around line 289, reads the file and constructs the Buffer synchronously.
Moving later parsing to a worker does not move this work.

The existing `file-open-huge` scenario opens 500,000 lines:

- Command dispatch: **451.699 ms**.
- Action completion: **540.311 ms**.
- Instrumented draw: **84.685 ms** in its recorded frame.

Dispatch time is directly relevant to blocked input. These numbers are not display scanout latency.
The first draw also needs investigation; moving only the read would leave that cost.

**Next change:** measure the existing file-open stages, then move or split the dominant preparation work.
Keep Buffer identity, encoding, and stale-result checks intact.
Do not start with a new storage model unless those measurements require it.

### 8. P2: small edits still perform work proportional to Buffer size

**Evidence: measured for plain Buffers; source-confirmed for snapshot preparation.**

[`line_offsets_for`](../data/core/buffer/init.lua), around line 1573, scans the line array.
Normal edit processing uses whole-Buffer offset construction.

The probe applied 25 single-character edits with language services disabled:

| Buffer lines | Median edit | Maximum edit |
|---:|---:|---:|
| 10,000 | 0.227 ms | 0.816 ms |
| 100,000 | 0.857 ms | 1.880 ms |
| 500,000 | 3.954 ms | 4.579 ms |

This isolates Buffer work. It excludes rendering, shell presentation, and language-service costs.
The result does not justify rewriting ordinary small-file editing.

Other whole-source preparation remains:

- [`Tree-sitter scheduling`](../data/core/treesitter/init.lua) constructs a native snapshot before worker parsing.
- [`snapshot.c`](../src/treesitter/snapshot.c) allocates source bytes and line arrays, then copies all lines.
- [`Markdown model`](../data/core/markdown/model.lua) builds source text for parse work.
- [`Markdown table indexing`](../data/core/markdown/tables.lua), `source_index`, scans source lines again after revision changes.
- [`Background save`](../data/core/buffer/init.lua), `save_async`, first concatenates Buffer lines on the UI thread.
- [`Untitled recovery`](../data/plugins/untitled_recovery.lua) also constructs complete text and persists recovery data.

Tree-sitter coalesces pending requests. That safeguard reduces repeated work but does not make snapshot construction free.

**Next change:** reuse revision-scoped data and avoid duplicate full scans where measurements show a material cost.
Keep the first change in Lua unless evidence and user approval justify a native change.

### Other scenario results

These runs used the existing D3D11 private-desktop harness.
Each scenario had one unprofiled run and one instrumented run. These are diagnostic samples, not a statistical baseline.

| Scenario | Workload | Action completion | Interpretation |
|---|---|---:|---|
| Long-line edit | 32 lines, 65,536 bytes per line | Insert median 5.583 ms; max 13.377 ms | This fixture did not show a severe recurring stall. |
| Multicaret edit | 4,000 lines, 1,024 carets | Insert median 18.643 ms; max 22.501 ms | Material cost under heavy multicaret use. |
| First file search | 10,000 files | 863.728 ms | Dispatch was only 5.386 ms; most time was readiness work. |
| Later file searches | Same index, seven queries | Median 14.210 ms; max 16.093 ms | Warm search was much faster. |

The search scenario also recorded one 42.981 ms frame.
It needs stage attribution before blaming search scoring or the renderer.

The runner used `--report-only`. Its `PASS` result does not mean all budgets passed.
It reported 18 absolute budget flags.

## Source-confirmed limits not measured here

### 9. P2: some command paths still do blocking work on the UI thread

[`FileTreeView:apply_plan`](../data/plugins/filetree/init.lua) performs recursive copying and permanent deletion synchronously.
A large directory, slow disk, or remote path can block interaction.

[`document_format.run`](../data/plugins/document_format.lua) calls `process.start` inside `core.add_thread`.
That is a UI-thread coroutine, not a worker thread.
Process startup remains blocking. Its five-second completion timer starts after input delivery.
The stream wrapper does yield during writes; this audit does not claim it drops partial writes.

Safe file saving has genuine protections, including checked I/O, backups, and guarded replacement.
Large eligible autosaves already use background preparation.
Special cases still use synchronous handling: links, encoding conversion, and files that require identity-preserving writes.

**Next change:** move suitable operations through the existing worker infrastructure.
Do not weaken safe-save behavior to make a timing number smaller.

### 10. P2: image limits constrain entries, not decoded memory

[`ImageView:load`](../data/core/imageview.lua) and [`Markdown images`](../data/core/markdown/images.lua) decode images synchronously.
[`canvas.load_image`](../src/api/canvas.c) calls SDL_image directly.
ImageView reduces large display textures only after decoding the full image.

The Markdown cache targets 256 assets, but cannot evict loading or subscribed entries.
That is not a strict memory bound. Encoded-byte limits do not bound decoded pixel memory.

The separate `asset_request_keys` map also grows until `clear_assets`; asset eviction does not prune its entries.

**Next change:** measure large-image decode time and memory, then set decoded-pixel and byte budgets.
Bound request-key retention with asset lifetime. Preserve visible-image ownership.

### 11. P2: dev update failure can leave the installation incomplete

[`prepare-dev-update.ps1`](../scripts/prepare-dev-update.ps1) moves the executable and ConPTY files out of the live installation.
[`update-anvil-dev-build.bat`](../update-anvil-dev-build.bat) then removes data junctions and runs installation.
It exits immediately if installation fails. There is no restoration path for those earlier changes.

The cleanup can delete retired files that no running host locks.
Thus, the retired directory is not a reliable rollback copy.

This was inspected without running a destructive update experiment.
The script correctly builds before shutdown and does not force-close an editor that refuses to exit.
Those safeguards should stay.

**Smallest correction:** stage installation before changing the live layout, or retain a rollback set until success.
Restore junctions on failure. Test failure after retirement and during installation in a disposable app folder.

The script also compares process paths after removing the drive letter.
That assumes the supported `C:` and `D:` layouts identify the same installation.
Use resolved identity if that assumption stops being true.

### 12. P2: the active Lua log session has no total size bound

[`SessionLog:_roll`](../data/core/session_log.lua) creates another part at the per-file limit.
Pruning protects every part belonging to the current session.
The total-byte target therefore does not bound a long-running active session.

This differs from native diagnostics, which keep a bounded set of parts.
A high-volume Lua log session can continue growing despite the apparent 100 MiB total target.

**Smallest correction:** define retention for older parts of an active session.
Keep recent diagnostics and explicit truncation information. Do not silently disable useful diagnostics.

## Risks that need a workload before promotion

| Area | Current limit or assumption | Focused next check |
|---|---|---|
| Worker submission and delivery | General channels do not provide the same bounded protocol as process streaming. A drain budget cannot preempt one large callback. | Flood a real producer; measure queued bytes, callback maximum, and cancellation recovery. |
| Native worker shutdown | `src/worker_pool.c` joins workers without a deadline. Cancellation depends on job progress. | Cancel during slow filesystem work; trace the blocked operation before changing lifetime rules. |
| Captured subprocesses | `process_capture` bounds output and checks cancellation, but has no general elapsed-time deadline. | Stall a child; verify callers cancel it and the named pool stays usable. |
| Fuzzy file search | Each asynchronous search starts a native thread. Releasing the task does not stop already running search work. | Submit rapid queries on a much larger index; measure concurrent work and retained indexes. |
| Terminal output | Each native update has a 128 KiB parse budget, not a time budget. Several loaded sessions can multiply cost. | Flood multiple sessions with expensive VT sequences; measure frame time and backlog. |
| Regex search | PCRE2 calls use default limits, not an Editor-specific time budget. Defaults are not unlimited. | Run costly valid patterns against long lines; distinguish errors from UI stalls. |
| Tabular preview | Parsing yields, but model construction and final row normalization can still scale with all cells. | Measure wide, sparse CSV data and result application separately. |
| Standalone runtime cache | Extraction reuses a complete build-specific runtime; older build directories have no general eviction policy here. | Measure disk growth across upgrades; retain files used by running hosts. |
| Logging I/O | Buffered writes, flushes, and pruning still run in caller context. | Trace input-heavy sessions on slow storage before introducing another queue. |
| Shell surface synchronization | Presentation readiness no longer blocks event collection, but surface acquisition and GPU failure paths still need bounded waits. | Reuse focused resize, surface-loss, and device-failure probes. Do not disable vsync as a substitute. |

Do not fix these by adding arbitrary threads or detaching workers that still own shared memory.
Use measurements to choose the smallest change with safe lifetime rules.

## Coverage and safeguards retained

| Essential area | What this audit checked | Important safeguard or remaining boundary |
|---|---|---|
| Shell input and presentation | Event collection, readiness waits, surface composition, Window teardown | One-shot presentation readiness and wait cleanup address the earlier blocking design. No new shell defect was reproduced. |
| Hosted transport | Pipe framing, surface ownership, disconnect and child lifecycle | Separate transport and application lifetimes matter. This was source inspection, not hostile IPC testing. |
| Terminal Sessions | Background startup, prepared sessions, output queues, snapshots, detach and shutdown | Bounded queues and backpressure exist. Slow client output can detach without killing the shell. |
| Prepared Terminal Sessions | Matching, activation, discard, hidden-Project cleanup | Preparation is bounded to one unused session per visible Selected Project. It is not free memory or profile execution. |
| Worker infrastructure | Lua/native submission, completion, cancellation, result drain, shutdown | Real workers exist. Specs are released and stale results are checked; completed Lua records remain. |
| Processes and Git | Capture/stream workers, output handling, cancellation | Named pools keep recurring Git work off the UI thread. Streaming uses explicit backpressure. |
| Buffer editing | Offset construction, batched edits, plain-Buffer timing | Large multicaret edits use batches. Whole-Buffer preparation remains. |
| Save and autosave | Atomic replacement, backups, conflict guards, asynchronous preparation | Do not replace these with an unchecked direct write. Workspace failure tracking is a separate defect. |
| Recovery and Workspace | Recovery snapshots, storage errors, save deduplication, restore data | Recovery exists; whole-text persistence and false successful-save caching need attention. |
| File Tree and paths | Copy, move, trash, permanent delete, recursive traversal | Default Windows trash avoids the unsafe recursive helper. Copy failure handling is still incorrect. |
| Filesystem watching | Backend selection, precise events, overflow/rescan, multiple watched roots | Overflow reconciliation exists. Unicode native-watch setup passed on this machine. Prefix siblings failed. |
| Project and symbol indexes | Worker scans, generation checks, native submission bounds | Directory scanning already avoids symlink traversal. Extremely large submissions can exceed a reported bound. |
| File search | Native asynchronous index/search, cold and warm actions | Search is not wholly synchronous. Cold readiness and occasional frames need separate attribution. |
| Tree-sitter and autocomplete | Snapshot preparation, parse coalescing, token/symbol work | Worker parsing and yielded symbol scanning exist. UI-side snapshots and individual long operations remain. |
| Markdown | Parse/model work, live rendering, table source indexing, vault updates | Shared Project watching and cancelled inactive rebuilds avoid some duplicate work. Full-source preparation remains. |
| Images and tabular data | Decode, texture reduction, asset lifetime, yielded parsing | Animated images stream frames. Static decode and decoded-memory budgets still need work. |
| Packaging and update | Embedded extraction, completion marker, runtime reuse, dev update ordering | Extraction has staging and completion checks. Dev installation lacks equivalent rollback. |
| Diagnostics | Session rotation, native diagnostics, shutdown timing | Useful evidence exists. Active Lua-session retention is not bounded by the total-byte target. |

## Recommended order

1. Fix junction deletion, incomplete copies, and Workspace save failure tracking.
2. Fix completed-job retention, watcher path boundaries, and bracket correctness.
3. Split measured large-file opening work. Measure first draw separately.
4. Remove measured duplicate full-source preparation on editing paths.
5. Bound image memory and active-session log growth. Add dev update rollback.
6. Run the targeted cancellation, terminal-load, and queue-growth experiments before broader changes.

Keep one regression case per durable behavior. Run it red, apply the smallest fix, then run it green.
The probes below provide the red cases. This audit deliberately did not implement fixes.

## Reproduction and artifacts

Diagnostic probes live in [`tools/audit/essential`](../tools/audit/essential/README.md).
They are outside normal test discovery because five assertions currently demonstrate known defects.
The worker-retention and edit-timing probes print measurements rather than pretending their current state is correct.

Run from the repository root:

```sh
PATH=/c/msys64/mingw64/bin:$PATH PYTHONIOENCODING=utf-8 ANVIL_TEST_JOBS=1 \
  /c/msys64/mingw64/bin/meson.exe test -C build-windows-x86_64 \
  anvil:lua-runtime --print-errorlogs \
  --test-args "$(pwd -W)/tools/audit/essential"
```

Baseline result: **8 probes; 3 passed, 5 failed** for the documented defects.
The positive controls included accepted Unicode watch setup and an observed change in the first watched sibling.
LuaJIT syntax validation passed for all four probe files.

Performance command:

```sh
python tools/run_render_perf_gate.py \
  --scenario long-line-edit --scenario multi-caret-edit \
  --scenario file-open-huge --scenario fuzzy-files-large \
  --runs 1 --metrics-runs 1 --max-runs 1 --actions 8 \
  --warmup-frames 8 --frames 24 --no-build --report-only
```

Local, untracked performance artifacts:
`tools/perf-results/render-gate/20261023_142533_79472/report.{md,json,html}`.
The audit did not use interactive-window captures or the daily portable user's state.
