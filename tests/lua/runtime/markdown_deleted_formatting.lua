local Buffer = require "core.buffer"
local markdown_model = require "core.markdown.model"
local test = require "core.test"
local worker_pool = require "core.worker_pool"

local function wait_ready(instance)
  local deadline = system.get_time() + 5
  repeat
    local pool = worker_pool.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if instance.status == "ready" then return end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  test.equal(instance.status, "ready", instance.reason)
end

test.describe("Deleted Markdown formatting", function()
  test.it("removes code spans when cutting a list item before an unchanged item", function()
    local buffer = Buffer("deleted-formatting.md", "deleted-formatting.md", true)
    buffer:insert(1, 1, "- `removed`\n- plain text\n")
    local instance = markdown_model.get(buffer)
    wait_ready(instance)
    local before = test.not_nil(instance:nodes_for_lines(1, 2))
    local has_code = false
    for _, node in ipairs(before) do
      if node.type == "code" then has_code = true end
    end
    test.ok(has_code)

    buffer:remove(1, 1, 2, 1)
    wait_ready(instance)
    local nodes = test.not_nil(instance:nodes_for_lines(1, 1))
    markdown_model.close(buffer, "test")
    for _, node in ipairs(nodes) do
      test.not_equal(node.type, "code", "the deleted code span remains on the plain list item")
    end
  end)
end)
