-- A hosted Project sends its Tabs to the shell, which shows them in the Project Sidebar. The Sidebar sends Pane
-- actions back through the shell.
local core = require "core"
local common = require "core.common"
local panes = require "core.panes"
local tab = require "core.tab"

local pane_report = {}

-- The report must fit the shell's bound. A Project with more Panes reports the first ones.
local TAB_LIMIT = 64
local TEXT_LIMIT = 16 * 1024 - 1
-- A Project that does not render still reports changes, at most this often.
local SUSPENDED_INTERVAL = 1

local sent, built_at

-- The report: one Tab item per Pane in Pane order, each with its Pane Group's one-based index. `active` is the
-- active Pane's Tab number and `visible` the visible Pane Group's index.
function pane_report.build()
  local report, groups = {}, {}
  local active, visible = panes.active(), panes.visible_group()
  for number, pane in ipairs(panes.ordered()) do
    if number > TAB_LIMIT then break end
    if not groups[pane.group] then
      groups[#groups + 1] = pane.group
      groups[pane.group] = #groups
    end
    local item = tab.describe(pane, number)
    item.group = groups[pane.group]
    if pane == active then report.active = number end
    if pane.group == visible then report.visible = item.group end
    report[number] = item
  end
  return report
end

-- Sends the report when it changed. `suspended` limits how often a Project that does not render builds it.
function pane_report.publish(suspended)
  if not system.is_hosted_surface() then return end
  local now = system.get_time()
  if suspended and built_at and now - built_at < SUSPENDED_INTERVAL then return end
  built_at = now
  local text = common.serialize(pane_report.build(), {sort = true})
  if text == sent then return end
  if #text > TEXT_LIMIT then
    core.log_quiet("Pane report not sent: %d bytes exceed the limit", #text)
    return
  end
  if system.set_project_panes(text) then sent = text end
end

function pane_report.reset_for_tests()
  sent, built_at = nil, nil
end

return pane_report
