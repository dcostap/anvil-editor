local test = require "core.test"
local core = require "core"
local command = require "core.command"
local panes = require "core.panes"
local dialog = require "core.ui.dialog"
local autocomplete = require "plugins.autocomplete"

local schema = {
  database = "AnvilTest", default_schema = "dbo", case_sensitive = false,
  objects = {
    { schema = "sales", name = "customers", kind = "table", columns = {
      { name = "id", type = "int", nullable = false, primary_key = true },
      { name = "name", type = "nvarchar(80)", nullable = true },
    } },
    { schema = "dbo", name = "orders", kind = "table", columns = {
      { name = "customer_id", type = "int", nullable = false },
    } },
  },
  foreign_keys = {
    { name = "FK_orders_customers", schema = "dbo", table = "orders", columns = { "customer_id" },
      ref_schema = "sales", ref_table = "customers", ref_columns = { "id" } },
  },
}
local function picker_row(label)
  local picker = core.fuzzy_searcher_active_view
  if not picker or picker.closed or picker.closing then return end
  for index, result in ipairs(picker.results) do
    if result.label == label and not result.header then return picker, index end
  end
end
-- Opens a search with `open_command`, or uses the open one, and types `text` until a row named `label` shows.
local function search_until(open_command, text, label)
  if open_command then test.ok(command.perform(open_command)) end
  local deadline = system.get_time() + 10
  while system.get_time() < deadline and not picker_row(label) do
    local picker = core.fuzzy_searcher_active_view
    if picker and not picker.closed and not picker.closing and picker.input:get_text() ~= text then
      picker.input:set_text(text); picker:update()
    end
    coroutine.yield(0.01)
  end
  return picker_row(label)
end
local function wait_preview(picker)
  local deadline = system.get_time() + 10
  while system.get_time() < deadline and not picker:update_preview_view() do coroutine.yield(0.01) end
  return test.not_nil(picker:update_preview_view())
end
local function connected_query(context, catalog)
  local sql = require "plugins.sql_server"
  local backend = require "plugins.sql_server.backend"
  context.original_backend = backend.read_schema
  context.original_execute = backend.execute
  context.original_definition = backend.read_definition
  context.original_columns = backend.read_columns
  backend.read_schema = function(_, callback)
    callback(catalog or schema)
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
    if context.original_end then require("plugins.sql_server.backend").end_transaction = context.original_end end
    if context.original_close then require("plugins.sql_server.backend").close_session = context.original_close end
    if context.nag_show then core.nag_view.show = context.nag_show end
    if context.original_warn then core.warn = context.original_warn end
    if context.original_time then system.get_time = context.original_time end
    require("plugins.sql_server.backend").read_definition = context.original_definition
    if context.original_columns then require("plugins.sql_server.backend").read_columns = context.original_columns end
    if context.connection_id then require("plugins.sql_server").remove(context.connection_id) end
    if context.second_connection_id then require("plugins.sql_server").remove(context.second_connection_id) end
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

  test.it("uses the Project's only connection without asking, and asks when the Project has more", function(context)
    local _, c = connected_query(context)
    local sql = require "plugins.sql_server"
    local editor = sql.new_query()
    editor.buffer:text_input("SELECT c.na FROM sales.customers AS c")
    editor.buffer:set_selection(1, #"SELECT c.na" + 1)
    autocomplete.trigger()
    test.ok(autocomplete.is_open())
    test.equal(autocomplete.get_selected_suggestion().text, "name")
    autocomplete.close()

    sql.disconnect(c.id)
    editor = sql.new_query()
    editor.buffer:text_input("SELECT 1")
    editor.buffer:set_selection(1, 1, 1, 9)
    local submitted, asked
    require("plugins.sql_server.backend").execute = function(_, text, callback)
      submitted = text
      callback({ results = {}, affected_rows = {} })
      return { cancel = function() end }
    end
    test.ok(command.perform("sql_server:run_selection"))
    local deadline = system.get_time() + 10
    while not submitted and system.get_time() < deadline do
      asked = asked or core.active_view == core.global_prompt_bar
      coroutine.yield(0.01)
    end
    test.equal(submitted, "SELECT 1")
    test.not_ok(asked)
    test.equal(core.active_view, editor)

    local second = test.not_nil(sql.add_connection())
    context.second_connection_id = second.id
    test.equal(sql.connection_for(editor.buffer), c)
    local other = sql.new_query()
    test.equal(sql.connection_for(other.buffer), nil)
    other.buffer:text_input("SELECT 2")
    other.buffer:set_selection(1, 1, 1, 9)
    submitted = nil
    test.ok(command.perform("sql_server:run_selection"))
    while core.active_view ~= core.global_prompt_bar and system.get_time() < deadline do coroutine.yield(0.01) end
    test.equal(core.active_view, core.global_prompt_bar)
    test.equal(submitted, nil)
  end)

  test.it("connects the Project's connections when it opens and asks once for a SQL login's password", function(context)
    local _, c = connected_query(context)
    local sql = require "plugins.sql_server"
    local passwords = {}
    require("plugins.sql_server.backend").read_schema = function(options, callback)
      passwords[#passwords + 1] = options.password or "none"
      callback(schema)
      return { cancel = function() end }
    end
    local login = test.not_nil(sql.add_connection())
    context.second_connection_id = login.id
    test.ok(sql.update(login.id, "name", "Login Connection"))
    test.ok(sql.update(login.id, "server", "login-test.invalid"))
    test.ok(sql.update(login.id, "database", "AnvilTest"))
    test.ok(sql.update(login.id, "user", "tester"))
    test.ok(sql.update(login.id, "integrated", false))
    sql.disconnect(c.id)
    sql.connect_on_open()
    local deadline = system.get_time() + 10
    while not dialog.current() and system.get_time() < deadline do coroutine.yield(0.01) end
    local card = test.not_nil(dialog.current())
    test.equal(card.title, "Login Connection")
    test.equal(c.state, "Ready")
    test.equal(login.state, "Disconnected")
    card:on_modal_text_input("pw-test")
    test.ok(card:confirm())
    test.equal(dialog.current(), nil)
    test.equal(login.state, "Ready")
    test.same(passwords, { "none", "pw-test" })
  end)

  test.it("completes a column through the normal popup using the table alias, and in an UPDATE", function(context)
    local editor = connected_query(context)
    editor.buffer:text_input("SELECT c.na FROM sales.customers AS c")
    editor.buffer:set_selection(1, #"SELECT c.na" + 1)
    autocomplete.trigger()
    test.ok(autocomplete.is_open())
    test.equal(autocomplete.get_selected_suggestion().text, "name")
    test.ok(command.perform("autocomplete:complete"))
    test.equal(editor.buffer:get_text(1, 1, math.huge, math.huge), "SELECT c.name FROM sales.customers AS c")
    editor.buffer:insert(2, 1, "\nUPDATE sales.customers SET na")
    editor.buffer:set_selection(2, math.huge)
    autocomplete.trigger()
    test.ok(autocomplete.is_open())
    test.equal(autocomplete.get_selected_suggestion().text, "name")
  end)

  test.it("opens columns where a name belongs, waits for a typed name at a value, and offers keywords after a term", function(context)
    local editor = connected_query(context)
    local function type_text(text)
      for char in text:gmatch(".") do core.on_event("textinput", char) end
    end
    local function line() return editor.buffer.lines[1]:gsub("\n$", "") end
    type_text("SELECT * FROM sales.customers WHERE ")
    test.ok(autocomplete.is_open())
    autocomplete.close()
    type_text("email ")
    test.not_ok(autocomplete.is_open())
    autocomplete.trigger()
    test.ok(autocomplete.is_open())
    test.equal(autocomplete.get_selected_suggestion().text, "AND")
    autocomplete.close()
    type_text("l")
    test.equal(autocomplete.get_selected_suggestion().text, "LIKE")
    test.ok(command.perform("autocomplete:complete"))
    test.equal(line(), "SELECT * FROM sales.customers WHERE email LIKE")
    type_text(" 'a%' ")
    test.not_ok(autocomplete.is_open())
    type_text("or")
    test.equal(autocomplete.get_selected_suggestion().text, "ORDER BY")

    -- A typed word after a table can be its alias, so keywords wait for a request. They follow
    -- the case of the clause.
    editor.buffer:set_selection(1, 1, 1, math.huge)
    type_text("select * from sales.customers c")
    test.not_ok(autocomplete.is_open())
    autocomplete.trigger()
    test.ok(autocomplete.is_open())
    autocomplete.close()
    type_text(" w")
    test.equal(autocomplete.get_selected_suggestion().text, "where")
    test.ok(command.perform("autocomplete:complete"))
    test.equal(line(), "select * from sales.customers c where")

    editor.buffer:set_selection(1, 1, 1, math.huge)
    type_text("SELECT * FROM sales.customers WHERE email <> ")
    test.not_ok(autocomplete.is_open())
    autocomplete.trigger()
    test.ok(autocomplete.is_open())
    autocomplete.close()
    type_text("n")
    test.ok(autocomplete.is_open())
    test.equal(autocomplete.get_selected_suggestion().text, "name")
  end)

  test.it("reads a large database's columns when completion needs them, and runs SQL without metadata", function(context)
    local large = { database = "AnvilTest", default_schema = "dbo", case_sensitive = false, columns_loaded = false,
      objects = { { schema = "sales", name = "customers", kind = "table" }, { schema = "dbo", name = "orders", kind = "table" },
        { schema = "dbo", name = "lines", kind = "table" } } }
    local editor = connected_query(context, large)
    local backend = require "plugins.sql_server.backend"
    local requests = {}
    backend.read_columns = function(_, object, callback)
      requests[#requests + 1] = { name = object.schema .. "." .. object.name, callback = callback }
      return { cancel = function() end }
    end
    -- At a value, columns that arrive later still answer the explicit request.
    editor.buffer:text_input("SELECT * FROM sales.customers AS c WHERE c.id = ")
    editor.buffer:set_selection(1, math.huge)
    autocomplete.trigger()
    test.not_ok(autocomplete.is_open())
    test.equal(#requests, 1)
    test.equal(requests[1].name, "sales.customers")
    autocomplete.trigger()
    test.equal(#requests, 1)
    requests[1].callback(schema.objects[1].columns)
    test.ok(autocomplete.is_open())
    test.equal(autocomplete.get_selected_suggestion().text, "id")
    autocomplete.close()

    editor.buffer:set_selection(1, 1, 1, math.huge)
    editor.buffer:text_input("SELECT * FROM dbo.orders")
    editor.buffer:set_selection(1, #"SELECT *" + 1)
    test.ok(command.perform("sql_server:expand_star"))
    test.equal(#requests, 2)
    test.equal(requests[2].name, "dbo.orders")
    requests[2].callback(schema.objects[2].columns)
    test.equal(editor.buffer.lines[1], "SELECT customer_id FROM dbo.orders\n")
    -- A CTE's * also reads the columns of its sources first.
    editor.buffer:set_selection(1, 1, 1, math.huge)
    editor.buffer:text_input("WITH w AS (SELECT * FROM dbo.lines) SELECT * FROM w")
    editor.buffer:set_selection(1, #"WITH w AS (SELECT * FROM dbo.lines) SELECT *" + 1)
    test.ok(command.perform("sql_server:expand_star"))
    test.equal(#requests, 3)
    test.equal(requests[3].name, "dbo.lines")
    requests[3].callback({ { name = "qty", type = "int" } })
    test.equal(editor.buffer.lines[1], "WITH w AS (SELECT * FROM dbo.lines) SELECT qty FROM w\n")
    editor.buffer:set_selection(1, 1, 1, math.huge)
    editor.buffer:text_input("SELECT customer_id FROM dbo.orders")

    local sql = require "plugins.sql_server"
    local c = sql.connection_for(editor.buffer)
    sql.disconnect(c.id)
    backend.read_schema = function(_, callback)
      callback({ database = "AnvilTest", default_schema = "dbo", columns_loaded = true, objects = {},
        metadata_error = "Metadata read failed (SQLSTATE 42000, error 229)." })
      return { cancel = function() end }
    end
    test.ok(sql.connect(c.id))
    test.equal(c.state, "Ready")
    local submitted
    backend.execute = function(_, text, done)
      submitted = text
      done({ results = {}, affected_rows = {}, messages = {} })
      return { cancel = function() end }
    end
    editor.buffer:set_selection(1, 1, 1, math.huge)
    test.ok(command.perform("sql_server:run_selection"))
    test.equal(submitted, "SELECT customer_id FROM dbo.orders")
  end)

  test.it("completes and expands the columns of CTEs and temporary tables, not of a table with the same name", function(context)
    local editor = connected_query(context)
    local text = "WITH orders AS (SELECT c.id AS customer_key FROM sales.customers c) SELECT o.cu FROM orders o"
    editor.buffer:text_input(text)
    editor.buffer:set_selection(1, #"WITH orders AS (SELECT c.id AS customer_key FROM sales.customers c) SELECT o.cu" + 1)
    autocomplete.trigger()
    test.ok(autocomplete.is_open())
    test.equal(autocomplete.get_selected_suggestion().text, "customer_key")
    autocomplete.close()
    editor.buffer:set_selection(1, #text)
    test.not_ok(require("core.commands.language").activate_symbol(editor))
    test.equal(core.active_view, editor)

    -- A * or x.* in the CTE takes its sources' columns at its place.
    editor.buffer:set_selection(1, 1, 1, #text + 1)
    text = "WITH picked AS (SELECT c.*, o.customer_id AS ref FROM sales.customers c JOIN dbo.orders o ON 1 = 1)"
      .. " SELECT * FROM picked p WHERE p.na"
    editor.buffer:text_input(text)
    editor.buffer:set_selection(1, #text + 1)
    autocomplete.trigger()
    test.ok(autocomplete.is_open())
    test.equal(autocomplete.get_selected_suggestion().text, "name")
    autocomplete.close()
    editor.buffer:set_selection(1, #"WITH picked AS (SELECT c.*, o.customer_id AS ref FROM sales.customers c JOIN dbo.orders o ON 1 = 1) SELECT *" + 1)
    test.ok(command.perform("sql_server:expand_star"))
    test.ok(editor.buffer.lines[1]:find(") SELECT id, name, ref FROM picked p", 1, true))
    -- A CTE that reads itself has no known columns.
    editor.buffer:set_selection(1, 1, 1, math.huge)
    editor.buffer:text_input("WITH r AS (SELECT * FROM r) SELECT * FROM r")
    editor.buffer:set_selection(1, #"WITH r AS (SELECT * FROM r) SELECT *" + 1)
    test.same({ pcall(require("plugins.sql_server.intelligence").expand_star, editor, require "plugins.sql_server") }, { true, false })
    test.equal(editor.buffer.lines[1], "WITH r AS (SELECT * FROM r) SELECT * FROM r\n")

    editor.buffer:set_selection(1, 1, 1, #text + 1)
    editor.buffer:text_input("CREATE TABLE #picked (code int, [the label] nvarchar(5))\nSELECT * FROM #picked")
    editor.buffer:set_selection(2, #"SELECT *" + 1)
    test.ok(command.perform("sql_server:expand_star"))
    test.equal(editor.buffer.lines[2], "SELECT code, [the label] FROM #picked\n")
    editor.buffer:set_selection(2, #"SELECT code, [the label] FROM #pi" + 1)
    autocomplete.trigger()
    test.ok(autocomplete.is_open())
    test.equal(autocomplete.get_selected_suggestion().text, "#picked")
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

  test.it("views the shown rows of a result as CSV and JSON text in new Editors", function(context)
    local editor = connected_query(context)
    require("plugins.sql_server.backend").execute = function(_, _, callback)
      callback({ results = { {
        headers = { "id", "note", "id" }, column_count = 3,
        rows = {
          { cells = { "1", 'say "hi", ok', "x" }, source_line1 = 1, source_line2 = 1 },
          { cells = { "2", false, "" }, source_line1 = 2, source_line2 = 2 },
          { cells = { "3", "two\nlines\0", "\t" }, source_line1 = 3, source_line2 = 3 },
        },
        distinct_values = {},
      } }, affected_rows = {}, messages = {} })
      return { cancel = function() end }
    end
    editor.buffer:text_input("SELECT 1")
    editor.buffer:set_selection(1, 1, 1, 9)
    test.ok(command.perform("sql_server:run_selection"))
    local Results = require "plugins.sql_server.results"
    local result
    for _, pane in ipairs(panes.ordered()) do
      for _, view in ipairs(panes.views(pane)) do
        if view:extends(Results) then result = view end
      end
    end
    panes.focus(panes.pane_for_view(result))
    test.ok(command.perform("sql_server:view_as_csv"))
    local csv = core.active_view
    test.not_equal(csv, result)
    test.not_ok(csv.buffer.read_only)
    test.equal(csv.buffer:get_text(1, 1, math.huge, math.huge),
      'id,note,id\n1,"say ""hi"", ok",x\n2,,""\n3,"two\nlines\0","\t"\n')
    panes.focus(panes.pane_for_view(result))
    test.ok(command.perform("sql_server:view_as_json"))
    test.equal(core.active_view.buffer:get_text(1, 1, math.huge, math.huge), table.concat({
      "[",
      '  {"id": "1", "note": "say \\"hi\\", ok", "id (2)": "x"},',
      '  {"id": "2", "note": null, "id (2)": ""},',
      '  {"id": "3", "note": "two\\nlines\\u0000", "id (2)": "\\t"}',
      "]", "",
    }, "\n"))
    test.equal(core.active_view.buffer.syntax.name, "JSON")
    repeat result:cycle_sort(1) until result:cell_value(1, 1) == "3"
    panes.focus(panes.pane_for_view(result))
    test.ok(command.perform("sql_server:view_as_csv"))
    test.equal(core.active_view.buffer.lines[2], '3,"two\n')
  end)

  test.it("views a cell's whole value in a text Pane, as JSON or XML when it is", function(context)
    local editor = connected_query(context)
    local long = string.rep("x", 40000)
    require("plugins.sql_server.backend").execute = function(_, _, callback)
      callback({ results = { {
        headers = { "doc", "note" }, column_count = 2,
        rows = {
          { cells = { ' {"a": [1, 2]}', "two\nlines" }, source_line1 = 1, source_line2 = 1 },
          { cells = { "<root><a/></root>", false }, source_line1 = 2, source_line2 = 2 },
          { cells = { long, "" }, source_line1 = 3, source_line2 = 3, cut = { [1] = true } },
        },
        distinct_values = {},
      } }, messages = {} })
      return { cancel = function() end }
    end
    editor.buffer:text_input("SELECT 1")
    editor.buffer:set_selection(1, 1, 1, 9)
    test.ok(command.perform("sql_server:run_selection"))
    local result = editor.buffer.sql_results
    local function view(row, column)
      panes.focus(panes.pane_for_view(result))
      result:select_cell(row, column, false)
      return command.perform("sql_server:view_cell")
    end
    test.ok(view(1, 1))
    test.equal(core.active_view.buffer:get_text(1, 1, math.huge, math.huge), ' {"a": [1, 2]}')
    test.equal(core.active_view.buffer.syntax.name, "JSON")
    test.ok(view(1, 2))
    test.equal(core.active_view.buffer:get_text(1, 1, math.huge, math.huge), "two\nlines")
    test.ok(view(2, 1))
    test.equal(core.active_view.buffer.syntax.name, "XML")
    local warnings = {}
    context.original_warn = core.warn
    core.warn = function(format, ...) warnings[#warnings + 1] = string.format(format, ...) end
    view(2, 2)
    test.equal(core.active_view, result)
    test.ok(view(3, 1))
    core.warn = context.original_warn
    test.equal(#core.active_view.buffer:get_text(1, 1, math.huge, math.huge), 40000)
    test.same(warnings, { "The value is NULL.", "SQL Server sent more of this value. Anvil keeps its first 32,768 characters." })
  end)

  test.it("opens the rows that a foreign key links to the selected result rows, in both directions", function(context)
    local editor = connected_query(context)
    local context_menu = require "core.context_menu"
    local describe_headers = { "name", "is_hidden", "source_schema", "source_table", "source_column",
      "is_part_of_unique_key", "is_updateable", "system_type_name" }
    local function row(...) return { cells = { ... }, source_line1 = 1, source_line2 = 1 } end
    local function described(schema_name, table_name, column, key)
      return row(column, "0", schema_name, table_name, column, key and "1" or "0", key and "0" or "1", "int")
    end
    local submitted, database = {}, "AnvilTest"
    require("plugins.sql_server.backend").execute = function(_, text, callback)
      submitted[#submitted + 1] = text
      local orders = text:find("dbo.orders", 1, true) ~= nil
      if text:find("^EXEC sys.sp_describe_first_result_set") then
        local rows = orders and { described("dbo", "orders", "id", true), described("dbo", "orders", "customer_id") }
          or { described("sales", "customers", "id", true), described("sales", "customers", "name") }
        callback({ session = 7, database = database, messages = {},
          results = { { headers = describe_headers, column_count = 8, distinct_values = {}, rows = rows } } })
      else
        local rows = orders and { row("10", "1"), row("11", "1"), row("12", false), row("13", "2") } or { row("1", "Ada") }
        callback({ session = 7, database = database, messages = {}, results = { {
          headers = orders and { "id", "customer_id" } or { "id", "name" }, column_count = 2, distinct_values = {}, rows = rows } } })
      end
      return { cancel = function() end }
    end
    local function related(text, row2, label)
      panes.focus(panes.pane_for_view(editor))
      editor.buffer:set_selection(1, 1, 1, math.huge)
      editor.buffer:text_input(text)
      editor.buffer:set_selection(1, 1, 1, math.huge)
      test.ok(command.perform("sql_server:run_selection"))
      local result = editor.buffer.sql_execution.view
      panes.focus(panes.pane_for_view(result))
      result:select_cell(1, 2, false)
      result:select_cell(row2, 2, true)
      test.ok(command.perform("sql_server:related_rows"))
      test.ok(context_menu.is_open())
      test.same(context_menu.labels(), { label })
      test.ok(context_menu.choose(label))
      return core.active_view.buffer:get_text(1, 1, math.huge, math.huge)
    end
    -- A NULL references nothing, and a repeated value gives one condition.
    test.equal(related("SELECT id, customer_id FROM dbo.orders", 4, "Referenced: sales.customers (customer_id)"),
      "SELECT *\nFROM [sales].[customers]\nWHERE ([id] = N'1')\n   OR ([id] = N'2');\n")
    test.equal(submitted[#submitted], "SELECT *\nFROM [sales].[customers]\nWHERE ([id] = N'1')\n   OR ([id] = N'2');\n")
    test.equal(related("SELECT id, name FROM sales.customers", 1, "Referencing: dbo.orders (customer_id)"),
      "SELECT *\nFROM [dbo].[orders]\nWHERE ([customer_id] = N'1');\n")
    -- A result of a Query that USE moved scripts its rows in that database.
    database = "Other"
    require("plugins.sql_server.backend").read_schema = function(options, callback)
      callback({ database = options.database, default_schema = "dbo", case_sensitive = false, objects = {},
        foreign_keys = schema.foreign_keys })
      return { cancel = function() end }
    end
    test.equal(related("SELECT id, name FROM sales.customers", 1, "Referencing: dbo.orders (customer_id)"),
      "USE [Other];\nSELECT *\nFROM [dbo].[orders]\nWHERE ([customer_id] = N'1');\n")
  end)

  test.it("scripts result edits by the table's key in a new Query and runs nothing", function(context)
    local editor = connected_query(context)
    local submitted = {}
    local describe_headers = { "name", "is_hidden", "source_schema", "source_table", "source_column",
      "is_part_of_unique_key", "is_updateable", "system_type_name" }
    local function described(name, column, key, hidden, updateable, type)
      return { cells = { name, hidden and "1" or "0", "sales", "customers", column, key and "1" or "0",
        updateable and "1" or "0", type }, source_line1 = 1, source_line2 = 1 }
    end
    local function row(...) return { cells = { ... }, source_line1 = 1, source_line2 = 1 } end
    require("plugins.sql_server.backend").execute = function(_, text, callback)
      submitted[#submitted + 1] = text
      if #submitted == 2 then
        callback({ messages = {}, results = { { headers = describe_headers, column_count = 8, distinct_values = {}, rows = {
          described("id", "id", true, false, false, "int"), described("who", "name", false, false, true, "nvarchar(80)"),
          row("n", "0", false, false, false, "0", "0", "int") } } } })
      else
        callback({ messages = {}, results = { { headers = { "id", "who", "n" }, column_count = 3, distinct_values = {},
          rows = { row("1", "Ada", "3"), row("2", "Bea", "3"), row("3", false, "0") } } } })
      end
      return { cancel = function() end }
    end
    local text = "SELECT id, name AS who, LEN(name) n FROM sales.customers WHERE city = 'Lisbon'"
    editor.buffer:text_input(text)
    editor.buffer:set_selection(1, 1, 1, #text + 1)
    test.ok(command.perform("sql_server:run_selection"))
    local result = editor.buffer.sql_execution.view
    panes.focus(panes.pane_for_view(result))
    result:select_cell(2, 2, false)
    test.ok(command.perform("sql_server:edit_cell"))
    test.equal(submitted[2], "EXEC sys.sp_describe_first_result_set @tsql = N'SELECT id, name AS who, LEN(name) n "
      .. "FROM sales.customers WHERE city = ''Lisbon''', @params = NULL, @browse_information_mode = 1;")
    -- The editor starts with the old value selected, so typing replaces it.
    core.on_event("textinput", "Bea O'Neil")
    test.equal(result:cell_value(2, 2), "Bea")
    core.on_event("keypressed", "return")
    test.equal(core.active_view, result)
    test.equal(result:cell_value(2, 2), "Bea O'Neil")
    result:select_cell(1, 3, false)
    command.perform("sql_server:edit_cell")
    test.equal(core.active_view, result)
    result:select_cell(3, 1, false)
    test.ok(command.perform("sql_server:delete_rows"))
    result:select_cell(1, 2, false)
    result:select_cell(1, 3, true)
    test.equal((result:footer_summary()), "2 cells")
    test.ok(command.perform("sql_server:set_cell_null"))
    test.equal(result:cell_value(1, 2), false)
    test.equal((result:footer_summary()), "2 cells · 1 NULL · Sum 3 · Avg 3 · Min 3 · Max 3")
    result:select_cell(1, 1, false)
    result:select_cell(3, 1, true)
    test.equal((result:footer_summary()), "3 cells · Sum 6 · Avg 2 · Min 1 · Max 3")
    local labels = {}
    for _, b in ipairs(result:footer_buttons()) do labels[#labels + 1] = b.label end
    test.equal(labels[1], "Show Script · 3 Changes")
    test.ok(command.perform("sql_server:show_change_script"))
    local script = core.active_view
    test.not_equal(script, result)
    test.equal(require("plugins.sql_server").connection_for(script.buffer), require("plugins.sql_server").connection_for(editor.buffer))
    test.equal(script.buffer:get_text(1, 1, math.huge, math.huge), table.concat({
      "-- Changes to [sales].[customers] from SQL Results. Review them, then run this script.",
      "SET XACT_ABORT ON;",
      "BEGIN TRANSACTION;",
      "UPDATE [sales].[customers] SET [name] = NULL WHERE [id] = N'1' AND [name] = N'Ada';",
      "IF @@ROWCOUNT <> 1 THROW 50001, N'Row 1 changed or no longer exists.', 1;",
      "UPDATE [sales].[customers] SET [name] = N'Bea O''Neil' WHERE [id] = N'2' AND [name] = N'Bea';",
      "IF @@ROWCOUNT <> 1 THROW 50001, N'Row 2 changed or no longer exists.', 1;",
      "DELETE FROM [sales].[customers] WHERE [id] = N'3' AND [name] IS NULL;",
      "IF @@ROWCOUNT <> 1 THROW 50001, N'Row 3 changed or no longer exists.', 1;",
      "COMMIT TRANSACTION;",
      "",
    }, "\n"))
    test.equal(#submitted, 2)

    panes.focus(panes.pane_for_view(result))
    result:select_cell(1, 1, false)
    result:select_cell(2, 3, true)
    test.ok(command.perform("sql_server:script_rows_as_insert"))
    test.equal(core.active_view.buffer:get_text(1, 1, math.huge, math.huge), table.concat({
      "-- Rows of [sales].[customers] from SQL Results. Review them, then run this script.",
      "INSERT INTO [sales].[customers] ([name]) VALUES",
      "    (NULL),",
      "    (N'Bea O''Neil');",
      "",
    }, "\n"))
    panes.focus(panes.pane_for_view(result))
    test.ok(command.perform("sql_server:script_rows_as_select"))
    test.equal(core.active_view.buffer:get_text(1, 1, math.huge, math.huge),
      "SELECT *\nFROM [sales].[customers]\nWHERE ([id] = N'1' AND [name] = N'Ada')\n   OR ([id] = N'2' AND [name] = N'Bea');\n")
    test.equal(#submitted, 2)

    -- A shown rowversion checks the whole row. Without one, only values that
    -- compare exactly as text are checked: not float, XML or text columns.
    local edit = require "plugins.sql_server.edit"
    local function script(columns, cells, edits, delete)
      local described_rows = {}
      for i, c in ipairs(columns) do described_rows[i] = described(c[1], c[1], c[2], false, c[3], c[4]) end
      local model = { column_count = #columns, rows = { row(unpack(cells)) } }
      local results = { model = model, edits = { [model.rows[1]] = edits }, deletes = { [model.rows[1]] = delete } }
      results.edit_info = test.not_nil(edit.analyze(model, { results = { { headers = describe_headers, rows = described_rows } } }))
      local text = edit.script(results)
      return text:match("\n(UPDATE [^\n]*)") or text:match("\n(DELETE [^\n]*)")
    end
    test.equal(script({ { "id", true, false, "int" }, { "name", false, true, "nvarchar(80)" }, { "rv", false, false, "timestamp" } },
      { "1", "Ada", "00000000000007D1" }, { [2] = "Bea" }),
      "UPDATE [sales].[customers] SET [name] = N'Bea' WHERE [id] = N'1' AND [rv] = 0x00000000000007D1;")
    test.equal(script({ { "id", true, false, "int" }, { "f", false, true, "float" }, { "x", false, true, "xml" },
      { "t", false, true, "ntext" }, { "d", false, true, "decimal(19,4)" } }, { "1", "0.1", "<a/>", "t", "2.5000" }, nil, true),
      "DELETE FROM [sales].[customers] WHERE [id] = N'1' AND [d] = N'2.5000';")

    local _, reason = require("plugins.sql_server.edit").analyze({ column_count = 1 }, { results = { {
      headers = describe_headers, rows = { described("id", "id", true, true, false, "int"),
        described("who", "name", false, false, true, "nvarchar(80)") } } } })
    test.equal(reason, "Include the key column [id] to edit this result.")
  end)

  test.it("edits result cells in place, and undoes and reverts the changes", function(context)
    local editor = connected_query(context)
    local describe_headers = { "name", "is_hidden", "source_schema", "source_table", "source_column",
      "is_part_of_unique_key", "is_updateable", "system_type_name" }
    local function described(name, key, updateable)
      return { cells = { name, "0", "sales", "customers", name, key and "1" or "0", updateable and "1" or "0", "nvarchar(80)" },
        source_line1 = 1, source_line2 = 1 }
    end
    local function row(...) return { cells = { ... }, source_line1 = 1, source_line2 = 1 } end
    require("plugins.sql_server.backend").execute = function(_, text, callback)
      if text:find("^EXEC sys.sp_describe_first_result_set") then
        callback({ messages = {}, results = { { headers = describe_headers, column_count = 8, distinct_values = {},
          rows = { described("id", true, false), described("name", false, true), described("city", false, true) } } } })
      else
        callback({ messages = {}, results = { { headers = { "id", "name", "city" }, column_count = 3, distinct_values = {},
          rows = { row("1", "Ada", "Lisbon"), row("2", "Bea", "Porto") } } } })
      end
      return { cancel = function() end }
    end
    editor.buffer:text_input("SELECT id, name, city FROM sales.customers")
    editor.buffer:set_selection(1, 1, 1, math.huge)
    test.ok(command.perform("sql_server:run_selection"))
    local result = editor.buffer.sql_execution.view
    panes.focus(panes.pane_for_view(result))
    local function focus()
      local _, column, display_row = result:focus_cell()
      return display_row .. ":" .. column
    end

    -- Typing over a cell replaces its value. Escape keeps the old value.
    result:select_cell(1, 2, false)
    core.on_event("textinput", "Z")
    core.on_event("textinput", "oe")
    core.on_event("keypressed", "escape")
    test.equal(result:cell_value(1, 2), "Ada")
    -- Tab keeps the text and moves right; Enter keeps it and moves down.
    core.on_event("textinput", "Zoe")
    core.on_event("keypressed", "tab")
    test.equal(result:cell_value(1, 2), "Zoe")
    test.equal(focus(), "1:3")
    test.ok(command.perform("sql_server:edit_cell"))
    core.on_event("textinput", "Faro")
    core.on_event("keypressed", "return")
    test.equal(result:cell_value(1, 3), "Faro")
    test.equal(focus(), "2:3")
    -- Backspace starts an empty value.
    core.on_event("keypressed", "backspace")
    core.on_event("keypressed", "return")
    test.equal(result:cell_value(2, 3), "")
    -- A column that cannot change takes no edit.
    local warnings = {}
    context.original_warn = core.warn
    core.warn = function(format, ...) warnings[#warnings + 1] = string.format(format, ...) end
    result:select_cell(1, 1, false)
    core.on_event("textinput", "9")
    core.on_event("keypressed", "return")
    test.equal(result:cell_value(1, 1), "1")
    test.equal(warnings[1], "Column id is not a column of customers that can change.")
    core.warn = context.original_warn

    -- Undo and redo go back through each change. Revert puts back the selected cells' values.
    test.ok(command.perform("sql_server:undo_change"))
    test.equal(result:cell_value(2, 3), "Porto")
    test.ok(command.perform("sql_server:undo_change"))
    test.equal(result:cell_value(1, 3), "Lisbon")
    test.ok(command.perform("sql_server:redo_change"))
    test.equal(result:cell_value(1, 3), "Faro")
    result:select_cell(1, 2, false)
    result:select_cell(1, 3, true)
    test.ok(command.perform("sql_server:revert_cells"))
    test.equal(result:cell_value(1, 2), "Ada")
    test.equal(result:cell_value(1, 3), "Lisbon")
    test.not_ok(command.is_valid("sql_server:show_change_script"))
    test.ok(command.perform("sql_server:undo_change"))
    test.equal(result:cell_value(1, 2), "Zoe")
    test.ok(command.is_valid("sql_server:show_change_script"))
  end)

  test.it("does not edit or script a value that Anvil cut, and warns when it exports one", function(context)
    local editor = connected_query(context)
    local describe_headers = { "name", "is_hidden", "source_schema", "source_table", "source_column",
      "is_part_of_unique_key", "is_updateable", "system_type_name" }
    local function described(name, key, updateable, type)
      return { cells = { name, "0", "sales", "customers", name, key and "1" or "0", updateable and "1" or "0", type },
        source_line1 = 1, source_line2 = 1 }
    end
    local runs = 0
    require("plugins.sql_server.backend").execute = function(_, _, callback)
      runs = runs + 1
      if runs == 2 then
        callback({ messages = {}, results = { { headers = describe_headers, column_count = 8, distinct_values = {}, rows = {
          described("id", true, false, "int"), described("doc", false, true, "nvarchar(max)") } } } })
      else
        callback({ messages = {}, results = { { headers = { "id", "doc" }, column_count = 2, distinct_values = {}, rows = {
          { cells = { "1", string.rep("x", 32768) }, cut = { [2] = true }, source_line1 = 1, source_line2 = 1 },
          { cells = { "2", "short" }, source_line1 = 1, source_line2 = 1 } } } } })
      end
      return { cancel = function() end }
    end
    editor.buffer:text_input("SELECT id, doc FROM sales.customers")
    editor.buffer:set_selection(1, 1, 1, math.huge)
    test.ok(command.perform("sql_server:run_selection"))
    local result = editor.buffer.sql_execution.view
    local warnings = {}
    context.original_warn = core.warn
    core.warn = function(format, ...) warnings[#warnings + 1] = string.format(format, ...) end
    local cut = "Anvil has only the first 32,768 characters of a value in doc."
    panes.focus(panes.pane_for_view(result))
    result:select_cell(1, 2, false)
    command.perform("sql_server:edit_cell")
    test.equal(core.active_view, result)
    test.equal(warnings[1], cut .. " Change it with SQL.")
    result:select_cell(1, 1, false)
    result:select_cell(2, 2, true)
    command.perform("sql_server:script_rows_as_insert")
    test.equal(core.active_view, result)
    test.equal(warnings[2], cut .. " Script these rows with SQL.")
    test.ok(command.perform("sql_server:script_rows_as_select"))
    test.equal(core.active_view.buffer:get_text(1, 1, math.huge, math.huge),
      "SELECT *\nFROM [sales].[customers]\nWHERE ([id] = N'1')\n   OR ([id] = N'2' AND [doc] = N'short');\n")
    test.equal(warnings[3], cut .. " The SELECT leaves it out.")
    panes.focus(panes.pane_for_view(result))
    test.ok(command.perform("sql_server:view_as_csv"))
    test.equal(warnings[4], "Anvil has only the first 32,768 characters of some values.")
    core.warn = context.original_warn
  end)

  test.it("designs a table in a Dialog and opens its ALTER script in a new Query that runs nothing", function(context)
    local editor = connected_query(context)
    local reads = 0
    local function result(headers, rows)
      local out = { headers = headers, rows = {} }
      for i, cells in ipairs(rows) do out.rows[i] = { cells = cells } end
      return out
    end
    require("plugins.sql_server.backend").execute = function(_, text, callback)
      test.ok(text:find("sys.sql_expression_dependencies", 1, true))
      reads = reads + 1
      callback({ results = {
        result({ "object_id" }, { { "10" } }),
        result({ "column_id", "name", "type", "collation_name", "is_nullable", "is_identity", "seed", "increment",
          "default_name", "default_definition", "computed", "is_persisted", "locked" },
          { { "1", "customer_id", "int", false, "0", "0", false, false, false, false, false, false, "0" } }),
        result({ "index_id", "name", "kind", "is_unique", "type", "column_id", "locked" }, {}),
        result({ "object_id", "name", "ref_schema", "ref_table", "parent_column_id", "ref_column", "on_delete",
          "on_update", "locked" }, {}),
        result({ "object_id", "name", "definition", "locked" }, {}),
        result({ "object_id", "minor_id", "column_id" }, {}),
      } })
      return { cancel = function() end }
    end
    local function type_text(text)
      for char in text:gmatch(".") do core.on_event("textinput", char) end
      test.ok(command.perform("dialog:confirm"))
    end
    local orders = { schema = "dbo", name = "orders", kind = "table" }
    test.ok(command.perform("sql_server:table_design", editor, orders))
    local design = test.not_nil(dialog.current())
    test.equal(tostring(design), "Table Design")
    test.equal(design.status.text, "No changes")
    test.ok(not design.script_button.enabled)

    test.ok(design.add_column:activate())
    test.equal(design.focused, design.column_name)
    type_text("id")
    design:focus(design.column_type)
    type_text("int")
    design.column_nullable:toggle()
    design.column_identity:toggle()
    design:show_page("primary")
    design.pk_columns:select(2)
    test.ok(design.pk_columns:activate())
    design:show_page("foreign")
    test.ok(design.add_fk:activate())
    test.equal(design.status.text, "Foreign key [FK_orders_1] needs a referenced table.")
    design.fk_table:choose("sales.customers")
    design.fk_columns:select(1)
    test.ok(design.fk_columns:activate())
    design:show_page("checks")
    test.ok(design.add_check:activate())
    type_text("customer_id > 0")
    design:show_page("indexes")
    test.ok(design.add_index:activate())
    design.index_columns:select(1)
    test.ok(design.index_columns:activate())
    test.equal(design.status.text, "")
    test.ok(design.script_button.enabled)

    -- A closed design stays until the next connect, so the Dialog opens it again without a read.
    design:close()
    test.ok(command.perform("sql_server:table_design", editor, orders))
    design = test.not_nil(dialog.current())
    test.equal(reads, 1)
    test.ok(design.script_button:activate())
    test.is_nil(dialog.current())
    local script = core.active_view
    test.not_equal(script, editor)
    test.equal(require("plugins.sql_server").connection_for(script.buffer), require("plugins.sql_server").connection_for(editor.buffer))
    test.equal(script.buffer:get_text(1, 1, math.huge, math.huge), table.concat({
      "SET XACT_ABORT ON;",
      "BEGIN TRANSACTION;",
      "ALTER TABLE [dbo].[orders] ADD [id] int IDENTITY(1,1) NOT NULL;",
      "ALTER TABLE [dbo].[orders] ADD CONSTRAINT [PK_orders] PRIMARY KEY ([id]);",
      "CREATE INDEX [IX_orders_1] ON [dbo].[orders] ([customer_id]);",
      "ALTER TABLE [dbo].[orders] ADD CONSTRAINT [CK_orders_1] CHECK (customer_id > 0);",
      "ALTER TABLE [dbo].[orders] ADD CONSTRAINT [FK_orders_1] FOREIGN KEY ([customer_id]) REFERENCES [sales].[customers] ([id]);",
      "COMMIT TRANSACTION;",
      "",
    }, "\n"))
    test.equal(reads, 1)

    -- A script that opened ends the design, so the next Dialog reads the table again.
    panes.focus(panes.pane_for_view(editor))
    test.ok(command.perform("sql_server:table_design", editor, orders))
    test.equal(reads, 2)
    test.not_nil(dialog.current()):close()
    test.ok(command.perform("sql_server:new_table"))
    design = test.not_nil(dialog.current())
    test.equal(design.title, "New Table")
    test.ok(design.script_button.enabled)
  end)

  test.it("keeps the Project's runs in SQL History and opens one in a new Query that runs nothing", function(context)
    local editor, c = connected_query(context)
    local history = require "plugins.sql_server.history"
    local runs = 0
    require("plugins.sql_server.backend").execute = function(_, text, callback)
      runs = runs + 1
      callback(text:find("missing", 1, true) and { error = "Invalid object name 'missing'." }
        or { results = {}, affected_rows = { "1" } })
      return { cancel = function() end }
    end
    editor.buffer:text_input("SELECT name\nFROM sales.customers")
    test.ok(command.perform("sql_server:run_buffer"))
    test.ok(command.perform("sql_server:run_buffer"))
    editor.buffer:set_selection(2, #editor.buffer.lines[2])
    editor.buffer:text_input("\nSELECT * FROM missing")
    editor.buffer:set_selection(3, 1, 3, math.huge)
    test.ok(command.perform("sql_server:run_selection"))
    test.ok(command.perform("sql_server:explain_selection"))
    test.equal(runs, 4)
    local deadline = system.get_time() + 10
    while require("plugins.sql_server").is_saving() and system.get_time() < deadline do coroutine.yield(0.01) end
    test.ok(not require("plugins.sql_server").is_saving())

    -- The history comes back from storage.
    history.reset()
    test.ok(command.perform("sql_server:history"))
    while core.active_view ~= core.global_prompt_bar and system.get_time() < deadline do coroutine.yield(0.01) end
    test.equal(core.active_view, core.global_prompt_bar)
    local items = core.global_prompt_bar.suggestions
    test.equal(items[1].text, "SELECT * FROM missing")
    test.equal(items[1].info, c.name .. " · now · Error")
    test.equal(items[2].text, "SELECT name FROM sales.customers")
    test.equal(items[2].info, c.name .. " · now · ×2")
    core.global_prompt_bar:set_text("customers")
    core.global_prompt_bar:submit()
    local query = core.active_view
    test.not_equal(query, editor)
    test.equal(query.buffer:get_text(1, 1, math.huge, math.huge), "SELECT name\nFROM sales.customers")
    test.equal(require("plugins.sql_server").connection_for(query.buffer), c)
    test.equal(runs, 4)
  end)

  test.it("reloads the catalog in place after SQL that changes the schema", function(context)
    local editor, c = connected_query(context)
    local backend = require "plugins.sql_server.backend"
    context.original_close = backend.close_session
    local closed, reads = {}, 0
    backend.close_session = function(id) closed[#closed + 1] = id end
    local grown = { database = "AnvilTest", default_schema = "dbo", case_sensitive = false, objects = {
      schema.objects[1], { schema = "sales", name = "notes", kind = "table", columns = { { name = "body", type = "nvarchar(max)" } } } } }
    backend.read_schema = function(_, callback)
      reads = reads + 1
      callback(grown)
      return { cancel = function() end }
    end
    local changed = true
    backend.execute = function(_, _, done)
      done({ session = 7, results = {}, messages = {}, transaction_count = 0, schema_changed = changed })
      return { cancel = function() end }
    end
    editor.buffer:text_input("CREATE TABLE sales.notes (body nvarchar(max))")
    editor.buffer:set_selection(1, 1, 1, math.huge)
    test.ok(command.perform("sql_server:run_selection"))
    test.equal(reads, 1)
    test.equal(c.state, "Ready")
    test.equal(c.catalog, grown)
    test.equal(require("plugins.sql_server.session").get(editor.buffer).id, 7)
    test.same(closed, {})
    changed = false
    editor.buffer:set_selection(1, 1, 1, math.huge)
    test.ok(command.perform("sql_server:run_selection"))
    test.equal(reads, 1)
  end)

  test.it("reloads the catalog after a cancelled run of SQL that changes the schema", function(context)
    local editor = connected_query(context)
    local backend = require "plugins.sql_server.backend"
    context.original_close = backend.close_session
    backend.close_session = function() end
    local reads, finish = 0, nil
    backend.read_schema = function(_, callback)
      reads = reads + 1
      callback(schema)
      return { cancel = function() end }
    end
    backend.execute = function(_, _, done)
      finish = done
      return { cancel = function() end }
    end
    editor.buffer:text_input("CREATE TABLE sales.a (x int)\nGO\nWAITFOR DELAY '01:00'")
    editor.buffer:set_selection(1, 1, 3, math.huge)
    test.ok(command.perform("sql_server:run_selection"))
    test.ok(command.perform("sql_server:cancel"))
    finish({ session = 7, results = {}, messages = {}, cancelled = true, transaction_count = 0, schema_changed = true })
    test.equal(reads, 1)
  end)

  test.it("reads the catalog once more after a schema change during a reload", function(context)
    local editor, c = connected_query(context)
    local backend = require "plugins.sql_server.backend"
    context.original_close = backend.close_session
    backend.close_session = function() end
    local pending = {}
    backend.read_schema = function(_, callback)
      pending[#pending + 1] = callback
      return { cancel = function() end }
    end
    backend.execute = function(_, _, done)
      done({ session = 7, results = {}, messages = {}, transaction_count = 0, schema_changed = true })
      return { cancel = function() end }
    end
    editor.buffer:text_input("CREATE TABLE sales.a (x int)")
    editor.buffer:set_selection(1, 1, 1, math.huge)
    test.ok(command.perform("sql_server:run_selection"))
    editor.buffer:set_selection(1, 1, 1, math.huge)
    test.ok(command.perform("sql_server:run_selection"))
    test.equal(#pending, 1)
    local first = { database = "AnvilTest", default_schema = "dbo", case_sensitive = false, objects = {} }
    pending[1](first)
    test.equal(c.catalog, first)
    test.equal(#pending, 2)
    local second = { database = "AnvilTest", default_schema = "dbo", case_sensitive = false, objects = { schema.objects[1] } }
    pending[2](second)
    test.equal(c.catalog, second)
    test.equal(#pending, 2)
  end)

  test.it("keeps the catalog when a reload fails, and reloads after an open transaction ends", function(context)
    local editor, c = connected_query(context)
    local original = c.catalog
    local backend = require "plugins.sql_server.backend"
    context.original_end, context.original_close = backend.end_transaction, backend.close_session
    backend.close_session = function() end
    local reads, reply = 0, { objects = {}, metadata_error = "Lock request time out period exceeded." }
    backend.read_schema = function(_, callback)
      reads = reads + 1
      callback(reply)
      return { cancel = function() end }
    end
    local count = 0
    backend.execute = function(_, _, done)
      done({ session = 7, results = {}, messages = {}, transaction_count = count, schema_changed = true })
      return { cancel = function() end }
    end
    backend.end_transaction = function(_, _, callback)
      callback(0)
      return { cancel = function() end }
    end
    editor.buffer:text_input("CREATE TABLE sales.notes (body nvarchar(max))")
    editor.buffer:set_selection(1, 1, 1, math.huge)
    test.ok(command.perform("sql_server:run_selection"))
    test.equal(reads, 1)
    test.equal(c.catalog, original)

    count = 1
    reply = { database = "AnvilTest", default_schema = "dbo", case_sensitive = false, objects = { schema.objects[1] } }
    editor.buffer:set_selection(1, 1, 1, math.huge)
    test.ok(command.perform("sql_server:run_selection"))
    test.equal(reads, 1)
    test.ok(command.perform("sql_server:commit"))
    test.equal(reads, 2)
    test.equal(c.catalog, reply)
  end)

  test.it("reloads a waiting schema change when its session ends", function(context)
    local editor, c = connected_query(context)
    local backend = require "plugins.sql_server.backend"
    context.original_close = backend.close_session
    backend.close_session = function() end
    local reads = 0
    backend.read_schema = function(_, callback)
      reads = reads + 1
      callback({ database = "AnvilTest", default_schema = "dbo", case_sensitive = false, objects = {} })
      return { cancel = function() end }
    end
    local reply
    backend.execute = function(_, _, done)
      done(reply)
      return { cancel = function() end }
    end
    -- The CREATE commits before the transaction opens, so the table stays
    -- when the session ends.
    reply = { session = 7, results = {}, messages = {}, transaction_count = 1, schema_changed = true }
    editor.buffer:text_input("CREATE TABLE sales.notes (body nvarchar(max)); BEGIN TRANSACTION")
    editor.buffer:set_selection(1, 1, 1, math.huge)
    test.ok(command.perform("sql_server:run_selection"))
    test.equal(reads, 0)
    reply = { session_lost = true, results = {}, messages = {}, error = "The connection to SQL Server was lost." }
    editor.buffer:set_selection(1, 1, 1, math.huge)
    test.ok(command.perform("sql_server:run_selection"))
    test.equal(reads, 1)

    reply = { session = 8, results = {}, messages = {}, transaction_count = 1, schema_changed = true }
    editor.buffer:set_selection(1, 1, 1, math.huge)
    test.ok(command.perform("sql_server:run_selection"))
    test.equal(reads, 1)
    require("plugins.sql_server.session").close(editor.buffer)
    test.equal(reads, 2)
  end)

  test.it("reloads metadata whose objects changed on the server since the last check", function(context)
    local function catalog(stamp, objects)
      return { database = "AnvilTest", default_schema = "dbo", case_sensitive = false, stamp = stamp,
        objects = objects, foreign_keys = {} }
    end
    local customers = { schema = "sales", name = "customers", kind = "table", columns = { { name = "id", type = "int" } } }
    local editor = connected_query(context, catalog("1|a", { customers }))
    local backend = require "plugins.sql_server.backend"
    local server_stamp, checks, reads = "1|a", 0, 0
    context.original_close = backend.close_session
    backend.close_session = function() end
    backend.execute = function(_, _, callback)
      checks = checks + 1
      callback({ session = 9, messages = {}, results = { { headers = { "" }, column_count = 1, distinct_values = {},
        rows = { { cells = { server_stamp } } } } } })
      return { cancel = function() end }
    end
    backend.read_schema = function(_, callback)
      reads = reads + 1
      callback(catalog(server_stamp, { customers,
        { schema = "sales", name = "invoices", kind = "table", columns = { { name = "id", type = "int" } } } }))
      return { cancel = function() end }
    end
    local now = system.get_time()
    context.original_time = system.get_time
    system.get_time = function() return now end
    editor.buffer:text_input("SELECT * FROM sales.inv")
    local function complete()
      autocomplete.close()
      editor.buffer:set_selection(1, #"SELECT * FROM sales.inv" + 1)
      autocomplete.trigger()
      local open = autocomplete.is_open() and autocomplete.get_selected_suggestion().text
      autocomplete.close()
      return open
    end
    test.not_ok(complete())
    test.equal(checks, 0)
    now = now + 31
    test.not_ok(complete())
    test.equal(checks, 1)
    test.equal(reads, 0)
    test.not_ok(complete())
    test.equal(checks, 1)
    server_stamp = "2|b"
    now = now + 31
    complete()
    test.equal(checks, 2)
    test.equal(reads, 1)
    test.equal(complete(), "invoices")
  end)

  test.it("completes from the database that a Query's session moved to with USE", function(context)
    local editor = connected_query(context)
    local backend = require "plugins.sql_server.backend"
    local database = "master"
    local reads, loaded = {}, nil
    backend.read_schema = function(options, callback)
      reads[#reads + 1] = options.database
      loaded = callback
      return { cancel = function() end }
    end
    local definitions = {}
    backend.read_definition = function(options, object, callback)
      definitions[#definitions + 1] = options.database .. ":" .. object.schema .. "." .. object.name
      callback({ source = "CREATE TABLE [sales].[customers] ([name_in_master] int);" })
      return { cancel = function() end }
    end
    backend.execute = function(_, _, done)
      done({ session = 7, results = {}, messages = {}, transaction_count = 0, database = database })
      return { cancel = function() end }
    end
    local function status()
      local item = core.status_bar:get_item("sql:connection")
      local text = ""
      for _, part in ipairs(item.get_item(item, editor)) do if type(part) == "string" then text = text .. part end end
      return text
    end
    local function completes()
      editor.buffer:set_selection(2, math.huge)
      autocomplete.trigger()
      local open = autocomplete.is_open()
      autocomplete.close()
      return open
    end
    editor.buffer:text_input("USE master\nSELECT c.na FROM sales.customers AS c")
    editor.buffer:set_selection(1, 1, 1, math.huge)
    test.ok(command.perform("sql_server:run_selection"))
    test.ok(status():find(" · Database master", 1, true))
    -- The other database's catalog loads once, in the background.
    editor.buffer:set_selection(2, #"SELECT c.na" + 1)
    autocomplete.trigger()
    test.not_ok(autocomplete.is_open())
    test.same(reads, { "master" })
    loaded({ database = "master", default_schema = "dbo", case_sensitive = false, objects = {
      { schema = "sales", name = "customers", kind = "table", columns = { { name = "name_in_master", type = "int" } } } } })
    editor.buffer:set_selection(2, #"SELECT c.na" + 1)
    autocomplete.trigger()
    test.ok(autocomplete.is_open())
    test.equal(autocomplete.get_selected_suggestion().text, "name_in_master")
    autocomplete.close()
    test.same(reads, { "master" })
    -- Go to Definition reads the object in its own database.
    editor.buffer:set_selection(2, #"SELECT c.na FROM sales.cust" + 1)
    test.ok(require("core.commands.language").activate_symbol(editor))
    test.same(definitions, { "master:sales.customers" })
    test.equal(core.active_view.buffer.lines[1], "USE [master];\n")
    panes.present(editor, { focus = true })

    database = "ANVILTEST"
    editor.buffer:set_selection(1, 1, 1, math.huge)
    test.ok(command.perform("sql_server:run_selection"))
    test.not_ok(status():find("Database", 1, true))
    editor.buffer:set_selection(2, #"SELECT c.na" + 1)
    autocomplete.trigger()
    test.ok(autocomplete.is_open())
    test.equal(autocomplete.get_selected_suggestion().text, "name")
  end)

  test.it("runs again on a new session when the idle session is gone, unless a transaction was open", function(context)
    local editor = connected_query(context)
    local backend = require "plugins.sql_server.backend"
    local session = require "plugins.sql_server.session"
    local calls, open = {}, 0
    backend.execute = function(_, _, done, settings)
      calls[#calls + 1] = settings.session or "new"
      if settings.session == 7 then
        done({ session_lost = true, idle_lost = true, results = {}, messages = {},
          error = "The idle SQL session was lost. The server rolled back any open transaction." })
      else
        done({ session = 7, results = {}, messages = { { text = "(1 row affected)" } }, transaction_count = open })
      end
      return { cancel = function() end }
    end
    editor.buffer:text_input("UPDATE sales.customers SET name = N'x' WHERE id = 1")
    local function run()
      editor.buffer:set_selection(1, 1, 1, math.huge)
      test.ok(command.perform("sql_server:run_selection"))
    end
    run()
    run()
    test.same(calls, { "new", 7, "new" })
    test.equal(session.get(editor.buffer).id, 7)
    local results = editor.buffer.sql_results
    test.equal(results:messages_text(), "The idle SQL session was lost, so a new session ran the SQL. "
      .. "Its temporary tables and SET options are gone.\n(1 row affected)")
    open = 1
    run()
    calls = {}
    run()
    test.same(calls, { 7 })
    test.equal(session.get(editor.buffer), nil)
    test.ok(results:messages_text():find("rolled back", 1, true))
  end)

  test.it("runs a large script without a time limit unless the Query sets one", function(context)
    local editor = connected_query(context)
    local backend = require "plugins.sql_server.backend"
    local settings
    backend.execute = function(_, _, done, options)
      settings = options
      done({ results = {}, affected_rows = {}, messages = {} })
      return { cancel = function() end }
    end
    editor.buffer:text_input("SELECT 1")
    editor.buffer:set_selection(1, 1, 1, math.huge)
    test.ok(command.perform("sql_server:run_selection"))
    test.equal(test.not_nil(settings).timeout, 0)
    test.ok(command.perform("sql_server:set_timeout"))
    test.equal(core.active_view, core.global_prompt_bar)
    core.global_prompt_bar:set_text("45")
    core.global_prompt_bar:submit()
    test.equal(core.active_view, editor)
    editor.buffer:set_selection(1, 1, 1, math.huge)
    test.ok(command.perform("sql_server:run_selection"))
    test.equal(settings.timeout, 45)
    local script = string.rep("PRINT N'" .. string.rep("x", 100) .. "'\nGO\n", 3000)
    editor.buffer:set_selection(1, 1, 1, math.huge)
    editor.buffer:text_input(script)
    settings = nil
    test.ok(command.perform("sql_server:run_buffer"))
    test.ok(#script > 256 * 1024 and test.not_nil(settings).timeout == 45)
  end)

  test.it("adjusts the Query's row limit from the result footer for the next run", function(context)
    local editor = connected_query(context)
    local context_menu = require "core.context_menu"
    local limits = {}
    require("plugins.sql_server.backend").execute = function(_, _, callback, settings)
      limits[#limits + 1] = settings.max_rows
      callback({ results = { { headers = { "id" }, column_count = 1, distinct_values = {},
        rows = { { cells = { "1" }, source_line1 = 1, source_line2 = 1 } } } }, affected_rows = {}, messages = {} })
      return { cancel = function() end }
    end
    editor.buffer:text_input("SELECT 1")
    editor.buffer:set_selection(1, 1, 1, 9)
    test.ok(command.perform("sql_server:run_selection"))
    local result = editor.buffer.sql_execution.view
    local function press(label)
      for _, b in ipairs(result:footer_buttons()) do
        if b.label == label then return result:on_mouse_pressed("left", b.x + 1, b.y + 1, 1) end
      end
      error("no footer button " .. label)
    end
    test.equal(limits[1], 1000)
    test.ok(press("Limit 1,000"))
    test.ok(context_menu.is_open())
    test.same(context_menu.labels(), { "Limit 100", "Limit 1,000", "Limit 10,000", "No Row Limit" })
    test.ok(context_menu.choose("Limit 100"))
    test.ok(command.perform("sql_server:run_selection"))
    test.equal(limits[2], 100)
    test.ok(press("Limit 100"))
    test.ok(context_menu.choose("No Row Limit"))
    test.ok(command.perform("sql_server:run_selection"))
    test.equal(limits[3], require("plugins.sql_server").ROW_LIMIT_MAX)
    test.ok(press("JSON"))
    test.equal(core.active_view.buffer:get_text(1, 1, math.huge, math.huge), '[\n  {"id": "1"}\n]\n')
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

  test.it("keeps one session per SQL Query and asks before its open transaction ends", function(context)
    local editor, c = connected_query(context)
    local backend = require "plugins.sql_server.backend"
    local sql = require "plugins.sql_server"
    context.original_end, context.original_close = backend.end_transaction, backend.close_session
    context.nag_show = core.nag_view.show
    local runs, ended, closed, question = {}, {}, {}, nil
    backend.execute = function(_, text, callback, settings)
      runs[#runs + 1] = { text = text, settings = settings }
      callback({ results = {}, session = 7, transaction_count = text:find("INSERT") and 1 or 0,
        messages = { { text = "(1 row affected)" } } })
      return { cancel = function() end }
    end
    backend.end_transaction = function(session, commit, callback)
      ended[#ended + 1] = { session = session, commit = commit }
      callback(0)
      return { cancel = function() end }
    end
    backend.close_session = function(session) closed[#closed + 1] = session end
    core.nag_view.show = function(_, title, _, _, callback) question = { title = title, answer = callback } end
    editor.buffer:text_input("INSERT sales.customers (name) VALUES (N'Ada')")
    test.ok(command.perform("sql_server:toggle_auto_commit"))
    test.ok(command.perform("sql_server:run_buffer"))
    test.equal(runs[1].settings.session, nil)
    test.equal(runs[1].settings.autocommit, false)
    test.ok(command.perform("sql_server:run_buffer"))
    test.equal(runs[2].settings.session, 7)

    test.ok(command.perform("sql_server:disconnect"))
    test.equal(test.not_nil(question).title, "Open Transaction")
    question.answer({ text = "Cancel" })
    test.same(ended, {})
    test.equal(c.state, "Ready")
    test.ok(command.perform("sql_server:commit"))
    test.same(ended, { { session = 7, commit = true } })

    test.ok(command.perform("sql_server:run_buffer"))
    question = nil
    local pane = panes.pane_for_view(editor)
    panes.close(pane)
    test.equal(test.not_nil(question).title, "Open Transaction")
    test.ok(panes.pane_for_view(editor))
    question.answer({ text = "Roll Back" })
    test.same(ended[2], { session = 7, commit = false })
    test.same(closed, {})
    sql.disconnect(c.id)
    test.same(closed, { 7 })
  end)

  test.it("shows server messages in order and moves the caret to the line of an error after edits", function(context)
    local editor = connected_query(context)
    require("plugins.sql_server.backend").execute = function(_, _, callback)
      callback({ results = {}, error = "Line 3: Invalid column name 'nam'.", error_line = 3, messages = {
        { text = "first" }, { text = "Msg 207, Level 16, State 1, Line 3\nInvalid column name 'nam'.", line = 3, error = true } } })
      return { cancel = function() end }
    end
    editor.buffer:text_input("-- note\nPRINT 'first'\nGO\nSELECT nam\nFROM sales.customers")
    editor.buffer:set_selection(2, 1, 5, 21)
    test.ok(command.perform("sql_server:run_selection"))
    local results = test.not_nil(editor.buffer.sql_results)
    test.equal(results:messages_text(), "first\nMsg 207, Level 16, State 1, Line 3\nInvalid column name 'nam'.")
    test.ok(command.perform("sql_server:go_to_error"))
    test.equal(select(1, editor.buffer:get_selection()), 4)
    editor.buffer:insert(1, 1, "-- added\n")
    test.ok(command.perform("sql_server:go_to_error"))
    test.equal(select(1, editor.buffer:get_selection()), 5)
  end)

  test.it("asks before an UPDATE or DELETE without WHERE, and before each change on a production connection", function(context)
    local sql = require "plugins.sql_server"
    local editor, c = connected_query(context)
    local submitted, question = {}, nil
    require("plugins.sql_server.backend").execute = function(_, text, callback)
      submitted[#submitted + 1] = text
      callback({ results = {}, affected_rows = {}, messages = {} })
      return { cancel = function() end }
    end
    context.nag_show = core.nag_view.show
    core.nag_view.show = function(_, title, text, _, callback) question = { title = title, text = text, answer = callback } end
    local function run(text, line1)
      question = nil
      panes.focus(panes.pane_for_view(editor))
      editor.buffer:set_selection(1, 1, math.huge, math.huge)
      editor.buffer:text_input(text)
      editor.buffer:set_selection(line1 or 1, 1, math.huge, math.huge)
      return command.perform("sql_server:run_selection")
    end
    test.ok(run("-- note\nSELECT 1\nDELETE FROM sales.customers", 2))
    test.equal(#submitted, 0)
    test.equal(test.not_nil(question).title, "DELETE without WHERE")
    test.ok(question.text:find("line 3", 1, true))
    question.answer({ text = "Cancel" })
    test.equal(#submitted, 0)
    test.ok(run("UPDATE sales.customers SET name = N'x'"))
    test.equal(test.not_nil(question).title, "UPDATE without WHERE")
    question.answer({ text = "Run" })
    test.same(submitted, { "UPDATE sales.customers SET name = N'x'" })
    test.ok(run("DELETE FROM sales.customers WHERE id = 1"))
    test.equal(question, nil)
    test.equal(#submitted, 2)

    -- A production connection asks before each change, and keeps its session when the flag changes.
    test.ok(sql.update(c.id, "production", true))
    test.equal(c.state, "Ready")
    test.ok(run("DELETE FROM sales.customers WHERE id = 1"))
    test.equal(test.not_nil(question).title, "Production Connection")
    test.equal(#submitted, 2)
    question.answer({ text = "Run" })
    test.equal(#submitted, 3)
    test.ok(run("SELECT * FROM sales.customers"))
    test.equal(question, nil)
    test.equal(#submitted, 4)
  end)

  test.it("keeps a result with its SQL and display state while a new run replaces the live result", function(context)
    local sql = require "plugins.sql_server"
    local editor, c = connected_query(context)
    local Results = require "plugins.sql_server.results"
    local parser = require "plugins.tabular_data_preview.parser"
    local function model(names)
      local result = { headers = { "name" }, column_count = 1, rows = {} }
      for i, name in ipairs(names) do result.rows[i] = { cells = { name }, source_line1 = i, source_line2 = i } end
      result.distinct_values = parser.distinct_values(result)
      return result
    end
    local reply = { model({ "Ada", "Bea", "Cy" }) }
    require("plugins.sql_server.backend").execute = function(_, _, callback)
      callback({ results = reply, affected_rows = {}, messages = {} })
      return { cancel = function() end }
    end
    editor.buffer:text_input("SELECT name FROM sales.customers")
    editor.buffer:set_selection(1, 1, 1, math.huge)
    test.ok(command.perform("sql_server:run_selection"))
    local live = editor.buffer.sql_results
    panes.focus(panes.pane_for_view(live))
    test.ok(live:toggle_filter_value(1, "Ada"))
    test.ok(live:toggle_filter_value(1, "Bea"))
    live:cycle_sort(1); live:cycle_sort(1)
    test.ok(command.perform("sql_server:keep_result"))
    test.equal(core.active_view, live)
    local kept
    for _, pane in ipairs(panes.ordered()) do
      for _, view in ipairs(panes.views(pane)) do
        if view:extends(Results) and view ~= live then kept = view end
      end
    end
    test.not_nil(kept)
    local function shown(view)
      local names = {}
      for row = 1, view:row_count() do names[row] = view:cell_value(row, 1) end
      return table.concat(names, " ")
    end
    test.equal(shown(kept), "Bea Ada")
    test.ok(kept:get_name():find("Kept", 1, true))

    -- A new run of changed SQL replaces only the live result.
    reply = { model({ "Dee" }) }
    panes.focus(panes.pane_for_view(editor))
    editor.buffer:set_selection(1, 1, 1, math.huge)
    editor.buffer:text_input("SELECT name FROM sales.customers WHERE 1 = 1")
    editor.buffer:set_selection(1, 1, 1, math.huge)
    test.ok(command.perform("sql_server:run_selection"))
    test.equal(editor.buffer.sql_results, live)
    test.equal(shown(live), "Dee")
    test.equal(shown(kept), "Bea Ada")

    -- A kept result does not change, and its SQL opens on its connection.
    panes.focus(panes.pane_for_view(kept))
    test.not_ok(command.is_valid("sql_server:edit_cell"))
    local sql_button
    for _, b in ipairs(kept:footer_buttons()) do if b.id == "sql" then sql_button = b end end
    test.ok(kept:press_footer_button(test.not_nil(sql_button)))
    local query = core.active_view
    test.equal(query.buffer:get_text(1, 1, math.huge, math.huge), "SELECT name FROM sales.customers")
    test.equal(sql.connection_for(query.buffer).id, c.id)
  end)

  test.it("shows every row of the next result in fitted columns, without the previous result's filter", function()
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
    local long = "Beatrice Alexandra Montgomery"
    view:complete({ results = { model({ "Ada", "Bea" }), model({ "Ada", long }) } })
    local narrow = view.column_widths[1]
    test.ok(view:toggle_filter_value(1, "Ada"))
    test.ok(command.perform("sql_server:next_result"))
    test.equal(view:row_count(), 2)
    test.equal(view:cell_value(2, 1), long)
    test.ok(view.column_widths[1] > narrow)
    view:cycle_sort(1); view:cycle_sort(1)
    -- Each result keeps its own filter, sort and widths.
    test.ok(command.perform("sql_server:previous_result"))
    test.equal(view:row_count(), 1)
    test.equal(view.column_widths[1], narrow)
    test.ok(command.perform("sql_server:next_result"))
    test.equal(view:cell_value(1, 1), long)
    -- A new run starts again.
    view:complete({ results = { model({ "Ada", "Bea" }) } })
    test.equal(view:row_count(), 2)
  end)

  test.it("summarizes the shown rows, the columns and the run time in the footer", function(context)
    local Results = require "plugins.sql_server.results"
    local result = { headers = { "name", "city" }, column_count = 2, rows = {} }
    for i, name in ipairs({ "Ada", "Bea", "Cy" }) do
      result.rows[i] = { cells = { name, "Lisbon" }, source_line1 = i, source_line2 = i }
    end
    result.distinct_values = require("plugins.tabular_data_preview.parser").distinct_values(result)
    local view = Results("Test")
    panes.place(function() return view end, { placement = "new", focus = true })
    view:complete({ results = { result }, seconds = 0.0123 })
    test.equal((view:footer_summary()), "3 rows · 2 columns · 12 ms")
    test.ok(view:toggle_filter_value(1, "Bea"))
    test.equal((view:footer_summary()), "1 of 3 rows · 2 columns · 12 ms")

    -- A run measures its time.
    local editor = connected_query(context)
    require("plugins.sql_server.backend").execute = function(_, _, done)
      done({ session = 7, results = { result }, messages = {}, transaction_count = 0 })
      return { cancel = function() end }
    end
    editor.buffer:text_input("SELECT name, city FROM sales.customers")
    editor.buffer:set_selection(1, 1, 1, math.huge)
    test.ok(command.perform("sql_server:run_selection"))
    test.ok((editor.buffer.sql_execution.view:footer_summary()):match("^%d+ rows? · 2 columns · %d+ ms$"))
  end)

  test.it("sorts a number column by value and a text column as text", function()
    local Results = require "plugins.sql_server.results"
    local values = { "10", "9", "-2.5", "-10", "0.75", "100000000000000000001", "100000000000000000000", "1E+3" }
    local result = { headers = { "n", "t" }, column_kinds = { "number", "text" }, column_count = 2, rows = {} }
    for i, value in ipairs(values) do
      result.rows[i] = { cells = { value, value }, source_line1 = i, source_line2 = i }
    end
    result.distinct_values = require("plugins.tabular_data_preview.parser").distinct_values(result)
    local view = Results("Test")
    panes.place(function() return view end, { placement = "new", focus = true })
    view:complete({ results = { result } })
    local function column(index)
      local shown = {}
      for row = 1, view:row_count() do shown[row] = view:cell_value(row, index) end
      return table.concat(shown, " ")
    end
    view:cycle_sort(1)
    test.equal(column(1), "-10 -2.5 0.75 9 10 1E+3 100000000000000000000 100000000000000000001")
    view:cycle_sort(2)
    test.equal(column(2), "-10 -2.5 0.75 10 100000000000000000000 100000000000000000001 1E+3 9")
  end)

  test.it("draws NULL apart from the text NULL, numbers at the right, and the start of a clipped value", function()
    local Results = require "plugins.sql_server.results"
    local result = { headers = { "n", "t" }, column_kinds = { "number", "text" }, column_count = 2,
      missing_label = "NULL", rows = {
        { cells = { "7", false }, source_line1 = 1, source_line2 = 1 },
        { cells = { "12345", "NULL" }, source_line1 = 2, source_line2 = 2 },
        { cells = { "1234567890123456789012345678901234567890", "x" }, source_line1 = 3, source_line2 = 3 },
      } }
    result.distinct_values = require("plugins.tabular_data_preview.parser").distinct_values(result)
    local view = Results("Test")
    panes.place(function() return view end, { placement = "new", focus = true })
    view:complete({ results = { result } })
    view.position, view.size = { x = 0, y = 0 }, { x = 600, y = 300 }
    view.column_widths[1] = view:min_column_width()
    view:rebuild_column_offsets()
    local drawn, saved = {}, { renderer.draw_text, renderer.draw_rect, renderer.set_clip_rect }
    renderer.draw_text = function(font, text, x, y, color)
      drawn[#drawn + 1] = { text = text, x = x, y = y, color = color }
      return x + font:get_width(text)
    end
    renderer.draw_rect = function() end
    renderer.set_clip_rect = function() end
    local ok, err = pcall(function() view:draw_body() end)
    renderer.draw_text, renderer.draw_rect, renderer.set_clip_rect = saved[1], saved[2], saved[3]
    test.ok(ok, err)
    local function find(text, row)
      local _, y, _, h = view:cell_screen_rect(row, 1)
      for _, call in ipairs(drawn) do
        if call.text == text and call.y >= y and call.y < y + h then return call end
      end
    end
    local null, text_null = test.not_nil(find("NULL", 1)), test.not_nil(find("NULL", 2))
    test.not_equal(table.concat(null.color, ","), table.concat(text_null.color, ","))
    local font = require("core.style").code_font
    local seven, large = test.not_nil(find("7", 1)), test.not_nil(find("12345", 2))
    test.equal(seven.x + font:get_width("7"), large.x + font:get_width("12345"))
    -- A value wider than its cell shows its first characters and a mark.
    local x, y, w, h = view:cell_screen_rect(3, 1)
    local clipped
    for _, call in ipairs(drawn) do
      if call.y >= y and call.y < y + h and call.x >= x and call.x < x + w then clipped = call end
    end
    test.not_nil(clipped)
    test.ok(clipped.text:match("^1234.*…$"), clipped.text)
    test.ok(clipped.x + font:get_width(clipped.text) <= x + w)
  end)

  test.it("offers the foreign keys' join conditions first at the start of a JOIN's ON", function(context)
    local function columns(...)
      local result = {}
      for i, name in ipairs({ ... }) do result[i] = { name = name, type = "int" } end
      return result
    end
    local editor = connected_query(context, {
      database = "AnvilTest", default_schema = "dbo", case_sensitive = false,
      objects = {
        schema.objects[1], schema.objects[2],
        { schema = "sales", name = "lines", kind = "table", columns = columns("order_id", "line_no") },
        { schema = "sales", name = "notes", kind = "table", columns = columns("order_id", "line_no") },
        { schema = "dbo", name = "staff", kind = "table", columns = columns("id", "manager_id") },
      },
      foreign_keys = {
        schema.foreign_keys[1],
        { name = "FK_notes_lines", schema = "sales", table = "notes", columns = { "order_id", "line_no" },
          ref_schema = "sales", ref_table = "lines", ref_columns = { "order_id", "line_no" } },
        { name = "FK_staff_manager", schema = "dbo", table = "staff", columns = { "manager_id" },
          ref_schema = "dbo", ref_table = "staff", ref_columns = { "id" } },
      },
    })
    local function type_line(text)
      editor.buffer:set_selection(1, 1, 1, math.huge)
      for char in text:gmatch(".") do core.on_event("textinput", char) end
    end
    local function selected() return autocomplete.get_selected_suggestion().text end
    type_line("SELECT * FROM sales.customers c JOIN dbo.orders o ON ")
    test.ok(autocomplete.is_open())
    test.equal(selected(), "c.id = o.customer_id")
    test.ok(command.perform("autocomplete:complete"))
    test.equal(editor.buffer.lines[1]:gsub("\n$", ""), "SELECT * FROM sales.customers c JOIN dbo.orders o ON c.id = o.customer_id")

    -- The earlier source comes first, whichever end of the key it is.
    type_line("SELECT * FROM dbo.orders o JOIN sales.customers c ON ")
    test.equal(selected(), "o.customer_id = c.id")
    type_line("SELECT * FROM sales.notes n JOIN sales.lines l ON ")
    test.equal(selected(), "n.order_id = l.order_id AND n.line_no = l.line_no")
    type_line("SELECT * FROM staff e JOIN staff m ON ")
    test.equal(selected(), "e.manager_id = m.id")
    test.ok(command.perform("autocomplete:next"))
    test.equal(selected(), "e.id = m.manager_id")
    test.ok(command.perform("autocomplete:next"))
    -- The columns follow.
    test.equal(selected(), "id")
  end)

  test.it("completes a typed variable from the batch's declarations", function(context)
    local editor = connected_query(context)
    local function type_text(text)
      for char in text:gmatch(".") do core.on_event("textinput", char) end
    end
    editor.buffer:set_selection(1, 1)
    editor.buffer:insert(1, 1, "DECLARE @limit int = 10, @Name nvarchar(80);\n")
    editor.buffer:set_selection(2, 1)
    type_text("SELECT TOP (@l")
    test.ok(autocomplete.is_open())
    test.equal(autocomplete.get_selected_suggestion().text, "@limit")
    test.equal(autocomplete.get_selected_suggestion().desc, "int")
    test.ok(command.perform("autocomplete:complete"))
    type_text(") * FROM sales.customers WHERE name = @")
    test.equal(autocomplete.get_selected_suggestion().text, "@limit")
    type_text("n")
    test.equal(autocomplete.get_selected_suggestion().text, "@Name")
    test.ok(command.perform("autocomplete:complete"))
    test.equal(editor.buffer.lines[2]:gsub("\n$", ""), "SELECT TOP (@limit) * FROM sales.customers WHERE name = @Name")
    -- A new declaration's name gets no list.
    editor.buffer:set_selection(1, 1)
    type_text("DECLARE @l")
    test.not_ok(autocomplete.is_open())
  end)

  test.it("offers built-in functions after the matching columns, with the caret in their arguments", function(context)
    local editor = connected_query(context)
    local function type_line(text)
      editor.buffer:set_selection(1, 1, 1, math.huge)
      for char in text:gmatch(".") do core.on_event("textinput", char) end
    end
    local function line() return (editor.buffer.lines[1]:gsub("\n$", "")) end
    local function selected() return autocomplete.get_selected_suggestion() end
    type_line("SELECT * FROM sales.customers WHERE n")
    test.equal(selected().text, "name")
    test.ok(command.perform("autocomplete:next"))
    test.equal(selected().text, "NEWID")
    type_line("SELECT cou")
    test.equal(selected().text, "COUNT")
    test.equal(selected().desc, "(expression)")
    test.ok(command.perform("autocomplete:complete"))
    for char in ("*"):gmatch(".") do core.on_event("textinput", char) end
    test.equal(line(), "SELECT COUNT(*)")
    -- A function without arguments leaves the caret after it. Functions follow the keywords' case.
    type_line("select getd")
    test.equal(selected().text, "getdate")
    test.ok(command.perform("autocomplete:complete"))
    test.equal(line(), "select getdate()")
    test.same({ editor.buffer:get_selection() }, { 1, #"select getdate()" + 1, 1, #"select getdate()" + 1 })
    type_line("SELECT @@ro")
    test.equal(selected().text, "@@ROWCOUNT")
  end)

  test.it("offers a procedure's remaining parameters in its EXEC arguments", function(context)
    local editor = connected_query(context, {
      database = "AnvilTest", default_schema = "dbo", case_sensitive = false,
      objects = {
        schema.objects[1], schema.objects[2],
        { schema = "sales", name = "find_customer", kind = "procedure", parameters = {
          { name = "@id", type = "int", output = false },
          { name = "@label", type = "nvarchar(80)", output = true },
          { name = "@amount", type = "decimal(19,4)", output = false },
        } },
      },
      foreign_keys = {},
    })
    local function type_line(text)
      editor.buffer:set_selection(1, 1, 1, math.huge)
      for char in text:gmatch(".") do core.on_event("textinput", char) end
    end
    local function selected() return autocomplete.get_selected_suggestion() end
    type_line("EXEC sales.find_customer ")
    test.ok(autocomplete.is_open())
    test.equal(selected().text, "@id")
    test.equal(selected().desc, "int")
    test.ok(command.perform("autocomplete:complete"))
    test.equal(editor.buffer:get_text(1, 1, 1, math.huge):gsub("\n$", ""), "EXEC sales.find_customer @id = ")
    type_line("EXEC sales.find_customer @id = 1, ")
    test.equal(selected().text, "@label")
    test.equal(selected().desc, "nvarchar(80) OUTPUT")
    type_line("EXEC sales.find_customer 1, @a")
    test.equal(selected().text, "@amount")
    type_line("EXEC sales.find_customer 1, 'x', @amount = 2, ")
    test.ok(not autocomplete.is_open())
  end)

  test.it("offers table-valued functions as sources, with the caret in their arguments", function(context)
    local editor = connected_query(context, {
      database = "AnvilTest", default_schema = "dbo", case_sensitive = false,
      objects = {
        schema.objects[1], schema.objects[2],
        { schema = "sales", name = "customers_from", kind = "function", table_valued = true,
          parameters = { { name = "@first", type = "int", output = false } },
          columns = { { name = "id", type = "int" }, { name = "label", type = "nvarchar(80)" } } },
        { schema = "sales", name = "customer_count", kind = "function", table_valued = false, parameters = {}, columns = {} },
      },
      foreign_keys = {},
    })
    local function type_line(text)
      editor.buffer:set_selection(1, 1, 1, math.huge)
      for char in text:gmatch(".") do core.on_event("textinput", char) end
    end
    local function line() return (editor.buffer:get_text(1, 1, 1, math.huge):gsub("\n$", "")) end
    type_line("SELECT * FROM sales.cust")
    test.equal(autocomplete.get_selected_suggestion().text, "customers")
    test.ok(command.perform("autocomplete:next"))
    local item = autocomplete.get_selected_suggestion()
    test.equal(item.text, "customers_from")
    test.equal(item.desc, "sales.customers_from (@first int)")
    test.ok(command.perform("autocomplete:complete"))
    test.equal(line(), "SELECT * FROM sales.customers_from()")
    local _, col = editor.buffer:get_selection()
    test.equal(col, #"SELECT * FROM sales.customers_from(" + 1)
    type_line("SELECT * FROM sales.customers_from(1) c WHERE c.la")
    test.equal(autocomplete.get_selected_suggestion().text, "label")
  end)

  test.it("ranks names that start with the typed text before names that only contain it", function(context)
    local editor = connected_query(context)
    local function type_line(text)
      editor.buffer:set_selection(1, 1, 1, math.huge)
      for char in text:gmatch(".") do core.on_event("textinput", char) end
    end
    local function selected() return autocomplete.get_selected_suggestion().text end
    type_line("SELECT * FROM sales.customers c JOIN dbo.orders o ON c.id = o.customer_id WHERE i")
    test.equal(selected(), "id")
    test.ok(command.perform("autocomplete:next"))
    test.equal(selected(), "customer_id")
  end)

  test.it("opens the table of an alias from the alias's declaration", function(context)
    local editor = connected_query(context)
    editor.buffer:text_input("SELECT * FROM sales.customers AS c")
    editor.buffer:set_selection(1, math.huge)
    test.ok(require("core.commands.language").activate_symbol(editor))
    test.ok(core.active_view.buffer:get_text(1, 1, math.huge, math.huge):find("CREATE TABLE [sales].[customers]", 1, true))
  end)

  test.it("opens a table definition and returns to the same Untitled Query", function(context)
    local editor = connected_query(context)
    editor.buffer:text_input("SELECT * FROM sales.customers")
    editor.buffer:set_selection(1, #"SELECT * FROM sales." + 1)
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

  test.it("opens a symbol's actions with its default first and runs a generated SELECT", function(context)
    local editor = connected_query(context)
    local context_menu = require "core.context_menu"
    editor.buffer:text_input("SELECT * FROM sales.customers")
    editor.buffer:set_selection(1, #"SELECT * FROM sales.cus" + 1)
    local items = editor:context_menu()
    test.equal(items[1].label, "sales.customers")
    test.equal(items[1].items[1].label, "Script as SELECT")
    local view_items = require("plugins.sql_server.source").action_items(editor,
      { schema = "dbo", name = "recent", kind = "view", columns = {} })
    test.equal(view_items[1].label, "Script as ALTER")
    local submitted, settings
    require("plugins.sql_server.backend").execute = function(_, sql, done, options)
      submitted, settings = sql, options
      done({ results = {}, affected_rows = {}, messages = {} })
      return { cancel = function() end }
    end
    test.ok(command.perform("sql_server:symbol_actions"))
    test.ok(context_menu.is_open())
    test.equal(context_menu.selected_label(), "Script as SELECT")
    test.ok(context_menu.choose("Script as SELECT"))
    local generated = core.active_view
    test.not_equal(generated, editor)
    test.equal(generated.buffer:get_text(1, 1, math.huge, math.huge), "SELECT [id], [name]\nFROM [sales].[customers];")
    test.equal(submitted, "SELECT [id], [name]\nFROM [sales].[customers];")
    test.not_nil(settings)
    test.equal(editor.buffer:get_text(1, 1, math.huge, math.huge), "SELECT * FROM sales.customers")
  end)

  test.it("formats the selected lines, or the Buffer without a selection, in one undo step", function()
    local config = require "core.config"
    test.ok(command.perform("sql_server:new_query"))
    local editor = core.active_view
    local i = config.tab_type == "hard" and "\t" or string.rep(" ", config.indent_size)
    local original = "select a from t\nselect c from u where x = 1 and y = 2\n-- tail"
    editor.buffer:text_input(original)
    editor.buffer:set_selection(2, 3, 2, 12)
    test.ok(command.perform("sql_server:format"))
    test.equal(editor.buffer:get_text(1, 1, math.huge, math.huge), "select a from t\nSELECT\n" .. i .. "c\nFROM\n" ..
      i .. "u\nWHERE\n" .. i .. "x = 1\nAND y = 2\n-- tail")
    editor.buffer:undo()
    test.equal(editor.buffer:get_text(1, 1, math.huge, math.huge), original)
    editor.buffer:set_selection(3, 1)
    test.ok(command.perform("sql_server:format"))
    test.equal(editor.buffer:get_text(1, 1, math.huge, math.huge), "SELECT\n" .. i .. "a\nFROM\n" .. i .. "t\nSELECT\n" ..
      i .. "c\nFROM\n" .. i .. "u\nWHERE\n" .. i .. "x = 1\nAND y = 2\n-- tail")
    editor.buffer:undo()
    editor.buffer.read_only = true
    command.perform("sql_server:format")
    test.equal(editor.buffer:get_text(1, 1, math.huge, math.huge), original)
  end)

  test.it("does not navigate an unknown column to an unrelated table", function(context)
    local editor = connected_query(context)
    editor.buffer:text_input("SELECT missing FROM sales.customers")
    editor.buffer:set_selection(1, #"SELECT missing" + 1)
    test.not_ok(require("core.commands.language").activate_symbol(editor))
    test.equal(core.active_view, editor)
  end)
  test.it("expands a SELECT star using its source columns and undoes it in one step", function(context)
    local editor = connected_query(context)
    editor.buffer:text_input("SELECT c.* FROM sales.customers c")
    editor.buffer:set_selection(1, #"SELECT c.*" + 1)
    test.ok(command.perform("sql_server:expand_star"))
    test.equal(editor.buffer:get_text(1, 1, math.huge, math.huge), "SELECT c.id, c.name FROM sales.customers c")
    editor.buffer:undo()
    test.equal(editor.buffer:get_text(1, 1, math.huge, math.huge), "SELECT c.* FROM sales.customers c")
  end)

  test.it("lists database objects in File Search after the files, and previews and opens their definition", function(context)
    local _, c = connected_query(context)
    local sql = require "plugins.sql_server"
    sql.disconnect(c.id)
    local plain = require("core.editor")(core.open_buffer())
    panes.place(function() return plain end, { placement = "new", focus = true })
    local picker, index = search_until("fuzzy:open_files", "customers", "Connect")
    test.not_nil(picker)
    test.ok(picker.results[index - 1].header)
    test.equal(picker.results[index - 1].label, "New Connection")
    picker.selected = index
    picker:confirm()
    picker, index = search_until(nil, "customers", "sales.customers")
    test.not_nil(picker)
    test.equal(c.state, "Ready")
    test.equal(sql.connection_for(plain.buffer), nil)
    picker.selected = index
    local preview = wait_preview(picker)
    test.ok(preview.buffer:get_text(1, 1, math.huge, math.huge):find("CREATE TABLE [sales].[customers]", 1, true))
    picker:confirm()
    local deadline = system.get_time() + 10
    while not core.active_view.buffer.read_only and system.get_time() < deadline do coroutine.yield(0.01) end
    test.ok(core.active_view.buffer.read_only)
    test.ok(core.active_view.buffer:get_text(1, 1, math.huge, math.huge):find("CREATE TABLE", 1, true))
    test.equal(sql.connection_for(core.active_view.buffer), c)
    local object = schema.objects[1]
    test.ok(command.is_valid("sql_server:script_object", c, object, "select"))
    sql.disconnect(c.id)
    test.not_ok(command.is_valid("sql_server:script_object", c, object, "select"))
  end)

  test.it("lists columns in Project Symbol Search and opens the definition at the column", function(context)
    connected_query(context)
    local picker, index = search_until("fuzzy:open_symbols", "$customers.name", "name")
    test.not_nil(picker)
    test.equal(picker.results[index].location_label, "sales.customers")
    for _, result in ipairs(picker.results) do test.not_equal(result.label, "sales.customers") end
    picker.selected = index
    local preview = wait_preview(picker)
    local line = preview.buffer:get_selection()
    test.equal(preview.buffer.lines[line], "  [name] nvarchar(80) NULL\n")
    picker:confirm()
    local deadline = system.get_time() + 10
    while not core.active_view.buffer.read_only and system.get_time() < deadline do coroutine.yield(0.01) end
    test.ok(core.active_view.buffer.read_only)
    test.equal((core.active_view.buffer:get_selection()), line)
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
    test.ok(#table.concat(text) > 0)
    open:close()
    test.equal(open.password:get_text(), "")
  end)
end)
