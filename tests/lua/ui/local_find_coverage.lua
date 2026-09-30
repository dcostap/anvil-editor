local core = require "core"
local command = require "core.command"
local test = require "core.test"
local panes = require "core.panes"
local Editor = require "core.editor"
local style = require "core.style"
require "plugins.intellij_find"

local function markers(view)
  local count = 0
  local draw = renderer.draw_rect
  local rounded = renderer.draw_rounded_rect
  renderer.draw_rounded_rect = function() end
  renderer.draw_rect = function(_, _, _, _, color)
    if color == style.search_overview or color == style.search_overview_secondary then
      count = count + 1
    end
  end
  local ok, err = pcall(view.draw_scrollbar, view)
  renderer.draw_rect = draw
  renderer.draw_rounded_rect = rounded
  if not ok then error(err) end
  return count
end

test.describe("Local Find coverage publication", function()
  test.after_each(function()
    command.perform("editor:find_close")
    panes.reset_for_tests()
  end)

  for _, wrapped in ipairs { false, true } do
    test.it("retains markers during " .. (wrapped and "wrapped" or "unwrapped") .. " edits", function()
      local buffer = core.open_buffer()
      buffer:text_input(("hit hit hit hit\n"):rep(3000))
      local view = panes.place(function() return Editor(buffer) end, { placement = "new", focus = true })
      view.size.x, view.size.y = 800, 600
      view:set_wrapping_enabled(wrapped)
      command.perform("editor:find")
      local input = core.active_view
      local state = input.local_find_state
      input:set_text("hit")
      for _ = 1, 10000 do
        view:update()
        if not state.pending and state.overview and state.overview.complete then break end
        coroutine.yield()
      end
      test.ok(markers(view) > 0, "initial coverage must be visible")
      buffer:insert(100, 1, "x")
      test.ok(markers(view) > 0, "the previous complete coverage must remain visible before update")
      for _ = 1, 10 do
        view:update()
        test.ok(markers(view) > 0, "coverage must remain visible during replacement")
        coroutine.yield()
      end
      buffer:clean()
    end)
  end
end)
