-- mod-version:3
-- Temporary diagnostics for unexpected scale/zoom changes.

local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"

local LOG_PATH = USERDIR .. PATHSEP .. "scale-debug.log"

local function append_log(message)
  local fp = io.open(LOG_PATH, "a")
  if not fp then return end
  fp:write(os.date("!%Y-%m-%dT%H:%M:%SZ"), " ", message, "\n")
  fp:close()
end

local function code_font_size()
  local ok, size = pcall(function() return style.code_font:get_size() end)
  return ok and size or nil
end

local function ui_font_size()
  local ok, size = pcall(function() return style.font:get_size() end)
  return ok and size or nil
end

local function log_state(reason, extra)
  append_log(string.format(
    "%s SCALE=%s DEFAULT_SCALE=%s ui_font=%s code_font=%s env_scale=%s env_code=%s%s",
    reason,
    tostring(SCALE),
    tostring(DEFAULT_SCALE),
    tostring(ui_font_size()),
    tostring(code_font_size()),
    tostring(os.getenv("ANVIL_SCALE_RESTART") or os.getenv("ANVIL_SCALE")),
    tostring(os.getenv("ANVIL_SCALE_CODE_RESTART")),
    extra and (" " .. extra) or ""
  ))
end

local function args_string(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[i] = tostring(select(i, ...))
  end
  return table.concat(parts, ",")
end

local function stack_summary()
  local parts = {}
  for level = 3, 10 do
    local info = debug.getinfo(level, "nSl")
    if not info then break end
    parts[#parts + 1] = string.format("%s:%s:%s", tostring(info.short_src), tostring(info.currentline), tostring(info.name or "?"))
  end
  return table.concat(parts, " <- ")
end

log_state("plugin-load")

local scale = package.loaded["plugins.scale"]
if scale and not scale.__debug_logged then
  scale.__debug_logged = true
  for _, name in ipairs({ "set", "set_code", "reset", "reset_code", "increase", "decrease", "increase_code", "decrease_code" }) do
    local original = scale[name]
    if type(original) == "function" then
      scale[name] = function(...)
        log_state("before scale." .. name, "args=" .. tostring(select(1, ...)) .. " stack=" .. stack_summary())
        local results = table.pack(pcall(original, ...))
        log_state("after scale." .. name, "ok=" .. tostring(results[1]))
        if not results[1] then error(results[2]) end
        return table.unpack(results, 2, results.n)
      end
    end
  end
end

if not system.__scale_debug_original_poll_event then
  system.__scale_debug_original_poll_event = system.poll_event
  system.poll_event = function()
    while true do
      local type, a, b, c, d = system.__scale_debug_original_poll_event()
      if not type then return nil end
      if type == "scalechanged" then
        local scale = tonumber(a)
        if not scale or scale <= 0 then
          log_state("ignored invalid scalechanged", "args=" .. args_string(a, b, c, d))
        else
          log_state("event scalechanged", "args=" .. args_string(a, b, c, d))
          return type, a, b, c, d
        end
      else
        return type, a, b, c, d
      end
    end
  end
end

if not core.__scale_debug_event_logged then
  core.__scale_debug_event_logged = true
  local core_on_event = core.on_event
  function core.on_event(type, ...)
    if type == "mousewheel" and (keymap.modkeys.ctrl or keymap.modkeys.shift) then
      log_state("event mousewheel-mod", "ctrl=" .. tostring(keymap.modkeys.ctrl) .. " shift=" .. tostring(keymap.modkeys.shift) .. " args=" .. args_string(...))
    end
    return core_on_event(type, ...)
  end
end

if not command.__scale_debug_perform_logged then
  command.__scale_debug_perform_logged = true
  local command_perform = command.perform
  function command.perform(name, ...)
    if type(name) == "string" and name:match("^editor:zoom%-") then
      log_state("command " .. name, "stack=" .. stack_summary())
    end
    return command_perform(name, ...)
  end
end

return { log_path = LOG_PATH }
