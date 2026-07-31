local config = require "core.config"
local Doc = require "core.doc"
local DocView = require "core.docview"
local linewrapping = require "core.linewrapping"
local markdown = require "core.markdown"
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

local function wait_ready(instance, timeout)
  local deadline = system.get_time() + (timeout or 10)
  local max_drain_ms = 0
  repeat
    local pool = worker_pool.current_system()
    if pool then
      local started = system.get_time()
      pool:drain({ max_ms = 5, max_messages = 128 })
      max_drain_ms = math.max(max_drain_ms, (system.get_time() - started) * 1000)
    end
    if instance.status == "ready" then return true, max_drain_ms end
    coroutine.yield(0.005)
  until system.get_time() >= deadline
  return instance.status == "ready", max_drain_ms
end

test.describe("Markdown live layout benchmark", function()
  test.it("reports cold whole-Document metrics and long rendered-line wrapping", function()
    local old_enabled = config.markdown_live_editor
    config.markdown_live_editor = true

    local metric_doc = Doc("cold-metric-benchmark.md", "cold-metric-benchmark.md", true)
    metric_doc:insert(1, 1, representative_source(100 * 1024))
    metric_doc:clear_undo_redo()
    local metric_view = DocView(metric_doc)
    metric_view.size.x, metric_view.size.y = 1200, 800
    metric_view:set_wrapping_enabled(false)
    markdown.live_render.refresh_view(metric_view)
    local metric_model = test.not_nil(markdown_model.peek(metric_doc))
    test.ok(wait_ready(metric_model), metric_model.reason)
    local metric_started = system.get_time()
    local metric_cache = test.not_nil(metric_view:get_visual_row_metric_cache())
    local metric_ms = (system.get_time() - metric_started) * 1000
    local render_started = system.get_time()
    for line = 1, math.min(60, #metric_doc.lines) do metric_view:get_line_render(line) end
    local post_metric_render_ms = (system.get_time() - render_started) * 1000

    local publication_doc = Doc(
      "publication-wrap-benchmark.md", "publication-wrap-benchmark.md", true
    )
    publication_doc:insert(1, 1, representative_source(25 * 1024))
    publication_doc:clear_undo_redo()
    local publication_view = DocView(publication_doc)
    publication_view.size.x, publication_view.size.y = 717, 800
    publication_view:set_wrapping_enabled(true)
    local publication_started = system.get_time()
    markdown.live_render.refresh_view(publication_view)
    local publication_model = test.not_nil(markdown_model.peek(publication_doc))
    local publication_ready, publication_callback_drain_ms = wait_ready(publication_model)
    test.ok(publication_ready, publication_model.reason)
    linewrapping.complete_async_reconstruction(publication_view)
    local publication_wrap_ms = (system.get_time() - publication_started) * 1000

    local wrap_results = {}
    for _, bytes in ipairs({ 1000, 2000, 4000 }) do
      local unit = "representative words for rendered wrapping "
      local text = unit:rep(math.ceil(bytes / #unit)):sub(1, bytes)
      local doc = Doc("long-wrap-benchmark.md", "long-wrap-benchmark.md", true)
      doc:insert(1, 1, text)
      doc:clear_undo_redo()
      local view = DocView(doc)
      view.size.x, view.size.y = 500, 800
      view:set_wrapping_enabled(false)
      view:add_line_render_provider("long-wrap-benchmark", {
        render_line = function(_, owner)
          return {
            source_text = text,
            fragments = {
              {
                source_col1 = 1,
                source_col2 = #text + 1,
                text = text,
                font = owner:get_font(),
              },
            },
          }
        end,
      })
      local started = system.get_time()
      local splits = linewrapping.compute_line_breaks_from_col(
        doc, view:get_font(), 1, 500, "word", 1, 0, view
      )
      wrap_results[#wrap_results + 1] = {
        bytes = bytes,
        ms = (system.get_time() - started) * 1000,
        rows = #splits,
      }
      view:remove_line_render_provider("long-wrap-benchmark")
    end

    local multi_text = ("A/0123456789"):rep(5000)
    local multi_doc = Doc(
      "long-multi-fragment-wrap-benchmark.md",
      "long-multi-fragment-wrap-benchmark.md",
      true
    )
    multi_doc:insert(1, 1, multi_text)
    multi_doc:clear_undo_redo()
    local multi_view = DocView(multi_doc)
    multi_view.size.x, multi_view.size.y = 500, 800
    multi_view:set_wrapping_enabled(false)
    local cut1, cut2 = 12, 32
    multi_view:add_line_render_provider("long-multi-fragment-wrap-benchmark", {
      render_line = function(_, owner)
        return {
          source_text = multi_text,
          fragments = {
            {
              source_col1 = 1, source_col2 = cut1,
              text = multi_text:sub(1, cut1 - 1), font = owner:get_font(),
            },
            {
              source_col1 = cut1, source_col2 = cut2,
              text = multi_text:sub(cut1, cut2 - 1), font = owner:get_font(),
            },
            {
              source_col1 = cut2, source_col2 = #multi_text + 1,
              text = multi_text:sub(cut2), font = owner:get_font(),
            },
          },
        }
      end,
    })
    local multi_started = system.get_time()
    local multi_splits = linewrapping.compute_line_breaks_from_col(
      multi_doc, multi_view:get_font(), 1, 500, "word", 1, 0, multi_view
    )
    local multi_wrap_ms = (system.get_time() - multi_started) * 1000
    multi_view:remove_line_render_provider("long-multi-fragment-wrap-benchmark")

    print(string.format(
      "Markdown cold metric benchmark: bytes=%d lines=%d metric_ms=%.3f post_metric_render_60_ms=%.3f total_height=%.1f provider_queries=%d sparse_skips=%d",
      #table.concat(metric_doc.lines), #metric_doc.lines, metric_ms,
      post_metric_render_ms, metric_cache.total_height,
      metric_view:get_render_cache_diagnostics().metric_provider_queries,
      metric_view:get_render_cache_diagnostics().metric_sparse_skips
    ))
    print(string.format(
      "Markdown cold semantic publication benchmark: bytes=%d lines=%d callback_drain_ms=%.3f ready_and_committed_ms=%.3f",
      #table.concat(publication_doc.lines), #publication_doc.lines,
      publication_callback_drain_ms, publication_wrap_ms
    ))
    for _, result in ipairs(wrap_results) do
      print(string.format(
        "Markdown rendered wrap benchmark: bytes=%d rows=%d wrap_ms=%.3f",
        result.bytes, result.rows, result.ms
      ))
      test.ok(result.rows > 1)
    end
    print(string.format(
      "Markdown multi-fragment rendered wrap benchmark: bytes=%d rows=%d wrap_ms=%.3f",
      #multi_text, #multi_splits, multi_wrap_ms
    ))
    test.ok(#multi_splits > 1)
    io.stdout:flush()
    test.equal(metric_cache.row_count, #metric_doc.lines)
    markdown.live_render.release(metric_view, "benchmark")
    markdown_model.close(metric_doc, "benchmark")
    markdown.live_render.release(publication_view, "benchmark")
    markdown_model.close(publication_doc, "benchmark")
    config.markdown_live_editor = old_enabled
  end)
end)
