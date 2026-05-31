local core = require "core"
local config = require "core.config"
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

local function tab_title_fit_width(text)
  return style.font:get_width(text)
    + style.icon_font:get_width("C")
    + style.padding.x
    + style.divider_size * 2
end

test.describe("node tabs", function()
  local old_tab_width
  local old_max_tabs
  local old_active_view

  test.before_each(function()
    old_tab_width = style.tab_width
    old_max_tabs = config.max_tabs
    old_active_view = core.active_view
    style.tab_width = 250 * SCALE
    config.max_tabs = 8
  end)

  test.after_each(function()
    style.tab_width = old_tab_width
    config.max_tabs = old_max_tabs
    if old_active_view then
      core.set_active_view(old_active_view)
    end
  end)

  test.it("keeps the configured minimum width when titles are short", function()
    local node = make_leaf(1200, { "a.lua", "b.lua" })
    test.equal(node:target_tab_width(), style.tab_width)
  end)

  test.it("grows to fit a visible title when there is room", function()
    local title = "very-long-tab-name-for-width-check.lua"
    local node = make_leaf(1200, { title, "b.lua" })
    test.equal(node:target_tab_width(), tab_title_fit_width(title))
  end)

  test.it("shrinks below the configured minimum when space runs out", function()
    local node = make_leaf(220, { "first.lua", "second.lua" })
    test.equal(node:target_tab_width(), 110)
  end)
end)
