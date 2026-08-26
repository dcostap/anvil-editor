local core = require "core"

---Functions to register and handle commands.
---@class core.command
local command = {}

---A predicate function accepts arguments from `command.perform()` and evaluates to a boolean. </br>
---If the function returns true, then the function associated with the command is executed.
---
---The predicate function can also return other values after the boolean, which will
---be passed into the function associated with the command.
---@alias core.command.predicate_function fun(...: any): boolean, ...

---A predicate is a string, an Object or a function, that is used to determine
---whether a command should be executed.
---
---If the predicate is a string, it is resolved into an `Object` via `require()`
---and checked against the active view with `Object:extends()`. </br>
---For example, `"core.textview"` will match any view that inherits from `TextView`. </br>
---A `!` can be appended to the predicate to strictly match the current view via `Object:is()`,
---instead of matching any view that inherits the predicate.
---
---If the predicate is a table, it is checked against the active view with `Object:extends()`.
---Strict matching via `Object:is()` is not available.
---
---If the predicate is a function, it must behave like a predicate function.
---@see core.command.predicate_function
---@alias core.command.predicate string|core.object|core.command.predicate_function

---A command identifier contains its owning View, feature, or domain prefix and action.
---Use `core` when no more specific owner exists.
---Both parts use lowercase snake_case and are separated by a colon.
---@alias core.command.command_name string

---The predicate and its associated function.
---@class core.command.command
---@field predicate core.command.predicate_function
---@field perform fun(...: any)
---@field status? fun(): any
---@field metadata? core.command.metadata

---@class core.command.metadata
---@field keywords? string[]
---@field supports_placement? boolean
---@field palette? boolean
---@field opens_view? boolean

---@class core.command.registration
---@field perform fun(...: any)
---@field metadata core.command.metadata

---@type { [string]: core.command.command }
command.map = {}

local function validate_name(name)
  assert(
    type(name) == "string"
      and name:match("^[a-z][a-z0-9_]*:[a-z][a-z0-9_]*$"),
    string.format("invalid command identifier %q; expected prefix:snake_case_action", tostring(name))
  )
end

local function validate_metadata(metadata)
  assert(not (metadata and (metadata.title or metadata.description)),
    "commands use their identifier and keywords, not titles or descriptions")
end

local invocation_context

---@type core.command.predicate_function
local always_true = function() return true end

local function pack(...)
  return { n = select("#", ...), ... }
end

local function is_textview(value)
  return type(value) == "table"
    and type(value.with_selection_state) == "function"
    and value.buffer ~= nil
end

local function active_textview()
  local view = core.active_view
  if is_textview(view) then return view end
end

local function with_view_selection(view, fn, ...)
  if is_textview(view) then
    return view:with_selection_state(fn, ...)
  end
  return fn(...)
end

local function first_textview_arg(args, n)
  for i = 1, n do
    if is_textview(args[i]) then return args[i] end
  end
end

local function perf_start()
  if core.perf_frame_stats then return system.get_time() end
  local perf = package.loaded["core.perf"]
  if perf and perf.is_recording and perf.is_recording() then return system.get_time() end
end

local function perf_detail_add(key, amount)
  local perf = package.loaded["core.perf"]
  if perf and perf.add_detail then perf.add_detail(key, amount or 1) end
end

local function perf_frame_add(key, amount)
  local stats = core.perf_frame_stats
  if stats then stats[key] = (stats[key] or 0) + (amount or 1) end
end

local function perf_command_time(name, kind, start_time)
  if not start_time then return end
  local elapsed = (system.get_time() - start_time) * 1000
  name = tostring(name or "<unknown>")
  perf_detail_add("command_" .. kind .. "_ms:" .. name, elapsed)
  perf_frame_add("command_" .. kind .. "_ms", elapsed)
  if kind == "total" then
    perf_detail_add("command_calls:" .. name, 1)
    perf_frame_add("command_calls", 1)
    local stats = core.perf_frame_stats
    if stats and elapsed > (stats.slowest_command_ms or 0) then
      stats.slowest_command_ms = elapsed
      stats.slowest_command_name = name
    end
  end
end


---This function takes in a predicate and produces a predicate function
---that is internally used to dispatch and execute commands.
---
---This function should not be called manually.
---@see core.command.predicate
---@param predicate core.command.predicate|nil If nil, the predicate always evaluates to true.
---@return core.command.predicate_function
function command.generate_predicate(predicate)
  predicate = predicate or always_true
  local strict = false
  if type(predicate) == "string" then
    if predicate:match("!$") then
      strict = true
      predicate = predicate:gsub("!$", "")
    end
    predicate = require(predicate)
  end
  if type(predicate) == "table" then
    local class = predicate
    if not strict then
      predicate = function(...)
        local view = core.active_view
        return view ~= nil and view.extends and view:extends(class) or false, view, ...
      end
    else
      predicate = function(...)
        local view = core.active_view
        return view ~= nil and view.is and view:is(class) or false, view, ...
      end
    end
  end
  ---@cast predicate core.command.predicate_function
  local raw_predicate = predicate
  return function(...)
    local args = pack(...)
    return with_view_selection(
      first_textview_arg(args, args.n) or active_textview(),
      raw_predicate,
      table.unpack(args, 1, args.n)
    )
  end
end


---Adds commands to the map.
---
---The function accepts a table containing a list of commands
---and their functions. </br>
---If a command already exists, it will be replaced.
---@see core.command.predicate
---@see core.command.command_name
---@param predicate? core.command.predicate
---@param map { [core.command.command_name]: fun(...: any)|core.command.registration }
function command.add(predicate, map)
  predicate = command.generate_predicate(predicate)
  for name, registration in pairs(map) do
    validate_name(name)
    local fn = registration
    local inline_metadata
    if type(registration) == "table" then
      fn = registration.perform
      inline_metadata = registration.metadata
      validate_metadata(inline_metadata)
    end
    assert(type(fn) == "function", "command registration requires a function")
    local existing = command.map[name]
    if existing then
      core.log_quiet("Replacing existing command \"%s\"", name)
    end
    local metadata = existing and existing.metadata or nil
    if inline_metadata then
      metadata = {}
      for key, value in pairs(existing and existing.metadata or {}) do metadata[key] = value end
      for key, value in pairs(inline_metadata) do metadata[key] = value end
    end
    command.map[name] = {
      predicate = predicate,
      perform = fn,
      status = existing and existing.status or nil,
      metadata = metadata,
    }
  end
end

---Mark a command registration as a user-facing Command Palette action.
---@param fn fun(...: any)
---@param metadata? core.command.metadata
---@return core.command.registration
function command.palette(fn, metadata)
  validate_metadata(metadata)
  local values = { palette = true }
  for key, value in pairs(metadata or {}) do values[key] = value end
  return { perform = fn, metadata = values }
end

---Attach a dynamic status value to a command for command-palette display.
---Boolean values are rendered as ON/OFF by `command.get_status_label()`.
---@param name core.command.command_name
---@param status fun(): any
function command.set_status(name, status)
  if command.map[name] then
    command.map[name].status = status
  end
end

---Attach user-facing Command Palette metadata to a command.
---@param name core.command.command_name
---@param metadata core.command.metadata
function command.set_metadata(name, metadata)
  if not command.map[name] then return end
  validate_metadata(metadata)
  local merged = {}
  for key, value in pairs(command.map[name].metadata or {}) do merged[key] = value end
  for key, value in pairs(metadata or {}) do merged[key] = value end
  command.map[name].metadata = merged
end

---@param name core.command.command_name
---@return core.command.metadata|nil
function command.get_metadata(name)
  local cmd = command.map[name]
  return cmd and cmd.metadata or nil
end

---Return context supplied by the surface that invoked the current command.
---@return table|nil
function command.get_invocation_context()
  return invocation_context
end

---Returns a command's dynamic status value, if one is registered.
---@param name core.command.command_name
---@param ... any Optional context forwarded to the status callback.
---@return any
function command.get_status(name, ...)
  local cmd = command.map[name]
  if not (cmd and cmd.status) then return nil end
  local ok, value = core.try(cmd.status, ...)
  if not ok then return nil end
  return value
end

---Returns the command-palette label fragment for a command's status.
---@param name core.command.command_name
---@param ... any Optional context forwarded to the status callback.
---@return string|nil
function command.get_status_label(name, ...)
  local value = command.get_status(name, ...)
  if value == nil or value == "" then return nil end
  if type(value) == "boolean" then
    value = value and "ON" or "OFF"
  end
  return string.format("[Currently: %s]", tostring(value))
end

---Register a boolean state command as a single toggle command.
---Calling the command without a boolean flips the current state. Calling it
---with a boolean forces that state, which gives programmatic callers an
---explicit set operation without adding separate user-facing commands.
---@class core.command.toggle_options
---@field predicate? core.command.predicate
---@field get fun(...: any): boolean
---@field set fun(enabled: boolean, ...: any)
---@field palette? boolean
---@field metadata? core.command.metadata

---@param name core.command.command_name
---@param options core.command.toggle_options
function command.add_toggle(name, options)
  local function unpack_without(args, omitted)
    local values = { n = args.n - 1 }
    for i = 1, args.n do
      if i < omitted then
        values[i] = args[i]
      elseif i > omitted then
        values[i - 1] = args[i]
      end
    end
    return table.unpack(values, 1, values.n)
  end

  command.add(options.predicate, {
    [name] = function(...)
      local args = pack(...)
      local explicit = type(args[1]) == "boolean" and 1
        or type(args[args.n]) == "boolean" and args.n
        or nil
      if explicit then
        options.set(args[explicit], unpack_without(args, explicit))
      else
        options.set(not options.get(table.unpack(args, 1, args.n)), table.unpack(args, 1, args.n))
      end
    end,
  })
  command.set_status(name, options.get)
  if options.palette or options.metadata then
    local metadata = options.metadata or {}
    if options.palette then metadata.palette = true end
    command.set_metadata(name, metadata)
  end
end


---Returns all the commands that can be executed (their predicates evaluate to true).
---@return core.command.command_name[]
function command.get_all_valid()
  local res = {}
  local memoized_predicates = {}
  for name, cmd in pairs(command.map) do
    if memoized_predicates[cmd.predicate] == nil then
      memoized_predicates[cmd.predicate] = cmd.predicate()
    end
    if memoized_predicates[cmd.predicate] then
      table.insert(res, name)
    end
  end
  return res
end

---Checks whether a command can be executed (its predicate evaluates to true).
---@param name core.command.command_name
---@param ... any
---@return boolean
function command.is_valid(name, ...)
  return command.map[name] and command.map[name].predicate(...)
end

local function perform(name, ...)
  local command_start = perf_start()
  local cmd = command.map[name]
  if not cmd then return false end
  local predicate_start = perf_start()
  local res = pack(cmd.predicate(...))
  perf_command_time(name, "predicate", predicate_start)
  local valid = res[1]
  if valid then
    local args, n
    if res.n > 1 then
      -- send values returned from predicate
      args, n = { n = res.n - 1 }, res.n - 1
      for i = 1, n do args[i] = res[i + 1] end
    else
      -- send original parameters
      args, n = pack(...), select("#", ...)
    end
    local body_start = perf_start()
    core.log_quiet(
      "Command: name=%s active=%s event=%s",
      tostring(name), tostring(core.active_view), core.current_event_context or "none"
    )
    local result = with_view_selection(first_textview_arg(args, n) or active_textview(), function()
      cmd.perform(table.unpack(args, 1, n))
      return true
    end)
    perf_command_time(name, "body", body_start)
    perf_command_time(name, "total", command_start)
    return result
  end
  perf_command_time(name, "total", command_start)
  return false
end


---Performs a command.
---
---The arguments passed into this function are forwarded to the predicate function. </br>
---If the predicate function returns more than 1 value, the other values are passed
---to the command.
---
---Otherwise, the arguments passed into this function are passed directly
---to the command.
---@see core.command.predicate
---@see core.command.predicate_function
---@param name core.command.command_name
---@param ... any
---@return boolean # true if the command is performed successfully.
function command.perform(name, ...)
  local ok, res = core.try(perform, name, ...)
  return not ok or res
end

---Perform a command with source and placement context.
---@param name core.command.command_name
---@param context table
---@param ... any
---@return boolean
function command.perform_with_context(name, context, ...)
  local previous = invocation_context
  invocation_context = context
  local result = table.pack(pcall(command.perform, name, ...))
  invocation_context = previous
  if not result[1] then error(result[2], 0) end
  return table.unpack(result, 2, result.n)
end


---Inserts the default commands for Anvil into the map.
function command.add_defaults()
  local reg = {
    "core", "root", "command", "text", "findreplace",
    "files", "dialog", "log", "statusbar", "image", "markdown", "language",
    "navigation"
  }
  for _, name in ipairs(reg) do
    require("core.commands." .. name)
  end
end


return command
