local Buffer = require "core.buffer"
local test = require "core.test"

test.describe("Buffer transaction observers", function()
  test.it("calls observers in registration order and keeps replacement positions", function()
    local buffer = Buffer(nil, nil, true)
    local calls = {}
    local ids = { "order-z", "order-a", "order-y", "order-b", "order-x", "order-c" }
    for _, id in ipairs(ids) do
      Buffer.register_text_transaction_handler(id, function(changed)
        if changed == buffer then calls[#calls + 1] = id end
      end)
    end
    Buffer.register_text_transaction_handler("order-y", function(changed)
      if changed == buffer then calls[#calls + 1] = "replacement" end
    end)
    Buffer.unregister_text_transaction_handler("order-b")
    buffer:insert(1, 1, "text")
    for _, id in ipairs(ids) do Buffer.unregister_text_transaction_handler(id) end
    test.same(calls, { "order-z", "order-a", "replacement", "order-x", "order-c" })
  end)
end)
