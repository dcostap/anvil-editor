-- Transport-independent editor operations. MCP and local clients share this boundary.
local core = require "core"
local panes = require "core.panes"
local json = require "core.json"
local net = require "net"
local common = require "core.common"
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
  assert(type(value) == ((kind == "object" or kind == "array") and "table" or kind == "integer" and "number" or kind), "Invalid " .. field)
  if kind == "string" then
    assert(not value:find("%z") and #value >= (schema.minLength or 0)
      and #value <= (schema.maxLength or 32768), "Invalid " .. field)
    if schema.enum then
      local found = false
      for _, item in ipairs(schema.enum) do if item == value then found = true end end
      assert(found, "Invalid " .. field)
    end
  elseif kind == "integer" then
    assert(value % 1 == 0 and value >= (schema.minimum or 1) and value <= (schema.maximum or 10000000), "Invalid " .. field)
  elseif kind == "array" then
    assert(#value <= (schema.maxItems or 64), "Too many " .. field)
    for key, item in pairs(value) do
      assert(type(key) == "number" and key >= 1 and key <= #value and key % 1 == 0, "Invalid " .. field)
      check(schema.items, item, field)
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

local function tool(name, description, properties, required, readonly)
  M.tools[#M.tools + 1] = {name = name, description = description,
    inputSchema = object(properties, required), annotations = {readOnlyHint = readonly,
      destructiveHint = not readonly, idempotentHint = true}}
end
local id = string_schema(128)
tool("agent_send", "Send a task to a specific Pi conversation. Queue waits until idle; steer changes active work. Returns a task ID, not a completed answer.",
  {terminal = id, instance = id, text = string_schema(32768), delivery = choice("queue", "steer"), request_id = id},
  {"terminal", "instance", "text", "delivery", "request_id"}, false)
tool("agent_read", "Read Pi status or the saved result of a task. Use the instance ID from workspace_state. A disconnected Pi is not complete.",
  {terminal = id, instance = id, task = id}, {"terminal", "instance"}, true)
tool("agent_interrupt", "Interrupt Pi's active work and cancel its queued Anvil tasks. Keep its Terminal Session open.",
  {terminal = id, instance = id, request_id = id}, {"terminal", "instance", "request_id"}, false)
tool("agent_wait", "Wait up to 30 seconds for a task. Timeout does not cancel it. A question or disconnect ends the wait.",
  {terminal = id, instance = id, task = id, timeout_ms = {type = "integer", minimum = 1, maximum = 30000}},
  {"terminal", "instance", "task"}, true)
local function placement(extra)
  local fields = {pane = id, placement = choice("new", "split"), direction = choice("left", "right", "up", "down"),
    focus = {type = "boolean"}, request_id = id}
  for key, value in pairs(extra or {}) do fields[key] = value end
  return fields
end
tool("open_file", "Open a file at a line in a new Pane or an explicit split. Keep the user's focus unless requested.",
  placement {path = string_schema(32768), line = {type = "integer"}, col = {type = "integer"}}, {"path", "request_id"}, false)
tool("terminal_start", "Open a Terminal Session, optionally running an executable with literal arguments. Structured program launch uses PowerShell on Windows. Returns an operation ID; query operation_read for readiness.",
  placement {cwd = string_schema(32768), executable = string_schema(4096), args = {type = "array", items = string_schema(4096), maxItems = 64}},
  {"cwd", "request_id"}, false)
tool("pi_start", "Start an independent interactive Pi in a new Terminal Pane. Specify provider, model and thinking explicitly. Optional task reaches Pi after its control connection is ready. No parent conversation is copied.",
  placement {cwd = string_schema(32768), provider = string_schema(), model = string_schema(),
    thinking = choice("off", "minimal", "low", "medium", "high", "xhigh", "max"), task = string_schema(32768)},
  {"cwd", "provider", "model", "thinking", "request_id"}, false)
tool("operation_read", "Read startup progress or failure. A ready Pi result includes its conversation instance and initial task ID.",
  {operation = id}, {"operation"}, true)
tool("terminal", "Read bounded terminal text, send literal terminal input, or end a Terminal through its normal Pane Close confirmation. Use agent_send for Pi tasks.",
  {action = choice("read", "input", "close"), terminal = id, text = string_schema(32768), request_id = id},
  {"action", "terminal"}, false)
for _, definition in ipairs(M.tools) do
  definition.inputSchema.properties.project = string_schema(32768)
end

local function canonical(value)
  if type(value) ~= "table" then return json.encode(value) end
  local keys, parts = {}, {}
  for key in pairs(value) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do parts[#parts + 1] = json.encode(key) .. ":" .. canonical(value[key]) end
  return "{" .. table.concat(parts, ",") .. "}"
end

function M.new(project)
  return setmetatable({ project = project or core.root_project().path,
    receipts = {}, receipt_count = 0, peers = {}, jobs = {}, starting = {} }, M)
end

function M:workspace_state(_, caller)
  local state = { project = self.project, panes = {}, terminals = {},
    active_pane = panes.active() and panes.active().id, caller_terminal = caller }
  for _, pane in ipairs(panes.ordered()) do
    local view = pane.current_view
    state.panes[pane.id] = { id = pane.id, group = pane.group.id, title = view:get_name(),
      file = view.buffer and view.buffer.abs_filename, terminal = view.session_id,
      terminal_state = view.state, agent_model = view.agent_model }
    local peer = view.session_id and self.peers[view.session_id]
    if peer then
      state.panes[pane.id].agent_instance = peer.instance
      state.panes[pane.id].agent_connected = system.get_time() - peer.seen < 10
    end
    for _, owned in ipairs(panes.views(pane)) do
      if owned.session_id == caller then state.caller_pane = pane.id end
      if owned.session_id then
        local peer = self.peers[owned.session_id]
        local status = owned:close_status()
        state.terminals[owned.session_id] = {terminal = owned.session_id, pane = pane.id, current = owned == view,
          state = owned.state, program = owned.agent_app, agent_status = status.agent_state,
          agent_model = owned.agent_model, agent_instance = peer and peer.instance,
          agent_connected = peer and system.get_time() - peer.seen < 10}
      end
    end
  end
  return state
end

local function place_options(args)
  if args.pane then assert(panes.find(args.pane), "Pane not found") end
  if args.placement == "split" then assert(args.pane and args.direction, "Split needs a Pane and direction") end
  return {pane = args.pane, placement = args.placement or "new", direction = args.direction,
    focus = args.focus == true, preserve_focus = args.focus ~= true, reason = "agent-control"}
end

function M:open_file(args)
  local opts = place_options(args)
  opts.line, opts.col = args.line, args.col
  local view, err = core.open_file(args.path, opts)
  if view == false then return {status = "confirmation_required"} end
  assert(view, err)
  return {pane = panes.pane_for_view(view).id, status = "completed"}
end

local function quote_argument(value)
  assert(not value:find("[%z\r\n]"), "Program arguments cannot contain line breaks")
  -- Windows CommandLineToArgvW rules. PowerShell passes this string to CreateProcess unchanged.
  return '"' .. value:gsub('(\\*)"', function(slashes) return slashes .. slashes .. '\\"' end)
    :gsub('(\\+)$', '%1%1') .. '"'
end

function M:launch(args, caller, pi)
  assert(PLATFORM == "Windows", "Terminal control currently requires Windows")
  assert(common.is_absolute_path(args.cwd), "Use an absolute starting directory")
  local info = system.get_file_info(args.cwd)
  assert(info and info.type == "dir", "Starting directory not found")
  local executable, argv = args.executable, args.args or {}
  if pi then
    executable = "pi"
    argv = {"--provider", args.provider, "--model", args.model, "--thinking", args.thinking}
  end
  local command
  if executable then
    local shell = require("core.config").plugins.terminal.shell:lower()
    assert(shell == "" or shell:find("powershell", 1, true) or shell:find("pwsh", 1, true),
      "Structured program launch requires a PowerShell Terminal")
    local parts = {quote_argument(executable)}
    for _, arg in ipairs(argv) do parts[#parts + 1] = quote_argument(arg) end
    command = table.concat(parts, " ")
    assert(#command <= 16384, "Program command line is too long")
  else assert(#argv == 0, "Arguments need an executable") end
  local options = place_options(args)
  options.cwd = args.cwd
  local view, err = require("plugins.terminal").open(options)
  assert(view, err)
  view.input_used = true
  local operation = net.random_token()
  local result = {operation = operation, pane = panes.pane_for_view(view).id, status = "starting"}
  self.jobs[operation] = {result = result, view = view, command = command, pi = pi, task = args.task,
    caller = caller, provider = args.provider, model = args.model, thinking = args.thinking,
    deadline = system.get_time() + 60}
  self.starting[operation] = self.jobs[operation]
  return result
end

function M:terminal_start(args, caller) return self:launch(args, caller, false) end
function M:pi_start(args, caller) return self:launch(args, caller, true) end
function M:operation_read(args) return assert(self.jobs[args.operation], "Operation not found").result end

function M:tick()
  for operation, job in pairs(self.starting) do
    local view, result = job.view, job.result
    if view and result.status == "starting" then
      if view.state == "failed" or view.state == "closed" or view.state == "exited" or system.get_time() > job.deadline then
        result.status, result.error = "failed", view.launch_error or "Terminal or Pi startup did not finish"
      elseif view.state == "running" and view.session_id then
        result.terminal = view.session_id
        if job.command then
          if not view:run_command_line(job.command) then result.status, result.error = "failed", "Could not start program" end
          job.command = nil
        end
        local peer = self.peers[view.session_id]
        if result.status == "starting" and (not job.pi or peer and system.get_time() - peer.seen < 10) then
          local matches = not job.pi or peer.model and peer.model.provider == job.provider
            and peer.model.id == job.model and peer.thinking == job.thinking
          result.status = matches and "ready" or "failed"
          if not matches then result.error = "Pi selected a different model or thinking level" end
          if peer then result.instance = peer.instance end
          if job.task and matches then
            local ok, sent = pcall(self.agent_send, self, {terminal = view.session_id, instance = peer.instance,
              text = job.task, delivery = "queue"}, job.caller)
            if ok then result.task = sent.task else result.status, result.error = "failed", tostring(sent) end
          end
        end
      end
      if result.status ~= "starting" then
        core.log_quiet("Control: launch %s status=%s Pane=%s", result.operation, result.status, result.pane)
        job.view, job.task = nil, nil
        self.starting[operation] = nil
      end
    end
  end
end

local function terminal_view(id)
  for _, view in ipairs(require("plugins.terminal").open_views()) do
    if view.session_id == id then return view end
  end
  error("Terminal Session has no View in this Project", 0)
end

function M:terminal(args)
  local view = terminal_view(args.terminal)
  if args.action == "close" then
    assert(args.request_id, "Close needs a request_id")
    local pane = panes.pane_for_view(view)
    local closed = panes.close_view(pane, {view = view, keep_pane = pane.current_view ~= view})
    return {status = closed and "closed" or "confirmation_required"}
  end
  assert(view.session and view.state == "running", "Terminal is not running")
  if args.action == "input" then
    assert(args.request_id and args.text, "Input needs text and a request_id")
    assert(view.agent_app ~= "pi", "Use agent_send to communicate with Pi")
    assert(view:write_input(args.text), "Terminal input was rejected")
    return {status = "accepted"}
  end
  local text = view.session:plain_text() or ""
  return {text = text:sub(-32768), truncated = #text > 32768}
end

local terminal_status = {completed = true, failed = true, interrupted = true}

function M:exchange(terminal, report)
  check(id, report.instance, "Pi instance")
  assert(type(report.receipts) == "table" and #report.receipts <= 256, "Invalid receipts")
  assert(type(report.tasks) == "table" and #report.tasks <= 32, "Invalid tasks")
  local peer = self.peers[terminal]
  if not peer or peer.instance ~= report.instance then
    peer = {instance = report.instance, commands = {}, receipts = {}, tasks = {}}
    self.peers[terminal] = peer
    core.log_quiet("Control: Pi connected Terminal=%s instance=%s", terminal, report.instance)
  end
  peer.seen, peer.busy = system.get_time(), report.busy == true
  peer.session, peer.model, peer.thinking = report.session, report.model, report.thinking
  peer.capacity = type(report.capacity) == "number" and math.max(0, math.min(256, report.capacity)) or 256
  for _, receipt in ipairs(report.receipts) do
    check(id, receipt.id, "receipt ID")
    if peer.commands[receipt.id] or peer.receipts[receipt.id] then
      peer.receipts[receipt.id] = receipt
      peer.commands[receipt.id] = nil
    end
  end
  for _, task in ipairs(report.tasks) do
    check(id, task.id, "task ID")
    assert(task.status == "queued" or task.status == "running" or terminal_status[task.status], "Invalid task state")
    assert(task.result == nil or type(task.result) == "string" and #task.result <= 32768, "Invalid task result")
    local previous = peer.tasks[task.id]
    if not previous or not terminal_status[previous.status] then peer.tasks[task.id] = task end
  end
  local commands = {}
  for _, command in pairs(peer.commands) do commands[#commands + 1] = command end
  table.sort(commands, function(a, b) return a.order < b.order end)
  return {commands = commands}
end

function M:peer(args, live)
  local peer = assert(self.peers[args.terminal], "Pi is not connected")
  assert(peer.instance == args.instance, "Pi conversation changed; inspect workspace_state again")
  if live then assert(system.get_time() - peer.seen < 10, "Pi is disconnected") end
  return peer
end

function M:send(args, caller, action)
  local peer = self:peer(args, true)
  local count = 0
  for _ in pairs(peer.commands) do count = count + 1 end
  assert(count < 16, "Pi command queue is full")
  assert(count < peer.capacity, "Pi control capacity reached; start a new Pi conversation")
  local task = net.random_token()
  peer.order = (peer.order or 0) + 1
  peer.commands[task] = {id = task, action = action, text = args.text, delivery = args.delivery,
    from = caller or "local", order = peer.order}
  return {terminal = args.terminal, instance = peer.instance, task = task, status = "pending"}
end

function M:agent_send(args, caller) return self:send(args, caller, "send") end
function M:agent_interrupt(args, caller) return self:send(args, caller, "interrupt") end

function M:agent_read(args)
  local peer = self:peer(args)
  local connected = system.get_time() - peer.seen < 10
  local result = {terminal = args.terminal, instance = peer.instance, connected = connected,
    status = connected and (peer.busy and "working" or "idle") or "disconnected",
    model = peer.model, thinking = peer.thinking}
  if connected then
    for _, view in ipairs(require("plugins.terminal").open_views()) do
      if view.session_id == args.terminal then result.waiting_for_user = view:close_status().agent_state == "blocked"; break end
    end
  end
  if args.task then
    local task, receipt = peer.tasks[args.task], peer.receipts[args.task]
    assert(task or receipt or peer.commands[args.task], "Task not found")
    result.task = args.task
    result.status = task and task.status or receipt and receipt.status or "pending"
    if not task and receipt and receipt.status == "accepted" and receipt.task ~= args.task then
      result.status, result.related_task = "delivered", receipt.task
    end
    result.result, result.truncated = task and task.result, task and task.truncated
    result.error = task and task.error or receipt and receipt.error
  end
  return result
end

function M:agent_wait(args) return self:agent_read(args) end

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
  assert(not args.project or common.path_equals(args.project, self.project), "Project needs routing through the control server")
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
