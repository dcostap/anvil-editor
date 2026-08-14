local core = require "core"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local test = require "core.test"
local trimwhitespace = require "plugins.trimwhitespace"

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

local function text(buffer)
  return table.concat(buffer.lines)
end

test.describe("trimwhitespace selection states", function()
  test.before_each(function(context)
    context.previous_active_view = core.active_view
  end)

  test.after_each(function(context)
    if context.previous_active_view then
      core.set_active_view(context.previous_active_view)
    end
    for _, buffer in ipairs(context.buffers or {}) do
      buffer:on_close()
    end
  end)

  test.it("preserves trailing whitespace before inactive view carets", function(context)
    local buffer = Buffer()
    set_text(buffer, "aa   \nbb   \ncc   ")
    local main = TextView(buffer)
    local side = TextView(buffer)
    context.buffers = { buffer }

    main:with_selection_state(function()
      buffer:set_selection(1, 1, 1, 1)
    end)
    side:with_selection_state(function()
      buffer:set_selection(2, 5, 2, 5)
    end)
    core.set_active_view(main)

    trimwhitespace.trim(buffer)

    test.equal(text(buffer), "aa\nbb  \ncc\n")
    test.same(side:get_selection_state().selections, { 2, 5, 2, 5 })
  end)
end)
