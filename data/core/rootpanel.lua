local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local Node = require "core.node"
local View = require "core.view"
local Editor = require "core.editor"
local file_context = require "core.file_context"

---@class core.rootpanel.overlay.to
---@field x number
---@field y number
---@field w number
---@field h number

---@class core.rootpanel.overlay
---@field x number
---@field y number
---@field w number
---@field h number
---@field visible boolean
---@field opacity number
---@field base_color renderer.color
---@field color renderer.color
---@field to core.rootpanel.overlay.to

---@class core.rootpanel.appoverlay
---@field owner any
---@field color renderer.color|string Overlay color or style key
---@field unobscured_view core.view?
---@field transition_name string?
---@field progress number Linear fade progress in [0, 1]
---@field target number Target fade progress (0 or 1)
---@field last_time number Last animation update timestamp

---@class core.rootpanel.mousegrab
---@field view core.view
---@field button core.view.mousebutton

---Root Panel: top-level UI container for the editor window.
---Coordinates the layout tree, handles drag & drop, and routes events to child views.
---@class core.rootpanel : core.view
---@overload fun():core.rootpanel
---@field super core.view
---@field root_node core.node
---@field mouse core.view.position
---@field drag_overlay core.rootpanel.overlay
---@field drag_overlay_tab core.rootpanel.overlay
---@field grab core.rootpanel.mousegrab?
---@field deferred_draws table[]
---@field app_overlay core.rootpanel.appoverlay?
---@field overlapping_view core.view?
---@field touched_view core.view?
---@field defer_open_buffers table[]
---@field first_dnd_processed boolean
---@field first_update_done boolean
local RootPanel = View:extend()

local APP_OVERLAY_FADE_DURATION = 0.08

local function perf_frame_add(key, amount)
  local perf = package.loaded["core.perf"]
  if perf and perf.frame_add then perf.frame_add(key, amount or 1) end
end

local function perf_elapsed(key, start_time)
  if start_time then perf_frame_add(key, (system.get_time() - start_time) * 1000) end
end

local function perf_scope_begin(name, capture_heap)
  if not core.perf_draw_scope_active then return nil end
  local perf = package.loaded["core.perf"]
  return perf and perf.scope_begin and perf.scope_begin(name, capture_heap) or nil
end

local function perf_scope_end(token)
  if not token then return end
  local perf = package.loaded["core.perf"]
  if perf and perf.scope_end then perf.scope_end(token) end
end

function RootPanel:__tostring() return "RootPanel" end

local function call_view_method(view, method, ...)
  if view and view.with_selection_state then
    return view:with_selection_state(method, view, ...)
  end
  return method(view, ...)
end

local function log_hex_bytes(text, max_bytes)
  text = tostring(text or "")
  max_bytes = max_bytes or 256
  local bytes = {}
  local count = math.min(#text, max_bytes)
  for i = 1, count do
    bytes[#bytes + 1] = string.format("%02X", text:byte(i))
  end
  if #text > count then
    bytes[#bytes + 1] = string.format("...(+%d bytes)", #text - count)
  end
  return table.concat(bytes, " ")
end

local function quote_drop_text(text)
  text = tostring(text or "")
  return '"' .. text:gsub('[%z\1-\31\127-\255\\"]', function(ch)
    if ch == "\\" then return "\\\\" end
    if ch == '"' then return '\\"' end
    if ch == "\n" then return "\\n" end
    if ch == "\r" then return "\\r" end
    if ch == "\t" then return "\\t" end
    return string.format("\\x%02X", ch:byte())
  end) .. '"'
end

local function log_file_drop(stage, filename, x, y, detail)
  local path = tostring(filename or "")
  core.log_quiet(
    "File drop: %s path=%s bytes=%d hex=%s x=%s y=%s%s",
    stage,
    quote_drop_text(path),
    #path,
    log_hex_bytes(path),
    tostring(x),
    tostring(y),
    detail and (" " .. detail) or ""
  )
end

---Constructor - initializes the root node tree and UI state.
---Called automatically by core at startup.
function RootPanel:new()
  RootPanel.super.new(self)
  self.root_node = Node()
  self.root_node.pane_id = "left"
  self.deferred_draws = {}
  self.app_overlay = nil
  self.mouse = { x = 0, y = 0 }
  self.drag_overlay = { x = 0, y = 0, w = 0, h = 0, visible = false, opacity = 0,
                        base_color = style.drag_overlay,
                        color = { table.unpack(style.drag_overlay) } }
  self.drag_overlay.to = { x = 0, y = 0, w = 0, h = 0 }
  self.drag_overlay_tab = { x = 0, y = 0, w = 0, h = 0, visible = false, opacity = 0,
                            base_color = style.drag_overlay_tab,
                            color = { table.unpack(style.drag_overlay_tab) } }
  self.drag_overlay_tab.to = { x = 0, y = 0, w = 0, h = 0 }
  self.grab = nil -- = {view = nil, button = nil}
  self.overlapping_view = nil
  self.touched_view = nil
  self.defer_open_buffers = {}
  self.first_dnd_processed = false
  self.first_update_done = false
end


---Queue a drawing operation to execute after main scene is rendered.
---Useful for overlays, tooltips, or drag indicators that should draw on top.
---@param fn function Function to call for drawing
---@param ... any Arguments to pass to the function
function RootPanel:defer_draw(fn, ...)
  table.insert(self.deferred_draws, 1, { fn = fn, ... })
end


local function quadratic_ease_in_out(progress)
  if progress < 0.5 then return 2 * progress * progress end
  local remaining = 1 - progress
  return 1 - 2 * remaining * remaining
end


---Advance the shared application-overlay animation.
---@param now? number Current timestamp, primarily for deterministic callers
---@return number progress
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
    local elapsed = math.max(0, now - overlay.last_time)
    local direction = overlay.target > progress and 1 or -1
    progress = common.clamp(
      progress + direction * elapsed / APP_OVERLAY_FADE_DURATION,
      0,
      1
    )
  end

  overlay.last_time = now
  if progress ~= overlay.progress then
    overlay.progress = progress
    core.redraw = true
  end
  if overlay.target == 0 and progress == 0 then
    self.app_overlay = nil
  end
  return progress
end


---Show or take over the shared application attention overlay.
---A takeover preserves the current fade progress so transitions between
---attention-demanding surfaces do not flash or stack multiple dimmers.
---@param owner any Stable owner identity
---@param color renderer.color|string Overlay color or key in core.style
---@param options? { unobscured_view?:core.view, transition_name?:string }
function RootPanel:show_app_overlay(owner, color, options)
  assert(owner ~= nil, "app overlay owner is required")
  options = options or {}
  local now = system.get_time()
  self:update_app_overlay(now)
  local overlay = self.app_overlay
  if not overlay then
    overlay = { progress = 0, target = 0, last_time = now }
    self.app_overlay = overlay
  end
  overlay.owner = owner
  overlay.color = color
  overlay.unobscured_view = options.unobscured_view
  overlay.transition_name = options.transition_name
  overlay.target = 1
  overlay.last_time = now
  core.redraw = true
end


---Fade out the shared application attention overlay if owned by the caller.
---@param owner any Stable owner identity
---@return boolean hidden Whether this owner controlled the overlay
function RootPanel:hide_app_overlay(owner)
  local overlay = self.app_overlay
  if not overlay or overlay.owner ~= owner then return false end
  local now = system.get_time()
  self:update_app_overlay(now)
  overlay = self.app_overlay
  if not overlay or overlay.owner ~= owner then return false end
  overlay.target = 0
  overlay.unobscured_view = nil
  overlay.last_time = now
  core.redraw = true
  return true
end


---Dim the application behind an attention-demanding surface.
---When an unobscured view is supplied, the overlay is drawn around that view.
---@param color renderer.color Overlay color
---@param unobscured_view core.view? View that should remain undimmed
function RootPanel:draw_app_overlay(color, unobscured_view)
  local root_left = self.position.x
  local root_top = self.position.y
  local root_right = root_left + self.size.x
  local root_bottom = root_top + self.size.y

  if not unobscured_view then
    renderer.draw_rect(root_left, root_top, self.size.x, self.size.y, color)
    return
  end

  local view_left = common.clamp(unobscured_view.position.x, root_left, root_right)
  local view_top = common.clamp(unobscured_view.position.y, root_top, root_bottom)
  local view_right = common.clamp(
    unobscured_view.position.x + unobscured_view.size.x, root_left, root_right
  )
  local view_bottom = common.clamp(
    unobscured_view.position.y + unobscured_view.size.y, root_top, root_bottom
  )

  if view_right <= root_left or view_left >= root_right
    or view_bottom <= root_top or view_top >= root_bottom
  then
    renderer.draw_rect(root_left, root_top, self.size.x, self.size.y, color)
    return
  end

  if view_top > root_top then
    renderer.draw_rect(root_left, root_top, self.size.x, view_top - root_top, color)
  end
  if view_bottom < root_bottom then
    renderer.draw_rect(root_left, view_bottom, self.size.x, root_bottom - view_bottom, color)
  end

  local middle_height = view_bottom - view_top
  if view_left > root_left and middle_height > 0 then
    renderer.draw_rect(root_left, view_top, view_left - root_left, middle_height, color)
  end
  if view_right < root_right and middle_height > 0 then
    renderer.draw_rect(view_right, view_top, root_right - view_right, middle_height, color)
  end
end


---Draw the current shared application attention overlay at its eased opacity.
function RootPanel:draw_active_app_overlay()
  local overlay = self.app_overlay
  if not overlay or overlay.progress <= 0 then return end
  local source = type(overlay.color) == "string" and style[overlay.color] or overlay.color
  if type(source) ~= "table" then return end
  local color = { table.unpack(source) }
  color[4] = (color[4] or 255) * quadratic_ease_in_out(overlay.progress)
  self:draw_app_overlay(color, overlay.unobscured_view)
end


---Get the layout node containing the currently active view.
---Falls back to the Left Pane if active view is not found.
---@return core.node node Node containing active view or the Left Pane node
function RootPanel:get_active_node()
  local active = core.active_view
  local node = self.root_node:get_node_for_view(active)
  if not node and active then
    local owner = active.__pane_focus_owner or active.git_owner_view or active.diff_view_parent
    if owner then node = self.root_node:get_node_for_view(owner) end
  end
  if not node then node = self:get_left_pane() end
  return node
end


---Find the Left Pane node in the layout tree recursively.
---@param node core.node Node to search from
---@return core.node node The Left Pane node
local function get_left_pane(node)
  if not node then return nil end
  if node.pane_id == "left" then
    return node
  end
  if node.type ~= "leaf" then
    return get_left_pane(node.a) or get_left_pane(node.b)
  end
end

local function get_first_leaf(node, prefer_unlocked)
  if not node then return nil end
  if node.type == "leaf" then
    if not prefer_unlocked then return node end
    local lx, ly = node.get_locked_size and node:get_locked_size()
    if not lx and not ly then return node end
    return nil
  end
  return get_first_leaf(node.a, prefer_unlocked) or get_first_leaf(node.b, prefer_unlocked)
end


---Get the active node, ensuring it's not locked.
---If active node is locked, switches to the Left Pane instead.
---Use this when adding new views to ensure they go to an editable node.
---@return core.node node Unlocked node suitable for adding views
function RootPanel:get_active_node_default()
  local active = core.active_view
  local node = self.root_node:get_node_for_view(active)
  if not node and active then
    local owner = active.__pane_focus_owner or active.git_owner_view or active.diff_view_parent
    if owner then node = self.root_node:get_node_for_view(owner) end
  end
  if not node then node = self:get_left_pane() end
  if node and node.locked then
    local left_pane = self:get_left_pane()
    local default_view = left_pane and left_pane.views[1]
    assert(default_view, "internal error: cannot find Left Pane node.")
    core.set_active_view(default_view)
    node = self:get_active_node()
  end
  return node
end


---Get the permanent Left Pane node.
---@return core.node node The Left Pane node
function RootPanel:get_left_pane()
  return get_left_pane(self.root_node)
      or get_first_leaf(self.root_node, true)
      or get_first_leaf(self.root_node, false)
end


---Open a buffer in one explicit layout node.
---If buffer is already open, switches to that view instead.
---Creates a new TextView and adds it as a tab in the target node.
---@param buffer core.buffer Buffer to open
---@param opts? table Options. opts.source_view copies scroll/selection from another TextView; opts.node targets a specific leaf node.
---@return core.textview view The view displaying the buffer
function RootPanel:open_buffer_in_node(buffer, opts)
  opts = opts or {}
  local node = opts.node or self:get_active_node_default()
  for i, view in ipairs(node.views) do
    if view.buffer == buffer then
      node:set_active_view(node.views[i])
      return view
    end
  end
  local view = Editor(buffer)
  if opts.source_view and opts.source_view.buffer == buffer and opts.source_view.get_selection_state then
    view:set_selection_state(opts.source_view:get_selection_state())
    view.scroll.x = opts.source_view.scroll.x or 0
    view.scroll.to.x = opts.source_view.scroll.to.x or opts.source_view.scroll.x or 0
    view.scroll.y = opts.source_view.scroll.y or 0
    view.scroll.to.y = opts.source_view.scroll.to.y or opts.source_view.scroll.y or 0
  end
  node:add_view(view)
  self.root_node:update_layout()
  local line = view.selection_state and view.selection_state.selections[1] or view.buffer:get_selection()
  view:scroll_to_line(line, true, true)
  return view
end

function RootPanel:open_buffer(buffer, opts)
  return require("core.panes").open_buffer(buffer, opts)
end


---Close all tabs/views in the node tree.
---Used by explicit tab closing commands.
---@param keep_view core.view? View to keep open
function RootPanel:close_all_views(keep_view)
  self.root_node:close_all_views(keep_view)
end

---Close all Text Views in the node tree.
---Used when closing a project or switching workspaces.
---@param keep_active boolean If true, keeps the currently active view open
function RootPanel:close_all_textviews(keep_active)
  self.root_node:close_all_textviews(keep_active)
end


---Capture mouse input for a specific view.
---All mouse events for the specified button will be routed to this view,
---even when the mouse moves outside the view's bounds.
---Only one grab can be active per button at a time.
---Common use: drag operations, scrollbar dragging, text selection.
---@param button core.view.mousebutton Button to grab
---@param view core.view View that should receive mouse events
function RootPanel:grab_mouse(button, view)
  assert(self.grab == nil)
  self.grab = {view = view, button = button}
end


---Release mouse grab for the specified button.
---Button must match the button that was grabbed.
---After release, normal mouse event routing resumes.
---@param button core.view.mousebutton Button to release (must match grabbed button)
function RootPanel:ungrab_mouse(button)
  assert(self.grab and self.grab.button == button)
  self.grab = nil
end


---Hook function called before mouse pressed events reach the active view.
---Override this to intercept or modify mouse press behavior globally.
---Default implementation does nothing.
---@param button core.view.mousebutton
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@param clicks integer Number of clicks
function RootPanel.on_view_mouse_pressed(button, x, y, clicks)
end


---Handle mouse press events and route to appropriate targets.
---Manages: divider dragging, tab clicking/dragging, view activation, event routing.
---Overrides base View implementation to handle complex UI interactions.
---@param button core.view.mousebutton
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@param clicks integer Number of clicks
---@return boolean handled True if event was handled
function RootPanel:on_mouse_pressed(button, x, y, clicks)
  -- If there is a grab, release it first
  if self.grab then
    self:on_mouse_released(self.grab.button, x, y)
  end
  local div = self.root_node:get_divider_overlapping_point(x, y)
  local node = self.root_node:get_child_overlapping_point(x, y)
  if div and (node and not node.active_view:scrollbar_overlaps_point(x, y)) then
    self.dragged_divider = div
    return true
  end
  if node.hovered_scroll_button > 0 then
    node:scroll_tabs(node.hovered_scroll_button)
    return true
  end
  local idx = node:get_tab_overlapping_point(x, y)
  if idx then
    if button == "middle" then
      node:close_view(self.root_node, node.views[idx])
      return true
    else
      if button == "left" then
        self.dragged_node = { node = node, idx = idx, dragging = false, drag_start_x = x, drag_start_y = y}
      end
      node:set_active_view(node.views[idx])
      return true
    end
  elseif not self.dragged_node then -- avoid sending on_mouse_pressed events when dragging tabs
    core.set_active_view(node.active_view)
    self:grab_mouse(button, node.active_view)
    return self.on_view_mouse_pressed(button, x, y, clicks)
      or call_view_method(node.active_view, node.active_view.on_mouse_pressed, button, x, y, clicks)
  end
end


---Get the base color for a drag overlay.
---Internal helper to fetch color from style based on overlay type.
---@param overlay core.rootpanel.overlay The overlay to get color for
---@return renderer.color color The base color from style
function RootPanel:get_overlay_base_color(overlay)
  if overlay == self.drag_overlay then
    return style.drag_overlay
  else
    return style.drag_overlay_tab
  end
end


---Show or hide a drag overlay with color reset.
---Internal helper for managing drag visual feedback state.
---@param overlay core.rootpanel.overlay The overlay to show/hide
---@param status boolean True to show, false to hide
function RootPanel:set_show_overlay(overlay, status)
  overlay.visible = status
  if status then -- reset colors
    -- reload base_color
    overlay.base_color = self:get_overlay_base_color(overlay)
    overlay.color[1] = overlay.base_color[1]
    overlay.color[2] = overlay.base_color[2]
    overlay.color[3] = overlay.base_color[3]
    overlay.color[4] = overlay.base_color[4]
    overlay.opacity = 0
  end
end


---Handle mouse button release events.
---Manages: mouse grab release, divider drag completion, tab drop/rearrange.
---Handles complex tab drag-and-drop logic (split, move, reorder).
---@param button core.view.mousebutton
---@param x number Screen x coordinate
---@param y number Screen y coordinate
function RootPanel:on_mouse_released(button, x, y, ...)
  if self.grab then
    if self.grab.button == button then
      local grabbed_view = self.grab.view
      call_view_method(grabbed_view, grabbed_view.on_mouse_released, button, x, y, ...)
      self:ungrab_mouse(button)

      -- If the mouse was released over a different view, send it the mouse position
      local hovered_view = self.root_node:get_child_overlapping_point(x, y)
      if grabbed_view ~= hovered_view then
        self:on_mouse_moved(x, y, 0, 0)
      end
    end
    return
  end

  if self.dragged_divider then
    self.dragged_divider = nil
  end
  if self.dragged_node then
    if button == "left" then
      if self.dragged_node.dragging then
        local node = self.root_node:get_child_overlapping_point(self.mouse.x, self.mouse.y)
        local dragged_node = self.dragged_node.node

        if node and not node.locked
           -- don't do anything if dragging onto own node, with only one view
           and (node ~= dragged_node or #node.views > 1) then
          local split_type = node:get_split_type(self.mouse.x, self.mouse.y)
          local view = dragged_node.views[self.dragged_node.idx]

          if split_type ~= "middle" and split_type ~= "tab" then -- needs splitting
            local new_node = node:split(split_type)
            self.root_node:get_node_for_view(view):remove_view(self.root_node, view)
            new_node:add_view(view)
          elseif split_type == "middle" and node ~= dragged_node then -- move to other node
            dragged_node:remove_view(self.root_node, view)
            node:add_view(view)
            self.root_node:get_node_for_view(view):set_active_view(view)
          elseif split_type == "tab" then -- move besides other tabs
            local tab_index = node:get_drag_overlay_tab_position(self.mouse.x, self.mouse.y, dragged_node, self.dragged_node.idx)
            dragged_node:remove_view(self.root_node, view)
            node:add_view(view, tab_index)
            self.root_node:get_node_for_view(view):set_active_view(view)
          end
          self.root_node:update_layout()
          core.redraw = true
        end
      end
      self:set_show_overlay(self.drag_overlay, false)
      self:set_show_overlay(self.drag_overlay_tab, false)
      if self.dragged_node and self.dragged_node.dragging then
        core.request_cursor("arrow")
      end
      self.dragged_node = nil
    end
  end
end


---Resize split node children when dragging divider.
---Tries resizing locked nodes first, falls back to proportional divider adjustment.
---@param node core.node The split node being resized
---@param axis string "x" or "y"
---@param value number New size value for the split
---@param delta number Mouse movement delta
local function resize_child_node(node, axis, value, delta)
  local accept_resize = node.a:resize(axis, value)
  if not accept_resize then
    accept_resize = node.b:resize(axis, node.size[axis] - value)
  end
  if not accept_resize then
    node.divider = node.divider + delta / node.size[axis]
  end
end


---Handle mouse movement events and route appropriately.
---Manages: grabbed view routing, divider dragging, tab drag start, cursor changes.
---Updates overlapping_view for hover state tracking.
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@param dx number Delta x since last move
---@param dy number Delta y since last move
function RootPanel:on_mouse_moved(x, y, dx, dy)
  self.mouse.x, self.mouse.y = x, y

  if self.grab then
    call_view_method(self.grab.view, self.grab.view.on_mouse_moved, x, y, dx, dy)
    core.request_cursor(self.grab.view.cursor)
    return
  end

  if core.active_view == core.nag_view then
    core.request_cursor("arrow")
    core.active_view:on_mouse_moved(x, y, dx, dy)
    return
  end

  if self.dragged_divider then
    local node = self.dragged_divider
    if node.type == "hsplit" then
      x = common.clamp(x - node.position.x, 0, self.root_node.size.x * 0.95)
      resize_child_node(node, "x", x, dx)
    elseif node.type == "vsplit" then
      y = common.clamp(y - node.position.y, 0, self.root_node.size.y * 0.95)
      resize_child_node(node, "y", y, dy)
    end
    node.divider = common.clamp(node.divider, 0.01, 0.99)
    return
  end

  local dn = self.dragged_node
  if dn and not dn.dragging then
    -- start dragging only after enough movement
    dn.dragging = common.distance(x, y, dn.drag_start_x, dn.drag_start_y) > style.tab_width * .05
    if dn.dragging then
      core.request_cursor("hand")
    end
  end

  -- avoid sending on_mouse_moved events when dragging tabs
  if dn then return end

  local last_overlapping_view = self.overlapping_view
  local overlapping_node = self.root_node:get_child_overlapping_point(x, y)
  self.overlapping_view = overlapping_node and overlapping_node.active_view

  if last_overlapping_view and last_overlapping_view ~= self.overlapping_view then
    last_overlapping_view:on_mouse_left()
  end

  if not self.overlapping_view then return end

  call_view_method(self.overlapping_view, self.overlapping_view.on_mouse_moved, x, y, dx, dy)
  core.request_cursor(self.overlapping_view.cursor)

  if not overlapping_node then return end

  local div = self.root_node:get_divider_overlapping_point(x, y)
  if overlapping_node:get_scroll_button_index(x, y) or overlapping_node:is_in_tab_area(x, y) then
    core.request_cursor("arrow")
  elseif div and not self.overlapping_view:scrollbar_overlaps_point(x, y) then
    core.request_cursor(div.type == "hsplit" and "sizeh" or "sizev")
  end
end


---Called when mouse leaves the Root Panel area.
---Notifies the currently overlapping view to clear hover states.
function RootPanel:on_mouse_left()
  if self.overlapping_view then
    self.overlapping_view:on_mouse_left()
  end
end


---Handle file/folder drop events from OS.
---Supports: opening files, adding projects, showing dialogs.
---Files are deferred if nagview is visible to avoid locked node errors.
---@param filename string Absolute path to dropped file/folder
---@param x number Screen x where dropped
---@param y number Screen y where dropped
---@return boolean handled True if event was handled
function RootPanel:on_file_dropped(filename, x, y)
  log_file_drop("received", filename, x, y)
  local node = self.root_node:get_child_overlapping_point(x, y)
  local result = node and call_view_method(node.active_view, node.active_view.on_file_dropped, filename, x, y)
  if result then
    log_file_drop("handled-by-view", filename, x, y)
    return result
  end
  local info, info_err = system.get_file_info(filename)
  if info and info.type == "dir" then
    log_file_drop("directory", filename, x, y)
    local abspath = system.absolute_path(filename) --[[@as string]]
    if self.first_update_done then
      -- ask the user if they want to open it here or somewhere else
      core.nag_view:show(
        "Open directory",
        string.format('You are trying to open "%s"\n', common.home_encode(abspath))
        .. "Do you want to open this directory here, or in a new window?",
        {
          { text = "Current window", default_yes = true },
          { text = "New window", default_no = true },
          { text = "Cancel" }
        },
        function(opt)
          if opt.text == "Current window" then
            core.add_project(abspath)
          elseif opt.text == "New window" then
            system.exec(string.format("%q %q", EXEFILE, filename))
          end
        end
      )
      return true
    end
    -- in macOS, when dropping folders into Anvil in the dock,
    -- the OS tries to start an instance of Anvil with each folder as a DND request.
    -- When this happens, the DND request always arrive before the first update() call.
    -- We need to change the current project folder for the first request, and start
    -- new instances for the rest to emulate existing behavior.
    if self.first_dnd_processed then
      -- FIXME: port to process API
      system.exec(string.format("%q %q", EXEFILE, filename))
    else
      -- change project directory
      core.confirm_close_buffers(core.buffers, function(dirpath)
        core.open_folder_project(dirpath)
      end, system.absolute_path(filename))
      self.first_dnd_processed = true
    end
    return true
  end
  if not info then
    log_file_drop(
      "rejected-missing",
      filename,
      x,
      y,
      info_err and ("error=" .. quote_drop_text(info_err)) or nil
    )
    return true
  end
  if info.type ~= "file" then
    log_file_drop("rejected-unsupported-type", filename, x, y, "type=" .. tostring(info.type))
    return true
  end
  -- defer opening buffers in case nagview is visible (which will cause a locked node error)
  log_file_drop("deferred-file", filename, x, y, "size=" .. tostring(info.size))
  table.insert(self.defer_open_buffers, { filename, x, y })
  return true
end


---Process deferred file drops (files dropped while nagview was active).
---Called during update() to safely open files when nagview is dismissed.
function RootPanel:process_defer_open_buffers()
  if core.active_view == core.nag_view then return end
  for _, drop in ipairs(self.defer_open_buffers) do
    -- file dragged into editor, try to open it
    local filename, x, y = table.unpack(drop)
    local info, info_err = system.get_file_info(filename)
    if not info or info.type ~= "file" then
      local detail = info and ("type=" .. tostring(info.type))
        or (info_err and ("error=" .. quote_drop_text(info_err)) or nil)
      log_file_drop("deferred-rejected", filename, x, y, detail)
    else
      local ok, buffer = core.try(core.open_buffer, filename)
      if ok then
        local node = core.root_panel.root_node:get_child_overlapping_point(x, y)
        node:set_active_view(node.active_view)
        core.root_panel:open_buffer(buffer)
        log_file_drop("opened-file", filename, x, y, "size=" .. tostring(info.size))
      end
    end
  end
  self.defer_open_buffers = {}
end


---Forward mouse wheel events to the view under the mouse.
function RootPanel:on_mouse_wheel(delta_y, delta_x, ...)
  local x, y = self.mouse.x, self.mouse.y
  local node = self.root_node:get_child_overlapping_point(x, y)
  if node and node:is_in_tab_area(x, y) then
    local dir
    if math.abs(delta_x or 0) > math.abs(delta_y or 0) then
      dir = delta_x > 0 and 1 or 2
    elseif delta_y ~= 0 then
      dir = delta_y > 0 and 1 or 2
    end
    if dir and node:can_scroll_tabs(dir) then
      node:scroll_tabs(dir)
      return true
    end
  end
  return call_view_method(node.active_view, node.active_view.on_mouse_wheel, delta_y, delta_x, ...)
end


---Forward text input events to the currently active view.
function RootPanel:on_text_input(...)
  call_view_method(core.active_view, core.active_view.on_text_input, ...)
end


---Forward unhandled key presses to the focused view.
function RootPanel:on_key_pressed(...)
  return call_view_method(core.active_view, core.active_view.on_key_pressed, ...)
end

---Forward keys which the focused view owns before normal keymap commands.
function RootPanel:on_key_pressed_before_keymap(...)
  return call_view_method(
    core.active_view, core.active_view.on_key_pressed_before_keymap, ...
  )
end


---Forward key releases to the focused view.
function RootPanel:on_key_released(...)
  return call_view_method(core.active_view, core.active_view.on_key_released, ...)
end


---Handle touch press events (touchscreen/trackpad).
---Tracks which view is being touched for subsequent touch events.
function RootPanel:on_touch_pressed(x, y, ...)
  local touched_node = self.root_node:get_child_overlapping_point(x, y)
  self.touched_view = touched_node and touched_node.active_view
end


---Handle touch release events.
---Clears the touched view tracking.
function RootPanel:on_touch_released(x, y, ...)
  self.touched_view = nil
end


---Handle touch movement events (swipe gestures, etc.).
---Routes to touched view or handles divider/tab dragging.
function RootPanel:on_touch_moved(x, y, dx, dy, ...)
  if not self.touched_view then return end
  if core.active_view == core.nag_view then
    core.active_view:on_touch_moved(x, y, dx, dy, ...)
    return
  end

  if self.dragged_divider then
    local node = self.dragged_divider
    if node.type == "hsplit" then
      x = common.clamp(x - node.position.x, 0, self.root_node.size.x * 0.95)
      resize_child_node(node, "x", x, dx)
    elseif node.type == "vsplit" then
      y = common.clamp(y - node.position.y, 0, self.root_node.size.y * 0.95)
      resize_child_node(node, "y", y, dy)
    end
    node.divider = common.clamp(node.divider, 0.01, 0.99)
    return
  end

  local dn = self.dragged_node
  if dn and not dn.dragging then
    -- start dragging only after enough movement
    dn.dragging = common.distance(x, y, dn.drag_start_x, dn.drag_start_y) > style.tab_width * .05
    if dn.dragging then
      core.request_cursor("hand")
    end
  end

  -- avoid sending on_touch_moved events when dragging tabs
  if dn then return end

  call_view_method(self.touched_view, self.touched_view.on_touch_moved, x, y, dx, dy, ...)
end


---Forward IME text editing events to the active view.
---Called during IME composition for text input.
function RootPanel:on_ime_text_editing(...)
  call_view_method(core.active_view, core.active_view.on_ime_text_editing, ...)
end


---Handle window focus lost events.
---Forces redraw so cursors can be hidden when window is inactive.
function RootPanel:on_focus_lost(...)
  -- Force a redraw so Text Views can redraw without the cursor.
  core.redraw = true
end


---Animate drag overlay position and opacity smoothly.
---Internal helper for tab/split drag visual feedback.
---@param overlay core.rootpanel.overlay The overlay to animate
function RootPanel:interpolate_drag_overlay(overlay)
  self:move_towards(overlay, "x", overlay.to.x, nil, "tab_drag")
  self:move_towards(overlay, "y", overlay.to.y, nil, "tab_drag")
  self:move_towards(overlay, "w", overlay.to.w, nil, "tab_drag")
  self:move_towards(overlay, "h", overlay.to.h, nil, "tab_drag")

  self:move_towards(overlay, "opacity", overlay.visible and 100 or 0, nil, "tab_drag")
  overlay.color[4] = overlay.base_color[4] * overlay.opacity / 100
end


---Update the entire UI tree each frame.
---Manages: node layout, drag overlays, deferred file drops.
---Called automatically by core every frame.
function RootPanel:update()
  local perf_active = core.perf_frame_stats ~= nil
  local update_start = perf_active and system.get_time()
  local phase_start = perf_active and system.get_time()
  self:update_app_overlay()
  phase_start = perf_active and system.get_time()
  Node.copy_position_and_size(self.root_node, self)
  perf_elapsed("rootpanel_copy_position_ms", phase_start)
  -- Keep view geometry current before per-view update hooks run.  View:update()
  -- refreshes cached scrollbar rectangles from view position/size; after a tab
  -- close the newly active view may still carry geometry from the last time it
  -- was active, which can draw its scrollbar at a stale nested-view width
  -- for one frame.  Run layout first, then again after updates in case update
  -- hooks changed the tree or animated locked view sizes.
  phase_start = perf_active and system.get_time()
  self.root_node:update_layout()
  perf_elapsed("rootpanel_initial_layout_ms", phase_start)
  phase_start = perf_active and system.get_time()
  self.root_node:update()
  perf_elapsed("rootpanel_node_update_ms", phase_start)
  phase_start = perf_active and system.get_time()
  self.root_node:update_layout()
  -- The final layout can move or resize views after View:update() cached their
  -- scrollbar rectangles. Synchronize geometry without advancing animations a
  -- second time so drawing always uses this frame's final layout.
  self.root_node:sync_scrollbar_geometry()
  perf_elapsed("rootpanel_final_layout_ms", phase_start)

  phase_start = perf_active and system.get_time()
  self:update_drag_overlay()
  self:interpolate_drag_overlay(self.drag_overlay)
  self:interpolate_drag_overlay(self.drag_overlay_tab)
  perf_elapsed("rootpanel_drag_overlay_ms", phase_start)
  phase_start = perf_active and system.get_time()
  self:process_defer_open_buffers()
  perf_elapsed("rootpanel_defer_open_buffers_ms", phase_start)
  self.first_update_done = true
  perf_elapsed("rootpanel_update_ms", update_start)
end


---Set drag overlay target position and size.
---If immediate is true, jumps to position instantly instead of animating.
---@param overlay core.rootpanel.overlay The overlay to position
---@param x number Target x coordinate
---@param y number Target y coordinate
---@param w number Target width
---@param h number Target height
---@param immediate boolean? If true, jump to position without animation
function RootPanel:set_drag_overlay(overlay, x, y, w, h, immediate)
  overlay.to.x = x
  overlay.to.y = y
  overlay.to.w = w
  overlay.to.h = h
  if immediate then
    overlay.x = x
    overlay.y = y
    overlay.w = w
    overlay.h = h
  end
  if not overlay.visible then
    self:set_show_overlay(overlay, true)
  end
end


---Calculate overlay rectangle for a split type.
---Returns modified x, y, w, h for showing where split will occur.
---@param split_type string "left", "right", "up", or "down"
---@param x number Original x coordinate
---@param y number Original y coordinate
---@param w number Original width
---@param h number Original height
---@return number x Modified x coordinate
---@return number y Modified y coordinate
---@return number w Modified width
---@return number h Modified height
local function get_split_sizes(split_type, x, y, w, h)
  if split_type == "left" then
    w = w * .5
  elseif split_type == "right" then
    x = x + w * .5
    w = w * .5
  elseif split_type == "up" then
    h = h * .5
  elseif split_type == "down" then
    y = y + h * .5
    h = h * .5
  end
  return x, y, w, h
end


---Update drag overlay position during tab drag.
---Shows visual feedback for where tab will land (split or reorder).
---Called during update() when dragging tabs.
function RootPanel:update_drag_overlay()
  if not (self.dragged_node and self.dragged_node.dragging) then return end
  local over = self.root_node:get_child_overlapping_point(self.mouse.x, self.mouse.y)
  if over and not over.locked then
    local _, _, _, tab_h = over:get_scroll_button_rect(1)
    local x, y = over.position.x, over.position.y
    local w, h = over.size.x, over.size.y
    local split_type = over:get_split_type(self.mouse.x, self.mouse.y)

    if split_type == "tab" and (over ~= self.dragged_node.node or #over.views > 1) then
      local tab_index, tab_x, tab_y, tab_w, tab_h = over:get_drag_overlay_tab_position(self.mouse.x, self.mouse.y)
      self:set_drag_overlay(self.drag_overlay_tab,
        tab_x + (tab_index and 0 or tab_w), tab_y,
        style.caret_width, tab_h,
        -- avoid showing tab overlay moving between nodes
        over ~= self.drag_overlay_tab.last_over)
      self:set_show_overlay(self.drag_overlay, false)
      self.drag_overlay_tab.last_over = over
    else
      if (over ~= self.dragged_node.node or #over.views > 1) then
        y = y + tab_h
        h = h - tab_h
        x, y, w, h = get_split_sizes(split_type, x, y, w, h)
      end
      self:set_drag_overlay(self.drag_overlay, x, y, w, h)
      self:set_show_overlay(self.drag_overlay_tab, false)
    end
  else
    self:set_show_overlay(self.drag_overlay, false)
    self:set_show_overlay(self.drag_overlay_tab, false)
  end
end


---Draw the currently dragged tab floating under the cursor.
---Visual feedback during tab drag operations.
function RootPanel:draw_grabbed_tab()
  local dn = self.dragged_node
  local _,_, w, h = dn.node:get_tab_rect(dn.idx)
  local x = self.mouse.x - w / 2
  local y = self.mouse.y - h / 2
  local view = dn.node.views[dn.idx]
  self.root_node:draw_tab(view, true, true, x, y, w, h, true)
end


---Draw a drag overlay rectangle with current opacity.
---Shows where tab/split will land when dropped.
---@param ov core.rootpanel.overlay The overlay to draw
function RootPanel:draw_drag_overlay(ov)
  if ov.opacity > 0 then
    renderer.draw_rect(ov.x, ov.y, ov.w, ov.h, ov.color)
  end
end


---Render the entire UI each frame.
---Draw order: 1) node tree, 2) app overlay, 3) deferred draws,
---4) drag overlays, 5) cursor update
function RootPanel:draw()
  local scope = perf_scope_begin("root_panel_core", true)
  local phase = perf_scope_begin("node_tree")
  self.root_node:draw()
  perf_scope_end(phase)
  phase = perf_scope_begin("app_overlay")
  self:draw_active_app_overlay()
  perf_scope_end(phase)
  phase = perf_scope_begin("deferred_draws")
  while #self.deferred_draws > 0 do
    local t = table.remove(self.deferred_draws)
    t.fn(table.unpack(t))
  end
  perf_scope_end(phase)

  phase = perf_scope_begin("drag_overlays")
  self:draw_drag_overlay(self.drag_overlay)
  self:draw_drag_overlay(self.drag_overlay_tab)
  if self.dragged_node and self.dragged_node.dragging then
    self:draw_grabbed_tab()
  end
  perf_scope_end(phase)
  phase = perf_scope_begin("cursor_update")
  if core.cursor_change_req then
    system.set_cursor(core.cursor_change_req)
    core.cursor_change_req = nil
  end
  perf_scope_end(phase)
  perf_scope_end(scope)
end

return RootPanel
