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
    if context.original_end then require("plugins.sql_server.backend").end_transaction = context.original_end end
    if context.original_close then require("plugins.sql_server.backend").close_session = context.original_close end
    if context.nag_show then core.nag_view.show = context.nag_show end
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
    test.equal(core.active_view, core.global_prompt_bar)
    test.equal(core.global_prompt_bar:get_text(), "Bea")
    core.global_prompt_bar:set_text("Bea O'Neil")
    core.global_prompt_bar:submit()
    test.equal(core.active_view, result)
    test.equal(result:cell_value(2, 2), "Bea O'Neil")
    result:select_cell(1, 3, false)
    command.perform("sql_server:edit_cell")
    test.equal(core.active_view, result)
    result:select_cell(3, 1, false)
    test.ok(command.perform("sql_server:delete_rows"))
    result:select_cell(1, 2, false)
    test.ok(command.perform("sql_server:set_cell_null"))
    test.equal(result:cell_value(1, 2), false)
    local labels = {}
    for _, b in ipairs(result:footer_buttons()) do labels[#labels + 1] = b.label end
    test.equal(labels[1], "Script 3 Changes")
    test.ok(command.perform("sql_server:script_changes"))
    local script = core.active_view
    test.not_equal(script, result)
    test.equal(require("plugins.sql_server").connection_for(script.buffer), require("plugins.sql_server").connection_for(editor.buffer))
    test.equal(script.buffer:get_text(1, 1, math.huge, math.huge), table.concat({
      "-- Changes to [sales].[customers] from SQL Results. Review them, then run this script.",
      "SET XACT_ABORT ON;",
      "BEGIN TRANSACTION;",
      "UPDATE [sales].[customers] SET [name] = NULL WHERE [id] = N'1';",
      "IF @@ROWCOUNT <> 1 THROW 50001, N'Row 1 changed or no longer exists.', 1;",
      "UPDATE [sales].[customers] SET [name] = N'Bea O''Neil' WHERE [id] = N'2';",
      "IF @@ROWCOUNT <> 1 THROW 50001, N'Row 2 changed or no longer exists.', 1;",
      "DELETE FROM [sales].[customers] WHERE [id] = N'3';",
      "IF @@ROWCOUNT <> 1 THROW 50001, N'Row 3 changed or no longer exists.', 1;",
      "COMMIT TRANSACTION;",
      "",
    }, "\n"))
    test.equal(#submitted, 2)

    local _, reason = require("plugins.sql_server.edit").analyze({ column_count = 1 }, { results = { {
      headers = describe_headers, rows = { described("id", "id", true, true, false, "int"),
        described("who", "name", false, false, true, "nvarchar(80)") } } } })
    test.equal(reason, "Include the key column [id] to edit this result.")
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

  test.it("shows server messages in order and moves the caret to the line of an error", function(context)
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

  test.it("finds database symbols with Project Symbol Search and opens their source", function(context)
    local _, c = connected_query(context)
    local sql = require "plugins.sql_server"
    sql.disconnect(c.id)
    local editor = sql.new_query()
    editor.buffer:text_input("SELECT 1;")
    test.ok(command.perform("fuzzy:open_symbols"))
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    local deadline = system.get_time() + 10
    local chose_connection
    while system.get_time() < deadline and not (picker.results[1] and picker.results[1].label == "sales.customers") do
      if core.active_view == core.global_prompt_bar then
        chose_connection = true
        core.global_prompt_bar:submit()
      end
      picker = core.fuzzy_searcher_active_view or picker
      if not picker.closed and not picker.closing then picker.input:set_text("$customers"); picker:update() end
      coroutine.yield(0.01)
    end
    test.ok(chose_connection)
    test.equal(sql.connection_for(editor.buffer), c)
    test.equal(test.not_nil(picker.results[1]).label, "sales.customers")
    picker:confirm()
    test.ok(core.active_view.buffer.read_only)
    test.ok(core.active_view.buffer:get_text(1, 1, math.huge, math.huge):find("CREATE TABLE", 1, true))
    test.ok(command.perform("core:navigate_back"))
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
    test.ok(#table.concat(text) > 0)
    open:close()
    test.equal(open.password:get_text(), "")
  end)
end)
