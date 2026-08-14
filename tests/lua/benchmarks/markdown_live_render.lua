local config = require "core.config"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local markdown = require "core.markdown"
local fence_highlight = require "core.markdown.fence_highlight"
local markdown_model = require "core.markdown.model"
local pending_projection = require "core.markdown.pending_projection"
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
  return percentile(values, 0.95), percentile(values, 0.99)
end

test.describe("Markdown live render benchmark", function()
  test.it("reports provisional source-topology latency", function()
    local buffer = Buffer("topology-benchmark.md", "topology-benchmark.md", true)
    buffer:insert(1, 1, representative_source(1024 * 1024))
    buffer:clear_undo_redo()
    local p95, p99 = measure(20, function()
      pending_projection.source_topology(buffer.lines)
    end)
    print(string.format(
      "Markdown pending topology benchmark: bytes=%d lines=%d p95_ms=%.3f p99_ms=%.3f",
      #table.concat(buffer.lines), #buffer.lines, p95, p99
    ))
    test.ok(p95 >= 0)
    test.ok(p99 >= p95)
  end)

  test.it("reports lazy fenced-code demand and cache diagnostics", function()
    local old_enabled = config.markdown_live_editor
    config.markdown_live_editor = true
    local buffer = Buffer("fence-benchmark.md", "fence-benchmark.md", true)
    buffer:insert(1, 1, fenced_source(2000, 3))
    buffer:clear_undo_redo()
    local view = Editor(buffer)
    view.size.x, view.size.y = 1200, 800
    view:set_wrapping_enabled(false)
    markdown.live_render.refresh_view(view)
    local instance = test.not_nil(markdown_model.peek(buffer))
    test.ok(wait_ready(instance), instance.reason)

    for line = 1, 30 do view:get_line_render(line) end
    local service = test.not_nil(fence_highlight.peek(buffer))
    local deadline = system.get_time() + 10
    while service:get_diagnostics().pending_work and system.get_time() < deadline do
      coroutine.yield(0)
    end
    local diagnostics = service:get_diagnostics()
    print(string.format(
      "Markdown fence benchmark: buffer_lines=%d tokenized=%d cached=%d bytes=%d pairs=%d checkpoints=%d queued=%d evictions=%d",
      #buffer.lines,
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
    markdown_model.close(buffer, "benchmark")
    config.markdown_live_editor = old_enabled
  end)

  test.it("reports cached viewport and caret-transition latency", function()
    local old_enabled = config.markdown_live_editor
    config.markdown_live_editor = true
    local buffer = Buffer("render-benchmark.md", "render-benchmark.md", true)
    buffer:insert(1, 1, representative_source(100 * 1024))
    buffer:clear_undo_redo()
    local view = Editor(buffer)
    view.size.x, view.size.y = 1200, 800
    view:set_wrapping_enabled(false)
    buffer:set_selection(#buffer.lines, 1)
    markdown.live_render.refresh_view(view)
    local instance = test.not_nil(markdown_model.peek(buffer))
    test.ok(wait_ready(instance), instance.reason)

    for line = 1, math.min(60, #buffer.lines) do view:get_line_render(line) end
    local viewport_p95, viewport_p99 = measure(100, function()
      for line = 1, math.min(60, #buffer.lines) do view:get_line_render(line) end
    end)
    local caret_p95, caret_p99 = measure(100, function(i)
      local line = i % 50 + 1
      buffer:set_selection(line, 2)
      view:get_line_render(line)
      if line > 1 then view:get_line_render(line - 1) end
    end)

    print(string.format(
      "Markdown live render benchmark: bytes=%d lines=%d viewport_p95_ms=%.3f viewport_p99_ms=%.3f caret_p95_ms=%.3f caret_p99_ms=%.3f",
      #table.concat(buffer.lines), #buffer.lines,
      viewport_p95, viewport_p99, caret_p95, caret_p99
    ))
    test.ok(viewport_p95 >= 0)
    test.ok(viewport_p99 >= viewport_p95)
    test.ok(caret_p95 >= 0)
    test.ok(caret_p99 >= caret_p95)
    markdown.live_render.release(view, "benchmark")
    markdown_model.close(buffer, "benchmark")
    config.markdown_live_editor = old_enabled
  end)

  test.it("reports edit-to-pending-presentation latency", function()
    local old_enabled = config.markdown_live_editor
    config.markdown_live_editor = true
    local buffer = Buffer("pending-benchmark.md", "pending-benchmark.md", true)
    buffer:insert(1, 1, representative_source(100 * 1024))
    buffer:clear_undo_redo()
    local view = Editor(buffer)
    view.size.x, view.size.y = 1200, 800
    view:set_wrapping_enabled(false)
    markdown.live_render.refresh_view(view)
    local instance = test.not_nil(markdown_model.peek(buffer))
    test.ok(wait_ready(instance), instance.reason)

    local values, edit_values, capture_values, projection_values = {}, {}, {}, {}
    for sample = 1, 100 do
      local line = sample % 40 + 1
      buffer:set_selection(line, #buffer.lines[line])
      local started = system.get_time()
      view:on_text_input("x")
      edit_values[sample] = (system.get_time() - started) * 1000
      local render = test.not_nil(view:get_line_render(line))
      values[sample] = (system.get_time() - started) * 1000
      local owner = test.not_nil(view.__markdown_live_owner)
      capture_values[sample] = owner.last_pre_edit_capture_ms or 0
      projection_values[sample] = owner.last_pending_projection_ms or 0
      test.equal(render.source_text, (buffer.lines[line] or ""):gsub("\n$", ""))
      test.ok(wait_ready(instance), instance.reason)
    end
    local p95, p99 = percentile(values, 0.95), percentile(values, 0.99)
    local capture_p95 = percentile(capture_values, 0.95)
    local projection_p95 = percentile(projection_values, 0.95)
    local edit_p95 = percentile(edit_values, 0.95)
    print(string.format(
      "Markdown pending presentation benchmark: bytes=%d samples=%d p95_ms=%.3f p99_ms=%.3f edit_p95_ms=%.3f capture_p95_ms=%.3f projection_p95_ms=%.3f",
      #table.concat(buffer.lines), #values, p95, p99,
      edit_p95, capture_p95, projection_p95
    ))
    test.ok(p95 >= 0)
    test.ok(p99 >= p95)
    markdown.live_render.release(view, "benchmark")
    markdown_model.close(buffer, "benchmark")
    config.markdown_live_editor = old_enabled
  end)

  test.it("reports wrapped edit-to-pending-presentation latency", function()
    local old_enabled = config.markdown_live_editor
    config.markdown_live_editor = true
    local buffer = Buffer("pending-wrapped-benchmark.md", "pending-wrapped-benchmark.md", true)
    buffer:insert(1, 1, representative_source(100 * 1024))
    buffer:clear_undo_redo()
    local view = Editor(buffer)
    view.size.x, view.size.y = 600, 800
    view:set_wrapping_enabled(true)
    markdown.live_render.refresh_view(view)
    local instance = test.not_nil(markdown_model.peek(buffer))
    test.ok(wait_ready(instance), instance.reason)

    local values, edit_values, capture_values, projection_values = {}, {}, {}, {}
    for sample = 1, 100 do
      local line = sample % 30 + 1
      buffer:set_selection(line, #buffer.lines[line])
      local started = system.get_time()
      view:on_text_input("x")
      edit_values[sample] = (system.get_time() - started) * 1000
      test.not_nil(view:get_line_render(line))
      values[sample] = (system.get_time() - started) * 1000
      local owner = test.not_nil(view.__markdown_live_owner)
      capture_values[sample] = owner.last_pre_edit_capture_ms or 0
      projection_values[sample] = owner.last_pending_projection_ms or 0
      test.ok(wait_ready(instance), instance.reason)
    end
    local p95, p99 = percentile(values, 0.95), percentile(values, 0.99)
    print(string.format(
      "Markdown wrapped pending presentation benchmark: bytes=%d samples=%d p95_ms=%.3f p99_ms=%.3f edit_p95_ms=%.3f capture_p95_ms=%.3f projection_p95_ms=%.3f",
      #table.concat(buffer.lines), #values, p95, p99,
      percentile(edit_values, 0.95), percentile(capture_values, 0.95),
      percentile(projection_values, 0.95)
    ))
    test.ok(p95 >= 0)
    test.ok(p99 >= p95)
    markdown.live_render.release(view, "benchmark")
    markdown_model.close(buffer, "benchmark")
    config.markdown_live_editor = old_enabled
  end)

  test.it("reports large structural edit-to-pending-presentation latency", function()
    local old_enabled = config.markdown_live_editor
    config.markdown_live_editor = true
    local buffer = Buffer("pending-structural-benchmark.md", "pending-structural-benchmark.md", true)
    buffer:insert(1, 1, representative_source(1024 * 1024))
    buffer:clear_undo_redo()
    local view = Editor(buffer)
    view.size.x, view.size.y = 1200, 800
    view:set_wrapping_enabled(false)
    markdown.live_render.refresh_view(view)
    local instance = test.not_nil(markdown_model.peek(buffer))
    test.ok(wait_ready(instance), instance.reason)

    local values, topology_values, capture_values, projection_values = {}, {}, {}, {}
    for sample = 1, 5 do
      local line = sample * 20
      buffer:set_selection(line, #buffer.lines[line])
      local started = system.get_time()
      view:on_text_input("\n")
      test.not_nil(view:get_line_render(line))
      values[sample] = (system.get_time() - started) * 1000
      local owner = test.not_nil(view.__markdown_live_owner)
      topology_values[sample] = owner.last_topology_ms or 0
      capture_values[sample] = owner.last_pre_edit_capture_ms or 0
      projection_values[sample] = owner.last_pending_projection_ms or 0
      test.ok(wait_ready(instance), instance.reason)
    end
    local p95, p99 = percentile(values, 0.95), percentile(values, 0.99)
    print(string.format(
      "Markdown large structural pending benchmark: bytes=%d samples=%d p95_ms=%.3f p99_ms=%.3f topology_p95_ms=%.3f capture_p95_ms=%.3f projection_p95_ms=%.3f",
      #table.concat(buffer.lines), #values, p95, p99,
      percentile(topology_values, 0.95), percentile(capture_values, 0.95),
      percentile(projection_values, 0.95)
    ))
    test.ok(p95 >= 0)
    test.ok(p99 >= p95)
    markdown.live_render.release(view, "benchmark")
    markdown_model.close(buffer, "benchmark")
    config.markdown_live_editor = old_enabled
  end)
end)
