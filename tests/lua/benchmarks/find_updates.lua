local core = require "core"
local command = require "core.command"
local Editor = require "core.editor"
local panes = require "core.panes"
local system = require "system"
local test = require "core.test"
require "plugins.intellij_find"

-- Run explicitly. Include the edit callback cost, not just the following update.
test.it("measures edits with an open Find in a large Buffer", function()
  local buffer = core.open_buffer()
  buffer.lines = {}
  for i = 1, 456328 do
    buffer.lines[i] = string.format("int %s_%d = 123456789;\n",
      i % 1000 == 0 and "sqlite3_open" or "sqlite_value", i)
  end
  local view = panes.place(function() return Editor(buffer) end, { placement = "new", focus = true })
  view.size.x, view.size.y = 2560, 1351
  view:set_wrapping_enabled(false)
  view:update()
  test.ok(command.perform("editor:find"))
  core.active_view:set_text("sqlite3_open")
  for _, open in ipairs { true, false } do
    if not open then test.ok(command.perform("editor:find_close")) end
    local edit_ms, update_ms = 0, 0
    for _ = 1, 5 do
      view:with_selection_state(function() buffer:set_selection(228164, 2) end)
      local start = system.get_time()
      view:with_selection_state(function() buffer:text_input("x") end)
      edit_ms = edit_ms + (system.get_time() - start) * 1000
      start = system.get_time()
      view:update()
      update_ms = update_ms + (system.get_time() - start) * 1000
    end
    print(string.format("FIND_UPDATE open=%s edit_ms=%.3f update_ms=%.3f", tostring(open), edit_ms / 5, update_ms / 5))
  end
  buffer:clean()
  panes.reset_for_tests()
end)
