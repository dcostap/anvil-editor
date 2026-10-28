-- Heading Outline: the document's headings, listed in the free space left of
-- the reading lane in Markdown Live Preview. It marks the section at the top
-- of the view, and a click on a heading moves the caret and the view to it.
-- It shows the headings that Current Buffer Symbol Search finds.
local core = require "core"
local common = require "core.common"
local style = require "core.style"
local navigation_history = require "core.navigation_history"
local treesitter = require "core.treesitter"

local heading_outline = {}

local MAX_WIDTH = 260
local MIN_WIDTH = 120
local EDGE_GAP = 16
local TEXT_GAP = 32
local TOP_GAP = 28
local BOTTOM_GAP = 28
local TITLE_GAP = 14
local INDENT = 20
local FONT_SCALE = 0.875 -- of the prose font
local ROW_HEIGHT = 1.75 -- in font heights
local MARKER_HEIGHT = 0.6 -- in row heights
-- The top level and this many levels below it show.
local DEEPER_LEVELS = 2
-- The current section is the last heading above this part of the view.
local READING_LINE = 0.25
local TRANSITION = "markdown_heading_outline"

local function scaled(value)
  return math.floor(value * SCALE + 0.5)
end

local function live_mode(view)
  return require("core.markdown.live_render").is_live_mode(view)
end

-- Headings ----------------------------------------------------------------

local function heading_level(buffer, symbol)
  local hashes = (buffer.lines[symbol.start_line] or ""):match("^ ? ? ?(#+)")
  if hashes then return #hashes end
  -- A setext heading: `=` underlines level 1 and `-` level 2.
  for line = symbol.start_line + 1, symbol.end_line do
    local text = buffer.lines[line] or ""
    if text:match("^%s*=+%s*$") then return 1 end
    if text:match("^%s*%-+%s*$") then return 2 end
  end
  return 2
end

-- A heading's text without its inline Markdown syntax.
local function plain_title(text)
  text = text:gsub("%[%[([^%]]-)%]%]", function(link)
    return link:match("|(.*)$") or link
  end)
  text = text:gsub("!?%[([^%]]*)%]%b()", "%1")
  text = text:gsub("`+", "")
  text = text:gsub("%*%*", ""):gsub("__", ""):gsub("~~", ""):gsub("==", "")
  text = text:gsub("%*(%S[^%*]-)%*", "%1")
  text = (" " .. text):gsub("(%s)_(%S[^_]-)_", "%1%2"):sub(2)
  text = text:gsub("\\(%p)", "%1")
  return (text:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

-- The headings that show, rebuilt when the outline changes. While the tree
-- is parsing an edit, the last headings stay.
local function headings(view, state)
  local symbols, reason = treesitter.get_buffer_outline(view.buffer)
  if reason or symbols == state.symbols then return state.headings or {} end
  local buffer, list, top = view.buffer, {}, math.huge
  for _, symbol in ipairs(symbols) do
    if symbol.kind == "heading" then
      local level = heading_level(buffer, symbol)
      top = math.min(top, level)
      list[#list + 1] = {
        line = symbol.start_line,
        col = symbol.name_range.start.col,
        level = level,
        title = plain_title(symbol.name),
      }
    end
  end
  local shown = {}
  for _, heading in ipairs(list) do
    if heading.level <= top + DEEPER_LEVELS then
      heading.depth = heading.level - top
      shown[#shown + 1] = heading
    end
  end
  core.log_quiet("Heading Outline: %d of %d headings for %s", #shown, #list, buffer:get_name())
  state.symbols, state.headings = symbols, shown
  return shown
end

-- Where you are -----------------------------------------------------------

local function line_y(view, line)
  local _, y = view:get_line_screen_position(line)
  return y
end

-- The heading that a click moved to stays current while the caret stays on
-- it and it shows, also when the end of the document stops it below the
-- reading line.
local function picked_index(view, state, list)
  local line = state.pick_line
  if not line then return nil end
  local y = line_y(view, line)
  if view.buffer:get_selection() == line
    and y >= view.position.y and y < view.position.y + view.size.y
  then
    for index, heading in ipairs(list) do
      if heading.line == line then return index end
    end
  end
  state.pick_line = nil
end

-- The last heading above the reading line. At the end of the document, the
-- last heading on screen.
local function current_index(view, state, list)
  local picked = picked_index(view, state, list)
  if picked then return picked end
  local limit = view.position.y + view.size.y * READING_LINE
  local max_scroll = view:get_scrollable_size() - view.size.y
  if max_scroll > 0 and view.scroll.y >= max_scroll - 1 then
    limit = view.position.y + view.size.y - view:get_line_height()
  end
  local low, high, found = 1, #list, nil
  while low <= high do
    local middle = math.floor((low + high) / 2)
    if line_y(view, list[middle].line) <= limit then
      found, low = middle, middle + 1
    else
      high = middle - 1
    end
  end
  return found
end

-- Layout ------------------------------------------------------------------

local function column(view)
  local centered = core.centered_editor
  if not (centered and centered.should_center(view)) then return nil end
  local lane_x = centered.get_lane_rect(view)
  local x = view.position.x + scaled(EDGE_GAP)
  local width = math.min(scaled(MAX_WIDTH), lane_x - scaled(TEXT_GAP) - x)
  if width < scaled(MIN_WIDTH) then return nil end
  return x, width
end

local function fit_text(font, text, width)
  if font:get_width(text) <= width then return text end
  local ellipsis = "…"
  local low, high = 0, text:ulen()
  while low < high do
    local middle = math.ceil((low + high) / 2)
    if font:get_width(text:usub(1, middle) .. ellipsis) <= width then
      low = middle
    else
      high = middle - 1
    end
  end
  return low > 0 and text:usub(1, low) .. ellipsis or ""
end

local fonts = setmetatable({}, { __mode = "k" })

-- The prose font, a little smaller, as footnote cards use it.
local function outline_font()
  local base = style.markdown_body_font
  local font = fonts[base]
  if not font then
    font = base:copy(base:get_size() * FONT_SCALE)
    fonts[base] = font
  end
  return font
end

local function state_for(view)
  local state = view.__heading_outline
  if not state then
    state = { offset = 0, alpha = 0 }
    view.__heading_outline = state
  end
  return state
end

---The outline's rect, its entries, and the index of the current entry, or
---nil when the view shows no outline.
function heading_outline.layout(view)
  if not (view.buffer and live_mode(view)) then return nil end
  local x, width = column(view)
  if not x then return nil end
  local state = state_for(view)
  local list = headings(view, state)
  if #list < 2 then return nil end
  local font = outline_font()
  local row_h = math.floor(font:get_height() * ROW_HEIGHT)
  local top = view.position.y + scaled(TOP_GAP)
  local height = math.max(0, view.size.y - scaled(TOP_GAP) - scaled(BOTTOM_GAP))
  local current = current_index(view, state, list)
  -- A long list scrolls to keep the current entry in its middle.
  local content_h = #list * row_h
  local offset_target = 0
  if content_h > height and current then
    offset_target = common.clamp((current - 0.5) * row_h - height / 2, 0, content_h - height)
  end
  local offset = math.min(state.offset, math.max(0, content_h - height))
  local entries = {}
  for index, heading in ipairs(list) do
    local text_x = x + scaled(TITLE_GAP) + heading.depth * scaled(INDENT)
    local text_width = x + width - text_x
    if heading.fit_width ~= text_width or heading.fit_font ~= font then
      heading.fit_width, heading.fit_font = text_width, font
      heading.fit_title = fit_text(font, heading.title, text_width)
    end
    entries[index] = {
      line = heading.line, col = heading.col, title = heading.title, shown_title = heading.fit_title,
      x = x, y = top + (index - 1) * row_h - offset, w = width, h = row_h, text_x = text_x,
    }
  end
  return {
    x = x, y = top, w = width, h = height, row_h = row_h, font = font,
    entries = entries, current = current, offset = offset, offset_target = offset_target,
    content_h = content_h,
  }
end

local function entry_at(layout, x, y)
  if not layout or x < layout.x or x >= layout.x + layout.w
    or y < layout.y or y >= layout.y + layout.h
  then
    return nil
  end
  for index, entry in ipairs(layout.entries) do
    if y >= entry.y and y < entry.y + entry.h then return index, entry end
  end
end

-- Moving ------------------------------------------------------------------

-- Put the caret at the heading's text and scroll the heading to the top of
-- the view, one line below its edge.
local function jump(view, entry)
  navigation_history.perform_jump_with_options(view, { departure = { prefer_incoming_state = true } }, function()
    view.buffer:set_selection(entry.line, entry.col)
    view:scroll_to_line(entry.line, false, false, { top_margin = view:get_line_height() })
  end)
  state_for(view).pick_line = entry.line
  core.set_active_view(view)
  core.log_quiet("Heading Outline: moved to %q at line %d", entry.title, entry.line)
end

-- Drawing -----------------------------------------------------------------

local function faded(color, alpha)
  return { color[1], color[2], color[3], (color[4] or 255) * alpha }
end

-- Animate the list scroll, the current-entry marker, and the fade-in.
local function animate(view)
  local state = view.__heading_outline
  local layout = heading_outline.layout(view)
  if not layout then
    state.alpha, state.marker_y = 0, nil
    return
  end
  view:move_towards(state, "alpha", 1, 0.15, TRANSITION)
  view:move_towards(state, "offset", layout.offset_target, 0.25, TRANSITION)
  if layout.current then
    local target = (layout.current - 1) * layout.row_h
    if state.marker_y then
      view:move_towards(state, "marker_y", target, 0.3, TRANSITION)
    else
      state.marker_y = target
    end
  else
    state.marker_y = nil
  end
end

function heading_outline.draw(view)
  local state = view.__heading_outline
  local layout = heading_outline.layout(view)
  state.layout = layout
  if not layout or state.alpha <= 0 then return end
  local alpha = state.alpha
  local font = layout.font
  local list_top = layout.y - layout.offset
  local track_w = math.max(1, scaled(1))
  local marker_w = scaled(3)
  core.push_clip_rect(layout.x, layout.y, layout.w, layout.h)
  renderer.draw_rect(layout.x + math.floor((marker_w - track_w) / 2), list_top,
    track_w, layout.content_h, faded(style.divider, alpha))
  if state.marker_y then
    local marker_h = math.floor(layout.row_h * MARKER_HEIGHT)
    renderer.draw_rounded_rect(layout.x, list_top + state.marker_y + math.floor((layout.row_h - marker_h) / 2),
      marker_w, marker_h, marker_w / 2, faded(style.accent, alpha))
  end
  local dim, bright = faded(style.dim, alpha), faded(style.text, alpha)
  local text_y = math.floor((layout.row_h - font:get_height()) / 2)
  for index, entry in ipairs(layout.entries) do
    if entry.y + entry.h >= layout.y and entry.y <= layout.y + layout.h then
      local color = (index == layout.current or index == state.hover) and bright or dim
      renderer.draw_text(font, entry.shown_title, entry.text_x, entry.y + text_y, color)
    end
  end
  core.pop_clip_rect()
end

-- Events ------------------------------------------------------------------

local function set_hover(state, index)
  if state.hover ~= index then
    state.hover = index
    core.redraw = true
  end
end

local function on_mouse_moved(view, x, y)
  local state = view.__heading_outline
  local index = entry_at(state.layout, x, y)
  set_hover(state, index)
  if index then
    view.cursor = "hand"
    return true
  end
end

local function on_mouse_pressed(view, button, x, y)
  if button ~= "left" then return false end
  local _, entry = entry_at(heading_outline.layout(view), x, y)
  if not entry then return false end
  jump(view, entry)
  return true
end

local HOOKS = { "draw", "update", "on_mouse_moved", "on_mouse_pressed", "on_mouse_left" }

---Install the outline on a Live Preview Text View. Each hook calls the
---view's earlier hook, so detach before the layers attached before it.
function heading_outline.attach(view)
  if view.__heading_outline_hooks then return false end
  local saved = {}
  for _, name in ipairs(HOOKS) do saved[name] = rawget(view, name) or false end
  view.__heading_outline_hooks = saved
  state_for(view)
  local function previous(self, name, ...)
    local fn = saved[name] or getmetatable(self)[name]
    return fn(self, ...)
  end
  view.draw = function(self, ...)
    local result = previous(self, "draw", ...)
    heading_outline.draw(self)
    return result
  end
  view.update = function(self, ...)
    local result = previous(self, "update", ...)
    animate(self)
    return result
  end
  view.on_mouse_moved = function(self, x, y, ...)
    if on_mouse_moved(self, x, y) then return true end
    return previous(self, "on_mouse_moved", x, y, ...)
  end
  view.on_mouse_pressed = function(self, button, x, y, ...)
    if on_mouse_pressed(self, button, x, y) then return true end
    return previous(self, "on_mouse_pressed", button, x, y, ...)
  end
  view.on_mouse_left = function(self, ...)
    set_hover(self.__heading_outline, nil)
    return previous(self, "on_mouse_left", ...)
  end
  return true
end

function heading_outline.detach(view)
  local saved = view.__heading_outline_hooks
  if not saved then return false end
  for _, name in ipairs(HOOKS) do view[name] = saved[name] or nil end
  view.__heading_outline_hooks, view.__heading_outline = nil, nil
  return true
end

return heading_outline
