-- UI wiring over the native SQL context and the connection's metadata snapshot.
local core = require "core"
local native = require "sql_server_native"
local autocomplete = require "plugins.autocomplete"
local M = {}
local cache = setmetatable({}, { __mode = "k" })
local symbol_names = setmetatable({}, { __mode = "k" })

local function equal(catalog, a, b)
  return a == b or (not catalog.case_sensitive and a:lower() == b:lower())
end
local function quote(buffer, value)
  local symbols = buffer.syntax and buffer.syntax.symbols or {}
  if value:match("^[#@]*[%a_][%w_@#$]*$") and not symbols[value:upper()] then return value end
  return "[" .. value:gsub("]", "]]") .. "]"
end
local function resolve(catalog, schema, name)
  local fallback
  for _, t in ipairs(catalog.objects) do
    if equal(catalog, t.name, name) and (schema == "" or equal(catalog, t.schema, schema)) then
      if schema ~= "" or equal(catalog, t.schema, catalog.default_schema) then return t end
      if equal(catalog, t.schema, "dbo") then fallback = t end
    end
  end
  return fallback
end
local LOCAL_LABELS = { cte = "CTE", derived = "derived table", temp = "temporary table", variable = "table variable" }
-- A source's object: a Local Source that the text defines, or else a catalog object.
local function source_object(state, source)
  local index = source.local_index
  if not index then return resolve(state.catalog, source.schema, source.name) end
  state.local_objects = state.local_objects or {}
  local object = state.local_objects[index]
  if not object then
    local definition = state.parsed.locals[index]
    object = { schema = "", name = definition.name, kind = definition.kind, local_source = true,
      incomplete = definition.star, columns = {} }
    for i, column in ipairs(definition.columns) do
      object.columns[i] = { name = column, type = LOCAL_LABELS[definition.kind] }
    end
    state.local_objects[index] = object
  end
  return object
end
local function context(view, sql)
  local buffer = view and view.buffer
  if not buffer then return end
  local c = sql.connection_for(buffer)
  if not c or not c.catalog or sql.other_database(buffer) then return end
  local line, col, line2, col2 = buffer:get_selection()
  if line ~= line2 or col ~= col2 then return end
  local previous = cache[buffer]
  if previous and previous.revision == buffer.text_revision and previous.line == line and previous.col == col
      and previous.generation == sql.generation then return previous end
  local size = 0
  for _, text in ipairs(buffer.lines) do
    size = size + #text
    if size > 256 * 1024 then return end
  end
  local text = table.concat(buffer.lines)
  local offset = col - 1
  for i = 1, line - 1 do offset = offset + #buffer.lines[i] end
  local parsed = native.context(text, offset)
  if not parsed then return end
  if parsed.start < offset - col + 1 or text:sub(offset + 1, parsed["end"]):find("[\r\n]") then return end
  local result = { revision = buffer.text_revision, line = line, col = col, offset = offset,
    generation = sql.generation, parsed = parsed, catalog = c.catalog, connection = c, text = text }
  cache[buffer] = result
  return result
end
-- A table whose columns are not loaded reads them. Completion then opens again, if the caret
-- has not moved.
local function load_columns(view, sql, state, object)
  sql.object_columns(state.connection, object, function()
    if core.active_view ~= view or view.buffer.text_revision ~= state.revision then return end
    local line, col = view.buffer:get_selection()
    if line == state.line and col == state.col then autocomplete.refresh() end
  end)
end
-- The keywords that can follow a complete term in each clause, most likely first.
local function list(...)
  local result = {}
  for _, words in ipairs({ ... }) do
    for _, word in ipairs(words) do result[#result + 1] = word end
  end
  return result
end
local PREDICATES = { "LIKE", "NOT LIKE", "IN", "NOT IN", "IS NULL", "IS NOT NULL", "BETWEEN" }
local SET_OPERATORS = { "UNION", "UNION ALL", "EXCEPT", "INTERSECT" }
local JOINS = { "JOIN", "INNER JOIN", "LEFT JOIN", "RIGHT JOIN", "FULL JOIN", "CROSS JOIN", "CROSS APPLY", "OUTER APPLY" }
local OUTER_JOINS = { "JOIN", "OUTER JOIN" }
local KEYWORDS = {
  select = list({ "FROM", "AS", "INTO", "OVER", "ORDER BY" }, SET_OPERATORS),
  from = list({ "AS", "WHERE" }, JOINS, { "GROUP BY", "ORDER BY", "WITH", "OPTION" }, SET_OPERATORS),
  join = list({ "ON", "AS", "WITH" }, JOINS, { "WHERE" }),
  on = list({ "AND", "OR" }, PREDICATES, { "WHERE" }, JOINS, { "GROUP BY", "ORDER BY" }, SET_OPERATORS),
  where = list({ "AND", "OR" }, PREDICATES, { "GROUP BY", "ORDER BY", "OPTION" }, SET_OPERATORS),
  having = list({ "AND", "OR" }, PREDICATES, { "ORDER BY", "OPTION" }, SET_OPERATORS),
  group = list({ "HAVING", "ORDER BY", "OPTION" }, SET_OPERATORS),
  order = { "ASC", "DESC", "COLLATE", "OFFSET", "OPTION" },
  sort = { "OFFSET", "OPTION" },
  partition = { "ORDER BY", "ROWS", "RANGE" },
  when = list({ "THEN", "AND", "OR" }, PREDICATES),
  ["then"] = { "WHEN", "ELSE", "END" },
  ["else"] = { "END" },
  case = { "WHEN" },
  set = { "FROM", "WHERE", "OUTPUT" },
  update = { "SET" },
  into = { "VALUES", "SELECT", "DEFAULT VALUES", "OUTPUT", "FROM" },
  insert = { "INTO" },
  by = { "BY" },
  union = { "ALL", "SELECT" },
  except = { "SELECT" },
  left = OUTER_JOINS, right = OUTER_JOINS, full = OUTER_JOINS,
  inner = { "JOIN" },
  cross = { "JOIN", "APPLY" },
  outer = { "JOIN", "APPLY" },
  is = { "NULL", "NOT NULL" },
  ["is not"] = { "NULL" },
}
-- Keywords that start with the typed text, in the case of the clause's keyword.
local function keyword_completion(state, buffer)
  local p = state.parsed
  local prefix = p.prefix:upper()
  local start_col = state.col - (state.offset - p.start)
  local end_col = state.col + p["end"] - state.offset
  local items = {}
  for _, word in ipairs(KEYWORDS[p.keywords] or {}) do
    if #word > #prefix and word:sub(1, #prefix) == prefix and (word ~= "AS" or p.alias) then
      local inserted = p.lower and word:lower() or word
      items[#items + 1] = { text = inserted, onselect = function()
        if buffer.text_revision ~= state.revision then return true end
        local line, col = buffer:get_selection()
        if line ~= state.line or col ~= state.col then return true end
        local edits = { { line1 = line, col1 = start_col, line2 = line, col2 = end_col, text = inserted, idx = 1 } }
        buffer:apply_edits(edits, { type = "insert", selections = buffer:selections_after_edits(edits, { "end" }), last_selection = 1 })
        return true
      end }
    end
  end
  return { query = p.prefix, line = state.line, query_col = state.col - #p.prefix, items = items }
end
-- The foreign keys at either end of each table, by its schema and name. Built once for each catalog.
local key_index = setmetatable({}, { __mode = "k" })
local function table_key(catalog, schema, name)
  local key = schema .. "\0" .. name
  return catalog.case_sensitive and key or key:lower()
end
local function keys_of(catalog, object)
  local index = key_index[catalog]
  if not index then
    index = {}
    for _, k in ipairs(catalog.foreign_keys) do
      for _, at in ipairs({ table_key(catalog, k.schema, k.table), table_key(catalog, k.ref_schema, k.ref_table) }) do
        local list = index[at] or {}
        index[at] = list
        -- A key that references its own table is listed once.
        if list[#list] ~= k then list[#list + 1] = k end
      end
    end
    key_index[catalog] = index
  end
  return index[table_key(catalog, object.schema, object.name)] or {}
end
-- `a.x = b.y` for each foreign key between the joined source and a source before it, with the
-- earlier source first. The column pairs of a key join with AND. A self-join gets both directions.
local function join_conditions(state, buffer, add)
  local p, catalog = state.parsed, state.catalog
  local joined = p.sources[p.join]
  local target = joined and source_object(state, joined)
  if not target or target.local_source then return end
  local function qualifier(source) return quote(buffer, source.alias ~= "" and source.alias or source.name) end
  local function at(o, schema, name) return equal(catalog, schema, o.schema) and equal(catalog, name, o.name) end
  for i = 1, p.join - 1 do
    local source = p.sources[i]
    local earlier = source_object(state, source)
    if earlier and not earlier.local_source then
      for _, k in ipairs(keys_of(catalog, target)) do
        for _, referenced in ipairs({ false, true }) do
          -- Referenced: the earlier source holds the key's referenced columns.
          local from, to = referenced and target or earlier, referenced and earlier or target
          if at(from, k.schema, k.table) and at(to, k.ref_schema, k.ref_table) then
            local parts = {}
            for c = 1, #k.columns do
              local mine = referenced and k.ref_columns[c] or k.columns[c]
              local theirs = referenced and k.columns[c] or k.ref_columns[c]
              parts[c] = qualifier(source) .. "." .. quote(buffer, mine) .. " = " .. qualifier(joined) .. "." .. quote(buffer, theirs)
            end
            local condition = table.concat(parts, " AND ")
            add(condition, condition, k.name)
          end
        end
      end
    end
  end
end
local function complete(view, sql, opts)
  local state = context(view, sql)
  if not state then return end
  local p, catalog, buffer = state.parsed, state.catalog, view.buffer
  -- No existing name goes here, but a keyword can. Keywords wait for a typed letter, and where
  -- the typed word can be an alias, for an explicit request.
  if p.slot == "none" then
    if not opts.manual and (p.prefix == "" or p.alias) then
      return { query = "", line = state.line, query_col = state.col, items = {} }
    end
    return keyword_completion(state, buffer)
  end
  -- At a value, names wait for a typed letter or an explicit request.
  if p.slot == "value" and p.prefix == "" and not opts.manual then
    return { query = "", line = state.line, query_col = state.col, items = {} }
  end
  if state.completion then return state.completion end
  if p.star then return end
  local items, seen, conditions = {}, {}, {}
  local function add(name, inserted, description, into)
    if not name:lower():find(p.prefix:lower(), 1, true) or seen[inserted] then return end
    seen[inserted] = true
    local start_col = state.col - (state.offset - p.start)
    local end_col = state.col + p["end"] - state.offset
    into = into or items
    into[#into + 1] = { text = name, desc = description, onselect = function()
      if buffer.text_revision ~= state.revision or sql.generation ~= state.generation then return true end
      local line, col = buffer:get_selection()
      if line ~= state.line or col ~= state.col then return true end
      local edits = { { line1 = line, col1 = start_col, line2 = line, col2 = end_col, text = inserted, idx = 1 } }
      buffer:apply_edits(edits, { type = "insert", selections = buffer:selections_after_edits(edits, { "end" }), last_selection = 1 })
      return true
    end }
  end
  if (p.mode == "table" or p.mode == "object" and p.object_kind == "table") and p.qualifier == "" then
    for _, definition in ipairs(p.locals) do
      if definition.kind ~= "derived" then add(definition.name, quote(buffer, definition.name), LOCAL_LABELS[definition.kind]) end
    end
  end
  if p.mode == "table" or p.mode == "object" then
    for _, t in ipairs(catalog.objects) do
      local kind = p.mode == "table" and "table" or p.object_kind
      if (t.kind == kind or kind == "table" and t.kind == "view") and (p.qualifier == "" or equal(catalog, p.qualifier, t.schema)) then
        local inserted = quote(buffer, t.name)
        if p.qualifier == "" then inserted = quote(buffer, t.schema) .. "." .. inserted end
        add(t.name, inserted, t.schema .. "." .. t.name)
      end
    end
  elseif p.mode == "column" then
    if p.join > 0 then
      join_conditions(state, buffer, function(name, inserted, description) add(name, inserted, description, conditions) end)
    end
    for _, source in ipairs(p.sources) do
      local qualifier = source.alias ~= "" and source.alias or source.name
      if p.qualifier == "" or equal(catalog, p.qualifier, qualifier) then
        local t = source_object(state, source)
        if t and not t.columns then load_columns(view, sql, state, t)
        elseif t then
          local owner = t.local_source and t.name or t.schema .. "." .. t.name
          for _, column in ipairs(t.columns) do
            local inserted = quote(buffer, column.name)
            if p.qualifier == "" and #p.sources > 1 then inserted = quote(buffer, qualifier) .. "." .. inserted end
            add(column.name, inserted, owner .. " · " .. column.type)
          end
        end
      end
    end
  end
  table.sort(items, function(a, b) return a.text < b.text or (a.text == b.text and a.desc < b.desc) end)
  -- Join conditions go first, in key order.
  for i = #conditions, 1, -1 do table.insert(items, 1, conditions[i]) end
  state.completion = { query = p.prefix, line = state.line, query_col = state.col - #p.prefix, items = items }
  return state.completion
end
function M.install(sql)
  autocomplete.add_provider("sql-server", function(view, opts) return complete(view, sql, opts) end)
  require("core.language_intelligence").register_provider {
    id = "sql-server", name = "Database", priority = 100,
    -- Database groups join Project Symbol Search from any Buffer. The other features need a SQL Buffer.
    is_available = function(buffer, feature)
      return feature == "project_symbol_groups" or buffer and buffer.syntax and buffer.syntax.name == "SQL"
    end,
    -- One group for each of the Project's connections, after the Project's code symbols. A Ready
    -- connection lists its matching objects. Enter shows an object's actions, and a new Pane opens its
    -- source. A connection that is not Ready shows one row that connects it and searches again.
    project_symbol_groups = function(query, opts)
      sql.load()
      local groups = {}
      for _, c in ipairs(sql.connections) do
        local items = {}
        if c.state == "Ready" and c.catalog then
          local catalog, generation = c.catalog, c.generation
          local names = symbol_names[catalog]
          if not names then
            names = {}
            for i, object in ipairs(catalog.objects) do names[i] = object.schema .. "." .. object.name end
            symbol_names[catalog] = names
          end
          for _, match in ipairs(require("fuzzy").filter(names, query, {
            limit = opts.limit, spans = false, case_sensitive = opts.case_sensitive,
          })) do
            local object = catalog.objects[match.index]
            items[#items + 1] = { name = names[match.index], kind = object.kind, display_file = c.database,
              activate = function(view, placement)
                if sql.find(c.id) ~= c or c.generation ~= generation then
                  core.warn("Database metadata changed. Search again."); return false
                end
                local source = require "plugins.sql_server.source"
                if placement then return source.open(sql, c, object, placement) end
                return source.object_actions(c, object, view)
              end,
            }
          end
        elseif c.server ~= "" and c.database ~= "" then
          items[1] = { name = c.state == "Connecting" and "Connecting…" or "Connect", kind = c.state,
            display_file = c.database, activate = function(view) return M.connect_and_search(sql, c, query, view) end }
        end
        groups[#groups + 1] = { label = c.name, items = items }
      end
      return groups
    end,
  }
end

-- Connects from a Project Symbol Search row, then runs the same search again.
function M.connect_and_search(sql, c, query, view)
  local function search_again()
    core.add_thread(function()
      local deadline = system.get_time() + 30
      while c.state == "Connecting" and system.get_time() < deadline do coroutine.yield(0.05) end
      if sql.find(c.id) ~= c then return end
      if c.state ~= "Ready" then core.error("%s", c.error or "SQL connection is not ready."); return end
      if view and core.active_view ~= view then return end
      require("plugins.fuzzy_searcher").open_project_symbols(query, { source_view = view })
    end)
  end
  if c.state == "Connecting" then search_again()
  elseif c.integrated then sql.connect(c.id); search_again()
  else
    require("plugins.sql_server.connection").password_prompt(c, function(password)
      if sql.find(c.id) ~= c then return end
      sql.connect(c.id, password)
      search_again()
    end)
  end
  return true
end
function M.object_at(view, sql)
  local state = context(view, sql)
  if not state or state.parsed.mode == "none" then return end
  local p = state.parsed
  local symbol = state.text:sub(p.start + 1, p["end"])
  if symbol:sub(1, 1) == "[" then symbol = symbol:sub(2):gsub("]$", ""):gsub("]]", "]")
  elseif symbol:sub(1, 1) == '"' then symbol = symbol:sub(2):gsub('"$', ""):gsub('""', '"') end
  -- A Local Source has no database definition, so it must not reach a catalog
  -- object with the same name.
  if p.qualifier == "" then
    for _, definition in ipairs(p.locals) do
      if definition.kind ~= "derived" and equal(state.catalog, definition.name, symbol) then return end
    end
  end
  if p.mode == "table" or p.mode == "object" then
    local direct = resolve(state.catalog, p.qualifier, symbol)
    if direct then return direct end
  end
  local candidate
  for _, source in ipairs(p.sources) do
    local qualifier = source.alias ~= "" and source.alias or source.name
    local t = source_object(state, source)
    if t then
      if p.qualifier == "" and symbol ~= "" and equal(state.catalog, qualifier, symbol) then
        if t.local_source then return end
        return t
      end
      if p.mode == "column" and (p.qualifier == "" or equal(state.catalog, qualifier, p.qualifier)) then
        for _, column in ipairs(t.columns or {}) do
          if equal(state.catalog, column.name, symbol) then
            if candidate then return end -- An unqualified column belongs to more than one source.
            candidate = t
          end
        end
      end
    end
  end
  if candidate and candidate.local_source then return end
  return candidate
end

function M.expand_star(view, sql)
  if view.buffer.read_only then return false end
  return sql.with_connection(view, function()
    local state = context(view, sql)
    if not state or not state.parsed.star then return false end
    local p, columns = state.parsed, {}
    -- Read the columns that a large database did not load, then expand at the same caret.
    local missing = {}
    for _, source in ipairs(p.sources) do
      local qualifier = source.alias ~= "" and source.alias or source.name
      local object = (p.qualifier == "" or equal(state.catalog, p.qualifier, qualifier)) and source_object(state, source)
      if object and not object.columns then missing[#missing + 1] = object end
    end
    if #missing > 0 then
      local remaining = #missing
      for _, object in ipairs(missing) do
        sql.object_columns(state.connection, object, function()
          remaining = remaining - 1
          if remaining > 0 or view.closed or view.buffer.text_revision ~= state.revision then return end
          local line, col = view.buffer:get_selection()
          if line == state.line and col == state.col then M.expand_star(view, sql) end
        end)
      end
      return true
    end
    for _, source in ipairs(p.sources) do
      local qualifier = source.alias ~= "" and source.alias or source.name
      if p.qualifier == "" or equal(state.catalog, p.qualifier, qualifier) then
        local object = source_object(state, source)
        if not object or #object.columns == 0 or object.incomplete then
          core.warn("Column metadata is unavailable."); return false
        end
        for _, column in ipairs(object.columns) do
          local name = quote(view.buffer, column.name)
          if (#columns > 0 and p.qualifier ~= "") or (p.qualifier == "" and #p.sources > 1) then
            name = quote(view.buffer, qualifier) .. "." .. name
          end
          columns[#columns + 1] = name
        end
      end
    end
    if #columns == 0 then return false end
    local col = state.col - (state.offset - p.start)
    local edits = { { line1 = state.line, col1 = col, line2 = state.line, col2 = col + p["end"] - p.start,
      text = table.concat(columns, ", "), idx = 1 } }
    view.buffer:apply_edits(edits, { type = "sql-expand", merge_undo = false,
      selections = view.buffer:selections_after_edits(edits, { "end" }), last_selection = 1 })
    return true
  end)
end
return M
