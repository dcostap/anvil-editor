local test = require "core.test"
local native = require "sql_server_native"
local options = { server = "must-not-connect.invalid", database = "unused", integrated = true }

test.describe("SQL execution input", function()
  test.it("refuses invalid batches before opening a connection", function()
    test.skip_if(PLATFORM ~= "Windows", "ODBC execution requires Windows")
    for _, text in ipairs({ "", "SELECT\0 1", "\255", string.rep("x", 256 * 1024 + 1) }) do
      local result = native.execute(options, text, 1000, 30)
      test.ok(result.error:find("SQL text", 1, true))
      test.same(result.results, {})
    end
  end)

  test.it("carries real results and cancellation through the worker in the isolated probe", function()
    local server = os.getenv("ANVIL_SQL_TEST_SERVER")
    test.skip_if(os.getenv("ANVIL_SQL_INTEGRATION") ~= "1" or not server,
      "Run the opt-in SQL Server integration test")
    test.ok(server:match("^%(localdb%)\\AnvilTest_%x+$"))
    local backend = require "plugins.sql_server.backend"
    local pipe = test.not_nil(os.getenv("ANVIL_SQL_TEST_PIPE"))
    test.ok(pipe:match("^np:\\\\%.\\pipe\\LOCALDB#[%x]+\\tsql\\query$"))
    local connection = { server = pipe, database = "AnvilTest", integrated = true, encrypt = false }
    local function await(reply)
      local deadline = system.get_time() + 45
      while not reply.value and system.get_time() < deadline do coroutine.yield(0.01) end
      return test.not_nil(reply.value)
    end
    local reply = {}
    test.not_nil(backend.read_schema(connection, function(value, err) reply.value = value or { error = err } end))
    local catalog = await(reply)
    test.equal(catalog.database, "AnvilTest")
    local definition
    reply = {}
    test.not_nil(backend.read_definition(connection, { schema = "sales", name = "child" }, function(value, err)
      reply.value = value or { error = err }
    end))
    definition = await(reply)
    test.equal(definition.error, nil)
    test.ok(definition.create:find("IDENTITY(7,3)", 1, true))
    test.ok(definition.create:find("REFERENCES [sales].[parent]", 1, true))
    test.ok(definition.create:find("[CK_amount] CHECK", 1, true))
    test.ok(definition.create:find("INCLUDE ([amount])", 1, true))
    local copy = definition.create:gsub("%[sales%]%.%[child%]", "[roundtrip].[child]")
    reply = {}
    backend.execute(connection, copy, function(value) reply.value = value end)
    test.equal(await(reply).error, nil)
    reply = {}
    backend.read_definition(connection, { schema = "roundtrip", name = "child" }, function(value, err)
      reply.value = value or { error = err }
    end)
    test.equal(await(reply).create, copy)
    for _, object in ipairs({ "customer_names", "list_customers" }) do
      reply = {}
      backend.read_definition(connection, { schema = "sales", name = object }, function(value, err)
        reply.value = value or { error = err }
      end)
      local source = await(reply)
      test.equal(source.error, nil)
      test.ok(source.create:match("^CREATE "))
      test.ok(source.alter:match("^ALTER "))
    end
    local schema_job = test.not_nil(backend.read_schema(connection, function() end))
    test.ok(schema_job:cancel())
    reply = {}
    test.not_nil(backend.execute(connection,
      "SELECT N'Ada' AS name, CAST(NULL AS nvarchar(1)) AS absent, N'' AS empty_value; SELECT 7 AS id",
      function(value) reply.value = value end))
    local result = await(reply)
    test.equal(result.error, nil)
    test.equal(#result.results, 2)
    test.same(result.results[1].rows[1].cells, { "Ada", false, "" })
    test.equal(result.results[1].distinct_values[2].counts[false], 1)
    test.equal(result.results[2].rows[1].cells[1], "7")

    reply = {}
    local handle = test.not_nil(backend.execute(connection, "WAITFOR DELAY '00:00:20'; SELECT 1",
      function(value) reply.value = value end))
    coroutine.yield(0.2)
    handle:cancel()
    test.ok(await(reply).cancelled)
  end)
end)
