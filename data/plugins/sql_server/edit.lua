-- Result editing. Edits stay in the results View until the user scripts them.
-- The script opens in a new SQL Query and runs nothing, so the user reviews it
-- and runs it like other SQL. SQL Server describes the result's source table
-- and key with sp_describe_first_result_set in browse mode. That call runs
-- nothing and opens no transaction.
local core = require "core"
local M = {}

local function quote(name) return "[" .. name:gsub("]", "]]") .. "]" end
local function literal(value)
  if value == false then return "NULL" end
  return "N'" .. value:gsub("'", "''") .. "'"
end
-- Types that a Unicode string literal cannot set without a change of value or type.
local function binary(type_name)
  local t = type_name:lower()
  return t:find("^varbinary") or t:find("^binary") or t == "image" or t == "timestamp" or t == "rowversion"
    or t == "geography" or t == "geometry" or t == "hierarchyid" or t == "sql_variant"
end
-- Types whose server text does not compare exactly, or that `=` refuses.
local function inexact(type_name)
  local t = type_name:lower()
  return t == "float" or t:find("^float%(") or t == "real" or t == "xml" or t == "text" or t == "ntext"
end
local function condition(column, value)
  return quote(column) .. (value == false and " IS NULL" or " = " .. literal(value))
end

-- The target table, its key columns and the editable columns of a result, from
-- the describe reply. Returns nil and a reason when the result is not editable.
function M.analyze(model, data)
  if data.error then return nil, (data.error:gsub("\n.*", "")) end
  local t = data.results and data.results[1]
  if not t then return nil, "SQL Server did not describe this result." end
  local index = {}
  for i, header in ipairs(t.headers) do index[header] = i end
  local entries, visible = {}, {}
  for _, row in ipairs(t.rows) do
    local function field(name)
      local value = index[name] and row.cells[index[name]]
      return value ~= false and value or nil
    end
    local entry = { schema = field("source_schema"), table = field("source_table"), column = field("source_column"),
      key = field("is_part_of_unique_key") == "1", updateable = field("is_updateable") == "1",
      type = field("system_type_name") or "", hidden = field("is_hidden") == "1" }
    entries[#entries + 1] = entry
    if not entry.hidden then visible[#visible + 1] = entry end
  end
  if #visible ~= model.column_count then return nil, "This result does not match its SQL. Run it again." end
  local target
  for _, entry in ipairs(visible) do
    if entry.updateable and entry.table and entry.column then target = entry; break end
  end
  if not target then return nil, "No column of this result belongs to a table." end
  local function same(entry) return entry.schema == target.schema and entry.table == target.table end
  local info = { schema = target.schema, table = target.table, keys = {}, columns = {} }
  for _, entry in ipairs(entries) do
    if same(entry) and entry.key then
      local found
      for i, column in ipairs(visible) do
        if same(column) and column.column == entry.column then found = i end
      end
      if not found then return nil, string.format("Include the key column %s to edit this result.", quote(entry.column)) end
      info.keys[#info.keys + 1] = { index = found, column = entry.column }
    end
  end
  if #info.keys == 0 then
    return nil, string.format("%s.%s has no primary key or unique key.", quote(target.schema), quote(target.table))
  end
  -- A table column can find its rows; an editable column can also take a value.
  -- A rowversion column (`version`) changes with each change of its row.
  for i, entry in ipairs(visible) do
    local column = same(entry) and entry.column and not binary(entry.type)
    local t = entry.type:lower()
    info.columns[i] = { column = entry.column, editable = column and entry.updateable, comparable = column,
      checkable = column and not inexact(entry.type),
      version = same(entry) and entry.column and (t == "timestamp" or t == "rowversion") or nil }
  end
  return info
end

function M.describe_sql(text)
  return "EXEC sys.sp_describe_first_result_set @tsql = " .. literal(text)
    .. ", @params = NULL, @browse_information_mode = 1;"
end

function M.change_count(results)
  local count = 0
  for _, row in ipairs(results.model.rows) do
    if results.deletes[row] or results.edits[row] then count = count + 1 end
  end
  return count
end

-- One statement for each changed row, in one transaction. Each statement must
-- change exactly one row, so a row that changed since the run stops the script.
-- A row matches by its key and by the values that the statement replaces or
-- deletes, so it does not overwrite another user's change. A shown rowversion
-- checks the whole row instead.
function M.script(results)
  local info = results.edit_info
  local target = quote(info.schema) .. "." .. quote(info.table)
  local keys, version = {}, nil
  for _, key in ipairs(info.keys) do keys[key.index] = true end
  for i, column in ipairs(info.columns) do if column.version then version = i end end
  local lines = { "-- Changes to " .. target .. " from SQL Results. Review them, then run this script.",
    "SET XACT_ABORT ON;", "BEGIN TRANSACTION;" }
  for number, row in ipairs(results.model.rows) do
    local edits = results.edits[row]
    if results.deletes[row] or edits then
      local where = {}
      for i, key in ipairs(info.keys) do where[i] = condition(key.column, row.cells[key.index]) end
      local stamp = version and row.cells[version]
      if stamp and stamp:find("^%x+$") then
        where[#where + 1] = quote(info.columns[version].column) .. " = 0x" .. stamp
      else
        for column = 1, results.model.column_count do
          local c = info.columns[column]
          if c.checkable and not keys[column] and not (row.cut and row.cut[column])
              and (results.deletes[row] or edits[column] ~= nil) then
            where[#where + 1] = condition(c.column, row.cells[column])
          end
        end
      end
      where = " WHERE " .. table.concat(where, " AND ") .. ";"
      if results.deletes[row] then
        lines[#lines + 1] = "DELETE FROM " .. target .. where
      else
        local set = {}
        for column = 1, results.model.column_count do
          if edits[column] ~= nil then
            set[#set + 1] = quote(info.columns[column].column) .. " = " .. literal(edits[column])
          end
        end
        lines[#lines + 1] = "UPDATE " .. target .. " SET " .. table.concat(set, ", ") .. where
      end
      lines[#lines + 1] = string.format("IF @@ROWCOUNT <> 1 THROW 50001, N'Row %d changed or no longer exists.', 1;", number)
    end
  end
  lines[#lines + 1] = "COMMIT TRANSACTION;"
  return table.concat(lines, "\n") .. "\n"
end

-- The selected rows as INSERT statements of their shown values, pending edits
-- included. Identity, computed and other columns that cannot take a value stay
-- out. SQL Server takes at most 1,000 rows in one VALUES list.
function M.insert_script(results, row1, row2)
  local info = results.edit_info
  local target = quote(info.schema) .. "." .. quote(info.table)
  local names, columns = {}, {}
  for i, column in ipairs(info.columns) do
    if column.editable then names[#names + 1] = quote(column.column); columns[#columns + 1] = i end
  end
  if #columns == 0 then return nil, string.format("No column of this result can take a value in %s.", target) end
  local lines = { "-- Rows of " .. target .. " from SQL Results. Review them, then run this script." }
  for display_row = row1, row2 do
    if (display_row - row1) % 1000 == 0 then
      if display_row > row1 then lines[#lines] = lines[#lines]:gsub(",$", ";") end
      lines[#lines + 1] = "INSERT INTO " .. target .. " (" .. table.concat(names, ", ") .. ") VALUES"
    end
    local values, row = {}, results:source_row(display_row)
    for i, column in ipairs(columns) do
      if results:is_cut(row, column) then return nil, results:cut_message(column) .. " Script these rows with SQL." end
      values[i] = literal(results:cell_value(display_row, column))
    end
    lines[#lines + 1] = "    (" .. table.concat(values, ", ") .. "),"
  end
  lines[#lines] = lines[#lines]:gsub(",$", ";")
  return table.concat(lines, "\n") .. "\n"
end

-- A SELECT of the table's rows that have the selected cells' values, as the
-- server sent them. Each selected row adds its own condition. A value that
-- Anvil cut stays out, and the third result tells it.
function M.select_script(results, row1, column1, row2, column2)
  local info = results.edit_info
  local target = quote(info.schema) .. "." .. quote(info.table)
  local conditions, note = {}, nil
  for display_row = row1, row2 do
    local row, parts = results:source_row(display_row), {}
    for column = column1, column2 do
      if row.cut and row.cut[column] then
        note = note or results:cut_message(column) .. " The SELECT leaves it out."
      elseif info.columns[column].comparable then
        local value = row.cells[column]
        parts[#parts + 1] = quote(info.columns[column].column) .. (value == false and " IS NULL" or " = " .. literal(value))
      end
    end
    if #parts == 0 then return nil, string.format("No selected column is a column of %s.", target) end
    conditions[#conditions + 1] = "(" .. table.concat(parts, " AND ") .. ")"
  end
  return "SELECT *\nFROM " .. target .. "\nWHERE " .. table.concat(conditions, "\n   OR ") .. ";\n", nil, note
end

-- Calls done(info) when SQL Server described the result. The describe call
-- uses the Query's SQL Session, so temporary tables and the database stay.
function M.prepare(sql, results, done)
  if results.edit_info then return done(results.edit_info) end
  if results.edit_error then core.warn("%s", results.edit_error); return false end
  local buffer = results.source_buffer
  local c = buffer and sql.connection_for(buffer)
  if not c or not results.run_text or results.kind ~= "SQL Results" or not results.data
      or #results.data.results ~= 1 then
    core.warn("Only the single result of a SQL run can be edited."); return false
  end
  if results.describing then return false end
  if buffer.sql_execution and buffer.sql_execution.active then core.warn("Wait for the running SQL to finish."); return false end
  local session = require "plugins.sql_server.session"
  local generation, data_now = c.generation, results.data
  results.describing = true
  local handle, err = require("plugins.sql_server.backend").execute(sql.connection_options(c), M.describe_sql(results.run_text),
    function(data)
      results.describing = false
      session.adopt(buffer, c, generation, data, sql.connection_for(buffer) == c)
      if results.closed or results.data ~= data_now then return end
      local info, reason = M.analyze(results.model, data)
      core.log_quiet("SQL Server: result edit check connection=%s editable=%s", c.id, tostring(info ~= nil))
      if not info then results.edit_error = reason; core.warn("%s", reason); return end
      results.edit_info = info
      done(info)
    end, { session = session.for_run(buffer, c), autocommit = buffer.sql_auto_commit ~= false, max_rows = 4096, timeout = 30 })
  if not handle then results.describing = false; core.warn("%s", err or "Could not read the result's columns."); return false end
  return true
end

return M
