local core = require "core"
local RootPanel = require "core.rootpanel"
local test = require "core.test"
local View = require "core.view"

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

  test.it("keeps scrollbar geometry synchronized with the final relayout", function()
    local old_active_view = core.active_view
    local ok, err = pcall(function()
      local root = RootPanel()
      root.position.x, root.position.y = 0, 0
      root.size.x, root.size.y = 1000, 600

      local left = View()
      left.scrollable = true
      function left:get_scrollable_size() return 2000 end
      root.root_node:add_view(left)

      local right = View()
      right.scrollable = true
      function right:get_scrollable_size() return 2000 end
      local update = right.update
      function right:update()
        update(self)
        self.size.x = 300
      end
      root.root_node:split("right", right, { x = true })
      right.size.x = 100

      root:update()

      test.equal(left.v_scrollbar.rect.x, left.position.x)
      test.equal(left.v_scrollbar.rect.y, left.position.y)
      test.equal(left.v_scrollbar.rect.w, left.size.x)
      test.equal(left.v_scrollbar.rect.h, left.size.y)
    end)
    core.active_view = old_active_view
    if not ok then error(err, 0) end
  end)
end)
