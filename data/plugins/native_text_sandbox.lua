-- mod-version:3
local core = require "core"
local command = require "core.command"
local common = require "core.common"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local native_text = require "native_text"

local NativeTextSandboxView = View:extend()

function NativeTextSandboxView:__tostring() return "NativeTextSandboxView" end

NativeTextSandboxView.context = "workspace"

function NativeTextSandboxView:new(text, filename)
  NativeTextSandboxView.super.new(self)
  self.buffer = native_text.new_buffer(text or "Native text sandbox\n\nType here. This view is backed by src/text Buffer/Editor userdata.")
  if filename then
    local ok = self.buffer:load_file(filename)
    if not ok then core.error("Failed to open native Buffer: %s", filename) end
  end
  self.editor = self.buffer:new_editor()
  self.scrollable = true
  self.cursor = "ibeam"
end

function NativeTextSandboxView:get_name()
  local path = self.buffer:path()
  local name = path and common.basename(path) or "Native Text Sandbox"
  if self.buffer:is_dirty() then name = "*" .. name end
  return name
end

function NativeTextSandboxView:supports_text_input()
  return true
end

function NativeTextSandboxView:get_line_height()
  return style.font:get_height() + math.floor(style.padding.y / 2)
end

function NativeTextSandboxView:get_gutter_width()
  return style.font:get_width(tostring(math.max(1, self.buffer:line_count()))) + style.padding.x * 2
end

function NativeTextSandboxView:get_scrollable_size()
  return math.max(self.size.y, self.buffer:line_count() * self:get_line_height() + style.padding.y * 2)
end

function NativeTextSandboxView:line_col_to_screen(line, col)
  local lh = self:get_line_height()
  local x = self.position.x + self:get_gutter_width() + style.padding.x - self.scroll.x + style.font:get_width(string.rep(" ", col))
  local y = self.position.y + style.padding.y - self.scroll.y + line * lh
  return x, y
end

function NativeTextSandboxView:cursor_line_col()
  local cursor = self.editor:cursor().cursor or 0
  local lc = self.buffer:offset_to_line_col(cursor)
  return lc and lc.line or 0, lc and lc.col or 0
end

function NativeTextSandboxView:scroll_to_cursor()
  local line = self:cursor_line_col()
  local lh = self:get_line_height()
  local y = line * lh
  if y < self.scroll.to.y then
    self.scroll.to.y = y
  elseif y + lh > self.scroll.to.y + self.size.y then
    self.scroll.to.y = y + lh - self.size.y + style.padding.y * 2
  end
  self:clamp_scroll_position()
end

function NativeTextSandboxView:on_text_input(text)
  if text and text ~= "" then
    self.editor:insert(text)
    self:scroll_to_cursor()
    core.redraw = true
  end
  return true
end

function NativeTextSandboxView:on_mouse_pressed(button, x, y, clicks)
  if NativeTextSandboxView.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  if button ~= "left" then return false end

  local lh = self:get_line_height()
  local line = math.floor((y - self.position.y + self.scroll.y - style.padding.y) / lh)
  line = common.clamp(line, 0, math.max(0, self.buffer:line_count() - 1))
  local text = self.buffer:line(line) or ""
  local text_x = self.position.x + self:get_gutter_width() + style.padding.x - self.scroll.x
  local col = 0
  local relx = math.max(0, x - text_x)
  for i = 1, #text do
    local next_width = style.font:get_width(text:sub(1, i))
    if next_width > relx then break end
    col = i
  end
  local offset = self.buffer:line_col_to_offset(line, col)
  if offset then self.editor:set_cursor(offset) end
  core.redraw = true
  return true
end

function NativeTextSandboxView:draw()
  self:draw_background(style.background)
  self:update()

  local x = self.position.x
  local y = self.position.y
  local w = self.size.x
  local h = self.size.y
  local lh = self:get_line_height()
  local gutter_w = self:get_gutter_width()
  local line_count = self.buffer:line_count()
  local first_line = math.max(0, math.floor(self.scroll.y / lh))
  local last_line = math.min(line_count - 1, first_line + math.ceil(h / lh) + 1)

  core.push_clip_rect(x, y, w, h)
  renderer.draw_rect(x, y, gutter_w, h, style.line_number_background or style.background2)

  for line = first_line, last_line do
    local row_y = y + style.padding.y - self.scroll.y + line * lh
    local line_number = tostring(line + 1)
    common.draw_text(style.font, style.dim, line_number, "right", x, row_y, gutter_w - style.padding.x, lh)
    renderer.draw_text(style.font, self.buffer:line(line) or "", x + gutter_w + style.padding.x - self.scroll.x, row_y, style.text)
  end

  local cursor_line, cursor_col = self:cursor_line_col()
  local caret_x, caret_y = self:line_col_to_screen(cursor_line, cursor_col)
  renderer.draw_rect(caret_x, caret_y, math.max(1, SCALE), style.font:get_height(), style.caret)

  core.pop_clip_rect()
  self:draw_scrollbar()
end

local function with_active_native_view(fn)
  return function(view)
    view = view or core.active_view
    if view and view:is(NativeTextSandboxView) then
      fn(view)
      view:scroll_to_cursor()
      core.redraw = true
    end
  end
end

local function open_native_text_file(filename)
  if not filename or filename == "" then return end
  core.root_panel:get_active_node_default():add_view(NativeTextSandboxView(nil, filename))
end

command.add(nil, {
  ["native-text-sandbox:open"] = function()
    core.root_panel:get_active_node_default():add_view(NativeTextSandboxView())
  end,
  ["native-text-sandbox:open-file"] = function()
    core.open_file_dialog(core.window, function(status, result)
      if status == "accept" then
        for _, filename in ipairs(result) do open_native_text_file(filename) end
      elseif status == "error" then
        core.error("Error while opening native text dialog: %s", result or "")
      end
    end, { allow_many = true })
  end,
})

command.add(NativeTextSandboxView, {
  ["native-text-sandbox:newline"] = with_active_native_view(function(view) view.editor:newline() end),
  ["native-text-sandbox:backspace"] = with_active_native_view(function(view) view.editor:backspace() end),
  ["native-text-sandbox:delete"] = with_active_native_view(function(view) view.editor:delete() end),
  ["native-text-sandbox:left"] = with_active_native_view(function(view) view.editor:left(false) end),
  ["native-text-sandbox:right"] = with_active_native_view(function(view) view.editor:right(false) end),
  ["native-text-sandbox:up"] = with_active_native_view(function(view) view.editor:line_up(false) end),
  ["native-text-sandbox:down"] = with_active_native_view(function(view) view.editor:line_down(false) end),
  ["native-text-sandbox:undo"] = with_active_native_view(function(view) view.editor:undo() end),
  ["native-text-sandbox:redo"] = with_active_native_view(function(view) view.editor:redo() end),
  ["native-text-sandbox:save"] = with_active_native_view(function(view)
    if not view.buffer:save_file() then core.error("Failed to save native Buffer") end
  end),
  ["native-text-sandbox:duplicate-cursor-up"] = with_active_native_view(function(view) view.editor:dup_cursor_up() end),
  ["native-text-sandbox:duplicate-cursor-down"] = with_active_native_view(function(view) view.editor:dup_cursor_down() end),
})

keymap.add {
  ["return"] = "native-text-sandbox:newline",
  ["backspace"] = "native-text-sandbox:backspace",
  ["delete"] = "native-text-sandbox:delete",
  ["left"] = "native-text-sandbox:left",
  ["right"] = "native-text-sandbox:right",
  ["up"] = "native-text-sandbox:up",
  ["down"] = "native-text-sandbox:down",
  ["ctrl+z"] = "native-text-sandbox:undo",
  ["ctrl+y"] = "native-text-sandbox:redo",
  ["ctrl+s"] = "native-text-sandbox:save",
  ["ctrl+shift+up"] = "native-text-sandbox:duplicate-cursor-up",
  ["ctrl+shift+down"] = "native-text-sandbox:duplicate-cursor-down",
}

return NativeTextSandboxView
