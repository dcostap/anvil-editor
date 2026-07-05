local common = require "core.common"
local test = require "core.test"
local registry = require "core.treesitter.registry"
local worker_pool = require "core.worker_pool"
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
    test.ok(final.diagnostics.parse_calls >= 1)
    test.ok(final.diagnostics.file_read_ms >= 0)
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
    test.equal(final.usage_truncated, true)
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
