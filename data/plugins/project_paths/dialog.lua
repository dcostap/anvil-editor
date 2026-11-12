-- The Project Paths Dialog: the Project's folders with their labels and roles.
-- The list shows each Project Path. The fields below it change the selected one. Each change applies at once.

local core = require "core"
local command = require "core.command"
local common = require "core.common"
local style = require "core.style"
local project_paths = require "core.project_paths"
local ui = require "core.ui"
local layout = require "core.ui.layout"
local Dialog = require("core.ui.dialog").Dialog
local Button = require "core.ui.button"
local List = require "core.ui.list"
local Segmented = require "core.ui.segmented"
local TextField = require "core.ui.text_field"
local paths = require "plugins.project_paths"

local ProjectPathsDialog = Dialog:extend()

function ProjectPathsDialog:__tostring() return "ProjectPathsDialog" end

-- The most rows that show before the list scrolls.
local VISIBLE_ROWS = 6

local ROLE_ICONS = { root = ui.icons.home, external = ui.icons.link, vendored = ui.icons.package }
local ROLE_TOOLTIPS = {
  external = "Source outside the Root Project. Browse files and symbols; Usage Search skips it.",
  vendored = "Dependency source inside or outside the Root Project. Usage Search includes it.",
}

local function role_color(role)
  if role == "external" then return style.project_path_external end
  if role == "vendored" then return style.project_path_vendored end
  return style.accent
end

local function key_of(entry)
  return common.path_compare_key(entry.path)
end

-- A folder in the Root Project shows its path from the Root Project. Others show their path from the home folder.
local function shown_path(path)
  local project = core.root_project and core.root_project()
  local root = project and project.path
  if root and common.path_belongs_to(path, root) then return common.relative_path(root, path) end
  return common.home_encode(path)
end

function ProjectPathsDialog:new()
  ProjectPathsDialog.super.new(self, { title = "Project Paths", width = 620 })
  local font = ui.font()
  self.list = List({
    row_height = 2 * font:get_height() + math.floor(14 * SCALE),
    max_rows = VISIBLE_ROWS,
    draw_row = function(...) self:draw_row(...) end,
    on_select = function() self:show_selected() end,
    on_activate = function() self:focus(self.label_field) end,
  })
  self.label_field = TextField({
    width = 320,
    on_submit = function(text)
      local entry = self:selected_entry()
      if not entry then return false end
      return paths.set_label(entry.id, text)
    end,
  })
  self.role_control = Segmented({
    on_change = function(role)
      local entry = self:selected_entry()
      return entry ~= nil and paths.set_role(entry.id, role)
    end,
  })
  self.location_text = layout.Text { wrap = false, cut = "start", align = "right" }
  self.reveal_button = Button({
    label = "Show in File Tree", icon = ui.icons.reveal, size = "small",
    on_click = function() self:reveal_selected() end,
  })
  self.remove_button = Button({
    label = "Remove", icon = ui.icons.remove, kind = "danger", size = "small",
    on_click = function() self:remove_selected() end,
  })
  self.add_button = Button({
    label = "Add Folder", icon = ui.icons.add,
    on_click = function() command.perform("project_paths:add") end,
  })
  self.done_button = Button({
    label = "Done", kind = "primary", min_width = 88,
    on_click = function() self:close() end,
  })
  self.body = layout.Column {
    self.list,
    layout.Group {
      layout.Field { title = "Label", control = self.label_field },
      layout.Field { title = "Role", control = self.role_control },
      layout.Field { title = "Location", control = self.location_text },
      layout.Row { gap = 8, self.reveal_button, self.remove_button },
    },
  }
  self.footer = layout.Row { justify = "between", self.add_button, self.done_button }
  self:refresh()
end

---The selected entry, or nil.
function ProjectPathsDialog:selected_entry()
  return self.list:selected_row()
end

---Read the Project Paths again. The selection stays on its folder, or on the same place when it was removed.
---`select` is a path or an entry ID to select instead.
function ProjectPathsDialog:refresh(select)
  local entries = project_paths.entries()
  local selected = self:selected_entry()
  local wanted = select and paths.find_entry(select)
  local wanted_key = (wanted and key_of(wanted)) or (selected and key_of(selected))
  local index = self.list.selected
  for i, entry in ipairs(entries) do
    if key_of(entry) == wanted_key then index = i end
  end
  self.generation = project_paths.generation()
  self.list:set_rows(entries, index)
  self:show_selected()
end

-- Show the selected entry in the fields.
function ProjectPathsDialog:show_selected()
  local entry = self:selected_entry()
  local field, role = self.label_field, self.role_control
  local editable = entry ~= nil and entry.role ~= "root"
  local shown_key = entry and key_of(entry)
  -- An edit in the label field stays while the same entry is selected.
  if shown_key ~= self.shown_key or field:get_text() == field.accepted then
    field:set_text(entry and entry.label or "")
  end
  self.shown_key = shown_key
  field.enabled = editable
  if not entry then
    role:set_options({}, nil)
  elseif entry.role == "root" then
    role:set_options({ { value = "root", label = paths.role_label("root"), enabled = false } }, "root")
  else
    local options = {}
    for _, value in ipairs({ "external", "vendored" }) do
      local allowed = false
      for _, candidate in ipairs(paths.roles_for(entry.path)) do allowed = allowed or candidate == value end
      options[#options + 1] = {
        value = value, label = paths.role_label(value), enabled = allowed, tooltip = ROLE_TOOLTIPS[value],
      }
    end
    -- The highlight slides between two entries with different roles. It starts again after the Root Project.
    if #role.options ~= #options then
      role:set_options(options, entry.role)
    else
      role.options, role.value = options, entry.role
    end
  end
  role.enabled = editable
  local location = self.location_text
  location:set_text(entry and (entry.exists == false and "Not found: " or "") .. common.home_encode(entry.path) or "")
  location.color = entry and entry.exists == false and style.dialog_danger or nil
  self.reveal_button.enabled = entry ~= nil and entry.exists ~= false
  self.remove_button.enabled = editable
  core.redraw = true
end

function ProjectPathsDialog:remove_selected()
  local entry = self:selected_entry()
  if not (entry and entry.role ~= "root") then return false end
  if not paths.remove(entry.id) then return false end
  self:refresh()
  self:focus(self.list)
  return true
end

function ProjectPathsDialog:reveal_selected()
  local entry = self:selected_entry()
  if not entry then return false end
  self:close()
  return command.perform("filetree:open_at_choose_path", entry.path)
end

-- With the list focused, Delete removes the selected row, and the character moves change its role.
function ProjectPathsDialog:perform(name)
  if self.focused == self.list then
    if name == "delete" then return self:remove_selected() end
    if self.role_control.enabled and self.role_control:perform(name) then return true end
  end
  return ProjectPathsDialog.super.perform(self, name)
end

function ProjectPathsDialog:on_update()
  -- The File Tree and the Workspace can change Project Paths while the Dialog is open.
  if project_paths.generation() ~= self.generation then self:refresh() end
end

------------------------------------------------------------------------------------------------------------------
-- Drawing

function ProjectPathsDialog:draw_row(entry, x, y, w, h, state)
  local um = ui.metrics()
  local font, icon_font = ui.font(), ui.icon_font()
  local pad = um.pad_x
  local line_h = font:get_height()
  local top = y + math.floor((h - 2 * line_h) / 2)
  local icon_w = math.floor(28 * SCALE)
  local icon = entry.exists == false and ui.icons.warning or ROLE_ICONS[entry.role] or ui.icons.folder
  local icon_color = entry.exists == false and style.dialog_danger or role_color(entry.role)
  common.draw_text(icon_font, icon_color, icon, "center", x + pad, y, icon_w, h)
  local tx = x + pad + icon_w + um.icon_gap
  local role = paths.role_label(entry.role)
  local role_w = font:get_width(role)
  local text_w = w - (tx - x) - pad
  local label_w = text_w - role_w - um.gap
  renderer.draw_text(font, ui.fit_text(font, entry.label or "", label_w), tx, top, style.dialog_text)
  renderer.draw_text(font, role, x + w - pad - role_w, top,
    state.selected and style.dialog_text or style.dialog_text_muted)
  local path = shown_path(entry.path)
  if entry.exists == false then path = "Not found: " .. path end
  renderer.draw_text(font, ui.fit_text(font, path, text_w, true), tx, top + line_h,
    entry.exists == false and style.dialog_danger or style.dialog_text_muted)
end

------------------------------------------------------------------------------------------------------------------
-- Module

local M = { Dialog = ProjectPathsDialog }

---Open the Dialog, or select in the open one.
---@param options? { select: string?, rename: boolean? }
function M.open(options)
  options = options or {}
  local open = require("core.ui.dialog").current()
  local instance = (open and open:is(ProjectPathsDialog)) and open or ProjectPathsDialog()
  instance:refresh(options.select)
  local entry = instance:selected_entry()
  local focus = options.rename and entry and entry.role ~= "root" and instance.label_field or instance.list
  instance:open(focus)
  instance:focus(focus)
  return instance
end

return M
