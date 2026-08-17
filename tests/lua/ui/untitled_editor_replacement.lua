local core = require "core"
local Buffer = require "core.buffer"
local BufferRegistry = require "core.buffer_registry"
local Editor = require "core.editor"
local View = require "core.view"
local panes = require "core.panes"
local test = require "core.test"

local TargetView = View:extend()
function TargetView:get_name() return "target" end

local function target_factory(counter)
  return function()
    counter.count = counter.count + 1
    return TargetView()
  end
end

test.describe("Untitled Editor replacement", function()
  local saved
  local prompt

  test.before_each(function()
    panes.reset_for_tests()
    saved = {
      buffers = core.buffers,
      buffer_registry = core.buffer_registry,
      set_active_view = core.set_active_view,
      prompt_bar = core.global_prompt_bar,
    }
    core.buffers = {}
    core.buffer_registry = BufferRegistry(core.buffers)
    core.set_active_view = function(view) core.active_view = view end
    prompt = nil
    core.global_prompt_bar = {
      enter = function(_, _, options) prompt = options end,
    }
  end)

  test.after_each(function()
    panes.reset_for_tests()
    core.buffers = saved.buffers
    core.buffer_registry = saved.buffer_registry
    core.set_active_view = saved.set_active_view
    core.global_prompt_bar = saved.prompt_bar
  end)

  local function untitled_pane(buffer)
    buffer = buffer or Buffer()
    core.buffer_registry:register(buffer)
    return panes.create { factory = function() return Editor(buffer) end }, buffer
  end

  test.it("closes a blank Untitled Editor without recording history", function()
    local pane = untitled_pane()
    local old = pane.current_view
    local counter = { count = 0 }
    local target = panes.replace_view(pane, target_factory(counter))
    test.ok(target)
    test.equal(counter.count, 1)
    test.equal(pane.current_view, target)
    test.same(panes.views(pane), { target })
    test.is_nil(old.__pane_owner)
    test.is_nil(prompt)
  end)

  test.it("does not construct the target when dirty replacement is canceled", function()
    local pane, buffer = untitled_pane()
    buffer:insert(1, 1, "text")
    local old = pane.current_view
    local counter = { count = 0 }
    local target = panes.replace_view(pane, target_factory(counter))
    test.is_nil(target)
    test.ok(prompt)
    test.equal(counter.count, 0)
    test.equal(pane.current_view, old)
  end)

  test.it("discards recovery state only after replacement is confirmed", function()
    local pane, buffer = untitled_pane()
    buffer:insert(1, 1, "text")
    local counter = { count = 0 }
    panes.replace_view(pane, target_factory(counter))
    prompt.submit(nil, { text = "Close Without Saving" })
    test.equal(counter.count, 1)
    test.ok(pane.current_view:is(TargetView))
    test.equal(#core.buffers, 0)
  end)

  test.it("suspends an Untitled Editor after Save As gives its Buffer file identity", function()
    local pane, buffer = untitled_pane()
    buffer:set_filename("saved.lua", "C:/saved.lua")
    local old = pane.current_view
    local target = panes.replace_view(pane, function() return TargetView() end)
    test.ok(target)
    test.equal(#panes.views(pane), 2)
    test.equal(panes.back(pane), old)
  end)

  test.it("does not show false data-loss wording while another Editor retains the Buffer", function()
    local first, buffer = untitled_pane()
    buffer:insert(1, 1, "text")
    panes.create { factory = function() return Editor(buffer) end }
    local target = panes.replace_view(first, function() return TargetView() end)
    test.ok(target)
    test.is_nil(prompt)
    test.equal(core.buffer_registry:reference_count(buffer), 1)
  end)

  test.it("does not replace or prompt when switching groups or splitting", function()
    local first, buffer = untitled_pane()
    buffer:insert(1, 1, "text")
    local untitled = first.current_view
    local other = panes.create { factory = function() return TargetView() end }
    panes.focus(first)
    panes.focus(other)
    test.equal(first.current_view, untitled)
    panes.focus(first)
    panes.split(first, "right", { factory = function() return TargetView() end })
    test.equal(first.current_view, untitled)
    test.is_nil(prompt)
  end)
end)
