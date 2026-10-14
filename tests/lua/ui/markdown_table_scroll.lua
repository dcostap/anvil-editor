local Buffer = require "core.buffer"
local config = require "core.config"
local Editor = require "core.editor"
local linewrapping = require "core.linewrapping"
local markdown = require "core.markdown"
local model = require "core.markdown.model"
local pool = require "core.worker_pool"
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
