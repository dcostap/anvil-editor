-- Pane History: the Panes that the user visited, in order, across Projects and Anvil Windows. Back and Forward move
-- through it and add no visit. Each Project keeps the visits to its own Panes and sends them in its Pane report.
-- system.get_time() reads one clock for every process on the computer, so the visits of all Projects merge.
local core = require "core"
local common = require "core.common"

local pane_history = {}

-- The visits that each Project keeps.
pane_history.LIMIT = 40
-- A history move waits this many seconds for its Pane to take focus.
local ARRIVAL = 5

-- This Project's entries, oldest first. `at` is the time in milliseconds, which also names the entry. An entry with
-- `to` is a history move: the Pane took focus to show the entry named `to`.
local log, arriving = {}, nil

local function ms(time) return math.floor(time * 1000) end

local function key(path, id)
  return (common.path_compare_key(path) or path) .. "\0" .. tostring(id)
end

-- The Pane `id` took focus at `time`. Recent Panes decide what a focus is.
function pane_history.visited(id, time)
  local entry = {id = id, at = ms(time)}
  if arriving and arriving.id == id and time <= arriving.deadline then
    entry.to, arriving = arriving.to, nil
  end
  log[#log + 1] = entry
  if #log > pane_history.LIMIT then table.remove(log, 1) end
end

-- The next focus of `id` is a history move to the entry named `to`.
function pane_history.arrive(id, to)
  arriving = {id = id, to = to, deadline = system.get_time() + ARRIVAL}
end

-- This Project's entries for its Pane report.
function pane_history.entries()
  return log
end

local function find_repeated_panes(keys)
  for length = 1, math.floor(#keys / 2) do
    for start = 1, #keys - 2 * length + 1 do
      local matches = true
      for offset = 0, length - 1 do
        if keys[start + offset] ~= keys[start + length + offset] then
          matches = false
          break
        end
      end
      if matches then return start, length end
    end
  end
end

local function compress_repetitions(list, current)
  local keys = {}
  for index, entry in ipairs(list) do keys[index] = key(entry.path, entry.id) end
  while true do
    local start, length = find_repeated_panes(keys)
    if not start then return list, current end
    -- Keep the later copy. A position in the earlier copy moves to the same Pane there.
    if current >= start and current < start + length then current = current + length end
    if current >= start + length then current = current - length end
    for _ = 1, length do
      table.remove(list, start)
      table.remove(keys, start)
    end
  end
end

-- The Pane History in the Project Sidebar model `projects`, oldest first, as {path, id, at}, and the position of the
-- current entry. When the user leaves a Pane that a move showed, that Pane goes again at the end, so no visit is lost.
function pane_history.timeline(projects)
  local entries = {}
  for _, project in ipairs(projects or {}) do
    local history = type(project.panes) == "table" and project.panes.history
    for _, entry in ipairs(type(history) == "table" and history or {}) do
      if type(entry) == "table" and type(entry.at) == "number" and entry.id ~= nil then
        entries[#entries + 1] = {path = project.path, id = entry.id, at = entry.at, to = entry.to}
      end
    end
  end
  table.sort(entries, function(a, b) return a.at < b.at end)
  local list, index_of, current, moved = {}, {}, nil, nil
  local function add(path, id, at)
    local last = list[#list]
    if not (last and key(last.path, last.id) == key(path, id)) then list[#list + 1] = {path = path, id = id, at = at} end
    index_of[at] = #list
  end
  for _, entry in ipairs(entries) do
    -- A move to an entry that its Project no longer keeps counts as a visit.
    local index = entry.to and index_of[entry.to]
    if index then
      current, moved = index, entry.at
    else
      if current then add(list[current].path, list[current].id, moved) end
      current = nil
      add(entry.path, entry.id, entry.at)
    end
  end
  -- Replay moves before compression, so their original visit times still resolve.
  return compress_repetitions(list, current or #list)
end

-- This Project's view of all Projects: the last fetched Project Sidebar model, with this Project's live Panes and
-- entries in place of its own report there.
local function model()
  local panes = require "core.panes"
  local project = core.root_project()
  -- The Sidebar names a Project on a Machine by its key.
  local path = project and require("core.machine_project").root_key(project.path) or ""
  local own = common.path_compare_key(path)
  local projects = {}
  for _, item in ipairs(core.project_sidebar or {}) do
    if common.path_compare_key(item.path) ~= own and type(item.panes) == "table" then projects[#projects + 1] = item end
  end
  local items = {history = log}
  for _, pane in ipairs(panes.ordered()) do items[#items + 1] = {id = pane.id, snoozed = pane.group.snoozed} end
  projects[#projects + 1] = {path = path, panes = items}
  return projects, path
end

local RANGES = {
  back = function(current) return current - 1, 1, -1 end,
  forward = function(current, count) return current + 1, count, 1 end,
  oldest = function(current) return 1, current - 1, 1 end,
  newest = function(current, count) return count, current + 1, -1 end,
}

-- Focuses the Pane that `direction` names: "back", "forward", "oldest" or "newest". It skips Panes that are closed,
-- Snoozed or current. The shell focuses a Pane in another Project.
function pane_history.move(direction)
  local projects, path = model()
  local list, current = pane_history.timeline(projects)
  local live = {}
  for _, project in ipairs(projects) do
    for _, item in ipairs(project.panes) do
      if type(item) == "table" and not item.snoozed then live[key(project.path, item.id)] = true end
    end
  end
  local active = require("core.panes").active()
  local here = active and key(path, active.id)
  local first, last, step = RANGES[direction](current, #list)
  local target
  for index = first, last, step do
    local item_key = key(list[index].path, list[index].id)
    if live[item_key] and item_key ~= here then target = list[index]; break end
  end
  if not target then
    core.log_quiet("Pane History %s: no Pane among %d entries at %d", direction, #list, current)
    return false
  end
  if common.path_compare_key(target.path) == common.path_compare_key(path) then
    pane_history.arrive(target.id, target.at)
    return require("core.panes").focus(target.id, "numbered") ~= nil
  end
  local sent = system.pane_request("select", target.path, common.serialize(
    {action = "focus", pane = target.id, feedback = "numbered", history = target.at}, {escape = true}))
  core.log_quiet("Pane History %s: Project=%s pane=%s sent=%s", direction, target.path, tostring(target.id),
    tostring(sent))
  return sent
end

function pane_history.reset_for_tests()
  log, arriving = {}, nil
end

return pane_history
