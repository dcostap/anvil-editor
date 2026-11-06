# Markdown picker preview performance

## Current behavior

Rendered Fuzzy Searcher previews keep the complete Buffer and Markdown parse. They measure visible text instead of preparing every line. A jump prepares the destination with its full Markdown context. Unknown lines have provisional heights, so the scrollbar range can change as more text appears.

Read-only Buffers parse on the worker. They use the vault's disk entries without editable overlays. Read-only Markdown Views share sized fonts through the existing style cache. Closing a View cancels its pending wrap and permits no new wrap work during feature release.

The Markdown preview setting remains off by default. This change does not retain Editors, add a file cache, or change normal editable Markdown layout.

## Measurements

The `preview` scenario suite uses real picker commands and static results. It checks the selected target line's committed Markdown draw. Parser readiness alone does not complete an action.

These Windows D3D11 runs used a private desktop, an uncapped frame loop, and the existing 4 GiB process-tree limit. Garbage collection stayed enabled. The fixtures contain prose, headings, lists, inline styles, and links. They contain no images or fenced code. Disk caches were warm. Search ranking, native key repeat, and display latency are outside this measurement.

The following comparison uses one repeated baseline run and two changed runs. Values are the runner's summaries, not pooled percentiles.

| Case | First Markdown draw p50, before → after | Frame work p95, before → after | Maximum frame work, before → after | Lua heap MiB, before → after |
| --- | ---: | ---: | ---: | ---: |
| New file, 8 sections | 88.0 → 53.6 ms | 78.34 → 26.52 ms | 104.40 → 36.60 ms | 18.2 → 18.1 |
| New file, 180 sections | 1124.0 → 113.9 ms | 28.41 → 34.07 ms | 80.42 → 54.97 ms | 31.6 → 20.0 |
| Same file, different location | 30.5 → 31.0 ms | 10.45 → 15.01 ms | 10.62 → 19.70 ms | 18.1 → 18.0 |
| Twelve-command burst | 1236.3 → 474.7 ms | 31.19 → 25.88 ms | 61.78 → 38.82 ms | 25.0 → 19.4 |
| Source-text control | 33.4 → 23.9 ms | 10.85 → 9.77 ms | 16.48 → 16.09 ms | 15.6 → 15.8 |

Return draws changed from 104.1 to 61.7 ms for small files and from 1107.1 to 115.3 ms for large files. The tracked Lua file calls changed from 44–48 to zero during cross-file navigation. This counter does not cover all native disk access.

The large-file p95 frame cost increased, despite the shorter wait and lower maximum. Each action now spans about eight redraws instead of about seventy. The shorter measurement contains fewer low-cost waiting frames. Same-file navigation also includes newly visible layout work that the baseline prepared during setup. These are accepted costs of avoiding whole-note preparation, not claims that every frame became faster.

Machine load varied. The first baseline gave 480 ms and 3918 ms for small and large first visits. Do not infer a fixed speed ratio. Its same-file readiness check also timed out: a search highlight intentionally revealed the syntax marker. The corrected scene uses file locations without highlights. The comparison above uses that corrected scene on both versions.

A diagnostic run after visible-only layout found 189 of 1036 measured stack samples at the two font-copy sites. Sharing the existing style cache reduced small-preview p95 frame work from 52–58 ms to about 27 ms. This required no retained Editor cache.

## Checks and limits

Four targeted regressions failed before their fixes:

- A closed wrapped View requested presentation after feature release.
- Closing a read-only preview accessed the disk through vault overlays.
- A View prepared unseen lines instead of leaving them provisional.
- Pre-draw settling parsed a read-only Buffer on the UI thread.

All four passed after the fixes. The focused checks also cover distant Markdown block context, matched syntax, live resize, wrapped publication, inline positions, and vault behavior.

The frame budgets still fail. Large-file first draws remain above 100 ms. The burst includes twelve commands at least 20 ms apart; its action budget is 500 ms. Reports recorded before that budget correction show the ordinary 100 ms limit, which the command schedule alone cannot meet.

This is a bounded performance improvement, not instant rendering. Images, long tables, fenced-code highlighting, and cold font creation still need separate measurements. The remaining visible layout pipeline is a C-port candidate. No broader port belongs in this change.

## Local artifacts

Artifacts are under `tools/perf-results/markdown-picker-preview-20261106/scenarios` in the main checkout:

- `20261106-154020`: first baseline; invalid same-file readiness check.
- `20261106-154859`: visible-only layout, before shared fonts.
- `20261106-155044`: diagnostic stacks for remaining font work.
- `20261106-155205`: unchanged baseline with the corrected scene.
- `20261106-155425`: two runs with shared fonts.
- `20261106-160126`: final run after rebasing onto `7014d100`; all scenarios completed, but frame budgets still failed.

The baseline product revision was `2d5ef9b5`. Both versions used the worktree's newly built native executable. The repeated baseline used its frozen application data with only the corrected scene copied in. The default launcher, private desktop, and memory limit stayed unchanged.

After the rebase, the native build and all eight focused test files passed again. Small and large first-draw medians were 48.7 and 105.2 ms. Their frame-work p95 values were 25.47 and 26.27 ms.
