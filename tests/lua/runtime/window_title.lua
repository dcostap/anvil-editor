local core = require "core"
local test = require "core.test"


test.describe("Window title", function()
  test.before_each(function(context)
    context.original_root_project = core.root_project
  end)

  test.after_each(function(context)
    core.root_project = context.original_root_project
  end)

  test.test("uses only the root Project name", function()
    core.root_project = function()
      return { path = table.concat({ "C:", "projects", "glp4" }, PATHSEP) }
    end

    test.equal(core.get_window_title(), "glp4")
  end)

  test.test("falls back to Anvil when no root Project is loaded", function()
    core.root_project = function() return nil end

    test.equal(core.get_window_title(), "Anvil")
  end)
end)
