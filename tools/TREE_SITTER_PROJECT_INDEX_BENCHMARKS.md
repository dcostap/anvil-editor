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

Each completed indexing case records wall time to first observable symbols, final symbols, final usages, and final readiness; cumulative worker-stage elapsed timings; file/byte/capture/record counts; observed Lua heap usage; temporary artifact I/O; native query-cache/parser-reuse/skipped-line-index counters; native batch/snapshot transfer counters; manifest/aggregate/inline UI adoption totals and maxima; and empty/short/selective Project Symbol Search latency. Synthetic cases fail rather than silently recording a baseline if any generated file is skipped. Cancellation cases cover an active Project run plus dedicated parsing, aggregation, and query jobs.

Synthetic density and timeout are configurable, for example:

```powershell
pwsh -File .\tools\anvil_treesitter_project_index_benchmark.ps1 `
  -MediumFiles 400 -LargeFiles 2000 -LargeSymbolsPerFile 60 `
  -TimeoutSeconds 300 -ReportPath .\tools\baselines\treesitter-project-index-before.lua
```

Use the same build type, Project inputs, options, and otherwise-idle machine for before/after comparisons. Report medians and p95 from repeated runs when evaluating a migration phase. Do not promote local elapsed-time values into ordinary test assertions.

`-TimeoutSeconds` is a per-indexing-case deadline. The runner raises Meson's overall timeout multiplier when necessary so the configured cases can use their full deadlines.

The benchmark currently cannot obtain native peak working-set, actual per-stage CPU time, or Lua GC pause duration from Anvil's public runtime APIs. It reports periodically observed Lua heap size and cumulative worker-stage elapsed time instead; parallel worker elapsed totals can exceed wall time. Use an external process profiler when native peak memory, CPU attribution, or GC pause distributions are required.
