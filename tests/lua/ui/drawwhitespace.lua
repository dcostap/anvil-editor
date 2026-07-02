local command = require "core.command"
local config = require "core.config"
local style = require "core.style"
local Doc = require "core.doc"
local DocView = require "core.docview"
local linewrapping = require "core.linewrapping"
local test = require "core.test"

require "plugins.drawwhitespace"

local function set_text(doc, text)
  doc.lines = {}
  for line in (text .. "\n"):gmatch("(.-\n)") do
    doc.lines[#doc.lines + 1] = line
  end
  if #doc.lines == 0 then doc.lines[1] = "\n" end
  doc:clear_undo_redo()
  doc:clean()
  doc:set_selection(1, 1)
end

local function new_view(text)
  local doc = Doc()
  set_text(doc, text or "")
  local view = DocView(doc)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 1000, 1000
  return doc, view
end

local function with_fake_draw_text(fn)
  local old_draw_text = renderer.draw_text
  renderer.draw_text = function(_, text, x)
    return x + #tostring(text)
  end
  local ok, err = pcall(fn)
  renderer.draw_text = old_draw_text
  if not ok then error(err) end
end

test.describe("draw-whitespace DocView drawing", function()
  test.before_each(function()
    command.perform "draw-whitespace:enable"
  end)

  test.it("skips whitespace work for lines without visible marker characters", function()
    local doc, view = new_view("abc")
    local visible_cols_called = false
    view.get_visible_cols_range = function()
      visible_cols_called = true
      return 1, 1
    end

    with_fake_draw_text(function()
      view:draw_line_text(1, 0, 0)
    end)

    test.equal(visible_cols_called, false)
    doc:on_close()
  end)

  test.it("clips tab marker draw calls before handing them to the renderer", function()
    local tab_count = 1000
    local doc, view = new_view(string.rep("\t", tab_count))
    view.size.x = 80
    view.get_visible_cols_range = function()
      return 1, tab_count
    end

    local marker_calls = 0
    local old_draw_text = renderer.draw_text
    renderer.draw_text = function(_, text, x)
      if tostring(text):find("→", 1, true) then marker_calls = marker_calls + 1 end
      return x + #tostring(text)
    end
    local ok, err = pcall(function()
      local x, y = view:get_line_screen_position(1)
      view:draw_line_text(1, x, y)
    end)
    renderer.draw_text = old_draw_text
    if not ok then error(err) end

    test.ok(marker_calls <= 2, "expected visible tab markers to be batched before renderer.draw_text")
    doc:on_close()
  end)

  test.it("draws wrapped leading space markers on continuation rows", function()
    local doc, view = new_view(string.rep(" ", 128) .. "2 de 112")
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
    linewrapping.update_docview_breaks(view)

    local marker_rows = {}
    local old_draw_rect_grid = renderer.draw_rect_grid
    local old_draw_text = renderer.draw_text
    local old_draw_text_known_bounds = renderer.draw_text_known_bounds
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
    renderer.draw_rect_grid = old_draw_rect_grid
    renderer.draw_text = old_draw_text
    renderer.draw_text_known_bounds = old_draw_text_known_bounds
    cfg.mode = old_mode
    cfg.indent = old_indent
    cfg.wrapping_indent = old_wrapping_indent
    cfg.width_override = old_width_override
    cfg.require_tokenization = old_require_tokenization
    doc:on_close()
    if not ok then error(err) end

    local row_count = 0
    for _ in pairs(marker_rows) do row_count = row_count + 1 end
    test.ok(row_count >= 2, "expected whitespace markers on wrapped continuation rows")
  end)

  test.it("does not build x-cache when whitespace runs are outside the visible columns", function()
    local doc, view = new_view("abc   def")
    view.get_visible_cols_range = function()
      return 1, 1
    end

    local old_test_font = style.syntax_fonts.__drawwhitespace_test
    style.syntax_fonts.__drawwhitespace_test = view:get_font()
    local get_render_line_calls = 0
    local old_get_render_line = doc.highlighter.get_render_line
    doc.highlighter.get_render_line = function(self, ...)
      get_render_line_calls = get_render_line_calls + 1
      return old_get_render_line(self, ...)
    end

    local ok, err = pcall(function()
      with_fake_draw_text(function()
        view:draw_line_text(1, 0, 0)
      end)
    end)
    doc.highlighter.get_render_line = old_get_render_line
    style.syntax_fonts.__drawwhitespace_test = old_test_font
    if not ok then error(err) end

    test.equal(get_render_line_calls, 1)
    doc:on_close()
  end)
end)
