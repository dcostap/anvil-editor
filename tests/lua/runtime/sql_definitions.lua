local test = require "core.test"
local native = require "sql_server_native"

test.describe("SQL definitions", function()
  test.it("refuses invalid object names before connecting", function()
    test.equal(type(native.read_definition), "function")
    local options = { server = "must-not-connect.invalid", database = "unused", integrated = true }
    for _, name in ipairs({ "", "bad\0name", string.rep("x", 514) }) do
      test.not_ok(pcall(native.read_definition, options, "dbo", name))
    end
  end)

  test.it("changes only the module declaration when generating ALTER", function()
    local source = "-- CREATE is a comment\n/* header */ CREATE OR ALTER VIEW [dbo].[v] AS SELECT 'CREATE' AS [text];"
    local altered = native.module_script(source, "ALTER")
    test.equal(altered, "-- CREATE is a comment\n/* header */ ALTER VIEW [dbo].[v] AS SELECT 'CREATE' AS [text];")
    test.equal(native.module_script(altered, "CREATE"),
      "-- CREATE is a comment\n/* header */ CREATE VIEW [dbo].[v] AS SELECT 'CREATE' AS [text];")
    test.equal(native.module_script("SELECT 'CREATE VIEW'", "ALTER"), nil)
    for _, text in ipairs({ "", "/* unterminated", "CREATE VIEW\0x", "CREATE VIEW \255", string.rep(" ", 512 * 1024 + 1) }) do
      test.equal(native.module_script(text, "ALTER"), nil)
    end
  end)
end)
