-- mod-version:3
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"

---Configuration options for `scale` plugin.
---@class config.plugins.scale
---Toggle auto detection of system scale.
---@field autodetect boolean
---Default scale applied at startup.
---@field default_scale number
---Allow using CTRL + MouseWheel for changing the scale.
---@field use_mousewheel boolean
local scale_factor = 1.1
local current_scale = SCALE
local current_code_scale = SCALE
local configured_scale = tonumber(os.getenv("ANVIL_SCALE"))
local restart_scale = tonumber(os.getenv("ANVIL_SCALE_RESTART"))
local user_scale = restart_scale or configured_scale
local project_zoom_modified = false

local function scale_font_once(font, factor, seen)
  if seen[font] then return end
  seen[font] = true
  if type(font) == "table" then
    for _, child in ipairs(font) do
      scale_font_once(child, factor, seen)
    end
  else
    font:set_size(factor * font:get_size())
  end
end

local function capture_active_textview_caret_y()
  local TextView = package.loaded["core.textview"]
  local view = core.active_view
  if not TextView or not view or not view.extends or not view:extends(TextView) then return nil end
  local line, col = view.buffer:get_selection()
  local y = view:get_position_highlight_geometry(line, col)
  return { view = view, line = line, col = col, y = y }
end

local function restore_active_textview_caret_y(anchor)
  if not anchor or not anchor.view or not anchor.view.buffer then return end
  local view = anchor.view
  local y = view:get_position_highlight_geometry(anchor.line, anchor.col)
  local target = (view.scroll.to.y or view.scroll.y or 0) + (y - anchor.y)
  local max = view:get_scrollable_size() - view.size.y
  target = common.clamp(target, 0, max)
  view.scroll.y = target
  view.scroll.to.y = target
end

---@class plugins.scale
local scale = {}

local function project_default_scale()
  if configured_scale then return common.clamp(configured_scale, 0.7, 6) end
  if config.plugins.scale.autodetect == false
  and type(config.plugins.scale.default_scale) == "number" then
    return common.clamp(config.plugins.scale.default_scale, 0.7, 6)
  end
  return DEFAULT_SCALE
end

local function at_project_default_zoom()
  local default = project_default_scale()
  return math.abs(current_scale - default) < 0.000001
    and math.abs(current_code_scale - default) < 0.000001
end

local function mark_project_zoom_changed()
  project_zoom_modified = not at_project_default_zoom()
end

function scale.set(scale)
  if current_scale == scale then return end
  system.setenv("ANVIL_SCALE_RESTART", scale)

  scale = common.clamp(scale, 0.7, 6)

  local active_caret_y = capture_active_textview_caret_y()

  -- save scroll positions
  local v_scrolls = {}
  local h_scrolls = {}
  for _, view in ipairs(core.root_panel:pane_views()) do
    local n = view:get_scrollable_size()
    if n ~= math.huge and n > view.size.y then
      v_scrolls[view] = view.scroll.y / (n - view.size.y)
    end
    local hn = view:get_h_scrollable_size()
    if hn ~= math.huge and hn > view.size.x then
      h_scrolls[view] = view.scroll.x / (hn - view.size.x)
    end
  end

  local s = scale / current_scale
  current_scale = scale

  SCALE = scale

  style.divider_size                = style.divider_size                * s
  style.scrollbar_size              = style.scrollbar_size              * s
  style.expanded_scrollbar_size     = style.expanded_scrollbar_size     * s
  style.minimum_thumb_size          = style.minimum_thumb_size          * s
  style.scrollbar_resize_edge_guard = style.scrollbar_resize_edge_guard * s
  style.scrollbar_end_padding      = style.scrollbar_end_padding      * s
  if style.gitdiff_width then style.gitdiff_width = style.gitdiff_width * s end
  if style.gitdiff_overview_min_height then style.gitdiff_overview_min_height = style.gitdiff_overview_min_height * s end
  style.contracted_scrollbar_margin = style.contracted_scrollbar_margin * s
  style.expanded_scrollbar_margin   = style.expanded_scrollbar_margin   * s
  style.caret_width                 = style.caret_width                 * s
  style.tab_min_width               = style.tab_min_width               * s
  style.tab_max_width               = style.tab_max_width               * s
  style.tab_width                   = style.tab_width                   * s
  style.padding.x                   = style.padding.x                   * s
  style.padding.y                   = style.padding.y                   * s
  style.margin.tab.top              = style.margin.tab.top              * s
  config.mouse_wheel_scroll         = config.mouse_wheel_scroll         * s

  local scaled_fonts = {}
  for _, name in ipairs {
    "font", "big_font", "icon_font", "icon_big_font",
    "prose_font", "markdown_body_font", "prose_strong_font", "prose_emphasis_font",
    "prose_strong_emphasis_font", "prose_heading_font",
    "prose_heading_emphasis_font",
  } do
    scale_font_once(style[name], s, scaled_fonts)
  end

  local Tabs = package.loaded["core.tabs"]
  if Tabs then
    Tabs._tab_title_font = nil
    Tabs._tab_title_font_base = nil
    Tabs._tab_title_font_size = nil
  end
  local untitled_tabs = package.loaded["plugins.untitled_tabs"]
  if untitled_tabs then
    untitled_tabs._secondary_font = nil
    untitled_tabs._secondary_font_base = nil
    untitled_tabs._secondary_font_size = nil
  end

  -- restore scroll positions
  for view, n in pairs(v_scrolls) do
    view.scroll.y = n * (view:get_scrollable_size() - view.size.y)
    view.scroll.to.y = view.scroll.y
  end
  for view, hn in pairs(h_scrolls) do
    view.scroll.x = hn * (view:get_h_scrollable_size() - view.size.x)
    view.scroll.to.x = view.scroll.x
  end

  restore_active_textview_caret_y(active_caret_y)

  core.redraw = true
end

function scale.set_code(scale)
  if current_code_scale == scale then return end
  system.setenv("ANVIL_SCALE_CODE_RESTART", scale)

  scale = common.clamp(scale, 0.7, 6)

  local active_caret_y = capture_active_textview_caret_y()

  local s = scale / current_code_scale
  current_code_scale = scale

  local scaled_fonts = {}
  for _, name in ipairs {
    "code_font", "terminal_font", "terminal_bold_font",
    "terminal_italic_font", "terminal_bold_italic_font",
  } do
    scale_font_once(style[name], s, scaled_fonts)
  end
  for _, font in pairs(style.syntax_fonts) do
    scale_font_once(font, s, scaled_fonts)
  end

  restore_active_textview_caret_y(active_caret_y)

  core.redraw = true
end

function scale.get()
  return current_scale
end

function scale.reset()
  local reset_code = current_scale == current_code_scale
  scale.set(project_default_scale())
  if reset_code then
    scale.set_code(project_default_scale())
  end
  mark_project_zoom_changed()
end

function scale.increase()
  scale.set(current_scale * scale_factor)
  scale.set_code(current_code_scale * scale_factor)
  mark_project_zoom_changed()
end

function scale.decrease()
  scale.set(current_scale / scale_factor)
  scale.set_code(current_code_scale / scale_factor)
  mark_project_zoom_changed()
end

function scale.get_code()
  return current_code_scale
end

function scale.save_workspace_state()
  if not project_zoom_modified or at_project_default_zoom() then
    project_zoom_modified = false
    return nil
  end
  return { interface = current_scale, code = current_code_scale }
end

function scale.load_workspace_state(state)
  local interface, code
  if type(state) == "table" then
    interface = tonumber(state.interface)
    code = tonumber(state.code) or interface
  elseif type(state) == "number" then
    interface, code = state, state
  end
  local explicit = interface ~= nil
  if explicit then
    interface = common.clamp(interface, 0.7, 6)
    code = common.clamp(code or interface, 0.7, 6)
  else
    interface = project_default_scale()
    code = interface
  end
  scale.set(interface)
  scale.set_code(code)
  project_zoom_modified = explicit and not at_project_default_zoom()
  core.log_quiet(
    "Project Zoom: %s interface=%.4f code=%.4f",
    project_zoom_modified and "restored" or "default",
    current_scale,
    current_code_scale
  )
end

function scale.reset_code()
  scale.set_code(DEFAULT_SCALE)
end

function scale.increase_code()
  scale.set_code(current_code_scale * scale_factor)
end

function scale.decrease_code()
  scale.set_code(current_code_scale / scale_factor)
end

if DEFAULT_SCALE ~= config.plugins.scale.default_scale then
  if type(config.plugins.scale.default_scale) == "number" then
    scale.set(config.plugins.scale.default_scale)
  end
end

local scale_set_by_user = 0
local first_on_apply_scale = user_scale and true or false

-- The config specification used by gui generators
config.plugins.scale.config_spec = {
  name = "Scale",
  {
    label = "Autodetect Scale",
    description = "Keeps the scale equal to display, ignored on startup if ANVIL_SCALE is set.",
    path = "autodetect",
    type = "toggle",
    default = true,
    on_apply = function(enabled)
      if not first_on_apply_scale then
        if not enabled then
          scale.set(config.plugins.scale.default_scale)
          scale.set_code(config.plugins.scale.default_scale)
        else
          scale.set(DEFAULT_SCALE)
          scale.set_code(DEFAULT_SCALE)
        end
      end
    end
  },
  {
    label = "Default Scale",
    description = "The scaling factor applied to anvil when autodetect is not enabled.",
    path = "default_scale",
    type = "number",
    default = DEFAULT_SCALE,
    step = 0.05,
    min = 0.70,
    max = 3.00,
    set_value = function(value)
      scale_set_by_user = value
      return value
    end,
    on_apply = function(value)
      -- Perevents overwriting the scale set by user in ANVIL_SCALE
      if first_on_apply_scale then
        first_on_apply_scale = false
        if scale_set_by_user == 0 then return end
      end
      if config.plugins.scale.autodetect then return end
      if value ~= current_scale then
        scale.set(value)
        scale.set_code(value)
      end
    end
  },
  {
    label = "Use MouseWheel",
    description = "Allow using CTRL + MouseWheel for changing the scale.",
    path = "use_mousewheel",
    type = "toggle",
    default = true,
    on_apply = function(enabled)
      if enabled then
        keymap.add {
          ["ctrl+wheelup"] = "editor:zoom_in",
          ["ctrl+wheeldown"] = "editor:zoom_out",
          ["ctrl+shift+wheelup"] = "editor:zoom_in",
          ["ctrl+shift+wheeldown"] = "editor:zoom_out"
        }
      else
        keymap.unbind("ctrl+wheelup", "editor:zoom_in")
        keymap.unbind("ctrl+wheeldown", "editor:zoom_out")
        keymap.unbind("ctrl+shift+wheelup", "editor:zoom_in")
        keymap.unbind("ctrl+shift+wheeldown", "editor:zoom_out")
      end
    end
  }
}


command.add(nil, {
  ["editor:zoom_reset"] = command.palette(function() scale.reset() end),
  ["editor:zoom_out"] = command.palette(function() scale.decrease() end),
  ["editor:zoom_in"] = command.palette(function() scale.increase() end)
})

keymap.unbind("ctrl+shift+0", "editor:zoom_reset")
keymap.unbind("ctrl+shift+-", "editor:zoom_out")
keymap.unbind("ctrl+shift+=", "editor:zoom_in")
keymap.unbind("ctrl+shift+wheelup", "editor:zoom_in")
keymap.unbind("ctrl+shift+wheeldown", "editor:zoom_out")

keymap.add {
  ["ctrl+shift+0"] = "editor:zoom_reset"
}

if config.plugins.scale.use_mousewheel then
  keymap.add {
    ["ctrl+wheelup"] = "editor:zoom_in",
    ["ctrl+wheeldown"] = "editor:zoom_out",
    ["ctrl+shift+wheelup"] = "editor:zoom_in",
    ["ctrl+shift+wheeldown"] = "editor:zoom_out"
  }
end

-- Apply previous scale on restart set on ANVIL_SCALE_RESTART and
-- ANVIL_SCALE_CODE_RESTART or custom ANVIL_SCALE if set by user
if user_scale then
  -- to prevent issues on restart we defer it
  core.add_thread(function()
    scale.set(user_scale)
    scale.set_code(
      tonumber(os.getenv("ANVIL_SCALE_CODE_RESTART")) or user_scale
    )
  end)
end


return scale
