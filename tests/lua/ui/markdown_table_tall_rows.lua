local Buffer = require "core.buffer"
local config = require "core.config"
local core = require "core"
local Editor = require "core.editor"
local linewrapping = require "core.linewrapping"
local markdown = require "core.markdown"
local model = require "core.markdown.model"
local pool = require "core.worker_pool"
local style = require "core.style"
local test = require "core.test"
local system = require "system"

local view
local function ready()
  local instance = model.peek(view.buffer)
  local deadline = system.get_time() + 5
  repeat
    pool.system():drain({ max_ms = 5, max_messages = 64 })
    if instance.status == "ready" then
      linewrapping.complete_async_reconstruction(view)
      return
    end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  test.fail("Markdown parse did not complete")
end

local function find_line(pattern)
  for line, text in ipairs(view.buffer.lines) do
    if text:find(pattern, 1, true) then return line end
  end
  test.fail("line not found: " .. pattern)
end

-- The table background rectangles that one frame draws.
local function draw_table_backgrounds()
  local rects = {}
  local old_rect, old_text, old_poly = renderer.draw_rect, renderer.draw_text, renderer.draw_poly
  local old_known_bounds = renderer.draw_text_known_bounds
  renderer.draw_rect = function(x, y, w, h, color)
    if color == style.markdown_live_table_background then
      rects[#rects + 1] = { x1 = x, y1 = y, x2 = x + w, y2 = y + h }
    end
  end
  renderer.draw_text = function(font, text, x) return x + font:get_width(text) end
  renderer.draw_text_known_bounds = function(_, _, x, _, _, _, w) return x + w end
  renderer.draw_poly = function() end
  renderer.begin_frame(core.window)
  local ok, err = pcall(function() view:draw() end)
  renderer.end_frame()
  renderer.draw_rect, renderer.draw_text, renderer.draw_poly = old_rect, old_text, old_poly
  renderer.draw_text_known_bounds = old_known_bounds
  if not ok then error(err, 0) end
  return rects
end

local LONG_CELL = string.rep("a long explanation that wraps ", 12)

test.describe("Markdown table rows taller than the view top", function()
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

  -- A footnote adds rows to the document besides its lines.
  test.it("draws the cells of a row whose top is above the view", function()
    local buffer = Buffer(nil, nil, true)
    buffer:set_filename("table-tall.md", nil)
    buffer:insert(1, 1, "Prose[^1].\n\n[^1]: a note\n\n| Status | Count | Meaning |\n|---|---|---|\n"
      .. "| matching | 5 | " .. LONG_CELL .. " |\n"
      .. "| other | 6 | short |\n"
      .. "\nafter\n")
    buffer:clear_undo_redo()
    view = Editor(buffer)
    view.size.x, view.size.y = 500, 300
    view:set_wrapping_enabled(true)
    buffer:set_selection(#buffer.lines, 1)
    markdown.live_render.refresh_view(view)
    ready()
    view:update()

    local body = find_line("| matching")
    local _, top = view:get_line_screen_position(body)
    local _, bottom = view:get_line_screen_position(body + 1)
    local height = bottom - top
    test.ok(height > view:get_line_height() * 6, "the row is not tall")
    local row_y = top - view.position.y + view.scroll.y

    for _, hidden in ipairs({ 0.25, 0.5, 0.75, 0.9 }) do
      -- Scroll the row's top part above the view.
      view.scroll.y = row_y + math.floor(height * hidden)
      view.scroll.to.y = view.scroll.y
      view:update()
      local probe_y = view.position.y + 2
      local covered = false
      for _, rect in ipairs(draw_table_backgrounds()) do
        if rect.y1 <= probe_y and rect.y2 >= probe_y then covered = true end
      end
      test.ok(covered, string.format("no cell drew at the view top with %.0f%% of the row hidden", hidden * 100))
    end
  end)
end)
