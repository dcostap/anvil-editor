local test = require "core.test"

test.describe("SQL context", function()
  test.it("keeps the complete name range when the caret is at its first character", function()
    local sql = require "sql_server_native"
    for _, name in ipairs({ "customers", "[customers]", '"customers"' }) do
      local prefix = "SELECT * FROM sales."
      local context = sql.context(prefix .. name .. " WHERE id = 1", #prefix)
      test.equal(context.mode, "table")
      test.equal(context.qualifier, "sales")
      test.equal(context.prefix, "")
      test.equal(context.start, #prefix)
      test.equal(context["end"], #prefix + #name)
    end
  end)
  test.it("finds the table of an alias declared after the caret", function()
    local sql = require "sql_server_native"
    local text = "SELECT c.na FROM sales.customers AS c WHERE c.id = 1"
    local context = sql.context(text, #"SELECT c.na")
    test.equal(context.prefix, "na")
    test.equal(context.qualifier, "c")
    test.equal(context.mode, "column")
    test.same(context.sources, { { schema = "sales", name = "customers", alias = "c" } })
  end)
  test.it("finds object names in calls and declarations without a SELECT", function()
    local sql = require "sql_server_native"
    for _, prefix in ipairs({ "EXEC ", "CREATE OR ALTER PROCEDURE ", "ALTER TABLE ", "INSERT INTO ", "UPDATE " }) do
      local text = prefix .. "[sales].[customers]"
      local context = sql.context(text, #text)
      test.equal(context.mode, "object")
      test.equal(context.qualifier, "sales")
      test.equal(context.prefix, "customers")
    end
  end)
  test.it("recognizes a projection star but not multiplication or COUNT", function()
    local sql = require "sql_server_native"
    local text = "SELECT c.* FROM sales.customers c"
    local context = sql.context(text, #"SELECT c.*")
    test.ok(context.star)
    test.equal(context.qualifier, "c")
    test.equal(text:sub(context.start + 1, context["end"]), "*")
    for _, prefix in ipairs({ "SELECT DISTINCT *", "SELECT TOP (10) *", "SELECT TOP 10 PERCENT WITH TIES c.*" }) do
      test.ok(sql.context(prefix .. " FROM sales.customers c", #prefix).star)
    end
    for _, prefix in ipairs({ "SELECT COUNT(*", "SELECT 2 *" }) do
      test.not_ok(sql.context(prefix .. ") FROM sales.customers", #prefix).star)
    end
  end)
end)
