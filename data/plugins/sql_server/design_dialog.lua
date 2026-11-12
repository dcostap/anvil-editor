-- The Table Design Dialog. Its pages show a table's columns, primary key, foreign keys, indexes and check
-- constraints, as DbVisualizer's Create Table and Alter Table Dialogs do. Each change applies to the design
-- at once. Open Script opens the CREATE or ALTER script in a new SQL Query. Nothing runs the script: the
-- user reads it and runs it as other SQL. A design that the user closes stays until the next connect.
local core = require "core"
local common = require "core.common"
local style = require "core.style"
local ui = require "core.ui"
local layout = require "core.ui.layout"
local Dialog = require("core.ui.dialog").Dialog
local List = require "core.ui.list"
local Nav = require "core.ui.nav"
local Button = require "core.ui.button"
local TextField = require "core.ui.text_field"
local Switch = require "core.ui.switch"
local Select = require "core.ui.select"
local backend = require "plugins.sql_server.backend"
local model = require "plugins.sql_server.table_design"

local Column, Row, Group, Field, Text, Spacer = layout.Column, layout.Row, layout.Group, layout.Field, layout.Text,
  layout.Spacer
local M = {}

local TableDesign = Dialog:extend()
M.TableDesign = TableDesign

function TableDesign:__tostring() return "Table Design" end

local PAGES = {
  { id = "table", label = "Table", icon = ui.icons.table },
  { id = "columns", label = "Columns", icon = ui.icons.view_list },
  { id = "primary", label = "Primary Key", icon = ui.icons.key },
  { id = "foreign", label = "Foreign Keys", icon = ui.icons.link },
  { id = "indexes", label = "Indexes", icon = ui.icons.sort },
  { id = "checks", label = "Check Constraints", icon = ui.icons.check },
}

-- Designs that the user closed without a script: connection -> { generation, [table key] = design }.
local kept = setmetatable({}, { __mode = "k" })
local function kept_designs(c)
  local designs = kept[c]
  if not designs or designs.generation ~= c.generation then
    designs = { generation = c.generation }
    kept[c] = designs
  end
  return designs
end
local function design_key(design)
  return design.existing and (design.original.schema .. "\0" .. design.original.name) or "\0new"
end

local function row_height() return ui.metrics().control_h end

-- Draws text parts at fractions of a row: { { text, start, color }, ... }.
local function draw_parts(x, y, w, h, parts)
  local font, pad = ui.font(), ui.metrics().pad_x
  for i, part in ipairs(parts) do
    local left = x + pad + math.floor((w - 2 * pad) * part[2])
    local right = parts[i + 1] and x + pad + math.floor((w - 2 * pad) * parts[i + 1][2]) - pad or x + w - pad
    common.draw_text(font, part[3] or style.dialog_text, ui.fit_text(font, part[1], right - left), "left",
      left, y, right - left, h)
  end
end

local function check_row(x, y, h, checked)
  local size = math.floor(16 * SCALE + 0.5)
  local pad = ui.metrics().pad_x
  ui.draw_check_box(x + pad, y + math.floor((h - size) / 2), size, checked and 1 or 0)
  return pad + size
end

local function index_of(list, value)
  for i, v in ipairs(list) do if v == value then return i end end
end

function TableDesign:new(sql, c, design)
  local title = design.existing and ("Table Design — " .. design.original.schema .. "." .. design.original.name)
    or "New Table"
  TableDesign.super.new(self, { title = title, width = 860 })
  self.sql, self.connection, self.design = sql, c, design
  self.pages = {}
  self.nav = Nav { items = PAGES, width = 196, on_select = function(item) self:show_page(item.id) end }
  self.page_scroll = layout.Scroll { height = 470, grow = true, layout.Node {} }
  self:build_table_page()
  self:build_columns_page()
  self:build_primary_page()
  self:build_foreign_page()
  self:build_indexes_page()
  self:build_checks_page()
  self:set_body(Row { gap = 24, align = "start", self.nav, self.page_scroll })
  self.status = Text { role = "description", color = style.error }
  self.script_button = Button { label = "Open Script", kind = "primary", on_click = function() self:open_script() end }
  self.footer = Row { gap = 16, self.status, Spacer { grow = 1 }, self.script_button }
  self:show_page("columns")
  self:changed()
end

-- A Text Field that saves into the selected item of `selected()`. `check(text, item)` can refuse the text.
function TableDesign:item_field(selected, key, check, options)
  options = options or {}
  options.on_submit = function(text)
    local item = selected()
    if not item then return false end
    if check then
      local ok, message = check(text, item)
      if ok == false then return false, message end
    end
    item[key] = text
    self:changed()
  end
  return TextField(options)
end

local function required(what)
  return function(text)
    if text == "" then return false, "Type a " .. what .. "." end
    if text:find("[%z\r\n]") then return false, "Use one line." end
  end
end
local function one_line(text) if text:find("[%z\r\n]") then return false, "Use one line." end end

local function header(title, ...)
  return Row { Text { text = title, role = "meta", wrap = false }, Spacer { grow = 1 }, ... }
end

function TableDesign:build_table_page()
  local design = self.design
  local function table_item() return design end
  self.schema_field = self:item_field(table_item, "schema", required("schema"), { width = 320 })
  self.name_field = self:item_field(table_item, "name", required("table name"), { width = 320 })
  self.pages.table = Column {
    Group {
      Field { title = "Schema", control = self.schema_field },
      Field { title = "Table", control = self.name_field },
    },
  }
end

function TableDesign:selected_column() return self.columns:selected_row() end

function TableDesign:build_columns_page()
  local design = self.design
  local function in_key(column) return index_of(design.primary_key.columns, column.key) ~= nil end
  self.columns = List {
    row_height = row_height(), max_rows = 7, empty = "No columns",
    draw_row = function(column, x, y, w, h)
      -- The key mark has its own column before the names, so the names stay aligned.
      local icon_font = ui.icon_font()
      local mark = icon_font:get_width(ui.icons.key) + math.floor(6 * SCALE)
      if in_key(column) then
        common.draw_text(icon_font, style.dialog_text_muted, ui.icons.key, "left", x + ui.metrics().pad_x, y, mark, h)
      end
      x, w = x + mark, w - mark
      draw_parts(x, y, w, h, {
        { column.name, 0 },
        { column.computed and ("AS " .. column.computed) or column.type, 0.4, style.dialog_text_muted },
        { column.nullable and "NULL" or "NOT NULL", 0.78, style.dialog_text_muted },
      })
    end,
    on_select = function() self:show_column() end,
  }
  local selected = function() return self:selected_column() end
  self.column_name = self:item_field(selected, "name", function(text, column)
    local ok, message = required("column name")(text)
    if ok == false then return ok, message end
    for _, other in ipairs(design.columns) do
      if other ~= column and other.name:lower() == text:lower() then return false, "Another column has this name." end
    end
  end, { width = 320 })
  self.column_type = self:item_field(selected, "type", required("data type"), { width = 320, placeholder = "nvarchar(100)" })
  self.column_collation = self:item_field(selected, "collation", one_line, { width = 320, placeholder = "Default" })
  self.column_default = self:item_field(selected, "default", one_line, { width = 320, placeholder = "None" })
  self.column_nullable = Switch { on_change = function(value)
    local column = selected()
    if not column then return false end
    if value and in_key(column) then return false end
    column.nullable = value
    self:changed()
  end }
  self.column_identity = Switch { on_change = function(value)
    local column = selected()
    if not column then return false end
    for _, other in ipairs(design.columns) do if other ~= column and value then other.identity = false end end
    column.identity = value
    self:changed()
  end }
  self.computed_text = Text { role = "body" }
  self.computed_row = Field { title = "Computed", control = self.computed_text }
  self.add_column = Button { label = "Add", icon = ui.icons.add, size = "small", on_click = function()
    local column = { key = model.new_key(design), name = "column" .. (#design.columns + 1), type = "nvarchar(100)",
      collation = "", nullable = true, default = "" }
    design.columns[#design.columns + 1] = column
    self:changed()
    self.columns:select(#design.columns)
    self:show_column()
    self:focus(self.column_name)
  end }
  local function move(delta)
    local index = self.columns.selected
    local other = index and index + delta
    if not other or other < 1 or other > #design.columns then return end
    design.columns[index], design.columns[other] = design.columns[other], design.columns[index]
    self.columns.selected = other
    self:changed()
  end
  self.move_up = Button { icon = ui.icons.arrow_up, kind = "ghost", size = "small", tooltip = "Move Up",
    on_click = function() move(-1) end }
  self.move_down = Button { icon = ui.icons.arrow_down, kind = "ghost", size = "small", tooltip = "Move Down",
    on_click = function() move(1) end }
  self.remove_column = Button { label = "Remove", icon = ui.icons.remove, kind = "danger", size = "small",
    on_click = function()
      local column = selected()
      if column then model.remove(design, design.columns, column, "column"); self:changed(); self:show_column() end
    end }
  self.column_group = Group {
    Field { title = "Name", control = self.column_name },
    Field { title = "Data Type", control = self.column_type },
    Field { title = "Collation", control = self.column_collation },
    Field { title = "Nullable", control = self.column_nullable },
    Field { title = "Default", control = self.column_default },
    Field { title = "Identity", control = self.column_identity },
    self.computed_row,
  }
  self.pages.columns = Column {
    Column { gap = 8, header("Columns", self.add_column, self.move_up, self.move_down, self.remove_column), self.columns },
    self.column_group,
  }
end

function TableDesign:show_column()
  local column = self:selected_column()
  self.column_group.visible = column ~= nil
  self.remove_column.enabled = column ~= nil
  -- SQL Server adds a column at the end, so only a new table orders its columns.
  self.move_up.visible, self.move_down.visible = not self.design.existing, not self.design.existing
  if not column then return end
  local existing, locked = column.original ~= nil, column.locked
  self.column_name:set_text(column.name)
  self.column_type:set_text(column.type)
  self.column_collation:set_text(column.collation)
  self.column_default:set_text(column.default)
  self.column_nullable:set_value(column.nullable)
  self.column_identity:set_value(column.identity)
  for _, control in ipairs({ self.column_type, self.column_collation, self.column_default, self.column_nullable }) do
    control.enabled = not locked
  end
  -- SQL Server cannot add or remove the identity of an existing column.
  self.column_identity.enabled = not existing and not locked
  self.computed_row.visible = column.computed ~= nil
  self.computed_text:set_text(column.computed and ("AS " .. column.computed .. (column.persisted and " PERSISTED" or "")) or "")
end

-- A list of the design's columns with check boxes, for the keys and indexes. `item()` gives the key or
-- index; a click adds or removes the column. `suffix(column, position)` gives muted text after the name.
function TableDesign:column_checklist(item, on_toggle, suffix)
  return List {
    row_height = row_height(), max_rows = 7, click_activates = true, empty = "No columns",
    draw_row = function(column, x, y, w, h)
      local target = item()
      local position = target and index_of(target.columns, column.key)
      local left = check_row(x, y, h, position ~= nil)
      local parts = { { column.name, 0 } }
      local extra = suffix and suffix(column, position)
      if extra then parts[2] = { extra, 0.5, style.dialog_text_muted } end
      draw_parts(x + left, y, w - left, h, parts)
    end,
    on_activate = function(column)
      local target = item()
      if not target or target.locked then return end
      local position = index_of(target.columns, column.key)
      if position then table.remove(target.columns, position) else target.columns[#target.columns + 1] = column.key end
      if on_toggle then on_toggle(target, column, position == nil, position) end
      self:changed()
    end,
  }
end

function TableDesign:build_primary_page()
  local design = self.design
  local function primary() return design.primary_key end
  self.pk_name = self:item_field(primary, "name", required("constraint name"), { width = 320 })
  self.pk_columns = self:column_checklist(primary, function(_, column, added)
    -- A key column cannot be nullable.
    if added and not column.locked then column.nullable = false end
  end, function(_, position) return position and ("Key column " .. position) end)
  self.pages.primary = Column {
    Group { Field { title = "Constraint Name", control = self.pk_name } },
    Column { gap = 8, header("Columns"), self.pk_columns },
  }
end

-- The tables of the connection's catalog, and the columns of one of them.
function TableDesign:catalog_tables()
  local options, seen = {}, {}
  local catalog = self.connection.catalog
  for _, object in ipairs(catalog and catalog.objects or {}) do
    if object.kind == "table" then
      local value = object.schema .. "." .. object.name
      seen[value] = true
      options[#options + 1] = { value = value, label = value }
    end
  end
  for _, fk in ipairs(self.design.foreign_keys) do
    local value = fk.ref_table ~= "" and (fk.ref_schema .. "." .. fk.ref_table)
    if value and not seen[value] then seen[value] = true; options[#options + 1] = { value = value, label = value } end
  end
  return options
end

function TableDesign:catalog_object(schema, name)
  local catalog = self.connection.catalog
  for _, object in ipairs(catalog and catalog.objects or {}) do
    if object.kind == "table" and object.schema == schema and object.name == name then return object end
  end
end

-- The columns of a referenced table. A large database reads them on first use; the page then
-- shows them when they arrive.
function TableDesign:referenced_columns(object)
  if object.columns then return object.columns end
  self.sql.object_columns(self.connection, object, function()
    if self.is_open then self:show_fk() end
  end)
  return {}
end

-- The referenced column for a new pair: the next primary key column, or a column with the same name.
function TableDesign:reference_for(fk, column)
  local object = self:catalog_object(fk.ref_schema, fk.ref_table)
  if not object then return "" end
  local used = {}
  for _, name in ipairs(fk.ref_columns) do used[name] = true end
  local columns = self:referenced_columns(object)
  for _, ref in ipairs(columns) do if ref.primary_key and not used[ref.name] then return ref.name end end
  for _, ref in ipairs(columns) do if ref.name:lower() == column.name:lower() then return ref.name end end
  return ""
end

function TableDesign:selected_fk() return self.fks:selected_row() end

function TableDesign:build_foreign_page()
  local design = self.design
  local selected = function() return self:selected_fk() end
  self.fks = List {
    row_height = row_height(), max_rows = 4, empty = "No foreign keys",
    draw_row = function(fk, x, y, w, h)
      draw_parts(x, y, w, h, { { fk.name, 0 },
        { fk.ref_table ~= "" and ("→ " .. fk.ref_schema .. "." .. fk.ref_table) or "", 0.5, style.dialog_text_muted },
        { fk.locked and "Locked" or "", 0.85, style.dialog_text_muted } })
    end,
    on_select = function() self:show_fk() end,
  }
  self.fk_name = self:item_field(selected, "name", required("constraint name"), { width = 320 })
  self.fk_table = Select { width = 320, placeholder = "Choose a table", on_change = function(value)
    local fk = selected()
    if not fk or fk.locked then return false end
    fk.ref_schema, fk.ref_table = value:match("^(.-)%.(.*)$")
    for i, key in ipairs(fk.columns) do
      fk.ref_columns[i] = ""
      fk.ref_columns[i] = self:reference_for(fk, model.column(design, key))
    end
    self:changed()
  end }
  local function action_select(key)
    local options = {}
    for i, action in ipairs(model.ACTIONS) do options[i] = { value = action, label = action } end
    return Select { width = 200, options = options, on_change = function(value)
      local fk = selected()
      if not fk or fk.locked then return false end
      fk[key] = value
      self:changed()
    end }
  end
  self.fk_delete, self.fk_update = action_select("on_delete"), action_select("on_update")
  self.fk_columns = self:column_checklist(selected, function(fk, column, added, position)
    if added then fk.ref_columns[#fk.columns] = self:reference_for(fk, column)
    else table.remove(fk.ref_columns, position) end
  end, function(column, position)
    local fk = selected()
    return position and ("→ " .. (fk.ref_columns[position] ~= "" and fk.ref_columns[position] or "?"))
  end)
  self.fk_columns.on_select = function() self:show_fk_reference() end
  self.fk_reference = Select { width = 320, placeholder = "Choose a column", on_change = function(value)
    local fk, column = selected(), self.fk_columns:selected_row()
    local position = fk and column and index_of(fk.columns, column.key)
    if not position or fk.locked then return false end
    fk.ref_columns[position] = value
    self:changed()
  end }
  self.add_fk = Button { label = "Add", icon = ui.icons.add, size = "small", on_click = function()
    local fk = { key = model.new_key(design), name = "FK_" .. design.name .. "_" .. (#design.foreign_keys + 1),
      columns = {}, ref_columns = {}, ref_schema = "", ref_table = "", on_delete = "NO ACTION", on_update = "NO ACTION" }
    design.foreign_keys[#design.foreign_keys + 1] = fk
    self:changed()
    self.fks:select(#design.foreign_keys)
    self:show_fk()
    self:focus(self.fk_table)
  end }
  self.remove_fk = Button { label = "Remove", icon = ui.icons.remove, kind = "danger", size = "small", on_click = function()
    local fk = selected()
    if fk then model.remove(design, design.foreign_keys, fk, "foreign_key"); self:changed(); self:show_fk() end
  end }
  self.fk_detail = Column {
    Group {
      Field { title = "Constraint Name", control = self.fk_name },
      Field { title = "Referenced Table", control = self.fk_table },
      Field { title = "On Delete", control = self.fk_delete },
      Field { title = "On Update", control = self.fk_update },
    },
    Column { gap = 8, header("Columns"), self.fk_columns },
    Group { Field { title = "Referenced Column", control = self.fk_reference } },
  }
  self.pages.foreign = Column {
    Column { gap = 8, header("Foreign Keys", self.add_fk, self.remove_fk), self.fks },
    self.fk_detail,
  }
end

function TableDesign:show_fk()
  local fk = self:selected_fk()
  self.fk_detail.visible = fk ~= nil
  self.remove_fk.enabled = fk ~= nil
  if not fk then return end
  self.fk_name:set_text(fk.name)
  self.fk_table:set_options(self:catalog_tables(), fk.ref_table ~= "" and (fk.ref_schema .. "." .. fk.ref_table) or nil)
  self.fk_delete:set_value(fk.on_delete)
  self.fk_update:set_value(fk.on_update)
  for _, control in ipairs({ self.fk_table, self.fk_delete, self.fk_update, self.fk_columns, self.fk_reference }) do
    control.enabled = not fk.locked
  end
  self:show_fk_reference()
end

function TableDesign:show_fk_reference()
  local fk, column = self:selected_fk(), self.fk_columns:selected_row()
  local position = fk and column and index_of(fk.columns, column.key)
  local object = fk and self:catalog_object(fk.ref_schema, fk.ref_table)
  local options = {}
  for i, ref in ipairs(object and self:referenced_columns(object) or {}) do options[i] = { value = ref.name, label = ref.name } end
  if position and fk.ref_columns[position] ~= "" and not object then
    options[1] = { value = fk.ref_columns[position], label = fk.ref_columns[position] }
  end
  self.fk_reference:set_options(options, position and fk.ref_columns[position] ~= "" and fk.ref_columns[position] or nil)
  self.fk_reference.enabled = position ~= nil and not fk.locked
end

function TableDesign:selected_index() return self.indexes:selected_row() end

local INDEX_KINDS = { index = "Index", constraint = "Unique Constraint" }

function TableDesign:build_indexes_page()
  local design = self.design
  local selected = function() return self:selected_index() end
  self.indexes = List {
    row_height = row_height(), max_rows = 4, empty = "No indexes",
    draw_row = function(index, x, y, w, h)
      local kind = index.kind == "index" and index.unique and "Unique Index" or INDEX_KINDS[index.kind]
      draw_parts(x, y, w, h, { { index.name, 0 }, { kind, 0.5, style.dialog_text_muted },
        { index.locked and "Locked" or "", 0.85, style.dialog_text_muted } })
    end,
    on_select = function() self:show_index() end,
  }
  self.index_name = self:item_field(selected, "name", required("index name"), { width = 320 })
  self.index_unique = Switch { on_change = function(value)
    local index = selected()
    if not index or index.locked or index.kind == "constraint" then return false end
    index.unique = value
    self:changed()
  end }
  self.index_columns = self:column_checklist(selected, nil, function(_, position)
    return position and ("Key column " .. position)
  end)
  self.add_index = Button { label = "Add", icon = ui.icons.add, size = "small", on_click = function()
    local index = { key = model.new_key(design), name = "IX_" .. design.name .. "_" .. (#design.indexes + 1),
      kind = "index", unique = false, columns = {} }
    design.indexes[#design.indexes + 1] = index
    self:changed()
    self.indexes:select(#design.indexes)
    self:show_index()
    self:focus(self.index_name)
  end }
  self.remove_index = Button { label = "Remove", icon = ui.icons.remove, kind = "danger", size = "small", on_click = function()
    local index = selected()
    if index then model.remove(design, design.indexes, index, "index"); self:changed(); self:show_index() end
  end }
  self.index_detail = Column {
    Group {
      Field { title = "Name", control = self.index_name },
      Field { title = "Unique", control = self.index_unique },
    },
    Column { gap = 8, header("Columns"), self.index_columns },
  }
  self.pages.indexes = Column {
    Column { gap = 8, header("Indexes", self.add_index, self.remove_index), self.indexes },
    self.index_detail,
  }
end

function TableDesign:show_index()
  local index = self:selected_index()
  self.index_detail.visible = index ~= nil
  self.remove_index.enabled = index ~= nil
  if not index then return end
  self.index_name:set_text(index.name)
  self.index_unique:set_value(index.unique)
  self.index_unique.enabled = not index.locked and index.kind ~= "constraint"
  self.index_columns.enabled = not index.locked
end

function TableDesign:selected_check() return self.checks:selected_row() end

function TableDesign:build_checks_page()
  local design = self.design
  local selected = function() return self:selected_check() end
  self.checks = List {
    row_height = row_height(), max_rows = 5, empty = "No check constraints",
    draw_row = function(check, x, y, w, h)
      draw_parts(x, y, w, h, { { check.name, 0 }, { check.condition, 0.4, style.dialog_text_muted },
        { check.locked and "Locked" or "", 0.85, style.dialog_text_muted } })
    end,
    on_select = function() self:show_check() end,
  }
  self.check_name = self:item_field(selected, "name", required("constraint name"), { width = 320 })
  self.check_condition = self:item_field(selected, "condition", required("condition"), { placeholder = "amount >= 0" })
  self.add_check = Button { label = "Add", icon = ui.icons.add, size = "small", on_click = function()
    local check = { key = model.new_key(design), name = "CK_" .. design.name .. "_" .. (#design.checks + 1), condition = "" }
    design.checks[#design.checks + 1] = check
    self:changed()
    self.checks:select(#design.checks)
    self:show_check()
    self:focus(self.check_condition)
  end }
  self.remove_check = Button { label = "Remove", icon = ui.icons.remove, kind = "danger", size = "small", on_click = function()
    local check = selected()
    if check then model.remove(design, design.checks, check, "check"); self:changed(); self:show_check() end
  end }
  self.check_detail = Group {
    Field { title = "Constraint Name", control = self.check_name },
    Field { title = "Condition", stacked = true, control = self.check_condition },
  }
  self.pages.checks = Column {
    Column { gap = 8, header("Check Constraints", self.add_check, self.remove_check), self.checks },
    self.check_detail,
  }
end

function TableDesign:show_check()
  local check = self:selected_check()
  self.check_detail.visible = check ~= nil
  self.remove_check.enabled = check ~= nil
  if not check then return end
  self.check_name:set_text(check.name)
  self.check_condition:set_text(check.condition)
  self.check_condition.enabled = not check.locked
end

function TableDesign:show_page(id)
  self.page_id = id
  self.nav.selected = id
  self.page_scroll:set_child(self.pages[id])
  self.page_scroll:reset()
  core.log_quiet("Table Design page: %s", id)
  return true
end

-- Shows the design after a change: the lists, the selected items and the status.
function TableDesign:changed()
  local design = self.design
  self.name_field:set_text(design.name)
  self.schema_field:set_text(design.schema)
  self.columns:set_rows(design.columns, self.columns.selected)
  self.pk_name:set_text(design.primary_key.name)
  self.pk_columns:set_rows(design.columns, self.pk_columns.selected)
  self.fks:set_rows(design.foreign_keys, self.fks.selected)
  self.fk_columns:set_rows(design.columns, self.fk_columns.selected)
  self.indexes:set_rows(design.indexes, self.indexes.selected)
  self.index_columns:set_rows(design.columns, self.index_columns.selected)
  self.checks:set_rows(design.checks, self.checks.selected)
  self:show_column()
  self:show_fk()
  self:show_index()
  self:show_check()
  local script, problems = model.script(design)
  self.script = script
  if problems then
    self.status:set_text(problems[1] .. (#problems > 1 and string.format(" (%d more)", #problems - 1) or ""))
  else
    self.status:set_text(script and "" or "No changes")
  end
  self.status.color = problems and style.error or style.dialog_text_muted
  self.script_button.enabled = script ~= nil
  core.redraw = true
end

function TableDesign:open_script()
  if not self.script then return false end
  local editor = self.sql.new_query(self.connection.id)
  if not editor then return false end
  kept_designs(self.connection)[design_key(self.design)] = nil
  self.opened_script = true
  self:close()
  editor.buffer:text_input(self.script)
  editor.buffer:set_selection(1, 1)
  core.log_quiet("SQL Server: Table Design script for %s table=%s", self.connection.id,
    self.design.existing and "existing" or "new")
  return true
end

function TableDesign:on_close()
  if not self.opened_script then kept_designs(self.connection)[design_key(self.design)] = self.design end
end

local function open_design(sql, c, design)
  local instance = TableDesign(sql, c, design)
  instance:open(instance.nav)
  return instance
end

-- Opens the design of the table at the caret, or of `object`. The catalog read uses its own session, so
-- the Query's transaction and settings do not change.
local function open_table(sql, c, object, alive)
  local designs = kept_designs(c)
  local key = object.schema .. "\0" .. object.name
  if designs[key] then open_design(sql, c, designs[key]); return true end
  local generation = c.generation
  local handle, err = backend.execute(sql.connection_options(c), model.read_sql(object.schema, object.name),
    function(data)
      if data.session then backend.close_session(data.session) end
      if c.generation ~= generation or not alive() then return end
      local design, reason = model.from_results(object.schema, object.name, data)
      core.log_quiet("SQL Server: Table Design read connection=%s ok=%s", c.id, tostring(design ~= nil))
      if not design then core.warn("%s", reason); return end
      open_design(sql, c, design)
    end, { max_rows = 4096 })
  if not handle then core.warn("%s", err or "Could not read the table."); return false end
  return true
end

-- `from` is a SQL Editor, which designs the table at its caret, or a Ready
-- connection from Project Symbol Search.
function M.open(sql, from, object)
  if sql.find(from.id) == from then
    local view = core.active_view
    return open_table(sql, from, object, function() return core.active_view == view end)
  end
  local view = from
  return sql.with_connection(view, function(c)
    object = object or require("plugins.sql_server.intelligence").object_at(view, sql)
    if not object or object.kind ~= "table" or object.local_source then
      core.warn("Table Design needs a table of the database at the caret."); return false
    end
    return open_table(sql, c, object, function() return not view.closed and core.active_view == view end)
  end)
end

-- Opens the design of a new table, or the new table design that the user closed.
function M.new_table(sql, view)
  return sql.with_connection(view, function(c)
    local designs = kept_designs(c)
    local schema = c.catalog and c.catalog.default_schema ~= "" and c.catalog.default_schema or "dbo"
    designs["\0new"] = designs["\0new"] or model.new_table(schema, "new_table")
    open_design(sql, c, designs["\0new"])
    return true
  end)
end

return M
