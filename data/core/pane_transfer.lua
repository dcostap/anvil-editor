local core = require "core"
local common = require "core.common"
local panes = require "core.panes"
local system = require "system"

local M = {}
local pending = {}

local function serialize(value)
  return common.serialize(value, { escape = true })
end

local function refuse(reason)
  reason = tostring(reason)
  core.log_quiet("Pane transfer refused: %s", reason)
  core.warn("Pane transfer: %s", reason)
  return nil, reason
end

local function send(route, path, request)
  local text = serialize(request)
  -- The request header has four 32-bit fields. The path has no terminator.
  if #text > 65536 - 16 - #path then return nil, "Pane exceeds the transfer size limit" end
  if not system.pane_request(route, path, text) then
    return nil, "Could not send the Pane transfer request"
  end
  return true
end

local function export(request)
  local pane = panes.find(request.pane)
  if not pane then return refuse("Pane is no longer available") end
  if pending[request.transfer] then return refuse("Transfer is already pending") end
  local views = panes.views(pane)
  for _, view in ipairs(views) do
    if view:get_module() == "plugins.terminal" and view:get_state().kind ~= "text_capture" then
      return refuse("A Terminal Session belongs to one Project")
    end
  end
  local buffers = {}
  for _, view in ipairs(views) do
    local buffer = view.buffer
    if buffer and not buffers[buffer] then
      if buffer.filename and buffer:is_dirty() then
        core.log_quiet("Pane transfer saving %s", buffer.filename)
        local ok, err = pcall(buffer.save, buffer)
        if not ok or buffer:is_dirty() then
          return refuse("Could not save " .. buffer.filename .. ": " .. tostring(err or "unsaved edits remain"))
        end
      end
      buffers[buffer] = buffer:get_change_id()
    end
  end
  local snapshot, err = panes.snapshot(pane)
  if not snapshot then return refuse(err) end
  -- Editor state already includes Untitled text. File paths must cross Project roots.
  for index, view in ipairs(views) do
    if view.buffer and view.buffer.abs_filename and snapshot.views[index].state.filename then
      snapshot.views[index].state.filename = view.buffer.abs_filename
    end
  end
  local project = core.root_project()
  pending[request.transfer] = { pane = pane, views = views, buffers = buffers }
  local ok
  ok, err = send("select", request.to, { action = "import", snapshot = snapshot,
    source = project and project.path or system.getcwd(), target = request.target, transfer = request.transfer })
  if not ok then
    pending[request.transfer] = nil
    return refuse(err)
  end
  core.log_quiet("Pane transfer %s exported %s to %s", request.transfer, pane.id, request.to)
  return true
end

local function import(request)
  local pane
  local ok, err = pcall(function()
    local reason
    pane, reason = panes.restore(request.snapshot, { focus = false })
    assert(pane, reason)
    local placed
    placed, reason = require("core.pane_requests").place(pane, request.target)
    assert(placed, reason)
  end)
  if not ok and pane then panes.close(pane, { force = true }) end
  core.log_quiet("Pane transfer %s import: %s", request.transfer, ok and "restored" or tostring(err))
  local sent, send_error = send("direct", request.source, { action = "transferred",
    transfer = request.transfer, ok = ok, error = not ok and tostring(err) or nil })
  if not sent then return refuse(send_error) end
  if not ok then return refuse(err) end
  return true
end

local function transferred(request)
  local transfer = pending[request.transfer]
  if not transfer then
    core.log_quiet("Pane transfer %s answer ignored: no pending transfer", request.transfer)
    return true
  end
  pending[request.transfer] = nil
  if not request.ok then return refuse(request.error or "The target could not restore the Pane") end
  local pane = transfer.pane
  if panes.find(pane.id) ~= pane then
    core.log_quiet("Pane transfer %s confirmed after source closed", request.transfer)
    return true
  end
  -- The target restored the Views and text that the snapshot held. Scrolling and focus can change meanwhile.
  local views = panes.views(pane)
  local changed = #views ~= #transfer.views
  for index, view in ipairs(views) do
    if view ~= transfer.views[index] then changed = true end
  end
  for buffer, revision in pairs(transfer.buffers) do
    if buffer:get_change_id() ~= revision or (buffer.filename and buffer:is_dirty()) then changed = true end
  end
  if changed then
    core.log_quiet("Pane transfer %s kept source: Pane changed after export", request.transfer)
    return true
  end
  panes.close(pane, { force = true })
  core.log_quiet("Pane transfer %s confirmed; source %s closed", request.transfer, pane.id)
  return true
end

function M.perform(request)
  core.log_quiet("Pane transfer %s: %s", tostring(request.transfer), tostring(request.action))
  if request.action == "export" then return export(request) end
  if request.action == "import" then return import(request) end
  if request.action == "transferred" then return transferred(request) end
  return nil, "Unknown Pane transfer action"
end

return M
