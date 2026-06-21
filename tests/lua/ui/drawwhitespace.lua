local command = require "core.command"
local style = require "core.style"
local Doc = require "core.doc"
local DocView = require "core.docview"
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
