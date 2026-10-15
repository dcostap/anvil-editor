-- The Color Theme is one setting for every Project and the Sidebar. USERDIR's user_settings.lua keeps it.
local color_theme = {}

-- Users see the colors.default module as "dark".
local DEFAULT_NAME, DEFAULT_MODULE = "dark", "default"

---The name users see for a saved or chosen Color Theme.
---@param name string?
---@return string
function color_theme.name(name)
  if name == nil or name == "" or name == DEFAULT_MODULE then return DEFAULT_NAME end
  return name
end

---The colors module that defines a Color Theme.
---@param name string?
---@return string
function color_theme.module_name(name)
  name = color_theme.name(name)
  return "colors." .. (name == DEFAULT_NAME and DEFAULT_MODULE or name)
end

---The saved Color Theme name. Another process may have saved it.
---@return string
function color_theme.saved_name()
  local ok, settings = pcall(dofile, USERDIR .. "/user_settings.lua")
  local config = ok and type(settings) == "table" and settings.config
  return color_theme.name(type(config) == "table" and config.theme or nil)
end

---Loads a Color Theme into core.style outside the editor: the theme over colors.default, then its saved Theme
---Editor edits. The editor uses core.reload_module, which also maps syntax colours.
---@param name string?
function color_theme.load_style(name)
  local theme_edits = require "core.theme_edits"
  name = color_theme.name(name)
  package.loaded["colors.default"] = nil
  local style = require "colors.default"
  local module = color_theme.module_name(name)
  if module ~= "colors.default" then
    package.loaded[module] = nil
    require(module)
  end
  local draft, err = theme_edits.load(name)
  if err then error(err) end
  theme_edits.apply(style, theme_edits.capture(style), draft)
end

-- The shell draws the Window controls, and the Project area while no Project frame covers it. Each shell
-- colour name maps to its style key.
local SHELL_COLORS = {
  {"background", "background"}, {"button", "background2"},
  {"text", "text"}, {"inactive_text", "dim"},
  {"hover", "titlebar_control_hover"}, {"pressed", "titlebar_control_pressed"},
  {"close_hover", "titlebar_close_hover"}, {"close_pressed", "titlebar_close_pressed"},
  {"close_text", "titlebar_close_text"},
}

---The colours the shell needs from a style, for system.set_shell_colors.
---@param style table
---@return table<string, table>
function color_theme.shell_colors(style)
  local colors = {}
  for _, key in ipairs(SHELL_COLORS) do
    local color = style[key[2]]
    colors[key[1]] = {color[1], color[2], color[3], color[4]}
  end
  return colors
end

---Whether a style still has the shell colours that were sent.
---@param style table
---@param sent table<string, table>?
---@return boolean
function color_theme.same_shell_colors(style, sent)
  if not sent then return false end
  for _, key in ipairs(SHELL_COLORS) do
    local color, previous = style[key[2]], sent[key[1]]
    for i = 1, 4 do
      if color[i] ~= previous[i] then return false end
    end
  end
  return true
end

return color_theme
