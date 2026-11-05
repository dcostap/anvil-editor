-- Snoozed Panes. The Project Sidebar saves each Snooze time by Terminal Session, then asks this Project to snooze
-- or wake the Terminal's Pane. Saved times also repair a Workspace whose Snooze flags were not saved yet.
-- A Snoozed Pane without a saved time wakes too, so a lost time cannot hide a Pane.
local core = require "core"
local panes = require "core.panes"
local layout = require "core.pane_layout"
local storage = require "core.storage"

local snoozed_panes = {}

-- How often, in seconds, this Project compares the Snooze times with the clock.
local INTERVAL = 5

-- The Terminal Session that the Pane shows, or else one that its history keeps.
function snoozed_panes.session(pane)
  local current = pane.current_view
  if current and current.terminal_view and current.session_id then return current.session_id end
  for _, view in ipairs(panes.views(pane)) do
    if view.terminal_view and view.session_id then return view.session_id end
  end
end

local function changed()
  if core.request_workspace_save then core.request_workspace_save("snooze") end
end

function snoozed_panes.snooze(target)
  local pane = panes.find(target)
  if not pane then return nil, "Pane not found" end
  if not snoozed_panes.session(pane) then return nil, "only a Terminal's Pane can snooze" end
  panes.snooze(pane)
  core.log_quiet("Snoozed Pane %s: session=%s", pane.id, snoozed_panes.session(pane))
  changed()
  return true
end

function snoozed_panes.wake(target)
  local count = panes.wake {target}
  core.log_quiet("Snoozed Pane %s woke on request: %s", tostring(target and target.id or target), count > 0 and "yes" or "no")
  if count > 0 then changed() end
  return true
end

-- Wakes the Snoozed Panes whose time has come, oldest Snooze first, so the ones that come due together share
-- Pane Groups. An unreadable times file wakes nothing.
function snoozed_panes.check()
  local ok, times, err = pcall(storage.load, "sidebar", "snoozes")
  if not ok or err or times ~= nil and type(times) ~= "table" then
    core.log_quiet("Snoozed Panes: times not read: %s", tostring(err or times))
    return 0
  end
  times = type(times) == "table" and times or {}
  for session, time in pairs(times) do
    if type(session) ~= "string" or type(time) ~= "number" then
      core.log_quiet("Snoozed Panes: invalid saved time")
      return 0
    end
  end
  local now, due = os.time(), {}
  -- Snapshot the list: snoozing a Pane changes its group and the group order.
  local recovered = 0
  for _, pane in ipairs(panes.ordered()) do
    local view = pane.current_view
    local time = view and view.terminal_view and times[view.session_id]
    if type(time) == "number" and time > now and not pane.group.snoozed then
      panes.snooze(pane, true)
      recovered = recovered + 1
    end
  end
  if recovered > 0 then
    core.log_quiet("Snoozed Panes: restored %d saved Snooze(s)", recovered)
    changed()
  end
  for _, group in ipairs(panes.groups) do
    if group.snoozed then
      local pane = layout.leaves(group.root)[1]
      local time = times[snoozed_panes.session(pane) or ""]
      if type(time) ~= "number" or time <= now then due[#due + 1] = {pane = pane, time = tonumber(time) or 0} end
    end
  end
  if #due == 0 then return 0 end
  table.sort(due, function(a, b) return a.time < b.time end)
  local list = {}
  for index, item in ipairs(due) do list[index] = item.pane end
  local count = panes.wake(list)
  core.log_quiet("Snoozed Panes: %d came due", count)
  changed()
  return count
end

-- Starts the check in a Project that the shell hosts. Only the shell's Sidebar sets Snoozes.
function snoozed_panes.start()
  if snoozed_panes.started or not system.is_hosted_surface() then return end
  snoozed_panes.started = true
  core.add_thread(function()
    while true do
      core.try(snoozed_panes.check)
      coroutine.yield(INTERVAL)
    end
  end)
end

return snoozed_panes
