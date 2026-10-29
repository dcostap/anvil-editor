local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local card = require "core.card"
local system_icons = require "core.system_icons"
local links = require "core.markdown.links"

---Image Controls work as in Obsidian. A Live Preview image under the pointer
---shows a zoom and an edit button at its top right, and a resize corner at
---its bottom right. A corner drag writes the width into the image link.
local image_controls = {}

-- Obsidian's smallest width from a drag.
local MIN_WIDTH = 20

-- Obsidian fades the buttons in and out over this time.
local FADE_SECONDS = 0.07

-- Each action has a system icon glyph and a fallback text.
local ACTIONS = {
  { id = "zoom", glyph = "\238\162\163", fallback = "+" },
  { id = "edit", glyph = "\238\165\131", fallback = "</>" },
}

local function scaled(value)
  return math.floor(value * SCALE + 0.5)
end

local function contains(rect, x, y)
  return rect ~= nil and x >= rect.x and y >= rect.y
    and x < rect.x + rect.w and y < rect.y + rect.h
end

local function part_at(layout, x, y)
  if not layout then return nil end
  for id, rect in pairs(layout.buttons or {}) do
    if contains(rect, x, y) then return id end
  end
  if contains(layout.corner, x, y) then return "corner" end
  if contains(layout.image, x, y) then return "image" end
end

local function resizing(view, spec)
  local drag = view.render_widget_drag
  return drag ~= nil and drag.image_reference_id == spec.reference_id
end

---The width that a corner drag shows for an image, or nil.
---@param view core.textview
---@param reference_id string
---@return integer?
function image_controls.drag_width(view, reference_id)
  local drag = view.render_widget_drag
  return drag and drag.image_reference_id == reference_id and drag.width or nil
end

-- Write `width` into the image link, or remove its size when it is nil.
local function set_width(view, spec, width)
  local buffer = view.buffer
  local source = (buffer.lines[spec.line] or ""):sub(spec.col1, spec.col2 - 1)
  local text = links.with_image_width(source, width)
  if not text then
    core.log_quiet("Markdown image at %s:%d is no longer an image link; its size stays",
      buffer:get_name(), spec.line)
    return false
  end
  if text ~= source then
    -- Change only the size, so the shown source keeps its other text while
    -- the note is parsed again.
    local prefix = 0
    while prefix < math.min(#text, #source)
      and text:byte(prefix + 1) == source:byte(prefix + 1)
    do
      prefix = prefix + 1
    end
    local suffix = 0
    while suffix < math.min(#text, #source) - prefix
      and text:byte(#text - suffix) == source:byte(#source - suffix)
    do
      suffix = suffix + 1
    end
    buffer:apply_edits({ {
      line1 = spec.line, col1 = spec.col1 + prefix,
      line2 = spec.line, col2 = spec.col2 - suffix,
      text = text:sub(prefix + 1, #text - suffix),
    } }, { type = "markdown-image", reason = width and "resize" or "reset-size" })
  end
  core.log_quiet("Markdown image at %s:%d %s", buffer:get_name(), spec.line,
    width and ("resized to " .. width) or "reset to its own size")
  return true
end

local function image_source(view, spec)
  local source = (view.buffer.lines[spec.line] or ""):sub(spec.col1, spec.col2 - 1)
  return links.with_image_width(source, nil) and source or nil
end

---The controls of the image at the screen point `x`, `y`, or nil.
---@param view core.textview
---@return table?
function image_controls.at_point(view, x, y)
  local hit = view:get_render_widget_at_position(x, y)
  local widget = hit and hit.widget
  if widget and widget.image_controls and part_at(widget.image_layout, x, y) then
    return widget.image_controls
  end
end

---True when the image link at `spec` is still in the source.
function image_controls.is_current(view, spec)
  return image_source(view, spec) ~= nil
end

---True when the image link at `spec` sets a size.
function image_controls.has_size(view, spec)
  local source = image_source(view, spec)
  return source ~= nil and links.with_image_width(source, nil) ~= source
end

function image_controls.reset_size(view, spec)
  set_width(view, spec, nil)
  spec.invalidate(view)
end

function image_controls.remove(view, spec)
  view.buffer:apply_edits({
    { line1 = spec.line, col1 = spec.col1, line2 = spec.line, col2 = spec.col2, text = "" },
  }, { type = "markdown-image", reason = "remove" })
end

function image_controls.copy(spec)
  local ok, err = system.set_clipboard_image(spec.image)
  core.log_quiet("Markdown image copy: %s", ok and "ok" or tostring(err))
  if not ok then core.warn("Could not copy the image: %s", tostring(err)) end
end

---Show the source of the image link at `spec` and select its target, as the
---edit button does.
function image_controls.edit(view, spec)
  local source = (view.buffer.lines[spec.line] or ""):sub(spec.col1, spec.col2 - 1)
  local col1, col2 = links.image_target_range(source)
  if not col1 then return false end
  view.buffer:set_selection(spec.line, spec.col1 + col2 - 1, spec.line, spec.col1 + col1 - 1)
  return true
end

---A click edits the image target. A drag selects its whole link without
---revealing the source under the pointer.
function image_controls.press_link(view, spec, x, y)
  view:begin_line_render_interaction("mouse-selection")
  view:begin_render_widget_drag({
    cursor = "ibeam",
    on_move = function(drag, owner, move_x, move_y)
      if not drag.moved and (move_x - x) ^ 2 + (move_y - y) ^ 2 < (5 * SCALE) ^ 2 then
        return
      end
      drag.moved = true
      local line, col = owner:resolve_screen_position(move_x, move_y)
      local forward = line > spec.line or line == spec.line and col >= spec.col1
      local anchor = forward and spec.col1 or spec.col2
      col = owner:whole_fragment_col(move_x, move_y, line, col, spec.line, anchor)
      if line == spec.line then
        col = forward and math.max(col, spec.col2) or math.min(col, spec.col1)
      end
      owner.buffer:set_selection(line, col, spec.line, anchor)
    end,
    on_release = function(drag, owner)
      if not drag.moved then image_controls.edit(owner, spec) end
    end,
  })
  return true
end

local function begin_resize(view, spec, layout, x, y)
  local image = layout.image
  local aspect = image.w / math.max(1, image.h)
  local threshold = scaled(5)
  view:begin_render_widget_drag({
    cursor = "sizenwse",
    image_reference_id = spec.reference_id,
    on_move = function(drag, owner, move_x, move_y)
      if not drag.width
        and (move_x - x) ^ 2 + (move_y - y) ^ 2 < threshold ^ 2
      then
        return
      end
      -- The corner follows the pointer along the edge that it moved further.
      local width = math.max(math.abs(move_x - image.x), math.abs(move_y - image.y) * aspect)
      width = math.floor(math.min(spec.max_width, math.max(MIN_WIDTH, width)) + 0.5)
      if width ~= drag.width then
        drag.width = width
        spec.invalidate(owner)
      end
    end,
    on_release = function(drag, owner)
      if not drag.width then return end
      set_width(owner, spec, drag.width)
      spec.invalidate(owner)
    end,
  })
end

---Give an image widget its controls. `spec` names the image link's source,
---`spec.line`, `spec.col1` and `spec.col2`, and its `reference_id`. The image
---grows to `spec.max_width` at most. `spec.image` is its canvas.
---`spec.open(view, hit)` shows the image, and `spec.invalidate(view)` lays
---out its line again.
---@param widget table
---@param spec table
function image_controls.attach(widget, spec)
  widget.image_controls = spec
  widget.track_hover = true
  widget.cursor_at = function(self, view, x, y)
    local part = part_at(self.image_layout, x, y)
    local pointer = view.image_controls_pointer
    if not pointer or pointer.part ~= part then core.redraw = true end
    view.image_controls_pointer = { x = x, y = y, part = part }
    return part == "corner" and "sizenwse" or "hand"
  end
  widget.on_mouse_pressed = function(self, view, hit, button, x, y, clicks)
    if button ~= "left" then return false end
    local layout = self.image_layout
    local part = part_at(layout, x, y)
    if part == "corner" then
      if clicks >= 2 then
        set_width(view, spec, nil)
      else
        begin_resize(view, spec, layout, x, y)
      end
      return true
    elseif part == "edit" then
      return image_controls.edit(view, spec)
    end
    return spec.open(view, hit)
  end
end

-- Move the buttons of `spec`'s image one step toward `shown`, and return
-- their opacity. The view keeps the fade, because each new layout of the
-- line makes a new widget.
local function fade(view, spec, shown)
  local fades = view.image_controls_fades or {}
  view.image_controls_fades = fades
  local state = fades[spec.reference_id]
  if not state then
    if not shown then return 0 end
    state = { progress = 0 }
    fades[spec.reference_id] = state
  end
  local now = system.get_time()
  -- One step covers at most one frame, as in Row Highlight.
  local frame = 1 / core.fps
  local dt = state.time and math.min(now - state.time, frame) or frame
  state.time = now
  if not config.transitions or core.in_live_resize_frame then dt = math.huge end
  local step = dt / FADE_SECONDS
  local progress = shown and math.min(1, state.progress + step)
    or math.max(0, state.progress - step)
  state.progress = progress
  if progress == 0 then
    fades[spec.reference_id] = nil
  elseif progress < 1 or not shown then
    core.redraw = true
  end
  -- CSS ease-out.
  return 1 - (1 - progress) ^ 2
end

local function faded(color, opacity)
  return { color[1], color[2], color[3], (color[4] or 255) * opacity }
end

---Draw the controls of an image widget over its image at `x`, `y`.
---@param widget table
---@param view core.textview
function image_controls.draw(widget, view, x, y, w, h)
  local spec = widget.image_controls
  local active = resizing(view, spec)
  local corner_size = scaled(30)
  local layout = {
    image = { x = x, y = y, w = w, h = h },
    corner = { x = x + w - corner_size, y = y + h - corner_size, w = corner_size, h = corner_size },
  }
  widget.image_layout = layout
  -- Text View draws a copy of the hovered fragment; both share the widget.
  -- A new layout of the line makes a new widget for the same image, so match
  -- the image, not the widget.
  local pointed = view.hovered_render_fragment
  local pointed_image = pointed and pointed.widget and pointed.widget.image_controls
  local shown = active
    or pointed_image ~= nil and pointed_image.reference_id == spec.reference_id

  if shown then
    local stroke, size, inset = math.max(1, scaled(1.75)), scaled(10), scaled(6)
    local right, bottom = x + w - inset, y + h - inset
    local color = active and style.accent or style.dim
    renderer.draw_rect(right - size, bottom - stroke, size, stroke, color)
    renderer.draw_rect(right - stroke, bottom - size, stroke, size - stroke, color)
  end

  -- Obsidian hides the buttons on an image too narrow to hold them.
  if w < scaled(80) then return end
  local opacity = fade(view, spec, shown)
  if opacity <= 0 then return end
  local button_w, button_h, gap, pad = scaled(28), scaled(24), scaled(2), scaled(2)
  local pill_w = pad * 2 + #ACTIONS * button_w + (#ACTIONS - 1) * gap
  local pill = { x = x + w - scaled(8) - pill_w, y = y + scaled(8), w = pill_w, h = button_h + pad * 2 }
  local buttons = {}
  for index, action in ipairs(ACTIONS) do
    buttons[action.id] = {
      x = pill.x + pad + (index - 1) * (button_w + gap), y = pill.y + pad,
      w = button_w, h = button_h,
    }
  end
  -- Fading buttons are not under the pointer, so only shown buttons take clicks.
  if shown then layout.buttons = buttons end

  local pointer = view.image_controls_pointer
  card.draw(pill.x, pill.y, pill.w, pill.h, scaled(6), nil, opacity)
  local icons = system_icons.font(scaled(14))
  for _, action in ipairs(ACTIONS) do
    local rect = buttons[action.id]
    local hovered = shown and not active and pointer ~= nil
      and contains(rect, pointer.x, pointer.y)
    if hovered then
      renderer.draw_rounded_rect(rect.x, rect.y, rect.w, rect.h, scaled(4), faded(style.card_selection, opacity))
    end
    common.draw_text(icons or style.font, faded(hovered and style.accent or style.text, opacity),
      icons and action.glyph or action.fallback, "center", rect.x, rect.y, rect.w, rect.h)
  end
end

---The screen rectangles of the image on `line` at its last draw: `image`,
---`corner`, and `buttons` by action while they show.
---@param view core.textview
---@param line integer
---@return table?
function image_controls.layout(view, line)
  local render = view:get_line_render(line)
  for _, fragment in ipairs(render and render.fragments or {}) do
    local widget = fragment.widget
    if widget and widget.image_layout then return widget.image_layout end
  end
end

return image_controls
