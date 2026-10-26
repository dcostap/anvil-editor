local core = require "core"
local common = require "core.common"
local panes = require "core.panes"
local layout = require "core.pane_layout"

local M = {}

local function fail(message)
  core.log_quiet("Pane request: rejected: %s", tostring(message))
  return nil, message
end

local function fields(value, allowed)
  if type(value) ~= "table" then return false end
  for key in pairs(value) do
    if not allowed[key] then return false end
  end
  return true
end

local function identifier(value)
  return type(value) == "string" and value ~= "" and not value:find("%z")
end

-- A position without an anchor is the end of the Tab order, so it needs no side.
local function position(target)
  if not fields(target, {mode = true, anchor = true, side = true})
    or (target.mode ~= "group" and target.mode ~= "join")
    or (target.side ~= "before" and target.side ~= "after" and (target.anchor or target.side ~= nil))
    or (target.anchor ~= nil and not identifier(target.anchor))
    or (target.mode == "join" and not target.anchor) then
    return nil, "invalid position"
  end
  return true
end

function M.place(pane, target)
  local valid, err = position(target)
  if not valid then return fail(err) end
  pane = panes.find(pane)
  if not pane then return fail("Pane not found") end
  local anchor = target.anchor and panes.find(target.anchor)
  if target.anchor and not anchor then return fail("anchor Pane not found") end
  local unchanged = false
  if target.mode == "group" then
    if not anchor then
      local ordered = panes.ordered()
      anchor = ordered[#ordered]
    end
    local side = target.anchor and target.side or "after"
    if #layout.leaves(pane.group.root) == 1 then
      local source_index, anchor_index
      for i, group in ipairs(panes.groups) do
        if group == pane.group then source_index = i end
        if group == anchor.group then anchor_index = i end
      end
      unchanged = source_index == anchor_index
        or source_index == anchor_index + (side == "before" and -1 or 1)
    end
    if not unchanged then pane, err = panes.move_to_group_boundary(pane, anchor, side) end
  else
    unchanged = pane == anchor
    if pane.group == anchor.group then
      local ordered = layout.leaves(pane.group.root)
      local source_index, anchor_index
      for i, item in ipairs(ordered) do
        if item == pane then source_index = i end
        if item == anchor then anchor_index = i end
      end
      unchanged = unchanged or source_index == anchor_index + (target.side == "before" and -1 or 1)
    end
    if not unchanged then
      local _, parent = layout.find(anchor.group.root, anchor)
      local vertical = parent and parent.axis == "y"
      local direction = target.side == "before" and (vertical and "up" or "left")
        or (vertical and "down" or "right")
      pane, err = panes.move(pane, anchor, direction)
    end
  end
  if not pane then return fail(err) end
  panes.focus(pane)
  core.log_quiet("Pane request: placed %s mode=%s unchanged=%s", pane.id, target.mode, tostring(unchanged))
  return pane
end

local schemas = {
  new_group = {},
  focus = {pane = true, feedback = true}, close = {pane = true}, move = {pane = true, target = true},
  open = {files = true, text = true, target = true},
  launch = {files = true},
  drop = {pane = true, files = true, text = true},
  export = {pane = true, to = true, target = true, transfer = true},
  import = {snapshot = true, target = true, source = true, transfer = true},
  transferred = {transfer = true, ok = true, error = true},
  drag = {phase = true, source = true, pane = true},
}
for _, schema in pairs(schemas) do schema.action = true end

local function validate(request)
  if type(request) ~= "table" or type(request.action) ~= "string" then return nil, "invalid request" end
  local schema = schemas[request.action]
  if not schema or not fields(request, schema) then return nil, "unknown action or field" end
  if schema.pane and not identifier(request.pane) then return nil, "invalid Pane ID" end
  if request.feedback ~= nil and request.feedback ~= "numbered" then return nil, "invalid focus feedback" end
  if schema.target then
    local ok, err = position(request.target)
    if not ok then return nil, err end
  end
  for _, key in ipairs {"to", "source"} do
    if schema[key] and (not identifier(request[key]) or not common.is_absolute_path(request[key])) then
      return nil, "invalid Project path"
    end
  end
  if schema.transfer and not identifier(request.transfer) then return nil, "invalid transfer ID" end
  if schema.snapshot and type(request.snapshot) ~= "table" then return nil, "invalid snapshot" end
  if request.action == "transferred" and (type(request.ok) ~= "boolean"
    or (request.error ~= nil and type(request.error) ~= "string")) then return nil, "invalid transfer result" end
  if request.action == "drag" and request.phase ~= "move" and request.phase ~= "drop"
    and request.phase ~= "leave" then return nil, "invalid drag phase" end
  if schema.files then
    if request.text ~= nil and type(request.text) ~= "string" then return nil, "invalid drop text" end
    if request.files ~= nil then
      if type(request.files) ~= "table" then return nil, "invalid files" end
      local count = 0
      for index, path in pairs(request.files) do
        if type(index) ~= "number" or index < 1 or index % 1 ~= 0
          or not identifier(path) or not common.is_absolute_path(path) then return nil, "invalid file path" end
        count = count + 1
      end
      if count ~= #request.files then return nil, "invalid file list" end
    end
    if not request.text and (not request.files or #request.files == 0) then return nil, "empty drop" end
  end
  return true
end

local function execute(request, x, y)
  local action = request.action
  if action == "new_group" then return require("core.command").perform("pane:new_group") end
  if action == "drag" then
    -- A Tab of another Project has the same Pane IDs, so the source Project must be this one.
    local project = core.root_project()
    local own = project and common.path_equals(project.path, request.source)
    core.title_bar:sidebar_pane_drag(own and panes.find(request.pane) or nil, request.phase, x, y)
    return true
  end
  if action == "export" or action == "import" or action == "transferred" then
    return require("core.pane_transfer").perform(request)
  end
  local pane = request.pane and panes.find(request.pane)
  if request.pane and not pane then return nil, "Pane not found" end
  -- An external launch names files, including new ones. Each opens in a new Pane, as from a Terminal.
  if action == "launch" then
    for _, path in ipairs(request.files) do
      local opened, err = core.open_file(path, { placement = "new", reason = "launch" })
      core.log_quiet("Pane request: launch opened %s: %s", path, opened and "yes" or tostring(err))
      if not opened then core.error("Cannot open %s: %s", path, tostring(err)) end
    end
    return true
  end
  if action == "focus" then panes.focus(pane, request.feedback); return true end
  if action == "close" then panes.close(pane); return true end
  if action == "move" then
    local placed, err = M.place(pane, request.target)
    return placed and true, err
  end
  if request.target and request.target.anchor and not panes.find(request.target.anchor) then
    return nil, "anchor Pane not found"
  end
  local root = core.root_panel
  local files = request.files or {}
  local text = (request.text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  if action == "drop" then
    if root:deliver_drop_to_view(pane, {files = files, text = text}) then return true end
    core.log_quiet("Pane request: View declined drop; opening %d files in %s", #files, pane.id)
    for _, path in ipairs(files) do
      if not root:open_dropped_file(path, nil, nil, {kind = "current", pane = pane}) then
        return nil, "could not open dropped file"
      end
    end
    return true
  end
  local target = request.target
  local function place_view(view)
    if not view then return nil, "could not open dropped content" end
    local placed, err = M.place(panes.pane_for_view(view), target)
    if not placed then return nil, err end
    target = {mode = target.mode, anchor = placed.id, side = "after"}
    return true
  end
  for _, path in ipairs(files) do
    local ok, err = place_view(root:open_dropped_file(path, nil, nil, {kind = "new"}))
    if not ok then return nil, err end
  end
  if text ~= "" then
    local Buffer = require "core.buffer"
    local buffer = Buffer(nil, nil, true)
    buffer:insert(1, 1, text)
    local ok, err = place_view(root:open_buffer(buffer, {placement = "new", reason = "text-drop"}))
    if not ok then return nil, err end
  end
  return true
end

function M.perform(text, x, y)
  if type(text) ~= "string" then return fail("request text must be a string") end
  local chunk, err = load("return " .. text, "=Pane request", "t", {})
  if not chunk then return fail(err) end
  local loaded, request = pcall(chunk)
  if not loaded then return fail(request) end
  local valid
  valid, err = validate(request)
  if not valid then return fail(err) end
  -- A drag sends a request for each pointer move.
  local quiet = request.phase == "move"
  if not quiet then
    core.log_quiet("Pane request: %s pointer=%s,%s", request.action, tostring(x), tostring(y))
  end
  local called, result
  called, result, err = pcall(execute, request, x, y)
  if not called then return fail(result) end
  if not result then return fail(err or "action failed") end
  if not quiet then core.log_quiet("Pane request: completed %s", request.action) end
  return true
end

return M
