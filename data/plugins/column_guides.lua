-- mod-version:3
-- priority:110
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local style = require "core.style"
local DocView = require "core.docview"

---Configuration options for `column_guides` plugin.
---@class config.plugins.column_guides
---Disable or enable drawing of column guides.
---@field enabled boolean
---Character columns where guides are drawn.
---@field columns table<integer,integer>
config.plugins.column_guides = common.merge({
  enabled = true,
  columns = { 100, 150 },
  config_spec = {
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
  },
}, config.plugins.column_guides)

local function guide_color()
  return style.whitespace
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

local function wrapped_line_count(dv, line)
  if not dv.wrapped_settings then return 1 end

  local total = #(dv.wrapped_lines or {}) / 2
  local start_idx = (dv.wrapped_line_to_idx or {})[line] or total
  local next_idx = (dv.wrapped_line_to_idx or {})[line + 1] or (total + 1)
  return math.max(1, next_idx - start_idx)
end

local function draw_column_guides(dv, x, y, height)
  local conf = config.plugins.column_guides
  if type(conf) ~= "table" or conf.enabled == false then return end

  local font = dv:get_font()
  local char_w = font:get_width("n")
  local line_w = math.max(1, math.floor(SCALE))
  local color = guide_color()

  for column in guide_columns(conf) do
    local gx = x + char_w * column - math.floor(line_w / 2)
    renderer.draw_rect(gx, y, line_w, height, color)
  end
end

local old_draw_line_body = DocView.draw_line_body
function DocView:draw_line_body(line, x, y)
  -- Draw after line backgrounds, including the current-line indicator, but
  -- before the ordinary line body so selections, search matches, text, hints,
  -- and carets always appear above the guides.
  draw_column_guides(self, x, y, self:get_line_height() * wrapped_line_count(self, line))

  return old_draw_line_body(self, line, x, y)
end

command.add(nil, {
  ["column-guides:toggle"] = function()
    config.plugins.column_guides.enabled = not config.plugins.column_guides.enabled
  end,
})
