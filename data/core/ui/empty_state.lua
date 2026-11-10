local common = require "core.common"
local style = require "core.style"
local ui = require "core.ui"
local surface = require "core.ui.surface"
local layout = require "core.ui.layout"

-- What a list or a page shows when it has nothing to show: an icon, a title, a description and optional
-- buttons, all centred. For example: `EmptyState { icon = ui.icons.database, title = "No databases",
-- description = "Add a server to start.", actions = { Button { label = "Add Server" } } }`.
-- It is a Column, so it takes the options of a Column and a node.
local EmptyState = layout.Column:extend()

local px = layout.px

-- The icon on a raised tile.
local Tile = layout.Node:extend()

function Tile:new(options)
  Tile.super.new(self, options)
  self.icon = options.icon
end

function Tile:content_width() return px(40) end
function Tile:content_height() return px(40) end

function Tile:draw_node()
  surface.draw("raised", self.x, self.y, self.w, self.h, px(10))
  common.draw_text(ui.icon_font(), style.dialog_text_muted, self.icon, "center", self.x, self.y, self.w, self.h)
end

---@param options { icon: string?, title: string, description: string?, actions: table[]? }
function EmptyState:new(options)
  local text = layout.Column { gap = 4, layout.Text { text = options.title or "", role = "strong", align = "center" } }
  if options.description then
    text.children[2] = layout.Text { text = options.description, role = "description", align = "center" }
  end
  local column = { gap = 12, padding = options.padding or { 24, 16 } }
  for key, value in pairs(options) do
    if type(key) == "string" and column[key] == nil and key ~= "actions" then column[key] = value end
  end
  if options.icon then column[#column + 1] = layout.Row { justify = "center", Tile { icon = options.icon } } end
  column[#column + 1] = text
  if options.actions and #options.actions > 0 then
    local row = layout.Row { justify = "center" }
    for i, action in ipairs(options.actions) do row.children[i] = action end
    column[#column + 1] = row
  end
  EmptyState.super.new(self, column)
end

return EmptyState
