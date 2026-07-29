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

local function run_case(root, file_count, chunk_bytes)
  collectgarbage("collect")
  local lua_before_kib = collectgarbage("count")
  local total_started = system.get_time()

  local discovery_started = system.get_time()
  local payload = build_scanner_payload(file_count)
  local discovery_ms = elapsed_ms(discovery_started)

  local accumulator = helpers.new_file_index_accumulator(core.get_ignore_file_rules())
  local ingestion_started = system.get_time()
  local pending = ""
  local first_candidate_ingested_ms
  for offset = 1, #payload, chunk_bytes do
    pending = helpers.ingest_file_index_chunk(
      accumulator,
      { path = root },
      pending,
      payload:sub(offset, offset + chunk_bytes - 1)
    )
    if not first_candidate_ingested_ms and accumulator.accepted > 0 then
      first_candidate_ingested_ms = elapsed_ms(total_started)
    end
  end
  if pending ~= "" then helpers.ingest_file_index_candidate(accumulator, { path = root }, pending) end
  local ingestion_ms = elapsed_ms(ingestion_started)

  test.equal(accumulator.candidates, file_count)
  test.equal(accumulator.accepted, file_count)
  test.equal(#accumulator.files, file_count)

  local sort_started = system.get_time()
  table.sort(accumulator.files)
  local sort_ms = elapsed_ms(sort_started)

  local native_started = system.get_time()
  local index = fuzzy_native.index(accumulator.files, { mode = "path" })
  local native_index_ms = elapsed_ms(native_started)

  local query_started = system.get_time()
  local query = string.format("file_%06d", file_count)
  local results = index:search(query, { limit = 30, spans = false })
  local first_query_ms = elapsed_ms(query_started)
  local time_to_first_results_ms = elapsed_ms(total_started)
  test.ok(#results > 0, "expected the completed native index to find the final synthetic path")
  index:free()

  local report = {
    benchmark = "fuzzy-file-index",
    recorded_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    files = file_count,
    scanner_payload_bytes = #payload,
    scanner_chunk_bytes = chunk_bytes,
    stages_ms = {
      synthetic_discovery = discovery_ms,
      lua_ingestion = ingestion_ms,
      sort = sort_ms,
      native_fuzzy_index = native_index_ms,
      first_query = first_query_ms,
    },
    first_candidate_ingested_ms = first_candidate_ingested_ms,
    time_to_first_results_ms = time_to_first_results_ms,
    lua_memory_kib = {
      before = lua_before_kib,
      after = collectgarbage("count"),
    },
    candidates = accumulator.candidates,
    accepted = accumulator.accepted,
    query_results = #results,
  }
  print("fuzzy-file-index-benchmark " .. common.serialize(report))
  return report
end

test.describe("Fuzzy Searcher file-index benchmark", function()
  test.before_each(function(context)
    context.original_projects = core.projects
    context.original_cwd = system.getcwd()
    context.root = USERDIR .. PATHSEP .. "fuzzy-file-index-benchmark"
    common.rm(context.root, true)
    local ok, err = common.mkdirp(context.root)
    test.ok(ok, err)
    core.projects = { Project(context.root) }
    system.chdir(context.root)
    project_paths.configure_project {}
  end)

  test.after_each(function(context)
    project_paths.configure_project {}
    core.projects = context.original_projects
    if context.original_cwd then pcall(system.chdir, context.original_cwd) end
    if context.root then common.rm(context.root, true) end
  end)

  test.test("records discovery, ingestion, native-index, and first-result baselines for 100k paths", function(context)
    local report = run_case(
      context.root,
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
end)
