local core = require "core"
local BufferRegistry = require "core.buffer_registry"
local Editor = require "core.editor"
local panes = require "core.panes"
local View = require "core.view"
local test = require "core.test"

local SavedView = View:extend()
function SavedView:new(name)
  SavedView.super.new(self)
  self.name = name
end
function SavedView:get_name() return self.name end

local function factory(name) return function() return SavedView(name) end end
local function save_view(view)
  if view.skip_save then return nil end
  return { module = "test.saved_view", state = { name = view.name } }
end
local function load_view(saved)
  if saved.state and saved.state.invalid then return nil end
  return SavedView(saved.state.name)
end
local function names()
  local result = {}
  for _, pane in ipairs(panes.ordered()) do result[#result + 1] = pane.current_view:get_name() end
  return result
end

test.describe("Pane Workspace state", function()
  local set_active_view

  test.before_each(function()
    panes.reset_for_tests()
    set_active_view = core.set_active_view
    core.set_active_view = function(view) core.active_view = view end
  end)

  test.after_each(function()
    panes.reset_for_tests()
    core.set_active_view = set_active_view
  end)

  test.it("round-trips zero Panes", function()
    local state = panes.save_workspace_state(save_view)
    test.equal(state.version, 1)
    test.same(state.groups, {})
    test.same(state.panes, {})
    test.ok(panes.restore_workspace_state(state, load_view))
    test.equal(panes.count(), 0)
  end)

  test.it("round-trips ordered groups and split ratios", function()
    local one = panes.create { factory = factory("one") }
    local two = panes.split(one, "right", { factory = factory("two") })
    one.group.root.ratio = 0.3
    local three = panes.create { factory = factory("three") }
    panes.focus(two)
    local state = panes.save_workspace_state(save_view)

    panes.reset_for_tests()
    test.ok(panes.restore_workspace_state(state, load_view))
    test.same(names(), { "one", "two", "three" })
    test.equal(#panes.groups, 2)
    test.equal(panes.groups[1].root.ratio, 0.3)
    test.equal(panes.number(panes.ordered()[3]), 3)
    test.equal(panes.active().current_view:get_name(), "two")
    test.equal(panes.visible_group(), panes.active().group)
  end)

  test.it("round-trips one Editor through its View state protocol", function()
    local old_buffers, old_registry = core.buffers, core.buffer_registry
    core.buffers = {}
    core.buffer_registry = BufferRegistry(core.buffers)
    local buffer = core.open_buffer()
    buffer:insert(1, 1, "workspace text")
    panes.create { factory = function() return Editor(buffer) end }
    local state = panes.save_workspace_state(function(view)
      return { module = view:get_module(), state = view:get_state() }
    end)
    test.ok(panes.restore_workspace_state(state, function(saved)
      return require(saved.module).from_state(saved.state)
    end))
    local editor = panes.active().current_view
    test.ok(editor:extends(Editor))
    test.equal(editor.buffer:get_text(1, 1, math.huge, math.huge), "workspace text")
    panes.reset_for_tests()
    core.buffers, core.buffer_registry = old_buffers, old_registry
  end)

  test.it("prunes a Pane whose Current View cannot restore", function()
    local state = {
      version = 1,
      visible_group_id = "group-a",
      focused_pane_id = "pane-b",
      panes = {
        { id = "pane-a", view = { state = { name = "one" } } },
        { id = "pane-b", view = { state = { invalid = true } } },
      },
      groups = {
        {
          id = "group-a",
          layout = {
            kind = "split", axis = "x", ratio = 0.4,
            a = { kind = "pane", pane_id = "pane-a" },
            b = { kind = "pane", pane_id = "pane-b" },
          },
        },
      },
    }
    test.ok(panes.restore_workspace_state(state, load_view))
    test.same(names(), { "one" })
    test.equal(panes.groups[1].root.kind, "pane")
    test.equal(panes.active().current_view:get_name(), "one")
  end)

  test.it("does not attach one Pane twice from invalid group state", function()
    local state = {
      version = 1,
      panes = { { id = "pane-a", view = { state = { name = "one" } } } },
      groups = {
        { id = "group-a", layout = { kind = "pane", pane_id = "pane-a" } },
        { id = "group-b", layout = { kind = "pane", pane_id = "pane-a" } },
      },
    }
    test.ok(panes.restore_workspace_state(state, load_view))
    test.equal(panes.count(), 1)
    test.equal(#panes.groups, 1)
    test.ok(panes.validate())
  end)

  test.it("ignores obsolete Left and Right state", function()
    local legacy = { panes = { left = { views = {} }, right = { views = {} } } }
    test.not_ok(panes.restore_workspace_state(legacy, load_view))
    test.equal(panes.count(), 0)
  end)
end)
