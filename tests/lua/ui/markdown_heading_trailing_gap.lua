local config = require "core.config"
local core = require "core"
local Doc = require "core.doc"
local DocView = require "core.docview"
local linewrapping = require "core.linewrapping"
local markdown = require "core.markdown"
local markdown_model = require "core.markdown.model"
local style = require "core.style"
local test = require "core.test"
local worker_pool = require "core.worker_pool"

local function make_view(text)
  local doc = Doc("wrapped-heading-spacing.md", "wrapped-heading-spacing.md", true)
  doc:insert(1, 1, text)
  doc:clear_undo_redo()
  local view = DocView(doc)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 150, 200
  view:set_wrapping_enabled(true)
  return view, doc
end

local function refresh(view)
  markdown.live_render.refresh_view(view)
  local instance = markdown_model.peek(view.doc)
  if not instance then return end
  local deadline = system.get_time() + 5
  while instance.status ~= "ready" and system.get_time() < deadline do
    local pool = worker_pool.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if instance.status ~= "ready" then system.sleep(0.001) end
  end
  test.equal(instance.status, "ready", instance.reason)
end

test.describe("Markdown wrapped heading spacing", function()
  test.before_each(function(context)
    context.old_markdown_live_editor = config.markdown_live_editor
    config.markdown_live_editor = true
  end)

  test.after_each(function(context)
    config.markdown_live_editor = context.old_markdown_live_editor
  end)

  test.it("keeps heading spacing above the first row instead of below the final row", function()
    local source = "# This rendered heading wraps across several visual rows in a narrow editor"
    local view, doc = make_view(source .. "\nbody")
    doc:set_selection(1, #source + 1)
    refresh(view)

    local first_row, _, row_count = linewrapping.get_line_idx_col_count(view, 1)
    test.ok(row_count > 1)
    local final_row = first_row + row_count - 1
    local render_line = test.not_nil(view:get_line_render(1))
    local content_height = test.not_nil(render_line.text_row_height)
    test.equal(view:get_visual_row_height(final_row), content_height)

    local old_draw_text = renderer.draw_text
    local text_ys = {}
    renderer.draw_text = function(font, text, x, y, color, opts)
      text_ys[y] = true
      return x + font:get_width(text, opts)
    end
    local ok, err = pcall(function() view:draw_line_text(1, 0, 0) end)
    renderer.draw_text = old_draw_text
    if not ok then error(err, 0) end

    local ordered_ys = {}
    for y in pairs(text_ys) do ordered_ys[#ordered_ys + 1] = y end
    table.sort(ordered_ys)
    test.equal(#ordered_ys, row_count)
    local final_row_y = view:get_visual_row_y_offset(final_row)
      - view:get_visual_row_y_offset(first_row)
    test.ok(
      ordered_ys[1] > ordered_ys[#ordered_ys] - final_row_y,
      "leading spacing must affect only the first wrapped heading row"
    )

    local old_draw_rect = renderer.draw_rect
    local highlight_height
    renderer.draw_rect = function(_, _, _, height, color)
      if color == style.line_highlight then highlight_height = height end
    end
    ok, err = pcall(function() view:draw_current_line_highlights(1, 2) end)
    renderer.draw_rect = old_draw_rect
    if not ok then error(err, 0) end

    test.equal(highlight_height, content_height)
  end)
end)
