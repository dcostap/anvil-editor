local common = require "core.common"
local registry = require "core.treesitter.registry"
local symbol_index = require "core.treesitter.symbol_index"
local test = require "core.test"
local worker_pool = require "core.worker_pool"

local report = {
  benchmark = "treesitter-project-index",
  recorded_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  cases = {},
}

local function env_number(name, default)
  local value = tonumber(os.getenv(name) or "")
  return value and math.max(1, math.floor(value)) or default
end

local function mkdir(path)
  local ok, err = common.mkdirp(path)
  test.ok(ok, err)
  return path
end

local function write_file(path, text)
  local fp = test.not_nil(io.open(path, "wb"))
  fp:write(text)
  fp:close()
end

local generators = {
  c = function(file, symbols)
    local out = {}
    for i = 1, symbols do
      out[#out + 1] = string.format("int %s_symbol_%03d(int value) { return value + %d; }\n", file, i, i)
    end
    return table.concat(out)
  end,
  cpp = function(file, symbols)
    local out = { string.format("namespace %s_space {\n", file) }
    for i = 1, symbols do
      out[#out + 1] = string.format("class Box%03d { public: int value() const { return %d; } };\n", i, i)
    end
    out[#out + 1] = "}\n"
    return table.concat(out)
  end,
  odin = function(file, symbols)
    local out = { "package benchmark\n\n" }
    for i = 1, symbols do
      out[#out + 1] = string.format("%s_symbol_%03d :: proc(value: int) -> int { return value + %d }\n", file, i, i)
    end
    return table.concat(out)
  end,
  kotlin = function(file, symbols)
    local out = { "package benchmark\n\n" }
    for i = 1, symbols do
      out[#out + 1] = string.format("fun %sSymbol%03d(value: Int): Int = value + %d\n", file, i, i)
    end
    return table.concat(out)
  end,
}

local extensions = { c = ".c", cpp = ".cpp", odin = ".odin", kotlin = ".kt" }

local function synthetic_project(name, file_count, symbols_per_file)
  local root = USERDIR .. PATHSEP .. "treesitter-project-index-benchmark-" .. name
  common.rm(root, true)
  mkdir(root)
  local ids = { "c", "cpp", "odin", "kotlin" }
  for i = 1, file_count do
    local id = ids[((i - 1) % #ids) + 1]
    local stem = string.format("bench_%04d", i)
    write_file(root .. PATHSEP .. stem .. extensions[id], generators[id](stem, symbols_per_file))
  end
  return root, true
end

local function count_files(path)
  local count = 0
  local function walk(dir)
    for _, name in ipairs(system.list_dir(dir) or {}) do
      local child = dir .. PATHSEP .. name
      local info = system.get_file_info(child)
      if info and info.type == "dir" then walk(child)
      elseif info and info.type == "file" then count = count + 1 end
    end
  end
  walk(path)
  return count
end

local function wait_for_scan(root, timeout)
  local deadline = system.get_time() + timeout
  local first_symbols_ms, final_symbols_ms, final_usages_ms
  local peak_lua_kib = collectgarbage("count")
  local status
  repeat
    status = symbol_index.status(root)
    local elapsed_ms = (system.get_time() - (status.started_at or system.get_time())) * 1000
    if not first_symbols_ms then
      local partial = status.native_partial_snapshot
      local partial_ok, partial_summary = pcall(function() return partial and partial:summary() end)
      if #(status.symbols or {}) > 0 or (partial_ok and partial_summary and (partial_summary.symbols or 0) > 0) then
        first_symbols_ms = elapsed_ms
      end
    end
    if not final_symbols_ms and status.symbol_status == "ready" then final_symbols_ms = elapsed_ms end
    if not final_usages_ms and status.usage_status == "ready" then final_usages_ms = elapsed_ms end
    peak_lua_kib = math.max(peak_lua_kib, collectgarbage("count"))
    if status.status == "ready" or status.status == "failed" or status.status == "cancelled" then break end
    coroutine.yield(0.005)
  until system.get_time() >= deadline
  return status, first_symbols_ms, final_symbols_ms, final_usages_ms, peak_lua_kib
end

local function time_symbol_query(root, query, limit)
  local started = system.get_time()
  local results, reason, status = symbol_index.workspace_symbols(query, {
    root = root,
    limit = limit,
    refresh_after_seconds = 0,
    max_sync_query_items = 10000000,
  })
  return {
    ms = (system.get_time() - started) * 1000,
    result_count = #(results or {}),
    reason = reason,
    status = status,
  }
end

local function combined_ui(diagnostics)
  local out = common.merge({}, diagnostics and diagnostics.ui or {})
  for _, phase in pairs(diagnostics and diagnostics.phases or {}) do
    local ui = phase.ui or {}
    for key, value in pairs(ui) do
      if type(value) == "number" then
        if key:match("_max_ms$") then out[key] = math.max(out[key] or 0, value)
        else out[key] = math.max(out[key] or 0, value) end
      end
    end
  end
  return out
end

local function run_case(name, root, remove_after, expected_files)
  symbol_index.reset_for_tests()
  collectgarbage("collect")
  local lua_before_kib = collectgarbage("count")
  local started = system.get_time()
  symbol_index.start_project_indexing({ root = root, reason = "benchmark", refresh_after_seconds = 0 })
  local status, first_symbols_ms, final_symbols_ms, final_usages_ms, peak_lua_kib =
    wait_for_scan(root, env_number("ANVIL_TS_BENCH_TIMEOUT_SECONDS", 120))
  local final_ms = (system.get_time() - started) * 1000
  test.equal(status.status, "ready", status.reason)
  local worker = status.diagnostics and status.diagnostics.worker or {}
  local ui = combined_ui(status.diagnostics)
  if expected_files then test.equal(status.files_indexed, expected_files, "synthetic Project coverage changed") end
  local case_report = {
    name = name,
    root = root,
    files_on_disk = count_files(root),
    files_indexed = status.files_indexed or worker.files_indexed,
    bytes_read = worker.bytes_read,
    symbols = #(status.symbols or {}),
    usages = status.usage_count or 0,
    first_partial_symbols_ms = first_symbols_ms,
    final_symbols_ms = final_symbols_ms or final_ms,
    final_usages_ms = final_usages_ms or final_ms,
    final_ready_ms = final_ms,
    worker_elapsed_stage_ms = {
      total = worker.total_ms,
      read = worker.file_read_ms,
      native = worker.native_total_ms,
      native_batch = worker.native_batch_ms,
      parse = worker.parse_ms,
      native_project_records = worker.native_project_record_ms,
      outline_query = worker.outline_query_ms,
      usage_query = worker.usage_query_ms,
      symbol_records = worker.symbol_record_ms,
      usage_records = worker.usage_record_ms,
      aggregate = worker.aggregate_total_ms,
    },
    captures = { outline = worker.outline_captures, usage = worker.usage_captures },
    records = { symbols = worker.symbols_emitted, usages = worker.usages_emitted },
    native_hot_path = {
      query_cache_hits = worker.query_cache_hits,
      query_cache_misses = worker.query_cache_misses,
      parser_reuses = worker.parser_reuses,
      line_indexes_skipped = worker.line_indexes_skipped,
      native_batch_jobs = worker.native_batch_jobs,
      native_project_files_transferred = worker.native_project_files_transferred,
      native_project_symbol_records = worker.native_project_symbol_records,
      native_project_usage_records = worker.native_project_usage_records,
    },
    temporary_io = {
      index_artifacts = worker.artifacts_sent,
      index_bytes = worker.artifact_bytes,
      query_artifacts = worker.aggregate_query_artifacts_written,
      query_bytes = worker.aggregate_query_artifact_bytes,
    },
    lua_memory_kib = { before = lua_before_kib, peak_observed = peak_lua_kib, after = collectgarbage("count") },
    ui_adoption = {
      manifest_total_ms = ui.manifest_adoption_ms,
      manifest_max_ms = ui.manifest_adoption_max_ms,
      aggregate_total_ms = ui.aggregate_chunk_adoption_ms,
      aggregate_max_ms = ui.aggregate_chunk_adoption_max_ms,
      inline_chunk_total_ms = ui.chunk_adoption_ms,
      inline_chunk_max_ms = ui.chunk_adoption_max_ms,
      chunks = ui.chunks_adopted,
      aggregate_chunks = ui.aggregate_chunks_adopted,
    },
    queries = {
      empty = time_symbol_query(root, "", 200),
      short = time_symbol_query(root, "sym", 200),
      selective = time_symbol_query(root, "bench_0001", 200),
    },
  }
  report.cases[#report.cases + 1] = case_report
  print("treesitter-project-index-benchmark " .. common.serialize(case_report))
  if remove_after then common.rm(root, true) end
end

local function run_cancellation_case()
  local root, remove_after = synthetic_project(
    "cancellation",
    env_number("ANVIL_TS_BENCH_CANCEL_FILES", 400),
    env_number("ANVIL_TS_BENCH_CANCEL_SYMBOLS_PER_FILE", 40)
  )
  symbol_index.reset_for_tests()
  symbol_index.start_project_indexing({
    root = root,
    reason = "benchmark-cancellation",
    refresh_after_seconds = 0,
    batch_files = 1,
    max_running_index_shards = 1,
  })
  local progress_deadline = system.get_time() + 10
  local status
  repeat
    status = symbol_index.status(root)
    if (status.files_scanned or 0) > 0 or #(status.symbols or {}) > 0 then break end
    coroutine.yield(0.001)
  until system.get_time() >= progress_deadline
  local scheduler = status.worker_run and status.worker_run.scheduler
  test.equal(status.status, "indexing", "cancellation fixture completed before cancellation")
  test.ok(scheduler and scheduler:outstanding_count() > 0, "cancellation fixture had no outstanding jobs")
  local started = system.get_time()
  symbol_index.invalidate(root)
  local cancellation_ms
  local cancel_deadline = system.get_time() + 10
  repeat
    status = symbol_index.status(root)
    if scheduler:outstanding_count() == 0 then
      cancellation_ms = (system.get_time() - started) * 1000
      break
    end
    coroutine.yield(0.001)
  until system.get_time() >= cancel_deadline
  test.not_nil(cancellation_ms, "Project cancellation did not drain outstanding jobs")
  report.cancellation = report.cancellation or {}
  report.cancellation.project_run = {
    latency_ms = cancellation_ms,
    final_status = status.status,
    outstanding_jobs = scheduler:outstanding_count(),
  }
  if remove_after then common.rm(root, true) end
end

local function measure_worker_cancellation(stage, spec, delay_seconds)
  local pool = worker_pool.new({ name = "treesitter-project-benchmark-cancel-" .. stage, worker_count = 1 })
  local terminal
  spec.on_cancelled = function() terminal = "cancelled" end
  spec.on_complete = function() terminal = terminal or "complete" end
  spec.on_error = function() terminal = "failed" end
  local handle = test.not_nil(pool:submit(spec))
  coroutine.yield(delay_seconds or 0.01)
  local started = system.get_time()
  test.ok(pool:cancel(handle), stage .. " benchmark job completed before cancellation")
  local deadline = system.get_time() + 15
  repeat
    pool:drain({ max_ms = 5, max_messages = 64 })
    if terminal then break end
    coroutine.yield(0.001)
  until system.get_time() >= deadline
  local status = pool:status(handle)
  local result = {
    latency_ms = terminal and (system.get_time() - started) * 1000 or nil,
    terminal = terminal,
    final_status = status and status.status,
  }
  test.equal(terminal, "cancelled", stage .. " cancellation did not reach a cancelled terminal state")
  pool:shutdown({ cancel_running = true, timeout_ms = 1000 })
  return result
end

local function run_parse_aggregation_and_query_cancellation_cases()
  registry.reload()
  local language = test.not_nil(registry.get("cancel-parse.c", ""))
  local parse_root = USERDIR .. PATHSEP .. "treesitter-project-index-benchmark-cancel-parse"
  common.rm(parse_root, true)
  mkdir(parse_root)
  local parse_path = parse_root .. PATHSEP .. "cancel-parse.c"
  local parse_lines = {}
  for i = 1, env_number("ANVIL_TS_BENCH_CANCEL_PARSE_SYMBOLS", 50000) do
    parse_lines[i] = string.format("int cancel_parse_%06d(int value) { return value + %d; }\n", i, i)
  end
  write_file(parse_path, table.concat(parse_lines))
  report.cancellation = report.cancellation or {}
  report.cancellation.parsing = measure_worker_cancellation("parsing", {
    kind = "treesitter_project_index",
    payload = {
      root = parse_root,
      files = { { path = parse_path, root = parse_root, info = system.get_file_info(parse_path), language_id = language.id } },
      languages = { language },
      include_usages = true,
      max_file_bytes = 32 * 1024 * 1024,
    },
  }, 0.02)
  common.rm(parse_root, true)

  local aggregate_files = {}
  local query_symbols = {}
  for i = 1, env_number("ANVIL_TS_BENCH_CANCEL_AGGREGATE_RECORDS", 50000) do
    local symbol = {
      name = string.format("CancellationSymbol%06d", i),
      search_text = string.format("CancellationSymbol%06d", i),
      path = string.format("cancel/%06d.c", i),
      relpath = string.format("cancel/%06d.c", i),
      start_line = 1,
    }
    aggregate_files[i] = {
      path = symbol.path,
      relpath = symbol.relpath,
      symbols = { symbol },
      usages_by_name = {},
      usage_complete = true,
    }
    query_symbols[i] = symbol
  end
  report.cancellation.aggregation = measure_worker_cancellation("aggregation", {
    kind = "treesitter_project_aggregate",
    payload = { files = aggregate_files, chunk_records = 512 },
  })
  report.cancellation.query = measure_worker_cancellation("query", {
    kind = "treesitter_symbol_query",
    payload = { symbols = query_symbols, query = "symbol49999", limit = 200 },
  })
end

test.describe("Tree-sitter Project index benchmark", function()
  test.test("records fixture, real, synthetic, query, and cancellation baselines", function()
    local small, small_remove = synthetic_project("small", 8, 4)
    run_case("small-mixed-fixture", small, small_remove, 8)

    local real_root = os.getenv("ANVIL_TS_BENCH_REAL_ROOT")
    if real_root and real_root ~= "" and system.get_file_info(real_root) then
      run_case("anvil-source", common.normalize_path(real_root), false)
    end

    local medium, medium_remove = synthetic_project(
      "medium", env_number("ANVIL_TS_BENCH_MEDIUM_FILES", 240),
      env_number("ANVIL_TS_BENCH_MEDIUM_SYMBOLS_PER_FILE", 20)
    )
    run_case("medium-mixed-synthetic", medium, medium_remove, env_number("ANVIL_TS_BENCH_MEDIUM_FILES", 240))

    local large, large_remove = synthetic_project(
      "large", env_number("ANVIL_TS_BENCH_LARGE_FILES", 1000),
      env_number("ANVIL_TS_BENCH_LARGE_SYMBOLS_PER_FILE", 40)
    )
    run_case("large-mixed-synthetic", large, large_remove, env_number("ANVIL_TS_BENCH_LARGE_FILES", 1000))
    run_cancellation_case()
    run_parse_aggregation_and_query_cancellation_cases()

    local report_path = os.getenv("ANVIL_TS_BENCH_REPORT")
    if report_path and report_path ~= "" then
      local fp = test.not_nil(io.open(report_path, "wb"))
      fp:write("return ", common.serialize(report), "\n")
      fp:close()
    end
  end)
end)
