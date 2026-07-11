local common = require "core.common"
local test = require "core.test"
local registry = require "core.treesitter.registry"
local artifact_codec = require "core.treesitter.artifact_codec"
local worker_pool = require "core.worker_pool"
local symbol_query_worker = require "core.workers.treesitter_symbol_query"
local usage_query_worker = require "core.workers.treesitter_usage_query"
local native = require "treesitter"

local function mkdir(path)
  local ok, err = common.mkdirp(path)
  test.ok(ok, err)
  return path
end

local function write_file(path, text)
  local fp = test.not_nil(io.open(path, "wb"))
  fp:write(text or "")
  fp:close()
  return path
end

local function drain_until(pool, predicate, limit)
  limit = limit or 2000
  for _ = 1, limit do
    pool:drain({ max_ms = 5, max_messages = 64 })
    if predicate() then return true end
    coroutine.yield(0.001)
  end
  pool:drain({ max_ms = 5, max_messages = 64 })
  return predicate()
end

test.describe("treesitter_project_index worker", function()
  local pools = {}

  test.after_each(function()
    for i = #pools, 1, -1 do
      pools[i]:shutdown({ cancel_running = true, timeout_ms = 1000 })
      pools[i] = nil
    end
  end)

  test.test("indexes a small C project off the UI thread", function()
    test.ok(native.has_language("c"))
    registry.reload()
    local language = registry.get("main.c", "")
    test.not_nil(language)

    local root = mkdir(USERDIR .. PATHSEP .. "worker-project-index-fixture")
    write_file(root .. PATHSEP .. "main.c", [[
static int helper(void) { return 1; }
int main(void) { return helper(); }
]])
    local vendor = write_file(root .. PATHSEP .. "vendor.c", "int vendor_symbol(void) { return 2; }\n")
    write_file(root .. PATHSEP .. "generated.c", "int generated_symbol(void) { return 3; }\n")
    write_file(root .. PATHSEP .. "ignored.txt", "helper\n")

    local pool = worker_pool.new({ name = "treesitter-project-index-test", worker_count = 1 })
    pools[#pools + 1] = pool

    local chunks = {}
    local logs = {}
    local final
    pool:submit({
      kind = "treesitter_project_index",
      generation = 1,
      project_paths_generation = 1,
      payload = {
        roots = { { path = root } },
        languages = { language },
        include_usages = true,
        excluded = { { path = vendor } },
        ignore_files = { "generated%.c$" },
        chunk_files = 1,
        max_file_bytes = 1024 * 1024,
        log_skips = true,
      },
      on_log = function(message)
        logs[#logs + 1] = message.payload
      end,
      on_result = function(message)
        if message.type == "chunk" then
          for _, file in ipairs(message.payload.files or {}) do chunks[#chunks + 1] = file end
        elseif message.type == "final" then
          final = message.payload
        end
      end,
      on_complete = function(message)
        final = final or message.payload or {}
      end,
    })

    test.ok(drain_until(pool, function() return final ~= nil end))
    test.ok(final.files_indexed == 1, common.serialize({ final = final, logs = logs }))
    test.not_nil(final.diagnostics)
    test.equal(final.diagnostics.files_indexed, 1)
    test.equal(final.diagnostics.parse_calls, 1)
    test.equal(final.diagnostics.native_index_jobs, 1)
    test.ok((final.diagnostics.native_project_symbol_records or 0) >= 1)
    test.ok((final.diagnostics.native_project_usage_records or 0) >= 1)
    test.equal(final.diagnostics.native_index_lazy_outline_records, nil)
    test.equal(final.diagnostics.native_index_lazy_usage_records, nil)
    test.ok(final.diagnostics.file_read_ms >= 0)
    test.ok(final.diagnostics.native_total_ms >= 0)
    test.ok(final.diagnostics.native_prepare_input_ms >= 0)
    test.ok(final.diagnostics.native_parser_setup_ms >= 0)
    test.ok(final.diagnostics.outline_query_compile_ms >= 0)
    test.ok(final.diagnostics.usage_query_compile_ms >= 0)
    test.equal(final.diagnostics.outline_line_index_ms, 0)
    test.equal(final.diagnostics.usage_line_index_ms, 0)
    test.equal(final.diagnostics.line_indexes_skipped, 2)
    test.equal((final.diagnostics.query_cache_hits or 0) + (final.diagnostics.query_cache_misses or 0), 2)
    test.ok(final.diagnostics.chunk_send_wait_ms >= 0)
    test.ok(final.diagnostics.chunk_files_max >= 1)
    test.equal(#chunks, 1)
    test.equal(chunks[1].relpath, "main.c")
    local found_main = false
    for _, symbol in ipairs(chunks[1].symbols or {}) do
      if symbol.name == "main" then found_main = true end
    end
    test.ok(found_main)
  end)

  test.test("walk mode emits bounded file batches without indexing", function()
    test.ok(native.has_language("c"))
    registry.reload()
    local language = registry.get("main.c", "")
    test.not_nil(language)

    local root = mkdir(USERDIR .. PATHSEP .. "worker-project-index-walk-batches-fixture")
    for i = 1, 5 do
      write_file(root .. PATHSEP .. string.format("file_%02d.c", i), string.format("int value_%02d(void) { return %d; }\n", i, i))
    end

    local pool = worker_pool.new({ name = "treesitter-project-index-walk-batches-test", worker_count = 1 })
    pools[#pools + 1] = pool
    local batches = {}
    local final
    pool:submit({
      kind = "treesitter_project_index",
      generation = 1,
      project_paths_generation = 1,
      payload = {
        mode = "walk",
        roots = { { path = root } },
        languages = { language },
        include_usages = false,
        batch_files = 2,
        batch_bytes = 1024 * 1024,
        max_file_bytes = 1024 * 1024,
      },
      on_result = function(message)
        if message.type == "chunk" then
          for _, batch in ipairs(message.payload.batches or {}) do batches[#batches + 1] = batch end
        elseif message.type == "final" then
          final = message.payload
        end
      end,
      on_complete = function(message) final = final or message.payload or {} end,
    })

    test.ok(drain_until(pool, function() return final ~= nil end))
    test.equal(final.files_scanned, 5)
    test.equal(final.files_indexed, 0)
    test.equal(final.diagnostics.files_scanned, 5)
    test.equal(final.diagnostics.files_indexed or 0, 0)
    test.equal(final.diagnostics.parse_calls or 0, 0)
    test.ok(#batches >= 3, "expected at least 3 batches, got " .. tostring(#batches))
    for _, batch in ipairs(batches) do
      test.ok(#(batch.files or {}) <= 2, common.serialize(batch))
      for _, file in ipairs(batch.files or {}) do
        test.not_nil(file.path)
        test.not_nil(file.info)
        test.equal(file.language_id, language.id)
      end
    end
  end)

  test.test("skips a discovered file that disappears before extraction", function()
    test.ok(native.has_language("c"))
    registry.reload()
    local language = registry.get("vanished.c", "")
    test.not_nil(language)

    local root = mkdir(USERDIR .. PATHSEP .. "worker-project-index-disappearing-file-fixture")
    local path = write_file(root .. PATHSEP .. "vanished.c", "int vanished(void) { return 1; }\n")
    local info = test.not_nil(system.get_file_info(path))
    test.ok(os.remove(path))

    local pool = worker_pool.new({ name = "treesitter-project-index-disappearing-file-test", worker_count = 1 })
    pools[#pools + 1] = pool
    local logs = {}
    local final
    pool:submit({
      kind = "treesitter_project_index",
      generation = 1,
      project_paths_generation = 1,
      payload = {
        root = root,
        files = { { path = path, root = root, info = info, language_id = language.id } },
        languages = { language },
        include_usages = true,
        log_skips = true,
      },
      on_log = function(message) logs[#logs + 1] = message.payload end,
      on_result = function(message)
        if message.type == "final" then final = message.payload end
      end,
      on_complete = function(message) final = final or message.payload or {} end,
    })

    test.ok(drain_until(pool, function() return final ~= nil end))
    test.equal(final.files_scanned, 1)
    test.equal(final.files_indexed, 0)
    test.equal(final.files_skipped, 1)
    test.equal(#logs, 1)
    test.equal(logs[1].path, common.normalize_path(path))
    test.equal(logs[1].reason, "not-file")
    common.rm(root, true)
  end)

  test.test("writes result chunks to file-backed artifacts when requested", function()
    test.ok(native.has_language("c"))
    registry.reload()
    local language = registry.get("main.c", "")
    test.not_nil(language)

    local root = mkdir(USERDIR .. PATHSEP .. "worker-project-index-artifact-fixture")
    local artifact_dir = USERDIR .. PATHSEP .. "worker-project-index-artifact-fixture-artifacts"
    common.rm(artifact_dir, true)
    write_file(root .. PATHSEP .. "main.c", "int artifact_symbol(void) { return 1; }\n")

    local pool = worker_pool.new({ name = "treesitter-project-index-artifact-test", worker_count = 1 })
    pools[#pools + 1] = pool
    local artifact_payload
    local artifact_path
    local final
    pool:submit({
      kind = "treesitter_project_index",
      generation = 1,
      project_paths_generation = 1,
      payload = {
        roots = { { path = root } },
        languages = { language },
        include_usages = false,
        chunk_files = 1,
        artifact_chunks = true,
        artifact_dir = artifact_dir,
      },
      on_result = function(message)
        if message.type == "chunk" then
          test.is_nil(message.payload.files)
          test.equal(#(message.payload.manifest or {}), 1)
          test.not_nil(message.payload.manifest[1].path)
          test.not_nil(message.payload.manifest[1].fingerprint)
          test.is_nil(message.payload.manifest[1].symbols)
          test.is_nil(message.payload.manifest[1].usages_by_name)
          artifact_path = message.payload.artifact and message.payload.artifact.path
          test.not_nil(artifact_path)
          artifact_payload = test.not_nil(artifact_codec.read(artifact_path))
          os.remove(artifact_path)
        elseif message.type == "final" then
          final = message.payload
        end
      end,
      on_complete = function(message) final = final or message.payload or {} end,
    })

    test.ok(drain_until(pool, function() return final ~= nil end))
    test.not_nil(artifact_payload)
    test.equal(#(artifact_payload.files or {}), 1)
    test.ok((final.diagnostics.artifacts_sent or 0) >= 1, common.serialize(final.diagnostics))
    test.equal(system.get_file_info(artifact_path), nil)
    common.rm(artifact_dir, true)
  end)

  test.test("splits one large file result into bounded output chunks", function()
    test.ok(native.has_language("c"))
    registry.reload()
    local language = registry.get("main.c", "")
    test.not_nil(language)

    local root = mkdir(USERDIR .. PATHSEP .. "worker-project-index-large-file-chunk-fixture")
    local lines = { "int target(void) { return 1; }", "int main(void) {" }
    for i = 1, 80 do
      lines[#lines + 1] = string.format("  int value_%02d = target();", i)
    end
    lines[#lines + 1] = "  return target();"
    lines[#lines + 1] = "}"
    write_file(root .. PATHSEP .. "main.c", table.concat(lines, "\n") .. "\n")

    local artifact_dir = USERDIR .. PATHSEP .. "worker-project-index-large-file-chunk-artifacts"
    common.rm(artifact_dir, true)
    local pool = worker_pool.new({ name = "treesitter-project-index-large-file-chunk-test", worker_count = 1 })
    pools[#pools + 1] = pool
    local chunks = {}
    local final
    pool:submit({
      kind = "treesitter_project_index",
      generation = 1,
      project_paths_generation = 1,
      payload = {
        roots = { { path = root } },
        languages = { language },
        include_usages = true,
        chunk_files = 16,
        chunk_records = 10,
        chunk_bytes = 8192,
        artifact_chunks = true,
        artifact_dir = artifact_dir,
        max_file_bytes = 1024 * 1024,
        max_usage_captures_per_file = 200,
      },
      on_result = function(message)
        if message.type == "chunk" then
          chunks[#chunks + 1] = message.payload
          test.ok((message.payload.artifact and message.payload.artifact.bytes or math.huge) <= 8192)
        elseif message.type == "final" then
          final = message.payload
        end
      end,
      on_complete = function(message) final = final or message.payload or {} end,
    })

    test.ok(drain_until(pool, function() return final ~= nil end))
    test.ok(#chunks > 1, "expected large single-file result to be split, got " .. tostring(#chunks))
    test.ok((final.diagnostics.chunk_records_max or 0) <= 10, common.serialize(final.diagnostics))
    common.rm(artifact_dir, true)
  end)

  test.test("keeps symbols when usage extraction fails", function()
    test.ok(native.has_language("c"))
    registry.reload()
    local language = registry.get("main.c", "")
    local bad_language = common.merge({}, language)
    bad_language.query_sources = common.merge({}, language.query_sources)
    bad_language.query_sources.locals = "((invalid"

    local root = mkdir(USERDIR .. PATHSEP .. "worker-project-index-usage-failure-fixture")
    write_file(root .. PATHSEP .. "main.c", "int main(void) { return 0; }\n")

    local pool = worker_pool.new({ name = "treesitter-project-index-usage-failure-test", worker_count = 1 })
    pools[#pools + 1] = pool
    local file
    local final
    pool:submit({
      kind = "treesitter_project_index",
      generation = 1,
      project_paths_generation = 1,
      payload = {
        roots = { { path = root } },
        languages = { bad_language },
        include_usages = true,
        chunk_files = 1,
      },
      on_result = function(message)
        if message.type == "chunk" then file = (message.payload.files or {})[1]
        elseif message.type == "final" then final = message.payload end
      end,
      on_complete = function(message) final = final or message.payload or {} end,
    })

    test.ok(drain_until(pool, function() return final ~= nil end))
    test.not_nil(file)
    test.ok(#(file.symbols or {}) > 0)
    test.equal(file.usage_complete, false)
    test.equal(final.files_indexed, 1)
    test.equal(final.diagnostics.parse_calls, 1)
    test.equal(final.diagnostics.native_index_jobs, 1)
    test.ok((final.diagnostics.native_project_symbol_records or 0) >= 1)
    test.equal(final.diagnostics.native_index_lazy_outline_records, nil)
    test.equal(final.usage_truncated, true)
  end)

  test.test("builds sorted aggregates from file-backed project chunks", function()
    local artifact_dir = mkdir(USERDIR .. PATHSEP .. "worker-project-aggregate-artifacts")
    local artifact_path = artifact_dir .. PATHSEP .. "chunk.bin"
    local artifact_payload = {
      files = {
        {
          path = "b.c",
          relpath = "b.c",
          symbols = {
            { name = "Beta", path = "b.c", relpath = "b.c", start_line = 3 },
          },
          usages_by_name = {
            Beta = {
              { name = "Beta", path = "b.c", relpath = "b.c", start_line = 5, start_col = 1 },
            },
          },
          usage_count = 1,
          usage_complete = true,
        },
        {
          path = "a.c",
          relpath = "a.c",
          symbols = {
            { name = "Alpha", path = "a.c", relpath = "a.c", start_line = 1 },
          },
          usages_by_name = {
            Alpha = {
              { name = "Alpha", path = "a.c", relpath = "a.c", start_line = 2, start_col = 1 },
            },
          },
          usage_count = 1,
          usage_complete = true,
        },
      },
    }
    test.not_nil(artifact_codec.write(artifact_path, artifact_payload))

    local pool = worker_pool.new({ name = "treesitter-project-aggregate-test", worker_count = 1 })
    pools[#pools + 1] = pool
    local symbols = {}
    local usages_by_name = {}
    local final
    pool:submit({
      kind = "treesitter_project_aggregate",
      generation = 1,
      project_paths_generation = 1,
      payload = {
        artifacts = { { path = artifact_path } },
        chunk_records = 1,
        remove_artifacts = true,
      },
      on_result = function(message)
        if message.type == "chunk" then
          local p = message.payload or {}
          for _, symbol in ipairs(p.symbols or {}) do symbols[#symbols + 1] = symbol end
          for name, list in pairs(p.usages_by_name or {}) do
            usages_by_name[name] = usages_by_name[name] or {}
            for _, usage in ipairs(list) do usages_by_name[name][#usages_by_name[name] + 1] = usage end
          end
        elseif message.type == "final" then
          final = message.payload
        end
      end,
      on_complete = function(message) final = final or message.payload or {} end,
    })

    test.ok(drain_until(pool, function() return final ~= nil end))
    test.equal(#symbols, 2)
    test.equal(symbols[1].name, "Alpha")
    test.equal(symbols[2].name, "Beta")
    test.equal(final.symbols_total, 2)
    test.equal(final.usage_count, 2)
    test.equal(#(usages_by_name.Alpha or {}), 1)
    test.equal(#(usages_by_name.Beta or {}), 1)
    test.ok(final.diagnostics.append_ms >= 0)
    test.ok(final.diagnostics.symbol_sort_ms >= 0)
    test.ok(final.diagnostics.usage_sort_ms >= 0)
    test.ok(final.diagnostics.emit_reset_ms >= 0)
    test.ok(final.diagnostics.emit_symbols_ms >= 0)
    test.ok(final.diagnostics.emit_usages_ms >= 0)
    test.ok(final.diagnostics.emit_serialize_ms >= 0)
    test.ok(final.diagnostics.emit_send_wait_ms >= 0)
    test.ok(final.diagnostics.serialized_size_calls >= 0)
    test.equal(system.get_file_info(artifact_path), nil)
    common.rm(artifact_dir, true)
  end)

  test.test("writes distinct persistent query artifacts for concurrent aggregate jobs", function()
    local artifact_dir = mkdir(USERDIR .. PATHSEP .. "worker-project-query-artifact-collisions")
    local pool = worker_pool.new({ name = "treesitter-project-query-artifact-collision-test", worker_count = 2 })
    pools[#pools + 1] = pool
    local finals = {}

    local function submit(name)
      pool:submit({
        kind = "treesitter_project_aggregate",
        generation = 1,
        project_paths_generation = 1,
        payload = {
          files = {
            {
              path = name .. ".c",
              relpath = name .. ".c",
              symbols = {
                { name = name, path = name .. ".c", relpath = name .. ".c", start_line = 1 },
              },
              usages_by_name = {},
              usage_count = 0,
              usage_complete = true,
            },
          },
          chunk_records = 16,
          query_artifact_dir = artifact_dir,
        },
        on_result = function(message)
          if message.type == "final" then finals[name] = message.payload end
        end,
        on_complete = function(message) finals[name] = finals[name] or message.payload or {} end,
      })
    end

    submit("AlphaArtifact")
    submit("BetaArtifact")

    test.ok(drain_until(pool, function() return finals.AlphaArtifact and finals.BetaArtifact end))
    local alpha_path = finals.AlphaArtifact.symbol_query_artifact and finals.AlphaArtifact.symbol_query_artifact.path
    local beta_path = finals.BetaArtifact.symbol_query_artifact and finals.BetaArtifact.symbol_query_artifact.path
    test.ok(alpha_path, "missing Alpha artifact")
    test.ok(beta_path, "missing Beta artifact")
    test.not_equal(alpha_path, beta_path)

    local alpha_payload = test.not_nil(artifact_codec.read(alpha_path))
    local beta_payload = test.not_nil(artifact_codec.read(beta_path))
    test.equal(alpha_payload.symbols[1].name, "AlphaArtifact")
    test.equal(beta_payload.symbols[1].name, "BetaArtifact")
    common.rm(artifact_dir, true)
  end)

  test.test("writes chunked persistent query artifacts that query workers can read", function()
    local artifact_dir = mkdir(USERDIR .. PATHSEP .. "worker-project-query-artifact-chunks")
    local pool = worker_pool.new({ name = "treesitter-project-query-artifact-chunk-test", worker_count = 1 })
    pools[#pools + 1] = pool
    local final

    pool:submit({
      kind = "treesitter_project_aggregate",
      generation = 1,
      project_paths_generation = 1,
      payload = {
        files = {
          {
            path = "one.c",
            relpath = "one.c",
            symbols = {
              { name = "alpha", text = "alpha", search_text = "alpha", path = "one.c", relpath = "one.c", start_line = 1 },
              { name = "parse", text = "parse", search_text = "parse", path = "one.c", relpath = "one.c", start_line = 2 },
            },
            usages_by_name = {
              parse = {
                { name = "parse", path = "one.c", relpath = "one.c", start_line = 3, start_col = 4 },
              },
            },
            usage_complete = true,
          },
          {
            path = "two.c",
            relpath = "two.c",
            symbols = {
              { name = "parse_more", text = "parse_more", search_text = "parse_more", path = "two.c", relpath = "two.c", start_line = 1 },
            },
            usages_by_name = {
              parse = {
                { name = "parse", path = "two.c", relpath = "two.c", start_line = 4, start_col = 5 },
              },
            },
            usage_complete = true,
          },
        },
        chunk_records = 16,
        query_artifact_chunk_records = 1,
        query_artifact_dir = artifact_dir,
      },
      on_result = function(message)
        if message.type == "final" then final = message.payload end
      end,
      on_complete = function(message) final = final or message.payload or {} end,
    })

    test.ok(drain_until(pool, function() return final ~= nil end))
    test.ok(final.symbol_query_artifact and final.symbol_query_artifact.chunks, "expected chunked symbol artifact")
    test.equal(#final.symbol_query_artifact.chunks, 3)
    test.ok(final.usage_query_artifact and final.usage_query_artifact.chunks, "expected chunked usage artifact")
    test.equal(#final.usage_query_artifact.chunks, 2)

    local symbol_messages = {}
    symbol_query_worker.run({
      query = "parse",
      limit = 10,
      index_artifacts = { final.symbol_query_artifact },
    }, { send = function(message) symbol_messages[#symbol_messages + 1] = message; return true end })
    local symbol_result = symbol_messages[1] and symbol_messages[1].payload
    test.equal(symbol_result.diagnostics.artifact_load_errors, 0)
    test.equal(symbol_result.diagnostics.artifacts_loaded, 3)
    test.equal(symbol_result.diagnostics.matched_symbols, 2)
    test.equal(symbol_result.symbols[1].name, "parse")

    local usage_messages = {}
    usage_query_worker.run({
      name = "parse",
      limit = 10,
      index_artifacts = { final.usage_query_artifact },
    }, { send = function(message) usage_messages[#usage_messages + 1] = message; return true end })
    local usage_result = usage_messages[1] and usage_messages[1].payload
    test.equal(usage_result.diagnostics.artifact_load_errors, 0)
    test.equal(usage_result.diagnostics.artifacts_loaded, 2)
    test.equal(usage_result.diagnostics.matched_usages, 2)

    common.rm(artifact_dir, true)
  end)

  test.test("symbol and usage query workers report missing top-level payload artifacts", function()
    local missing_symbol_path = USERDIR .. PATHSEP .. "missing-symbol-query-payload.lua"
    local symbol_messages = {}
    symbol_query_worker.run({
      artifact = { path = missing_symbol_path },
    }, { send = function(message) symbol_messages[#symbol_messages + 1] = message; return true end })
    local symbol_result = symbol_messages[1] and symbol_messages[1].payload
    test.equal(symbol_result.diagnostics.artifact_load_errors, 1)
    test.equal(symbol_result.diagnostics.last_artifact_load_path, missing_symbol_path)

    local missing_usage_path = USERDIR .. PATHSEP .. "missing-usage-query-payload.lua"
    local usage_messages = {}
    usage_query_worker.run({
      artifact = { path = missing_usage_path },
    }, { send = function(message) usage_messages[#usage_messages + 1] = message; return true end })
    local usage_result = usage_messages[1] and usage_messages[1].payload
    test.equal(usage_result.diagnostics.artifact_load_errors, 1)
    test.equal(usage_result.diagnostics.last_artifact_load_path, missing_usage_path)
  end)

  test.test("cancels a project index job before adoption", function()
    test.ok(native.has_language("c"))
    registry.reload()
    local language = registry.get("main.c", "")
    local root = mkdir(USERDIR .. PATHSEP .. "worker-project-index-cancel-fixture")
    for i = 1, 40 do
      write_file(root .. PATHSEP .. string.format("file_%02d.c", i), string.format("int value_%02d(void) { return %d; }\n", i, i))
    end

    local pool = worker_pool.new({ name = "treesitter-project-index-cancel-test", worker_count = 1 })
    pools[#pools + 1] = pool
    local progress = 0
    local cancelled = false
    local handle = pool:submit({
      kind = "treesitter_project_index",
      generation = 1,
      project_paths_generation = 1,
      payload = {
        roots = { { path = root } },
        languages = { language },
        include_usages = false,
        chunk_files = 1,
        max_file_bytes = 1024 * 1024,
        progress_interval = 0,
      },
      on_progress = function(message) progress = message.payload.files_scanned or progress end,
      on_cancelled = function() cancelled = true end,
    })

    test.ok(drain_until(pool, function() return progress >= 1 end))
    test.ok(pool:cancel(handle))
    test.ok(drain_until(pool, function() return cancelled end))
    test.equal(pool:status(handle).status, "cancelled")
  end)
end)
