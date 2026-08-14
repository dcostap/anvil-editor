local Buffer = require "core.buffer"
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

local function operation_fixture(target_bytes)
  local lines, bytes, index = {}, 0, 1
  while bytes < target_bytes do
    local line
    if index % 29 == 0 then
      line = "- list item with **formatting** and enough representative body text"
    elseif index % 17 == 0 then
      line = "## Heading with [[Note|Alias]], *emphasis*, and `inline code`"
    else
      line = "Ordinary paragraph text with several words for an incremental edit target."
    end
    lines[#lines + 1] = line
    bytes = bytes + #line + 1
    if index % 4 == 0 then
      lines[#lines + 1] = ""
      bytes = bytes + 1
    end
    index = index + 1
  end
  return table.concat(lines, "\n")
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
  local buffer = Buffer("markdown-benchmark.md", "markdown-benchmark.md", true)
  buffer:insert(1, 1, source)
  buffer:clear_undo_redo()

  local started = system.get_time()
  local instance = markdown_model.get(buffer)
  test.ok(wait_ready(instance, 15), instance.reason)
  local full_ms = (system.get_time() - started) * 1000
  local full_native_ms = instance.diagnostics.last_parse_ms

  local query_started = system.get_time()
  local middle = math.max(1, math.floor(line_count / 2))
  local nodes = test.not_nil(instance:nodes_for_lines(middle, middle + 2))
  local query_ms = (system.get_time() - query_started) * 1000
  test.ok(#nodes > 0)

  local batch_started = system.get_time()
  local batch_nodes = test.not_nil(instance:nodes_for_lines(1, math.min(60, line_count), {
    limit = 10000,
  }))
  local batch_query_ms = (system.get_time() - batch_started) * 1000

  started = system.get_time()
  buffer:insert(middle, 4, "edited ")
  test.ok(wait_ready(instance, 15), instance.reason)
  local incremental_ms = (system.get_time() - started) * 1000
  local incremental_native_ms = instance.diagnostics.last_parse_ms
  local summary = instance.result:summary()
  test.equal(instance.diagnostics.incremental_publications, 1)
  test.ok(instance.diagnostics.reused_inline_regions > 0)

  print(string.format(
    "markdown-semantic-benchmark bytes=%d lines=%d full_e2e_ms=%.3f full_native_ms=%.3f incremental_e2e_ms=%.3f incremental_native_ms=%.3f block_parse_ms=%.3f inline_parse_ms=%.3f incremental_total_ms=%.3f block_query_ms=%.3f inline_query_ms=%.3f visible_query_ms=%.3f visible_nodes=%d normalized_60_line_query_ms=%.3f normalized_60_line_nodes=%d",
    #source, line_count, full_ms, full_native_ms, incremental_ms,
    incremental_native_ms, summary.metrics.block_parse_ms,
    summary.metrics.inline_parse_ms, summary.metrics.total_ms, summary.metrics.outline_query_ms,
    summary.metrics.usage_query_ms, query_ms, #nodes, batch_query_ms, #batch_nodes
  ))
  io.stdout:flush()
  markdown_model.close(buffer, "benchmark")
end

local function run_operation_case(target_bytes)
  local source = operation_fixture(target_bytes)
  local buffer = Buffer("markdown-operation-benchmark.md", "markdown-operation-benchmark.md", true)
  buffer:insert(1, 1, source)
  buffer:clear_undo_redo()
  local instance = markdown_model.get(buffer)
  test.ok(wait_ready(instance, 15), instance.reason)

  local function middle_line(matcher)
    local middle = math.max(1, math.floor(#buffer.lines / 2))
    if not matcher then return middle end
    for distance = 0, #buffer.lines do
      for _, line in ipairs({ middle - distance, middle + distance }) do
        local text = line >= 1 and line <= #buffer.lines and buffer.lines[line] or nil
        if text and text:match(matcher) then return line end
      end
    end
    error("benchmark fixture has no matching line")
  end

  local function measure_operation(name, edit)
    local started = system.get_time()
    edit()
    test.ok(wait_ready(instance, 15), instance.reason)
    local elapsed_ms = (system.get_time() - started) * 1000
    local summary = instance.result:summary()
    print(string.format(
      "markdown-semantic-operation bytes=%d operation=%s e2e_ms=%.3f native_parse_ms=%.3f native_total_ms=%.3f block_parse_ms=%.3f inline_parse_ms=%.3f",
      #source, name, elapsed_ms,
      instance.diagnostics.last_parse_ms,
      summary.metrics.total_ms or 0,
      summary.metrics.block_parse_ms or 0,
      summary.metrics.inline_parse_ms or 0
    ))
    io.stdout:flush()
  end

  measure_operation("character-insert", function()
    buffer:insert(middle_line(), 10, "x")
  end)
  measure_operation("newline-insert", function()
    buffer:insert(middle_line("^Ordinary"), 24, "\n")
  end)
  measure_operation("list-indent", function()
    buffer:insert(middle_line("^%- "), 1, "    ")
  end)
  measure_operation("delimiter-create", function()
    local line = middle_line("^Ordinary")
    buffer:apply_edits({
      { line1 = line, col1 = 10, line2 = line, col2 = 10, text = "**" },
      { line1 = line, col1 = 19, line2 = line, col2 = 19, text = "**" },
    }, { type = "benchmark-delimiter-create", merge_cursors = false })
  end)
  measure_operation("ten-line-paste", function()
    local paste = {}
    for index = 1, 10 do paste[index] = "pasted representative line " .. index end
    buffer:insert(middle_line(), 15, table.concat(paste, "\n"))
  end)

  markdown_model.close(buffer, "benchmark")
end

test.describe("Markdown semantic-model benchmark", function()
  test.it("measures 100 KiB and 1 MiB publication paths", function()
    run_case(100 * 1024)
    run_case(1024 * 1024)
  end)

  test.it("measures ordinary edit publication at representative sizes", function()
    run_operation_case(10 * 1024)
    run_operation_case(100 * 1024)
    run_operation_case(1024 * 1024)
  end)
end)
