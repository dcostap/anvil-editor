local edit_projection = require "core.markdown.edit_projection"
local markdown_model = require "core.markdown.model"

local snapshot = {}

local function current_snapshot(view)
  local owner = view.__markdown_live_owner
  return owner and owner.presentation_snapshot or nil
end

function snapshot.changes(view)
  local current = current_snapshot(view)
  return current and current.changes or nil
end

function snapshot.begin(view, transaction)
  local owner = view.__markdown_live_owner
  if not owner then return nil end
  local current = owner.presentation_snapshot
  if not current then
    local instance = markdown_model.peek(view.buffer)
    -- Keep one published semantic base for the complete pending revision.
    -- Rows, metrics, and decorations project from this same base.
    current = {
      semantic_revision = instance and instance.published_revision or nil,
      revision = view.buffer.text_revision,
      changes = {},
    }
    owner.presentation_snapshot = current
  end
  current.revision = view.buffer.text_revision
  current.changes[#current.changes + 1] = {
    ranges = edit_projection.ordered_changed_ranges(transaction),
  }
  return current
end

function snapshot.map_published_line(view, line)
  for _, change in ipairs(snapshot.changes(view) or {}) do
    line = edit_projection.map_unchanged_line(change.ranges, line)
    if not line then return nil end
  end
  return line
end

function snapshot.map_current_line(view, line)
  local changes = snapshot.changes(view)
  for index = #(changes or {}), 1, -1 do
    line = edit_projection.map_unchanged_new_line(changes[index].ranges, line)
    if not line then return nil end
  end
  return line
end

function snapshot.semantic_line(view, line)
  local instance = markdown_model.peek(view.buffer)
  if not (instance and instance.result and instance.status == "pending") then
    return nil
  end
  local current = current_snapshot(view)
  if not current or current.revision ~= view.buffer.text_revision
    or current.semantic_revision ~= instance.published_revision
  then
    return nil
  end
  local published_line = snapshot.map_current_line(view, line)
  if not published_line then return nil end
  return instance, published_line
end

local function clone_value(value, delta, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local copy = {}
  seen[value] = copy
  for key, item in pairs(value) do
    if type(item) == "number"
      and (key == "line" or key == "line1" or key == "line2"
        or key == "start_line" or key == "end_line")
    then
      copy[key] = item + delta
    else
      copy[key] = clone_value(item, delta, seen)
    end
  end
  return copy
end

function snapshot.semantic_node(view, node)
  local source = node and node.source
  if not (source and source.line1 and source.line2) then return nil end
  local line1 = snapshot.map_published_line(view, source.line1)
  local line2 = snapshot.map_published_line(view, source.line2)
  if not line1 or not line2 then return nil end
  local delta = line1 - source.line1
  if line2 - source.line2 ~= delta then return nil end
  return clone_value(node, delta)
end

return snapshot
