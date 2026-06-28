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
local user_scale = tonumber(
  os.getenv("ANVIL_SCALE_RESTART") or os.getenv("ANVIL_SCALE")
)

local function capture_active_docview_caret_y()
  local DocView = package.loaded["core.docview"]
  local view = core.active_view
  if not DocView or not view or not view.extends or not view:extends(DocView) then return nil end
  local line, col = view.doc:get_selection()
  local _, y = view:get_line_screen_position(line, col)
  return { view = view, line = line, col = col, y = y }
end

local function restore_active_docview_caret_y(anchor)
  if not anchor or not anchor.view or not anchor.view.doc then return end
  local view = anchor.view
  local _, y = view:get_line_screen_position(anchor.line, anchor.col)
  local target = (view.scroll.to.y or view.scroll.y or 0) + (y - anchor.y)
  local max = view:get_scrollable_size() - view.size.y
  target = common.clamp(target, 0, max)
  view.scroll.y = target
  view.scroll.to.y = target
end

---@class plugins.scale
local scale = {}

function scale.set(scale)
  if current_scale == scale then return end
  system.setenv("ANVIL_SCALE_RESTART", scale)

  scale = common.clamp(scale, 0.7, 6)

  local active_caret_y = capture_active_docview_caret_y()

  -- save scroll positions
  local v_scrolls = {}
  local h_scrolls = {}
  for _, view in ipairs(core.root_panel.root_node:get_children()) do
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

  for _, name in ipairs {"font", "big_font", "icon_font", "icon_big_font"} do
    style[name]:set_size(s * style[name]:get_size())
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

  restore_active_docview_caret_y(active_caret_y)

  core.redraw = true
end

function scale.set_code(scale)
  if current_code_scale == scale then return end
  system.setenv("ANVIL_SCALE_CODE_RESTART", scale)

  scale = common.clamp(scale, 0.7, 6)

  local active_caret_y = capture_active_docview_caret_y()

  local s = scale / current_code_scale
  current_code_scale = scale

  style.code_font:set_size(s * style.code_font:get_size())
  for name, font in pairs(style.syntax_fonts) do
    style.syntax_fonts[name]:set_size(s * font:get_size())
  end

  restore_active_docview_caret_y(active_caret_y)

  core.redraw = true
end

function scale.get()
  return current_scale
end

function scale.reset()
  local reset_code = current_scale == current_code_scale
  scale.set(DEFAULT_SCALE)
  if reset_code then
    scale.set_code(DEFAULT_SCALE)
  end
end

function scale.increase()
  scale.set(current_scale * scale_factor)
  scale.set_code(current_code_scale * scale_factor)
end

function scale.decrease()
  scale.set(current_scale / scale_factor)
  scale.set_code(current_code_scale / scale_factor)
end

function scale.get_code()
  return current_code_scale
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
      keymap.unbind("ctrl+wheelup", "scale:increase")
      keymap.unbind("ctrl+wheeldown", "scale:decrease")
      keymap.unbind("ctrl+shift+wheelup", "scale:increase")
      keymap.unbind("ctrl+shift+wheeldown", "scale:decrease")
      if enabled then
        keymap.add {
          ["ctrl+wheelup"] = "editor:zoom-in",
          ["ctrl+wheeldown"] = "editor:zoom-out",
          ["ctrl+shift+wheelup"] = "editor:zoom-in",
          ["ctrl+shift+wheeldown"] = "editor:zoom-out"
        }
      else
        keymap.unbind("ctrl+wheelup", "editor:zoom-in")
        keymap.unbind("ctrl+wheeldown", "editor:zoom-out")
        keymap.unbind("ctrl+shift+wheelup", "editor:zoom-in")
        keymap.unbind("ctrl+shift+wheeldown", "editor:zoom-out")
      end
    end
  }
}


command.add(nil, {
  ["editor:zoom-reset"] = function() scale.reset() end,
  ["editor:zoom-out"] = function() scale.decrease() end,
  ["editor:zoom-in"] = function() scale.increase() end
})

command.map["scale:reset"] = nil
command.map["scale:decrease"] = nil
command.map["scale:increase"] = nil
command.map["scale:reset-code"] = nil
command.map["scale:decrease-code"] = nil
command.map["scale:increase-code"] = nil

keymap.unbind("ctrl+0", "scale:reset")
keymap.unbind("ctrl+-", "scale:decrease")
keymap.unbind("ctrl+=", "scale:increase")
keymap.unbind("ctrl+shift+0", "scale:reset")
keymap.unbind("ctrl+shift+-", "scale:decrease")
keymap.unbind("ctrl+shift+=", "scale:increase")
keymap.unbind("ctrl+wheelup", "scale:increase")
keymap.unbind("ctrl+wheeldown", "scale:decrease")
keymap.unbind("ctrl+shift+wheelup", "scale:increase")
keymap.unbind("ctrl+shift+wheeldown", "scale:decrease")
keymap.unbind("ctrl+shift+0", "scale:reset-code")
keymap.unbind("ctrl+shift+-", "scale:decrease-code")
keymap.unbind("ctrl+shift+=", "scale:increase-code")
keymap.unbind("ctrl+shift+wheelup", "scale:increase-code")
keymap.unbind("ctrl+shift+wheeldown", "scale:decrease-code")

keymap.add {
  ["ctrl+0"] = "editor:zoom-reset",
  ["ctrl+-"] = "editor:zoom-out",
  ["ctrl+="] = "editor:zoom-in",
  ["ctrl+shift+0"] = "editor:zoom-reset",
  ["ctrl+shift+-"] = "editor:zoom-out",
  ["ctrl+shift+="] = "editor:zoom-in"
}

if config.plugins.scale.use_mousewheel then
  keymap.add {
    ["ctrl+wheelup"] = "editor:zoom-in",
    ["ctrl+wheeldown"] = "editor:zoom-out",
    ["ctrl+shift+wheelup"] = "editor:zoom-in",
    ["ctrl+shift+wheeldown"] = "editor:zoom-out"
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
