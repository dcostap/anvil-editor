local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local style = require "core.style"
local project_paths = require "core.project_paths"
local TextView = require "core.textview"
local GlobalPromptBar = require "core.global_prompt_bar"
local LogView = require "core.logview"
local ImageView = require "core.imageview"
local View = require "core.view"
local Object = require "core.object"


---Styled text array containing fonts, colors, and strings.
---@alias core.statusbar.styledtext table<integer, renderer.font|renderer.color|string>


---Compact Status Bar made of items. Each item is a chip: hovering shows its
---tooltip, and an item with an action highlights and runs that action on a
---left click. Temporary messages and widget tooltips replace the left items;
---right items stay visible.
---Access the global instance via `core.status_bar`.
---@class core.statusbar : core.view
---@field super core.view
---@field items core.statusbar.item[] All registered items
---@field active_items core.statusbar.item[] Visible items that pass their predicates
---@field hovered_item core.statusbar.item|nil Item under the pointer
---@field pressed_item core.statusbar.item|nil Item that received the current left press
---@field message_timeout number Timestamp when the current message expires
---@field message_pulse_start number Timestamp when the current message pulse started
---@field message table|nil Current temporary message
---@field tooltip_mode boolean Whether a persistent tooltip replaces the left items
---@field tooltip core.statusbar.styledtext Persistent tooltip content
---@field left_limit number Right edge of the left items, relative to the Status Bar
---@field hide_messages boolean Whether to suppress status messages
local StatusBar = View:extend()

function StatusBar:__tostring() return "StatusBar" end

local function statusbar_font()
  return style.get_small_font(style.font)
end

local MESSAGE_PULSE_DURATION = 0.15
local MESSAGE_PULSE_AMPLITUDE = 3 * SCALE
local MESSAGE_MIN_LENGTH = 20
local MESSAGE_MAX_LENGTH = 100
local MESSAGE_MAX_TIMEOUT_MULTIPLIER = 4
local TOOLTIP_DELAY = 0.35
-- After one tooltip shows, moving to a neighbor shows its tooltip at once.
local TOOLTIP_GRACE = 0.6
local ELLIPSIS = "…"

local function metrics()
  return {
    edge = common.round(style.padding.x * 0.5),
    chip = common.round(style.padding.x * 0.45),
    gap = common.round(2 * SCALE),
    inset = common.round(2 * SCALE),
    radius = common.round(4 * SCALE),
  }
end

local function message_text_length(text)
  if type(text) ~= "string" then text = tostring(text or "") end
  local ok, len = pcall(function() return text:ulen(nil, nil, true) end)
  return ok and len or #text
end

local function message_timeout_duration(text)
  local base = config.message_timeout
  local length = message_text_length(text)
  if length <= MESSAGE_MIN_LENGTH then return base end
  if length >= MESSAGE_MAX_LENGTH then return base * MESSAGE_MAX_TIMEOUT_MULTIPLIER end

  local progress = (length - MESSAGE_MIN_LENGTH) / (MESSAGE_MAX_LENGTH - MESSAGE_MIN_LENGTH)
  return base * (1 + progress * (MESSAGE_MAX_TIMEOUT_MULTIPLIER - 1))
end


---@alias core.statusbar.item.predicate fun():boolean
---@alias core.statusbar.item.onclick fun(button: string, x: number, y: number)
---@alias core.statusbar.item.get_item fun(self: core.statusbar.item):core.statusbar.styledtext?
---@alias core.statusbar.item.ondraw fun(x, y, h, hovered: boolean, calc_only?: boolean):number
---Returns the tooltip text, which may contain newlines, and an optional dim action hint.
---@alias core.statusbar.item.gettooltip fun(self: core.statusbar.item):string?,string?

---Individual Status Bar item.
---@class core.statusbar.item : core.object
---@field name string Unique identifier for the item
---@field predicate core.statusbar.item.predicate Condition to display item
---@field alignment core.statusbar.item.alignment Left or right side placement
---@field tooltip string|core.statusbar.item.gettooltip|nil Text shown on hover
---@field command string|nil Command name to execute on click
---@field on_click core.statusbar.item.onclick|nil Click handler function
---@field can_click fun():boolean|nil Whether the click action applies now
---@field on_draw core.statusbar.item.ondraw|nil Custom drawing function
---@field shrink boolean Whether the item elides its start to fit the space left
---@field visible boolean Whether item is shown
---@field active boolean Whether item passes predicate check
---@field x number Chip x position relative to the Status Bar (calculated)
---@field w number Chip width in pixels (calculated)
---@field visible_w number Unclipped chip width in pixels (calculated)
---@field cached_item core.statusbar.styledtext Cached content
local StatusBarItem = Object:extend()

function StatusBarItem:__tostring() return "StatusBarItem" end

---Options for creating a Status Bar item.
---@class core.statusbar.item.options : table
---@field predicate string|table|core.statusbar.item.predicate Condition for display (string=module, table=class, function=custom, nil=always)
---@field name string Unique identifier for the item
---@field alignment core.statusbar.item.alignment Left or right side placement
---@field get_item core.statusbar.item.get_item|core.statusbar.styledtext Styled text, or a function returning it
---@field command string|core.statusbar.item.onclick|nil Command name or click callback
---@field can_click? fun():boolean Whether the click action applies now
---@field position? integer Insertion position (-1=end, 1=beginning)
---@field tooltip? string|core.statusbar.item.gettooltip Text displayed on hover
---@field visible? boolean Initial visibility state
---@field shrink? boolean Elide the start of the content when space runs out

---Align item on left side of status bar.
---@type integer
StatusBarItem.LEFT = 1

---Align item on right side of status bar.
---@type integer
StatusBarItem.RIGHT = 2

---@alias core.statusbar.item.alignment
---|>`StatusBar.Item.LEFT`
---| `StatusBar.Item.RIGHT`

---Create a new status bar item.
---@param options core.statusbar.item.options
function StatusBarItem:new(options)
  self:set_predicate(options.predicate)
  self.name = options.name
  self.alignment = options.alignment or StatusBar.Item.LEFT
  self.command = type(options.command) == "string" and options.command or nil
  self.on_click = type(options.command) == "function" and options.command or nil
  self.can_click = options.can_click
  self.tooltip = options.tooltip
  self.on_draw = options.on_draw
  self.shrink = options.shrink == true
  self.visible = options.visible == nil and true or options.visible
  self.active = false
  self.x = 0
  self.w = 0
  self.visible_w = 0
  self.get_item = options.get_item
end

---Generate the styled text for this item.
---Override this method or pass `get_item` in options.
---Ignored if `on_draw` is set.
---@return core.statusbar.styledtext
function StatusBarItem:get_item() return {} end

---Hide the item from the status bar.
function StatusBarItem:hide() self.visible = false end

---Show the item on the status bar.
function StatusBarItem:show() self.visible = true end

---Set the condition to evaluate whether this item should be displayed.
---String: treated as module name (e.g. "core.textview"), checked against active view.
---Table: treated as class, checked against active view with `extends()`.
---Function: called each update, should return boolean.
---Nil: always displays the item.
---@param predicate string|table|core.statusbar.item.predicate
function StatusBarItem:set_predicate(predicate)
  self.predicate = command.generate_predicate(predicate)
end

---Report whether a left click on this item runs an action now.
---@return boolean
function StatusBarItem:is_clickable()
  if not self.command and not self.on_click then return false end
  return self.can_click == nil or self.can_click() == true
end

---Get the hover text and the optional action hint.
---@return string? text
---@return string? hint
function StatusBarItem:get_tooltip()
  if type(self.tooltip) == "function" then return self.tooltip(self) end
  if self.tooltip == "" then return nil end
  return self.tooltip
end

---@type core.statusbar.item
StatusBar.Item = StatusBarItem


---Iterate the strings of styled text with their font and color.
local function each_segment(styled, fn)
  local font = statusbar_font()
  local color = style.text
  for _, part in ipairs(styled) do
    if Object.is(part, renderer.font) then
      font = part
    elseif type(part) == "table" then
      color = part
    elseif part ~= nil then
      fn(font, color, tostring(part))
    end
  end
end

local function styled_width(styled)
  local w = 0
  each_segment(styled, function(font, _, text) w = w + font:get_width(text) end)
  return w
end

local function draw_styled(styled, x, y, h)
  each_segment(styled, function(font, color, text)
    local ty = common.round(y + (h - font:get_height()) / 2)
    x = renderer.draw_text(font, text, common.round(x), ty, color)
  end)
  return x
end

---Drop text from the start of styled text so it fits in `max_w`.
---@return core.statusbar.styledtext
local function elide_start(styled, max_w)
  local total = styled_width(styled)
  if total <= max_w then return styled end
  local font = statusbar_font()
  local need = total - max_w + font:get_width(ELLIPSIS)
  local dropped = 0
  local out = { font, style.dim, ELLIPSIS }
  each_segment(styled, function(seg_font, color, text)
    if dropped < need then
      local w = seg_font:get_width(text)
      if dropped + w <= need then
        dropped = dropped + w
        return
      end
      while text ~= "" and dropped < need do
        local ch = text:match("^[%z\1-\127\194-\244][\128-\191]*") or text:sub(1, 1)
        dropped = dropped + seg_font:get_width(ch)
        text = text:sub(#ch + 1)
      end
      if text == "" then return end
    end
    table.insert(out, seg_font)
    table.insert(out, color)
    table.insert(out, text)
  end)
  return out
end


---Get the active Text View, excluding the Global Prompt Bar.
---@return core.textview|nil
local function active_textview()
  local view = core.active_view
  if view and view:extends(TextView) and not view:is(GlobalPromptBar) then
    return view
  end
end

---Check if active view is a Text View (but not the Global Prompt Bar).
---@return boolean
local function predicate_textview()
  return active_textview() ~= nil
end

local function plural(n, word)
  return string.format("%d %s%s", n, word, n == 1 and "" or "s")
end

local selection_counts_cache = {
  buffer = nil,
  key = nil,
  carets = 0,
  chars = 0,
  selected_lines = 0,
  chars_pending = false
}

local max_sync_selection_count_bytes = 200000
local max_sync_selection_count_lines = 2000

local function perf_stat_add(key, amount)
  local stats = core.perf_frame_stats
  if stats then stats[key] = (stats[key] or 0) + (amount or 1) end
  local perf = package.loaded["core.perf"]
  if perf and perf.add_detail then perf.add_detail(key, amount or 1) end
end

local function get_buffer_selection_counts(buffer)
  local perf_t = core.perf_frame_stats and system.get_time()
  local carets = math.floor(#buffer.selections / 4)
  local key = tostring(buffer:get_change_id()) .. ":" .. tostring(buffer.selection_revision or 0) .. ":" .. tostring(#buffer.selections)
  if selection_counts_cache.buffer == buffer and selection_counts_cache.key == key then
    perf_stat_add("statusbar_selection_cache_hits", 1)
    if perf_t then perf_stat_add("statusbar_selection_ms", (system.get_time() - perf_t) * 1000) end
    return
      selection_counts_cache.carets,
      selection_counts_cache.chars,
      selection_counts_cache.selected_lines,
      selection_counts_cache.chars_pending
  end

  perf_stat_add("statusbar_selection_cache_misses", 1)
  local chars = 0
  local selected_lines = 0
  local seen_lines = {}
  local count_chars = true
  local estimated_bytes = 0
  local estimated_lines = 0

  for _, line1, col1, line2, col2 in buffer:get_selections(true) do
    if line1 ~= line2 or col1 ~= col2 then
      estimated_lines = estimated_lines + line2 - line1 + 1
      if count_chars then
        if line1 == line2 then
          estimated_bytes = estimated_bytes + math.max(0, col2 - col1)
        else
          estimated_bytes = estimated_bytes + #buffer.lines[line1] - col1 + 1 + col2 - 1
          for line = line1 + 1, line2 - 1 do
            estimated_bytes = estimated_bytes + #buffer.lines[line]
            if estimated_bytes > max_sync_selection_count_bytes then break end
          end
        end
        if
          estimated_bytes > max_sync_selection_count_bytes
          or estimated_lines > max_sync_selection_count_lines
        then
          count_chars = false
        end
      end
      if count_chars then
        chars = chars + buffer:get_text(line1, col1, line2, col2):ulen(nil, nil, true) - (line2 - line1)
      end
      for line = line1, line2 do
        if not seen_lines[line] then
          seen_lines[line] = true
          selected_lines = selected_lines + 1
        end
      end
    end
  end

  selection_counts_cache.buffer = buffer
  selection_counts_cache.key = key
  selection_counts_cache.carets = carets
  selection_counts_cache.chars = count_chars and chars or 0
  selection_counts_cache.selected_lines = selected_lines
  selection_counts_cache.chars_pending = not count_chars

  if perf_t then perf_stat_add("statusbar_selection_ms", (system.get_time() - perf_t) * 1000) end
  return carets, selection_counts_cache.chars, selected_lines, not count_chars
end

---Get the caret line and its display column, counting hard tabs as the indent width.
local function caret_line_col(dv)
  local line, col = dv.buffer:sanitize_position(dv.buffer:get_selection())
  local line_text = dv.buffer:get_utf8_line(line)
  local byte_col = col
  if config.caret_column_mode == "char" then
    col = line_text:ulen(1, byte_col, true)
  end
  local tab_type, indent_size = dv.buffer:get_indent_info()
  local ntabs = 0
  if tab_type == "hard" then
    local last_idx = 0
    while last_idx < byte_col do
      local s, e = string.find(line_text, "\t", last_idx, true)
      if s and s < byte_col then
        ntabs = ntabs + 1
        last_idx = e + 1
      else
        break
      end
    end
  end
  return line, col + ntabs * (indent_size - 1)
end

---Split a display path into styled directory and file name parts.
local function styled_path(display)
  local text = display.text
  local base_start = (text:match("^.*()[/\\]") or 0) + 1
  local prefix = display.prefix_span
  if prefix and prefix[2] < base_start then
    return {
      style.accent, text:sub(prefix[1], prefix[2]),
      style.dim, text:sub(prefix[2] + 1, base_start - 1),
      style.text, text:sub(base_start),
    }
  elseif prefix then
    return { style.accent, text:sub(prefix[1], prefix[2]), style.text, text:sub(prefix[2] + 1) }
  end
  return { style.dim, text:sub(1, base_start - 1), style.text, text:sub(base_start) }
end

---Ask the user to pick one action, then perform its command.
---@param label string
---@param actions { text: string, info?: string, command: string }[]
local function choose_command(label, actions)
  local mt = { __tostring = function(x) return x.text end }
  for _, action in ipairs(actions) do setmetatable(action, mt) end
  core.global_prompt_bar:enter(label, {
    submit = function(_, item)
      if item and item.command then command.perform(item.command) end
    end,
    suggest = function(text)
      return common.fuzzy_match(actions, text)
    end,
    validate = function(_, item) return item ~= nil end,
  })
end

local function copy_path(path)
  system.set_clipboard(path)
  core.log_quiet("Status Bar copied path: %s", path)
  core.status_bar:show_message("i", style.text, "Copied " .. common.home_encode(path))
end


---Create a new status bar and register default items.
function StatusBar:new()
  StatusBar.super.new(self)
  self.message_timeout = 0
  self.message_pulse_start = 0
  self.message = nil
  self.tooltip_mode = false
  self.tooltip = {}
  self.items = {}
  self.active_items = {}
  self.hovered_item = nil
  self.pressed_item = nil
  self.hover_start = 0
  self.tooltip_shown_at = -math.huge
  self.tooltip_dismissed = nil
  self.left_limit = 0
  self.hide_messages = false
  self.visible = true

  self.message_item = StatusBar.Item({
    name = "message",
    command = function()
      if not (core.active_view and core.active_view:is(LogView)) then
        command.perform "log:open"
      end
    end,
    tooltip = function()
      return self.message and self.message.text, "Click to open the log"
    end,
  })

  self:register_textview_items()
  self:register_imageview_items()
end

---Register default status bar items for Text Views.
function StatusBar:register_textview_items()
  if self:get_item("text:file") then return end

  self:add_item({
    predicate = predicate_textview,
    name = "text:file",
    alignment = StatusBar.Item.LEFT,
    shrink = true,
    get_item = function()
      local dv = core.active_view
      if dv.buffer.abs_filename then
        local display = project_paths.display_path(dv.buffer.abs_filename, { kind = "file" })
        if display and display.text then return styled_path(display) end
      end
      local buffer_name = dv.buffer.intellij_untitled_name or dv.buffer:get_name()
      return { dv.buffer.filename and style.text or style.dim, common.home_encode(buffer_name) }
    end,
    tooltip = function()
      local dv = active_textview()
      if not dv then return nil end
      if dv.buffer.abs_filename then
        return common.home_encode(dv.buffer.abs_filename), "Click to copy the full path"
      end
      return "Not saved to a file"
    end,
    can_click = function()
      local dv = active_textview()
      return dv ~= nil and dv.buffer.abs_filename ~= nil
    end,
    command = function()
      local dv = active_textview()
      if dv and dv.buffer.abs_filename then copy_path(dv.buffer.abs_filename) end
    end,
  })

  self:add_item({
    predicate = predicate_textview,
    name = "text:selection",
    alignment = StatusBar.Item.RIGHT,
    get_item = function()
      local dv = active_textview()
      if not dv then return {} end
      local carets, chars, lines, chars_pending = get_buffer_selection_counts(dv.buffer)
      local parts = {}
      if carets > 1 then table.insert(parts, plural(carets, "caret")) end
      if chars > 0 then table.insert(parts, plural(chars, "char")) end
      if lines > 1 or (lines > 0 and chars_pending) then table.insert(parts, plural(lines, "line")) end
      local styled = {}
      for i, part in ipairs(parts) do
        if i > 1 then
          table.insert(styled, style.dim)
          table.insert(styled, " · ")
        end
        table.insert(styled, style.text)
        table.insert(styled, part)
      end
      return styled
    end,
    tooltip = function()
      local dv = active_textview()
      if not dv then return nil end
      local carets, chars, lines, chars_pending = get_buffer_selection_counts(dv.buffer)
      local text = {}
      if lines > 0 then
        table.insert(text, chars_pending
          and string.format("%s selected (too large to count characters)", plural(lines, "line"))
          or string.format("%s selected across %s", plural(chars, "character"), plural(lines, "line")))
      end
      if carets > 1 then table.insert(text, plural(carets, "caret")) end
      return table.concat(text, "\n")
    end,
  })

  self:add_item({
    predicate = predicate_textview,
    name = "text:position",
    alignment = StatusBar.Item.RIGHT,
    get_item = function()
      local dv = active_textview()
      if not dv then return {} end
      local line, col = caret_line_col(dv)
      return {
        style.text, tostring(line),
        style.dim, ":",
        col > config.line_limit and style.accent or style.text, tostring(col),
      }
    end,
    tooltip = function()
      local dv = active_textview()
      if not dv then return nil end
      local line, col = caret_line_col(dv)
      local count = #dv.buffer.lines
      local text = string.format("Line %d of %d (%.f%%), column %d", line, count, line / count * 100, col)
      if col > config.line_limit then
        text = text .. string.format("\nPast the %d-column line limit", config.line_limit)
      end
      return text, "Click to go to a line"
    end,
    command = "editor:go_to_line",
  })

  self:add_item({
    predicate = predicate_textview,
    name = "text:indentation",
    alignment = StatusBar.Item.RIGHT,
    get_item = function()
      local dv = active_textview()
      if not dv then return {} end
      local indent_type, indent_size, confirmed = dv.buffer:get_indent_info()
      return {
        confirmed and style.text or style.dim,
        string.format("%s: %d", indent_type == "hard" and "Tabs" or "Spaces", indent_size),
      }
    end,
    tooltip = function()
      local dv = active_textview()
      if not dv then return nil end
      local indent_type, indent_size, confirmed = dv.buffer:get_indent_info()
      local text = indent_type == "hard"
        and string.format("Indents with tabs, %d columns wide", indent_size)
        or string.format("Indents with %s", plural(indent_size, "space"))
      if not confirmed then text = text .. "\nEditor default: the file shows no clear indentation" end
      return text, "Click to change indentation"
    end,
    command = "editor:set_file_indentation",
  })

  self:add_item({
    predicate = predicate_textview,
    name = "text:encoding",
    alignment = StatusBar.Item.RIGHT,
    get_item = function()
      local dv = active_textview()
      if not dv then return {} end
      local styled = { style.text, dv.buffer.encoding or "none" }
      if dv.buffer.bom then
        table.insert(styled, style.dim)
        table.insert(styled, " BOM")
      end
      return styled
    end,
    tooltip = function()
      local dv = active_textview()
      if not dv then return nil end
      local text = "Encoding: " .. (dv.buffer.encoding or "none")
      if dv.buffer.bom then text = text .. " with byte order mark" end
      return text, "Click to save or reopen with another encoding"
    end,
    command = function()
      choose_command("Encoding", {
        { text = "Save with Encoding", info = "convert this file", command = "editor:change_encoding" },
        { text = "Reopen with Encoding", info = "reread this file", command = "editor:reload_with_encoding" },
      })
    end,
  })

  self:add_item({
    predicate = predicate_textview,
    name = "text:line-ending",
    alignment = StatusBar.Item.RIGHT,
    get_item = function()
      local dv = active_textview()
      if not dv then return {} end
      return { style.text, dv.buffer.crlf and "CRLF" or "LF" }
    end,
    tooltip = function()
      local dv = active_textview()
      if not dv then return nil end
      return dv.buffer.crlf and "Line endings: CRLF (Windows)" or "Line endings: LF (Unix)",
        "Click to change line endings"
    end,
    command = "editor:select_line_ending",
  })
end


---Register default status bar items for image views.
function StatusBar:register_imageview_items()
  local function active_image()
    local view = core.active_view
    return view and view:is(ImageView) and view.image and view or nil
  end

  self:add_item({
    predicate = ImageView,
    name = "image-view:file",
    alignment = StatusBar.Item.LEFT,
    shrink = true,
    get_item = function()
      local view = active_image()
      if not view then return {} end
      return { style.text, common.basename(view.path) }
    end,
    tooltip = function()
      local view = active_image()
      return view and common.home_encode(view.path), "Click to copy the full path"
    end,
    command = function()
      local view = active_image()
      if view then copy_path(view.path) end
    end,
  })

  self:add_item({
    predicate = ImageView,
    name = "image-view:size",
    alignment = StatusBar.Item.RIGHT,
    get_item = function()
      local view = active_image()
      if not view then return {} end
      local w, h = view.image:get_size()
      return { style.text, string.format("%d × %d", w, h) }
    end,
    tooltip = "Image size in pixels",
  })

  self:add_item({
    predicate = ImageView,
    name = "image-view:zoom",
    alignment = StatusBar.Item.RIGHT,
    get_item = function()
      local view = active_image()
      if not view then return {} end
      return { style.text, string.format("%.0f%%", view.zoom_scale * 100) }
    end,
    tooltip = function() return "Zoom", "Click to reset zoom" end,
    command = "image:zoom_reset",
  })
end


---Normalize item position handling negative indices and alignment.
---@param self core.statusbar
---@param position integer Position (negative for reverse order)
---@param alignment core.statusbar.item.alignment
---@return integer position Normalized position index
local function normalize_position(self, position, alignment)
  local offset = 0
  local items_count = 0
  local left = self:get_items_list(1)
  local right = self:get_items_list(2)
  if alignment == 2 then
    items_count = #right
    offset = #left
  else
    items_count = #left
  end
  if position == 0 then
    position = offset +  1
  elseif position < 0 then
    position = offset + items_count + (position + 2)
  else
    position = offset + position
  end
  if position < 1 then
    position = offset + 1
  elseif position > #left + #right then
    position = offset + items_count + 1
  end
  return position
end


---Add a new item to the status bar.
---@param options core.statusbar.item.options
---@return core.statusbar.item item The created item
function StatusBar:add_item(options)
  assert(self:get_item(options.name) == nil, "status item already exists: " .. options.name)
  ---@type core.statusbar.item
  local item = StatusBar.Item(options)
  table.insert(self.items, normalize_position(self, options.position or -1, options.alignment), item)
  return item
end


---Get a status bar item by name.
---@param name string Unique item name
---@return core.statusbar.item|nil item The item or nil if not found
function StatusBar:get_item(name)
  for _, item in ipairs(self.items) do
    if item.name == name then return item end
  end
  return nil
end


---Get all items or items filtered by alignment.
---@param alignment? core.statusbar.item.alignment Filter by left or right alignment
---@return core.statusbar.item[] items List of items
function StatusBar:get_items_list(alignment)
  if alignment then
    local items = {}
    for _, item in ipairs(self.items) do
      if item.alignment == alignment then
        table.insert(items, item)
      end
    end
    return items
  end
  return self.items
end


---Move an item to a different position.
---@param name string Item name to move
---@param position integer New position (negative for reverse order)
---@param alignment? core.statusbar.item.alignment Optional new alignment
---@return boolean moved True if item was found and moved
function StatusBar:move_item(name, position, alignment)
  assert(name, "no name provided")
  assert(position, "no position provided")
  local item = nil
  for pos, it in ipairs(self.items) do
    if it.name == name then
      item = table.remove(self.items, pos)
      break
    end
  end
  if item then
    if alignment then
      item.alignment = alignment
    end
    position = normalize_position(self, position, item.alignment)
    table.insert(self.items, position, item)
    return true
  end
  return false
end


---Remove an item from the status bar.
---@param name string Item name to remove
---@return core.statusbar.item|nil removed_item The removed item or nil
function StatusBar:remove_item(name)
  for pos, it in ipairs(self.items) do
    if it.name == name then
      return table.remove(self.items, pos)
    end
  end
end


---Reorder items by the given name list.
---Items are placed at the beginning in the order specified.
---@param names table<integer, string> List of item names in desired order
function StatusBar:order_items(names)
  local removed_items = {}
  for _, name in ipairs(names) do
    local item = self:remove_item(name)
    if item then table.insert(removed_items, item) end
  end

  for i, item in ipairs(removed_items) do
    table.insert(self.items, i, item)
  end
end


---Hide the status bar.
function StatusBar:hide()
  self.visible = false
end


---Show the status bar.
function StatusBar:show()
  self.visible = true
end


---Toggle status bar visibility.
function StatusBar:toggle()
  self.visible = not self.visible
end


---Hide specific items or all items if no names provided.
---@param names? table<integer, string>|string Single name or list of item names
function StatusBar:hide_items(names)
  if type(names) == "string" then
    names = {names}
  end
  if not names then
    for _, item in ipairs(self.items) do
      item:hide()
    end
    return
  end
  for _, name in ipairs(names) do
    local item = self:get_item(name)
    if item then item:hide() end
  end
end


---Show specific items or all items if no names provided.
---@param names? table<integer, string>|string Single name or list of item names
function StatusBar:show_items(names)
  if type(names) == "string" then
    names = {names}
  end
  if not names then
    for _, item in ipairs(self.items) do
      item:show()
    end
    return
  end
  for _, name in ipairs(names) do
    local item = self:get_item(name)
    if item then item:show() end
  end
end


---Display a temporary message in place of the left items.
---Message duration uses `config.message_timeout` as the minimum, then scales
---linearly up to four times that value for longer messages.
---@param icon string Icon character to display
---@param icon_color renderer.color Icon color
---@param text string Message text
function StatusBar:show_message(icon, icon_color, text)
  if not self.visible or self.hide_messages then return end
  self.message = {
    icon = icon,
    icon_color = icon_color,
    text = text
  }
  local now = system.get_time()
  self.message_timeout = now + message_timeout_duration(text)
  self.message_pulse_start = now
  core.redraw = true
end


---Enable or disable system messages on the status bar.
---@param enable boolean True to show messages, false to hide them
function StatusBar:display_messages(enable)
  self.hide_messages = not enable
end


---Show a persistent tooltip in place of the left items.
---Remains visible until `remove_tooltip()` is called.
---@param text string|core.statusbar.styledtext Plain text or styled text array
function StatusBar:show_tooltip(text)
  self.tooltip = type(text) == "table" and text or { text }
  self.tooltip_mode = true
end


---Hide the persistent tooltip and restore normal status bar items.
function StatusBar:remove_tooltip()
  self.tooltip_mode = false
end


local function message_active(self)
  return self.message ~= nil and system.get_time() <= self.message_timeout
end

local function get_rendered_message(self)
  return {
    self.message.icon_color, style.icon_font, self.message.icon,
    statusbar_font(), style.text, "  " .. tostring(self.message.text),
  }
end

local function get_message_pulse_yoffset(self)
  local elapsed = system.get_time() - self.message_pulse_start
  if elapsed < 0 or elapsed >= MESSAGE_PULSE_DURATION then return 0 end
  local t = elapsed / MESSAGE_PULSE_DURATION
  return math.sin(t * math.pi) * MESSAGE_PULSE_AMPLITUDE
end


---Rebuild the active items and lay them out as chips.
---Right items keep their full width; left items use the space that is left.
function StatusBar:update_active_items()
  local m = metrics()
  local lefts, rights = {}, {}
  self.active_items = {}

  for _, item in ipairs(self.items) do
    item.active = false
    item.cached_item = nil
    if item.visible and item:predicate() then
      local styled, content_w
      if item.on_draw then
        content_w = item.on_draw(0, self.position.y, self.size.y, self.hovered_item == item, true)
      else
        styled = type(item.get_item) == "function" and item.get_item(item) or item.get_item
        content_w = styled and #styled > 0 and styled_width(styled) or 0
      end
      if content_w > 0 then
        item.active = true
        item.cached_item = styled
        item.w = content_w + m.chip * 2
        table.insert(item.alignment == StatusBar.Item.RIGHT and rights or lefts, item)
      end
    end
  end

  local x = self.size.x - m.edge
  for i = #rights, 1, -1 do
    local item = rights[i]
    x = x - item.w
    item.x = x
    item.visible_w = item.w
    x = x - m.gap
  end
  local right_start = #rights > 0 and x + m.gap or self.size.x - m.edge
  self.left_limit = math.max(m.edge, right_start - style.padding.x)

  x = m.edge
  for _, item in ipairs(lefts) do
    if item.shrink then item.w = math.max(0, math.min(item.w, self.left_limit - x)) end
    item.x = x
    item.visible_w = math.max(0, math.min(item.w, self.left_limit - x))
    x = x + item.w + m.gap
  end

  local message = self.message_item
  if message_active(self) then
    message.active = true
    message.x = m.edge
    message.w = styled_width(get_rendered_message(self)) + m.chip * 2
    message.visible_w = math.max(0, math.min(message.w, self.left_limit - m.edge))
  else
    message.active = false
  end

  for _, item in ipairs(lefts) do table.insert(self.active_items, item) end
  for _, item in ipairs(rights) do table.insert(self.active_items, item) end
end


---Find the item under a point.
---@param x number
---@param y number
---@return core.statusbar.item|nil
function StatusBar:get_item_at(x, y)
  if y < self.position.y or y >= self.position.y + self.size.y then return nil end
  local rx = x - self.position.x
  local function hit(item)
    return item.active and item.visible_w > 0 and rx >= item.x and rx < item.x + item.visible_w
  end
  if self.message_item.active and hit(self.message_item) then return self.message_item end
  local left_replaced = self.message_item.active or self.tooltip_mode
  for _, item in ipairs(self.active_items) do
    if (item.alignment == StatusBar.Item.RIGHT or not left_replaced) and hit(item) then
      return item
    end
  end
end


local function set_hovered(self, item)
  if self.hovered_item == item then return end
  self.hovered_item = item
  self.hover_start = system.get_time()
  self.tooltip_dismissed = nil
  core.redraw = true
end


---Keep focus in the editor; a left press arms the clicked item.
---@param button string Mouse button identifier
---@param x number Mouse x coordinate
---@param y number Mouse y coordinate
---@param clicks number Number of clicks
---@return boolean
function StatusBar:on_mouse_pressed(button, x, y, clicks)
  if not self.visible then return end
  -- last_active_view is the view before the current one, so restore it only
  -- when the Status Bar itself took focus.
  if core.active_view == self and core.last_active_view then
    core.set_active_view(core.last_active_view)
  end
  local item = self:get_item_at(x, y)
  set_hovered(self, item)
  if button == "left" and item and item:is_clickable() then
    self.pressed_item = item
    self.tooltip_dismissed = item
    core.redraw = true
  end
  return true
end


---Handle mouse leaving the status bar area.
function StatusBar:on_mouse_left()
  StatusBar.super.on_mouse_left(self)
  set_hovered(self, nil)
  self.pressed_item = nil
  self.cursor = "arrow"
end


---Track the hovered item and show the hand cursor over items with actions.
---@param x number Mouse x coordinate
---@param y number Mouse y coordinate
---@param dx number Delta x movement
---@param dy number Delta y movement
function StatusBar:on_mouse_moved(x, y, dx, dy)
  if not self.visible then return end
  StatusBar.super.on_mouse_moved(self, x, y, dx, dy)
  local item = self:get_item_at(x, y)
  set_hovered(self, item)
  self.cursor = item and item:is_clickable() and "hand" or "arrow"
end


---Run the pressed item's action when the release lands on the same item.
---@param button string Mouse button identifier
---@param x number Mouse x coordinate
---@param y number Mouse y coordinate
function StatusBar:on_mouse_released(button, x, y)
  if not self.visible then return end
  StatusBar.super.on_mouse_released(self, button, x, y)
  local pressed = self.pressed_item
  self.pressed_item = nil
  if button ~= "left" or not pressed then return end
  core.redraw = true
  if self:get_item_at(x, y) ~= pressed or not pressed:is_clickable() then return end
  core.log_quiet("Status Bar item clicked: %s", pressed.name)
  if pressed.command then
    command.perform(pressed.command)
  elseif pressed.on_click then
    pressed.on_click(button, x, y)
  end
end


---Update status bar height, message state, and active items.
function StatusBar:update()
  local collapsed = not self.visible
  if collapsed and self.size.y <= 0 then
    return
  elseif collapsed and self.size.y > 0 then
    self:move_towards(self.size, "y", 0, nil, "statusbar")
    return
  end

  local height = statusbar_font():get_height() + common.round(3 * SCALE) * 2

  if self.size.y + 1 < height then
    self:move_towards(self.size, "y", height, nil, "statusbar")
  else
    self.size.y = height
  end

  local now = system.get_time()
  if self.message then
    if now > self.message_timeout then
      self.message = nil
      core.redraw = true
    elseif now - self.message_pulse_start < MESSAGE_PULSE_DURATION then
      core.redraw = true
    end
  end

  -- Redraw until a pending hover tooltip appears.
  local hovered = self.hovered_item
  if hovered and hovered ~= self.tooltip_dismissed and now - self.hover_start < TOOLTIP_DELAY then
    core.redraw = true
  end

  StatusBar.super.update(self)

  self:update_active_items()
end


local function tooltip_lines(text, hint)
  local lines = {}
  for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
    if line ~= "" then table.insert(lines, { style.text, line }) end
  end
  if hint then table.insert(lines, { style.dim, hint }) end
  return lines
end

---Draw the hover tooltip of an item above the Status Bar.
---@param item core.statusbar.item
function StatusBar:draw_item_tooltip(item)
  local text, hint = item:get_tooltip()
  local lines = tooltip_lines(text, hint)
  if #lines == 0 then return end
  self.tooltip_shown_at = system.get_time()
  core.root_panel:defer_draw(function()
    local font = statusbar_font()
    local line_h = font:get_height()
    local pad_x, pad_y = common.round(style.padding.x * 0.6), common.round(style.padding.y * 0.6)
    local w = 0
    for _, line in ipairs(lines) do w = math.max(w, font:get_width(line[2])) end
    w = w + pad_x * 2
    local h = line_h * #lines + pad_y * 2
    local x = common.clamp(self.position.x + item.x, self.position.x, self.position.x + self.size.x - w)
    local y = self.position.y - h - common.round(4 * SCALE)
    local radius = common.round(4 * SCALE)
    renderer.draw_rounded_rect(x - 1, y - 1, w + 2, h + 2, radius + 1, style.divider)
    renderer.draw_rounded_rect(x, y, w, h, radius, style.background3)
    local ty = y + pad_y
    for _, line in ipairs(lines) do
      renderer.draw_text(font, line[2], common.round(x + pad_x), common.round(ty), line[1])
      ty = ty + line_h
    end
  end)
end


---Render the status bar.
function StatusBar:draw()
  if not self.visible and self.size.y <= 0 then return end

  local m = metrics()
  local x0, y0, h = self.position.x, self.position.y, self.size.y
  local ds = style.divider_size or 0
  renderer.draw_rect(x0, y0 - ds, self.size.x, h + ds, style.wallpaper_surface(style.background))

  local function draw_chip_background(item)
    if not item:is_clickable() or item.visible_w <= 0 then return end
    local color
    if self.pressed_item == item and self.hovered_item == item then
      color = style.titlebar_control_pressed
    elseif self.hovered_item == item and not self.pressed_item then
      color = style.titlebar_control_hover
    end
    if color then
      renderer.draw_rounded_rect(x0 + item.x, y0 + m.inset, item.visible_w, h - m.inset * 2, m.radius, color)
    end
  end

  local function draw_item(item)
    draw_chip_background(item)
    local cx = x0 + item.x + m.chip
    if item.on_draw then
      core.push_clip_rect(x0 + item.x, y0, item.visible_w, h)
      item.on_draw(cx, y0, h, self.hovered_item == item)
      core.pop_clip_rect()
    else
      local styled = item.cached_item
      if item.shrink then styled = elide_start(styled, item.w - m.chip * 2) end
      draw_styled(styled, cx, y0, h)
    end
  end

  core.push_clip_rect(x0, y0, self.left_limit, h)
  if self.message_item.active and self.message then
    local message = self.message_item
    draw_chip_background(message)
    local styled = elide_start(get_rendered_message(self), message.visible_w - m.chip * 2)
    draw_styled(styled, x0 + message.x + m.chip, y0 + get_message_pulse_yoffset(self), h)
  elseif self.tooltip_mode then
    draw_styled(elide_start(self.tooltip, self.left_limit - m.edge - m.chip), x0 + m.edge + m.chip, y0, h)
  else
    for _, item in ipairs(self.active_items) do
      if item.alignment == StatusBar.Item.LEFT then draw_item(item) end
    end
  end
  core.pop_clip_rect()

  for _, item in ipairs(self.active_items) do
    if item.alignment == StatusBar.Item.RIGHT then draw_item(item) end
  end

  local hovered = self.hovered_item
  if hovered and hovered.active and hovered ~= self.tooltip_dismissed then
    local now = system.get_time()
    if now - self.hover_start >= TOOLTIP_DELAY or now - self.tooltip_shown_at < TOOLTIP_GRACE then
      self:draw_item_tooltip(hovered)
    end
  end

  -- The status bar view is clipped to its node, so draw the border inside its
  -- top edge rather than in the divider space above it.
  renderer.draw_rect(x0, y0, self.size.x, ds, style.divider)
end

return StatusBar
