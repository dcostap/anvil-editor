local core = require "core"
local style = require "core.style"
local test = require "core.test"
local Node = require "core.node"
local View = require "core.view"

local function named_view(name)
  local view = View()
  function view:get_name()
    return name
  end
  return view
end

local function make_leaf(width, names)
  local node = Node("leaf")
  node.size.x = width
  for _, name in ipairs(names) do
    node:add_view(named_view(name))
  end
  node.tab_offset = 1
  return node
end

test.describe("node tabs", function()
  local old_tab_min_width
  local old_tab_max_width
  local old_tab_width
  local old_active_view

  test.before_each(function()
    old_tab_min_width = style.tab_min_width
    old_tab_max_width = style.tab_max_width
    old_tab_width = style.tab_width
    old_active_view = core.active_view
    style.tab_min_width = 100 * SCALE
    style.tab_max_width = 240 * SCALE
    style.tab_width = style.tab_min_width
  end)

  test.after_each(function()
    style.tab_min_width = old_tab_min_width
    style.tab_max_width = old_tab_max_width
    style.tab_width = old_tab_width
    if old_active_view then
      core.set_active_view(old_active_view)
    end
  end)

  test.it("uses the minimum width for short titles", function()
    local node = make_leaf(1200, { "a.lua", "b.lua" })
    test.equal(node:get_tab_width(1), style.tab_min_width)
  end)

  test.it("grows tabs to fit titles", function()
    local node = make_leaf(1200, { "very-long-tab-name.lua" })
    test.ok(node:get_tab_width(1) > style.tab_min_width)
  end)

  test.it("caps title-sized tabs at the maximum width", function()
    local node = make_leaf(1200, { "very-very-very-very-very-very-long-tab-name.lua" })
    test.equal(node:get_tab_width(1), style.tab_max_width)
  end)

  test.it("derives visible tabs from variable tab widths", function()
    local node = make_leaf(260, { "a.lua", "very-very-very-very-long-tab-name.lua", "c.lua" })
    test.equal(node:get_visible_tabs_number(), 1)
  end)
end)
