local test = require "core.test"
local metadata = require "plugins.file_metadata"

test.describe("Shared file metadata", function()
  test.it("shows folder contents instead of a file size", function()
    local parts = metadata.parts({ type = "dir", size = 9999, count = 7 })
    local values = {}
    for _, part in ipairs(parts) do values[part.id] = part.text end
    test.equal(values.size, "7")
    test.is_nil(values.ignored)
  end)

  test.it("marks ignored entries without adding a label to ordinary files", function()
    local ignored = metadata.parts({ type = "file", git = { kind = "ignored" } })
    local ordinary = metadata.parts({ type = "file" })
    local found = false
    for _, part in ipairs(ignored) do
      if part.id == "ignored" then test.equal(part.text, "ignored"); found = true end
    end
    test.ok(found)
    for _, part in ipairs(ordinary) do test.ok(part.id ~= "ignored") end
  end)
end)
