local core = require "core"
local common = require "core.common"
local Project = require "core.project"
local project_paths = require "core.project_paths"
local test = require "core.test"
local fuzzy_native = require "fuzzy"
local fuzzy_searcher = require "plugins.fuzzy_searcher"
local helpers = fuzzy_searcher._test

local function env_count(name, default)
  local value = tonumber(os.getenv(name) or "")
  return value and math.max(1, math.floor(value)) or default
end

local function elapsed_ms(started)
  return (system.get_time() - started) * 1000
end

local function build_scanner_payload(file_count)
  local paths = {}
  for i = 1, file_count do
    paths[i] = string.format(
      "src/module_%03d/layer_%02d/component_%03d/file_%06d.cpp",
      i % 251, i % 37, i % 503, i
    )
  end
  return table.concat(paths, "\0") .. "\0"
end

local function run_case(file_count, chunk_bytes)
  collectgarbage("collect")
  local lua_before_kib = collectgarbage("count")
  local total_started = system.get_time()

  local discovery_started = system.get_time()
  local payload = build_scanner_payload(file_count)
  local discovery_ms = elapsed_ms(discovery_started)

  local builder = fuzzy_native.file_index_builder {
    {
      path = USERDIR .. PATHSEP .. "fuzzy-file-index-benchmark",
      label = "fuzzy-file-index-benchmark",
      role = "root",
      id = "root",
      rank_penalty = 0,
    },
  }
  local ingestion_started = system.get_time()
  local first_chunk_ingested_ms
  for offset = 1, #payload, chunk_bytes do
    builder:feed(1, payload:sub(offset, offset + chunk_bytes - 1))
    if not first_chunk_ingested_ms then first_chunk_ingested_ms = elapsed_ms(total_started) end
  end
  local native_ingestion_ms = elapsed_ms(ingestion_started)

  local finalize_started = system.get_time()
  local index, stats = builder:finish()
  local native_finalize_ms = elapsed_ms(finalize_started)
  test.equal(stats.candidates, file_count)
  test.equal(stats.accepted, file_count)
  test.equal(#index, file_count)

  local query_started = system.get_time()
  local query = string.format("file_%06d", file_count)
  local results = index:search(query, { limit = 30, spans = false })
  local first_query_ms = elapsed_ms(query_started)
  local time_to_first_results_ms = elapsed_ms(total_started)
  test.ok(#results > 0, "expected the completed native index to find the final synthetic path")
  index:free()

  local report = {
    benchmark = "fuzzy-file-index",
    implementation = "native-project-file-index",
    recorded_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    files = file_count,
    scanner_payload_bytes = #payload,
    scanner_chunk_bytes = chunk_bytes,
    stages_ms = {
      synthetic_discovery = discovery_ms,
      native_ingestion = native_ingestion_ms,
      native_finalize_and_fuzzy_index = native_finalize_ms,
      first_query = first_query_ms,
    },
    first_chunk_ingested_ms = first_chunk_ingested_ms,
    time_to_first_results_ms = time_to_first_results_ms,
    lua_memory_kib = {
      before = lua_before_kib,
      after = collectgarbage("count"),
    },
    candidates = stats.candidates,
    accepted = stats.accepted,
    duplicates = stats.duplicates,
    query_results = #results,
  }
  print("fuzzy-file-index-benchmark " .. common.serialize(report))
  return report
end

test.describe("Fuzzy Searcher file-index benchmark", function()
  test.test("records native ingestion, finalization, and first-result baselines for 100k paths", function()
    local report = run_case(
      env_count("ANVIL_FUZZY_FILE_BENCH_FILES", 100000),
      env_count("ANVIL_FUZZY_FILE_BENCH_CHUNK_BYTES", 16384)
    )

    local report_path = os.getenv("ANVIL_FUZZY_FILE_BENCH_REPORT")
    if report_path and report_path ~= "" then
      local fp = test.not_nil(io.open(report_path, "wb"))
      fp:write("return ", common.serialize(report), "\n")
      fp:close()
    end
  end)

  test.test("records an optional real-Project scanner-to-search baseline", function()
    local root = os.getenv("ANVIL_FUZZY_FILE_BENCH_REAL_ROOT")
    if not root or root == "" then return end
    local info = system.get_file_info(root)
    test.ok(info and info.type == "dir", "real benchmark root is unavailable: " .. tostring(root))

    local original_projects = core.projects
    local original_cwd = system.getcwd()
    helpers.cancel_file_index_for_test()
    core.projects = { Project(root) }
    system.chdir(root)
    project_paths.configure_project {}

    local started = system.get_time()
    local expected_root = common.normalize_path(root)
    fuzzy_searcher.open(os.getenv("ANVIL_FUZZY_FILE_BENCH_QUERY") or "vehicle")
    local deadline = started + env_count("ANVIL_FUZZY_FILE_BENCH_TIMEOUT", 30)
    local status = helpers.file_index_status()
    local function expected_snapshot_ready()
      return status.native and not status.indexing
        and type(status.root_signature) == "string"
        and status.root_signature:find(expected_root, 1, true) ~= nil
    end
    while not expected_snapshot_ready() and system.get_time() < deadline do
      coroutine.yield(0.01)
      status = helpers.file_index_status()
    end
    local elapsed = elapsed_ms(started)
    test.ok(expected_snapshot_ready(), "real Project native file index did not become ready")
    test.ok(status.count > 0, "real Project native file index was empty")
    print("fuzzy-file-index-real-benchmark " .. common.serialize({
      benchmark = "fuzzy-file-index-real-project",
      root = root,
      files = status.count,
      scanner_to_searchable_ms = elapsed,
      diagnostics = status.diagnostics,
    }))

    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    helpers.cancel_file_index_for_test()
    project_paths.configure_project {}
    core.projects = original_projects
    if original_cwd then system.chdir(original_cwd) end
  end)
end)
