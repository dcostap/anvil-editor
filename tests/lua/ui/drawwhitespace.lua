local command = require "core.command"
local config = require "core.config"
local style = require "core.style"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local linewrapping = require "core.linewrapping"
local test = require "core.test"

require "plugins.drawwhitespace"

local function set_text(buffer, text)
  buffer.lines = {}
  for line in (text .. "\n"):gmatch("(.-\n)") do
    buffer.lines[#buffer.lines + 1] = line
  end
  if #buffer.lines == 0 then buffer.lines[1] = "\n" end
  buffer:clear_undo_redo()
  buffer:clean()
  buffer:set_selection(1, 1)
end

local function new_view(text)
  local buffer = Buffer()
  set_text(buffer, text or "")
  local view = TextView(buffer)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 1000, 1000
  return buffer, view
end

test.describe("draw-whitespace Text View drawing", function()
  test.before_each(function()
    command.perform("editor:toggle_whitespace", true)
  end)

  test.it("draws wrapped leading space markers on continuation rows", function()
    local buffer, view = new_view(string.rep(" ", 128) .. "2 de 112")
    local cfg = config.plugins.linewrapping
    local old_mode = cfg.mode
    local old_indent = cfg.indent
    local old_wrapping_indent = cfg.wrapping_indent
    local old_width_override = cfg.width_override
    local old_require_tokenization = cfg.require_tokenization
    cfg.mode = "word"
    cfg.indent = true
    cfg.wrapping_indent = 6
    cfg.width_override = view:get_font():get_width(string.rep("x", 100))
    cfg.require_tokenization = false
    view:set_wrapping_enabled(true)
    linewrapping.update_textview_breaks(view)

    local marker_rows = {}
    local old_draw_rect = renderer.draw_rect
    local old_draw_rect_grid = renderer.draw_rect_grid
    local old_draw_text = renderer.draw_text
    local old_draw_text_known_bounds = renderer.draw_text_known_bounds
    renderer.draw_rect = function() end
    renderer.draw_rect_grid = function(_, y, _, _, _, count)
      if count and count > 0 then marker_rows[math.floor(y + 0.5)] = true end
    end
    renderer.draw_text = function(font, text, x, y)
      if tostring(text):find("·", 1, true) then marker_rows[math.floor((y or 0) + 0.5)] = true end
      return x + font:get_width(tostring(text))
    end
    renderer.draw_text_known_bounds = function(font, text, x, y)
      if tostring(text):find("·", 1, true) then marker_rows[math.floor((y or 0) + 0.5)] = true end
      return x + font:get_width(tostring(text))
    end

    local ok, err = pcall(function()
      local x, y = view:get_line_screen_position(1)
      view:draw_line_body(1, x, y)
    end)
    renderer.draw_rect = old_draw_rect
    renderer.draw_rect_grid = old_draw_rect_grid
    renderer.draw_text = old_draw_text
    renderer.draw_text_known_bounds = old_draw_text_known_bounds
    cfg.mode = old_mode
    cfg.indent = old_indent
    cfg.wrapping_indent = old_wrapping_indent
    cfg.width_override = old_width_override
    cfg.require_tokenization = old_require_tokenization
    buffer:on_close()
    if not ok then error(err) end

    local row_count = 0
    for _ in pairs(marker_rows) do row_count = row_count + 1 end
    test.ok(row_count >= 2, "expected whitespace markers on wrapped continuation rows")
  end)

end)
