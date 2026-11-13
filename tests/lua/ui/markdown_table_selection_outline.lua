local Buffer = require "core.buffer"
local config = require "core.config"
local Editor = require "core.editor"
local linewrapping = require "core.linewrapping"
local markdown = require "core.markdown"
local model = require "core.markdown.model"
local tables = require "core.markdown.tables"
local pool = require "core.worker_pool"
local style = require "core.style"
local system = require "system"
local test = require "core.test"

local view

test.describe("Markdown Table Selection Outline", function()
  test.before_each(function(context)
    context.live = config.markdown_live_editor
    context.interactive = config.markdown_live_interactive_tables
    config.markdown_live_editor = true
    config.markdown_live_interactive_tables = true
  end)

  test.after_each(function(context)
    if view then view.buffer:clean(); view:on_close(); view = nil end
    config.markdown_live_editor = context.live
    config.markdown_live_interactive_tables = context.interactive
  end)

  test.it("joins selection corners to straight edges at fractional screen positions", function()
    local buffer = Buffer(nil, nil, true)
    buffer:set_filename("selection-outline.md", nil)
    buffer:insert(1, 1, "| A | B |\n| --- | --- |\n| one | two |\n\nplain")
    buffer:clear_undo_redo()
    buffer:set_selection(5, 1)
    view = Editor(buffer)
    view.size.x, view.size.y = 500, 300
    markdown.live_render.refresh_view(view)
    local instance = model.peek(buffer)
    local deadline = system.get_time() + 10
    while instance.status ~= "ready" and system.get_time() < deadline do
      pool.system():drain({ max_ms = 5, max_messages = 64 })
      coroutine.yield(0.01)
    end
    test.equal(instance.status, "ready")
    linewrapping.complete_async_reconstruction(view)
    test.ok(tables.select_row(view, 1))
    view:prepare_line_body_draw_cache(1, 1)

    local old_rect, old_poly, old_text = renderer.draw_rect, renderer.draw_poly, renderer.draw_text
    local edges, corners
    local color = style.markdown_live_table_cell_selection_outline
    -- Match the native rectangle rounding and polygon coordinate conversion.
    renderer.draw_rect = function(x, y, w, h, paint)
      if paint == color then
        edges[#edges + 1] = {
          math.floor(x + 0.5), math.floor(y + 0.5),
          math.floor(x + w + 0.5), math.floor(y + h + 0.5),
        }
      end
    end
    renderer.draw_poly = function(paths, paint)
      if paint == color then
        for _, path in ipairs(paths) do
          -- Each curve starts and ends where it meets a straight edge.
          corners[#corners + 1] = { math.floor(path[1]), math.floor(path[2]) }
          corners[#corners + 1] = { math.floor(path[#path - 1]), math.floor(path[#path]) }
        end
      end
    end
    renderer.draw_text = function(font, text, x) return x + font:get_width(text) end
    local ok, err = pcall(function()
      for _, offset in ipairs({ 0.25, 0.75 }) do
        edges, corners = {}, {}
        view:draw_line_body(1, 100 + offset, 100 + offset)
        test.ok(#edges > 0 and #corners > 0, "the selection outline was not drawn")
        for _, point in ipairs(corners) do
          local joined = false
          for _, edge in ipairs(edges) do
            if (point[1] == edge[1] or point[1] == edge[3])
            and (point[2] == edge[2] or point[2] == edge[4]) then
              joined = true
              break
            end
          end
          test.ok(joined, "a rounded corner does not meet its straight edge")
        end
      end
    end)
    renderer.draw_rect, renderer.draw_poly, renderer.draw_text = old_rect, old_poly, old_text
    if not ok then error(err, 0) end
  end)
end)
