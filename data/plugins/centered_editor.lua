-- mod-version:3 priority:200
-- Center normal editor TextViews inside a capped-width editing lane.
local core = require "core"
local command = require "core.command"
local config = require "core.config"
local style = require "core.style"
local linewrapping = require "core.linewrapping"
local TextView = require "core.textview"
local Editor = require "core.editor"
local panes = require "core.panes"

local centered_editor = config.plugins.centered_editor

local M = {}

local function perf_frame_add(key, amount)
  if not core.perf_frame_stats then return end
  local perf = package.loaded["core.perf"]
  if perf and perf.frame_add then perf.frame_add(key, amount or 1) end
end

local function perf_elapsed(key, start_time)
  if start_time then perf_frame_add(key, (system.get_time() - start_time) * 1000) end
end

local function perf_detail(key, amount)
  local perf = package.loaded["core.perf"]
  if perf and perf.is_recording and perf.is_recording() and perf.add_detail then
    perf.add_detail(key, amount or 1)
  end
end

local function perf_scope_begin(name)
  if not core.perf_draw_scope_active then return nil end
  local perf = package.loaded["core.perf"]
  return perf and perf.scope_begin and perf.scope_begin(name) or nil
end

local function perf_scope_end(token)
  if not token then return end
  local perf = package.loaded["core.perf"]
  if perf and perf.scope_end then perf.scope_end(token) end
end

local pack = table.pack or function(...)
  return { n = select("#", ...), ... }
end
local unpack = table.unpack or unpack

local originals = TextView.__centered_editor_originals
if originals then
  -- Restore previous centered-editor wrappers before rebuilding them.  This
  -- keeps config/plugin reloads from stacking wrappers on top of wrappers.
  for name, fn in pairs(originals.textview) do
    TextView[name] = fn
  end
  for name, cmd in pairs(originals.commands) do
    if command.map[name] then
      command.map[name].predicate = cmd.predicate
      command.map[name].perform = cmd.perform
    end
  end
  linewrapping.unregister_width_provider("centered_editor")
else
  originals = { textview = {}, commands = {} }
  TextView.__centered_editor_originals = originals
end

local function settings()
  return config.plugins.centered_editor or centered_editor
end

local function pane_for_view(view)
  local perf_start = core.perf_frame_stats and system.get_time()
  perf_frame_add("centered_editor_pane_lookup_calls", 1)
  local pane = panes.pane_for_view(view)
  perf_elapsed("centered_editor_pane_lookup_ms", perf_start)
  return pane
end

local function set_pane_membership(view, is_member)
  if not view then return end
  is_member = not not is_member
  if view.__centered_editor_pane_membership ~= is_member then
    view.__centered_editor_pane_membership = is_member
    view.__centered_editor_pane_membership_generation =
      (view.__centered_editor_pane_membership_generation or 0) + 1
  end
end

function M.should_center(view)
  perf_frame_add("centered_editor_should_center_calls", 1)
  local cfg = settings()
  if not cfg.enabled then
    perf_frame_add("centered_editor_should_center_disabled", 1)
    return false
  end
  if not view or getmetatable(view) ~= Editor or not view.buffer then
    perf_frame_add("centered_editor_should_center_non_editor", 1)
    return false
  end
  if cfg.pane_views_only then
    local pane = pane_for_view(view)
    local is_member = pane ~= nil
    set_pane_membership(view, is_member)
    if not is_member then
      perf_frame_add("centered_editor_should_center_not_pane", 1)
      return false
    end
  else
    set_pane_membership(view, true)
  end
  local max_width = M.get_scaled_max_width(view)
  if max_width <= 0 then
    perf_frame_add("centered_editor_should_center_no_width", 1)
    return false
  end
  local centered = view.size
    and view.size.x > max_width + (tonumber(cfg.min_margin) or 0) * 2
  perf_frame_add(
    centered and "centered_editor_should_center_true"
      or "centered_editor_should_center_too_narrow",
    1
  )
  return centered
end

function M.get_scaled_max_width(view)
  local cfg = settings()
  local max_width
  if view and view.__markdown_live_attached then
    max_width = tonumber(cfg.markdown_live_max_width)
  end
  if max_width == nil then max_width = tonumber(cfg.max_width) or 0 end
  if cfg.scale_width ~= false then
    max_width = max_width * SCALE
  end
  return max_width
end

function M.get_lane_rect(view)
  local cfg = settings()
  local max_width = M.get_scaled_max_width(view)
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
  perf_frame_add("centered_editor_with_geometry_calls", 1)
  local should_center = M.should_center(view)
  if not should_center or view.__centered_editor_in_geometry then
    perf_frame_add(
      view.__centered_editor_in_geometry
        and "centered_editor_with_geometry_nested_bypasses"
        or "centered_editor_with_geometry_inactive_bypasses",
      1
    )
    return fn(...)
  end

  local geometry_x, geometry_width = rect_fn(view)
  local old_x, old_w = view.position.x, view.size.x
  perf_frame_add("centered_editor_with_geometry_entries", 1)
  perf_detail(string.format(
    "centered_editor_geometry:host_x=%d:host_width=%d:effective_x=%d:effective_width=%d",
    math.floor(tonumber(old_x) or 0), math.floor(tonumber(old_w) or 0),
    math.floor(tonumber(geometry_x) or 0), math.floor(tonumber(geometry_width) or 0)
  ), 1)
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

local function save_textview_method(name)
  originals.textview[name] = TextView[name]
end

save_textview_method("get_presentation_viewport_width")
function TextView:get_presentation_viewport_width(...)
  if self.__centered_editor_in_geometry then return self.size.x end
  if M.should_center(self) then
    local _, width = M.get_editor_rect(self)
    return width
  end
  return originals.textview.get_presentation_viewport_width(self, ...)
end

save_textview_method("get_presentation_layout_generation")
function TextView:get_presentation_layout_generation()
  local cfg = settings()
  if cfg.pane_views_only and self.__centered_editor_pane_membership == nil then
    local pane = pane_for_view(self)
    set_pane_membership(
      self,
      pane ~= nil
    )
  elseif not cfg.pane_views_only then
    set_pane_membership(self, true)
  end
  local host_width = self.__centered_editor_in_geometry
    and self.__full_width_highlight_size_x or self.size.x
  local wrapped = M.wrapping_limits_to_lane(self)
  local state = self.__centered_editor_presentation_layout_state
  if state
    and state.host_width == host_width
    and state.enabled == cfg.enabled
    and state.pane_views_only == cfg.pane_views_only
    and state.membership_generation == (self.__centered_editor_pane_membership_generation or 0)
    and state.max_width == cfg.max_width
    and state.markdown_live_max_width == cfg.markdown_live_max_width
    and state.min_margin == cfg.min_margin
    and state.scale_width == cfg.scale_width
    and state.scale == SCALE
    and state.markdown_live_attached == not not self.__markdown_live_attached
    and state.wrapped == wrapped
  then
    return state.generation
  end
  self.__centered_editor_presentation_layout_generation =
    (self.__centered_editor_presentation_layout_generation or 0) + 1
  state = {
    generation = self.__centered_editor_presentation_layout_generation,
    host_width = host_width,
    enabled = cfg.enabled,
    pane_views_only = cfg.pane_views_only,
    membership_generation = self.__centered_editor_pane_membership_generation or 0,
    max_width = cfg.max_width,
    markdown_live_max_width = cfg.markdown_live_max_width,
    min_margin = cfg.min_margin,
    scale_width = cfg.scale_width,
    scale = SCALE,
    markdown_live_attached = not not self.__markdown_live_attached,
    wrapped = wrapped,
  }
  self.__centered_editor_presentation_layout_state = state
  return state.generation
end

save_textview_method("get_content_offset")
function TextView:get_content_offset(...)
  if not M.should_center(self)
  or self.__centered_editor_in_geometry
  or self.__centered_editor_in_lane_geometry then
    return originals.textview.get_content_offset(self, ...)
  end
  local lane_x = M.get_lane_rect(self)
  local _, y = originals.textview.get_content_offset(self, ...)
  return math.floor(lane_x - self.scroll.x + 0.5), y
end

save_textview_method("get_visible_cols_range")
function TextView:get_visible_cols_range(...)
  return M.with_editor_geometry(self, function(...)
    return originals.textview.get_visible_cols_range(self, ...)
  end, ...)
end

save_textview_method("draw")
function TextView:draw(...)
  if not M.should_center(self) then
    return originals.textview.draw(self, ...)
  end

  local scope = perf_scope_begin("centered_editor")

  -- Paint the whole tab background first; the existing draw chain then uses
  -- centered geometry for the buffer origin while preserving the full
  -- drawable width unless line wrapping is active.
  self:draw_background(style.background)
  local result = M.with_editor_geometry(self, function(...)
    return originals.textview.draw(self, ...)
  end, ...)
  perf_scope_end(scope)
  return result
end

save_textview_method("on_mouse_moved")
function TextView:on_mouse_moved(x, y, ...)
  if M.should_center(self) and type(x) == "number" and type(y) == "number" then
    local in_vertical = y >= self.position.y and y < self.position.y + self.size.y
    if in_vertical
    and not self.mouse_selecting
    and not self:scrollbar_dragging()
    and not self:scrollbar_overlaps_point(x, y)
    and not editor_contains_x(self, x) then
      self.cursor = "arrow"
      self.hovering_gutter = false
      self.v_scrollbar:on_mouse_left()
      self.h_scrollbar:on_mouse_left()
      return true
    end
  end
  return M.with_editor_geometry(self, function(x, y, ...)
    return originals.textview.on_mouse_moved(self, x, y, ...)
  end, x, y, ...)
end

save_textview_method("on_mouse_pressed")
function TextView:on_mouse_pressed(button, x, y, clicks, ...)
  return M.with_editor_geometry(self, function(button, x, y, clicks, ...)
    return originals.textview.on_mouse_pressed(self, button, x, y, clicks, ...)
  end, button, x, y, clicks, ...)
end

save_textview_method("on_mouse_released")
function TextView:on_mouse_released(...)
  return M.with_editor_geometry(self, function(...)
    return originals.textview.on_mouse_released(self, ...)
  end, ...)
end

save_textview_method("scroll_to_make_visible")
function TextView:scroll_to_make_visible(...)
  return M.with_editor_geometry(self, function(...)
    return originals.textview.scroll_to_make_visible(self, ...)
  end, ...)
end

save_textview_method("scroll_to_line")
function TextView:scroll_to_line(...)
  return M.with_editor_geometry(self, function(...)
    return originals.textview.scroll_to_line(self, ...)
  end, ...)
end

command.add_toggle("centered-editor:toggle", {
  palette = true,
  get = function()
    return settings().enabled
  end,
  set = function(enabled)
    local cfg = settings()
    cfg.enabled = enabled
    core.log("Centered editor %s", cfg.enabled and "enabled" or "disabled")
  end,
})

local mouse_commands = {
  "text:set-cursor",
  "text:set-cursor-word",
  "text:set-cursor-line",
  "text:split-cursor",
  "text:select-to-cursor",
  "text:paste-primary-selection",
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

-- Wrap to the centered lane instead of the full tab width when no explicit
-- user line-wrapping width override is configured.
linewrapping.register_width_provider("centered_editor", function(textview)
  if config.plugins.linewrapping.width_override ~= nil then return nil end
  if not M.should_center(textview) then return nil end
  local scrollbar_width = textview.v_scrollbar.expanded_size or style.expanded_scrollbar_size
  local _, lane_width = M.get_lane_rect(textview)
  return math.max(0, lane_width - textview:get_gutter_width() - scrollbar_width)
end)

core.centered_editor = M
return M
