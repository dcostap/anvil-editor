local test = require "core.test"
local AdoptionQueue = require "core.treesitter.adoption_queue"

test.describe("Tree-sitter adoption queue", function()
  test.it("steps adoption within deterministic byte and record allowances", function()
    local queue = AdoptionQueue.new({ max_item_bytes = 256, max_item_records = 8 })
    local adopted = {}
    test.ok(queue:enqueue({ bytes = 60, records = 2, adopt = function() adopted[#adopted + 1] = "one" end }))
    test.ok(queue:enqueue({ bytes = 70, records = 2, adopt = function() adopted[#adopted + 1] = "two" end }))
    test.ok(queue:enqueue({ bytes = 80, records = 3, adopt = function() adopted[#adopted + 1] = "three" end }))

    local result = queue:step({ max_bytes = 140, max_records = 4 })
    test.equal(result.adopted, 2)
    test.equal(result.bytes, 130)
    test.equal(result.records, 4)
    test.same(adopted, { "one", "two" })
    test.equal(queue:count(), 1)

    result = queue:step({ max_bytes = 140, max_records = 4 })
    test.equal(result.adopted, 1)
    test.same(adopted, { "one", "two", "three" })
    test.equal(queue:count(), 0)
  end)

  test.it("discards stale work without adopting it", function()
    local queue = AdoptionQueue.new()
    local current_generation = 2
    local adopted = false
    test.ok(queue:enqueue({
      bytes = 20,
      records = 1,
      stale = function() return current_generation ~= 1 end,
      adopt = function() adopted = true end,
    }))

    local result = queue:step({ max_bytes = 100, max_records = 10 })
    test.equal(result.discarded, 1)
    test.not_ok(adopted)
    test.equal(queue:count(), 0)
  end)

  test.it("rejects an oversized atomic item", function()
    local queue = AdoptionQueue.new({ max_item_bytes = 128, max_item_records = 4 })
    local ok, reason = queue:enqueue({ bytes = 129, records = 1, adopt = function() end })
    test.not_ok(ok)
    test.equal(reason, "item-too-large")
    ok, reason = queue:enqueue({ bytes = 10, records = 5, adopt = function() end })
    test.not_ok(ok)
    test.equal(reason, "item-too-large")
    test.equal(queue:count(), 0)
  end)
end)
