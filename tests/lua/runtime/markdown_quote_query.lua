local Buffer = require "core.buffer"
local model = require "core.markdown.model"
local pool = require "core.worker_pool"
local test = require "core.test"
local system = require "system"

local buffer
local function ready(instance)
  local deadline = system.get_time() + 5
  repeat
    pool.system():drain({ max_ms = 5, max_messages = 64 })
    if instance.status == "ready" then return end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  test.fail("Markdown parse did not complete")
end

test.describe("Markdown quote discovery", function()
  test.after_each(function()
    if buffer then model.close(buffer, "test"); buffer = nil end
  end)

  test.it("returns only quotes within the requested lines", function()
    buffer = Buffer("quotes.md", "quotes.md", true)
    buffer:insert(1, 1, "# Heading\n\n- item with **bold**\n\n> [!NOTE]- Title\n> body\n\n```text\n> not a quote\n```\n")
    local instance = model.get(buffer)
    ready(instance)
    local nodes, reason = instance:quote_nodes_for_lines(1, #buffer.lines)
    test.not_nil(nodes, reason)
    test.equal(#nodes, 1)
    test.equal(nodes[1].type, "quote")
    test.equal(nodes[1].source.line1, 5)
    test.equal(nodes[1].source.col1, 1)
    test.equal(#instance:quote_nodes_for_lines(1, 3), 0)
    test.equal(instance:quote_nodes_for_lines(6, 6)[1].id, nodes[1].id)
  end)

  test.it("reports the same quote identity as the full node query", function()
    buffer = Buffer("quote-identity.md", "quote-identity.md", true)
    buffer:insert(1, 1, "Prose\n\n> [!TIP] Title\n> body\n")
    local instance = model.get(buffer)
    ready(instance)
    local full_id
    for _, node in ipairs(instance:nodes_for_lines(1, #buffer.lines)) do
      if node.type == "quote" then full_id = node.id end
    end
    test.not_nil(full_id)
    test.equal(instance:quote_nodes_for_lines(1, #buffer.lines)[1].id, full_id)
  end)

  test.it("agrees with the full node query about quotes inside comments", function()
    buffer = Buffer("quote-comment.md", "quote-comment.md", true)
    buffer:insert(1, 1, "Prose\n\n%%\n> [!NOTE]- Hidden\n> body\n%%\n\n> [!TIP]- Shown\n> body\n")
    local instance = model.get(buffer)
    ready(instance)
    local full = {}
    for _, node in ipairs(instance:nodes_for_lines(1, #buffer.lines)) do
      if node.type == "quote" then full[#full + 1] = node.source.line1 end
    end
    local quotes = {}
    for _, node in ipairs(instance:quote_nodes_for_lines(1, #buffer.lines)) do
      quotes[#quotes + 1] = node.source.line1
    end
    test.same(quotes, full)
  end)
end)
