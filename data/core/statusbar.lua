local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local project_paths = require "core.project_paths"
local TextView = require "core.textview"
local GlobalPromptBar = require "core.global_prompt_bar"
local LogView = require "core.logview"
local ImageView = require "core.imageview"
local Object = require "core.object"
local PaneStatusBar = require "core.pane_status_bar"


---Styled text array containing fonts, colors, and strings.
---@alias core.statusbar.styledtext table<integer, renderer.font|renderer.color|string>


---Shared Status Bar state. Each Pane draws its own Pane Status Bar from the
---items registered here, evaluated against that Pane's Current View.
---Temporary messages and widget tooltips show in the focused Pane's bar.
---Access the global instance via `core.status_bar`.
---@class core.statusbar : core.object
---@field items core.statusbar.item[] All registered items
---@field message table|nil Current temporary message
---@field message_timeout number Timestamp when the current message expires
---@field message_pulse_start number Timestamp when the current message pulse started
---@field message_item core.statusbar.item Pseudo item that hit-tests the message
---@field tooltip_mode boolean Whether a persistent tooltip replaces the left items
---@field tooltip core.statusbar.styledtext Persistent tooltip content
---@field tooltip_shown_at number When any Pane Status Bar last drew a hover tooltip
---@field visible boolean Whether Pane Status Bars are shown
---@field height number Height of each Pane Status Bar
---@field hide_messages boolean Whether to suppress status messages
local StatusBar = Object:extend()

function StatusBar:__tostring() return "StatusBar" end

local MESSAGE_PULSE_DURATION = 0.15
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


---@alias core.statusbar.item.predicate fun(view: core.view):boolean
---`chip` is the clicked chip's screen rectangle.
---@alias core.statusbar.item.onclick fun(view: core.view, button: string, x: number, y: number, chip: { x: number, y: number, w: number, h: number })
---@alias core.statusbar.item.get_item fun(self: core.statusbar.item, view: core.view):core.statusbar.styledtext?
---@alias core.statusbar.item.ondraw fun(view: core.view, x, y, h, hovered: boolean, calc_only?: boolean):number
---Returns the tooltip text, which may contain newlines, and an optional dim action hint.
---@alias core.statusbar.item.gettooltip fun(self: core.statusbar.item, view: core.view):string?,string?

---Individual Status Bar item. Its callbacks receive the View of the Pane
---whose bar draws it.
---@class core.statusbar.item : core.object
---@field name string Unique identifier for the item
---@field predicate core.statusbar.item.predicate Condition to display item
---@field alignment core.statusbar.item.alignment Left or right side placement
---@field tooltip string|core.statusbar.item.gettooltip|nil Text shown on hover
---@field command string|nil Command name to execute on click
---@field on_click core.statusbar.item.onclick|nil Click handler function
---@field can_click fun(view: core.view):boolean|nil Whether the click action applies now
---@field on_draw core.statusbar.item.ondraw|nil Custom drawing function
---@field shrink boolean Whether the item elides its start to fit the space left
---@field optional boolean Whether the item hides when the bar is too narrow for all items
---@field visible boolean Whether item is shown
local StatusBarItem = Object:extend()

function StatusBarItem:__tostring() return "StatusBarItem" end

---Options for creating a Status Bar item.
---@class core.statusbar.item.options : table
---@field predicate string|table|core.statusbar.item.predicate Condition for display (string=module, table=class, function=custom, nil=always)
---@field name string Unique identifier for the item
---@field alignment core.statusbar.item.alignment Left or right side placement
---@field get_item core.statusbar.item.get_item|core.statusbar.styledtext Styled text, or a function returning it
---@field command string|core.statusbar.item.onclick|nil Command name or click callback
---@field can_click? fun(view: core.view):boolean Whether the click action applies now
---@field position? integer Insertion position (-1=end, 1=beginning)
---@field tooltip? string|core.statusbar.item.gettooltip Text displayed on hover
---@field visible? boolean Initial visibility state
---@field shrink? boolean Elide the start of the content when space runs out
---@field optional? boolean Hide, with the other optional items, when the bar is too narrow for all items

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
  self.optional = options.optional == true
  self.visible = options.visible == nil and true or options.visible
  self.get_item = options.get_item
end

---Generate the styled text for this item.
---Override this method or pass `get_item` in options.
---Ignored if `on_draw` is set.
---@param view core.view
---@return core.statusbar.styledtext
function StatusBarItem:get_item(view) return {} end

---Hide the item from the status bar.
function StatusBarItem:hide() self.visible = false end

---Show the item on the status bar.
function StatusBarItem:show() self.visible = true end

---Set the condition to evaluate whether this item should be displayed.
---String: treated as module name (e.g. "core.textview"), checked against the Pane's View.
---Table: treated as class, checked against the Pane's View with `extends()`.
---Function: called with the Pane's View, should return boolean.
---Nil: always displays the item.
---@param predicate string|table|core.statusbar.item.predicate|nil
function StatusBarItem:set_predicate(predicate)
  if type(predicate) == "string" then predicate = require(predicate) end
  if type(predicate) == "table" then
    local class = predicate
    predicate = function(view) return view ~= nil and view.extends ~= nil and view:extends(class) end
  end
  self.predicate = predicate or function() return true end
end

---Report whether a left click on this item runs an action for a View.
---@param view core.view
---@return boolean
function StatusBarItem:is_clickable(view)
  if not self.command and not self.on_click then return false end
  return self.can_click == nil or self.can_click(view) == true
end

---Get the hover text and the optional action hint.
---@param view core.view
---@return string? text
---@return string? hint
function StatusBarItem:get_tooltip(view)
  if type(self.tooltip) == "function" then return self.tooltip(self, view) end
  if self.tooltip == "" then return nil end
  return self.tooltip
end

---@type core.statusbar.item
StatusBar.Item = StatusBarItem


---@param view core.view
---@return core.textview|nil
local function as_textview(view)
  if view and view.extends and view:extends(TextView) and not view:is(GlobalPromptBar) then
    return view
  end
end

local function predicate_textview(view)
  return as_textview(view) ~= nil
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


---Create the shared Status Bar state and register default items.
function StatusBar:new()
  self.message_timeout = 0
  self.message_pulse_start = 0
  self.message = nil
  self.tooltip_mode = false
  self.tooltip = {}
  self.tooltip_shown_at = -math.huge
  self.items = {}
  self.hide_messages = false
  self.visible = true
  self.height = 0

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
  self:register_markdown_items()
end

---Get the Pane Status Bar for a Pane, creating it on first use.
---@param pane table
---@return core.pane_status_bar
function StatusBar:bar_for_pane(pane)
  local bar = pane.status_bar
  if not bar or bar.controller ~= self then
    bar = PaneStatusBar(self, pane)
    pane.status_bar = bar
  end
  return bar
end

---Height of a shown Pane Status Bar.
---@return number
function StatusBar:target_height()
  return PaneStatusBar.font():get_height() + common.round(3 * SCALE) * 2
end

---Follow visibility and font changes, and expire messages.
function StatusBar:update()
  self.height = self.visible and self:target_height() or 0

  local now = system.get_time()
  if self.message then
    if now > self.message_timeout then
      self.message = nil
      core.redraw = true
    elseif now - self.message_pulse_start < MESSAGE_PULSE_DURATION then
      core.redraw = true
    end
  end
end

---Current height of each Pane Status Bar.
---@return number
function StatusBar:get_height()
  return common.round(self.height)
end

---Whether a temporary message is showing.
---@return boolean
function StatusBar:message_active()
  return self.message ~= nil and system.get_time() <= self.message_timeout
end

---Vertical offset of a message that was just shown or repeated.
---@return number
function StatusBar:message_pulse_offset()
  local elapsed = system.get_time() - self.message_pulse_start
  if elapsed < 0 or elapsed >= MESSAGE_PULSE_DURATION then return 0 end
  return math.sin(elapsed / MESSAGE_PULSE_DURATION * math.pi) * 3 * SCALE
end

---Register default status bar items for Text Views.
function StatusBar:register_textview_items()
  if self:get_item("text:file") then return end

  self:add_item({
    predicate = predicate_textview,
    name = "text:file",
    alignment = StatusBar.Item.LEFT,
    shrink = true,
    get_item = function(_, dv)
      if dv.buffer.abs_filename then
        local display = project_paths.display_path(dv.buffer.abs_filename, { kind = "file" })
        if display and display.text then return styled_path(display) end
      end
      local buffer_name = dv.buffer.intellij_untitled_name or dv.buffer:get_name()
      return { dv.buffer.filename and style.text or style.dim, common.home_encode(buffer_name) }
    end,
    tooltip = function(_, dv)
      if dv.buffer.abs_filename then
        return common.home_encode(dv.buffer.abs_filename), "Click to copy the full path"
      end
      return "Not saved to a file"
    end,
    can_click = function(dv)
      return dv.buffer.abs_filename ~= nil
    end,
    command = function(dv)
      if dv.buffer.abs_filename then copy_path(dv.buffer.abs_filename) end
    end,
  })

  self:add_item({
    predicate = predicate_textview,
    name = "text:selection",
    alignment = StatusBar.Item.RIGHT,
    get_item = function(_, dv)
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
    tooltip = function(_, dv)
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
    get_item = function(_, dv)
      local line, col = caret_line_col(dv)
      return {
        style.text, tostring(line),
        style.dim, ":",
        col > config.line_limit and style.accent or style.text, tostring(col),
      }
    end,
    tooltip = function(_, dv)
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
    get_item = function(_, dv)
      local indent_type, indent_size, confirmed = dv.buffer:get_indent_info()
      return {
        confirmed and style.text or style.dim,
        string.format("%s: %d", indent_type == "hard" and "Tabs" or "Spaces", indent_size),
      }
    end,
    tooltip = function(_, dv)
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
    get_item = function(_, dv)
      local styled = { style.text, dv.buffer.encoding or "none" }
      if dv.buffer.bom then
        table.insert(styled, style.dim)
        table.insert(styled, " BOM")
      end
      return styled
    end,
    tooltip = function(_, dv)
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
    get_item = function(_, dv)
      return { style.text, dv.buffer.crlf and "CRLF" or "LF" }
    end,
    tooltip = function(_, dv)
      return dv.buffer.crlf and "Line endings: CRLF (Windows)" or "Line endings: LF (Unix)",
        "Click to change line endings"
    end,
    command = "editor:select_line_ending",
  })
end


---Register default status bar items for image views.
function StatusBar:register_imageview_items()
  local function has_image(view)
    return view ~= nil and view.is ~= nil and view:is(ImageView) and view.image ~= nil
  end

  self:add_item({
    predicate = has_image,
    name = "image-view:file",
    alignment = StatusBar.Item.LEFT,
    shrink = true,
    get_item = function(_, view)
      return { style.text, common.basename(view.path) }
    end,
    tooltip = function(_, view)
      return common.home_encode(view.path), "Click to copy the full path"
    end,
    command = function(view) copy_path(view.path) end,
  })

  self:add_item({
    predicate = has_image,
    name = "image-view:size",
    alignment = StatusBar.Item.RIGHT,
    get_item = function(_, view)
      local w, h = view.image:get_size()
      return { style.text, string.format("%d × %d", w, h) }
    end,
    tooltip = "Image size in pixels",
  })

  self:add_item({
    predicate = has_image,
    name = "image-view:zoom",
    alignment = StatusBar.Item.RIGHT,
    get_item = function(_, view)
      return { style.text, string.format("%.0f%%", view.zoom_scale * 100) }
    end,
    tooltip = function() return "Zoom", "Click to reset zoom" end,
    command = "image:zoom_reset",
  })
end


local HEADING_MENU = {
  { label = "Normal Text", command = "markdown:normal_text" },
  { label = "Heading 1", command = "markdown:heading_1" },
  { label = "Heading 2", command = "markdown:heading_2" },
  { label = "Heading 3", command = "markdown:heading_3" },
}

-- Formatting buttons, from left to right. Each runs a command, or opens a menu of commands.
local MARKDOWN_BUTTONS = {
  { name = "heading", glyph = "\u{F027F}", label = "Heading", menu = HEADING_MENU },
  { name = "bold", glyph = "\u{F0264}", label = "Bold", command = "markdown:surround_bold" },
  { name = "italic", glyph = "\u{F0277}", label = "Italic", command = "markdown:surround_italic" },
  { name = "strikethrough", glyph = "\u{F0280}", label = "Strikethrough", command = "markdown:surround_strikethrough" },
  { name = "code", glyph = "\u{F0174}", label = "Inline Code", command = "markdown:surround_code" },
  { name = "link", glyph = "\u{F0339}", label = "Link", command = "markdown:insert_link" },
  { name = "bullets", glyph = "\u{F0279}", label = "Bulleted List", command = "markdown:toggle_bullet_list" },
  { name = "numbers", glyph = "\u{F027B}", label = "Numbered List", command = "markdown:toggle_numbered_list" },
  { name = "tasks", glyph = "\u{F0756}", label = "Task List", command = "markdown:toggle_task_list" },
  { name = "quote", glyph = "\u{F0757}", label = "Quote", command = "markdown:toggle_quote" },
  { name = "table", glyph = "\u{F04EB}", label = "Table", command = "markdown:insert_table" },
}

---Register the Markdown formatting buttons. They show in the focused Pane while its Markdown can change.
function StatusBar:register_markdown_items()
  if self:get_item("markdown:heading") then return end
  local function editable_markdown(view)
    local Editor = require "core.editor"
    return view ~= nil and view.extends ~= nil and view:extends(Editor)
      and require("core.markdown.live_render").is_markdown_buffer(view.buffer)
      and view:can_edit("format Markdown") == true
  end
  for _, button in ipairs(MARKDOWN_BUTTONS) do
    self:add_item({
      predicate = function(view)
        return editable_markdown(view) and (button.menu ~= nil or command.is_valid(button.command))
      end,
      name = "markdown:" .. button.name,
      alignment = StatusBar.Item.RIGHT,
      optional = true,
      get_item = function() return { style.format_icon_font, style.dim, button.glyph } end,
      tooltip = function()
        local binding = button.command and keymap.get_binding(button.command)
        return button.label, binding and require("core.context_menu").shortcut_text(binding) or nil
      end,
      command = button.command or function(_, _, _, _, chip)
        require("core.context_menu").open(chip.x, chip.y - math.floor(4 * SCALE), button.menu, { above = true })
      end,
    })
  end
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

return StatusBar
