-- mod-version:3 priority:200
-- Center normal editor DocViews inside a capped-width editing lane.
local core = require "core"
local command = require "core.command"
local config = require "core.config"
local style = require "core.style"
local DocView = require "core.docview"

local centered_editor = config.plugins.centered_editor

local M = {}

local pack = table.pack or function(...)
  return { n = select("#", ...), ... }
end
local unpack = table.unpack or unpack

local originals = DocView.__centered_editor_originals
if originals then
  -- Restore previous centered-editor wrappers before rebuilding them.  This
  -- keeps config/plugin reloads from stacking wrappers on top of wrappers.
  for name, fn in pairs(originals.docview) do
    DocView[name] = fn
  end
  for name, cmd in pairs(originals.commands) do
    if command.map[name] then
      command.map[name].predicate = cmd.predicate
      command.map[name].perform = cmd.perform
    end
  end
  if originals.linewrapping_width_override_marker then
    config.plugins.linewrapping.width_override = originals.linewrapping_width_override
  end
else
  originals = { docview = {}, commands = {} }
  DocView.__centered_editor_originals = originals
end

local function settings()
  return config.plugins.centered_editor or centered_editor
end

local function root_node_for_view(view)
  local root = core.root_panel and core.root_panel.root_node
  return root and root.get_node_for_view and root:get_node_for_view(view) or nil
end

function M.should_center(view)
  local cfg = settings()
  if not cfg.enabled then return false end
  if not view or getmetatable(view) ~= DocView or not view.doc then return false end
  if cfg.main_tabs_only then
    local node = root_node_for_view(view)
    if not node or not node.get_view_idx or not node:get_view_idx(view) then
      return false
    end
  end
  local max_width = M.get_scaled_max_width()
  if max_width <= 0 then return false end
  return view.size and view.size.x > max_width + (tonumber(cfg.min_margin) or 0) * 2
end

function M.get_scaled_max_width()
  local cfg = settings()
  local max_width = tonumber(cfg.max_width) or 0
  if cfg.scale_width ~= false then
    max_width = max_width * SCALE
  end
  return max_width
end

function M.get_lane_rect(view)
  local cfg = settings()
  local max_width = M.get_scaled_max_width()
  if max_width <= 0 then max_width = view.size.x end
  local min_margin = tonumber(cfg.min_margin) or 0
  if cfg.scale_width ~= false then min_margin = min_margin * SCALE end
  local available = math.max(0, view.size.x - min_margin * 2)
  local lane_width = math.min(view.size.x, math.max(0, math.min(max_width, available)))
  local lane_x = view.position.x + math.floor((view.size.x - lane_width) / 2)
  return lane_x, lane_width
end

function M.wrapping_limits_to_lane(view)
  if not view then return false end
  local wrapped = view.wrapped_settings and view.wrapped_settings.width ~= math.huge
  return view.wrapping_enabled or wrapped or false
end

function M.get_shifted_full_rect(view)
  local lane_x = M.get_lane_rect(view)
  local view_right = view.position.x + view.size.x
  return lane_x, math.max(0, view_right - lane_x)
end

function M.get_editor_rect(view)
  if M.wrapping_limits_to_lane(view) then
    return M.get_lane_rect(view)
  end
  return M.get_shifted_full_rect(view)
end

local function editor_contains_x(view, x)
  local editor_x, editor_width = M.get_editor_rect(view)
  return x >= editor_x and x < editor_x + editor_width
end

local function editor_contains_content_x(view, x)
  local editor_x, editor_width = M.get_editor_rect(view)
  local gw = view:get_gutter_width()
  return x >= editor_x + gw and x < editor_x + editor_width
end

local function with_geometry(view, rect_fn, fn, ...)
  if not M.should_center(view) or view.__centered_editor_in_geometry then
    return fn(...)
  end

  local geometry_x, geometry_width = rect_fn(view)
  local old_x, old_w = view.position.x, view.size.x
  local old_geometry_flag = view.__centered_editor_in_geometry
  local old_lane_flag = view.__centered_editor_in_lane_geometry
  local old_highlight_x = view.__full_width_highlight_position_x
  local old_highlight_w = view.__full_width_highlight_size_x
  view.position.x = geometry_x
  view.size.x = geometry_width
  view.__centered_editor_in_geometry = true
  view.__centered_editor_in_lane_geometry = true
  view.__full_width_highlight_position_x = old_x
  view.__full_width_highlight_size_x = old_w

  local args = pack(...)
  local results
  local ok, err = xpcall(function()
    results = pack(fn(unpack(args, 1, args.n)))
  end, debug.traceback)

  view.position.x = old_x
  view.size.x = old_w
  view.__centered_editor_in_geometry = old_geometry_flag
  view.__centered_editor_in_lane_geometry = old_lane_flag
  view.__full_width_highlight_position_x = old_highlight_x
  view.__full_width_highlight_size_x = old_highlight_w

  if not ok then error(err, 0) end
  return unpack(results, 1, results.n)
end

function M.with_lane_geometry(view, fn, ...)
  return with_geometry(view, M.get_lane_rect, fn, ...)
end

function M.with_editor_geometry(view, fn, ...)
  return with_geometry(view, M.get_editor_rect, fn, ...)
end

local function save_docview_method(name)
  originals.docview[name] = DocView[name]
end

save_docview_method("get_content_offset")
function DocView:get_content_offset(...)
  if not M.should_center(self)
  or self.__centered_editor_in_geometry
  or self.__centered_editor_in_lane_geometry then
    return originals.docview.get_content_offset(self, ...)
  end
  local lane_x = M.get_lane_rect(self)
  local _, y = originals.docview.get_content_offset(self, ...)
  return math.floor(lane_x - self.scroll.x + 0.5), y
end

save_docview_method("get_visible_cols_range")
function DocView:get_visible_cols_range(...)
  return M.with_editor_geometry(self, function(...)
    return originals.docview.get_visible_cols_range(self, ...)
  end, ...)
end

save_docview_method("draw")
function DocView:draw(...)
  if not M.should_center(self) then
    return originals.docview.draw(self, ...)
  end

  -- Paint the whole tab background first; the existing draw chain then uses
  -- centered geometry for the document origin while preserving the full
  -- drawable width unless line wrapping is active.
  self:draw_background(style.background)
  return M.with_editor_geometry(self, function(...)
    return originals.docview.draw(self, ...)
  end, ...)
end

save_docview_method("on_mouse_moved")
function DocView:on_mouse_moved(x, y, ...)
  if M.should_center(self) and type(x) == "number" and type(y) == "number" then
    local in_vertical = y >= self.position.y and y < self.position.y + self.size.y
    if in_vertical and not self.mouse_selecting and not self:scrollbar_dragging() and not editor_contains_x(self, x) then
      self.cursor = "arrow"
      self.hovering_gutter = false
      self.v_scrollbar:on_mouse_left()
      self.h_scrollbar:on_mouse_left()
      return true
    end
  end
  return M.with_editor_geometry(self, function(x, y, ...)
    return originals.docview.on_mouse_moved(self, x, y, ...)
  end, x, y, ...)
end

save_docview_method("on_mouse_pressed")
function DocView:on_mouse_pressed(button, x, y, clicks, ...)
  return M.with_editor_geometry(self, function(button, x, y, clicks, ...)
    return originals.docview.on_mouse_pressed(self, button, x, y, clicks, ...)
  end, button, x, y, clicks, ...)
end

save_docview_method("on_mouse_released")
function DocView:on_mouse_released(...)
  return M.with_editor_geometry(self, function(...)
    return originals.docview.on_mouse_released(self, ...)
  end, ...)
end

save_docview_method("scroll_to_make_visible")
function DocView:scroll_to_make_visible(...)
  return M.with_editor_geometry(self, function(...)
    return originals.docview.scroll_to_make_visible(self, ...)
  end, ...)
end

save_docview_method("scroll_to_line")
function DocView:scroll_to_line(...)
  return M.with_editor_geometry(self, function(...)
    return originals.docview.scroll_to_line(self, ...)
  end, ...)
end

command.add(nil, {
  ["centered-editor:toggle"] = function()
    local cfg = settings()
    cfg.enabled = not cfg.enabled
    core.log("Centered editor %s", cfg.enabled and "enabled" or "disabled")
  end,
})

local mouse_commands = {
  "doc:set-cursor",
  "doc:set-cursor-word",
  "doc:set-cursor-line",
  "doc:split-cursor",
  "doc:select-to-cursor",
  "doc:paste-primary-selection",
}

local function patch_mouse_command(name)
  local cmd = command.map[name]
  if not cmd then return end
  originals.commands[name] = { predicate = cmd.predicate, perform = cmd.perform }
  local old_predicate = cmd.predicate
  cmd.predicate = function(x, y, ...)
    local res = pack(old_predicate(x, y, ...))
    if not res[1] then return unpack(res, 1, res.n) end
    if type(x) ~= "number" or type(y) ~= "number" then
      return unpack(res, 1, res.n)
    end

    local dv = res[2]
    if not dv or not M.should_center(dv) then
      return unpack(res, 1, res.n)
    end
    if not editor_contains_content_x(dv, x) then
      return false
    end
    return unpack(res, 1, res.n)
  end
end

for _, name in ipairs(mouse_commands) do
  patch_mouse_command(name)
end

-- If the official linewrapping plugin is active and the user has not supplied
-- an override, wrap to the centered lane instead of the full tab width.
if config.plugins.linewrapping.width_override == nil then
  originals.linewrapping_width_override = config.plugins.linewrapping.width_override
  originals.linewrapping_width_override_marker = true
  config.plugins.linewrapping.width_override = function(docview)
    local scrollbar_width = docview.v_scrollbar.expanded_size or style.expanded_scrollbar_size
    if M.should_center(docview) then
      local _, lane_width = M.get_lane_rect(docview)
      return math.max(0, lane_width - docview:get_gutter_width() - scrollbar_width)
    end
    return docview.size.x - docview:get_gutter_width() - scrollbar_width
  end
end

core.centered_editor = M
return M
