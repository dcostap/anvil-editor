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
require "plugins.selectionhighlight"
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

local function last_cell(line)
  local render = test.not_nil(view:get_line_render(line))
  local x, found = 0, nil
  for _, fragment in ipairs(render.fragments or {}) do
    if fragment.table_cell then found = { x = x, fragment = fragment } end
    x = x + (fragment.width or 0)
  end
  return test.not_nil(found)
end

local function last_cell_visible(line)
  local cell = last_cell(line)
  local line_x = view:get_line_screen_position(line)
  local center = line_x + cell.x + cell.fragment.width / 2
  return center >= view.position.x + view:get_gutter_width()
    and center <= view.position.x + view.size.x
end

test.describe("Markdown Table Scroll", function()
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

  test.it("draws matches of the selection where a scrolled table shows them", function()
    local buffer = Buffer(nil, nil, true)
    buffer:set_filename("table-scroll.md", nil)
    buffer:insert(1, 1, "Prose\n\n| A | B | C | D | E | F | G | H | I |\n"
      .. "|---|---|---|---|---|---|---|---|---|\n"
      .. "|alpha one|beta two|gamma three|delta four|epsilon five|zeta six|eta seven|theta eight|iota nine|\n"
      .. "\nafter nine\n")
    buffer:clear_undo_redo()
    view = Editor(buffer)
    view.size.x, view.size.y = 500, 400
    view:set_wrapping_enabled(true)
    buffer:set_selection(#buffer.lines, 1)
    markdown.live_render.refresh_view(view)
    ready()
    local body = find_line("alpha one")
    view:scroll_to_make_visible(body, last_cell(body).fragment.text_source_col1, true)
    local after = find_line("after nine")
    buffer:set_selection(after, 7, after, 11)
    view:update()

    local cell = last_cell(body)
    local cell_x1 = view:get_line_screen_position(body) + cell.x
    local cell_x2 = cell_x1 + cell.fragment.width
    local matches = {}
    local old_rect, old_text, old_poly = renderer.draw_rect, renderer.draw_text, renderer.draw_poly
    local old_known_bounds = renderer.draw_text_known_bounds
    renderer.draw_rect = function(x, y, w, h, color)
      if color == style.selectionhighlight then
        matches[#matches + 1] = { x1 = x, x2 = x + w }
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

    test.equal(#matches, 1)
    test.ok(matches[1].x1 >= cell_x1 and matches[1].x2 <= cell_x2,
      "the match was not drawn inside its scrolled cell")
  end)

  test.it("keeps a table's scroll through edits above it and their undo", function()
    local buffer = Buffer(nil, nil, true)
    buffer:set_filename("table-scroll.md", nil)
    buffer:insert(1, 1, "Prose\n\n| A | B | C | D | E | F | G | H | I |\n"
      .. "|---|---|---|---|---|---|---|---|---|\n"
      .. "|alpha one|beta two|gamma three|delta four|epsilon five|zeta six|eta seven|theta eight|iota nine|\n"
      .. "\nafter\n")
    buffer:clear_undo_redo()
    view = Editor(buffer)
    view.size.x, view.size.y = 500, 400
    view:set_wrapping_enabled(true)
    buffer:set_selection(#buffer.lines, 1)
    markdown.live_render.refresh_view(view)
    ready()
    local body = find_line("alpha one")
    test.not_ok(last_cell_visible(body), "the last column starts out of view")
    local col = last_cell(body).fragment.text_source_col1
    view:scroll_to_make_visible(body, col, true)
    test.ok(last_cell_visible(body), "the table did not scroll to its last column")
    buffer:set_selection(#buffer.lines, 1)

    view:with_selection_state(function() buffer:insert(1, 1, "More prose\n\n") end)
    ready()
    test.equal(find_line("alpha one"), body + 2)
    test.ok(last_cell_visible(body + 2), "an edit above the table reset its scroll")

    view:with_selection_state(function() buffer:undo() end)
    ready()
    test.ok(last_cell_visible(body), "undo reset the table's scroll")
    test.equal(view.scroll.x, 0)
  end)
end)
