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
  context.original_execute = backend.execute
  context.original_definition = backend.read_definition
  backend.read_schema = function(_, callback)
    callback(schema)
    return { cancel = function() end }
  end
  backend.read_definition = function(_, object, callback)
    callback({ source = "CREATE TABLE [sales].[customers] (\n  [id] int NOT NULL PRIMARY KEY,\n  [name] nvarchar(80) NULL\n);",
      select = "SELECT [id], [name]\nFROM [sales].[customers];" })
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
    core.global_prompt_bar:exit(true)
    if context.original_backend then require("plugins.sql_server.backend").read_schema = context.original_backend end
    if context.original_execute then require("plugins.sql_server.backend").execute = context.original_execute end
    require("plugins.sql_server.backend").read_definition = context.original_definition
    if context.connection_id then require("plugins.sql_server").remove(context.connection_id) end
    local open = dialog.current()
    if open then open:close() end
    panes.reset_for_tests()
    if context.folder then test.ok(test.remove_tree(context.folder)) end
  end)

  test.it("opens an ordinary Untitled SQL Query before choosing a connection and keeps its choice through restore", function(context)
    local sql = require "plugins.sql_server"
    test.ok(command.perform("sql_server:new_query"))
    local editor = core.active_view
    test.ok(editor.buffer.intellij_untitled)
    test.equal(editor.buffer.syntax.name, "SQL")
    test.equal(sql.connection_for(editor.buffer), nil)
    test.ok(command.is_valid("sql_server:run_selection"))
    sql.load()
    local deadline = system.get_time() + 10
    while not sql.ready() and system.get_time() < deadline do coroutine.yield(0.01) end
    test.ok(sql.ready())
    local connection = sql.add_connection()
    test.ok(connection)
    context.connection_id = connection.id
    test.ok(sql.bind(editor.buffer, connection.id))
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

  test.it("chooses a connection when an ordinary SQL Editor first runs a selection", function(context)
    local _, c = connected_query(context)
    local sql = require "plugins.sql_server"
    sql.disconnect(c.id)
    local editor = sql.new_query()
    editor.buffer:text_input("SELECT 1")
    editor.buffer:set_selection(1, 1, 1, 9)
    local submitted
    require("plugins.sql_server.backend").execute = function(_, text, callback)
      submitted = text
      callback({ results = {}, affected_rows = {} })
      return { cancel = function() end }
    end
    test.ok(command.perform("sql_server:run_selection"))
    local deadline = system.get_time() + 10
    while core.active_view ~= core.global_prompt_bar and system.get_time() < deadline do coroutine.yield(0.01) end
    test.equal(core.active_view, core.global_prompt_bar)
    test.equal(submitted, nil)
    core.global_prompt_bar:submit()
    while not submitted and system.get_time() < deadline do coroutine.yield(0.01) end
    test.equal(submitted, "SELECT 1")
    test.equal(sql.connection_for(editor.buffer), c)
    test.equal(core.active_view, editor)
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

  test.it("runs selected SQL and shows a read-only result without taking focus", function(context)
    local editor = connected_query(context)
    local backend = require "plugins.sql_server.backend"
    local submitted, reply
    backend.execute = function(options, text, callback)
      test.equal(options.database, "AnvilTest")
      submitted, reply = text, callback
      return { cancel = function() end }
    end
    editor.buffer:text_input("-- not selected\nSELECT name FROM sales.customers\n-- not selected")
    editor.buffer:set_selection(2, 1, 2, #"SELECT name FROM sales.customers" + 1)
    test.ok(command.perform("sql_server:run_selection"))
    test.equal(submitted, "SELECT name FROM sales.customers")
    test.equal(core.active_view, editor)
    reply({ results = { {
      headers = { "name", "note" }, column_count = 2,
      rows = { { cells = { "Ada", false }, source_line1 = 1, source_line2 = 1 } },
      distinct_values = { { values = { "Ada" }, counts = { Ada = 1 } }, { values = { false }, counts = { [false] = 1 } } },
    } }, affected_rows = {} })
    local Results = require "plugins.sql_server.results"
    local result
    for _, pane in ipairs(panes.ordered()) do
      for _, view in ipairs(panes.views(pane)) do
        if view:extends(Results) then result = view end
      end
    end
    test.not_nil(result)
    test.equal(result:cell_value(1, 1), "Ada")
    test.equal(result:cell_value(1, 2), false)
    test.equal(result.buffer, nil)
    test.equal(result:get_state(), nil)
    test.equal(core.active_view, editor)
    test.equal(editor.buffer:get_text(1, 1, math.huge, math.huge), "-- not selected\nSELECT name FROM sales.customers\n-- not selected")
  end)

  test.it("runs nothing at a caret unless Run Buffer is explicit, and reuses its results", function(context)
    local editor = connected_query(context)
    local replies, submitted = {}, {}
    require("plugins.sql_server.backend").execute = function(_, text, callback)
      submitted[#submitted + 1], replies[#replies + 1] = text, callback
      return { cancel = function() end }
    end
    editor.buffer:text_input("SELECT name FROM sales.customers")
    test.ok(command.perform("sql_server:run_selection"))
    test.equal(#submitted, 0)
    test.equal(#panes.ordered(), 1)
    test.ok(command.perform("sql_server:run_buffer"))
    test.equal(submitted[1], "SELECT name FROM sales.customers")
    replies[1]({ results = {}, affected_rows = { "3" } })
    test.equal(core.active_view, editor)
    test.ok(command.perform("sql_server:run_buffer"))
    replies[2]({ error = "Test server refused the statement." })
    test.equal(editor.buffer:get_text(1, 1, math.huge, math.huge), "SELECT name FROM sales.customers")
    local count = 0
    for _, pane in ipairs(panes.ordered()) do
      for _, view in ipairs(panes.views(pane)) do
        if view:extends(require "plugins.sql_server.results") then
          count = count + 1
          test.equal(view.message, "Test server refused the statement.")
        end
      end
    end
    test.equal(count, 1)
  end)

  test.it("cancels a Query and rejects its late result after disconnect", function(context)
    local editor, c = connected_query(context)
    local reply, cancelled
    require("plugins.sql_server.backend").execute = function(_, _, callback)
      reply = callback
      return { cancel = function() cancelled = true end }
    end
    editor.buffer:text_input("SELECT name FROM sales.customers")
    test.ok(command.perform("sql_server:run_buffer"))
    test.ok(command.perform("sql_server:cancel"))
    test.ok(cancelled)
    require("plugins.sql_server").disconnect(c.id)
    reply({ error = "A late response must not replace cancellation." })
    local found
    for _, pane in ipairs(panes.ordered()) do
      for _, view in ipairs(panes.views(pane)) do
        if view:extends(require "plugins.sql_server.results") then
          found = true
          test.equal(#view.model.rows, 0)
          test.ok(view.message:find("cancelled", 1, true))
        end
      end
    end
    test.ok(found)
    test.not_ok(command.is_valid("sql_server:cancel"))
  end)

  test.it("closing a running result cancels it and does not reopen it for a late response", function(context)
    local editor = connected_query(context)
    local reply, cancelled
    require("plugins.sql_server.backend").execute = function(_, _, callback)
      reply = callback
      return { cancel = function() cancelled = true end }
    end
    editor.buffer:text_input("SELECT name FROM sales.customers")
    test.ok(command.perform("sql_server:run_buffer"))
    local result_pane
    for _, pane in ipairs(panes.ordered()) do
      for _, view in ipairs(panes.views(pane)) do
        if view:extends(require "plugins.sql_server.results") then result_pane = pane end
      end
    end
    test.ok(panes.close(test.not_nil(result_pane)))
    test.ok(cancelled)
    reply({ error = "Late response" })
    test.equal(#panes.ordered(), 1)
    test.equal(core.active_view, editor)
  end)

  test.it("shows every row of the next result without the previous result's filter", function()
    local Results = require "plugins.sql_server.results"
    local function model(names)
      local result = { headers = { "name" }, column_count = 1, rows = {} }
      for i, name in ipairs(names) do
        result.rows[i] = { cells = { name }, source_line1 = i, source_line2 = i }
      end
      result.distinct_values = require("plugins.tabular_data_preview.parser").distinct_values(result)
      return result
    end
    local view = Results("Test")
    panes.place(function() return view end, { placement = "new", focus = true })
    view:complete({ results = { model({ "Ada" }), model({ "Ada", "Bea" }) } })
    test.ok(view:toggle_filter_value(1, "Ada"))
    test.ok(command.perform("sql_server:next_result"))
    test.equal(view:row_count(), 2)
    test.equal(view:cell_value(2, 1), "Bea")
    test.ok(command.perform("sql_server:previous_result"))
    test.equal(view:row_count(), 1)
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
    test.ok(text:find("CREATE TABLE [sales].[customers]", 1, true))
    test.ok(text:find("SELECT [id], [name]", 1, true))
    test.equal(require("plugins.sql_server").connection_for(core.active_view.buffer),
      require("plugins.sql_server").connection_for(editor.buffer))
    test.ok(command.is_valid("sql_server:run_selection"))
    local definition = core.active_view
    local submitted
    require("plugins.sql_server.backend").execute = function(_, sql, done)
      submitted = sql
      done({ results = {}, affected_rows = {} })
      return { cancel = function() end }
    end
    for line, value in ipairs(definition.buffer.lines) do
      if value:match("^SELECT") then definition.buffer:set_selection(line, 1, line + 1, #definition.buffer.lines[line + 1]); break end
    end
    test.ok(command.perform("sql_server:run_selection"))
    test.equal(submitted, "SELECT [id], [name]\nFROM [sales].[customers];")
    test.equal(core.active_view, definition)
    test.equal(definition.buffer:get_text(1, 1, math.huge, math.huge), text)
    test.ok(command.perform("core:navigate_back"))
    test.equal(core.active_view, editor)
    test.equal(editor.buffer:get_text(1, 1, math.huge, math.huge), "SELECT * FROM sales.customers")
    test.ok(command.perform("sql_server:generate_select"))
    test.not_equal(core.active_view, editor)
    test.not_ok(core.active_view.buffer.read_only)
    test.equal(core.active_view.buffer:get_text(1, 1, math.huge, math.huge), "SELECT [id], [name]\nFROM [sales].[customers];")
    test.equal(require("plugins.sql_server").connection_for(core.active_view.buffer),
      require("plugins.sql_server").connection_for(editor.buffer))
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

  test.it("offers the selected connection only to an Editor that uses another connection", function(context)
    local editor, c = connected_query(context)
    local open = require("plugins.sql_server.dialog").open()
    test.equal(open:selected().id, c.id)
    test.not_ok(open.bind_button.visible)
    open:close()
    local other = require("core.editor")(core.open_buffer())
    panes.place(function() return other end, { placement = "new", focus = true })
    open = require("plugins.sql_server.dialog").open()
    open:refresh(c.id)
    test.ok(open.bind_button.visible)
    test.ok(open.bind_button:activate())
    test.equal(require("plugins.sql_server").connection_for(other.buffer).id, c.id)
    test.equal(editor.buffer.sql_connection_id, c.id)
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
    test.ok(#table.concat(text) > 0)
    open:close()
    test.equal(open.password:get_text(), "")
  end)
end)
