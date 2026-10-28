-- mod-version:3
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local zoom = require "core.zoom"

---Configuration options for `scale` plugin.
---@class config.plugins.scale
---Toggle auto detection of system scale.
---@field autodetect boolean
---Default scale applied at startup.
---@field default_scale number
---Allow using CTRL + MouseWheel for changing the scale.
---@field use_mousewheel boolean
local MIN_SCALE = 0.25
local MAX_SCALE = 6
local current_scale = SCALE
local current_code_scale = SCALE
local configured_scale = tonumber(os.getenv("ANVIL_SCALE"))
local base_font_size = style.font:get_size() / SCALE

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

-- Zoom keeps the active caret at the center of the viewport, as far as the
-- scroll range allows.
local function capture_active_textview_center()
  local TextView = package.loaded["core.textview"]
  local view = core.active_view
  if not TextView or not view or not view.extends or not view:extends(TextView) then return nil end
  return view:with_selection_state(function()
    return { view = view, center = view:capture_caret_center() }
  end)
end

local function restore_active_textview_center(anchor)
  if not anchor or not anchor.view or not anchor.view.buffer then return end
  local view = anchor.view
  view:with_selection_state(function()
    -- Publish visible geometry before restoring the center. A large Markdown
    -- buffer can still rebuild its offscreen wrapped layout in the background.
    view:invalidate_measurement_dependent_layout("zoom")
    view:restore_viewport_center(anchor.center)
    if anchor.center then
      core.log_quiet("Zoom center: %s:%d:%d row_fraction=%.3f scroll_y=%.1f",
        view.buffer:get_name(), anchor.center.line, anchor.center.col,
        anchor.center.fraction, view.scroll.y)
    end
  end)
end

---@class plugins.scale
local scale = {}

local function base_scale()
  if configured_scale then return common.clamp(configured_scale, MIN_SCALE, MAX_SCALE) end
  if config.plugins.scale.autodetect == false
  and type(config.plugins.scale.default_scale) == "number" then
    return common.clamp(config.plugins.scale.default_scale, MIN_SCALE, MAX_SCALE)
  end
  return DEFAULT_SCALE
end

-- A Zoom step adds one point near the default size. A large size adds about the same fraction as one point at
-- the default size, so a large Zoom does not need more and more steps.
local function font_step(size)
  return math.max(1, common.round(size / base_font_size))
end

-- Zoom out goes back along the sizes that Zoom in goes through.
local function next_font_size(size, direction)
  if direction > 0 then return size + font_step(size) end
  local previous = size - 1
  while previous > 1 and previous + font_step(previous) > size do previous = previous - 1 end
  return previous
end

local function zoomed_scale(current, direction)
  local default = base_scale()
  local current_size = common.round(current / default * base_font_size)
  local min_size = math.ceil(MIN_SCALE / default * base_font_size)
  local max_size = math.floor(MAX_SCALE / default * base_font_size)
  local target_size = common.clamp(next_font_size(current_size, direction), min_size, max_size)
  local target = common.clamp(
    default * target_size / base_font_size, MIN_SCALE, MAX_SCALE
  )
  -- Keep generated Zoom values stable after Lua serialization.
  return math.floor(target * 1000000000000 + 0.5) / 1000000000000
end

local function zoom_ratio(scale)
  return math.floor(scale / base_scale() * 1000000000000 + 0.5) / 1000000000000
end

local function logical_font_size(scale)
  return common.round(scale / base_scale() * base_font_size)
end

local function show_zoom_message()
  if core.status_bar and core.status_bar.show_message then
    core.status_bar:show_message(
      "i", style.accent, string.format("Font size: %d", logical_font_size(current_code_scale))
    )
  end
end

-- The shell sends the Zoom to the other Projects and the Sidebar. New processes read the saved Zoom.
local function save_zoom()
  local interface, code = zoom_ratio(current_scale), zoom_ratio(current_code_scale)
  zoom.save(interface, code)
  local shared = system.zoom_saved(interface, code)
  core.log_quiet("Zoom saved: interface=%.4f code=%.4f shared=%s", interface, code, tostring(shared))
end

local function apply_zoom(reason, interface, code)
  local base = base_scale()
  scale.set(common.clamp(base * interface, MIN_SCALE, MAX_SCALE))
  scale.set_code(common.clamp(base * code, MIN_SCALE, MAX_SCALE))
  core.log_quiet("Zoom applied (%s): interface=%.4f code=%.4f base=%.4f", reason, interface, code, base)
end

function scale.set(scale)
  if current_scale == scale then return end

  scale = common.clamp(scale, MIN_SCALE, MAX_SCALE)

  local active_center = capture_active_textview_center()

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
  style.scrollbar_overview_min_height = style.scrollbar_overview_min_height * s
  style.scrollbar_resize_edge_guard = style.scrollbar_resize_edge_guard * s
  style.scrollbar_end_padding      = style.scrollbar_end_padding      * s
  if style.gitdiff_width then style.gitdiff_width = style.gitdiff_width * s end
  style.contracted_scrollbar_margin = style.contracted_scrollbar_margin * s
  style.expanded_scrollbar_margin   = style.expanded_scrollbar_margin   * s
  style.caret_width                 = style.caret_width                 * s
  style.tab_min_width               = style.tab_min_width               * s
  style.tab_max_width               = style.tab_max_width               * s
  style.tab_width                   = style.tab_width                   * s
  style.padding.x                   = style.padding.x                   * s
  style.padding.y                   = style.padding.y                   * s
  style.fuzzy_searcher_result_row_padding = style.fuzzy_searcher_result_row_padding * s
  style.margin.tab.top              = style.margin.tab.top              * s
  config.mouse_wheel_scroll         = config.mouse_wheel_scroll         * s

  local scaled_fonts = {}
  for _, name in ipairs {
    "font", "big_font", "icon_font", "icon_big_font", "menu_icon_font",
    "view_text_font", "markdown_body_font", "prose_strong_font", "prose_emphasis_font",
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

  restore_active_textview_center(active_center)

  core.redraw = true
end

function scale.set_code(scale)
  if current_code_scale == scale then return end

  scale = common.clamp(scale, MIN_SCALE, MAX_SCALE)

  local active_center = capture_active_textview_center()

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

  restore_active_textview_center(active_center)

  core.redraw = true
end

function scale.get()
  return current_scale
end

function scale.reset()
  local reset_code = current_scale == current_code_scale
  scale.set(base_scale())
  if reset_code then
    scale.set_code(base_scale())
  end
  save_zoom()
  show_zoom_message()
end

function scale.increase()
  scale.set(zoomed_scale(current_scale, 1))
  scale.set_code(zoomed_scale(current_code_scale, 1))
  save_zoom()
  show_zoom_message()
end

function scale.decrease()
  scale.set(zoomed_scale(current_scale, -1))
  scale.set_code(zoomed_scale(current_code_scale, -1))
  save_zoom()
  show_zoom_message()
end

function scale.get_code()
  return current_code_scale
end

function scale.reset_code()
  scale.set_code(base_scale())
  save_zoom()
  show_zoom_message()
end

function scale.increase_code()
  scale.set_code(zoomed_scale(current_code_scale, 1))
  save_zoom()
  show_zoom_message()
end

function scale.decrease_code()
  scale.set_code(zoomed_scale(current_code_scale, -1))
  save_zoom()
  show_zoom_message()
end

local on_event = core.on_event
function core.on_event(type, ...)
  if type == "zoomwheel" then
    local direction = ...
    if config.plugins.scale.use_mousewheel then
      if direction > 0 then scale.increase() elseif direction < 0 then scale.decrease() end
      core.log_quiet("Sidebar Zoom wheel: direction=%s", tostring(direction))
    end
    return true
  end
  if type ~= "zoomchanged" then return on_event(type, ...) end
  apply_zoom("another Project saved it", ...)
  return true
end

local scale_set_by_user = 0
local first_on_apply_scale = configured_scale and true or false

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
        apply_zoom(enabled and "display scale" or "default scale", zoom.load())
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
      apply_zoom("default scale", zoom.load())
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

keymap.add_direct {
  ["ctrl+-"] = "editor:zoom_out",
  ["ctrl+="] = "editor:zoom_in",
  ["ctrl+plus"] = "editor:zoom_in",
}

if config.plugins.scale.use_mousewheel then
  keymap.add {
    ["ctrl+wheelup"] = "editor:zoom_in",
    ["ctrl+wheeldown"] = "editor:zoom_out",
    ["ctrl+shift+wheelup"] = "editor:zoom_in",
    ["ctrl+shift+wheeldown"] = "editor:zoom_out"
  }
end

-- Defer the saved Zoom until startup configuration has loaded its fonts.
core.add_thread(function() apply_zoom("startup", zoom.load()) end)


return scale
