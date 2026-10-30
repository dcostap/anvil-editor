local core = require "core"
local panes = require "core.panes"
local RootPanel = require "core.rootpanel"
local View = require "core.view"
local test = require "core.test"

-- Seam: editor control operations, shared by MCP and other local clients.
test.describe("Agent editor control", function()
  local saved, control
  test.before_each(function()
    saved = { root = core.root_panel, active = core.active_view, focus = core.set_active_view }
    panes.reset_for_tests()
    core.set_active_view = function(view) core.active_view = view end
    core.root_panel = RootPanel()
    control = require("core.control").new()
  end)
  test.after_each(function()
    panes.reset_for_tests()
    core.root_panel, core.active_view, core.set_active_view = saved.root, saved.active, saved.focus
  end)
  test.it("creates a named split once without taking focus", function()
    local source = panes.create { factory = function() return View() end }
    local args = { action = "split", pane = source.id, direction = "right", request_id = "split-one" }
    local result = control:call("pane", args, "test-client")
    test.ok(result.pane and result.pane ~= source.id)
    test.equal(panes.find(result.pane).group, source.group)
    test.equal(panes.active(), source)
    test.equal(core.active_view, source.current_view)
    test.equal(control:call("pane", args, "test-client").pane, result.pane)
    test.equal(#panes.ordered(), 2)
    local state = control:call("workspace_state", {}, "test-client")
    test.ok(state.panes[result.pane])
    local ok = pcall(function()
      control:call("pane", { action = "create", request_id = "split-one" }, "test-client")
    end)
    test.equal(ok, false, "A retry key cannot describe different work")
  end)
  test.it("keeps close confirmation and rejects unrecognized fields", function()
    local approve
    local pane = panes.create { factory = function()
      local view = View()
      function view:can_close(done) approve = done end
      return view
    end }
    local result = control:call("pane", { action = "close", pane = pane.id, request_id = "close-one" }, "test-client")
    test.equal(result.status, "confirmation_required")
    test.ok(panes.find(pane.id))
    test.equal(pcall(function()
      control:call("pane", { action = "close", pane = pane.id, force = true, request_id = "close-force" }, "test-client")
    end), false)
    approve()
    test.is_nil(panes.find(pane.id))
  end)
end)
