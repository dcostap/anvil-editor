-- Heading Outline: the document's headings, listed in the free space left of
-- the reading lane in Markdown Live Preview. It marks the section at the top
-- of the view, or the caret's section after the caret moves. A click on a
-- heading moves the caret and the view to it.
-- It shows the headings that Current Buffer Symbol Search finds.
local core = require "core"
local common = require "core.common"
local style = require "core.style"
local navigation_history = require "core.navigation_history"
local RowHighlight = require "core.row_highlight"
local markdown_model = require "core.markdown.model"

local heading_outline = {}

local MIN_WIDTH = 120
local EDGE_GAP = 16
-- From the text, so the gutter's Git change bars stay clear.
local TEXT_GAP = 24
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

local function heading_level(buffer, line1, line2)
  local hashes = (buffer.lines[line1] or ""):match("^ ? ? ?(#+)")
  if hashes then return #hashes end
  -- A setext heading: `=` underlines level 1 and `-` level 2.
  for line = line1 + 1, line2 do
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

-- A heading's name as the document outline gives it: the content text with
-- its whitespace collapsed, and without an ATX heading's closing hashes.
local function heading_name(buffer, heading_line, heading_col, line1, col1, line2, col2)
  local text
  if line1 == line2 then
    text = (buffer.lines[line1] or ""):sub(col1, math.max(col1 - 1, col2 - 1))
  else
    local parts = { (buffer.lines[line1] or ""):sub(col1) }
    for line = line1 + 1, line2 - 1 do parts[#parts + 1] = buffer.lines[line] or "" end
    parts[#parts + 1] = (buffer.lines[line2] or ""):sub(1, math.max(0, col2 - 1))
    text = table.concat(parts)
  end
  local name = text:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
  if (buffer.lines[heading_line] or ""):sub(heading_col, heading_col) == "#" then
    name = name:gsub("[ \t]+#+$", "")
  end
  return name
end

-- The headings that show, rebuilt for each parse that the Markdown model
-- publishes. While the worker parses an edit, the last headings stay. The
-- parse lists the headings, so an edit does not query the whole document on
-- the UI thread.
local function headings(view, state)
  local buffer = view.buffer
  local instance = markdown_model.peek(buffer)
  if not instance or instance.status ~= "ready"
    or instance.published_revision ~= buffer.text_revision
    or (instance == state.model and instance.generation == state.generation)
  then
    return state.headings or {}
  end
  -- An edit changes few headings. A heading that keeps its name keeps its
  -- record, so its title and its fitted title are not made again.
  local previous, by_name = state.by_name or {}, {}
  local list, top = {}, math.huge
  local found = instance:headings() or {}
  for index = 1, #found, 7 do
    local line1, col1, line2 = found[index], found[index + 1], found[index + 2]
    local content_col1 = found[index + 4]
    local name = heading_name(
      buffer, line1, col1, found[index + 3], content_col1, found[index + 5], found[index + 6]
    )
    if name ~= "" then
      local level = heading_level(buffer, line1, line2)
      top = math.min(top, level)
      local record = previous[name]
      if record then
        previous[name] = nil
      else
        record = { name = name, title = plain_title(name) }
      end
      record.line, record.col, record.level = line1, content_col1, level
      by_name[name] = by_name[name] or record
      list[#list + 1] = record
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
  state.model, state.generation, state.headings = instance, instance.generation, shown
  state.by_name = by_name
  return shown
end

-- Where you are -----------------------------------------------------------

local function heading_line(view, heading)
  return heading.line
end

local function heading_y(view, heading)
  local _, y = view:get_line_screen_position(heading.line)
  return y
end

-- The index of the last heading whose key is at or above the limit.
local function last_index(view, list, key, limit)
  local low, high, found = 1, #list, nil
  while low <= high do
    local middle = math.floor((low + high) / 2)
    if key(view, list[middle]) <= limit then
      found, low = middle, middle + 1
    else
      high = middle - 1
    end
  end
  return found
end

-- After the caret moves, the caret's section is current: the last heading at
-- or above the caret's line. A click on an entry moves the caret too. The
-- current section goes back to the reading line when the user scrolls.
-- Each Text View has its own caret. The Buffer's selection belongs to the
-- focused view, so the outline listens to its own view.
local function on_selection_changed(view, selection_state)
  local state = view.__heading_outline
  local selections = selection_state.selections
  state.caret_line = selections[(selection_state.last_selection - 1) * 4 + 1] or selections[1]
  state.follow_caret = true
end

-- The last heading above the reading line. At the end of the document, the
-- last heading on screen.
local function current_index(view, state, list)
  if state.follow_caret and state.caret_line then
    return last_index(view, list, heading_line, state.caret_line)
  end
  local limit = view.position.y + view.size.y * READING_LINE
  local max_scroll = view:get_scrollable_size() - view.size.y
  if max_scroll > 0 and view.scroll.y >= max_scroll - 1 then
    limit = view.position.y + view.size.y - view:get_line_height()
  end
  return last_index(view, list, heading_y, limit)
end

-- Layout ------------------------------------------------------------------

local function column(view)
  local centered = core.centered_editor
  if not (centered and centered.should_center(view)) then return nil end
  local text_x = centered.get_lane_rect(view) + view:get_gutter_width()
  local x = view.position.x + scaled(EDGE_GAP)
  local width = text_x - scaled(TEXT_GAP) - x
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
    state = { offset = 0, alpha = 0, marker = RowHighlight(RowHighlight.selection) }
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
  -- The headings stay until the outline changes, so each one keeps its
  -- entry fields. A long document has thousands of headings, and layout runs
  -- in each update and draw.
  for index, heading in ipairs(list) do
    local text_x = x + scaled(TITLE_GAP) + heading.depth * scaled(INDENT)
    local text_width = x + width - text_x
    if heading.fit_width ~= text_width or heading.fit_font ~= font then
      heading.fit_width, heading.fit_font = text_width, font
      heading.shown_title = fit_text(font, heading.title, text_width)
    end
    heading.x, heading.y, heading.w, heading.h = x, top + (index - 1) * row_h - offset, width, row_h
    heading.text_x = text_x
  end
  return {
    x = x, y = top, w = width, h = height, row_h = row_h, font = font,
    entries = list, current = current, offset = offset, offset_target = offset_target,
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
    view:with_selection_state(function() view.buffer:set_selection(entry.line, entry.col) end)
    view:scroll_to_line(entry.line, false, false, { top_margin = view:get_line_height() })
  end)
  local state = state_for(view)
  state.follow_caret, state.caret_line = true, entry.line
  core.set_active_view(view)
  core.log_quiet("Heading Outline: moved to %q at line %d", entry.title, entry.line)
end

-- Drawing -----------------------------------------------------------------

-- Each color has one table in the view's state, written again in each draw.
local function faded(state, key, color, alpha)
  local result = state[key] or {}
  state[key] = result
  result[1], result[2], result[3], result[4] = color[1], color[2], color[3], (color[4] or 255) * alpha
  return result
end

-- The current entry's text color. While the marker glides, the entry that it
-- leaves dims as the entry that it reaches brightens. At most two entries are
-- between those colors, one with an odd index and one with an even index.
local function entry_color(state, index, row_h, dim, bright)
  local marker = state.marker
  if not marker.alpha then return dim end
  local near = 1 - math.abs(marker.y + marker.h / 2 - (index - 0.5) * row_h) / row_h
  local amount = common.clamp(near, 0, 1) * marker.alpha
  if amount <= 0 then return dim end
  if amount >= 1 then return bright end
  local key = index % 2 == 0 and "even_color" or "odd_color"
  local result = state[key] or {}
  state[key] = result
  for i = 1, 4 do result[i] = dim[i] + (bright[i] - dim[i]) * amount end
  return result
end

-- Animate the list scroll, the current-entry marker, and the fade-in. The
-- marker glides like the Project Sidebar's selection.
local function animate(view)
  local state = view.__heading_outline
  local layout = heading_outline.layout(view)
  if not layout then
    state.alpha = 0
    state.marker:reset()
    return
  end
  view:move_towards(state, "alpha", 1, 0.15, TRANSITION)
  view:move_towards(state, "offset", layout.offset_target, 0.25, TRANSITION)
  if layout.current then
    local marker_h = math.floor(layout.row_h * MARKER_HEIGHT)
    state.marker:step((layout.current - 1) * layout.row_h + math.floor((layout.row_h - marker_h) / 2), marker_h)
  else
    state.marker:step()
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
    track_w, layout.content_h, faded(state, "track_color", style.divider, alpha))
  state.marker:draw(layout.x, list_top, marker_w, marker_w / 2, faded(state, "marker_color", style.accent, alpha))
  local dim = faded(state, "dim_color", style.dim, alpha)
  local bright = faded(state, "bright_color", style.text, alpha)
  local text_y = math.floor((layout.row_h - font:get_height()) / 2)
  for index, entry in ipairs(layout.entries) do
    if entry.y + entry.h >= layout.y and entry.y <= layout.y + layout.h then
      local color = index == state.hover and bright or entry_color(state, index, layout.row_h, dim, bright)
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
  local _, entry = entry_at(heading_outline.layout(view), x, y)
  if not (entry and button == "left") then
    if view:scrollbar_overlaps_point(x, y) then view.__heading_outline.follow_caret = false end
    return false
  end
  jump(view, entry)
  return true
end

local HOOKS = { "draw", "update", "on_mouse_moved", "on_mouse_pressed", "on_mouse_left", "on_mouse_wheel" }

---Install the outline on a Live Preview Text View. Each hook calls the
---view's earlier hook, so detach before the layers attached before it.
function heading_outline.attach(view)
  if view.__heading_outline_hooks then return false end
  local saved = {}
  for _, name in ipairs(HOOKS) do saved[name] = rawget(view, name) or false end
  view.__heading_outline_hooks = saved
  state_for(view)
  view:add_selection_listener("heading_outline", on_selection_changed)
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
  view.on_mouse_wheel = function(self, ...)
    self.__heading_outline.follow_caret = false
    return previous(self, "on_mouse_wheel", ...)
  end
  return true
end

function heading_outline.detach(view)
  local saved = view.__heading_outline_hooks
  if not saved then return false end
  for _, name in ipairs(HOOKS) do view[name] = saved[name] or nil end
  view:remove_selection_listener("heading_outline")
  view.__heading_outline_hooks, view.__heading_outline = nil, nil
  return true
end

return heading_outline
