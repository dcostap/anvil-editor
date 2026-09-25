-- mod-version:3
-- Live color theme editor. Drafts stay in memory until saved.
local core = require "core"
local command = require "core.command"
local style = require "core.style"
local edits = require "core.theme_edits"
local Widget = require "widget"
local Button = require "widget.button"
local CheckBox = require "widget.checkbox"
local ColorPicker = require "widget.colorpicker"
local Label = require "widget.label"
local ListBox = require "widget.listbox"
local TextBox = require "widget.textbox"

local theme_editor = {}
local editor

local function settings()
  return require "plugins.settings"
end

local function module_name(name)
  return "colors." .. (name == "dark" and "default" or name)
end

local function rgba(value)
  if not value then return "inherited" end
  return string.format("#%02X%02X%02X%02X", value[1], value[2], value[3], value[4])
end

local function copy_color(value)
  return edits.color(value)
end

local function sorted_keys(tbl)
  local keys = {}
  for key in pairs(tbl) do keys[#keys + 1] = key end
  table.sort(keys)
  return keys
end

local ThemeEditor = Widget:extend()

function ThemeEditor:new(name)
  ThemeEditor.super.new(self)
  self.name = "Theme Editor"
  self.draggable = true
  self.scrollable = false
  self.theme = name
  self.previous_theme = settings().config.theme or "dark"
  self.selected_path = nil
  self.suppress_picker = false
  self.resizing = nil
  self:set_size(1050 * SCALE, 620 * SCALE)
  self:set_position(40 * SCALE, 40 * SCALE)

  self.title = Label(self, "Edit theme: " .. name)
  self.help = Label(self, "Changes appear now. Reload or Close drops changes you did not save.", true)
  self.filter = TextBox(self, "", "Find named colors or rules...")
  self.list = ListBox(self)
  self.list.border.width = 0
  self.list:add_column("Rule / named color", 295 * SCALE, false)
  self.list:add_column("Source", 160 * SCALE, false)
  self.list:add_column("Effective color", 105 * SCALE, false)
  self.selected = Label(self, "Select a rule or named color.", true)
  self.override = CheckBox(self, "Use this override")
  self.picker = ColorPicker(self, {255, 255, 255, 255})
  self.link = Button(self, "Use Named Color")
  self.direct = Button(self, "Use Direct Color")
  self.add_rule = Button(self, "Add Syntax Rule")
  self.save_user = Button(self, "Save User")
  self.save_source = Button(self, "Publish Source")
  if not edits.source_available() then self.save_source:hide() end
  self.reload_button = Button(self, "Reload Saved")
  self.close_button = Button(self, "Close")

  local view = self
  function self.filter:on_change(text) view.list:filter(text) end
  function self.list:on_row_click(_, path) view:select(path) end
  function self.picker:on_change(value) view:change_color(value) end
  function self.override:on_checked(value) view:toggle_override(value) end
  function self.link:on_click() view:choose_named_color() end
  function self.direct:on_click() view:use_direct_color() end
  function self.add_rule:on_click() view:prompt_new_rule() end
  function self.save_user:on_click() view:save(false) end
  function self.save_source:on_click() view:save(true) end
  function self.reload_button:on_click() view:reload() end
  function self.close_button:on_click() theme_editor.close() end

  self:reload()
end

function ThemeEditor:reload()
  local saved, err = edits.load(self.theme)
  if err then core.error("%s", err); return end
  self.draft = saved
  self.draft.palette = self.draft.palette or {}
  self.draft.rules = self.draft.rules or {}
  -- Capture the unedited theme. A reload does not keep unsaved changes.
  core.reload_module(module_name(self.theme), {theme_draft = {}})
  self.base = edits.capture(style)
  self:preview()
  core.log_quiet("Theme Editor loaded %s", self.theme)
end

function ThemeEditor:preview()
  edits.apply(style, self.base, self.draft)
  core.theme_edit_custom_syntax = edits.custom_syntax_keys(self.base, self.draft)
  core.color_theme_generation = (core.color_theme_generation or 0) + 1
  core.bump_render_style_generation("theme-editor-preview")
  self:refresh_rows()
  if self.selected_path then self:select(self.selected_path) end
end

function ThemeEditor:paths()
  local paths = {}
  local included = {}
  local function add(path)
    if included[path] then return end
    included[path] = true
    paths[#paths + 1] = path
    local parent = path:match("^(syntax%..+)%.[^.]+$")
    if parent then add(parent) end
  end
  for name in pairs(self.base.palette) do add("palette." .. name) end
  for _, entry in ipairs(self.base.entries) do add(entry.path) end
  for path in pairs(self.draft.rules) do
    if path:match("^syntax%.") then add(path) end
  end
  table.sort(paths, function(a, b)
    local function rank(path)
      if path:match("^palette%.") then return 1 end
      if path:match("^syntax%.") then return 3 end
      return 2
    end
    local ar, br = rank(a), rank(b)
    return ar == br and a < b or ar < br
  end)
  return paths
end

function ThemeEditor:current_color(path)
  local name = path:match("^palette%.(.+)$")
  if name then return style.theme_palette[name] end
  local entry = self.base.by_path[path]
  if entry then return entry.container[entry.key] end
  local syntax = path:match("^syntax%.(.+)$")
  return syntax and style.syntax[syntax]
end

function ThemeEditor:source(path)
  if path:match("^palette%.") then return "named color" end
  local rule = self.draft.rules[path]
  if rule and rule.enabled == false then return "override off" end
  if rule and rule.palette then return "named: " .. rule.palette end
  if rule and rule.color then return "direct color" end
  local entry = self.base.by_path[path]
  if entry and entry.palette then return "named: " .. entry.palette end
  if entry then return "theme color" end
  return "inherited"
end

function ThemeEditor:refresh_rows()
  self.list:clear()
  for _, path in ipairs(self:paths()) do
    local value = self:current_color(path)
    local source = self:source(path)
    local indent = path:match("^syntax%.(.+)$")
    indent = indent and string.rep("  ", select(2, indent:gsub("%.", ""))) or ""
    local label = indent .. path
    local color = value or style.dim
    self.list:add_row({style.text, label, ListBox.COLEND,
      style.dim, source, ListBox.COLEND, color, rgba(value)}, path)
  end
  if self.filter:get_text() ~= "" then self.list:filter(self.filter:get_text()) end
end

function ThemeEditor:select(path)
  self.selected_path = path
  if not path then return end
  local named = path:match("^palette%.") ~= nil
  if named then
    self.override:hide()
    self.link:hide()
    self.direct:hide()
  else
    self.override:show()
    self.link:show()
    self.direct:show()
  end
  local value = self:current_color(path)
  local parent = path:match("^syntax%.(.+)%.[^.]+$")
  local saved = self.draft.rules[path]
  self.selected:set_label(path .. "\n" .. self:source(path) .. " = " .. rgba(value)
    .. (saved and saved.enabled == false and saved.color
      and ("\nStored override: " .. rgba(saved.color)) or "")
    .. (parent and ("\nParent: syntax." .. parent .. " = " .. rgba(style.syntax[parent])) or ""))
  self.suppress_picker = true
  local picked = saved and saved.enabled == false and saved.color or value
  if picked then self.picker:set_color(copy_color(picked)) end
  self.override:set_checked(not (self.draft.rules[path] and self.draft.rules[path].enabled == false))
  self.suppress_picker = false
end

function ThemeEditor:set_palette(name, value)
  if not self.base.palette[name] then return end
  self.draft.palette[name] = copy_color(value)
  self:preview()
end

function ThemeEditor:set_rule(path, rule)
  if not self.base.by_path[path] and not path:match("^syntax%.[%w_.]+$") then return end
  self.draft.rules[path] = rule
  self:preview()
end

function ThemeEditor:change_color(value)
  if self.suppress_picker or not self.selected_path then return end
  local path = self.selected_path
  local name = path:match("^palette%.(.+)$")
  if name then return self:set_palette(name, value) end
  local rule = self.draft.rules[path] or {}
  -- A disabled rule keeps its edited color until the override is enabled.
  rule.color = copy_color(value)
  rule.palette = nil
  if rule.enabled == nil then rule.enabled = true end
  self:set_rule(path, rule)
end

function ThemeEditor:toggle_override(enabled)
  if self.suppress_picker or not self.selected_path then return end
  local path = self.selected_path
  if path:match("^palette%.") then return end
  local rule = self.draft.rules[path] or {color = copy_color(self:current_color(path))}
  rule.enabled = enabled
  self:set_rule(path, rule)
end

function ThemeEditor:use_direct_color()
  local path = self.selected_path
  if not path or path:match("^palette%.") then return end
  self:set_rule(path, {enabled = true, color = copy_color(self:current_color(path))})
end

function ThemeEditor:choose_named_color()
  local path = self.selected_path
  if not path or path:match("^palette%.") then return end
  local names = sorted_keys(self.base.palette)
  core.global_prompt_bar:enter("Named color", {
    suggest = function(text)
      local result = {}
      for _, name in ipairs(names) do
        if name:lower():find(text:lower(), 1, true) then
          result[#result + 1] = {text = name}
        end
      end
      return result
    end,
    validate = function(text) return self.base.palette[text] ~= nil end,
    submit = function(text, suggestion)
      local name = suggestion and suggestion.text or text
      if self.base.palette[name] then
        self:set_rule(path, {enabled = true, palette = name})
      end
    end,
  })
end

function ThemeEditor:prompt_new_rule()
  core.global_prompt_bar:enter("Syntax rule (for example type.class)", {
    validate = function(text) return text:match("^[%w_]+[%.%w_]*$") ~= nil end,
    submit = function(text)
      local path = "syntax." .. text
      if not self.base.by_path[path] and not self.draft.rules[path] then
        self:set_rule(path, {enabled = false, color = copy_color(style.syntax[text] or style.syntax.normal)})
      end
      self:select(path)
    end,
  })
end

function ThemeEditor:save(source)
  local path, err = edits.save(self.theme, self.draft, source)
  if not path then core.error("Theme save failed: %s", err); return end
  settings().apply_color_theme(self.theme)
  self.previous_theme = self.theme
  core.log("Theme %s saved to %s", self.theme, path)
  self:reload()
end

function ThemeEditor:hide()
  ThemeEditor.super.hide(self)
  core.reload_module(module_name(self.previous_theme))
  core.log_quiet("Theme Editor closed; unsaved changes discarded")
end

function ThemeEditor:update_size_position()
  ThemeEditor.super.update_size_position(self)
  local pad, gap = style.padding.x, style.padding.y
  local w, h = self:get_width(), self:get_height()
  local right = w - 390 * SCALE
  local detail_width = w - right - pad * 2
  self.title:set_position(pad, gap)
  self.help:set_position(pad, self.title:get_bottom() + gap / 2)
  self.close_button:set_position(w - self.close_button:get_width() - pad, gap)
  self.filter:set_position(pad, self.help:get_bottom() + gap)
  self.filter:set_size(right - pad * 2)
  self.list:set_position(pad, self.filter:get_bottom() + gap)
  self.list:set_size(right - pad * 2, math.max(140 * SCALE, h - self.list.position.ry - 110 * SCALE))
  self.selected:set_position(right, self.list.position.ry)
  self.selected:set_size(detail_width, nil)
  self.override:set_position(right, self.selected:get_bottom() + gap)
  self.picker:set_position(right, self.override:get_bottom() + gap)
  self.link:set_position(right, self.picker:get_bottom() + gap)
  self.direct:set_position(right, self.link:get_bottom() + gap)
  self.add_rule:set_position(pad, h - self.add_rule:get_height() - gap)
  self.save_user:set_position(self.add_rule:get_right() + pad, self.add_rule.position.ry)
  self.save_source:set_position(self.save_user:get_right() + pad, self.add_rule.position.ry)
  local last = edits.source_available() and self.save_source or self.save_user
  self.reload_button:set_position(last:get_right() + pad, self.add_rule.position.ry)
end

function ThemeEditor:on_mouse_pressed(button, x, y, clicks)
  local grip = 20 * SCALE
  if button == "left" and x >= self.position.x + self:get_width() - grip
      and y >= self.position.y + self:get_height() - grip then
    self.resizing = {x = x, y = y, w = self:get_width(), h = self:get_height()}
    return true
  end
  return ThemeEditor.super.on_mouse_pressed(self, button, x, y, clicks)
end

function ThemeEditor:on_mouse_moved(x, y, dx, dy)
  if self.resizing then
    self:set_size(math.max(950 * SCALE, self.resizing.w + x - self.resizing.x),
      math.max(520 * SCALE, self.resizing.h + y - self.resizing.y))
    self.perform_update_size_position = true
    core.redraw = true
    return true
  end
  return ThemeEditor.super.on_mouse_moved(self, x, y, dx, dy)
end

function ThemeEditor:on_mouse_released(button, x, y)
  if self.resizing then self.resizing = nil; return true end
  return ThemeEditor.super.on_mouse_released(self, button, x, y)
end

function ThemeEditor:draw()
  if not ThemeEditor.super.draw(self) then return false end
  local x = self.position.x + self:get_width()
  local y = self.position.y + self:get_height()
  for i = 1, 3 do
    local offset = i * 5 * SCALE
    renderer.draw_rect(x - offset, y - 2 * SCALE, offset, 2 * SCALE, style.dim)
  end
  return true
end

function theme_editor.open(name)
  if editor then
    if editor:is_visible() then editor:hide() end
    editor.theme = name
    editor.previous_theme = settings().config.theme or "dark"
    editor.title:set_label("Edit theme: " .. name)
    editor.selected_path = nil
    editor:reload()
  else
    editor = ThemeEditor(name)
  end
  editor:show()
  return editor
end

function theme_editor.close()
  if editor and editor:is_visible() then editor:hide() end
end

command.add(nil, {
  ["theme_editor:edit_theme"] = command.palette(function()
    core.global_prompt_bar:enter("Edit theme", {
      suggest = function(text)
        local result = {}
        for _, theme in ipairs(settings().get_installed_colors()) do
          if theme.name:lower():find(text:lower(), 1, true) then
            result[#result + 1] = {text = theme.name}
          end
        end
        return result
      end,
      validate = function(text)
        for _, theme in ipairs(settings().get_installed_colors()) do
          if theme.name == text then return true end
        end
        return false
      end,
      submit = function(text, suggestion)
        theme_editor.open(suggestion and suggestion.text or text)
      end,
    })
  end),
})

return theme_editor
