local test = require "core.test"
local style = require "core.style"

test.describe("syntax color hierarchy", function()
  test.test("semantic child keys fall back dynamically to broad parents", function()
    local syntax = style.syntax
    local old_type = syntax["type"]
    local old_class = rawget(syntax, "type.class")
    local old_property = rawget(syntax, "variable.property")
    local old_variable = syntax["variable"]

    local new_type = { 11, 22, 33, 44 }
    local new_variable = { 55, 66, 77, 88 }
    syntax["type"] = new_type
    syntax["type.class"] = nil
    syntax["variable"] = new_variable
    syntax["variable.property"] = nil

    test.equal(syntax["type.class"], new_type)
    test.equal(syntax["type.class.default_library"], new_type)
    test.equal(syntax["variable.property"], new_variable)
    test.equal(syntax["variable.property.readonly"], new_variable)

    syntax["type.class"] = old_class
    syntax["type"] = old_type
    syntax["variable.property"] = old_property
    syntax["variable"] = old_variable
  end)
end)
