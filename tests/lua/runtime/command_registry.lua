local command = require "core.command"
local keymap = require "core.keymap"
local test = require "core.test"

local function command_exists(name)
  return command.map[name] ~= nil
end

test.describe("Command Registry integrity", function()
  test.it("uses canonical command name syntax", function()
    local invalid = {}
    for name in pairs(command.map) do
      if not name:match("^[a-z][a-z0-9_]*:[a-z][a-z0-9_]*$") then
        invalid[#invalid + 1] = name
      end
    end
    table.sort(invalid)
    test.same(invalid, {})
  end)

  test.it("does not register removed command namespaces", function()
    local forbidden = { buffer = true, doc = true, node = true, ["tool-window"] = true }
    local stale = {}
    for name in pairs(command.map) do
      local namespace = name:match("^([^:]+):")
      if forbidden[namespace] then stale[#stale + 1] = name end
    end
    table.sort(stale)
    test.same(stale, {})
  end)

  test.it("has a registered command for every key binding", function()
    local missing = {}
    for stroke, bindings in pairs(keymap.map) do
      for _, name in ipairs(bindings) do
        if type(name) == "string" and not command_exists(name) then
          missing[#missing + 1] = stroke .. " -> " .. name
        end
      end
    end
    table.sort(missing)
    test.same(missing, {})
  end)

end)
