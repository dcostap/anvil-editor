local core = require "core"
local style = require "core.style"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local Node = require "core.node"
local panes = require "core.panes"


local t = {
  ["root:close"] = function(node)
    if not panes.close_view(core.active_view) then
      node:close_active_view(core.root_panel.root_node)
    end
  end,

  ["root:close-or-quit"] = function(node)
    if node and (not node:is_empty() or not node.pane_id) then
      node:close_active_view(core.root_panel.root_node)
    else
      core.quit()
    end
  end,

  ["root:close-all"] = function()
    core.confirm_close_docs(core.docs, core.root_panel.close_all_views, core.root_panel)
  end,

  ["root:close-all-others"] = function()
    local active_doc, docs = core.active_view and core.active_view.doc, {}
    for _, doc in ipairs(core.docs) do
      if doc ~= active_doc then table.insert(docs, doc) end
    end
    core.confirm_close_docs(docs, core.root_panel.close_all_views, core.root_panel, core.active_view)
  end,

  ["root:move-tab-left"] = function(node)
    local idx = node:get_view_idx(core.active_view)
    if idx > 1 then
      table.remove(node.views, idx)
      table.insert(node.views, idx - 1, core.active_view)
    end
  end,

  ["root:move-tab-right"] = function(node)
    local idx = node:get_view_idx(core.active_view)
    if idx < #node.views then
      table.remove(node.views, idx)
      table.insert(node.views, idx + 1, core.active_view)
    end
  end,

  ["root:shrink"] = function(node)
    local parent = node:get_parent_node(core.root_panel.root_node)
    local n = (parent.a == node) and -0.1 or 0.1
    parent.divider = common.clamp(parent.divider + n, 0.1, 0.9)
  end,

  ["root:grow"] = function(node)
    local parent = node:get_parent_node(core.root_panel.root_node)
    local n = (parent.a == node) and 0.1 or -0.1
    parent.divider = common.clamp(parent.divider + n, 0.1, 0.9)
  end
}


for i = 1, 9 do
  t["root:switch-to-tab-" .. i] = function(node)
    panes.switch_to_index(panes.focused_pane(), i)
  end
end


for _, dir in ipairs { "left", "right", "up", "down" } do
  t["root:switch-to-" .. dir] = function(node)
    local x, y
    if dir == "left" or dir == "right" then
      y = node.position.y + node.size.y / 2
      x = node.position.x + (dir == "left" and -1 or node.size.x + style.divider_size)
    else
      x = node.position.x + node.size.x / 2
      y = node.position.y + (dir == "up"   and -1 or node.size.y + style.divider_size)
    end
    local node = core.root_panel.root_node:get_child_overlapping_point(x, y)
    local sx, sy = node:get_locked_size()
    if not sx and not sy then
      core.set_active_view(node.active_view)
    end
  end
end

command.add(function()
  local node = core.root_panel:get_active_node()
  local sx, sy = node:get_locked_size()
  return not sx and not sy, node
end, t)

command.add(nil, {
  ["root:scroll"] = function(delta)
    local view = core.root_panel.overlapping_view or core.active_view
    if view and view.scrollable then
      view.scroll.to.y = view.scroll.to.y + delta * -config.mouse_wheel_scroll
      return true
    end
    return false
  end,
  ["root:horizontal-scroll"] = function(delta)
    local view = core.root_panel.overlapping_view or core.active_view
    if view and view.scrollable then
      view.scroll.to.x = view.scroll.to.x + delta * -config.mouse_wheel_scroll
      return true
    end
    return false
  end
})

command.add(function(node)
    if not Node:is_extended_by(node) then node = nil end
    -- No node was specified, use the active one
    node = node or core.root_panel:get_active_node()
    if not node then return false end
    return true, node
  end,
  {
    ["root:switch-to-previous-tab"] = function(node)
      panes.switch(panes.focused_pane(), -1)
    end,

    ["root:switch-to-next-tab"] = function(node)
      panes.switch(panes.focused_pane(), 1)
    end,

    ["root:scroll-tabs-backward"] = function(node)
      node:scroll_tabs(1)
    end,

    ["root:scroll-tabs-forward"] = function(node)
      node:scroll_tabs(2)
    end
  }
)

command.add(function()
    local node = core.root_panel.root_node:get_child_overlapping_point(core.root_panel.mouse.x, core.root_panel.mouse.y)
    if not node then return false end
    return (node.hovered_tab or node.hovered_scroll_button > 0) and true, node
  end,
  {
    ["root:switch-to-hovered-previous-tab"] = function(node)
      command.perform("root:switch-to-previous-tab", node)
    end,

    ["root:switch-to-hovered-next-tab"] = function(node)
      command.perform("root:switch-to-next-tab", node)
    end,

    ["root:scroll-hovered-tabs-backward"] = function(node)
      command.perform("root:scroll-tabs-backward", node)
    end,

    ["root:scroll-hovered-tabs-forward"] = function(node)
      command.perform("root:scroll-tabs-forward", node)
    end
  }
)
