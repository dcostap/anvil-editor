-- Database source uses ordinary SQL Editors and normal Pane navigation.
local core = require "core"
local panes = require "core.panes"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local backend = require "plugins.sql_server.backend"
local Definition = Editor:extend()
function Definition:get_state() return nil end
function Definition:can_suspend() return true end
local M = {}
local pending = {}
function M.cancel_connection(connection)
  for request, owner in pairs(pending) do if owner == connection then request:cancel() end end
end

-- Reads an object's scripts on a worker. The owner keeps one request; a View
-- owner ends it when the View closes. `alive` tells if the reply still applies.
local searched = {}
local function read_object(sql, c, object, owner, alive, done, failed)
  local generation, request = c.generation, {}
  if owner.sql_definition_request then owner.sql_definition_request:cancel() end
  owner.sql_definition_request = request
  local function release()
    pending[request] = nil
    if request.handle and not request.finished then request.handle:cancel() end
    if owner.sql_definition_request == request then owner.sql_definition_request = nil end
  end
  local function finish(scripts, err)
    if owner.sql_definition_request ~= request then return end
    request.finished = true
    if owner.remove_owned_feature then owner:remove_owned_feature("sql-definition", "finished") else release() end
    if not alive() or sql.find(c.id) ~= c or c.generation ~= generation then return end
    if not scripts then
      if failed then failed(err or "Could not read SQL definition.") else core.error("%s", err or "Could not read SQL definition.") end
      return
    end
    core.log_quiet("SQL definition: %s.%s connection=%s", object.schema, object.name, c.id)
    done(c, object, scripts)
  end
  if owner.add_owned_feature then
    function request:cancel() owner:remove_owned_feature("sql-definition", "cancelled") end
    request.on_release = release
    owner:add_owned_feature("sql-definition", request)
  else
    request.cancel = release
  end
  pending[request] = c
  local handle, err = backend.read_definition(sql.object_options(c, object), object, finish)
  request.handle = handle
  if not handle then finish(nil, err) end
  return true
end

-- `from` is a SQL Editor, which acts on the object at its caret, or a Ready
-- connection from Project Symbol Search.
local function read(sql, from, object, done)
  if sql.find(from.id) == from then
    return read_object(sql, from, object, searched, function() return true end, done)
  end
  local view = from
  return sql.with_connection(view, function(c)
    object = object or require("plugins.sql_server.intelligence").object_at(view, sql)
    if not object then core.warn("No database symbol at the caret."); return false end
    local buffer, revision = view.buffer, view.buffer.text_revision
    local l1, c1, l2, c2 = buffer:get_selection()
    return read_object(sql, c, object, view, function()
      local a, b, d, e = buffer:get_selection()
      return not (view.closed or core.active_view ~= view or not panes.pane_for_view(view) or buffer.text_revision ~= revision
        or sql.connection_for(buffer) ~= c or a ~= l1 or b ~= c1 or d ~= l2 or e ~= c2)
    end, done)
  end)
end

local function definition_text(sql, c, target, scripts)
  return sql.in_database(c, target.database, scripts.source .. (scripts.select and ("\n\n-- Query\n" .. scripts.select) or ""))
end

-- The line and the columns of a column's name in a table's definition.
function M.column_position(text, column)
  local quoted = "[" .. column:gsub("%]", "]]") .. "]"
  local line = 0
  for row in (text .. "\n"):gmatch("([^\n]*)\n") do
    line = line + 1
    local first = row:find(quoted, 1, true)
    if first and row:sub(1, first - 1):match("^%s*$") then return line, first, first + #quoted end
  end
end

-- The definition of an object for a search preview, or nil while Anvil reads it. Each text stays while its catalog
-- stays, and one read runs at a time. A failed read gives `nil, error`.
local previews = setmetatable({}, { __mode = "k" })
local previewing = {}
function M.preview(sql, c, object)
  local catalog = sql.object_catalog(c, object)
  if not catalog or sql.find(c.id) ~= c or c.state ~= "Ready" then return nil, "The connection is not ready." end
  local texts = previews[catalog] or {}
  previews[catalog] = texts
  local text = texts[object]
  if text then return text end
  if previewing.object == object then
    if previewing.error then return nil, previewing.error end
    if previewing.sql_definition_request then return nil end
  end
  previewing.object, previewing.error = object, nil
  read_object(sql, c, object, previewing, function() return previewing.object == object end, function(_, target, scripts)
    texts[target] = definition_text(sql, c, target, scripts)
    core.redraw = true
  end, function(err)
    previewing.error = err
    core.redraw = true
  end)
end

-- `opts.line` and `opts.col` place the caret.
function M.open(sql, from, object, opts)
  return read(sql, from, object, function(c, target, scripts)
    local buffer = Buffer()
    buffer.display_name = target.schema .. "." .. target.name
    buffer:insert(1, 1, definition_text(sql, c, target, scripts))
    buffer:clear_undo_redo()
    buffer:clean()
    sql.bind(buffer, c.id)
    buffer.read_only, buffer.read_only_reason = true, "Database definitions are read-only. Generate a script to edit."
    local line = opts and opts.line
    if line then buffer:set_selection(line, opts.col or 1) end
    local definition = Definition(buffer)
    if opts and opts.placement then panes.place(function() return definition end, opts)
    else
      local pane, err = panes.present(definition, { focus = true })
      if not pane then definition:on_close(); core.warn("%s", err); return end
    end
    if line then definition:scroll_to_line(line, true, true) end
  end)
end

-- A generated SELECT runs at once, so its rows show below it.
function M.generate(sql, from, action, object)
  return read(sql, from, object, function(c, target, scripts)
    local text = scripts[action]
    if not text then core.warn("This symbol does not support Script as %s.", action:upper()); return end
    local editor = sql.new_query(c.id)
    editor.buffer:text_input(sql.in_database(c, target.database, text))
    editor.buffer:set_selection(1, 1)
    core.log_quiet("SQL script: %s for %s.%s", action, target.schema, target.name)
    if action == "select" and require("core.config").plugins.sql_server.run_generated_select then
      sql.run(editor, { whole_buffer = true })
    end
  end)
end

-- Actions for each object kind. The first is the default, so a keyboard-opened
-- menu selects it: SELECT for tables, ALTER for views and modules.
local ACTIONS = {
  table = { "select", "design", "source", "insert", "update", "delete", "create" },
  view = { "alter", "select", "source", "create" },
  procedure = { "alter", "source", "create" },
  ["function"] = { "alter", "source", "create" },
}
local LABELS = { select = "Script as SELECT", insert = "Script as INSERT", update = "Script as UPDATE",
  delete = "Script as DELETE", create = "Script as CREATE", alter = "Script as ALTER",
  design = "Table Design", source = "Open Definition" }
local COMMANDS = { design = "sql_server:table_design", source = "sql_server:open_object" }

function M.action_items(from, object)
  local icons = require("core.context_menu").icons
  local items = {}
  for _, action in ipairs(ACTIONS[object.kind] or ACTIONS["function"]) do
    items[#items + 1] = { label = LABELS[action], icon = action == "source" and icons.definition or icons.source,
      command = COMMANDS[action] or "sql_server:script_object", args = { from, object, action } }
  end
  return items
end

-- Opens the actions of the database symbol at the caret below the caret.
function M.symbol_actions(sql, view)
  return sql.with_connection(view, function()
    local object = require("plugins.sql_server.intelligence").object_at(view, sql)
    if not object then core.warn("No database symbol at the caret."); return false end
    local x, y = view:context_menu_point()
    return require("core.context_menu").open(x, y, M.action_items(view, object), {})
  end)
end

return M
