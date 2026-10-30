-- Transport-independent editor operations. MCP and local clients share this boundary.
local core = require "core"
local panes = require "core.panes"
local json = require "core.json"
local M = {}
M.__index = M

local function string_schema(max) return { type = "string", minLength = 1, maxLength = max or 256 } end
local function choice(...)
  return { type = "string", enum = {...} }
end
local function object(properties, required)
  return { type = "object", properties = properties, required = required, additionalProperties = false }
end
local function check(schema, value, field)
  field = field or "arguments"
  local kind = schema.type
  assert(type(value) == (kind == "object" and "table" or kind), "Invalid " .. field)
  if kind == "string" then
    assert(not value:find("%z") and #value >= (schema.minLength or 0)
      and #value <= (schema.maxLength or 32768), "Invalid " .. field)
    if schema.enum then
      local found = false
      for _, item in ipairs(schema.enum) do if item == value then found = true end end
      assert(found, "Invalid " .. field)
    end
  elseif kind == "object" then
    for key, item in pairs(value) do
      assert(schema.properties[key], "Unknown field " .. tostring(key))
      check(schema.properties[key], item, key)
    end
    for _, key in ipairs(schema.required or {}) do assert(value[key] ~= nil, "Missing " .. key) end
  end
end

M.tools = {
  { name = "workspace_state", description = "List this Project's Panes and identify the caller. IDs, not Pane numbers, select targets.",
    inputSchema = object({}, nil), annotations = { readOnlyHint = true, destructiveHint = false } },
  { name = "pane", description = "Create, split, move, focus or close a Pane. Focus stays unchanged unless requested. Close keeps normal confirmation. Reuse request_id only for retries of the same operation.",
    inputSchema = object({ action = choice("create", "split", "move", "focus", "close"),
      pane = string_schema(), target = string_schema(), direction = choice("left", "right", "up", "down"),
      focus = {type = "boolean"}, request_id = string_schema(128) }, {"action", "request_id"}),
    annotations = { readOnlyHint = false, destructiveHint = true, idempotentHint = true } },
}

local function canonical(value)
  if type(value) ~= "table" then return json.encode(value) end
  local keys, parts = {}, {}
  for key in pairs(value) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do parts[#parts + 1] = json.encode(key) .. ":" .. canonical(value[key]) end
  return "{" .. table.concat(parts, ",") .. "}"
end

function M.new()
  return setmetatable({ receipts = {}, receipt_count = 0 }, M)
end

function M:workspace_state(_, caller)
  local state = { project = core.root_project() and core.root_project().path, panes = {},
    active_pane = panes.active() and panes.active().id, caller_terminal = caller }
  for _, pane in ipairs(panes.ordered()) do
    local view = pane.current_view
    state.panes[pane.id] = { id = pane.id, group = pane.group.id, title = view:get_name(),
      file = view.buffer and view.buffer.abs_filename, terminal = view.session_id,
      terminal_state = view.state, agent_status = view.agent_state, agent_model = view.agent_model }
    for _, owned in ipairs(panes.views(pane)) do
      if owned.session_id == caller then state.caller_pane = pane.id end
    end
  end
  return state
end

function M:pane(args)
  local source = args.pane and assert(panes.find(args.pane), "Pane not found")
  local previous, active_view = panes.active(), core.active_view
  local result
  if args.action == "create" then result = assert(panes.create {focus = args.focus == true})
  elseif args.action == "split" then
    assert(source and args.direction, "Split needs a Pane and direction")
    result = assert(panes.split(source, args.direction, {focus = args.focus == true}))
  elseif args.action == "move" then
    assert(source and args.target and args.direction, "Move needs a Pane, target and direction")
    result = assert(panes.move(source, assert(panes.find(args.target), "Target Pane not found"), args.direction))
  elseif args.action == "focus" then
    assert(source, "Focus needs a Pane")
    result = assert(panes.focus(source))
  elseif args.action == "close" then
    assert(source, "Close needs a Pane")
    return { pane = source.id, status = panes.close(source) and "closed" or "confirmation_required" }
  end
  if args.action ~= "focus" and not args.focus and previous and panes.contains(previous) then
    panes.focus(previous)
    if active_view and active_view ~= core.active_view then core.set_active_view(active_view) end
  end
  return { pane = result.id, status = "completed" }
end

function M:call(name, args, caller)
  local definition
  for _, tool in ipairs(M.tools) do if tool.name == name then definition = tool; break end end
  assert(definition, "Unknown control tool")
  check(definition.inputSchema, args)
  local key = args.request_id and ((caller or "local") .. ":" .. args.request_id)
  local fingerprint = name .. canonical(args)
  if key and self.receipts[key] then
    local receipt = self.receipts[key]
    assert(receipt.fingerprint == fingerprint, "Request ID already names different work")
    if receipt.error then error(receipt.error, 0) end
    return receipt.result
  end
  if key then
    assert(self.receipt_count < 4096, "Control receipt limit reached; reconnect after restarting this Project")
    self.receipt_count = self.receipt_count + 1
    -- Reserve before executing. A failed partial operation must not run twice.
    self.receipts[key] = { fingerprint = fingerprint, error = "Operation did not finish" }
  end
  local ok, result = pcall(self[name], self, args, caller)
  if key then
    self.receipts[key].result, self.receipts[key].error = ok and result or nil, not ok and tostring(result) or nil
    core.log_quiet("Control: %s caller=%s request=%s ok=%s", name, caller or "local", args.request_id, tostring(ok))
  end
  if not ok then error(result, 0) end
  return result
end

return M
