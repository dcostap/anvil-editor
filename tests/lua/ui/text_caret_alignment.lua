local Buffer = require "core.buffer"
local Editor = require "core.editor"
local linewrapping = require "core.linewrapping"
local test = require "core.test"

local function check_drawn_boundaries(view)
  local drawn = {}
  local old_draw, old_known = renderer.draw_text, renderer.draw_text_known_bounds
  local function capture(font, text, x, y, color, options)
    if color == require("core.style").syntax.normal then
      drawn[#drawn + 1] = { text = text, x = x, y = y,
        layout = font:text_layout(text, options) }
    end
    return x + font:get_width(text, options)
  end
  renderer.draw_text = capture
  renderer.draw_text_known_bounds = function(font, text, x, y, _, _, _, _, color, options)
    return capture(font, text, x, y, color, options)
  end
  local ok, err = pcall(function() view:draw_line_text(1, 0, 0) end)
  renderer.draw_text, renderer.draw_text_known_bounds = old_draw, old_known
  if not ok then error(err, 0) end
  test.ok(#drawn > 0, "the view must draw text")

  local source_col = 1
  for _, run in ipairs(drawn) do
    for offset = 0, #run.text - 1 do
      local byte = run.text:byte(offset + 1)
      if byte < 128 or byte >= 192 then
        local col = source_col + offset
        local expected = run.x + run.layout:width_at(offset)
        test.ok(math.abs(view:get_col_x_offset(1, col) - expected) < 0.01,
          string.format("column %d does not match drawn text", col))
        if view.wrapped_settings then
          local idx = linewrapping.get_line_idx_col_count(view, 1, col)
          local _, hit_col = linewrapping.get_line_col_from_index_and_x(view, idx, expected)
          test.equal(hit_col, col, "mouse hit does not match drawn text")
        else
          test.equal(view:get_x_offset_col(1, expected), col,
            "mouse hit does not match drawn text")
        end
      end
    end
    source_col = source_col + #run.text
  end
  test.equal(source_col, #view.buffer.lines[1], string.format(
    "the view must draw the complete line (end %d, expected %d, last text %q)",
    source_col, #view.buffer.lines[1], drawn[#drawn].text))
end

test.describe("Shaped text alignment", function()
  for _, wrapped in ipairs { false, true } do
    test.it("shares drawn boundaries with carets and mouse hits (wrapped=" .. tostring(wrapped) .. ")", function()
      local text = "a || b\t|> c │ café á next"
      local buffer = Buffer()
      buffer:insert(1, 1, text)
      local view = Editor(buffer)
      view.size.x, view.size.y = 2000, 300
      view:set_wrapping_enabled(wrapped)
      if wrapped then linewrapping.complete_async_reconstruction(view) end
      check_drawn_boundaries(view)

      local col = assert(text:find("á", 1, true)) + 1
      local layout = view:get_font():text_layout(text, { tab_offset = 0 })
      local x1, _, x2 = view:iter_text_range_screen_segments(1, col, col + 2, 0, 0)()
      test.equal(x1, layout:width_at(col - 1), "selection start must match drawn text")
      test.equal(x2, layout:width_at(col + 1), "selection end must match drawn text")
    end)
  end

  test.it("keeps wrapped continuation rows aligned after edits", function()
    local buffer = Buffer()
    buffer:insert(1, 1, string.rep("ab || á next ", 12))
    local view = Editor(buffer)
    view.size.x, view.size.y = 280, 1000
    view:set_wrapping_enabled(true)
    linewrapping.complete_async_reconstruction(view)
    local _, _, rows = linewrapping.get_line_idx_col_count(view, 1)
    test.ok(rows > 1, "the text must wrap")
    check_drawn_boundaries(view)
    buffer:insert(1, 1, "prefix | ")
    linewrapping.complete_async_reconstruction(view)
    check_drawn_boundaries(view)
  end)

  test.it("remeasures drawn boundaries after the font changes", function()
    local style = require "core.style"
    local old_font = style.code_font
    local buffer = Buffer()
    buffer:insert(1, 1, "a || á next")
    local view = Editor(buffer)
    view.size.x, view.size.y = 2000, 300
    view:set_wrapping_enabled(false)
    local ok, err = pcall(function()
      check_drawn_boundaries(view)
      style.code_font = renderer.font.load(
        DATADIR .. "/fonts/FiraSans-Regular.ttf", 19, { ligatures = true })
      check_drawn_boundaries(view)
    end)
    style.code_font = old_font
    if not ok then error(err, 0) end
  end)
end)
