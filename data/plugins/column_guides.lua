-- mod-version:3
-- priority:110
local core = require "core"
local command = require "core.command"
local config = require "core.config"
local file_context = require "core.file_context"
local style = require "core.style"
local DocView = require "core.docview"

---Configuration options for `column_guides` plugin.
---@class config.plugins.column_guides
---Disable or enable drawing of column guides.
---@field enabled boolean
---Character columns where guides are drawn.
---@field columns table<integer,integer>
config.plugins.column_guides.config_spec = {
    name = "Column Guides",
    {
      label = "Enabled",
      description = "Disable or enable drawing of column guides.",
      path = "enabled",
      type = "toggle",
      default = true,
    },
    {
      label = "Guide Columns",
      description = "Character columns where guides are drawn.",
      path = "columns",
      type = "list_strings",
      default = { "100", "150" },
      get_value = function(columns)
        local values = {}
        if type(columns) == "table" then
          for _, column in ipairs(columns) do
            values[#values + 1] = tostring(column)
          end
        end
        return #values > 0 and values or { "100", "150" }
      end,
      set_value = function(columns)
        local values = {}
        for _, column in ipairs(columns or {}) do
          local number = tonumber(column)
          if number and number > 0 then
            values[#values + 1] = math.floor(number)
          end
        end
        return values
      end,
    },
  }

local function guide_color()
  return style.line_wrapping_guide
end

local function guide_columns(conf)
  local columns = type(conf.columns) == "table" and conf.columns or {}
  local i = 0
  return function()
    while true do
      i = i + 1
      local column = columns[i]
      if column == nil then return nil end
      column = tonumber(column)
      if column and column > 0 then
        return math.floor(column)
      end
    end
  end
end

local function draw_column_guides(dv)
  local conf = config.plugins.column_guides
  if type(conf) ~= "table" or conf.enabled == false then return end
  if not file_context.is_editor_view(dv) then return end

  local font = dv:get_font()
  local char_w = font:get_width("n")
  local line_w = math.max(1, math.floor(SCALE))
  local gw = dv:get_gutter_width()
  local x = dv:get_line_screen_position(1)
  local color = guide_color()

  core.push_clip_rect(dv.position.x + gw, dv.position.y, dv.size.x - gw, dv.size.y)
  for column in guide_columns(conf) do
    local gx = x + char_w * column - math.floor(line_w / 2)
    renderer.draw_rect(gx, dv.position.y, line_w, dv.size.y, color)
  end
  core.pop_clip_rect()
end

local old_draw_current_line_highlights = DocView.draw_current_line_highlights
function DocView:draw_current_line_highlights(...)
  old_draw_current_line_highlights(self, ...)

  -- Draw one uninterrupted viewport-height guide before line bodies are drawn.
  -- This keeps the guide visible past EOF and below text, selections, search
  -- matches, hints, and carets while remaining above current-line highlights.
  draw_column_guides(self)
end

command.add_toggle("column-guides:toggle", {
  get = function()
    return config.plugins.column_guides.enabled
  end,
  set = function(enabled)
    config.plugins.column_guides.enabled = enabled
  end,
})
