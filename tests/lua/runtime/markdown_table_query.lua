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

test.describe("Markdown table discovery", function()
  test.after_each(function()
    if buffer then model.close(buffer, "test"); buffer = nil end
  end)

  test.it("returns only tables within the requested lines", function()
    buffer = Buffer("tables.md", "tables.md", true)
    buffer:insert(1, 1, "# Heading\n\n**Prose**\n\n| Name | Value |\n| --- | --- |\n| A | B |\n\n```text\n| Not | a table |\n| --- | --- |\n```\n")
    local instance = model.get(buffer)
    ready(instance)
    local nodes, reason = instance:table_nodes_for_lines(1, #buffer.lines)
    test.not_nil(nodes, reason)
    test.equal(#nodes, 1)
    test.equal(nodes[1].type, "table")
    test.equal(nodes[1].source.line1, 5)
    test.equal(nodes[1].source.col1, 1)
    local id = nodes[1].id
    test.equal(#instance:table_nodes_for_lines(1, 3), 0)
    test.equal(instance:table_nodes_for_lines(7, 7)[1].id, id)
    local _, limit_reason = instance:table_nodes_for_lines(1, #buffer.lines, { limit = 1 })
    test.equal(limit_reason, "limit", "partial discovery must not claim that no tables exist")
  end)

  test.it("discovers added tables and removes deleted tables after publication", function()
    buffer = Buffer("changing-tables.md", "changing-tables.md", true)
    buffer:insert(1, 1, "Plain prose\n")
    local instance = model.get(buffer)
    ready(instance)
    test.equal(#instance:table_nodes_for_lines(1, #buffer.lines), 0)
    buffer:insert(2, 1, "\n| Key | Value |\n| --- | --- |\n| A | B |\n")
    ready(instance)
    test.equal(#instance:table_nodes_for_lines(1, #buffer.lines), 1)
    buffer:remove(2, 1, #buffer.lines, 1)
    ready(instance)
    test.equal(#instance:table_nodes_for_lines(1, #buffer.lines), 0)
  end)
end)
