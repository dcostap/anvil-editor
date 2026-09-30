local core = require "core"
local command = require "core.command"
local test = require "core.test"
local Editor = require "core.editor"
local panes = require "core.panes"
local native = require "line_search"
require "plugins.intellij_find"

local function with_pending_find(check)
  local buffer = core.open_buffer()
  buffer:text_input(("hit miss\n"):rep(12000))
  local view = panes.place(function() return Editor(buffer) end, { placement = "new", focus = true })
  view.size.x, view.size.y = 800, 600
  view:set_wrapping_enabled(false)
  view:with_selection_state(function() buffer:set_selection(6000, 5) end)
  command.perform("editor:find")
  local input = core.active_view
  local state = input.local_find_state
  -- Control the native timer boundary so this test does not depend on CPU speed.
  local mt = debug.getmetatable(native.begin({}))
  local advance = mt.advance
  mt.advance = function(index, lines, query, compiled, sensitive, first, _, ...)
    return advance(index, lines, query, compiled, sensitive, first, .000000001, ...)
  end
  local ok, err = pcall(function()
    input:set_text("hit")
    view:update()
    test.ok(state.info:find("Searching", 1, true), "count must remain pending")
    check(buffer, view)
  end)
  mt.advance = advance
  command.perform("editor:find_close")
  buffer:clean()
  panes.reset_for_tests()
  if not ok then error(err) end
end

test.it("reveals the caret's nearest match while the final count is pending", function()
  with_pending_find(function(buffer, view)
    local selected = view:with_selection_state(function()
      local l1, c1, l2, c2 = buffer:get_selection(true)
      return { l1, c1, l2, c2 }
    end)
    test.same(selected, { 6001, 1, 6001, 4 })
  end)
end)

test.it("keeps a later caret position after an edit during a pending search", function()
  with_pending_find(function(buffer, view)
    view:with_selection_state(function()
      buffer:set_selection(8000, 5)
      buffer:insert(8000, 5, "new")
    end)
    local expected = view:with_selection_state(function() return { buffer:get_selection(true) } end)
    view:update()
    view:update()
    test.same(view:with_selection_state(function() return { buffer:get_selection(true) } end), expected)
  end)
end)
