-- Recent Panes: the Panes, from every Project and Anvil Window, that had focus most recently before the current
-- Pane. The latest five get the numbers 1 to 5, newest first, so the first one is the previous Pane.
-- Each Project's Pane report stamps its Panes with the time they last took focus. system.get_time() reads one clock
-- for every process on the computer, so stamps from different Projects compare.
local core = require "core"
local common = require "core.common"

local recent_panes = {}

recent_panes.COUNT = 5
-- A Pane counts as a visit when it keeps focus this many seconds, or when the user types in it.
recent_panes.VISIT = 1

-- When each Pane of this Project last took focus, by Pane ID. The active Pane and the keyboard focus at the last
-- observation.
local focused_at, last_active, had_focus = {}, nil, false
-- The Pane that took focus last, while it is not a visit yet: {id, since, previous stamp}.
local visit

-- Stamps the active Pane when it takes focus: the active Pane changes while the Project has keyboard focus, or the
-- Project takes keyboard focus. Then the other Projects' stamps can have changed, so it fetches them too.
-- A Pane that loses focus before it is a visit gets its previous stamp again. Examples are a Pane that a cycle
-- passes, and the old active Pane in the frame before a Pane request moves focus.
function recent_panes.observe(active)
  local has_focus = core.window ~= nil and system.window_has_focus(core.window)
  local now = system.get_time()
  if visit and now - visit.since >= recent_panes.VISIT then visit = nil end
  if visit and not (has_focus and active and active.id == visit.id) then
    focused_at[visit.id] = visit.previous
    core.log_quiet("Recent Pane: %s lost focus after %.2fs; not a visit", tostring(visit.id), now - visit.since)
    visit = nil
  end
  if has_focus and active and (active ~= last_active or not had_focus) then
    visit = {id = active.id, since = now, previous = focused_at[active.id]}
    focused_at[active.id] = now
  end
  if has_focus and not had_focus then core.request_project_sidebar() end
  last_active, had_focus = active, has_focus
end

-- The user typed text while `active` had focus: its focus is a visit.
function recent_panes.typed(active)
  if visit and active and active.id == visit.id then visit = nil end
end

function recent_panes.focused_at(pane)
  return focused_at[pane.id]
end

-- The key of a Pane in a Project.
function recent_panes.key(path, id)
  return (common.path_compare_key(path) or path) .. "\0" .. tostring(id)
end

-- Every stamped Pane in the Project Sidebar model `projects`, newest first, as {path, id}. The first is the current
-- Pane.
function recent_panes.order(projects)
  local list = {}
  for _, project in ipairs(projects or {}) do
    for _, item in ipairs(project.panes or {}) do
      if type(item.focused) == "number" and not item.snoozed then
        list[#list + 1] = {path = project.path, id = item.id, focused = item.focused}
      end
    end
  end
  table.sort(list, function(a, b) return a.focused > b.focused end)
  return list
end

-- The Recent Pane numbers in `projects` by key, and the order that gives them.
function recent_panes.numbers(projects)
  local order, numbers = recent_panes.order(projects), {}
  for number = 1, math.min(recent_panes.COUNT, #order - 1) do
    local item = order[number + 1]
    numbers[recent_panes.key(item.path, item.id)] = number
  end
  return numbers, order
end

-- The Recent Pane with `number` in `projects`, as {path, id}, or nil.
function recent_panes.target(projects, number)
  local _, order = recent_panes.numbers(projects)
  return number >= 1 and number <= recent_panes.COUNT and order[number + 1] or nil, #order
end

-- Asks the shell to select the Project at `path`, bring its Window to the front, and focus its Pane `id`.
function recent_panes.request(path, id)
  return system.pane_request("select", path,
    common.serialize({action = "focus", pane = id, feedback = "numbered"}, {escape = true}))
end

-- This Project's view of all Projects: the last fetched Project Sidebar model, with this Project's live Panes in
-- place of its own report there.
local function model()
  local panes = require "core.panes"
  local project = core.root_project()
  local path = project and project.path or ""
  local own = common.path_compare_key(path)
  local projects = {}
  for _, item in ipairs(core.project_sidebar or {}) do
    if common.path_compare_key(item.path) ~= own then projects[#projects + 1] = item end
  end
  local items = {}
  for _, pane in ipairs(panes.ordered()) do
    items[#items + 1] = {id = pane.id, focused = focused_at[pane.id], snoozed = pane.group.snoozed}
  end
  projects[#projects + 1] = {path = path, panes = items}
  return projects, path
end

-- The Recent Pane numbers of this Project's Panes, by Pane ID.
function recent_panes.local_numbers()
  local projects, path = model()
  local numbers, result = recent_panes.numbers(projects), {}
  for _, pane in ipairs(projects[#projects].panes) do
    result[pane.id] = numbers[recent_panes.key(path, pane.id)]
  end
  return result
end

-- Focuses the Recent Pane with `number`. The shell focuses a Pane in another Project.
function recent_panes.focus(number)
  local projects, path = model()
  local item, stamped = recent_panes.target(projects, number)
  if not item then
    core.log_quiet("Recent Pane %d: none of %d stamped Panes", number, stamped)
    return false
  end
  if common.path_compare_key(item.path) == common.path_compare_key(path) then
    return require("core.panes").focus(item.id, "numbered") ~= nil
  end
  local sent = recent_panes.request(item.path, item.id)
  core.log_quiet("Recent Pane %d: Project=%s pane=%s sent=%s", number, item.path, tostring(item.id), tostring(sent))
  return sent
end

function recent_panes.reset_for_tests()
  focused_at, last_active, had_focus, visit = {}, nil, false, nil
end

return recent_panes
