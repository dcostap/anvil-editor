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

local function rebalance_node(node, axis)
  if is_leaf(node) then return 1 end
  assert(is_split(node), "invalid Pane layout node")
  local first = rebalance_node(node.a, axis)
  local second = rebalance_node(node.b, axis)
  if node.axis == axis then
    node.ratio = first / (first + second)
    return first + second
  end
  return math.max(first, second)
end

function layout.rebalance(root, axis)
  assert(axis == "x" or axis == "y", "invalid Pane rebalance axis")
  if root then rebalance_node(root, axis) end
  return root
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

function layout.split(root, pane, direction, new_pane, opts)
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
  root = replace_node(root, target, replacement)
  root = layout.rebalance(root, axis)
  if opts and opts.ratio ~= nil then
    replacement.ratio = common.clamp(tonumber(opts.ratio) or 0.5, MIN_RATIO, MAX_RATIO)
  end
  return root
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
  local _, parent = layout.find(root, pane)
  local result, changed = remove_node(root, pane)
  assert(changed, "Pane is not in this layout")
  return parent and layout.rebalance(result, parent.axis) or result
end

local function set_pane_rect(pane, x, y, w, h)
  pane.position = pane.position or {}
  pane.size = pane.size or {}
  pane.position.x, pane.position.y = x, y
  pane.size.x, pane.size.y = w, h
end

local function normalize_ratio(node)
  node.ratio = tonumber(node.ratio) or 0.5
  if node.ratio <= 0 or node.ratio >= 1 then
    node.ratio = common.clamp(node.ratio, MIN_RATIO, MAX_RATIO)
  end
  return node.ratio
end

local function update_rect(node, x, y, w, h)
  node.rect = { x = x, y = y, w = w, h = h }
  node.row, node.view_rect = nil, nil
  if is_leaf(node) then
    set_pane_rect(node.pane, x, y, w, h)
    return
  end
  assert(is_split(node), "invalid Pane layout node")
  normalize_ratio(node)
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

-- The top row of a layout holds its Pane Columns: the parts that sit side by side. A top and bottom split is one
-- column. Each column's share is its part of the row's width. Layout runs in each frame, so the lists are reused.
local column_nodes, column_shares, column_count = {}, {}, 0

local function collect_columns(node, share)
  if is_split(node) and node.axis == "x" then
    local ratio = normalize_ratio(node)
    collect_columns(node.a, share * ratio)
    collect_columns(node.b, share * (1 - ratio))
  else
    column_count = column_count + 1
    column_nodes[column_count], column_shares[column_count] = node, share
  end
end

-- Row splits divide Pane Columns. Their dividers move width between two neighbouring columns only.
local function update_row(node, x, y, w, h)
  if not (is_split(node) and node.axis == "x") then return update_rect(node, x, y, w, h) end
  node.rect = { x = x, y = y, w = w, h = h }
  node.row = true
  local first = w * normalize_ratio(node)
  update_row(node.a, x, y, first, h)
  update_row(node.b, x + first, y, w - first, h)
end

---Lays out the Panes in `rect`. When not all Pane Columns fit at `strip.min_width`, only the columns that fit show,
---from `strip.first`, moved so that `strip.focus` shows. They share the whole width in their own proportions.
---The other columns lie outside `rect` on the same row. Returns the first shown column.
function layout.update_rects(root, rect, strip)
  if not root then return nil end
  assert(type(rect) == "table", "Pane layout rectangle is required")
  strip = strip or {}
  local x, y = rect.x or 0, rect.y or 0
  local w, h = rect.w or rect.width or 0, rect.h or rect.height or 0
  column_count = 0
  collect_columns(root, 1)
  local shown = column_count
  if strip.min_width and strip.min_width > 0 then
    shown = common.clamp(math.floor(w / strip.min_width), 1, column_count)
  end
  local first = common.clamp(math.floor(tonumber(strip.first) or 1), 1, column_count - shown + 1)
  for index = 1, strip.focus and column_count or 0 do
    if layout.find(column_nodes[index], strip.focus) then
      if index < first then first = index
      elseif index >= first + shown then first = index - shown + 1 end
      break
    end
  end
  local before, inside = 0, 0
  for index = 1, column_count do
    if index < first then before = before + column_shares[index]
    elseif index < first + shown then inside = inside + column_shares[index] end
    column_nodes[index] = nil
  end
  local scale = inside > 0 and w / inside or w
  local view = root.view_rect or {}
  update_row(root, x - before * scale, y, scale, h)
  view.x, view.y, view.w, view.h = x, y, w, h
  root.view_rect = view
  return first
end

---Lays out the Panes again on the same row and view, for example after a reorder.
function layout.refresh(root)
  if not (root and root.rect) then return end
  local view = root.view_rect
  update_row(root, root.rect.x, root.rect.y, root.rect.w, root.rect.h)
  root.view_rect = view
end

---Whether `pane` is in a shown Pane Column. A layout without rectangles shows every Pane.
function layout.is_shown(root, pane)
  local view = root and root.view_rect
  if not view or not pane.position or not pane.position.x or not pane.size.x then return true end
  local center = pane.position.x + pane.size.x / 2
  return center > view.x and center < view.x + view.w
end

function layout.shown_leaves(root)
  local result = {}
  for _, pane in ipairs(layout.leaves(root)) do
    if layout.is_shown(root, pane) then result[#result + 1] = pane end
  end
  return result
end

local function contains(rect, x, y)
  return rect and x >= rect.x and y >= rect.y
    and x < rect.x + rect.w and y < rect.y + rect.h
end

local function pane_at(node, x, y)
  if not node or not contains(node.rect, x, y) then return nil end
  if is_leaf(node) then return node.pane end
  return pane_at(node.a, x, y) or pane_at(node.b, x, y)
end

function layout.pane_at(root, x, y)
  if root and root.view_rect and not contains(root.view_rect, x, y) then return nil end
  return pane_at(root, x, y)
end

local function divider_at(node, x, y, tolerance, view)
  if not node or not is_split(node) or not node.rect then return nil end
  local nested = divider_at(node.a, x, y, tolerance, view)
    or divider_at(node.b, x, y, tolerance, view)
  if nested then return nested end
  local divider = node.axis == "x"
    and node.rect.x + node.rect.w * node.ratio
    or node.rect.y + node.rect.h * node.ratio
  local cross = node.axis == "x" and x or y
  local along = node.axis == "x" and y or x
  local start = node.axis == "x" and node.rect.y or node.rect.x
  local length = node.axis == "x" and node.rect.h or node.rect.w
  -- A divider at the edge of the shown Pane Columns borders a column that does not show.
  local inside = not view or node.axis ~= "x"
    or (divider > view.x + 0.5 and divider < view.x + view.w - 0.5)
  if inside and math.abs(cross - divider) <= tolerance and along >= start and along < start + length then
    return node
  end
end

function layout.divider_at(root, x, y, tolerance)
  local view = root and root.view_rect
  if view and not contains(view, x, y) then return nil end
  return divider_at(root, x, y, tolerance or 3, view)
end

-- Sets each row split's ratio from the widths of its Pane Columns and returns the row's width.
local function apply_widths(node, widths)
  if not node.row then return widths[node] or node.rect.w end
  local first = apply_widths(node.a, widths)
  local total = first + apply_widths(node.b, widths)
  node.ratio = first / total
  return total
end

function layout.resize(node, pointer_position)
  assert(is_split(node) and node.rect, "split layout node with a rectangle is required")
  local pointer = type(pointer_position) == "table"
    and pointer_position[node.axis] or pointer_position
  assert(type(pointer) == "number", "split resize pointer is required")
  if node.row then
    -- The other Pane Columns keep their widths, so the shown columns still fill the view.
    local left, right = node.a, node.b
    while left.row do left = left.b end
    while right.row do right = right.a end
    local pair = left.rect.w + right.rect.w
    if pair <= 0 then return node.ratio end
    local width = common.clamp(pointer - left.rect.x, pair * MIN_RATIO, pair * MAX_RATIO)
    apply_widths(node, { [left] = width, [right] = pair - width })
    update_row(node, node.rect.x, node.rect.y, node.rect.w, node.rect.h)
    return node.ratio
  end
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
  if node.ratio <= 0 or node.ratio >= 1 then
    node.ratio = common.clamp(node.ratio, MIN_RATIO, MAX_RATIO)
  end
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
