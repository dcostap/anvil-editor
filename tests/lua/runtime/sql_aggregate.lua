local test = require "core.test"
local aggregate = require "plugins.sql_server.aggregate"

test.describe("SQL result aggregates", function()
  test.it("sums decimal cells exactly and keeps the text of the minimum and maximum", function()
    test.equal(aggregate.summary({ "0.1", "0.2", false, "12.3400", " -2 " }),
      "5 cells · 1 NULL · Sum 10.64 · Avg 2.66 · Min -2 · Max 12.3400")
    test.equal(aggregate.summary({ "9007199254740991", "1" }),
      "2 cells · Sum ≈9.00719925474099e+15 · Avg ≈4.5035996273705e+15 · Min 1 · Max 9007199254740991")
    test.equal(aggregate.summary({ "1.5E-3", "2" }), "2 cells · Sum ≈2.0015 · Avg ≈1.00075 · Min 1.5E-3 · Max 2")
    test.equal(aggregate.summary({ "1", "2", "2" }), "3 cells · Sum 5 · Avg 1.6667 · Min 1 · Max 2")
  end)

  test.it("counts cells without number aggregates when a cell is not a number", function()
    test.equal(aggregate.summary({ "12", "north", false }), "3 cells · 1 NULL")
    test.equal(aggregate.summary({ "0x10", "inf" }), "2 cells")
    test.equal(aggregate.summary({ false, false }), "2 cells · 2 NULL")
  end)
end)
