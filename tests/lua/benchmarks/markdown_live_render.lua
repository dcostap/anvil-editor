local config = require "core.config"
local Doc = require "core.doc"
local DocView = require "core.docview"
local markdown = require "core.markdown"
local fence_highlight = require "core.markdown.fence_highlight"
local markdown_model = require "core.markdown.model"
local test = require "core.test"
local worker_pool = require "core.worker_pool"

local function representative_source(bytes)
  local lines, size, i = {}, 0, 1
  while size < bytes do
    local line
    if i % 23 == 0 then
      line = string.format("## Heading %d with **important text**\n", i)
    elseif i % 17 == 0 then
      line = string.format("Paragraph %d links to [[Folder/Note %d|an alias]] and continues with prose.\n", i, i)
    else
      line = string.format("Paragraph %d has representative prose, *emphasis*, and enough words for viewport work.\n", i)
    end
    lines[#lines + 1], size, i = line, size + #line, i + 1
  end
  return table.concat(lines)
end

local function fenced_source(count, body_lines)
  local lines = {}
  for fence = 1, count do
    local language = fence % 2 == 0 and "js" or "lua"
    lines[#lines + 1] = "```" .. language
    for line = 1, body_lines do
      lines[#lines + 1] = language == "js"
        and string.format("const value%d_%d = %d", fence, line, line)
        or string.format("local value%d_%d = %d", fence, line, line)
    end
    lines[#lines + 1] = "```"
    lines[#lines + 1] = ""
  end
  return table.concat(lines, "\n")
end

local function wait_ready(instance, timeout)
  local deadline = system.get_time() + (timeout or 10)
  repeat
    local pool = worker_pool.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 128 }) end
    if instance.status == "ready" then return true end
    coroutine.yield(0.005)
  until system.get_time() >= deadline
  return instance.status == "ready"
end

local function percentile(values, fraction)
  table.sort(values)
  return values[math.max(1, math.ceil(#values * fraction))]
end

local function measure(samples, fn)
  local values = {}
  for i = 1, samples do
    local started = system.get_time()
    fn(i)
    values[i] = (system.get_time() - started) * 1000
  end
  return percentile(values, 0.95)
end

test.describe("Markdown live render benchmark", function()
  test.it("reports lazy fenced-code demand and cache diagnostics", function()
    local old_enabled = config.markdown_live_editor
    config.markdown_live_editor = true
    local doc = Doc("fence-benchmark.md", "fence-benchmark.md", true)
    doc:insert(1, 1, fenced_source(2000, 3))
    doc:clear_undo_redo()
    local view = DocView(doc)
    view.size.x, view.size.y = 1200, 800
    view:set_wrapping_enabled(false)
    markdown.live_render.refresh_view(view)
    local instance = test.not_nil(markdown_model.peek(doc))
    test.ok(wait_ready(instance), instance.reason)

    for line = 1, 30 do view:get_line_render(line) end
    local service = test.not_nil(fence_highlight.peek(doc))
    local deadline = system.get_time() + 10
    while service:get_diagnostics().pending_work and system.get_time() < deadline do
      coroutine.yield(0)
    end
    local diagnostics = service:get_diagnostics()
    print(string.format(
      "Markdown fence benchmark: document_lines=%d tokenized=%d cached=%d bytes=%d pairs=%d checkpoints=%d queued=%d evictions=%d",
      #doc.lines,
      diagnostics.lines_tokenized,
      diagnostics.cached_lines,
      diagnostics.cached_source_bytes,
      diagnostics.cached_token_pairs,
      diagnostics.checkpoint_count,
      diagnostics.queued_lines,
      diagnostics.evictions
    ))
    test.ok(diagnostics.lines_tokenized < 2000 * 3)
    markdown.live_render.release(view, "benchmark")
    markdown_model.close(doc, "benchmark")
    config.markdown_live_editor = old_enabled
  end)

  test.it("reports cached viewport and caret-transition latency", function()
    local old_enabled = config.markdown_live_editor
    config.markdown_live_editor = true
    local doc = Doc("render-benchmark.md", "render-benchmark.md", true)
    doc:insert(1, 1, representative_source(100 * 1024))
    doc:clear_undo_redo()
    local view = DocView(doc)
    view.size.x, view.size.y = 1200, 800
    view:set_wrapping_enabled(false)
    doc:set_selection(#doc.lines, 1)
    markdown.live_render.refresh_view(view)
    local instance = test.not_nil(markdown_model.peek(doc))
    test.ok(wait_ready(instance), instance.reason)

    for line = 1, math.min(60, #doc.lines) do view:get_line_render(line) end
    local viewport_p95 = measure(100, function()
      for line = 1, math.min(60, #doc.lines) do view:get_line_render(line) end
    end)
    local caret_p95 = measure(100, function(i)
      local line = i % 50 + 1
      doc:set_selection(line, 2)
      view:get_line_render(line)
      if line > 1 then view:get_line_render(line - 1) end
    end)

    print(string.format(
      "Markdown live render benchmark: bytes=%d lines=%d viewport_p95_ms=%.3f caret_p95_ms=%.3f",
      #table.concat(doc.lines), #doc.lines, viewport_p95, caret_p95
    ))
    test.ok(viewport_p95 >= 0)
    test.ok(caret_p95 >= 0)
    markdown.live_render.release(view, "benchmark")
    markdown_model.close(doc, "benchmark")
    config.markdown_live_editor = old_enabled
  end)
end)
