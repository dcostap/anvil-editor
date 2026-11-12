-- Pending Panes first, then Recent Panes in the remaining number slots.
local core = require "core"
local common = require "core.common"
local tab = require "core.tab"
local recent = require "core.recent_panes"
local storage = require "core.storage"
local pending = {COUNT = recent.COUNT, key = recent.key, request = recent.request}

-- Sidebar surfaces supply their shared live tables. Projects read the same persisted seen times and Snoozes.
-- The Sidebar process writes them. Only the first read is on the UI thread. A worker rereads them,
-- because a slow disk must not stop the UI.
local cache = {}
local function store(entry, value)
  entry.value = type(value) == "table" and value or {}
end

local function reread(key, entry)
  local function done() entry.job = nil end
  entry.job = require("core.worker_pool").system():submit {
    kind = "storage_load", priority = "background",
    payload = {userdir = USERDIR, module = "sidebar", key = key},
    on_result = function(message) store(entry, message.payload.value) end,
    on_complete = done, on_error = done, on_cancelled = done,
  }
end

local function saved(key)
  local now, entry = system.get_time(), cache[key]
  if not entry then
    entry = {value = {}, read_at = now}
    local ok, value = pcall(storage.load, "sidebar", key)
    if ok then store(entry, value) end
    cache[key] = entry
  elseif now - entry.read_at >= 0.25 and not entry.job then
    entry.read_at = now
    reread(key, entry)
  end
  return entry.value
end

function pending.order(projects, seen, snoozes, window_id)
  window_id = window_id or system.get_anvil_window_id()
  seen, snoozes = seen or saved("seen"), snoozes or saved("snoozes")
  local list = {}
  local selected = {}
  for _, window in ipairs(projects and projects.windows or {}) do selected[window.selected_project] = true end
  for _, project in ipairs(projects or {}) do
    if (project.window_id or 0) == window_id then
      local records = {}
      for _, record in ipairs(project.terminals or {}) do records[record.id] = record end
      for index, item in ipairs(project.panes or {}) do
        local terminal = item.terminal
        if terminal and not item.snoozed then
          local record = records[terminal.session]
          local agent = record and record.state == "running" and tab.agent(record) or nil
          local snooze = snoozes[terminal.session]
          local attention = tab.attention({terminal = terminal, agent = agent}, seen[terminal.session], snooze)
          local active = (project.selected or selected[project.id]) and index == project.panes.active
          if attention and (not active or attention == "blocked") then
            local since = attention == "bell" and terminal.bell or attention == "snooze" and snooze
              or agent.since or 0
            -- A still-unread bell can precede the agent's result.
            if (terminal.bell or 0) > (seen[terminal.session] or 0) then since = math.min(since, terminal.bell) end
            -- A held Terminal joins the queue at its Snooze time.
            if snooze then since = math.max(since, snooze) end
            list[#list + 1] = {path = project.path, id = item.id, since = since}
          end
        end
      end
    end
  end
  table.sort(list, function(a, b)
    if a.since ~= b.since then return a.since > b.since end
    return pending.key(a.path, a.id) < pending.key(b.path, b.id)
  end)
  return list
end

-- A new pending event waits HOLD seconds before it takes a number, so a number key that the user presses for the
-- shown numbers still reaches the shown Pane. Each process times the events that it sees.
pending.HOLD = 0.25
local arrivals, arrival_count = {}, 0

-- Removes the events that arrived less than HOLD ago.
-- Returns the rest and the time when the next held event takes its number.
local function hold(order)
  local now, kept, release = system.get_time(), {}, nil
  for _, item in ipairs(order) do
    local event = pending.key(item.path, item.id) .. "@" .. item.since
    local arrival = arrivals[event]
    if not arrival then
      arrival, arrival_count = {at = now}, arrival_count + 1
      arrivals[event] = arrival
    end
    arrival.checked = now
    if now - arrival.at >= pending.HOLD then
      kept[#kept + 1] = item
    else
      release = math.min(release or math.huge, arrival.at + pending.HOLD)
    end
  end
  if arrival_count > 256 then
    for event, arrival in pairs(arrivals) do
      if now - arrival.checked > 3600 then arrivals[event], arrival_count = nil, arrival_count - 1 end
    end
  end
  return kept, release
end

-- Returns the numbers, the numbered order and the time when a held event takes its number.
function pending.numbers(projects, seen, snoozes, window_id)
  local order, release = hold(pending.order(projects, seen, snoozes, window_id))
  local numbers, included = {}, {}
  for _, item in ipairs(order) do included[pending.key(item.path, item.id)] = true end
  -- Skip the current Pane before filtering duplicates. It can itself be pending.
  local history = recent.order(projects, window_id)
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
  return numbers, order, release
end

function pending.target(projects, number, seen, snoozes, window_id)
  local _, order = pending.numbers(projects, seen, snoozes, window_id)
  return number >= 1 and number <= pending.COUNT and order[number] or nil, #order
end

local function model()
  local project = core.root_project()
  -- The Sidebar names a Project on a Machine by its key.
  local path = project and require("core.machine_project").root_key(project.path) or ""
  local projects, own = {windows = (core.project_sidebar or {}).windows}, nil
  for _, item in ipairs(core.project_sidebar or {}) do
    if common.path_compare_key(item.path) == common.path_compare_key(path) then own = item
    else projects[#projects + 1] = item end
  end
  local panes, items = require "core.panes", {}
  local active = panes.active()
  for index, pane in ipairs(panes.ordered()) do
    local view = pane.current_view
    items[index] = {id = pane.id, focused = recent.focused_at(pane), snoozed = pane.group.snoozed}
    if view.terminal_view then
      items[index].terminal = {session = view.session_id, state = view.state, bell = view.bell_at}
    end
    if pane == active then items.active = index end
  end
  projects[#projects + 1] = {path = path, id = own and own.id, selected = own and own.selected,
    terminals = own and own.terminals, panes = items, window_id = system.get_anvil_window_id()}
  return projects, path
end

-- All local attention marks, without the Pane number limit or Recent Pane slots.
function pending.local_attention()
  local projects = model()
  -- A close can just have revealed this Pane's Terminal. Selection alone does not mean it was read.
  projects[#projects].selected = false
  local result = {}
  for _, item in ipairs(pending.order {projects[#projects]}) do result[item.id] = true end
  return result
end

local redraw_at

function pending.local_numbers()
  local projects, path = model()
  local numbers, _, release = pending.numbers(projects)
  -- Draw the held event's number when it takes it.
  if release and release ~= redraw_at then
    redraw_at = release
    core.add_thread(function()
      coroutine.yield(math.max(0, release - system.get_time()))
      core.redraw = true
    end)
  end
  local result = {}
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
    core.log_quiet("Pending Pane %d: Project=%s pane=%s local=true", number, path, tostring(item.id))
    return require("core.panes").focus(item.id, "numbered") ~= nil
  end
  local sent = pending.request(item.path, item.id)
  core.log_quiet("Pending Pane %d: Project=%s pane=%s sent=%s", number, item.path, tostring(item.id), tostring(sent))
  return sent
end

return pending
