local Doc = require "core.doc"
local markdown_model = require "core.markdown.model"
local test = require "core.test"
local worker_pool = require "core.worker_pool"

local function fixture(target_bytes)
  local plain = "Ordinary prose for a representative note, with enough words to exercise paragraph parsing.\n"
  local rich = "## Heading with **bold**, *italic*, [[Note|Alias]], ==mark==, and `code`.\n"
  local lines = {}
  local bytes = 0
  while bytes < target_bytes do
    local line = (#lines % 20 == 0) and rich or plain
    lines[#lines + 1] = line
    bytes = bytes + #line
  end
  return table.concat(lines), #lines
end

local function wait_ready(instance, timeout)
  local deadline = system.get_time() + timeout
  repeat
    local pool = worker_pool.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 128 }) end
    if instance.status == "ready" then return true end
    coroutine.yield(0.001)
  until system.get_time() >= deadline
  return false
end

local function run_case(target_bytes)
  print(string.format("markdown-semantic-benchmark starting target_bytes=%d", target_bytes))
  io.stdout:flush()
  local source, line_count = fixture(target_bytes)
  local doc = Doc("markdown-benchmark.md", "markdown-benchmark.md", true)
  doc:insert(1, 1, source)
  doc:clear_undo_redo()

  local started = system.get_time()
  local instance = markdown_model.get(doc)
  test.ok(wait_ready(instance, 15), instance.reason)
  local full_ms = (system.get_time() - started) * 1000
  local full_native_ms = instance.diagnostics.last_parse_ms

  local query_started = system.get_time()
  local middle = math.max(1, math.floor(line_count / 2))
  local nodes = test.not_nil(instance:nodes_for_lines(middle, middle + 2))
  local query_ms = (system.get_time() - query_started) * 1000
  test.ok(#nodes > 0)

  started = system.get_time()
  doc:insert(middle, 4, "edited ")
  test.ok(wait_ready(instance, 15), instance.reason)
  local incremental_ms = (system.get_time() - started) * 1000
  local incremental_native_ms = instance.diagnostics.last_parse_ms
  local summary = instance.result:summary()
  test.equal(instance.diagnostics.incremental_publications, 1)
  test.ok(instance.diagnostics.reused_inline_regions > 0)

  print(string.format(
    "markdown-semantic-benchmark bytes=%d lines=%d full_e2e_ms=%.3f full_native_ms=%.3f incremental_e2e_ms=%.3f incremental_native_ms=%.3f incremental_total_ms=%.3f block_query_ms=%.3f inline_query_ms=%.3f visible_query_ms=%.3f visible_nodes=%d",
    #source, line_count, full_ms, full_native_ms, incremental_ms,
    incremental_native_ms, summary.metrics.total_ms, summary.metrics.outline_query_ms,
    summary.metrics.usage_query_ms, query_ms, #nodes
  ))
  io.stdout:flush()
  markdown_model.close(doc, "benchmark")
end

test.describe("Markdown semantic-model benchmark", function()
  test.it("measures 100 KiB and 1 MiB publication paths", function()
    run_case(100 * 1024)
    run_case(1024 * 1024)
  end)
end)
