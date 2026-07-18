local core = require "core"
local RootPanel = require "core.rootpanel"
local test = require "core.test"

test.describe("RootPanel", function()
  test.test("new Root Panels provide a Left Pane fallback when focus belongs elsewhere", function()
    local old_active_view = core.active_view
    local root = RootPanel()
    local external_view = {}
    core.active_view = external_view

    local ok, node = pcall(function()
      return root:get_active_node_default()
    end)

    core.active_view = old_active_view
    test.equal(ok, true)
    test.equal(node, root.root_node)
    test.equal(root:get_left_pane(), root.root_node)
  end)

  test.test("Root Panels without an attached pane tree still fall back to a leaf", function()
    local old_active_view = core.active_view
    local root = RootPanel()
    root.root_node.pane_id = nil
    local external_view = {}
    core.active_view = external_view

    local ok, node = pcall(function()
      return root:get_active_node_default()
    end)

    core.active_view = old_active_view
    test.equal(ok, true)
    test.equal(node, root.root_node)
    test.equal(root:get_left_pane(), root.root_node)
  end)
end)
