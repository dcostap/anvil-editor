local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local prompt_bar_renderer = require "core.prompt_bar_renderer"
local Doc = require "core.doc"
local DocView = require "core.docview"
local View = require "core.view"
local RootPanel = require "core.rootpanel"


---Single-line document that prevents newline insertion.
---Used internally by the Global Prompt Bar for single-line input.
---@class core.global_prompt_bar.input : core.doc
---@overload fun():core.global_prompt_bar.input
---@field super core.doc
local SingleLineDoc = Doc:extend()

function SingleLineDoc:__tostring() return "SingleLineDoc" end

---Insert text, stripping any newlines to maintain single-line constraint.
---@param line integer Line number
---@param col integer Column number
---@param text string Text to insert (newlines will be removed)
function SingleLineDoc:normalize_edit_text(text, edit, opts)
  return tostring(text or ""):gsub("[\r\n]", "")
end

function SingleLineDoc:insert(line, col, text)
  SingleLineDoc.super.insert(self, line, col, self:normalize_edit_text(text))
end


---Global Prompt Bar: bottom-anchored full-width prompt for app-wide actions.
---Provides autocomplete, suggestions, and app-wide prompt execution.
---@class core.global_prompt_bar : core.docview
---@overload fun():core.global_prompt_bar
---@field super core.docview
---@field suggestion_idx integer Currently selected suggestion index
---@field suggestions table[] List of suggestion items
---@field suggestions_height number Animated height of suggestions box
---@field suggestions_offset number Scroll offset for suggestions list
---@field suggestions_first integer First visible suggestion index
---@field suggestions_last integer Last visible suggestion index
---@field last_change_id integer Last document change ID (for detecting updates)
---@field last_text string Last input text (for typeahead)
---@field gutter_width number Width of label gutter
---@field gutter_text_brightness number Label brightness animation value
---@field selection_offset number Animated cursor position in suggestions
---@field state core.global_prompt_bar.state Current prompt state
---@field font string Font name to use
---@field label string Label text displayed in gutter
---@field mouse_position table Mouse coordinates {x, y}
---@field save_suggestion string? Saved suggestion for cycling
local GlobalPromptBar = DocView:extend()

function GlobalPromptBar:__tostring() return "GlobalPromptBar" end

GlobalPromptBar.context = "application"

local noop = function() end


---Configuration state for one Global Prompt Bar interaction.
---@class core.global_prompt_bar.state
---@field submit fun(text: string, suggestion: table?) Callback when prompt text is submitted
---@field suggest fun(text: string): table[]? Function returning suggestion list
---@field cancel fun(explicit: boolean) Callback when prompt interaction is cancelled
---@field validate fun(text: string, suggestion: table?): boolean Validate before submission
---@field text string Initial text to display
---@field draw_text? fun(item: table, font: renderer.font, color: renderer.color, x: number, y: number, w: number, h: number) Custom suggestion renderer
---@field select_text boolean Whether to select initial text
---@field show_suggestions boolean Whether to show suggestions box
---@field typeahead boolean Whether to enable typeahead completion
---@field wrap boolean Whether suggestion cycling wraps around
local default_state = {
  submit = noop,
  suggest = noop,
  cancel = noop,
  validate = function() return true end,
  text = "",
  draw_text = nil,
  select_text = false,
  show_suggestions = true,
  typeahead = true,
  wrap = true,
}


---Constructor - initializes the Global Prompt Bar.
function GlobalPromptBar:new()
  GlobalPromptBar.super.new(self, SingleLineDoc())
  self.suggestion_idx = 1
  self.suggestions = {}
  self.suggestions_height = 0
  self.suggestions_offset = 0
  self.suggestions_first = 1
  self.suggestions_last = 0
  self.last_change_id = 0
  self.last_text = ""
  self.gutter_width = 0
  self.gutter_text_brightness = 0
  self.selection_offset = 0
  self.state = default_state
  self.font = "font"
  self.size.y = 0
  self.label = ""
  self.mouse_position = {x = 0, y = 0}
end


---Hide suggestions box.
---@deprecated Use state.show_suggestions = false instead
function GlobalPromptBar:set_hidden_suggestions()
  core.warn("Using deprecated function GlobalPromptBar:set_hidden_suggestions")
  self.state.show_suggestions = false
end


---Get the view name for display.
---@return string name Returns generic View name
function GlobalPromptBar:get_name()
  return View.get_name(self)
end


---Get screen position of line and column, vertically centered in view.
---@param line integer Line number (always 1 for single-line)
---@param col integer Column number
---@return number x Screen x coordinate
---@return number y Screen y coordinate (vertically centered)
function GlobalPromptBar:get_line_screen_position(line, col)
  local x = GlobalPromptBar.super.get_line_screen_position(self, 1, col)
  local _, y = self:get_content_offset()
  return x, prompt_bar_renderer.line_y(y, self.size.y, self:get_font())
end


---Check if this view accepts text input.
---@return boolean accepts Always returns true
function GlobalPromptBar:supports_text_input()
  return true
end


---Get scrollable size (disabled for the Global Prompt Bar).
---@return integer size Always returns 0
function GlobalPromptBar:get_scrollable_size()
  return 0
end


---Get horizontal scrollable size (disabled for the Global Prompt Bar).
---@return integer size Always returns 0
function GlobalPromptBar:get_h_scrollable_size()
  return 0
end


---Scroll to make position visible (no-op for the Global Prompt Bar).
function GlobalPromptBar:scroll_to_make_visible()
  -- no-op function to disable this functionality
end


---Get the current input text.
---@return string text The entire input text
function GlobalPromptBar:get_text()
  return self.doc:get_text(1, 1, 1, math.huge)
end


---Set the input text and optionally select it.
---@param text string Text to set
---@param select boolean? If true, select all text
function GlobalPromptBar:set_text(text, select)
  self.last_text = text
  self.doc:remove(1, 1, math.huge, math.huge)
  self.doc:text_input(text)
  if select then
    self.doc:set_selection(math.huge, math.huge, 1, 1)
  end
end


---Move suggestion selection by offset (for arrow keys/wheel).
---Handles wrapping, history cycling, and updates the input text.
---@param dir integer Direction to move (-1 for up/previous, 1 for down/next)
function GlobalPromptBar:move_suggestion_idx(dir)
  local function overflow_suggestion_idx(n, count)
    if count == 0 then return 0 end
    if self.state.wrap then
      return (n - 1) % count + 1
    else
      return common.clamp(n, 1, count)
    end
  end

  if self.state.show_suggestions then
    local n = self.suggestion_idx + dir
    self.suggestion_idx = overflow_suggestion_idx(n, #self.suggestions)
    self:complete()
    self.last_change_id = self.doc:get_change_id()
  else
    local current_suggestion = #self.suggestions > 0 and self.suggestions[self.suggestion_idx].text
    local text = self:get_text()
    if text == current_suggestion then
      local n = self.suggestion_idx + dir
      if n == 0 and self.save_suggestion then
        self:set_text(self.save_suggestion)
      else
        self.suggestion_idx = overflow_suggestion_idx(n, #self.suggestions)
        self:complete()
      end
    else
      self.save_suggestion = text
      self:complete()
    end
    self.last_change_id = self.doc:get_change_id()
    self.state.suggest(self:get_text())
  end
end


---Complete input with currently selected suggestion.
---Sets the input text to the selected suggestion's text.
function GlobalPromptBar:complete()
  if #self.suggestions > 0 and self.suggestions[self.suggestion_idx] then
    self:set_text(self.suggestions[self.suggestion_idx].text)
  end
end


---Submit the current prompt text.
---Validates input, calls submit callback, and exits the Global Prompt Bar.
function GlobalPromptBar:submit()
  local suggestion = self.suggestions[self.suggestion_idx]
  local text = self:get_text()
  if self.state.validate(text, suggestion) then
    local submit = self.state.submit
    self:exit(true)
    submit(text, suggestion)
  end
end


---Enter the Global Prompt Bar with a prompt.
---Activates the prompt with the specified label and options.
---@param label string Label text to display (": " will be appended)
---@param options core.global_prompt_bar.state Configuration options for this prompt interaction
---@overload fun(label: string, submit: function, suggest: function, cancel: function, validate: function)
function GlobalPromptBar:enter(label, ...)
  if self.state ~= default_state then
    return
  end
  local options = select(1, ...)

  if type(options) ~= "table" then
    core.warn("Using GlobalPromptBar:enter in a deprecated way")
    local submit, suggest, cancel, validate = ...
    options = {
      submit = submit,
      suggest = suggest,
      cancel = cancel,
      validate = validate,
    }
  end

  -- Support deprecated GlobalPromptBar:set_hidden_suggestions
  -- Remove this when set_hidden_suggestions is not supported anymore
  if options.show_suggestions == nil then
    options.show_suggestions = self.state.show_suggestions
  end

  self.state = common.merge(default_state, options)

  -- Retrieve text added with GlobalPromptBar:set_text
  -- and use it if options.text is not given
  local set_text = self:get_text()
  if options.text or options.select_text then
    local text = options.text or set_text
    self:set_text(text, self.state.select_text)
  end

  core.set_active_view(self)
  self:update_suggestions()
  self.gutter_text_brightness = 100
  self.label = label .. ": "
end


---Exit the Global Prompt Bar.
---Restores previous view and calls cancel callback if not submitted.
---@param submitted boolean? True if prompt text was submitted, false if cancelled
---@param inexplicit boolean? True if exit was automatic (e.g., focus lost)
function GlobalPromptBar:exit(submitted, inexplicit)
  if core.active_view == self then
    core.set_active_view(core.last_active_view)
  end
  local cancel = self.state.cancel
  self.state = default_state
  self.doc:reset()
  self.suggestions = {}
  if not submitted then cancel(not inexplicit) end
  self.save_suggestion = nil
  self.last_text = ""
end


---Get line height for input text.
---@return integer height Line height in pixels
function GlobalPromptBar:get_line_height()
  return prompt_bar_renderer.line_height(self:get_font())
end


---Get the width of the label gutter area.
---@return number width Gutter width in pixels
function GlobalPromptBar:get_gutter_width()
  return self.gutter_width
end


---Get line height for suggestion items.
---@return number height Suggestion line height in pixels
function GlobalPromptBar:get_suggestion_line_height()
  return self:get_font():get_height() + style.padding.y
end


---Update suggestions list by calling suggest callback.
---Normalizes string suggestions to table format {text = string}.
function GlobalPromptBar:update_suggestions()
  local t = self.state.suggest(self:get_text()) or {}
  local res = {}
  for i, item in ipairs(t) do
    if type(item) == "string" then
      item = { text = item }
    end
    res[i] = item
  end
  self.suggestions = res
  self.suggestion_idx = 1
end


---Update the Global Prompt Bar state each frame.
---Handles typeahead, animations, and auto-exit on focus loss.
function GlobalPromptBar:update()
  GlobalPromptBar.super.update(self)

  if core.active_view ~= self and self.state ~= default_state then
    self:exit(false, true)
  end

  -- update suggestions if text has changed
  if self.last_change_id ~= self.doc:get_change_id() then
    self:update_suggestions()
    if self.state.typeahead and self.suggestions[self.suggestion_idx] then
      local current_text = self:get_text()
      local suggested_text = self.suggestions[self.suggestion_idx].text or ""
      if #self.last_text < #current_text and
         string.find(suggested_text, current_text, 1, true) == 1 then
        self:set_text(suggested_text)
        self.doc:set_selection(1, #current_text + 1, 1, math.huge)
      end
      self.last_text = current_text
    end
    self.last_change_id = self.doc:get_change_id()
  end

  -- update gutter text color brightness
  self:move_towards("gutter_text_brightness", 0, 0.1, "global_prompt_bar")

  -- update gutter width
  local dest = prompt_bar_renderer.label_width(self.label, self:get_font())
  if self.size.y <= 0 then
    self.gutter_width = dest
  else
    self:move_towards("gutter_width", dest, nil, "global_prompt_bar")
  end

  -- update suggestions box height
  local lh = self:get_suggestion_line_height()
  local dest = self.state.show_suggestions and math.min(#self.suggestions, config.max_visible_commands) * lh or 0
  self:move_towards("suggestions_height", dest, nil, "global_prompt_bar")

  -- update suggestion cursor offset
  local dest = math.min(self.suggestion_idx, config.max_visible_commands) * self:get_suggestion_line_height()
  self:move_towards("selection_offset", dest, nil, "global_prompt_bar")

  -- update size based on whether this is the active_view
  local dest = 0
  if self == core.active_view then
    dest = prompt_bar_renderer.height(style.font)
  end
  self:move_towards(self.size, "y", dest, nil, "global_prompt_bar")
end


---Draw line highlight (disabled for the Global Prompt Bar).
function GlobalPromptBar:draw_line_highlight()
  -- no-op function to disable this functionality
end


---Draw the label gutter with animated brightness.
---@param idx integer Line index (unused)
---@param x number Gutter x position
---@param y number Gutter y position
---@return integer height Line height
function GlobalPromptBar:draw_line_gutter(idx, x, y)
  local pos = self.position
  prompt_bar_renderer.draw_label(
    self:get_font(),
    self.label,
    pos.x,
    pos.y,
    self:get_gutter_width(),
    self.size.y,
    self.gutter_text_brightness
  )
  return self:get_line_height()
end


---Check if the mouse is hovering the suggestions box.
---@return boolean hovering True if mouse is over suggestions box
function GlobalPromptBar:is_mouse_on_suggestions()
  if self.state.show_suggestions and #self.suggestions > 0 then
    local mx, my = self.mouse_position.x, self.mouse_position.y
    local dh = style.divider_size
    local sh = math.ceil(self.suggestions_height)
    local x, y, w, h = self.position.x, self.position.y - sh - dh, self.size.x, sh
    if mx >= x and mx <= x+w and my >= y and my <= y+h then
      return true
    end
  end
  return false
end


---Draw the suggestions dropdown box.
---Renders background, divider, and suggestion items with highlighting.
---@param self core.global_prompt_bar
local function draw_suggestions_box(self)
  local lh = self:get_suggestion_line_height()
  local dh = style.divider_size
  local x, _ = self:get_line_screen_position()
  local h = math.ceil(self.suggestions_height)
  local rx, ry, rw, rh = self.position.x, self.position.y - h - dh, self.size.x, h

  if #self.suggestions > 0 then
    -- draw suggestions background
    renderer.draw_rect(rx, ry, rw, rh, style.background3)
    renderer.draw_rect(rx, ry - dh, rw, dh, style.divider)

    -- draw suggestion text
    local current = self.suggestion_idx
    local offset = math.max(current - config.max_visible_commands, 0)
    if self.suggestions_first-1 == current then
      offset = math.max(self.suggestions_first - 2, 0)
    end
    local first = 1 + offset
    local last = math.min(offset + config.max_visible_commands, #self.suggestions)
    if
      current < self.suggestions_first
      or
      current > self.suggestions_last
      or
      self.suggestions_last - self.suggestions_first < last - first
    then
      self.suggestions_first = first
      self.suggestions_last = last
      self.suggestions_offset = offset
    else
      offset = self.suggestions_offset
      first = self.suggestions_first
      last = math.min(self.suggestions_last, #self.suggestions)
    end
    core.push_clip_rect(rx, ry, rw, rh)
    local draw_text = self.state.draw_text
    local font = self:get_font()
    for i=first, last do
      local item = self.suggestions[i]
      local color = (i == current) and style.accent or style.text
      local y = self.position.y - (i - offset) * lh - dh
      if i == current then
        renderer.draw_rect(rx, y, rw, lh, style.line_highlight)
      end
      local w = self.size.x - x - style.padding.x
      if not draw_text then
        common.draw_text(font, color, item.text, nil, x, y, 0, lh)
      else
        draw_text(item, font, color, x, y, w, lh)
      end
      if item.info then
        common.draw_text(self:get_font(), style.dim, item.info, "right", x, y, w, lh)
      end
    end
    core.pop_clip_rect()
  end
end


---Draw the Global Prompt Bar.
---Renders input text and defers suggestions box drawing.
function GlobalPromptBar:draw()
  GlobalPromptBar.super.draw(self)
  if self.state.show_suggestions then
    core.root_panel:defer_draw(draw_suggestions_box, self)
  end
end


---Handle mouse movement over the Global Prompt Bar and suggestions.
---Updates suggestion selection when hovering suggestions box.
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@return boolean handled True if mouse is over suggestions
function GlobalPromptBar:on_mouse_moved(x, y, ...)
  self.mouse_position.x = x
  self.mouse_position.y = y
  if self:is_mouse_on_suggestions() then
    core.request_cursor("arrow")

    local lh = self:get_suggestion_line_height()
    local dh = style.divider_size
    local offset = self.suggestions_offset
    local first = self.suggestions_first
    local last = self.suggestions_last

    for i=first, last do
      local sy = self.position.y - (i - offset) * lh - dh
      if y >= sy then
        self.suggestion_idx=i
        self:complete()
        self.last_change_id = self.doc:get_change_id()
        break
      end
    end
    return true
  end
  GlobalPromptBar.super.on_mouse_moved(self, x, y, ...)
  return false
end


---Handle mouse wheel over suggestions box.
---Scrolls through suggestions when hovering.
---@param y number Scroll delta (negative = down, positive = up)
---@return boolean handled True if event was consumed
function GlobalPromptBar:on_mouse_wheel(y, ...)
  if self:is_mouse_on_suggestions() then
    if y < 0 then
      self:move_suggestion_idx(-1)
    else
      self:move_suggestion_idx(1)
    end
    return true
  end
  GlobalPromptBar.super.on_mouse_wheel(self, y, ...)
  return false
end


---Handle mouse press on suggestions box.
---Submits the current prompt text if clicking a suggestion with left button.
---@param button core.view.mousebutton
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@param clicks integer Number of clicks
---@return boolean handled True if event was consumed
function GlobalPromptBar:on_mouse_pressed(button, x, y, clicks)
  if self:is_mouse_on_suggestions() then
    if button == "left" then
      self:submit()
    end
    return true
  end
  GlobalPromptBar.super.on_mouse_pressed(self, button, x, y, clicks)
  return false
end


---Handle mouse release on suggestions box.
---Consumes event to prevent propagation.
---@return boolean handled True if mouse is over suggestions
function GlobalPromptBar:on_mouse_released(...)
  if self:is_mouse_on_suggestions() then
    return true
  end
  GlobalPromptBar.super.on_mouse_released(self, ...)
  return false
end


--------------------------------------------------------------------------------
-- Transmit mouse events to the suggestions box
-- TODO: Remove these overrides once FloatingView is implemented
--------------------------------------------------------------------------------
-- These monkey-patches intercept Root Panel mouse events to allow the
-- Global Prompt Bar suggestions box (which renders outside the bar bounds)
-- to receive mouse events. This is a temporary solution until FloatingView
-- is implemented to properly handle overlay UI elements.

local root_panel_on_mouse_moved = RootPanel.on_mouse_moved
local root_panel_on_mouse_wheel = RootPanel.on_mouse_wheel
local root_panel_on_mouse_pressed = RootPanel.on_mouse_pressed
local root_panel_on_mouse_released = RootPanel.on_mouse_released


---Intercept mouse movement to check Global Prompt Bar suggestions first.
function RootPanel:on_mouse_moved(...)
  if core.active_view:is(GlobalPromptBar) then
    if core.active_view:on_mouse_moved(...) then return true end
  end
  return root_panel_on_mouse_moved(self, ...)
end


---Intercept mouse wheel to check Global Prompt Bar suggestions first.
function RootPanel:on_mouse_wheel(...)
  if core.active_view:is(GlobalPromptBar) then
    if core.active_view:on_mouse_wheel(...) then return true end
  end
  return root_panel_on_mouse_wheel(self, ...)
end


---Intercept mouse press to check Global Prompt Bar suggestions first.
function RootPanel:on_mouse_pressed(...)
  if core.active_view:is(GlobalPromptBar) then
    if core.active_view:on_mouse_pressed(...) then return true end
  end
  return root_panel_on_mouse_pressed(self, ...)
end


---Intercept mouse release to check Global Prompt Bar suggestions first.
function RootPanel:on_mouse_released(...)
  if core.active_view:is(GlobalPromptBar) then
    if core.active_view:on_mouse_released(...) then return true end
  end
  return root_panel_on_mouse_released(self, ...)
end


return GlobalPromptBar
