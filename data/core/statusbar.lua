local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local style = require "core.style"
local project_paths = require "core.project_paths"
local DocView = require "core.docview"
local GlobalPromptBar = require "core.global_prompt_bar"
local LogView = require "core.logview"
local ImageView = require "core.imageview"
local View = require "core.view"
local Object = require "core.object"


---Styled text array containing fonts, colors, and strings.
---@alias core.statusbar.styledtext table<integer, renderer.font|renderer.color|string>

---Left or right alignment identifier.
---@alias core.statusbar.position '"left"' | '"right"'


---Status Bar with customizable items displaying document info and system status.
---Access the global instance via `core.status_bar`.
---@class core.statusbar : core.view
---@field super core.view
---@field items core.statusbar.item[] All registered items
---@field active_items core.statusbar.item[] Currently visible items that pass predicates
---@field hovered_item core.statusbar.item Item currently under mouse cursor
---@field message_timeout number Timestamp when current message expires
---@field message_pulse_start number Timestamp when current message retrigger pulse started
---@field message core.statusbar.styledtext Current temporary message content
---@field tooltip_mode boolean Whether persistent tooltip is active
---@field tooltip core.statusbar.styledtext Persistent tooltip content
---@field left_width number Visible width of left panel
---@field right_width number Visible width of right panel
---@field r_left_width number Real (total) width of left panel content
---@field r_right_width number Real (total) width of right panel content
---@field left_xoffset number Horizontal pan offset for left panel
---@field right_xoffset number Horizontal pan offset for right panel
---@field dragged_panel '""'|core.statusbar.position Panel being dragged ("left", "right", or "")
---@field hovered_panel '""'|core.statusbar.position Panel under cursor ("left", "right", or "")
---@field hide_messages boolean Whether to suppress status messages
local StatusBar = View:extend()

function StatusBar:__tostring() return "StatusBar" end

local function statusbar_font()
  return style.get_small_font(style.font)
end

local MESSAGE_PULSE_DURATION = 0.15
local MESSAGE_PULSE_AMPLITUDE = 7 * SCALE
local MESSAGE_MIN_LENGTH = 20
local MESSAGE_MAX_LENGTH = 100
local MESSAGE_MAX_TIMEOUT_MULTIPLIER = 4

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

---Space separator
---@type string
StatusBar.separator  = "  "

---Wide separator between status sections.
---@type string
StatusBar.separator2 = "  "

---@alias core.statusbar.item.separator
---|>`StatusBar.separator`
---| `StatusBar.separator2`

---@alias core.statusbar.item.predicate fun():boolean
---@alias core.statusbar.item.onclick fun(button: string, x: number, y: number)
---@alias core.statusbar.item.get_item fun(self: core.statusbar.item):core.statusbar.styledtext?,core.statusbar.styledtext?
---@alias core.statusbar.item.ondraw fun(x, y, h, hovered: boolean, calc_only?: boolean):number

---Individual status bar item with custom rendering and interaction.
---@class core.statusbar.item : core.object
---@field name string Unique identifier for the item
---@field predicate core.statusbar.item.predicate Condition to display item
---@field alignment core.statusbar.item.alignment Left or right side placement
---@field tooltip string Text shown on mouse hover
---@field command string|nil Command name to execute on click
---@field on_click core.statusbar.item.onclick|nil Click handler function
---@field on_draw core.statusbar.item.ondraw|nil Custom drawing function
---@field background_color renderer.color|nil Normal background color
---@field background_color_hover renderer.color|nil Hover background color
---@field visible boolean Whether item is shown
---@field separator core.statusbar.item.separator Separator style
---@field active boolean Whether item passes predicate check
---@field x number Horizontal position (calculated)
---@field w number Width in pixels (calculated)
---@field cached_item core.statusbar.styledtext Cached rendered content
local StatusBarItem = Object:extend()

function StatusBarItem:__tostring() return "StatusBarItem" end

---Options for creating a status bar item.
---@class core.statusbar.item.options : table
---@field predicate string|table|core.statusbar.item.predicate Condition for display (string=module, table=class, function=custom, nil=always)
---@field name string Unique identifier for the item
---@field alignment core.statusbar.item.alignment Left or right side placement
---@field get_item core.statusbar.item.get_item Function returning styled text (can return empty table)
---@field command string|core.statusbar.item.onclick|nil Command name or click callback
---@field position? integer Insertion position (-1=end, 1=beginning)
---@field tooltip? string Text displayed on mouse hover
---@field visible? boolean Initial visibility state
---@field separator? core.statusbar.item.separator Separator style (space or pipe)

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
  self.tooltip = options.tooltip or ""
  self.on_click = type(options.command) == "function" and options.command or nil
  self.on_draw = options.on_draw
  self.background_color = nil
  self.background_color_hover = nil
  self.visible = options.visible == nil and true or options.visible
  self.active = false
  self.x = 0
  self.w = 0
  self.separator = options.separator or StatusBar.separator
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
---String: treated as module name (e.g. "core.docview"), checked against active view.
---Table: treated as class, checked against active view with `extends()`.
---Function: called each update, should return boolean.
---Nil: always displays the item.
---@param predicate string|table|core.statusbar.item.predicate
function StatusBarItem:set_predicate(predicate)
  self.predicate = command.generate_predicate(predicate)
end

---@type core.statusbar.item
StatusBar.Item = StatusBarItem


---Check if active view is a Document View (but not the Global Prompt Bar).
---@return boolean
local function predicate_docview()
  return  core.active_view:is(DocView)
    and not core.active_view:is(GlobalPromptBar)
end

local function plural_suffix(n)
  return n == 1 and "" or "s"
end

local selection_counts_cache = {
  doc = nil,
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

local function get_doc_selection_counts(doc)
  local perf_t = core.perf_frame_stats and system.get_time()
  local carets = math.floor(#doc.selections / 4)
  local key = tostring(doc:get_change_id()) .. ":" .. tostring(doc.selection_revision or 0) .. ":" .. tostring(#doc.selections)
  if selection_counts_cache.doc == doc and selection_counts_cache.key == key then
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

  for _, line1, col1, line2, col2 in doc:get_selections(true) do
    if line1 ~= line2 or col1 ~= col2 then
      estimated_lines = estimated_lines + line2 - line1 + 1
      if count_chars then
        if line1 == line2 then
          estimated_bytes = estimated_bytes + math.max(0, col2 - col1)
        else
          estimated_bytes = estimated_bytes + #doc.lines[line1] - col1 + 1 + col2 - 1
          for line = line1 + 1, line2 - 1 do
            estimated_bytes = estimated_bytes + #doc.lines[line]
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
        chars = chars + doc:get_text(line1, col1, line2, col2):ulen(nil, nil, true) - (line2 - line1)
      end
      for line = line1, line2 do
        if not seen_lines[line] then
          seen_lines[line] = true
          selected_lines = selected_lines + 1
        end
      end
    end
  end

  selection_counts_cache.doc = doc
  selection_counts_cache.key = key
  selection_counts_cache.carets = carets
  selection_counts_cache.chars = count_chars and chars or 0
  selection_counts_cache.selected_lines = selected_lines
  selection_counts_cache.chars_pending = not count_chars

  if perf_t then perf_stat_add("statusbar_selection_ms", (system.get_time() - perf_t) * 1000) end
  return carets, selection_counts_cache.chars, selected_lines, not count_chars
end

local function draw_reserved_status_text(text, reserved_text, x, y, h, calc_only)
  local font = statusbar_font()
  local w = font:get_width(reserved_text)
  if not calc_only and text ~= "" then
    renderer.draw_text(font, text, x, y + math.floor((h - font:get_height()) / 2), style.text)
  end
  return w
end

local function draw_reserved_count_label(count, label, reserved_label, x, y, h, calc_only)
  local font = statusbar_font()
  local number_width = font:get_width("9999")
  local w = number_width + font:get_width(reserved_label)
  if not calc_only then
    local ty = y + math.floor((h - font:get_height()) / 2)
    local number = tostring(count)
    renderer.draw_text(font, number, x + number_width - font:get_width(number), ty, style.text)
    renderer.draw_text(font, label, x + number_width, ty, style.text)
  end
  return w
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
  self.hovered_item = {}
  self.pointer = {x = 0, y = 0}
  self.left_width = 0
  self.right_width = 0
  self.r_left_width = 0
  self.r_right_width = 0
  self.left_xoffset = 0
  self.right_xoffset = 0
  self.dragged_panel = ""
  self.hovered_panel = ""
  self.hide_messages = false
  self.visible = true

  self:register_docview_items()
  self:register_command_items()
  self:register_imageview_items()
end

---Register default status bar items for document views.
---Shows file, position, selections, indentation, encoding, line ending, etc.
function StatusBar:register_docview_items()
  if self:get_item("doc:file") then return end

  self:add_item({
    predicate = predicate_docview,
    name = "doc:file",
    alignment = StatusBar.Item.LEFT,
    get_item = function()
      local dv = core.active_view
      local filename
      if dv.doc.abs_filename then
        local display = project_paths.display_path(dv.doc.abs_filename, { kind = "file" })
        if display and display.text then
          if display.prefix_span then
            local label = display.text:sub(display.prefix_span[1], display.prefix_span[2])
            local rest = display.text:sub(display.prefix_span[2] + 1)
            filename = { style.accent, label, style.text, rest }
          else
            filename = { style.text, display.text }
          end
        end
      end
      if not filename then
        local doc_name = dv.doc.intellij_untitled_name or dv.doc:get_name()
        filename = {
          dv.doc.filename and style.text or style.dim,
          common.home_encode(doc_name)
        }
      end
      return {
        table.unpack(filename)
      }
    end
  })

  self:add_item({
    predicate = predicate_docview,
    name = "doc:position",
    alignment = StatusBar.Item.LEFT,
    get_item = {},
    on_draw = function(x, y, h, _, calc_only)
      local dv = core.active_view
      local line, col = dv.doc:get_selection()
      if config.caret_column_mode == "char" then
        col = dv.doc.lines[line]:ulen(1, col, true)
      end
      local tab_type, indent_size = dv.doc:get_indent_info()
      -- Calculating tabs when the doc is using the "hard" indent type.
      local ntabs = 0
      if tab_type == "hard" then
        local last_idx = 0
        while last_idx < col do
          local s, e = string.find(dv.doc.lines[line], "\t", last_idx, true)
          if s and s < col then
            ntabs = ntabs + 1
            last_idx = e + 1
          else
            break
          end
        end
      end
      col = col + ntabs * (indent_size - 1)

      local font = statusbar_font()
      local line_width = font:get_width("9999")
      local colon_width = font:get_width(":")
      local col_width = font:get_width("9999")
      local w = line_width + colon_width + col_width
      if not calc_only then
        local ty = y + math.floor((h - font:get_height()) / 2)
        local line_text = tostring(line)
        local col_text = tostring(col)
        renderer.draw_text(
          font,
          line_text,
          x + line_width - font:get_width(line_text),
          ty,
          style.text
        )
        renderer.draw_text(font, ":", x + line_width, ty, style.text)
        renderer.draw_text(
          font,
          col_text,
          x + line_width + colon_width,
          ty,
          col > config.line_limit and style.accent or style.text
        )
      end
      return w
    end,
    command = "doc:go-to-line",
    tooltip = "line : column"
  })

  self:add_item({
    predicate = predicate_docview,
    name = "doc:carets",
    alignment = StatusBar.Item.LEFT,
    position = 3,
    get_item = {},
    on_draw = function(x, y, h, _, calc_only)
      local carets = get_doc_selection_counts(core.active_view.doc)
      local label = string.format(" caret%s", plural_suffix(carets))
      return draw_reserved_count_label(carets, label, " carets", x, y, h, calc_only)
    end
  })

  self:add_item({
    predicate = predicate_docview,
    name = "doc:selected-chars",
    alignment = StatusBar.Item.LEFT,
    position = 4,
    get_item = {},
    on_draw = function(x, y, h, _, calc_only)
      local _, chars, _, chars_pending = get_doc_selection_counts(core.active_view.doc)
      if chars_pending or chars <= 0 then
        return draw_reserved_status_text("", "9999 chars selected", x, y, h, calc_only)
      end
      local label = string.format(" char%s selected", plural_suffix(chars))
      return draw_reserved_count_label(chars, label, " chars selected", x, y, h, calc_only)
    end
  })

  self:add_item({
    predicate = predicate_docview,
    name = "doc:selected-lines",
    alignment = StatusBar.Item.LEFT,
    position = 5,
    get_item = {},
    on_draw = function(x, y, h, _, calc_only)
      local _, _, selected_lines = get_doc_selection_counts(core.active_view.doc)
      if selected_lines <= 0 then
        return draw_reserved_status_text("", "9999 lines selected", x, y, h, calc_only)
      end
      local label = string.format(" line%s selected", plural_suffix(selected_lines))
      return draw_reserved_count_label(selected_lines, label, " lines selected", x, y, h, calc_only)
    end
  })

  self:add_item({
    predicate = predicate_docview,
    name = "doc:position-percent",
    alignment = StatusBar.Item.LEFT,
    get_item = function()
      local dv = core.active_view
      local line = dv.doc:get_selection()
      return {
        string.format("%.f%%", line / #dv.doc.lines * 100)
      }
    end,
    tooltip = "caret position"
  })


  self:add_item({
    predicate = predicate_docview,
    name = "doc:indentation",
    alignment = StatusBar.Item.RIGHT,
    get_item = function()
      local dv = core.active_view
      local indent_type, indent_size, indent_confirmed = dv.doc:get_indent_info()
      local indent_label = (indent_type == "hard") and "tabs: " or "spaces: "
      return {
        style.text, indent_label, indent_size,
        indent_confirmed and "" or "*"
      }
    end,
    command = function(button, x, y)
      if button == "left" then
        command.perform "indent:set-file-indent-size"
      elseif button == "right" then
        command.perform "indent:set-file-indent-type"
      end
    end,
    separator = self.separator2
  })

  self:add_item({
    predicate = predicate_docview,
    name = "doc:lines",
    alignment = StatusBar.Item.RIGHT,
    get_item = function()
      local dv = core.active_view
      return {
        style.text, #dv.doc.lines, " lines",
      }
    end,
    separator = self.separator2
  })

  self:add_item({
    predicate = predicate_docview,
    name = "doc:encoding",
    alignment = StatusBar.Item.RIGHT,
    get_item = function()
      local dv, bom = core.active_view, ""
      if dv.doc.bom then bom = " (BOM)" end
      return {
        style.text, (dv.doc.encoding or "none"), bom
      }
    end,
    command = function(button)
      if button == "left" then
        command.perform "doc:change-encoding"
      elseif button == "right" then
        command.perform "doc:reload-with-encoding"
      end
    end,
    tooltip = "encoding"
  })

  self:add_item({
    predicate = predicate_docview,
    name = "doc:line-ending",
    alignment = StatusBar.Item.RIGHT,
    get_item = function()
      local dv = core.active_view
      return {
        style.text, dv.doc.crlf and "CRLF" or "LF"
      }
    end,
    command = "doc:toggle-line-ending"
  })

end


---Register default status bar items for Global Prompt Bar interactions.
---Shows file count icon.
function StatusBar:register_command_items()
  if self:get_item("command:files") then return end

  self:add_item({
    predicate = "core.global_prompt_bar",
    name = "command:files",
    alignment = StatusBar.Item.RIGHT,
    get_item = function()
      return {
        style.icon_font, "g",
        statusbar_font(), style.dim, self.separator2
      }
    end
  })
end


---Register default status bar items for image views.
---Shows image filename, dimensions, and zoom level.
function StatusBar:register_imageview_items()
  self:add_item({
    predicate = ImageView,
    name = "image-view:details",
    alignment = StatusBar.Item.LEFT,
    get_item = function()
      if core.active_view.image then
        local file = common.basename(core.active_view.path)
        local w, h = core.active_view.image:get_size()
        local dimensions = string.format("%dx%d", w, h)
        return {
          statusbar_font(), style.accent,
          file,
          style.text,
          StatusBar.separator,
          dimensions,
          StatusBar.separator,
          string.format("Zoom: %sx", core.active_view.zoom_scale),
        }
      else
        return {}
      end
    end,
    position = 1
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
  local item = nil
  for pos, it in ipairs(self.items) do
    if it.name == name then
      item = table.remove(self.items, pos)
      break
    end
  end
  return item
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


---Display a temporary message in the status bar.
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


---Show a persistent tooltip replacing all status bar content.
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


---Process styled text array with a drawing function.
---@param self core.statusbar
---@param items core.statusbar.styledtext Styled text array
---@param x number Starting x coordinate
---@param y number Starting y coordinate
---@param draw_fn fun(font, color, text, align, x, y, w, h):number Drawing or measurement function
local function draw_items(self, items, x, y, draw_fn)
  local font = statusbar_font()
  local color = style.text

  for _, item in ipairs(items) do
    if Object.is(item, renderer.font) then
      font = item
    elseif type(item) == "table" then
      color = item
    else
      x = draw_fn(font, color, item, nil, x, y, 0, self.size.y)
    end
  end

  return x
end


---Calculate text width (used as callback for draw_items).
---@param font renderer.font
---@param _ any Unused color parameter
---@param text string Text to measure
---@param _ any Unused align parameter
---@param x number Current x position
---@return number x Updated x position
local function text_width(font, _, text, _, x)
  return x + font:get_width(text)
end


---Draw styled text on the status bar with optional alignment.
---@param items core.statusbar.styledtext Styled text to render
---@param right_align? boolean True to right-align, false for left-align
---@param xoffset? number Horizontal offset in pixels
---@param yoffset? number Vertical offset in pixels
function StatusBar:draw_items(items, right_align, xoffset, yoffset)
  local x, y = self:get_content_offset()
  x = x + (xoffset or 0)
  y = y + (yoffset or 0)
  if right_align then
    local w = draw_items(self, items, 0, 0, text_width)
    x = x + self.size.x - w - style.padding.x
    draw_items(self, items, x, y, common.draw_text)
  else
    x = x + style.padding.x
    draw_items(self, items, x, y, common.draw_text)
  end
end


---Draw a tooltip box above the status bar for an item.
---@param item core.statusbar.item Item with tooltip text
function StatusBar:draw_item_tooltip(item)
  core.root_panel:defer_draw(function()
    local text = item.tooltip
    local font = statusbar_font()
    local w = font:get_width(text)
    local h = font:get_height()
    local x = self.pointer.x - (w / 2) - (style.padding.x * 2)

    if x < 0 then x = 0 end
    if (x + w + (style.padding.x * 3)) > self.size.x then
      x = self.size.x - w - (style.padding.x * 3)
    end

    renderer.draw_rect(
      x + style.padding.x,
      self.position.y - h - (style.padding.y * 2),
      w + (style.padding.x * 2),
      h + (style.padding.y * 2),
      style.background3
    )

    renderer.draw_text(
      font,
      text,
      -- we round the coords to prevent jumpy text on fractional scales
      common.round(x + (style.padding.x * 2)),
      common.round(self.position.y - h - style.padding.y),
      style.text
    )
  end)
end


---Legacy method for retrieving status bar items.
---@deprecated Use `core.status_bar:add_item()` instead
---@param nowarn boolean Suppress deprecation warning if true
---@return table left Left-aligned items
---@return table right Right-aligned items
function StatusBar:get_items(nowarn)
  if not nowarn and not self.get_items_warn then
    core.warn(
      "Overriding StatusBar:get_items() is deprecated, "
      .. "use core.status_bar:add_item() instead."
    )
    self.get_items_warn = true
  end
  return {"{:dummy:}"}, {"{:dummy:}"}
end


---Append all elements from one styled text array to another.
---@param t1 core.statusbar.styledtext Destination array
---@param t2 core.statusbar.styledtext Source array to append
local function table_add(t1, t2)
  for _, value in ipairs(t2) do
    table.insert(t1, value)
  end
end


---Merge legacy get_items() results into the item list for backwards compatibility.
---@param destination table Item list to merge into
---@param items core.statusbar.styledtext Legacy styled text items
---@param alignment core.statusbar.item.alignment Item alignment
local function merge_deprecated_items(destination, items, alignment)
  local start = true
  local items_start, items_end = {}, {}
  for i, value in ipairs(items) do
    if value ~= "{:dummy:}" then
      if start then
        table.insert(items_start, i, value)
      else
        table.insert(items_end, value)
      end
    else
      start = false
    end
  end

  local position = alignment == StatusBar.Item.LEFT and "left" or "right"

  local item_start = StatusBar.Item({
    name = "deprecated:"..position.."-start",
    alignment = alignment,
    get_item = items_start
  })

  local item_end = StatusBar.Item({
    name = "deprecated:"..position.."-end",
    alignment = alignment,
    get_item = items_end
  })

  table.insert(destination, 1, item_start)
  table.insert(destination, item_end)
end


---Create and insert a separator item between status bar items.
---@param self core.statusbar
---@param destination core.statusbar.item[] Active items list
---@param separator string Separator text (space or pipe)
---@param alignment core.statusbar.item.alignment Item alignment
---@param x number X position for the separator
---@return core.statusbar.item separator The created separator item
local function add_spacing(self, destination, separator, alignment, x)
  ---@type core.statusbar.item
  local space = StatusBar.Item({name = "space", alignment = alignment})
  space.cached_item = separator == self.separator and {
    style.text, separator
  } or {
    style.dim, separator
  }
  space.x = x
  space.w = draw_items(self, space.cached_item, 0, 0, text_width)

  table.insert(destination, space)

  return space
end


---Strip leading and trailing separators from styled text.
---@param self core.statusbar
---@param styled_text core.statusbar.styledtext Styled text to modify in-place
local function remove_spacing(self, styled_text)
  if
    not Object.is(styled_text[1], renderer.font)
    and
    type(styled_text[1]) == "table"
    and
    (
      styled_text[2] == self.separator
      or
      styled_text[2] == self.separator2
    )
  then
    table.remove(styled_text, 1)
    table.remove(styled_text, 1)
  end

  if
    not Object.is(styled_text[#styled_text-1], renderer.font)
    and
    type(styled_text[#styled_text-1]) == "table"
    and
    (
      styled_text[#styled_text] == self.separator
      or
      styled_text[#styled_text] == self.separator2
    )
  then
    table.remove(styled_text, #styled_text)
    table.remove(styled_text, #styled_text)
  end
end


---Rebuild the active items list by evaluating predicates and calculating positions.
---Updates item visibility, positions, and handles panel overflow.
function StatusBar:update_active_items()
  local x = self:get_content_offset()

  local rx = x + self.size.x
  local lx = x
  local rw, lw = 0, 0

  self.active_items = {}

  ---@type core.statusbar.item[]
  local combined_items = {}
  table_add(combined_items, self.items)

  -- load deprecated items for compatibility
  local dleft, dright = self:get_items(true)
  merge_deprecated_items(combined_items, dleft, StatusBar.Item.LEFT)
  merge_deprecated_items(combined_items, dright, StatusBar.Item.RIGHT)

  local lfirst, rfirst = true, true

  -- calculate left and right width
  for _, item in ipairs(combined_items) do
    item.cached_item = {}
    if item.visible and item:predicate() then
      local styled_text = type(item.get_item) == "function"
        and item.get_item(item) or item.get_item

      if #styled_text > 0 then
        remove_spacing(self, styled_text)
      end

      if #styled_text > 0 or item.on_draw then
        item.active = true
        local hovered = self.hovered_item == item
        if item.alignment == StatusBar.Item.LEFT then
          if not lfirst then
            local space = add_spacing(
              self, self.active_items, item.separator, item.alignment, lx
            )
            lw = lw + space.w
            lx = lx + space.w
          else
            lfirst = false
          end
          item.w = item.on_draw and
            item.on_draw(lx, self.position.y, self.size.y, hovered, true)
            or
            draw_items(self, styled_text, 0, 0, text_width)
          item.x = lx
          lw = lw + item.w
          lx = lx + item.w
        else
          if not rfirst then
            local space = add_spacing(
              self, self.active_items, item.separator, item.alignment, rx
            )
            rw = rw + space.w
            rx = rx + space.w
          else
            rfirst = false
          end
          item.w = item.on_draw and
            item.on_draw(rx, self.position.y, self.size.y, hovered, true)
            or
            draw_items(self, styled_text, 0, 0, text_width)
          item.x = rx
          rw = rw + item.w
          rx = rx + item.w
        end
        item.cached_item = styled_text
        table.insert(self.active_items, item)
      else
        item.active = false
      end
    else
      item.active = false
    end
  end

  self.r_left_width, self.r_right_width = lw, rw

  -- try to calc best size for left and right
  if lw + rw + (style.padding.x * 4) > self.size.x then
    if lw + (style.padding.x * 2) < self.size.x / 2 then
      rw = self.size.x - lw  - (style.padding.x * 3)
      if rw > self.r_right_width then
        lw = lw + (rw - self.r_right_width)
        rw = self.r_right_width
      end
    elseif rw + (style.padding.x * 2) < self.size.x / 2 then
      lw = self.size.x - rw  - (style.padding.x * 3)
    else
      lw = self.size.x / 2 - (style.padding.x + style.padding.x / 2)
      rw = self.size.x / 2 - (style.padding.x + style.padding.x / 2)
    end
    -- reposition left and right offsets when window is resized
    if rw >= self.r_right_width then
      self.right_xoffset = 0
    elseif rw > self.right_xoffset + self.r_right_width then
      self.right_xoffset = rw - self.r_right_width
    end
    if lw >= self.r_left_width then
      self.left_xoffset = 0
    elseif lw > self.left_xoffset + self.r_left_width then
      self.left_xoffset = lw - self.r_left_width
    end
  else
    self.left_xoffset = 0
    self.right_xoffset = 0
  end

  self.left_width, self.right_width = lw, rw

  for _, item in ipairs(self.active_items) do
    if item.alignment == StatusBar.Item.RIGHT then
      -- re-calculate x position now that we have the total width
      item.x = item.x - rw - (style.padding.x * 2)
    end
  end
end


---Pan a status bar panel horizontally when content overflows.
---@param panel core.statusbar.position Panel to drag ("left" or "right")
---@param dx number Horizontal drag distance in pixels
function StatusBar:drag_panel(panel, dx)
  if panel == "left" and self.r_left_width > self.left_width then
    local nonvisible_w = self.r_left_width - self.left_width
    local new_offset = self.left_xoffset + dx
    if new_offset >= 0 - nonvisible_w and new_offset <= 0 then
      self.left_xoffset = new_offset
    elseif dx < 0 then
      self.left_xoffset = 0 - nonvisible_w
    else
      self.left_xoffset = 0
    end
  elseif panel == "right" and self.r_right_width > self.right_width then
    local nonvisible_w = self.r_right_width - self.right_width
    local new_offset = self.right_xoffset + dx
    if new_offset >= 0 - nonvisible_w and new_offset <= 0 then
      self.right_xoffset = new_offset
    elseif dx < 0 then
      self.right_xoffset = 0 - nonvisible_w
    else
      self.right_xoffset = 0
    end
  end
end


---Determine which panel (left or right) is under the cursor.
---@param x number Mouse x coordinate
---@param y number Mouse y coordinate
---@return string panel "left", "right", or "" if none
function StatusBar:get_hovered_panel(x, y)
  if y >= self.position.y and x <= self.left_width + style.padding.x then
    return "left"
  end
  return "right"
end


---Calculate the visible portion of an item considering panel overflow.
---@param item core.statusbar.item Item to check
---@return number x Visible x coordinate (0 if fully clipped)
---@return number w Visible width (0 if fully clipped)
function StatusBar:get_item_visible_area(item)
  local item_ox = item.alignment == StatusBar.Item.LEFT and
    self.left_xoffset or self.right_xoffset

  local item_x = item_ox + item.x + style.padding.x
  local item_w = item.w

  if item.alignment == StatusBar.Item.LEFT then
    if self.left_width - item_x > 0 and self.left_width - item_x < item.w then
      item_w = (self.left_width + style.padding.x) - item_x
    elseif self.left_width - item_x < 0 then
      item_x = 0
      item_w = 0
    end
  else
    local rx = self.size.x - self.right_width - style.padding.x
    if item_x < rx then
      if item_x + item.w > rx then
        item_x = rx
        item_w = (item_x + item.w) - rx
      else
        item_x = 0
        item_w = 0
      end
    end
  end

  return item_x, item_w
end



---Handle mouse button press events.
---Clicking on active message opens log view. Left-click enables panel dragging when content overflows.
---@param button string Mouse button identifier
---@param x number Mouse x coordinate
---@param y number Mouse y coordinate
---@param clicks number Number of clicks
---@return boolean
function StatusBar:on_mouse_pressed(button, x, y, clicks)
  if not self.visible then return end
  core.set_active_view(core.last_active_view)
  if
    system.get_time() < self.message_timeout
    and
    not core.active_view:is(LogView)
  then
    command.perform "core:open-log"
  else
    if y >= self.position.y and button == "left" and clicks == 1 then
      self.position.dx = x
      if
        self.r_left_width > self.left_width
        or
        self.r_right_width > self.right_width
      then
        self.dragged_panel = self:get_hovered_panel(x, y)
        self.cursor = "hand"
      end
    end
  end
  return true
end


---Handle mouse leaving the status bar area.
function StatusBar:on_mouse_left()
  StatusBar.super.on_mouse_left(self)
  self.hovered_item = {}
end


---Handle mouse movement over the status bar.
---Updates hovered item, cursor, and handles panel dragging.
---@param x number Mouse x coordinate
---@param y number Mouse y coordinate
---@param dx number Delta x movement
---@param dy number Delta y movement
function StatusBar:on_mouse_moved(x, y, dx, dy)
  if not self.visible then return end
  StatusBar.super.on_mouse_moved(self, x, y, dx, dy)

  self.hovered_panel = self:get_hovered_panel(x, y)

  if self.dragged_panel ~= "" then
    self:drag_panel(self.dragged_panel, dx)
    return
  end

  if y < self.position.y or self.message then
    self.cursor = "arrow"
    self.hovered_item = {}
    return
  end

  for _, item in ipairs(self.items) do
    if
      item.visible and item.active
      and
      (item.command or item.on_click or item.tooltip ~= "")
    then
      local item_x, item_w = self:get_item_visible_area(item)

      if x > item_x and (item_x + item_w) > x then
        self.pointer.x = x
        self.pointer.y = y
        if self.hovered_item ~= item then
          self.hovered_item = item
        end
        if item.command or item.on_click then
          self.cursor = "hand"
        end
        return
      end
    end
  end
  self.cursor = "arrow"
  self.hovered_item = {}
end


---Handle mouse button release events.
---Executes item command or callback if clicked on an item.
---@param button string Mouse button identifier
---@param x number Mouse x coordinate
---@param y number Mouse y coordinate
function StatusBar:on_mouse_released(button, x, y)
  if not self.visible then return end
  StatusBar.super.on_mouse_released(self, button, x, y)

  if self.dragged_panel ~= "" then
    self.dragged_panel = ""
    self.cursor = "arrow"
    if self.position.dx ~= x then
      return
    end
  end

  if y < self.position.y or not self.hovered_item.active then return end

  local item = self.hovered_item
  local item_x, item_w = self:get_item_visible_area(item)

  if x > item_x and (item_x + item_w) > x then
    if item.command then
      command.perform(item.command)
    elseif item.on_click then
      item.on_click(button, x, y)
    end
  end
end


---Handle mouse wheel scrolling to pan overflowing panels.
---@param y number Vertical scroll amount
---@param x number Horizontal scroll amount
function StatusBar:on_mouse_wheel(y, x)
  if not self.visible or self.hovered_panel == "" then return end
  if x ~= 0 then
    self:drag_panel(self.hovered_panel, x * self.left_width / 10)
  else
    self:drag_panel(self.hovered_panel, y * self.left_width / 10)
  end
end


---Update status bar height, message scroll, and active items.
function StatusBar:update()
  if not self.visible and self.size.y <= 0 then
    return
  elseif not self.visible and self.size.y > 0 then
    self:move_towards(self.size, "y", 0, nil, "statusbar")
    return
  end

  local height = statusbar_font():get_height() + style.padding.y * 2;

  if self.size.y + 1 < height then
    self:move_towards(self.size, "y", height, nil, "statusbar")
  else
    self.size.y = height
  end

  local now = system.get_time()
  if self.message and now < self.message_timeout then
    self.scroll.to.y = self.size.y
    if now - self.message_pulse_start < MESSAGE_PULSE_DURATION then
      core.redraw = true
    end
  else
    self.scroll.to.y = 0
  end

  StatusBar.super.update(self)

  self:update_active_items()
end


---Get item hover state and background color.
---@param self core.statusbar
---@param item core.statusbar.item Item to check
---@return boolean is_hovered True if item is currently hovered
---@return renderer.color|nil color Background color to use (nil if none)
local function get_item_bg_color(self, item)
  local hovered = self.hovered_item == item

  local item_bg = hovered
    and item.background_color_hover or item.background_color

  return hovered, item_bg
end


---Format the current status message as styled text.
---@param self core.statusbar
---@return core.statusbar.styledtext message Styled message with icon and text
local function get_rendered_message(self)
  return {
    self.message.icon_color, style.icon_font, self.message.icon,
    style.dim, statusbar_font(), StatusBar.separator2, style.text, self.message.text
  }
end

local function get_message_pulse_yoffset(self)
  local elapsed = system.get_time() - self.message_pulse_start
  if elapsed < 0 or elapsed >= MESSAGE_PULSE_DURATION then return 0 end
  local t = elapsed / MESSAGE_PULSE_DURATION
  return math.sin(t * math.pi) * MESSAGE_PULSE_AMPLITUDE
end


---Render the status bar with all active items, messages, and tooltips.
function StatusBar:draw()
  if not self.visible and self.size.y <= 0 then return end

  local background = style.background
  local ds = style.divider_size or 0
  renderer.draw_rect(self.position.x, self.position.y - ds, self.size.x, self.size.y + ds, background)

  if self.message and system.get_time() <= self.message_timeout then
    self:draw_items(get_rendered_message(self), false, 0, self.size.y + get_message_pulse_yoffset(self))
  else
    if self.message then self.message = nil end
    if self.tooltip_mode then
      self:draw_items(self.tooltip)
    end
    if #self.active_items > 0 then
      --- draw left pane
      core.push_clip_rect(
        0, self.position.y,
        self.left_width + style.padding.x, self.size.y
      )
      for _, item in ipairs(self.active_items) do
        local item_x = self.left_xoffset + item.x + style.padding.x
        local hovered, item_bg = get_item_bg_color(self, item)
        if item.alignment == StatusBar.Item.LEFT and not self.tooltip_mode then
          if type(item_bg) == "table" then
            renderer.draw_rect(
              item_x, self.position.y,
              item.w, self.size.y, item_bg
            )
          end
          if item.on_draw then
            core.push_clip_rect(item_x, self.position.y, item.w, self.size.y)
            item.on_draw(item_x, self.position.y, self.size.y, hovered)
            core.pop_clip_rect()
          else
            self:draw_items(item.cached_item, false, item_x - style.padding.x)
          end
        end
      end
      core.pop_clip_rect()

      --- draw right pane
      core.push_clip_rect(
        self.size.x - (self.right_width + style.padding.x), self.position.y,
        self.right_width + style.padding.x, self.size.y
      )
      for _, item in ipairs(self.active_items) do
        local item_x = self.right_xoffset + item.x + style.padding.x
        local hovered, item_bg = get_item_bg_color(self, item)
        if item.alignment == StatusBar.Item.RIGHT then
          if type(item_bg) == "table" then
            renderer.draw_rect(
              item_x, self.position.y,
              item.w, self.size.y, item_bg
            )
          end
          if item.on_draw then
            core.push_clip_rect(item_x, self.position.y, item.w, self.size.y)
            item.on_draw(item_x, self.position.y, self.size.y, hovered)
            core.pop_clip_rect()
          else
            self:draw_items(item.cached_item, false, item_x - style.padding.x)
          end
        end
      end
      core.pop_clip_rect()

      -- draw tooltip
      if self.hovered_item.tooltip ~= "" and self.hovered_item.active then
        self:draw_item_tooltip(self.hovered_item)
      end
    end
  end

  -- The status bar view is clipped to its node, so draw the border inside its
  -- top edge rather than in the divider space above it.
  renderer.draw_rect(self.position.x, self.position.y, self.size.x, ds, style.divider)
end

return StatusBar
