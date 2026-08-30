-- mod-version:3
-- Deterministic commit graph lane layout for Git Log rows.

local graph = {}

local function find_lane(lanes, hash)
  for index, lane in ipairs(lanes) do
    if lane.hash == hash then return index end
  end
end

local function copy_lanes(lanes)
  local copy = {}
  for index, lane in ipairs(lanes) do
    copy[index] = { hash = lane.hash, color = lane.color }
  end
  return copy
end

function graph.layout(commits)
  local rows = { max_lanes = 0 }
  local lanes = {}
  local next_color = 1

  local function new_color()
    local color = next_color
    next_color = next_color + 1
    return color
  end

  for row_index, commit in ipairs(commits or {}) do
    local hash = commit.hash
    local node_lane = find_lane(lanes, hash)
    local incoming = node_lane ~= nil
    if not node_lane then
      node_lane = #lanes + 1
      lanes[node_lane] = { hash = hash, color = new_color() }
    end

    local before = copy_lanes(lanes)
    local node_color = before[node_lane].color
    table.remove(lanes, node_lane)

    for parent_index, parent in ipairs(commit.parents or {}) do
      local target = find_lane(lanes, parent)
      if not target then
        target = math.min(node_lane + parent_index - 1, #lanes + 1)
        table.insert(lanes, target, {
          hash = parent,
          color = parent_index == 1 and node_color or new_color(),
        })
      end
    end

    local segments = {}
    for before_index, lane in ipairs(before) do
      if before_index ~= node_lane then
        local target = find_lane(lanes, lane.hash)
        if target then
          segments[#segments + 1] = {
            kind = "continuation",
            from_lane = before_index,
            to_lane = target,
            color = lane.color,
          }
        end
      end
    end
    for parent_index, parent in ipairs(commit.parents or {}) do
      local target = find_lane(lanes, parent)
      local target_lane = lanes[target]
      segments[#segments + 1] = {
        kind = "parent",
        from_lane = node_lane,
        to_lane = target,
        color = parent_index == 1 and node_color or (target_lane and target_lane.color or node_color),
      }
    end

    local lane_count = math.max(#before, #lanes, node_lane)
    rows[row_index] = {
      node_lane = node_lane,
      node_color = node_color,
      incoming = incoming,
      segments = segments,
      lane_count = lane_count,
    }
    rows.max_lanes = math.max(rows.max_lanes, lane_count)
  end

  return rows
end

return graph
