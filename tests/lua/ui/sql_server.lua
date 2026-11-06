local test = require "core.test"
local core = require "core"
local command = require "core.command"
local panes = require "core.panes"
local dialog = require "core.ui.dialog"
local autocomplete = require "plugins.autocomplete"

local schema = {
  database = "AnvilTest", default_schema = "dbo", case_sensitive = false,
  tables = {
    { schema = "sales", name = "customers", columns = {
      { name = "id", type = "int", nullable = false, primary_key = true },
      { name = "name", type = "nvarchar(80)", nullable = true },
    } },
    { schema = "dbo", name = "orders", columns = {
      { name = "customer_id", type = "int", nullable = false },
    } },
  },
}
local function connected_query(context)
  local sql = require "plugins.sql_server"
  local backend = require "plugins.sql_server.backend"
  context.original_backend = backend.read_schema
  backend.read_schema = function(_, callback)
    callback(schema)
    return { cancel = function() end }
  end
  sql.load()
  local deadline = system.get_time() + 10
  while not sql.ready() and system.get_time() < deadline do coroutine.yield(0.01) end
  test.ok(sql.ready())
  local c = test.not_nil(sql.add_connection())
  context.connection_id = c.id
  sql.update(c.id, "server", "test-only.invalid")
  sql.update(c.id, "database", "AnvilTest")
  test.ok(sql.connect(c.id))
  return sql.new_query(c.id), c
end

test.describe("SQL Queries", function()
  test.after_each(function(context)
    autocomplete.close()
    if context.original_backend then require("plugins.sql_server.backend").read_schema = context.original_backend end
    if context.connection_id then require("plugins.sql_server").remove(context.connection_id) end
    local open = dialog.current()
    if open then open:close() end
    panes.reset_for_tests()
    if context.folder then test.ok(test.remove_tree(context.folder)) end
  end)

  test.it("opens a persistent Untitled SQL Query from the Databases Dialog", function(context)
    local sql = require "plugins.sql_server"
    test.ok(command.perform("sql_server:manage"))
    local open = test.not_nil(dialog.current())
    test.equal(open.title, "Databases")
    local deadline = system.get_time() + 10
    while not sql.ready() and system.get_time() < deadline do coroutine.yield(0.01) end
    test.ok(sql.ready())
    local connection = sql.add_connection()
    test.ok(connection)
    context.connection_id = connection.id
    open:refresh(connection.id)
    test.ok(open.query_button:activate())
    local editor = core.active_view
    test.ok(editor.buffer.intellij_untitled)
    test.equal(editor.buffer.language_mode_override, "SQL")
    test.equal(sql.connection_for(editor.buffer).id, connection.id)
    editor.buffer:text_input("SELECT id FROM dbo.customers")
    local state = editor:get_state()
    local restored = require("core.editor").from_state(state)
    test.equal(sql.connection_for(restored.buffer).id, connection.id)
    test.equal(restored.buffer:get_text(1, 1, math.huge, math.huge), "SELECT id FROM dbo.customers")
    restored:on_close()
    context.folder = USERDIR .. PATHSEP .. "sql-server-save-test"
    test.ok(system.mkdir(context.folder))
    local path = context.folder .. PATHSEP .. "query.sql"
    editor.buffer:save(path, path)
    test.equal(sql.connection_for(editor.buffer).id, connection.id)
    local saved = require("core.editor").from_state(editor:get_state())
    test.equal(saved.buffer.abs_filename, path)
    test.equal(sql.connection_for(saved.buffer).id, connection.id)
    saved:on_close()
  end)

  test.it("keeps the connection in Untitled recovery without a Workspace snapshot", function(context)
    local editor, c = connected_query(context)
    editor.buffer:text_input("SELECT * FROM sales.customers")
    local recovery = require "plugins.untitled_recovery"
    test.ok(recovery.flush_buffer(editor.buffer, "SQL recovery test", true))
    local state = recovery.state_for_buffer(editor.buffer)
    local buffer = core.open_buffer()
    recovery.attach_from_workspace_state(buffer, state)
    test.equal(require("plugins.sql_server").connection_for(buffer).id, c.id)
    test.equal(buffer:get_text(1, 1, math.huge, math.huge), "SELECT * FROM sales.customers")
  end)

  test.it("completes a column through the normal popup using the table alias", function(context)
    local editor = connected_query(context)
    editor.buffer:text_input("SELECT c.na FROM sales.customers AS c")
    editor.buffer:set_selection(1, #"SELECT c.na" + 1)
    autocomplete.trigger()
    test.ok(autocomplete.is_open())
    test.equal(autocomplete.get_selected_suggestion().text, "name")
    test.ok(command.perform("autocomplete:complete"))
    test.equal(editor.buffer:get_text(1, 1, math.huge, math.huge), "SELECT c.name FROM sales.customers AS c")
  end)

  test.it("opens a table definition and returns to the same Untitled Query", function(context)
    local editor = connected_query(context)
    editor.buffer:text_input("SELECT * FROM sales.customers")
    editor.buffer:set_selection(1, #"SELECT * FROM sales.customers" + 1)
    test.ok(require("core.commands.language").activate_symbol(editor))
    test.not_equal(core.active_view, editor)
    test.ok(core.active_view.buffer.read_only)
    local text = core.active_view.buffer:get_text(1, 1, math.huge, math.huge)
    test.ok(text:find("nvarchar(80)", 1, true))
    test.ok(command.perform("core:navigate_back"))
    test.equal(core.active_view, editor)
    test.equal(editor.buffer:get_text(1, 1, math.huge, math.huge), "SELECT * FROM sales.customers")
  end)

  test.it("does not navigate an unknown column to an unrelated table", function(context)
    local editor = connected_query(context)
    editor.buffer:text_input("SELECT missing FROM sales.customers")
    editor.buffer:set_selection(1, #"SELECT missing" + 1)
    test.not_ok(require("core.commands.language").activate_symbol(editor))
    test.equal(core.active_view, editor)
  end)

  test.it("ignores metadata received after disconnect and never saves a password", function(context)
    local editor, c = connected_query(context)
    local sql = require "plugins.sql_server"
    local backend = require "plugins.sql_server.backend"
    local reply
    backend.read_schema = function(_, callback)
      reply = callback
      return { cancel = function() end }
    end
    test.ok(sql.connect(c.id, "test-password-not-for-storage"))
    sql.disconnect(c.id)
    reply(schema)
    editor.buffer:text_input("SELECT c.na FROM sales.customers c")
    editor.buffer:set_selection(1, #"SELECT c.na" + 1)
    autocomplete.trigger()
    test.not_ok(autocomplete.is_open())
    local deadline = system.get_time() + 10
    while sql.is_saving() and system.get_time() < deadline do coroutine.yield(0.01) end
    test.not_ok(sql.is_saving())
    local key = require("plugins.untitled_recovery").project_key(require("core.machine_project").root_key(core.root_project().path))
    local saved = test.not_nil(require("core.storage").load("sql_server", key))
    test.not_ok(require("core.common").serialize(saved):find("test-password-not-for-storage", 1, true))
  end)

  test.it("edits connection settings through the Dialog and masks the password", function(context)
    local _, c = connected_query(context)
    local open = require("plugins.sql_server.dialog").open()
    open:refresh(c.id)
    open:focus(open.fields.server)
    open:on_modal_text_input("another-test.invalid")
    test.ok(open.fields.server:submit())
    test.equal(c.server, "another-test.invalid")
    test.equal(c.state, "Disconnected")
    test.ok(open.auth:choose("sql"))
    open.password:set_text("secret-é")
    dialog.update()
    local saved = { renderer.draw_text, renderer.draw_rect, renderer.draw_rounded_rect, core.push_clip_rect, core.pop_clip_rect }
    local text = {}
    renderer.draw_text = function(font, value)
      text[#text + 1] = value
      return font:get_width(value)
    end
    renderer.draw_rect, renderer.draw_rounded_rect = function() end, function() end
    core.push_clip_rect, core.pop_clip_rect = function() end, function() end
    local ok, err = pcall(function() open.password:draw(true) end)
    renderer.draw_text, renderer.draw_rect, renderer.draw_rounded_rect, core.push_clip_rect, core.pop_clip_rect = unpack(saved)
    test.ok(ok, err)
    test.not_ok(table.concat(text):find("secret", 1, true))
    test.ok(table.concat(text):find("*", 1, true))
    open:close()
    test.equal(open.password:get_text(), "")
  end)
end)
