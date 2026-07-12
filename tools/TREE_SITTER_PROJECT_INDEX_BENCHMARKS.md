# Tree-sitter Project index benchmarks

Run the benchmark with Anvil closed when the build may be refreshed:

```powershell
pwsh -File .\tools\anvil_treesitter_project_index_benchmark.ps1
```

The runner executes `tests/lua/benchmarks/treesitter_project_index.lua` through the isolated Meson Lua-runtime harness. It records a Lua data file under `tools/baselines` by default. Reports are intentionally data, not correctness tests or machine-specific timing assertions.

The default cases are:

- a small mixed-language fixture;
- the Anvil source tree (`-RealRoot` selects another real Project);
- a medium mixed C/C++/Odin/Kotlin synthetic Project;
- a large mixed-language synthetic Project;
- cancellation while Project work is outstanding.

Each completed indexing case records wall time to first observable symbols, final symbols, final usages, and final readiness; cumulative worker-stage elapsed timings; file/byte/capture/record counts; observed Lua heap usage; temporary artifact I/O; native query-cache/parser-reuse/skipped-line-index counters; native batch/snapshot transfer counters; manifest/aggregate/inline UI adoption totals and maxima; and empty/short/selective Project Symbol Search latency. Synthetic cases fail rather than silently recording a baseline if any generated file is skipped.

After each completed case, the benchmark also performs an unchanged single-file targeted refresh and records wall time, files reused, native builder seeding time, native final-snapshot construction time, and UI time spent submitting retired snapshots for asynchronous destruction. This guards the targeted publication path that is not represented by initial full-scan timing alone.

Cancellation measurement covers an active native Project run and verifies terminal cleanup.

Synthetic density and timeout are configurable, for example:

```powershell
pwsh -File .\tools\anvil_treesitter_project_index_benchmark.ps1 `
  -MediumFiles 400 -LargeFiles 2000 -LargeSymbolsPerFile 60 `
  -TimeoutSeconds 300 -ReportPath .\tools\baselines\treesitter-project-index-before.lua
```

Use the same build type, Project inputs, options, and otherwise-idle machine for before/after comparisons. Report medians and p95 from repeated runs when evaluating a migration phase. Do not promote local elapsed-time values into ordinary test assertions.

The Phase 4 native-query baseline is `tools/baselines/treesitter-project-index-native-queries.lua`. It measures bounded native symbol/usage queries after publication without materializing Project-wide record tables in Lua or writing query artifacts.

The Phase 5 native-orchestration baseline is `tools/baselines/treesitter-project-index-native-orchestration.lua`. Full scans use one Lua-visible native run handle with native enumeration, cost-balanced parsing lanes, coalesced progress, and direct snapshot publication.

The final Phase 6–7 baseline is `tools/baselines/treesitter-project-index-native-final.lua`. Targeted refreshes reuse immutable native file records, scoped deletion happens natively, query filtering uses bounded native path rules, and superseded Lua artifact/shard/query-worker machinery is removed.

`-TimeoutSeconds` is a per-indexing-case deadline. The runner raises Meson's overall timeout multiplier when necessary so the configured cases can use their full deadlines.

The benchmark currently cannot obtain native peak working-set, actual per-stage CPU time, or Lua GC pause duration from Anvil's public runtime APIs. It reports periodically observed Lua heap size and cumulative worker-stage elapsed time instead; parallel worker elapsed totals can exceed wall time. Use an external process profiler when native peak memory, CPU attribution, or GC pause distributions are required.
