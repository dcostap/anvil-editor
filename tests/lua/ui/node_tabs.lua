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

  test.it("pages tabs without changing the active tab", function()
    local node = make_leaf(260, { "a.lua", "b.lua", "c.lua", "d.lua" })
    node:set_active_view(node.views[1])

    node:scroll_tabs(2)
    node:scroll_tabs_to_visible()

    test.equal(node.active_view, node.views[1])
    test.equal(node.tab_offset, 2)
    test.ok(node:can_scroll_tabs(2))
    test.ok(node:can_scroll_tabs(1))
  end)

  test.it("keeps a manual page even when the active tab remains visible", function()
    local node = make_leaf(500, { "a.lua", "b.lua", "c.lua", "d.lua", "e.lua", "f.lua" })
    node:set_active_view(node.views[1])

    node:scroll_tabs(2)
    node:scroll_tabs_to_visible()

    test.equal(node.tab_offset, 2)
  end)

  test.it("does not hover disabled pagination chevrons", function()
    local node = make_leaf(260, { "a.lua", "b.lua", "c.lua", "d.lua" })
    local x, y, w, h = node:get_scroll_button_rect(1)

    node:tab_hovered_update(x + w / 2, y + h / 2)

    test.equal(node.hovered_scroll_button, 0)
  end)

  test.it("reserves chevron space when earlier tabs are paged out", function()
    local node = make_leaf(335, { "a.lua", "b.lua", "c.lua" })
    node.tab_offset = 2
    node.tab_shift = node:target_tab_shift()

    local visible = node:get_visible_tabs_number()
    local tab_x, _, tab_w = node:get_tab_rect(node.tab_offset + visible - 1)
    local chevron_x = node:get_scroll_button_rect(1)

    test.ok(tab_x + tab_w <= chevron_x)
  end)

  test.it("does not hover tabs under the pagination chevron area", function()
    local node = make_leaf(335, { "a.lua", "b.lua", "c.lua" })
    node.tab_offset = 2
    node.tab_shift = node:target_tab_shift()
    local x, y, w, h = node:get_scroll_button_rect(1)

    test.equal(node:get_tab_overlapping_point(x + w / 2, y + h / 2), nil)
  end)

  test.it("close_all_views keeps only the requested tab across splits", function()
    local root = make_leaf(1200, { "left-a", "left-b" })
    local keep = root.views[1]
    local right = root:split("right", named_view("right-a"))
    right:add_view(named_view("right-b"))

    root:close_all_views(keep)

    local views = root:get_children()
    test.equal(#views, 1)
    test.equal(views[1], keep)
  end)

  test.it("close_all_views does not filter utility or non-file tabs", function()
    local root = make_leaf(1200, { "file" })
    local keep = root.views[1]
    local utility = named_view("utility")
    utility.context = "tool"
    root:add_view(utility)
    root:set_active_view(keep)

    root:close_all_views(keep)

    local views = root:get_children()
    test.equal(#views, 1)
    test.equal(views[1], keep)
  end)

  test.it("close_all_views preserves locked chrome leaves", function()
    local root = make_leaf(1200, { "file" })
    local keep = root.views[1]
    local chrome = named_view("titlebar")
    root:split("up", chrome, { y = true })

    root:close_all_views(keep)

    local views = root:get_children()
    test.equal(#views, 2)
    test.ok(root:get_node_for_view(keep))
    test.ok(root:get_node_for_view(chrome))
  end)
end)
