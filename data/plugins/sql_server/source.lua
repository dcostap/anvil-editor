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

local function read(sql, view, object, done)
  return sql.with_connection(view, function(c)
    object = object or require("plugins.sql_server.intelligence").object_at(view, sql)
    if not object then core.warn("No database symbol at the caret."); return false end
    local buffer, generation, revision = view.buffer, c.generation, view.buffer.text_revision
    local l1, c1, l2, c2 = buffer:get_selection()
    local request = {}
    if view.sql_definition_request then view.sql_definition_request:cancel() end
    view.sql_definition_request = request
    local function finish(scripts, err)
      if view.sql_definition_request ~= request then return end
      request.finished = true
      view:remove_owned_feature("sql-definition", "finished")
      local a, b, d, e = buffer:get_selection()
      if view.closed or core.active_view ~= view or not panes.pane_for_view(view) or buffer.text_revision ~= revision
          or sql.connection_for(buffer) ~= c or c.generation ~= generation or a ~= l1 or b ~= c1 or d ~= l2 or e ~= c2 then return end
      if not scripts then core.error("%s", err or "Could not read SQL definition."); return end
      core.log_quiet("SQL definition: %s.%s connection=%s", object.schema, object.name, c.id)
      done(c, object, scripts)
    end
    function request:cancel()
      view:remove_owned_feature("sql-definition", "cancelled")
    end
    function request:on_release()
      pending[self] = nil
      if self.handle and not self.finished then self.handle:cancel() end
      if view.sql_definition_request == self then view.sql_definition_request = nil end
    end
    view:add_owned_feature("sql-definition", request)
    pending[request] = c
    local handle, err = backend.read_definition(sql.connection_options(c), object, finish)
    request.handle = handle
    if not handle then finish(nil, err) end
    return true
  end)
end

function M.open(sql, view, object, opts)
  return read(sql, view, object, function(c, target, scripts)
    local buffer = Buffer()
    buffer.display_name = target.schema .. "." .. target.name
    buffer:insert(1, 1, scripts.source .. (scripts.select and ("\n\n-- Query\n" .. scripts.select) or ""))
    buffer:clear_undo_redo()
    buffer:clean()
    sql.bind(buffer, c.id)
    buffer.read_only, buffer.read_only_reason = true, "Database definitions are read-only. Generate a script to edit."
    local definition = Definition(buffer)
    if opts and opts.placement then panes.place(function() return definition end, opts)
    else
      local pane, err = panes.present(definition, { focus = true })
      if not pane then definition:on_close(); core.warn("%s", err) end
    end
  end)
end

-- A generated SELECT runs at once, so its rows show below it.
function M.generate(sql, view, action, object)
  return read(sql, view, object, function(c, target, scripts)
    local text = scripts[action]
    if not text then core.warn("This symbol does not support Script as %s.", action:upper()); return end
    local editor = sql.new_query(c.id)
    editor.buffer:text_input(text)
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

function M.action_items(view, object)
  local icons = require("core.context_menu").icons
  local items = {}
  for _, action in ipairs(ACTIONS[object.kind] or ACTIONS["function"]) do
    items[#items + 1] = { label = LABELS[action], icon = action == "source" and icons.definition or icons.source,
      command = COMMANDS[action] or "sql_server:script_object", args = { view, object, action } }
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
