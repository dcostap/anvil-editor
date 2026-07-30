# Line Wrapping Performance

## Cost model

Anvil keeps an exact whole-Document map from Document lines to Wrapped Visual Rows. A cold reconstruction therefore has a lower bound of:

- one visit per Document line;
- one width/wrap calculation per line that cannot be reused;
- one stored pair per produced Wrapped Visual Row.

The current flat representation provides constant-time visual-row lookup, but rebuilding is `O(document lines + produced rows)`. A row-count-changing edit also splices the flat row array and shifts the first-row index of every later Document line, making that part of an early edit proportional to the remaining Document.

Sliced reconstruction bounds main-thread latency but does not reduce total CPU work. Preventing, reusing, or narrowing reconstruction is more valuable than merely making it asynchronous.

## Wrapping branches

The ordinary non-tokenized path has specialized scans for:

- plain ASCII letter wrapping;
- plain ASCII word wrapping;
- ASCII with tabs;
- long unbroken words;
- UTF-8 fallback with per-codepoint width caching.

A source-preserving rendered line can use the renderer's native text layout and native wrap scan. Mixed hidden/widget/font fragments use a monotonic rendered-column cursor. Tokenization-dependent wrapping additionally requires syntax tokenization and syntax-font metrics.

The fast ASCII scans are already efficient for very long lines. Whole-Document overhead on many ordinary short lines and repeated reconstruction are more important in typical source files.

## Permanent benchmark

`tests/lua/benchmarks/linewrap.lua` reports:

- a 1.58 MB, 20,001-line ordinary source reconstruction;
- approximately 1 MB single-line ASCII wrapping;
- a large single-line UTF-8 reconstruction;
- a 1.05 MB, 5,001-line repeated UTF-8 reconstruction;
- row-count-changing edits at the start and end of a 20,000-line Document;
- a 100-range non-structural edit across a 20,000-line Document.

Run it with:

```sh
meson test -C build-windows-x86_64 anvil:lua-ui \
  --test-args tests/lua/benchmarks/linewrap.lua --print-errorlogs
```

Representative medians from the optimization pass (milliseconds):

| Case | Before | After |
|---|---:|---:|
| 1.58 MB / 20,001 ordinary lines | 72.250 | 34.684 |
| 1.09 MB single ASCII line | 7.088 | 6.161 |
| 624 KB single UTF-8 line | 26.990 | 20.971 |
| Row-changing edit at line 1 / 20,000 | 17.093 | 14.363 |
| Row-changing edit at line 20,000 / 20,000 | 11.203 | 9.673 |
| 100-range non-structural edit / 20,000 lines | 44.342 | 6.498 |

These values are diagnostics, not pass/fail thresholds; process startup, JIT state, and machine load cause variation.

Performance recordings intentionally collect branch, byte, split, and slow-line details for each computed line. Their absolute reconstruction time therefore includes diagnostic overhead. Use recordings to attribute calls and branches, and the focused benchmark to compare normal non-recording throughput.

## Optimizations in this pass

Cold ordinary reconstruction previously paid several avoidable per-line costs:

- detailed performance-counter dispatch even when no performance recording was active;
- repeated default-cell, tab, and configured continuation-indent measurements;
- a second retrieval of the same line text in the non-tokenized iterator;
- a line-render lookup on every line even when the Document View had no line-render providers.

Reconstruction now creates one immutable measurement context and shares it across all lines (and all slices of a sliced reconstruction). It caches font cell/continuation measurements, the Document indent size, wrapping configuration, and whether rendered-line lookup is relevant. Inactive detailed diagnostics return directly. The same line string is reused by the plain token iterator.

Snapshotting wrapping configuration in the context also prevents one sliced reconstruction from mixing settings if global wrapping configuration changes between slices.

Before each slice and commit, asynchronous reconstruction now revalidates the complete wrapping signature, including font generations, surface scale, relevant syntax fonts, the configured continuation-indent size, line-render provider presence, and targeted line-render invalidations. Stale settings work is cancelled, while line-render invalidation restarts reconstruction from fresh presentation data instead of publishing mixed or obsolete geometry. Diagnostic activation is refreshed per slice, and large/slow-line details remain available for recordings performed outside normal frame statistics.

The context also shares measured UTF-8 codepoint widths across Document lines. In the focused repeated-UTF-8 case this reduced the median from 61.694 ms to 49.851 ms (about 19%) compared with the previous per-line cache.

Plain overflowing UTF-8 lines now use `font:wrap_text(...)`, a direct native
scan that decodes, measures, and emits byte break offsets in one pass. Unlike
`font:text_layout()`, it does not copy the complete string or allocate and
retain byte-offset and advance arrays. It preserves standalone shaping for
non-ASCII characters, including zero-width combining marks, while accepting
the fixed ASCII-cell and tab advances used by ordinary wrapping. The native
entry point receives the source length, clamps its scan range, and consumes
malformed or truncated UTF-8 safely as replacement characters.

The migration also fixed word-wrap width accounting that added the overflowing
character twice after moving text following the previous space to a new row.
Both the tokenized UTF-8 fallback and the ASCII tab-and-space fallback had the
same defect.

Representative focused medians before and after the native scan:

| Case | Before native scan | Native scan |
|---|---:|---:|
| 624 KB single UTF-8 line | 20.645 ms | 2.691 ms |
| 1.05 MB / 5,001 repeated UTF-8 lines | 49.633 ms | 27.393 ms |

The single-line case is about 7.7 times faster and the repeated-line
reconstruction is about 45% faster. The latter retains per-line and produced-row
costs that cannot move into the font scan. Plain ASCII continues to use its
existing specialized Lua paths.

An attempted scratch-table reuse for per-line split results did not show a repeatable gain under LuaJIT and was not retained.

Multi-range transactions previously forced a full-Document reconstruction even
when every edit stayed within its existing Document line. Document Views
without line-render providers now recompute only the distinct affected lines
and rebuild the flat row map by copying unaffected Wrapped Visual Rows without remeasurement. The path
supports several edits on the same line and tokenization-dependent wrapping.
Transactions that insert or remove Document lines, stale wrapping caches,
changed wrapping settings, and views with line-render providers retain the
conservative full-reconstruction fallback.

The 100-range benchmark measures the complete `Doc:apply_edits()` transaction,
not only wrapping. Its representative median improved from 44.342 ms to
6.498 ms (about 85% less elapsed time). The result is workload-specific: the
row map still requires one linear copy, while text measurement scales with the
number of distinct affected lines rather than the whole Document.

## Highest-value follow-ups

1. **Eliminate unnecessary reconstructions.** Attribute every full reconstruction to content, width, font, settings, or rendered-line invalidation. Transient views should not enable wrapping when they do not need exact Wrapped Visual Row geometry.
2. **Reuse width-only work.** On widening, every previously single-row line can remain single-row without text measurement. With cached unwrapped widths, narrowing can also skip lines known to fit.
3. **Replace the monolithic row map if edit scaling matters.** Per-line break arrays plus a prefix-sum/Fenwick or chunked row index would make same-line row-count changes logarithmic instead of moving and renumbering the entire suffix. The tradeoff is logarithmic visual-row-to-line lookup and a larger refactor of geometry consumers.
4. **Share equivalent standard layouts.** Document Views with the same Document, font, width, and plain wrapping settings could share immutable break data. Render-provider layouts must remain view-specific.
5. **Move remaining expensive scans native only where profiles justify it.** Plain non-tokenized UTF-8 is now native; the remaining candidates are tokenization-dependent and mixed rendered-fragment lines. Plain long ASCII is already fast enough that additional native crossings may not help.
6. **Keep sliced reconstruction for responsiveness.** It should remain a latency mechanism for unavoidable rich whole-Document rebuilds, with cancellation diagnostics used to detect wasted repeated work.
