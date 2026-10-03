# Font rendering checks

## Causes and changes

Glyph atlas growth uploaded complete pages after individual glyph additions.
The D3D11 renderer now collects additions until the quad batch ends.
It initializes each texture completely, then uploads only added rows.
Image and canvas uploads keep their existing order.

Draws did not retain shaping results unless width queries had filled the cache.
The 512-entry cache also lost the Unicode working set.
Width, layout, and draw calls now share one bounded shaped-run cache.
Storage grows from 64 to 4096 entries per font.
Hash buckets speed lookup. Linked LRU entries remove full-cache eviction scans.
Font changes clear the cache.

The first width query after drawing reads the established glyph bearing.
This preserves clipped italic overhang.

## Unicode measurements

The supplied Unicode specimen used 600 measured scroll frames and eight warmup frames.
The final comparison used three timing runs and three metrics runs.
Both executables ran through the existing private-desktop harness.
The paired reference executable contains none of these native changes.

| Measurement | Original | Fixed |
|---|---:|---:|
| Frame median, paired replay | 18.060 ms | 4.741 ms |
| Frame p95, paired replay | 23.046 ms | 6.901 ms |
| Renderer end median, paired replay | 16.117 ms | 3.018 ms |
| Draw emission p95, paired replay | 2.955 ms | 2.809 ms |
| Upload bytes, 600-frame captured runs | 3,244,574,592 | 45,064,464 |
| Upload count, 600-frame captured runs | 24,040 | 969 |
| Draw-time HarfBuzz shapes, captured runs | 883,657 | 0 |

Upload totals compare the preserved original capture with the median final capture.
They do not add overlapping profiler scopes.
The median frame cost fell by about 74%. Upload bytes fell by about 99%.

## Checks

- The unchanged executable failed the known-bounds shaping reuse test.
- The fixed executable passed that test without a prior width query.
- An intermediate change failed the clipped italic overhang test. The final change passed.
- The original executable passed the italic test, which confirms preserved behavior.
- Layout tests cover cache eviction and resize through public layout results.
- Focused renderer, transform, text layout, and native raster tests passed.
- Harness and diagnostics tests passed: 35 tests.
- The full D3D11 performance suite passed against the preserved reference.
- The Unicode startup, scroll, caret, and soak suite passed.
- Seven software-renderer scenes matched original pixels exactly.
- The glyph growth scene passed on both renderers.
- Its complete D3D11 image matched the original executable exactly.
- Image filtering passed on both original and fixed D3D11 executables.

The image fixture previously blended against wallpaper instead of white.
It failed on the original executable too. It now draws an opaque white background.
The glyph fixture uses high contrast to avoid blend-rounding boundaries.
Golden comparisons and consecutive frame captures still require exact pixels.
Only the independent cold/warm column comparison permits one channel unit.

## Limits

The broad editor matrix did not receive full acceptance.
Large wrapped-code runs showed different text-command counts despite identical glyph counts and final pixels.
Longer warmup also changed the first action capture.
Markdown scroll checks intermittently differed at one pixel by one channel unit.
The original baseline had shown that same Markdown pixel instability.
The original executable also produced inconclusive wrapped-code timing against itself.
It reproduced both changed action captures without any native fixes.
Those original captures matched the corresponding fixed captures exactly.
Do not treat these findings as a clean broad-editor PASS.

Cold font work can still exceed one frame.
The stress scene creates many cold font groups; its remaining cost is not a zero-stall guarantee.
These checks do not prove every font, document, or renderer state.

## Local evidence

Reports and captured runtimes remain under the ignored `tools/perf-results/render-gate` directory.

- Full D3D11: `20261002_145815_12372/report.html`
- Unicode comparison: `20261002_150653_17972/report.html`
- Software pixel comparison: `20261002_153049_30168/report.html`
- Broad editor matrix: `20261002_151447_24624/report.html`
- Controlled glyph growth: `20261002_161311_29636/report.html`
- Image filtering: `20261002_161427_13892/report.html`
- Unchanged wrapped-code self-check: `20261002_161556_12320/report.html`
- Unchanged long-warmup code capture: `20261002_161751_4700/report.html`
- Unchanged Markdown scroll capture: `20261002_161842_20120/report.html`
