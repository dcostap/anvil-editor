local common = require "core.common"
local style = require "core.style"
local keymap = require "core.keymap"
local ui = require "core.ui"
local surface = require "core.ui.surface"
local layout = require "core.ui.layout"

-- Key caps for a key or a chord, such as "ctrl+shift+p". It takes no input.
-- `command` shows the user's first binding of a command instead, and nothing while the command has none.
-- Prefer `command`: the user can change each binding.
local Kbd = layout.Node:extend()

local px = layout.px

local NAMES = { ["return"] = "Enter", escape = "Esc", pageup = "PgUp", pagedown = "PgDn", delete = "Del" }

---@param options { keys: string?, command: string? }
function Kbd:new(options)
  Kbd.super.new(self, options)
  self.keys = options.keys
  self.command = options.command
  self.parts = {}
end

-- The caps of the current keys. The parts change only when the keys change.
local function parts(self)
  local bindings = self.command and keymap.get_bindings(self.command)
  local keys = (self.command and (bindings and bindings[1])) or (not self.command and self.keys) or ""
  if keys ~= self.parsed then
    self.parsed = keys
    local list = self.parts
    for i = #list, 1, -1 do list[i] = nil end
    for part in keys:gmatch("[^+]+") do
      list[#list + 1] = NAMES[part] or (#part == 1 and part:upper() or part:sub(1, 1):upper() .. part:sub(2))
    end
    if keys:sub(-1) == "+" and #keys > 1 then list[#list + 1] = "+" end
  end
  return self.parts
end

local function cap_height()
  return ui.role_font("meta"):get_height() + px(4)
end

local function cap_width(part)
  return math.max(cap_height(), math.ceil(ui.role_font("meta"):get_width(part)) + 2 * px(5))
end

function Kbd:content_width()
  local list, w = parts(self), 0
  for i, part in ipairs(list) do w = w + cap_width(part) + (i > 1 and px(3) or 0) end
  return w
end

function Kbd:content_height()
  return #parts(self) > 0 and cap_height() or 0
end

function Kbd:draw_node()
  local font, h = ui.role_font("meta"), cap_height()
  local x, y = self.x, self.y + math.floor((self.h - h) / 2)
  local r = px(4)
  for _, part in ipairs(parts(self)) do
    local w = cap_width(part)
    surface.draw("kbd", x, y, w, h, r)
    common.draw_text(font, style.dialog_text, part, "center", x, y, w, h)
    x = x + w + px(3)
  end
end

return Kbd
