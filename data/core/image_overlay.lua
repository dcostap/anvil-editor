local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local card = require "core.card"
local keymap = require "core.keymap"
local system_icons = require "core.system_icons"
local ImageView = require "core.imageview"

---The Image Overlay shows one image above the editor, with zoom, pan and file actions.
---Markdown images and Terminal images open in it.
local overlay = {}

local OPEN_DURATION = 0.12
local CLOSE_DURATION = 0.18
local TOAST_DURATION = 1.8
local TOOLTIP_DELAY = 0.35

-- Each action has a system icon glyph and a fallback glyph from the bundled icon font.
local ACTIONS = {
  { id = "copy", glyph = "\238\163\136", fallback = "f", tooltip = "Copy image", shortcut = "Ctrl+C" },
  { id = "save", glyph = "\238\157\142", fallback = "S", tooltip = "Save image as…", shortcut = "Ctrl+S" },
  { id = "open_in_pane", glyph = "\238\163\165", fallback = "F", tooltip = "Open in a Pane", needs_path = true },
  { id = "open_external", glyph = "\238\162\167", fallback = "W", tooltip = "Open with the default app" },
  { id = "show_in_folder", glyph = "\238\160\184", fallback = "D", tooltip = "Show in folder", needs_path = true },
  { id = "close", glyph = "\238\156\145", fallback = "C", tooltip = "Close", shortcut = "Esc", separated = true },
}

---@class core.image_overlay.state
---@field view core.imageview
---@field source { x: number, y: number, w: number, h: number }?
---@field progress number
---@field target number
local state
local temp_count = 0
local modal_handlers

local function now() return system.get_time() end

local function ease_out(t) return 1 - (1 - t) ^ 3 end

local function root_rect()
  local root = core.root_panel
  return root.position.x, root.position.y, root.size.x, root.size.y
end

local function contains(rect, x, y)
  return rect ~= nil and x >= rect.x and y >= rect.y and x < rect.x + rect.w and y < rect.y + rect.h
end

local function with_alpha(color, factor)
  return { color[1], color[2], color[3], (color[4] or 255) * factor }
end

-- Checked once when the overlay opens, so layout does not read the disk each frame.
local function has_file(st)
  return st.file
end

local function icon_font()
  return system_icons.font(math.floor(14 * SCALE + 0.5))
end

---True while the overlay takes input. A closing overlay still draws but takes no input.
function overlay.is_open() return state ~= nil and state.target == 1 end

---The Image View of the open overlay.
function overlay.get_view() return state and state.target == 1 and state.view or nil end

-- The source rectangle is usable when it has a size and some part shows in the Window.
local function source_transform(st)
  local rect = st.source
  if not rect or not rect.w or rect.w <= 0 or rect.h <= 0 then return nil end
  local x, y, w, h = root_rect()
  if rect.x + rect.w <= x or rect.y + rect.h <= y or rect.x >= x + w or rect.y >= y + h then return nil end
  local view = st.view
  local iw, ih = view.image:get_size()
  local scale = math.min(rect.w / iw, rect.h / ih)
  return {
    scale = scale,
    x = rect.x - view.position.x + (rect.w - iw * scale) / 2,
    y = rect.y - view.position.y + (rect.h - ih * scale) / 2,
  }
end

-- Lay out the top bar: the title on the left and the actions on the right.
local function layout(st)
  local x, y, w, h = root_rect()
  local view = st.view
  view.position.x, view.position.y = x, y
  view.size.x, view.size.y = w, h
  local margin = style.padding.x
  local button = math.floor(style.font:get_height() + style.padding.y * 2)
  local pad = math.floor(style.padding.y / 2)
  local actions = {}
  for _, action in ipairs(ACTIONS) do
    if not action.needs_path or has_file(st) then actions[#actions + 1] = action end
  end
  local gap = math.floor(style.padding.y)
  local width = pad * 2
  for i, action in ipairs(actions) do
    width = width + button + ((i > 1 and action.separated) and gap or 0)
  end
  local bar = { x = x + w - margin - width, y = y + margin, w = width, h = button + pad * 2 }
  local bx = bar.x + pad
  st.buttons = {}
  for i, action in ipairs(actions) do
    if i > 1 and action.separated then
      st.separator = bx + gap / 2
      bx = bx + gap
    end
    st.buttons[#st.buttons + 1] = { action = action, x = bx, y = bar.y + pad, w = button, h = button }
    bx = bx + button
  end
  st.bar = bar
  local iw, ih = view.image:get_size()
  local name = view:get_name()
  local detail = string.format("%d × %d", iw, ih)
  local font = style.font
  local title_w = math.min(font:get_width(name) + font:get_width(detail) + style.padding.x * 3,
    math.max(0, bar.x - x - margin * 2))
  st.title = { x = x + margin, y = bar.y, w = title_w, h = bar.h, name = name, detail = detail }
  local controls = view:get_controls().rect
  local bottom = controls and (y + h - controls.y + pad) or margin
  view:set_insets(margin, bar.y + bar.h + pad - y, margin, bottom)
end

local function button_at(st, x, y)
  for _, item in ipairs(st.buttons or {}) do
    if contains(item, x, y) then return item end
  end
end

---Show a short message above the zoom controls.
function overlay.show_toast(text)
  if not state then return end
  state.toast = { text = text, started = now() }
  core.redraw = true
end
local show_toast = overlay.show_toast

---Return the screen rectangle of an action button, such as "copy", or nil when it is not shown.
function overlay.button_rect(id)
  for _, item in ipairs(state and state.buttons or {}) do
    if item.action.id == id then return { x = item.x, y = item.y, w = item.w, h = item.h } end
  end
end

function overlay.update()
  local st = state
  if not st then return end
  local t = config.transitions and common.clamp((now() - st.started) / st.duration, 0, 1) or 1
  st.progress = common.lerp(st.from, st.target, ease_out(t))
  if t < 1 then core.redraw = true end
  layout(st)
  st.view:update()
  if st.target == 0 and t >= 1 then
    state = nil
    core.redraw = true
    return
  end
  if st.toast then
    if now() - st.toast.started > TOAST_DURATION then st.toast = nil end
    core.redraw = true
  end
  if st.hovered and not st.tooltip_shown then
    st.tooltip_shown = now() - st.hovered.since >= TOOLTIP_DELAY
    core.redraw = true
  end
end

---Open an image. `opts.source_rect` is the image's place on screen; the image grows from there.
---`opts.open_animation` returns a canvas animation for an animated image.
---@param image canvas
---@param opts? { label: string?, path: string?, open_animation: function?, source_rect: table? }
function overlay.open_image(image, opts)
  if not image then return false, "image is required" end
  opts = opts or {}
  if overlay.is_open() then core.root_panel:pop_modal_input(overlay) end
  local view = ImageView()
  view:set_image(image, opts.label, opts.path, opts.open_animation)
  state = {
    view = view, source = opts.source_rect, file = opts.path ~= nil and system.get_file_info(opts.path) ~= nil,
    progress = 0, from = 0, target = 1, started = now(), duration = OPEN_DURATION,
  }
  layout(state)
  view:update()
  local from = config.transitions and source_transform(state)
  state.flying = from ~= nil
  if from then
    view:animate_to(view.zoom_scale, view.image_x, view.image_y, { from = from, duration = OPEN_DURATION })
  end
  core.root_panel:push_modal_input(overlay, { label = "image-overlay", handlers = modal_handlers })
  core.log_quiet("Image overlay opened: %s (source rect: %s)", opts.label or opts.path or "Image",
    from and "yes" or "no")
  core.redraw = true
  return true
end

---Open an image file.
function overlay.open(path, opts)
  if type(path) ~= "string" or path == "" then return false end
  local image, err = canvas.load_image(path)
  if not image then
    core.log_quiet("Image overlay failed to load %s: %s", path, tostring(err))
    return false, err
  end
  opts = opts or {}
  return overlay.open_image(image, {
    label = opts.label, path = path, source_rect = opts.source_rect,
    open_animation = ImageView.file_animation_opener(path),
  })
end

---Close the overlay. The image returns to its source rectangle, or fades out.
function overlay.close()
  local st = state
  if not st or st.target == 0 then return end
  core.root_panel:pop_modal_input(overlay)
  st.view:on_mouse_left()
  st.hovered, st.tooltip_shown, st.backdrop_press = nil, nil, nil
  if not config.transitions then
    state = nil
  else
    st.from, st.target, st.started, st.duration = st.progress, 0, now(), CLOSE_DURATION
    local to = source_transform(st)
    st.flying = to ~= nil
    if to then
      st.view:stop_motion()
      st.view:animate_to(to.scale, to.x, to.y, { duration = CLOSE_DURATION, free = true })
    end
  end
  core.log_quiet("Image overlay closed")
  core.redraw = true
end

local function write_temp_png(st)
  if st.temp_path and system.get_file_info(st.temp_path) then return st.temp_path end
  local dir = os.getenv("TEMP") or os.getenv("TMP") or os.getenv("TMPDIR") or "/tmp"
  temp_count = temp_count + 1
  local path = string.format("%s%sanvil-image-%d-%d.png", dir, PATHSEP, system.get_process_id(), temp_count)
  local ok, err = st.view.image:save_image(path, "png")
  if not ok then return nil, err end
  st.temp_path = path
  return path
end

local function copy_file(from, to)
  local input, err = io.open(from, "rb")
  if not input then return false, err end
  local data = input:read("*a")
  input:close()
  local output
  output, err = io.open(to, "wb")
  if not output then return false, err end
  output:write(data)
  output:close()
  return true
end

local ENCODED_FORMATS = { png = "png", jpg = "jpg", jpeg = "jpg", avif = "avif" }

local function extension(path)
  return path and (path:match("%.([%w]+)$") or ""):lower()
end

---Save the image. The same extension as the source file copies the file, so animation and metadata stay.
---Other extensions encode the shown image as PNG, JPEG or AVIF.
function overlay.save_to(path)
  local st = state
  if not st then return false, "no image" end
  local source, ext = st.view.path, extension(path)
  local ok, err
  if source and has_file(st) and ext == extension(source) then
    ok, err = copy_file(source, path)
  elseif ENCODED_FORMATS[ext] then
    ok, err = st.view.image:save_image(path, ENCODED_FORMATS[ext])
  else
    ok, err = false, "use a .png, .jpg or .avif file name"
  end
  core.log_quiet("Image overlay save to %s: %s", path, ok and "ok" or tostring(err))
  show_toast(ok and ("Saved " .. common.basename(path)) or ("Could not save: " .. tostring(err)))
  return ok, err
end

local function default_save_location(st)
  local source = st.view.path
  local name = source and common.basename(source) or "image.png"
  local dir = source and common.dirname(source)
  if not dir then
    local home = HOME or os.getenv("USERPROFILE") or os.getenv("HOME")
    local pictures = home and home .. PATHSEP .. "Pictures"
    dir = pictures and system.get_file_info(pictures) and pictures or home
  end
  return dir and dir .. PATHSEP .. name or name, extension(name)
end

local perform = {}

function perform.copy(st)
  local ok, err = system.set_clipboard_image(st.view.image)
  core.log_quiet("Image overlay copy: %s", ok and "ok" or tostring(err))
  show_toast(ok and "Image copied" or ("Could not copy image: " .. tostring(err)))
end

function perform.save(st)
  local location, ext = default_save_location(st)
  core.save_file_dialog(core.window, function(status, result)
    if status ~= "accept" or state ~= st then return end
    local path = type(result) == "table" and result[1] or result
    if type(path) ~= "string" or path == "" then return end
    if not path:match("%.[%w]+$") then path = path .. "." .. ext end
    overlay.save_to(path)
  end, { title = "Save image as", default_location = location })
end

function perform.open_in_pane(st)
  local path = st.view.path
  overlay.close()
  if not core.open_file(path) then core.error("Could not open image: %s", path) end
end

function perform.open_external(st)
  local path, err = st.view.path
  if not has_file(st) then path, err = write_temp_png(st) end
  local ok = path and common.open_in_system(path)
  core.log_quiet("Image overlay open with default app: %s (%s)", tostring(path), ok and "ok" or tostring(err))
  if not ok then show_toast("Could not open the image") end
end

function perform.show_in_folder(st)
  local ok = common.show_in_folder(st.view.path)
  core.log_quiet("Image overlay show in folder: %s (%s)", st.view.path, ok and "ok" or "failed")
  if not ok then show_toast("Could not show the image in its folder") end
end

function perform.close() overlay.close() end

---Run one action, such as "copy" or "show_in_folder".
function overlay.perform(id)
  local st = state
  if not overlay.is_open() or not perform[id] then return false end
  for _, action in ipairs(ACTIONS) do
    if action.id == id and action.needs_path and not has_file(st) then return false end
  end
  perform[id](st)
  return true
end

function overlay.on_mouse_pressed(button, x, y, clicks)
  local st = state
  if not overlay.is_open() then return false end
  local view = st.view
  if button ~= "left" then
    if button == "middle" or button == "right" then overlay.close() end
    return true
  end
  local item = button_at(st, x, y)
  if item then
    overlay.perform(item.action.id)
  elseif contains(st.bar, x, y) or contains(st.title, x, y) then
    return true
  elseif view:controls_contain(x, y) or view:contains_image(x, y) then
    view:on_mouse_pressed(button, x, y, clicks)
  else
    st.backdrop_press = { x = x, y = y }
  end
  return true
end

-- A click on the backdrop closes the overlay. A drag that starts there does not.
function overlay.on_mouse_released(button, x, y)
  local st = state
  if not overlay.is_open() then return false end
  st.view:on_mouse_released(button, x, y)
  local press = st.backdrop_press
  st.backdrop_press = nil
  local slop = 6 * SCALE
  if button == "left" and press and math.abs(x - press.x) <= slop and math.abs(y - press.y) <= slop then
    overlay.close()
  end
  return true
end

function overlay.on_mouse_moved(x, y, dx, dy)
  local st = state
  if not overlay.is_open() then return false end
  st.view:on_mouse_moved(x, y, dx, dy)
  local item = not st.view.panning and button_at(st, x, y)
  local id = item and item.action.id
  if (st.hovered and st.hovered.id) ~= id then
    st.hovered = id and { id = id, item = item, since = now() } or nil
    st.tooltip_shown = false
    core.redraw = true
  end
  core.request_cursor(item and "hand" or st.view.cursor)
  return true
end

function overlay.on_mouse_left()
  if state then
    state.view:on_mouse_left()
    state.hovered, state.backdrop_press = nil, nil
  end
  return true
end

function overlay.on_mouse_wheel(delta_y)
  if not overlay.is_open() then return false end
  state.view:on_mouse_wheel(delta_y)
  return true
end

local PAN_KEYS = { left = { -1, 0 }, right = { 1, 0 }, up = { 0, -1 }, down = { 0, 1 } }

function overlay.on_key_pressed(key, event)
  if not overlay.is_open() then return false end
  local view = state.view
  local ctrl = (type(event) == "table" and event.ctrl) or keymap.modkeys.ctrl
  if key == "escape" then
    overlay.close()
  elseif ctrl and key == "c" then
    overlay.perform("copy")
  elseif ctrl and key == "s" then
    overlay.perform("save")
  elseif key == "+" or key == "=" or key == "keypad +" then
    view:zoom_in()
  elseif key == "-" or key == "keypad -" then
    view:zoom_out()
  elseif key == "0" or key == "keypad 0" then
    view:zoom_fit()
  elseif key == "1" or key == "keypad 1" then
    view:zoom_reset()
  elseif PAN_KEYS[key] then
    local _, _, bw, bh = view:get_box()
    local step = PAN_KEYS[key]
    view:pan_by(step[1] * bw / 5, step[2] * bh / 5)
  end
  return true
end

modal_handlers = {
  key_pressed = overlay.on_key_pressed,
  mouse_pressed = overlay.on_mouse_pressed,
  mouse_released = overlay.on_mouse_released,
  mouse_moved = overlay.on_mouse_moved,
  mouse_left = overlay.on_mouse_left,
  mouse_wheel = overlay.on_mouse_wheel,
}

local function draw_pill(rect)
  card.draw(rect.x, rect.y, rect.w, rect.h, rect.h / 2)
end

-- Draw a label centered on `x`, kept inside the Window.
local function draw_label_card(text, x, y)
  local font = style.font
  local w = font:get_width(text) + style.padding.x * 2
  local h = font:get_height() + style.padding.y * 2
  local left, _, width = root_rect()
  x = math.floor(common.clamp(x - w / 2, left + style.padding.x, left + width - style.padding.x - w))
  card.draw(x, y, w, h, h / 2)
  common.draw_text(font, style.text, text, "center", x, y, w, h)
end

local function draw_chrome(st)
  local font = style.font
  local title = st.title
  if title.w > style.padding.x * 2 then
    draw_pill(title)
    core.push_clip_rect(title.x, title.y, title.w, title.h)
    local tx = title.x + style.padding.x
    tx = common.draw_text(font, style.text, title.name, "left", tx, title.y, 0, title.h)
    common.draw_text(font, style.dim, title.detail, "left", tx + style.padding.x, title.y, 0, title.h)
    core.pop_clip_rect()
  end
  draw_pill(st.bar)
  local icons = icon_font()
  for _, item in ipairs(st.buttons) do
    local hovered = st.hovered and st.hovered.id == item.action.id
    if hovered then
      renderer.draw_rounded_rect(item.x, item.y, item.w, item.h, item.h / 2, style.card_selection)
    end
    local glyph_font = icons or style.icon_font
    local glyph = icons and item.action.glyph or item.action.fallback
    common.draw_text(glyph_font, hovered and style.accent or style.text, glyph, "center",
      item.x, item.y, item.w, item.h)
  end
  if st.separator then
    local inset = st.bar.h / 4
    renderer.draw_rect(math.floor(st.separator), st.bar.y + inset, math.max(1, math.floor(SCALE)),
      st.bar.h - inset * 2, style.card_border)
  end
  st.view:draw_controls()
  if st.hovered and st.tooltip_shown then
    local item, action = st.hovered.item, st.hovered.item.action
    local text = action.shortcut and (action.tooltip .. "  ·  " .. action.shortcut) or action.tooltip
    draw_label_card(text, item.x + item.w / 2, st.bar.y + st.bar.h + style.padding.y)
  end
  local toast = st.toast
  if toast then
    local x, y, w, h = root_rect()
    local controls = st.view:get_controls().rect
    local label_h = font:get_height() + style.padding.y * 2
    local label_y = (controls and controls.y or y + h) - label_h - style.padding.y
    local alpha = common.clamp((TOAST_DURATION - (now() - toast.started)) / 0.3, 0, 1)
    renderer.push_transform(x + w / 2, label_y + label_h / 2, 1, alpha)
    draw_label_card(toast.text, x + w / 2, label_y)
    renderer.pop_transform()
  end
end

function overlay.draw()
  local st = state
  if not st then return end
  local x, y, w, h = root_rect()
  local p = st.progress
  local backdrop = with_alpha(style.image_overlay_background, p)
  renderer.draw_rect(x, y, w, h, backdrop)
  core.root_panel:dim_sidebar(backdrop)
  core.push_clip_rect(x, y, w, h)
  -- An image that does not fly from or to its source rectangle fades, and grows a little as it opens.
  local fade = not st.flying and p < 0.999
  if fade then
    local ix, iy, iw, ih = st.view:get_image_rect()
    renderer.push_transform(ix + iw / 2, iy + ih / 2, 0.96 + 0.04 * p, p)
  end
  st.view:draw_image()
  if fade then renderer.pop_transform() end
  if p > 0.001 then
    local chrome = p < 0.999
    if chrome then renderer.push_transform(x + w / 2, y + h / 2, 1, p) end
    draw_chrome(st)
    if chrome then renderer.pop_transform() end
  end
  core.pop_clip_rect()
end

return overlay
