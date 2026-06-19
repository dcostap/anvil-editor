local core = require "core"
local style = require "core.style"

---Transient user feedback for navigation commands that hit a boundary.
---This intentionally does not use core.warn(), because reaching a navigation
---boundary is expected UX state and should not create a warning log/backtrace.
local feedback = {}

local direction_names = {
  [1] = "next",
  [-1] = "previous",
  next = "next",
  previous = "previous",
  forward = "next",
  backward = "previous",
}

local function show_warning(text)
  text = tostring(text or "")
  if text == "" then return false end
  if core.status_bar and type(core.status_bar.show_message) == "function" then
    core.status_bar:show_message("!", style.warn, text)
  elseif core.log_quiet then
    core.log_quiet("Navigation feedback: %s", text)
  end
  return false, text
end

---Show a warning-style transient message without logging a warning.
---@param text string
---@return false,string
function feedback.warning(text)
  return show_warning(text)
end

---Show feedback that no target exists for a directional navigation command.
---@param direction integer|string Positive/"next"/"forward" or negative/"previous"/"backward".
---@param target string Singular target label, such as "Git change" or "symbol".
---@return false,string
function feedback.no_more(direction, target)
  local name = direction_names[direction]
  if not name and type(direction) == "number" then
    name = direction < 0 and "previous" or "next"
  end
  name = name or tostring(direction or "next")
  target = target or "target"
  return show_warning(string.format("No %s %s", name, target))
end

---Show feedback that there are no targets of this kind at all.
---@param target string Plural or collective target label, such as "Git changes".
---@return false,string
function feedback.none(target)
  return show_warning(string.format("No %s", target or "targets"))
end

return feedback
