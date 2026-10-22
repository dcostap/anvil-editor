local core = require "core"
local config = require "core.config"
local Editor = require "core.editor"
local keymap = require "core.keymap"
local markdown = require "core.markdown"
local footnotes = require "core.markdown.footnotes"
local model = require "core.markdown.model"
local panes = require "core.panes"
local style = require "core.style"
local workers = require "core.worker_pool"
local test = require "core.test"

local WIDE_TABLE = "| Status | Functions | Share | Bytes | Byte share | Meaning |\n"
  .. "|---|---|---|---|---|---|\n"
  .. "| matching | 5,013 | 92.39% | 871.04 KB | 68.81% | byte for byte identical to the original build output |\n"

local function ready(instance)
  local deadline = system.get_time() + 5
  repeat
    local pool = workers.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if instance.status == "ready" then return end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  test.equal(instance.status, "ready", instance.reason)
end

local function open_view(context, text, width)
  local buffer = core.open_buffer()
  buffer:set_filename("wide-tables.md", nil)
  buffer:insert(1, 1, text)
  buffer:clear_undo_redo()
  context.buffer = buffer
  local view = panes.place(function() return Editor(buffer) end, { placement = "new", focus = true })
  buffer:set_selection(#buffer.lines, 1)
  markdown.live_render.refresh_view(view)
  ready(test.not_nil(model.peek(buffer)))
  core.set_active_view(view)
  -- The root layout sizes Panes while the parse runs, so size the view after it.
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = width, 600
  view:update()
  test.ok(core.centered_editor.should_center(view), "the view has no reading lane")
  return view, buffer
end

local function find_line(view, pattern)
  for line, text in ipairs(view.buffer.lines) do
    if text:find(pattern, 1, true) then return line end
  end
  test.fail("line not found: " .. pattern)
end

-- The screen span of a table row's last cell.
local function last_cell(view, line)
  local render = test.not_nil(view:get_line_render(line))
  local x, found = view:get_line_screen_position(line), nil
  for _, fragment in ipairs(render.fragments or {}) do
    if fragment.table_cell then found = { x1 = x, x2 = x + fragment.width, fragment = fragment } end
    x = x + (fragment.width or 0)
  end
  return test.not_nil(found)
end

local function lane_right(view)
  local lane_x, lane_width = core.centered_editor.get_lane_rect(view)
  return lane_x + lane_width
end

test.describe("Markdown tables wider than the reading lane", function()
  test.before_each(function(context)
    panes.reset_for_tests()
    context.live = config.markdown_live_editor
    context.interactive = config.markdown_live_interactive_tables
    context.lane_width = config.plugins.centered_editor.markdown_live_max_width
    -- A narrow lane leaves the free space right of it to the table.
    config.plugins.centered_editor.markdown_live_max_width = 400
    config.markdown_live_editor = true
    config.markdown_live_interactive_tables = true
  end)

  test.after_each(function(context)
    panes.reset_for_tests()
    local buffer = context.buffer
    if buffer then
      if buffer:is_dirty() then buffer:clean() end
      for i = #core.buffers, 1, -1 do
        if core.buffers[i] == buffer then table.remove(core.buffers, i) end
      end
    end
    config.markdown_live_editor = context.live
    config.markdown_live_interactive_tables = context.interactive
    config.plugins.centered_editor.markdown_live_max_width = context.lane_width
  end)

  test.it("extends a wide table into the free space right of the lane", function(context)
    local view = open_view(context, "Some prose.\n\n" .. WIDE_TABLE .. "\nend", 2000)
    local body = find_line(view, "| matching")
    local cell = last_cell(view, body)
    test.ok(cell.x2 > lane_right(view), "the table stops at the reading lane")
    test.equal(view:get_line_render(body).horizontal_scroll, nil,
      "the table scrolls instead of using the free space")
    test.ok(cell.x2 <= view.position.x + view.size.x, "the table leaves the view")
  end)

  test.it("keeps a code block's background inside the lane", function(context)
    local view = open_view(context, "Some prose.\n\n```\nplain code\n```\n\nend", 2000)
    local code_rects = {}
    local old_rect, old_rounded = renderer.draw_rect, renderer.draw_rounded_rect
    local old_text = renderer.draw_text
    local old_push, old_pop = core.push_clip_rect, core.pop_clip_rect
    local function record(x, _, w, _, _, color)
      if color == style.markdown_live_code_background then
        code_rects[#code_rects + 1] = { x = x, w = w }
      end
    end
    renderer.draw_rect = function(x, y, w, h, color) record(x, y, w, h, nil, color) end
    renderer.draw_rounded_rect = record
    renderer.draw_text = function(font, text, x) return x + font:get_width(text) end
    core.push_clip_rect, core.pop_clip_rect = function() end, function() end
    local ok, err = pcall(view.draw, view)
    renderer.draw_rect, renderer.draw_rounded_rect = old_rect, old_rounded
    renderer.draw_text = old_text
    core.push_clip_rect, core.pop_clip_rect = old_push, old_pop
    if not ok then error(err, 0) end
    test.ok(#code_rects > 0, "the code block has no background")
    for _, rect in ipairs(code_rects) do
      test.ok(rect.x + rect.w <= lane_right(view), string.format(
        "the code background ends at %d, past the lane at %d",
        rect.x + rect.w, lane_right(view)
      ))
    end
  end)

  test.it("stops a wide table before the footnote cards", function(context)
    local view = open_view(context,
      "Some prose[^1].\n\n[^1]: a note\n\n" .. WIDE_TABLE .. "\nend", 2000)
    local body = find_line(view, "| matching")
    local cell = last_cell(view, body)
    test.ok(cell.x2 > lane_right(view), "the table stops at the reading lane")
    local layout = test.not_nil(footnotes.layout(view))
    test.equal(layout.mode, "margin")
    for _, card in ipairs(layout.cards) do
      test.ok(card.x >= cell.x2, "a card overlaps the table")
    end
  end)

  test.it("places the caret in a cell right of the lane when it is clicked", function(context)
    local view, buffer = open_view(context, "Some prose.\n\n" .. WIDE_TABLE .. "\nend", 2000)
    local body = find_line(view, "| matching")
    local cell = last_cell(view, body)
    test.ok(cell.x1 > lane_right(view), "the last cell starts inside the lane")
    local _, y = view:get_line_screen_position(body)
    local x = math.floor((cell.x1 + cell.x2) / 2)
    y = y + math.floor(view:get_line_height() / 2)
    if not view:on_mouse_pressed("left", x, y, 1) then keymap.on_mouse_pressed("left", x, y, 1) end
    view:on_mouse_released("left", x, y)
    local line, col = buffer:get_selection()
    test.equal(line, body)
    local source = buffer.lines[body]
    local cell_start = source:find("byte for byte", 1, true)
    test.ok(col >= cell_start and col <= #source, "the caret is outside the clicked cell")
  end)
end)
