local Buffer = require "core.buffer"
local config = require "core.config"
local core = require "core"
local Editor = require "core.editor"
local linewrapping = require "core.linewrapping"
local markdown = require "core.markdown"
local model = require "core.markdown.model"
local pool = require "core.worker_pool"
local poi = require "core.poi"
local preview = require "core.poi_preview"
local style = require "core.style"
local test = require "core.test"
local gitdiff = require "plugins.gitdiff_highlight"
local system = require "system"

local TABLE = "Intro\n\n"
  .. "| Status | Count | Share |\n"
  .. "|---|---|---:|\n"
  .. "| matching | 5013 | 92.39% |\n"
  .. "| drift | 140 |  |\n"
  .. "| logic | 217 | 4.00% |\n"
  .. "\nAfter\n"
local CHANGED_LINE = 6

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

local function open_with_baseline(base_row)
  local buffer = Buffer(nil, nil, true)
  buffer:set_filename("table-change.md", nil)
  buffer:insert(1, 1, TABLE)
  buffer:clear_undo_redo()
  view = Editor(buffer)
  view.size.x, view.size.y = 900, 600
  view:set_wrapping_enabled(true)
  buffer:set_selection(1, 1)
  markdown.live_render.refresh_view(view)
  ready()
  local base_lines = {}
  for line, text in ipairs(buffer.lines) do
    base_lines[line] = line == CHANGED_LINE and base_row or text
  end
  gitdiff._set_state_for_tests(buffer, {
    is_in_repo = true, base_lines = base_lines,
    ranges = {{
      type = "modification", current_start = CHANGED_LINE, current_end = CHANGED_LINE + 1,
      base_start = CHANGED_LINE, base_end = CHANGED_LINE + 1,
    }},
    line_index = {},
  })
  test.ok(poi.navigate(view, 1))
  test.equal(buffer:get_selection(), CHANGED_LINE)
  view:update()
end

-- Screen bounds of one column of a rendered table row.
local function cell_bounds(line, column)
  local render = test.not_nil(view:get_line_render(line))
  local x = view:get_line_screen_position(line)
  for _, fragment in ipairs(render.fragments or {}) do
    if fragment.table_cell and fragment.table_column == column then
      return x, x + fragment.width
    end
    x = x + (fragment.width or 0)
  end
  test.fail("no cell " .. column .. " on line " .. line)
end

local function draw()
  local texts, rects = {}, {}
  local old_rect, old_text, old_poly = renderer.draw_rect, renderer.draw_text, renderer.draw_poly
  local old_known_bounds = renderer.draw_text_known_bounds
  renderer.draw_rect = function(x, y, w, h, color)
    rects[#rects + 1] = { x1 = x, x2 = x + w, y1 = y, y2 = y + h, color = color }
  end
  renderer.draw_text = function(font, text, x, y)
    texts[#texts + 1] = { text = text, x = x, y = y }
    return x + font:get_width(text)
  end
  renderer.draw_text_known_bounds = function(_, _, x, _, _, _, w) return x + w end
  renderer.draw_poly = function() end
  renderer.begin_frame(core.window)
  local ok, err = pcall(function() view:draw() end)
  renderer.end_frame()
  renderer.draw_rect, renderer.draw_text, renderer.draw_poly = old_rect, old_text, old_poly
  renderer.draw_text_known_bounds = old_known_bounds
  if not ok then error(err, 0) end
  return texts, rects
end

local function provider_entries()
  local entries = {}
  for row = 1, view:get_composed_visual_row_count() do
    local entry = view:get_visual_row_entry(row)
    if entry.type == "provider" then entries[#entries + 1] = entry end
  end
  return entries
end

test.describe("Markdown table file change previews", function()
  test.before_each(function(context)
    context.live = config.markdown_live_editor
    context.interactive = config.markdown_live_interactive_tables
    config.markdown_live_editor = true
    config.markdown_live_interactive_tables = true
  end)

  test.after_each(function(context)
    if view then
      preview.dismiss(view)
      view.buffer:clean()
      view:on_close()
      view = nil
    end
    config.markdown_live_editor = context.live
    config.markdown_live_interactive_tables = context.interactive
  end)

  test.it("shows a changed row's baseline cells in the table's columns", function()
    open_with_baseline("| drift | 140 | 2.58% |\n")
    local texts = draw()
    local x1, x2 = cell_bounds(CHANGED_LINE + 1, 3)
    local found
    for _, drawn in ipairs(texts) do
      test.equal(drawn.text:find("|", 1, true), nil, "drew raw table source: " .. drawn.text)
      if drawn.text == "2.58%" then found = drawn end
    end
    found = test.not_nil(found, "the baseline cell text was not drawn as a cell")
    test.ok(found.x >= x1 and found.x < x2, "the baseline cell is outside its column")
  end)

  test.it("marks the changed cell of the current row", function()
    open_with_baseline("| drift | 140 | 2.58% |\n")
    local _, rects = draw()
    local x1, x2 = cell_bounds(CHANGED_LINE, 3)
    local other1, other2 = cell_bounds(CHANGED_LINE, 1)
    local _, line_y = view:get_line_screen_position(CHANGED_LINE)
    local changed, unchanged
    for _, rect in ipairs(rects) do
      if rect.color == style.diff_insert_inline and rect.y1 >= line_y - 1
      and rect.y1 < line_y + view:get_line_height() then
        if rect.x1 >= x1 - 1 and rect.x2 <= x2 + 1 and rect.x2 > rect.x1 then changed = true end
        if rect.x1 < other2 and rect.x2 > other1 then unchanged = true end
      end
    end
    test.ok(changed, "the changed cell is not marked")
    test.ok(not unchanged, "an unchanged cell is marked")
  end)

  test.it("shows a baseline that does not fit the grid after the table", function()
    open_with_baseline("| drift | 140 |\n")
    local entries = provider_entries()
    test.ok(#entries > 0, "no preview rows")
    local last_table_line = CHANGED_LINE + 1
    for _, entry in ipairs(entries) do
      test.equal(entry.line, last_table_line)
      test.equal(entry.placement, "after")
    end
  end)
end)
