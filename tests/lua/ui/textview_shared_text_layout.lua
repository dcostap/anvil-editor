local Buffer = require "core.buffer"
local TextView = require "core.textview"
local config = require "core.config"
local linewrapping = require "core.linewrapping"
local preview_text_view = require "plugins.fuzzy_searcher.preview_text_view"
local test = require "core.test"

local function make_view(context, text)
  local buffer = Buffer("shared-text-layout.txt", "shared-text-layout.txt", true)
  buffer:insert(1, 1, text)
  buffer:clear_undo_redo()
  local view = TextView(buffer)
  view.discard_buffer_on_close = true
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 400, view:get_line_height() * 4
  view:set_wrapping_enabled(true)
  context.views[#context.views + 1] = view
  context.buffers[#context.buffers + 1] = buffer
  linewrapping.complete_async_reconstruction(view)
  view:update()
  return view, buffer
end

local function layout_width(view, line)
  return view:get_plain_text_layout(line).width
end

local function make_preview(context, text)
  local buffer = Buffer(nil, nil, true)
  buffer:insert(1, 1, text)
  local view = preview_text_view.new(buffer)
  context.views[#context.views + 1] = view
  return view, buffer
end

test.describe("TextView shared text layouts", function()
  test.before_each(function(context)
    context.views = {}
    context.buffers = {}
    local wrapping = config.plugins.linewrapping
    context.wrapping = {}
    for key, value in pairs(wrapping) do context.wrapping[key] = value end
    -- Keep every fixture line on one visual row.
    wrapping.width_override = nil
    wrapping.mode = "letter"
    wrapping.indent = false
  end)

  test.after_each(function(context)
    for key, value in pairs(context.wrapping or {}) do
      config.plugins.linewrapping[key] = value
    end
    for _, view in ipairs(context.views or {}) do view:on_close() end
    for _, buffer in ipairs(context.buffers or {}) do buffer:on_close() end
  end)

  test.it("measures a changed line with its new text", function(context)
    local view, buffer = make_view(context, "alpha\n")
    local font = test.not_nil(view:get_font())
    test.equal(layout_width(view, 1), font:get_width("alpha"))

    buffer:insert(1, 6, " beta")
    view:update()

    test.equal(layout_width(view, 1), font:get_width("alpha beta"))
  end)

  test.it("keeps lines with matching token shapes separate", function(context)
    -- Equal byte length and equal token kinds: only the text differs.
    local view = make_view(context, "漢\nabc\n")
    local font = test.not_nil(view:get_font())
    local wide_char = font:get_width("漢")
    local ascii = font:get_width("abc")
    test.ok(wide_char ~= ascii, "fixture needs two different line widths")

    test.equal(layout_width(view, 1), wide_char)
    test.equal(layout_width(view, 2), ascii)
  end)

  test.it("measures an edited unwrapped line after scrolling past cached rows", function(context)
    local lines = { "漢" }
    for i = 2, 300 do lines[i] = "row " .. i end
    local view, buffer = make_view(context, table.concat(lines, "\n") .. "\n")
    view:set_wrapping_enabled(false)
    local font = test.not_nil(view:get_font())

    for i = 1, 300 do layout_width(view, i) end
    test.equal(layout_width(view, 1), font:get_width("漢"))

    buffer:insert(1, 1, "new ")
    test.equal(layout_width(view, 1), font:get_width("new 漢"))
  end)

  test.it("keeps preview text measurements separate across Buffers", function(context)
    local first, buffer = make_preview(context, "漢\n")
    local second = make_preview(context, "abc\n")
    local font = first:get_font()
    test.ok(font:get_width("漢") ~= font:get_width("abc"))

    test.equal(layout_width(first, 1), font:get_width("漢"))
    test.equal(layout_width(second, 1), font:get_width("abc"))
    test.equal(layout_width(first, 1), font:get_width("漢"))

    buffer:insert(1, 1, "new ")
    test.equal(layout_width(first, 1), font:get_width("new 漢"))
    test.equal(layout_width(second, 1), font:get_width("abc"))
  end)

  test.it("uses each preview Font and follows its size changes", function(context)
    local first = make_preview(context, "shared text\n")
    local second = make_preview(context, "shared text\n")
    local font = first:get_font()
    local larger = font:copy(font:get_size() * 2)
    second.get_font = function() return larger end

    test.equal(layout_width(first, 1), font:get_width("shared text"))
    test.equal(layout_width(second, 1), larger:get_width("shared text"))
    test.ok(layout_width(second, 1) > layout_width(first, 1))

    larger:set_size(font:get_size() * 3)
    test.equal(layout_width(second, 1), larger:get_width("shared text"))
    test.equal(layout_width(first, 1), font:get_width("shared text"))
  end)
end)
