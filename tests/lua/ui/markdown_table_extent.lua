local Buffer = require "core.buffer"
local Editor = require "core.editor"
local markdown = require "core.markdown"
local model = require "core.markdown.model"
local pool = require "core.worker_pool"
local test = require "core.test"
local system = require "system"

local view
local function ready()
  local instance = model.peek(view.buffer)
  local deadline = system.get_time() + 5
  repeat
    pool.system():drain({ max_ms = 5, max_messages = 64 })
    if instance.status == "ready" then return end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  test.fail("Markdown parse did not complete")
end

test.describe("Markdown table horizontal extent", function()
  test.after_each(function()
    if view then view.buffer:clean(); view:on_close(); view = nil end
  end)

  test.it("preserves overflow through prose edits and restores it after undo", function()
    local buffer = Buffer(nil, nil, true)
    buffer:set_filename("table-extent.md", nil)
    buffer:insert(1, 1, "Prose\n\n| A | B | C | D | E | F | G | H | I |\n|---|---|---|---|---|---|---|---|---|\n|1|2|3|4|5|6|7|8|9|\n")
    view = Editor(buffer)
    view.size.x, view.size.y = 500, 400
    view:set_wrapping_enabled(true)
    markdown.live_render.refresh_view(view)
    ready()
    local width = view:get_h_scrollable_size()
    test.ok(width > view.size.x, "table must expose horizontal overflow")

    view:with_selection_state(function() buffer:insert(1, 2, "more prose ") end)
    test.equal(view:get_h_scrollable_size(), width)
    ready()
    test.equal(view:get_h_scrollable_size(), width)

    buffer:clear_undo_redo()
    view:with_selection_state(function() buffer:remove(3, 1, #buffer.lines, 1) end)
    ready()
    test.ok(view:get_h_scrollable_size() <= view.size.x, "deleting the table must remove overflow")
    view:with_selection_state(function() buffer:undo() end)
    ready()
    test.equal(view:get_h_scrollable_size(), width)
    view.size.x = width * 2
    test.ok(view:get_h_scrollable_size() <= view.size.x, "a wide viewport must not overflow")
  end)
end)
