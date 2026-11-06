local test = require "core.test"

test.describe("SQL context", function()
  test.it("finds the table of an alias declared after the caret", function()
    local sql = require "sql_server_native"
    local text = "SELECT c.na FROM sales.customers AS c WHERE c.id = 1"
    local context = sql.context(text, #"SELECT c.na")
    test.equal(context.prefix, "na")
    test.equal(context.qualifier, "c")
    test.equal(context.mode, "column")
    test.same(context.sources, { { schema = "sales", name = "customers", alias = "c" } })
  end)
end)
