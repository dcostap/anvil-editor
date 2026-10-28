local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local View = require "core.view"
local layout = require "core.pane_layout"
local CaretRenderer = require "core.caret_renderer"
local FocusFeedback = require "core.focus_feedback"
local wallpaper_contrast = require "core.wallpaper_contrast"
local wallpapers = require "core.wallpapers"

local RootPanel = View:extend()

local APP_OVERLAY_FADE_DURATION = 0.06
local DIVIDER_TOLERANCE = 4

function RootPanel:__tostring() return "RootPanel" end

local function panes()
  return core.panes or require "core.panes"
end

local function file_open_begin(path, source)
  local perf = package.loaded["core.perf"]
  return perf and perf.file_open_begin and perf.file_open_begin(path, source)
end

local function file_open_stage_begin(name)
  local perf = package.loaded["core.perf"]
  return perf and perf.file_open_stage_begin and perf.file_open_stage_begin(name)
end

local function file_open_stage_end(token)
  if not token then return end
  local perf = package.loaded["core.perf"]
  if perf and perf.file_open_stage_end then perf.file_open_stage_end(token) end
end

local function file_open_attach_view(view)
  local perf = package.loaded["core.perf"]
  if perf and perf.file_open_attach_view then perf.file_open_attach_view(view) end
end

local function perf_begin(name)
  if not core.perf_frame_stats then return end
  local perf = package.loaded["core.perf"]
  local scope = core.perf_draw_scope_active and perf and perf.scope_begin(name, true)
  return system.get_time(), scope
end

local function perf_end(name, started, scope)
  if not started then return end
  local perf = package.loaded["core.perf"]
  if not perf then return end
  if scope then perf.scope_end(scope) end
  perf.frame_add(name .. "_ms", (system.get_time() - started) * 1000)
end

local function invoke_view(view, name, ...)
  local method = view and view[name]
  if not method then return nil end
  if view.with_selection_state then
    return view:with_selection_state(method, view, ...)
  end
  return method(view, ...)
end

local function call_view(view, name, ...)
  if not core.perf_frame_stats or not view or (name ~= "update" and name ~= "draw") then
    return invoke_view(view, name, ...)
  end
  local key = "rootpanel_" .. tostring(view) .. "_" .. name
  local started, scope = perf_begin(key)
  local result = table.pack(invoke_view(view, name, ...))
  perf_end(key, started, scope)
  return table.unpack(result, 1, result.n)
end

local function point_in_view(view, x, y)
  return view and x >= view.position.x and y >= view.position.y
    and x < view.position.x + view.size.x
    and y < view.position.y + view.size.y
end

local function set_rect(view, x, y, w, h)
  if not view then return end
  view.position.x, view.position.y = x, y
  view.size.x, view.size.y = w, h
end

function RootPanel:new()
  RootPanel.super.new(self)
  self.mouse = { x = 0, y = 0 }
  self.deferred_draws = {}
  self.app_overlay = nil
  self.above_sidebar = {}
  self.grab = nil
  self.overlapping_view = nil
  self.touched_view = nil
  self.dragged_divider = nil
  self.modal_inputs = {}
  self.content_rect = { x = 0, y = 0, w = 0, h = 0 }
  self.caret_renderer = CaretRenderer.new()
  self.focus_feedback = FocusFeedback()
end

-- The Root Panel draws in layers: Views, overlays, deferred popups, then the top layer.
-- The keyboard caret draws at the end of the layer that drew its owner, so later layers cover it.
local CARET_LAYER_VIEWS, CARET_LAYER_OVERLAYS, CARET_LAYER_DEFERRED, CARET_LAYER_TOP = 1, 2, 3, 4

---Submit the focused keyboard caret for global drawing.
function RootPanel:submit_keyboard_caret(target)
  target.layer = self.caret_layer or CARET_LAYER_TOP
  target.trail_color = target.trail_color or style.caret_trail or target.color
  local previous = self.caret_renderer.previous_target
  if previous and previous.owner ~= target.owner then
    core.log_quiet(
      "Caret trail: following focus from=%s to=%s",
      tostring(previous.owner), tostring(target.owner)
    )
  end
  self.caret_renderer:submit(target)
end

function RootPanel:begin_keyboard_caret_frame()
  self.caret_renderer:begin_frame(config.animated_caret)
end

-- Draw the keyboard caret when the layer of its owner ends. The top layer draws it in any case.
local function end_caret_layer(self)
  local layer = self.caret_layer
  local target = self.caret_renderer.target
  if not self.caret_drawn and (layer == CARET_LAYER_TOP or (target and target.layer <= layer)) then
    self.caret_drawn = true
    self:draw_keyboard_caret()
  end
  self.caret_layer = layer + 1
end

function RootPanel:draw_keyboard_caret()
  local animating = self.caret_renderer:draw(
    system.get_time(),
    config.animated_caret_animation_length,
    config.animated_caret_min_animation_length,
    config.animated_caret_trail_size,
    config.animated_caret_trail_min_distance,
    config.animated_caret_trail_full_distance,
    config.animated_caret_min_speed,
    config.animated_caret_max_speed,
    config.animated_caret_distance_min,
    config.animated_caret_distance_max,
    self.size.y
  )
  if animating then core.redraw = true end
end

local function modal_input_index(root, owner)
  for index, entry in ipairs(root.modal_inputs) do
    if entry.owner == owner then return index end
  end
end

---Place one input owner above all normal UI targets.
---An owner with on_raw_keyboard_event receives keys, text, and IME events before normal routing.
---An owner can return true from on_window_close to block a native close request.
function RootPanel:push_modal_input(owner, options)
  assert(owner ~= nil, "Modal Input Owner is required")
  self:stop_autoscroll("new modal input")
  options = options or {}
  local index = modal_input_index(self, owner)
  if index then table.remove(self.modal_inputs, index) end
  self.modal_inputs[#self.modal_inputs + 1] = {
    owner = owner,
    handlers = options.handlers,
    label = options.label or tostring(owner),
  }
  core.log_quiet("Modal input: pushed owner=%s depth=%d",
    options.label or tostring(owner), #self.modal_inputs)
  return owner
end

---Remove an input owner without changing the other owners.
function RootPanel:pop_modal_input(owner)
  local index = modal_input_index(self, owner)
  if not index then return false end
  local entry = table.remove(self.modal_inputs, index)
  core.log_quiet("Modal input: popped owner=%s depth=%d",
    entry.label, #self.modal_inputs)
  return true
end

---Return the input owner at the top of the stack.
function RootPanel:modal_input_owner()
  local entry = self.modal_inputs[#self.modal_inputs]
  return entry and entry.owner or nil
end

---Send an input event only to the top owner.
---Key handlers can return "target" or "keymap" for controlled routing.
function RootPanel:dispatch_modal_input(event, ...)
  local entry = self.modal_inputs[#self.modal_inputs]
  if not entry then return false end
  if event == "mouse_pressed" and entry.owner.get_autoscroll_target then
    local button, x, y = ...
    local target = button == "middle" and entry.owner:get_autoscroll_target(x, y)
    if target and self:start_autoscroll(target, x, y, entry.owner) then return true end
  end
  local handler = entry.handlers and entry.handlers[event]
  local result
  if handler then
    result = handler(...)
  else
    handler = entry.owner["on_modal_" .. event] or entry.owner["on_" .. event]
    if handler then result = handler(entry.owner, ...) end
  end
  if event == "key_pressed" then
    core.log_quiet("Modal input: key owner=%s route=%s",
      entry.label, tostring(result or "consumed"))
  end
  return true, result
end

function RootPanel:defer_draw(fn, ...)
  table.insert(self.deferred_draws, 1, { fn = fn, ... })
end

local function quintic_ease_out(progress)
  local remaining = 1 - progress
  return 1 - remaining * remaining * remaining * remaining * remaining
end

local function fuzzy_searcher_overlay_ease(progress)
  return progress * progress * (3 - 2 * progress)
end

local function start_app_overlay_transition(overlay, target, now)
  if overlay.target == target then return end
  overlay.start_progress = overlay.progress
  overlay.target = target
  overlay.transition_started_at = now
  overlay.transition_duration = APP_OVERLAY_FADE_DURATION
    * math.abs(target - overlay.progress)
end

function RootPanel:update_app_overlay(now)
  local overlay = self.app_overlay
  if not overlay then return 0 end
  now = now or system.get_time()
  local transition_disabled = not config.transitions
    or (overlay.transition_name and config.disabled_transitions[overlay.transition_name])
    or (overlay.transition_name == "global_prompt_bar" and config.disabled_transitions.commandview)
    or core.in_live_resize_frame
    or (core.fps or config.fps) < 30
  local progress = overlay.progress
  if transition_disabled then
    progress = overlay.target
  elseif overlay.target ~= progress then
    local duration = overlay.transition_duration or APP_OVERLAY_FADE_DURATION
    if duration <= 0 then
      progress = overlay.target
    else
      local elapsed = math.max(0, now - (overlay.transition_started_at or now))
      local normalized = common.clamp(elapsed / duration, 0, 1)
      local eased = overlay.transition_name == "fuzzy_searcher"
        and fuzzy_searcher_overlay_ease(normalized)
        or quintic_ease_out(normalized)
      progress = common.lerp(
        overlay.start_progress or progress, overlay.target, eased
      )
    end
  end
  if progress ~= overlay.progress then overlay.progress, core.redraw = progress, true end
  if overlay.target == 0 and progress == 0 then self.app_overlay = nil end
  return progress
end

function RootPanel:show_app_overlay(owner, color, options)
  assert(owner ~= nil, "app overlay owner is required")
  options = options or {}
  local now = system.get_time()
  self:update_app_overlay(now)
  local overlay = self.app_overlay
  if not overlay then
    overlay = {
      progress = 0,
      target = 0,
      start_progress = 0,
      transition_started_at = now,
      transition_duration = 0,
    }
    self.app_overlay = overlay
  end
  overlay.owner = owner
  overlay.color = color
  overlay.transition_name = options.transition_name
  start_app_overlay_transition(overlay, 1, now)
  core.redraw = true
end

function RootPanel:hide_app_overlay(owner)
  local overlay = self.app_overlay
  if not overlay or overlay.owner ~= owner then return false end
  local now = system.get_time()
  self:update_app_overlay(now)
  overlay = self.app_overlay
  if not overlay or overlay.owner ~= owner then return false end
  start_app_overlay_transition(overlay, 0, now)
  core.redraw = true
  return true
end

function RootPanel:draw_app_overlay(color)
  renderer.draw_rect(self.position.x, self.position.y, self.size.x, self.size.y, color)
end

function RootPanel:draw_active_app_overlay()
  local overlay = self.app_overlay
  local source = overlay and overlay.progress > 0
    and (type(overlay.color) == "string" and style[overlay.color] or overlay.color)
  self.surface_overlay_color = nil
  if type(source) ~= "table" then return end
  local color = { table.unpack(source) }
  color[4] = (color[4] or 255) * overlay.progress
  self:draw_app_overlay(color)
  self.surface_overlay_color = color
end

-- The most areas one frame shows above a hosted shell's Sidebar.
local ABOVE_SIDEBAR_MAX = 4

-- A modal view that draws over a hosted shell's Sidebar reports its drawn area each frame it draws.
function RootPanel:show_above_sidebar(x, y, w, h)
  if #self.above_sidebar >= ABOVE_SIDEBAR_MAX then
    core.log_quiet("Area above the Sidebar dropped: %d already shown", ABOVE_SIDEBAR_MAX)
    return
  end
  local left, top = math.floor(x), math.floor(y)
  self.above_sidebar[#self.above_sidebar + 1] = { left, top, math.ceil(x + w) - left, math.ceil(y + h) - top }
end

-- A modal view that dims the whole Window adds its dim over the Sidebar, above any dim already there.
function RootPanel:dim_sidebar(color)
  local under = self.surface_overlay_color
  local alpha = (color[4] or 255) / 255
  if not under then
    self.surface_overlay_color = { color[1], color[2], color[3], alpha * 255 }
    return
  end
  local under_alpha = under[4] / 255
  local total = alpha + under_alpha * (1 - alpha)
  local mixed = { [4] = total * 255 }
  for i = 1, 3 do
    mixed[i] = total > 0 and (color[i] * alpha + under[i] * under_alpha * (1 - alpha)) / total or 0
  end
  self.surface_overlay_color = mixed
end

-- A hosted shell extends the dim over its Sidebar, and shows the reported areas above the Sidebar and the dim.
function RootPanel:publish_surface_overlay()
  local color = self.surface_overlay_color
  if not color then
    system.set_surface_overlay(core.window)
  else
    system.set_surface_overlay(core.window, color[1], color[2], color[3], color[4],
      #self.above_sidebar > 0 and self.above_sidebar or nil)
  end
end

function RootPanel:shell_views()
  return { core.title_bar, core.nag_view, core.global_prompt_bar }
end

function RootPanel:pane_views()
  local group = panes().visible_group()
  if not group then return {} end
  local result = {}
  for _, pane in ipairs(layout.leaves(group.root)) do
    if pane.current_view then result[#result + 1] = pane.current_view end
  end
  return result
end

---The Pane Status Bars of the visible Pane Group.
function RootPanel:pane_status_bars()
  local group = panes().visible_group()
  if not group or not core.status_bar then return {} end
  local result = {}
  for _, pane in ipairs(layout.leaves(group.root)) do
    result[#result + 1] = core.status_bar:bar_for_pane(pane)
  end
  return result
end

function RootPanel:children()
  local result = {}
  for _, view in ipairs(self:shell_views()) do if view then result[#result + 1] = view end end
  for _, view in ipairs(self:pane_views()) do result[#result + 1] = view end
  return result
end

function RootPanel:contains_view(view)
  if not view then return false end
  for _, child in ipairs(self:children()) do
    if child == view then return true end
  end
  local owner = panes().owner_for_view(view)
  local pane = owner and panes().pane_for_view(owner)
  return pane ~= nil and panes().is_visible(pane)
end

function RootPanel:view_at(x, y)
  for _, view in ipairs(self:shell_views()) do
    if point_in_view(view, x, y) then return view end
  end
  local group = panes().visible_group()
  local pane = group and layout.pane_at(group.root, x, y)
  local bar = pane and pane.status_bar
  if bar and bar.size.y > 0 and point_in_view(bar, x, y) then return bar end
  return pane and pane.current_view or nil
end

function RootPanel:get_active_pane()
  return panes().active()
end

-- Apply the destination before the Pane records the arrival place.
local function prepare_file_destination(view, opts)
  if not opts.line and not opts.navigate then return view end
  local pane = panes().pane_for_view(view) or (view and view.status_bar_pane)
  if pane and pane.current_view == view then
    require("core.navigation_history").flush_edit(view, nil, true)
    panes().record_location(pane)
  end
  view:with_selection_state(function()
    if opts.navigate then
      opts.navigate(view)
    else
      local line, col = opts.line, opts.col or 1
      view.buffer:set_selection(line, col, opts.line2 or line, opts.col2 or col)
      view:scroll_to_line(line, false, false)
    end
  end)
  local selection = view:get_selection_state().selections
  core.log_quiet("Navigation History: file destination prepared at %d:%d", selection[1], selection[2])
  return view
end

-- Show Live Preview from the first frame, also when another view keeps focus.
local function new_file_editor(buffer, opts)
  local editor = require("core.editor")(buffer)
  require("core.markdown.live_render").refresh_view(editor)
  return prepare_file_destination(editor, opts)
end

function RootPanel:open_buffer(buffer, opts)
  opts = opts or {}
  local Editor = require "core.editor"
  local target = panes().find(opts.pane or panes().active())
  if target and (opts.placement == nil or opts.placement == "current") then
    for _, view in ipairs(panes().views(target)) do
      if view.extends and view:extends(Editor) and view.buffer == buffer
          and target.current_view:can_open_view(view) then
        prepare_file_destination(view, opts)
        panes().present(view, { pane = target, focus = opts.focus })
        return view
      end
    end
  end
  return panes().place(function() return new_file_editor(buffer, opts) end, {
    pane = opts.pane,
    placement = opts.placement or "current",
    direction = opts.direction,
    focus = opts.focus,
    preserve_focus = opts.preserve_focus,
    reason = opts.reason,
  })
end

function RootPanel:open_file(filename, opts)
  opts = opts or {}
  local operation = file_open_begin(filename, "root_panel.open_file")
  local total_stage = operation and file_open_stage_begin("root_panel_open_file")
  local project = core.root_project()
  local path_stage = file_open_stage_begin("root_panel_path_resolution")
  local normalized = project:normalize_path(filename)
  local abs_filename = project:absolute_path(normalized)
  file_open_stage_end(path_stage)
  local lookup_stage = file_open_stage_begin("root_panel_buffer_lookup")
  local existing = core.buffer_registry:find(abs_filename)
  file_open_stage_end(lookup_stage)
  if existing then
    if existing.load_error
      or ((opts.line or opts.navigate or opts.background == false) and existing:is_loading()) then
      existing = core.open_buffer(filename, {
        background = opts.background ~= false and not opts.line and not opts.navigate,
      })
    end
    local present_stage = file_open_stage_begin("root_panel_present_existing_view")
    local view = self:open_buffer(existing, opts)
    file_open_stage_end(present_stage)
    file_open_stage_end(total_stage)
    file_open_attach_view(view)
    return view
  end

  local place_stage = file_open_stage_begin("root_panel_place_editor")
  local view = panes().place(function()
    return new_file_editor(core.open_buffer(filename, {
      background = opts.background ~= false and not opts.line and not opts.navigate,
    }), opts)
  end, {
    pane = opts.pane,
    placement = opts.placement or "current",
    direction = opts.direction,
    focus = opts.focus,
    preserve_focus = opts.preserve_focus,
    reason = opts.reason,
  })
  file_open_stage_end(place_stage)
  file_open_stage_end(total_stage)
  file_open_attach_view(view)
  return view
end

function RootPanel:close_all_views(keep_view)
  for i = #panes().ordered(), 1, -1 do
    local pane = panes().ordered()[i]
    if pane.current_view ~= keep_view then panes().close(pane) end
  end
end

function RootPanel:close_all_textviews(keep_active)
  local Editor = require "core.editor"
  local keep = keep_active and panes().active()
  for i = #panes().ordered(), 1, -1 do
    local pane = panes().ordered()[i]
    if pane ~= keep and pane.current_view:is(Editor) then panes().close(pane) end
  end
end

function RootPanel:update_layout()
  local x, y, w, h = self.position.x, self.position.y, self.size.x, self.size.y
  local title, nag, prompt = core.title_bar, core.nag_view, core.global_prompt_bar

  for _, view in ipairs { title, nag, prompt } do
    if view then
      view.position.x, view.size.x = x, w
      call_view(view, "update")
    end
  end
  if core.status_bar then core.status_bar:update() end
  local status_h = core.status_bar and core.status_bar:get_height() or 0

  local title_h = title and title.size.y or 0
  local pane_prompt = prompt and prompt.pane_scope and panes().find(prompt.pane_scope)
  set_rect(title, x, y, w, title_h)
  -- The nag bar's card floats over the Panes. Its View covers the area below the Title Bar while a dialog is open.
  set_rect(nag, x, y + title_h, w, nag and nag.visible and math.max(0, h - title_h) or 0)
  local content_y = y + title_h
  local content_h = math.max(0, h - title_h)
  -- The prompt's card floats over the Panes, near the top of the window or of its Pane.
  if prompt and not pane_prompt then prompt:place(x, content_y, w, content_h) end
  self.content_rect = { x = x, y = content_y, w = w, h = content_h }
  local group = panes().visible_group()
  if group then
    layout.update_rects(group.root, self.content_rect)
    -- Each Pane's Status Bar takes the bottom of the Pane; the View gets the rest.
    for _, pane in ipairs(layout.leaves(group.root)) do
      local bar_h = math.min(status_h, pane.size.y)
      local view_h = pane.size.y - bar_h
      if core.status_bar then
        local bar = core.status_bar:bar_for_pane(pane)
        set_rect(bar, pane.position.x, pane.position.y + view_h, pane.size.x, bar_h)
        bar:update()
      end
      if pane == pane_prompt then prompt:place(pane.position.x, pane.position.y, pane.size.x, view_h) end
      set_rect(pane.current_view, pane.position.x, pane.position.y, pane.size.x, view_h)
    end
  end
end

local function scrollbar_owns_point(view, x, y)
  return view and view.scrollbar_overlaps_point
    and view:scrollbar_overlaps_point(x, y)
end

local function request_view_cursor(view, x, y)
  local dragging = view and view.scrollbar_dragging and view:scrollbar_dragging()
  core.request_cursor((dragging or scrollbar_owns_point(view, x, y)) and "arrow" or view.cursor)
end

---Keep input and scrolling on the surface selected by middle-click.
function RootPanel:start_autoscroll(view, x, y, host)
  if not view or not view.scrollable then return false end
  self:stop_autoscroll("restart")
  host = host or self:view_at(x, y)
  if not self:modal_input_owner() and host then
    if host == view then core.set_active_view(view)
    else host:focus_surface_target(view) end
  end
  self:ungrab_mouse()
  local state = {
    view = view, host = host, x = x, y = y, mouse_y = y,
    last_time = system.get_time(), remainder = 0,
    modal_host = self:modal_input_owner() == host,
  }
  self:push_modal_input(state, {
    label = "Middle-click autoscroll",
    handlers = {
      mouse_moved = function(mx, my)
        self.mouse.x, self.mouse.y = mx, my
        state.mouse_y = my
        core.request_cursor("sizev")
        core.redraw = true
      end,
      mouse_pressed = function() self:stop_autoscroll("click") end,
      key_pressed = function() self:stop_autoscroll("key") end,
      mouse_wheel = function() self:stop_autoscroll("wheel") end,
      mouse_left = function() self:stop_autoscroll("pointer left window") end,
    },
  })
  self.autoscroll_state = state
  self.mouse.x, self.mouse.y = x, y
  core.request_cursor("sizev")
  core.redraw = true
  core.log_quiet("Autoscroll: started view=%s anchor=%.1f,%.1f", tostring(view), x, y)
  return true
end

function RootPanel:stop_autoscroll(reason)
  local state = self.autoscroll_state
  if not state then return end
  self.autoscroll_state = nil
  self:pop_modal_input(state)
  core.request_cursor("arrow")
  core.redraw = true
  core.log_quiet("Autoscroll: stopped reason=%s", reason)
end

function RootPanel:update_autoscroll()
  local state = self.autoscroll_state
  if not state then return end
  local host_visible = state.modal_host and modal_input_index(self, state.host)
    or self:view_at(state.x, state.y) == state.host
  local target = state.host and state.host.get_autoscroll_target
    and state.host:get_autoscroll_target(state.x, state.y)
  if not host_visible or target ~= state.view or self:modal_input_owner() ~= state then
    self:stop_autoscroll("surface no longer visible")
    return
  end
  local now = system.get_time()
  local dt = common.clamp(now - state.last_time, 0, 0.05)
  state.last_time = now
  local distance = (state.mouse_y - state.y) / SCALE
  local outside = math.max(0, math.abs(distance) - 12)
  if outside == 0 then state.remainder = 0; return end
  local speed = outside * (4 + outside / 8) * SCALE
  local dy = (distance < 0 and -speed or speed) * dt
  state.remainder = call_view(state.view, "autoscroll", dy + state.remainder) or 0
  core.request_cursor("sizev")
  core.redraw = true
end

function RootPanel:draw_autoscroll()
  local state = self.autoscroll_state
  if not state then return end
  local x, y, s = state.x, state.y, SCALE
  renderer.draw_rounded_rect(x - 12 * s, y - 16 * s, 24 * s, 32 * s, 12 * s, style.background2)
  renderer.draw_rect(x - s, y - s, 2 * s, 2 * s, style.text)
  for i = 0, 4 do
    local width = (1 + i * 2) * s
    renderer.draw_rect(x - width / 2, y - (11 - i) * s, width, s, style.text)
    renderer.draw_rect(x - width / 2, y + (10 - i) * s, width, s, style.text)
  end
end

function RootPanel:update()
  local started, scope = perf_begin("rootpanel_update")
  self:update_app_overlay()
  local layout_started, layout_scope = perf_begin("rootpanel_initial_layout")
  self:update_layout()
  perf_end("rootpanel_initial_layout", layout_started, layout_scope)
  self:update_autoscroll()
  local current = {}
  for _, view in ipairs(self:pane_views()) do
    current[view] = true
    call_view(view, "update")
  end
  for view in pairs(panes().suspended_services) do
    if not current[view] then
      call_view(view, "update_suspended")
    end
  end
  if not self.autoscroll_state and not self.grab and not self.dragged_divider then
    local hovered = self:view_at(self.mouse.x, self.mouse.y)
    if hovered ~= self.overlapping_view then
      if self.overlapping_view then call_view(self.overlapping_view, "on_mouse_left") end
      self.overlapping_view = hovered
      if hovered then
        call_view(hovered, "on_mouse_moved", self.mouse.x, self.mouse.y, 0, 0)
        request_view_cursor(hovered, self.mouse.x, self.mouse.y)
      end
    end
  end
  local target = core.active_window == core.window and system.window_has_focus(core.window)
    and self:keyboard_target() or nil
  -- Confirmations have their own button focus ring. Their View spans the content area, not just the card.
  if target == core.nag_view then target = nil end
  local pane = target and panes().pane_for_view(target)
  -- A new file in the same Pane keeps the same focus region. Compound Views use their focused child.
  local identity = pane and pane.current_view == target and pane or target
  local kind = self.focus_feedback_kind
  local active, changed, finished = self.focus_feedback:update(identity, nil, kind)
  -- A remote request can arrive before this Project gains keyboard focus.
  if target then self.focus_feedback_kind = nil end
  self.focus_feedback_view = target
  if active or changed or finished then core.redraw = true end
  if changed or (target and kind) then
    core.log_quiet("Focus feedback: target=%s kind=%s", tostring(target), kind or "standard")
  end
  local image_overlay = package.loaded["core.image_overlay"]
  if image_overlay then image_overlay.update() end
  local context_menu = package.loaded["core.context_menu"]
  if context_menu then context_menu.update() end
  perf_end("rootpanel_update", started, scope)
end

function RootPanel:update_suspended()
  for view in pairs(panes().suspended_services) do
    call_view(view, "update_suspended")
  end
end

function RootPanel:grab_mouse(button, view)
  self.grab = { button = button, view = view }
end

function RootPanel:ungrab_mouse(button)
  if self.grab and (not button or self.grab.button == button) then self.grab = nil end
end

function RootPanel:on_mouse_pressed(button, x, y, clicks)
  self.mouse.x, self.mouse.y = x, y
  if self.grab then self:on_mouse_released(self.grab.button, x, y) end
  local view = self:view_at(x, y)
  local group = panes().visible_group()
  if button == "left" and group then
    local divider = layout.divider_at(group.root, x, y, DIVIDER_TOLERANCE * SCALE)
    if divider and not scrollbar_owns_point(view, x, y) then
      self.dragged_divider = divider
      return true
    end
  end
  self.overlapping_view = view
  local pane = panes().pane_for_view(view) or (view and view.status_bar_pane)
  -- A click on the overlay beside the UI, such as over a hosted Sidebar, dismisses like one over a Pane.
  if not view and self.app_overlay then pane = panes().active() end
  if pane then panes().focus(pane) end
  if button == "middle" and view and view.get_autoscroll_target then
    local target = view:get_autoscroll_target(x, y)
    if target and self:start_autoscroll(target, x, y, view) then return true end
  end
  if view then self:grab_mouse(button, view) end
  return call_view(view, "on_mouse_pressed", button, x, y, clicks)
end

function RootPanel:on_mouse_released(button, x, y, ...)
  self.mouse.x, self.mouse.y = x, y
  if button == "left" and self.dragged_divider then
    self.dragged_divider = nil
    return true
  end
  local grabbed_view = self.grab and self.grab.view
  local view = grabbed_view or self:view_at(x, y)
  local result = call_view(view, "on_mouse_released", button, x, y, ...)
  self:ungrab_mouse(button)
  local hovered_view = self:view_at(x, y)
  if grabbed_view and grabbed_view ~= hovered_view then
    self:on_mouse_moved(x, y, 0, 0)
  end
  return result
end

function RootPanel:on_mouse_moved(x, y, dx, dy)
  self.mouse.x, self.mouse.y = x, y
  if self.dragged_divider then
    layout.resize(self.dragged_divider, { x = x, y = y })
    core.request_cursor(self.dragged_divider.axis == "x" and "sizeh" or "sizev")
    core.redraw = true
    return true
  end
  local view = self.grab and self.grab.view or self:view_at(x, y)
  if self.grab then
    local result = call_view(view, "on_mouse_moved", x, y, dx, dy)
    request_view_cursor(view, x, y)
    return result
  end
  local previous_view = self.overlapping_view
  self.overlapping_view = view
  if previous_view and previous_view ~= view then
    call_view(previous_view, "on_mouse_left")
  end
  local result = call_view(view, "on_mouse_moved", x, y, dx, dy)
  if view then request_view_cursor(view, x, y) end
  local group = panes().visible_group()
  local divider = group and layout.divider_at(
    group.root, x, y, DIVIDER_TOLERANCE * SCALE)
  if divider and not scrollbar_owns_point(view, x, y) then
    core.request_cursor(divider.axis == "x" and "sizeh" or "sizev")
  end
  return result
end

function RootPanel:on_mouse_left()
  local view = self.overlapping_view
  self.overlapping_view = nil
  -- Keep layout updates from restoring hover at the last position inside the surface.
  self.mouse.x, self.mouse.y = -math.huge, -math.huge
  if core.title_bar and core.title_bar ~= view then core.title_bar:on_mouse_left() end
  return call_view(view, "on_mouse_left")
end

function RootPanel:on_mouse_wheel(...)
  return call_view(self.overlapping_view or self:view_at(self.mouse.x, self.mouse.y), "on_mouse_wheel", ...)
end

function RootPanel:keyboard_target()
  if self:contains_view(core.active_view) then return core.active_view end
  local active_pane = panes().pane_for_view(core.active_view)
  if active_pane and active_pane.current_view then return core.active_view end
  local pane = panes().active()
  return pane and pane.current_view or nil
end

function RootPanel:on_text_input(...)
  return call_view(self:keyboard_target(), "on_text_input", ...)
end

function RootPanel:on_key_pressed(...)
  return call_view(self:keyboard_target(), "on_key_pressed", ...)
end

function RootPanel:on_key_released(...)
  return call_view(self:keyboard_target(), "on_key_released", ...)
end

function RootPanel:on_ime_text_editing(...)
  return call_view(self:keyboard_target(), "on_ime_text_editing", ...)
end

function RootPanel:on_focus_lost(...)
  self:stop_autoscroll("window focus lost")
  local context_menu = package.loaded["core.context_menu"]
  if context_menu then context_menu.on_focus_lost() end
  core.redraw = true
  local target = self:keyboard_target()
  local grabbed = self.grab and self.grab.view or nil
  if grabbed and grabbed ~= target then call_view(grabbed, "on_focus_lost", ...) end
  return call_view(target, "on_focus_lost", ...)
end

function RootPanel:on_touch_pressed(x, y, ...)
  self.touched_view = self:view_at(x, y)
  return call_view(self.touched_view, "on_touch_pressed", x, y, ...)
end

function RootPanel:on_touch_released(x, y, ...)
  local view = self.touched_view
  self.touched_view = nil
  return call_view(view, "on_touch_released", x, y, ...)
end

function RootPanel:on_touch_moved(x, y, ...)
  return call_view(self.touched_view, "on_touch_moved", x, y, ...)
end

function RootPanel:resolve_external_drop_target(x, y)
  if not x or not y or self:modal_input_owner() then return end
  local title = core.title_bar
  if title and title.get_external_drop_target then
    local target = title:get_external_drop_target(x, y)
    if target then return target end
    if y < title.position.y + title.size.y then return end
  end
  local group = panes().visible_group()
  local pane = group and layout.pane_at(group.root, x, y)
  if pane then
    return { kind = "current", pane = pane }
  elseif not group then
    local rect = self.content_rect
    if rect and x >= rect.x and x < rect.x + rect.w
      and y >= rect.y and y < rect.y + rect.h then
      return { kind = "new", area = "work", rect = rect }
    end
  end
end

function RootPanel:get_external_drop_target()
  local drop = self.external_drop
  if not drop then return end
  local target = self:resolve_external_drop_target(drop.x, drop.y)
  if target and target.kind == "current" then
    target.caret = call_view(target.pane.current_view, "get_drop_caret", drop.x, drop.y)
  end
  return target
end

function RootPanel:on_drop_begin()
  self.external_drop = { files = {}, seen = {}, text = {} }
  core.redraw = true
  core.log_quiet("External drop: began")
end

function RootPanel:on_drop_moved(x, y)
  if not self.external_drop then self:on_drop_begin() end
  self.external_drop.x, self.external_drop.y = x, y
  core.redraw = true
end

function RootPanel:on_text_dropped(text, x, y)
  if not self.external_drop then self:on_drop_begin() end
  self:on_drop_moved(x, y)
  self.external_drop.text[#self.external_drop.text + 1] = text
end

function RootPanel:on_drop_complete()
  local drop = self.external_drop
  local target = self:get_external_drop_target()
  self.external_drop = nil
  core.redraw = true
  if not drop or not target then
    core.log_quiet("External drop: cancelled or outside a drop target")
    return
  end
  core.log_quiet("External drop: completed target=%s files=%d text_parts=%d",
    target.kind, #drop.files, #drop.text)
  local text = table.concat(drop.text):gsub("\r\n", "\n"):gsub("\r", "\n")
  if target.kind == "current" and self:deliver_drop_to_view(target.pane, {
    files = drop.files, text = text, x = drop.x, y = drop.y,
  }) then
    return
  end
  local opened, failed = 0, 0
  for _, filename in ipairs(drop.files) do
    if self:open_dropped_file(filename, drop.x, drop.y, target) then
      opened = opened + 1
    else
      failed = failed + 1
    end
  end
  if target.kind == "new" then
    if text ~= "" then
      local Buffer = require "core.buffer"
      local buffer = Buffer(nil, nil, true)
      buffer:insert(1, 1, text)
      if self:open_buffer(buffer, { placement = "new", reason = "text-drop" }) then
        opened = opened + 1
      end
    end
  end
  if target.kind == "new" and opened > 0 and failed == 0 and core.status_bar then
    core.status_bar:show_message(style.log.INFO.icon, style.drop_target_accent, opened == 1
      and "Opened in a new Pane" or string.format("Opened %d items in new Panes", opened))
  end
end

function RootPanel:on_file_dropped(filename, x, y)
  if self.external_drop then
    self:on_drop_moved(x, y)
    local path = system.absolute_path(filename) or filename
    if not self.external_drop.seen[path] then
      self.external_drop.seen[path] = true
      self.external_drop.files[#self.external_drop.files + 1] = path
    end
    return true
  end
  local title = core.title_bar
  if title and title.get_external_drop_target and x and y
    and y >= title.position.y and y < title.position.y + title.size.y then
    local target = self:resolve_external_drop_target(x, y)
    if not target then return false end
    return self:open_dropped_file(filename, x, y, target)
  end
  local group = panes().visible_group()
  local pane = group and x and y and layout.pane_at(group.root, x, y)
  if pane and self:deliver_drop_to_view(pane, {
    files = { system.absolute_path(filename) or filename }, text = "", x = x, y = y,
  }) then
    return true
  end
  return self:open_dropped_file(filename, x, y)
end

function RootPanel:deliver_drop_to_view(pane, drop)
  local view = pane.current_view
  if not call_view(view, "on_drop", drop) then return false end
  core.log_quiet("External drop: consumed by %s files=%d text_bytes=%d",
    tostring(view), #drop.files, #drop.text)
  panes().focus(pane)
  return true
end

function RootPanel:open_dropped_file(filename, x, y, target)
  if target and target.kind == "new" then
    local info, err = system.get_file_info(filename)
    if not info or (info.type ~= "dir" and info.type ~= "file") then
      core.error("Could not open dropped path: %s (%s)", filename, tostring(err or "unsupported path"))
      return false
    end
    local view
    if info.type == "dir" then
      view, err = require("plugins.filetree").open(filename, {
        placement = "new", reason = "directory-drop",
      })
    else
      view, err = core.open_file(filename, { placement = "new", reason = "file-drop" })
    end
    if view == nil then core.error("Could not open dropped path: %s (%s)", filename, tostring(err)) end
    core.log_quiet("External drop: new Pane path=%s opened=%s", filename, tostring(view ~= nil))
    return view
  end
  local group = panes().visible_group()
  local hit_pane = target and target.pane or (group and x and y and layout.pane_at(group.root, x, y))
  local target_pane = hit_pane or panes().active()
  local info = system.get_file_info(filename)
  if info and info.type == "dir" then
    local path = system.absolute_path(filename) or filename
    local function add_to_window() core.add_project(path) end
    if core.nag_view and core.nag_view.show then
      core.nag_view:show(
        "Open Project Directory",
        string.format('Add "%s" to this window or open it in a new window?', path),
        {
          { text = "Current window", default_yes = true },
          { text = "New window", default_no = true },
          { text = "Cancel" },
        },
        function(option)
          if option.text == "Current window" then
            add_to_window()
          elseif option.text == "New window" then
            core.open_project_in_new_window(path)
          end
        end
      )
    else
      add_to_window()
    end
    return true
  end
  if core.open_file then
    return core.open_file(filename, {
      pane = target_pane, placement = "current", reason = "file-drop",
    })
  end
end

local function draw_split_dividers(node)
  if not node or node.kind ~= "split" or not node.rect then return end
  local color = style.divider or style.background3 or style.background2
  if node.axis == "x" then
    local x = node.rect.x + node.rect.w * node.ratio
    renderer.draw_rect(x - 1, node.rect.y, 2, node.rect.h, color)
  else
    local y = node.rect.y + node.rect.h * node.ratio
    renderer.draw_rect(node.rect.x, y - 1, node.rect.w, 2, color)
  end
  draw_split_dividers(node.a)
  draw_split_dividers(node.b)
end

-- Replace existing content in one region with the window-aligned wallpaper.
-- The backdrop covers the whole window surface, including a hosted Project's area under the Sidebar.
function RootPanel:backdrop_rect()
  return 0, 0, self.position.x + self.size.x, self.position.y + self.size.y
end

function RootPanel:draw_wallpaper_region(x, y, width, height)
  if width <= 0 or height <= 0 then return end
  if not self.wallpaper then
    renderer.draw_rect(x, y, width, height, style.background)
    return
  end
  local bx, by, bw, bh = self:backdrop_rect()
  local clipped = x ~= bx or y ~= by or width ~= bw or height ~= bh
  if clipped then core.push_clip_rect(x, y, width, height) end
  local iw, ih = self.wallpaper:get_size()
  local scale = math.max(bw / iw, bh / ih)
  local w, h = iw * scale, ih * scale
  renderer.draw_canvas_scaled(self.wallpaper, bx + (bw - w) / 2, by + (bh - h) / 2, w, h)
  if clipped then core.pop_clip_rect() end
  renderer.draw_rect(x, y, width, height,
    style.wallpaper_surface(style.background, self.wallpaper_backdrop_opacity))
end

function RootPanel:draw_wallpaper(has_pane_view)
  local selected = wallpapers.current()
  if selected == "none" then
    self.wallpaper = nil
    self.wallpaper_name = nil
    self.wallpaper_contrast_image = nil
    self.wallpaper_visibility = nil
    self.wallpaper_backdrop_opacity = nil
    local x, y, w, h = self:backdrop_rect()
    renderer.draw_rect(x, y, w, h, style.background)
    return
  end
  if self.wallpaper_name ~= selected then
    local path = wallpapers.path(selected)
    local image, err = canvas.load_image(path)
    self.wallpaper = image or false
    self.wallpaper_name = selected
    if image then
      core.log_quiet("Window wallpaper loaded: %s", path)
    else
      core.log_quiet("Window wallpaper unavailable: %s (%s)", path, tostring(err))
    end
  end
  if not self.wallpaper then
    self:draw_wallpaper_region(self:backdrop_rect())
    return
  end
  if self.wallpaper_contrast_image ~= self.wallpaper then
    self.wallpaper_contrast_image = self.wallpaper
    self.wallpaper_sample_low, self.wallpaper_sample_high, self.wallpaper_sample_mid =
      wallpaper_contrast.sample(self.wallpaper)
    self.wallpaper_contrast_generation = nil
  end
  if not self.wallpaper_visibility or self.wallpaper_contrast_generation ~= core.color_theme_generation then
    self.wallpaper_visibility = wallpaper_contrast.visibility(
      self.wallpaper_sample_low, self.wallpaper_sample_high, self.wallpaper_sample_mid,
      style.background,
      style.wallpaper_reference_background, style.wallpaper_reference_visibility)
    self.wallpaper_contrast_generation = core.color_theme_generation
    core.log_quiet("Window wallpaper theme visibility: %.1f%% generation=%s",
      self.wallpaper_visibility * 100, tostring(core.color_theme_generation))
  end
  -- With a View, both fills attenuate the image. Without one, the root does it alone.
  self.wallpaper_backdrop_opacity = 1 - self.wallpaper_visibility
    / (has_pane_view and (1 - style.wallpaper_surface_opacity) or 1)
  self:draw_wallpaper_region(self:backdrop_rect())
end

function RootPanel:draw()
  local started, scope = perf_begin("rootpanel_core_draw")
  self:begin_keyboard_caret_frame()
  self.caret_layer, self.caret_drawn = CARET_LAYER_VIEWS, false
  local pane_views = self:pane_views()
  self.above_sidebar = {}
  self:draw_wallpaper(#pane_views > 0)
  local group = panes().visible_group()
  for _, view in ipairs(pane_views) do
    core.push_clip_rect(view.position.x, view.position.y, view.size.x, view.size.y)
    call_view(view, "draw")
    core.pop_clip_rect()
  end
  for _, bar in ipairs(self:pane_status_bars()) do call_view(bar, "draw") end
  if group then draw_split_dividers(group.root) end
  for _, view in ipairs(self:shell_views()) do call_view(view, "draw") end
  end_caret_layer(self)
  local overlay_started, overlay_scope = perf_begin("rootpanel_overlays_draw")
  self:draw_active_app_overlay()
  local drop_target = self:get_external_drop_target()
  local drop_caret = drop_target and drop_target.caret
  if drop_caret then
    local view = drop_target.pane.current_view
    core.push_clip_rect(view.position.x, view.position.y, view.size.x, view.size.y)
    renderer.draw_rect(drop_caret.x, drop_caret.y, math.max(drop_caret.w, common.round(2 * SCALE)),
      drop_caret.h, style.drop_target_accent)
    core.pop_clip_rect()
  elseif drop_target and drop_target.area ~= "titlebar" then
    local pane = drop_target.pane
    local rect = drop_target.rect or {
      x = pane.position.x, y = pane.position.y, w = pane.size.x, h = pane.size.y,
    }
    local x, y, w, h = rect.x, rect.y, rect.w, rect.h
    local stroke = math.max(1, SCALE)
    core.push_clip_rect(x, y, w, h)
    renderer.draw_rect(x, y, w, h, style.drop_target_background)
    renderer.draw_rect(x, y, w, stroke, style.drop_target_accent)
    renderer.draw_rect(x, y + h - stroke, w, stroke, style.drop_target_accent)
    renderer.draw_rect(x, y, stroke, h, style.drop_target_accent)
    renderer.draw_rect(x + w - stroke, y, stroke, h, style.drop_target_accent)
    local text = drop_target.kind == "new" and "Drop to open in new Panes"
      or "Drop here"
    local font = style.view_text_font
    if font:get_width(text) + style.padding.x * 2 > w then text = "Drop here" end
    local width = math.min(w, font:get_width(text) + style.padding.x * 2)
    local height = font:get_height() + style.padding.y * 2
    local label_x, label_y = x + (w - width) / 2, y + (h - height) / 2
    renderer.draw_rounded_rect(label_x, label_y, width, height, 6 * SCALE, style.background2)
    common.draw_text(font, style.text, text, "center", label_x, label_y, width, height)
    core.pop_clip_rect()
  end
  local navigation_history = package.loaded["core.navigation_history"]
  if navigation_history then navigation_history.draw_feedback(self) end
  perf_end("rootpanel_overlays_draw", overlay_started, overlay_scope)
  end_caret_layer(self)
  local deferred_started, deferred_scope = perf_begin("rootpanel_deferred_draw")
  while #self.deferred_draws > 0 do
    local item = table.remove(self.deferred_draws)
    item.fn(table.unpack(item, 1, #item))
  end
  perf_end("rootpanel_deferred_draw", deferred_started, deferred_scope)
  end_caret_layer(self)
  local focused = self.focus_feedback_view
  if focused then
    core.push_clip_rect(focused.position.x, focused.position.y, focused.size.x, focused.size.y)
    self.focus_feedback:draw(focused.position.x, focused.position.y, focused.size.x, focused.size.y)
    core.pop_clip_rect()
  end
  local image_overlay = package.loaded["core.image_overlay"]
  if image_overlay then image_overlay.draw() end
  local context_menu = package.loaded["core.context_menu"]
  if context_menu then context_menu.draw() end
  self:publish_surface_overlay()
  end_caret_layer(self)
  self:draw_autoscroll()
  if core.cursor_change_req then
    system.set_cursor(core.cursor_change_req)
    core.cursor_change_req = nil
  end
  perf_end("rootpanel_core_draw", started, scope)
end

return RootPanel
