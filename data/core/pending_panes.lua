-- Pending Panes first, then Recent Panes in the remaining number slots.
local core = require "core"
local common = require "core.common"
local tab = require "core.tab"
local recent = require "core.recent_panes"
local storage = require "core.storage"
local pending = {COUNT = recent.COUNT, key = recent.key, request = recent.request}

-- Sidebar surfaces supply their shared live table. Projects read the same persisted seen times.
local cached_seen, read_at = {}, -math.huge
local function seen_times()
  local now = system.get_time()
  if now - read_at >= 0.25 then
    read_at = now
    local ok, value = pcall(storage.load, "sidebar", "seen")
    if ok then cached_seen = type(value) == "table" and value or {} end
  end
  return cached_seen
end

function pending.order(projects, seen)
  seen = seen or seen_times()
  local list = {}
  local selected = {}
  for _, window in ipairs(projects and projects.windows or {}) do selected[window.selected_project] = true end
  for _, project in ipairs(projects or {}) do
    local records = {}
    for _, record in ipairs(project.terminals or {}) do records[record.id] = record end
    for index, item in ipairs(project.panes or {}) do
      local terminal = item.terminal
      if terminal then
        local record = records[terminal.session]
        local agent = record and record.state == "running" and tab.agent(record) or nil
        local attention = tab.attention({terminal = terminal, agent = agent}, seen[terminal.session])
        local active = (project.selected or selected[project.id]) and index == project.panes.active
        if attention and (not active or attention == "blocked") then
          local since = attention == "bell" and terminal.bell or agent.since or 0
          -- A still-unread bell can precede the agent's result.
          if (terminal.bell or 0) > (seen[terminal.session] or 0) then since = math.min(since, terminal.bell) end
          list[#list + 1] = {path = project.path, id = item.id, since = since}
        end
      end
    end
  end
  table.sort(list, function(a, b)
    if a.since ~= b.since then return a.since < b.since end
    return pending.key(a.path, a.id) < pending.key(b.path, b.id)
  end)
  return list
end

function pending.numbers(projects, seen)
  local order, numbers = pending.order(projects, seen), {}
  local included = {}
  for _, item in ipairs(order) do included[pending.key(item.path, item.id)] = true end
  -- Skip the current Pane before filtering duplicates. It can itself be pending.
  local history = recent.order(projects)
  for index = 2, #history do
    if #order >= pending.COUNT then break end
    local item = history[index]
    local key = pending.key(item.path, item.id)
    if not included[key] then
      order[#order + 1] = item
      included[key] = true
    end
  end
  for number = 1, math.min(pending.COUNT, #order) do
    local item = order[number]
    numbers[pending.key(item.path, item.id)] = number
  end
  return numbers, order
end

function pending.target(projects, number, seen)
  local _, order = pending.numbers(projects, seen)
  return number >= 1 and number <= pending.COUNT and order[number] or nil, #order
end

local function model()
  local project = core.root_project()
  local path = project and project.path or ""
  local projects, own = {windows = (core.project_sidebar or {}).windows}, nil
  for _, item in ipairs(core.project_sidebar or {}) do
    if common.path_compare_key(item.path) == common.path_compare_key(path) then own = item
    else projects[#projects + 1] = item end
  end
  local panes, items = require "core.panes", {}
  local active = panes.active()
  for index, pane in ipairs(panes.ordered()) do
    local view = pane.current_view
    items[index] = {id = pane.id, focused = recent.focused_at(pane)}
    if view.terminal_view then
      items[index].terminal = {session = view.session_id, state = view.state, bell = view.bell_at}
    end
    if pane == active then items.active = index end
  end
  projects[#projects + 1] = {path = path, id = own and own.id, selected = own and own.selected,
    terminals = own and own.terminals, panes = items}
  return projects, path
end

function pending.local_numbers()
  local projects, path = model()
  local numbers, result = pending.numbers(projects), {}
  for _, pane in ipairs(projects[#projects].panes) do result[pane.id] = numbers[pending.key(path, pane.id)] end
  return result
end

function pending.focus(number)
  local projects, path = model()
  local item = pending.target(projects, number)
  if not item then
    core.log_quiet("Pending Pane %d: none", number)
    return false
  end
  if common.path_compare_key(item.path) == common.path_compare_key(path) then
    return require("core.panes").focus(item.id, "numbered") ~= nil
  end
  local sent = pending.request(item.path, item.id)
  core.log_quiet("Pending Pane %d: Project=%s pane=%s sent=%s", number, item.path, tostring(item.id), tostring(sent))
  return sent
end

return pending
