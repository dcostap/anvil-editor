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
  if not buffer or not buffer.sql_connection_id then return end
  local c = sql.connection_for(buffer)
  if not c or not c.catalog then return end
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
    generation = sql.generation, parsed = parsed, catalog = c.catalog, text = text }
  cache[buffer] = result
  return result
end
local function complete(view, sql)
  local state = context(view, sql)
  if not state then return end
  if state.completion then return state.completion end
  local p, catalog, buffer = state.parsed, state.catalog, view.buffer
  if p.star then return end
  local items, seen = {}, {}
  local function add(name, inserted, description)
    if not name:lower():find(p.prefix:lower(), 1, true) or seen[inserted] then return end
    seen[inserted] = true
    local start_col = state.col - (state.offset - p.start)
    local end_col = state.col + p["end"] - state.offset
    items[#items + 1] = { text = name, desc = description, onselect = function()
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
    for _, source in ipairs(p.sources) do
      local qualifier = source.alias ~= "" and source.alias or source.name
      if p.qualifier == "" or equal(catalog, p.qualifier, qualifier) then
        local t = source_object(state, source)
        if t then
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
  state.completion = { query = p.prefix, line = state.line, query_col = state.col - #p.prefix, items = items }
  return state.completion
end
function M.install(sql)
  autocomplete.add_provider("sql-server", function(view) return complete(view, sql) end)
  require("core.language_intelligence").register_provider {
    id = "sql-server", name = "Database", priority = 100,
    is_available = function(buffer) return buffer and buffer.syntax and buffer.syntax.name == "SQL" end,
    prepare_project_symbols = function(view, done) return sql.with_connection(view, done) end,
    project_symbols = function(buffer, query, opts)
      local c = sql.connection_for(buffer)
      if not c or not c.catalog then return nil, "Choose a database connection", "pending" end
      local catalog, generation = c.catalog, c.generation
      local names = symbol_names[catalog]
      if not names then
        names = {}
        for i, object in ipairs(catalog.objects) do names[i] = object.schema .. "." .. object.name end
        symbol_names[catalog] = names
      end
      local results = {}
      for _, match in ipairs(require("fuzzy").filter(names, query, {
        limit = opts.limit, spans = false, case_sensitive = opts.case_sensitive,
      })) do
        local object = catalog.objects[match.index]
        results[#results + 1] = { name = names[match.index], kind = object.kind, display_file = c.database,
          activate = function(view, placement)
            if sql.connection_for(view.buffer) ~= c or c.generation ~= generation then
              core.warn("Database metadata changed. Search again."); return false
            end
            return require("plugins.sql_server.source").open(sql, view, object, placement)
          end,
        }
      end
      return results, nil, "fresh"
    end,
  }
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
        for _, column in ipairs(t.columns) do
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
