local common = require "core.common"

local layout = {}

local MIN_RATIO = 0.05
local MAX_RATIO = 0.95

local function is_leaf(node)
  return type(node) == "table" and node.kind == "pane"
end

local function is_split(node)
  return type(node) == "table" and node.kind == "split"
end

local function leaf(pane)
  return { kind = "pane", pane = assert(pane, "Pane layout leaf requires a Pane") }
end

local function collect_leaves(node, result)
  if not node then return result end
  if is_leaf(node) then
    result[#result + 1] = node.pane
  elseif is_split(node) then
    collect_leaves(node.a, result)
    collect_leaves(node.b, result)
  else
    error("invalid Pane layout node")
  end
  return result
end

function layout.leaves(root)
  return collect_leaves(root, {})
end

local function collect_leaf_nodes(node, result)
  if not node then return result end
  if is_leaf(node) then
    result[#result + 1] = node
  else
    assert(is_split(node), "invalid Pane layout node")
    collect_leaf_nodes(node.a, result)
    collect_leaf_nodes(node.b, result)
  end
  return result
end

function layout.reorder(root, ordered_panes)
  local nodes = collect_leaf_nodes(root, {})
  assert(#nodes == #ordered_panes, "Pane reorder count does not match layout")
  local seen = {}
  for i, pane in ipairs(ordered_panes) do
    assert(pane and not seen[pane], "Pane reorder contains an invalid duplicate")
    seen[pane] = true
    nodes[i].pane = pane
  end
  layout.validate(root)
  return root
end

local function find_node(node, pane, parent, key)
  if not node then return nil end
  if is_leaf(node) then
    if node.pane == pane then return node, parent, key end
    return nil
  end
  if not is_split(node) then return nil end
  local found, found_parent, found_key = find_node(node.a, pane, node, "a")
  if found then return found, found_parent, found_key end
  return find_node(node.b, pane, node, "b")
end

function layout.find(root, pane)
  return find_node(root, pane)
end

local function replace_node(root, target, replacement)
  if root == target then return replacement, true end
  if not is_split(root) then return root, false end
  local changed
  root.a, changed = replace_node(root.a, target, replacement)
  if changed then return root, true end
  root.b, changed = replace_node(root.b, target, replacement)
  return root, changed
end

function layout.split(root, pane, direction, new_pane)
  local target = layout.find(root, pane)
  assert(target, "Pane is not in this layout")
  local before = direction == "left" or direction == "up"
  local axis = (direction == "left" or direction == "right") and "x"
    or (direction == "up" or direction == "down") and "y"
  assert(axis, "invalid split direction")
  local new_leaf = leaf(new_pane)
  local replacement = {
    kind = "split",
    axis = axis,
    ratio = 0.5,
    a = before and new_leaf or target,
    b = before and target or new_leaf,
  }
  return (replace_node(root, target, replacement))
end

local function remove_node(node, pane)
  if not node then return nil, false end
  if is_leaf(node) then
    if node.pane == pane then return nil, true end
    return node, false
  end
  assert(is_split(node), "invalid Pane layout node")
  local changed
  node.a, changed = remove_node(node.a, pane)
  if not changed then node.b, changed = remove_node(node.b, pane) end
  if not changed then return node, false end
  if not node.a then return node.b, true end
  if not node.b then return node.a, true end
  return node, true
end

function layout.remove(root, pane)
  local result, changed = remove_node(root, pane)
  assert(changed, "Pane is not in this layout")
  return result
end

local function set_pane_rect(pane, x, y, w, h)
  pane.position = pane.position or {}
  pane.size = pane.size or {}
  pane.position.x, pane.position.y = x, y
  pane.size.x, pane.size.y = w, h
end

local function update_rect(node, x, y, w, h)
  node.rect = { x = x, y = y, w = w, h = h }
  if is_leaf(node) then
    set_pane_rect(node.pane, x, y, w, h)
    return
  end
  assert(is_split(node), "invalid Pane layout node")
  node.ratio = common.clamp(tonumber(node.ratio) or 0.5, MIN_RATIO, MAX_RATIO)
  if node.axis == "x" then
    local first = w * node.ratio
    update_rect(node.a, x, y, first, h)
    update_rect(node.b, x + first, y, w - first, h)
  else
    local first = h * node.ratio
    update_rect(node.a, x, y, w, first)
    update_rect(node.b, x, y + first, w, h - first)
  end
end

function layout.update_rects(root, rect)
  if not root then return end
  assert(type(rect) == "table", "Pane layout rectangle is required")
  update_rect(root, rect.x or 0, rect.y or 0, rect.w or rect.width or 0, rect.h or rect.height or 0)
end

local function contains(rect, x, y)
  return rect and x >= rect.x and y >= rect.y
    and x < rect.x + rect.w and y < rect.y + rect.h
end

function layout.pane_at(root, x, y)
  if not root or not contains(root.rect, x, y) then return nil end
  if is_leaf(root) then return root.pane end
  return layout.pane_at(root.a, x, y) or layout.pane_at(root.b, x, y)
end

function layout.divider_at(root, x, y, tolerance)
  if not root or not is_split(root) or not root.rect then return nil end
  local nested = layout.divider_at(root.a, x, y, tolerance)
    or layout.divider_at(root.b, x, y, tolerance)
  if nested then return nested end
  tolerance = tolerance or 3
  local divider = root.axis == "x"
    and root.rect.x + root.rect.w * root.ratio
    or root.rect.y + root.rect.h * root.ratio
  local cross = root.axis == "x" and x or y
  local along = root.axis == "x" and y or x
  local start = root.axis == "x" and root.rect.y or root.rect.x
  local length = root.axis == "x" and root.rect.h or root.rect.w
  if math.abs(cross - divider) <= tolerance and along >= start and along < start + length then
    return root
  end
end

function layout.resize(node, pointer_position)
  assert(is_split(node) and node.rect, "split layout node with a rectangle is required")
  local pointer = type(pointer_position) == "table"
    and pointer_position[node.axis] or pointer_position
  assert(type(pointer) == "number", "split resize pointer is required")
  local start = node.axis == "x" and node.rect.x or node.rect.y
  local length = node.axis == "x" and node.rect.w or node.rect.h
  if length <= 0 then return node.ratio end
  node.ratio = common.clamp((pointer - start) / length, MIN_RATIO, MAX_RATIO)
  update_rect(node, node.rect.x, node.rect.y, node.rect.w, node.rect.h)
  return node.ratio
end

function layout.serialize(root)
  if not root then return nil end
  if is_leaf(root) then
    return { kind = "pane", pane_id = assert(root.pane.id, "Pane requires an identifier") }
  end
  assert(is_split(root), "invalid Pane layout node")
  return {
    kind = "split",
    axis = root.axis,
    ratio = root.ratio,
    a = layout.serialize(root.a),
    b = layout.serialize(root.b),
  }
end

function layout.deserialize(state, panes_by_id)
  if state == nil then return nil end
  assert(type(state) == "table", "invalid serialized Pane layout")
  local node
  if state.kind == "pane" then
    node = leaf(assert(panes_by_id[state.pane_id], "unknown Pane identifier"))
  elseif state.kind == "split" then
    node = {
      kind = "split",
      axis = state.axis,
      ratio = tonumber(state.ratio) or 0.5,
      a = layout.deserialize(state.a, panes_by_id),
      b = layout.deserialize(state.b, panes_by_id),
    }
  else
    error("invalid serialized Pane layout node")
  end
  layout.validate(node)
  return node
end

local function validate_node(node, seen)
  assert(type(node) == "table", "Pane layout node is missing")
  if is_leaf(node) then
    assert(type(node.pane) == "table", "Pane layout leaf is missing its Pane")
    assert(not seen[node.pane], "Pane appears more than once in one layout")
    seen[node.pane] = true
    return
  end
  assert(is_split(node), "invalid Pane layout node kind")
  assert(node.axis == "x" or node.axis == "y", "invalid Pane split axis")
  assert(type(node.ratio) == "number" and node.ratio == node.ratio, "invalid Pane split ratio")
  node.ratio = common.clamp(node.ratio, MIN_RATIO, MAX_RATIO)
  assert(node.a and node.b, "Pane split requires two children")
  validate_node(node.a, seen)
  validate_node(node.b, seen)
end

function layout.validate(root)
  if not root then return true end
  validate_node(root, {})
  return true
end

return layout
