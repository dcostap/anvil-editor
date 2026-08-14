local core = require "core"
local Buffer = require "core.buffer"
local BufferRegistry = require "core.buffer_registry"
local Editor = require "core.editor"
local panes = require "core.panes"
local test = require "core.test"

test.describe("Buffer Registry Editor retention", function()
  local saved

  test.before_each(function()
    panes.reset_for_tests()
    saved = {
      buffers = core.buffers,
      buffer_registry = core.buffer_registry,
      set_active_view = core.set_active_view,
    }
    core.buffers = {}
    core.buffer_registry = BufferRegistry(core.buffers)
    core.set_active_view = function(view) core.active_view = view end
  end)

  test.after_each(function()
    panes.reset_for_tests()
    core.buffers = saved.buffers
    core.buffer_registry = saved.buffer_registry
    core.set_active_view = saved.set_active_view
  end)

  test.it("retains Buffers for Current and suspended Editors", function()
    local one, two = Buffer(), Buffer()
    core.buffer_registry:register(one)
    core.buffer_registry:register(two)
    local pane = panes.create { factory = function() return Editor(one) end }
    panes.present(Editor(two), { pane = pane })
    test.equal(core.buffer_registry:reference_count(one), 1)
    test.equal(core.buffer_registry:reference_count(two), 1)
    test.equal(core.buffer_registry:collect(), 0)

    panes.close(pane, { force = true })
    test.equal(core.buffer_registry:reference_count(one), 0)
    test.equal(core.buffer_registry:reference_count(two), 0)
    test.equal(core.buffer_registry:collect(), 2)
  end)
end)
