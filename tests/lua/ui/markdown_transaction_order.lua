local Buffer = require "core.buffer"
local Editor = require "core.editor"
local markdown = require "core.markdown"
local model = require "core.markdown.model"
local worker_pool = require "core.worker_pool"
local test = require "core.test"

test.describe("Markdown edit scheduling", function()
  test.it("submits the parse before notifying line render providers", function()
    local buffer = Buffer(nil, nil, true)
    buffer:set_filename("transaction-order.md", nil)
    buffer:insert(1, 1, "plain text")
    local view = Editor(buffer)
    view.size.x, view.size.y = 600, 300
    view:set_wrapping_enabled(false)
    markdown.live_render.refresh_view(view)
    local instance = test.not_nil(model.peek(buffer))
    local deadline = system.get_time() + 10
    repeat
      local pool = worker_pool.current_system()
      if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
      if instance.status == "ready" then break end
      coroutine.yield(0.01)
    until system.get_time() >= deadline
    test.equal(instance.status, "ready", instance.reason)

    local status
    view:add_line_render_provider("observe-parse-state", {
      on_text_transaction = function() status = instance.status end,
    })
    buffer:insert(1, 6, "new ")
    test.equal(status, "pending", "the worker must start before edit projection")
  end)
end)
