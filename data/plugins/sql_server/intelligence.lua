-- UI wiring over the native SQL context and the connection's metadata snapshot.
local core = require "core"
local native = require "sql_server_native"
local autocomplete = require "plugins.autocomplete"
local M = {}
local cache = setmetatable({}, { __mode = "k" })

local function equal(catalog, a, b)
  return a == b or (not catalog.case_sensitive and a:lower() == b:lower())
end
local function quote(buffer, value)
  local symbols = buffer.syntax and buffer.syntax.symbols or {}
  if value:match("^[%a_][%w_]*$") and not symbols[value:upper()] then return value end
  return "[" .. value:gsub("]", "]]") .. "]"
end
local function resolve(catalog, schema, name)
  local fallback
  for _, t in ipairs(catalog.tables) do
    if equal(catalog, t.name, name) and (schema == "" or equal(catalog, t.schema, schema)) then
      if schema ~= "" or equal(catalog, t.schema, catalog.default_schema) then return t end
      if equal(catalog, t.schema, "dbo") then fallback = t end
    end
  end
  return fallback
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
  if p.mode == "table" then
    for _, t in ipairs(catalog.tables) do
      if p.qualifier == "" or equal(catalog, p.qualifier, t.schema) then
        local inserted = quote(buffer, t.name)
        if p.qualifier == "" then inserted = quote(buffer, t.schema) .. "." .. inserted end
        add(t.name, inserted, t.schema .. "." .. t.name)
      end
    end
  elseif p.mode == "column" then
    for _, source in ipairs(p.sources) do
      local qualifier = source.alias ~= "" and source.alias or source.name
      if p.qualifier == "" or equal(catalog, p.qualifier, qualifier) then
        local t = resolve(catalog, source.schema, source.name)
        if t then
          for _, column in ipairs(t.columns) do
            local inserted = quote(buffer, column.name)
            if p.qualifier == "" and #p.sources > 1 then inserted = quote(buffer, qualifier) .. "." .. inserted end
            add(column.name, inserted, t.schema .. "." .. t.name .. " · " .. column.type)
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
end
function M.table_at(view, sql)
  local state = context(view, sql)
  if not state or state.parsed.mode == "none" then return end
  local p = state.parsed
  local symbol = state.text:sub(p.start + 1, p["end"])
  if symbol:sub(1, 1) == "[" then symbol = symbol:sub(2):gsub("]$", ""):gsub("]]", "]")
  elseif symbol:sub(1, 1) == '"' then symbol = symbol:sub(2):gsub('"$', ""):gsub('""', '"') end
  if p.mode == "table" then
    local direct = resolve(state.catalog, p.qualifier, symbol)
    if direct then return direct end
  end
  local candidate
  for _, source in ipairs(p.sources) do
    local qualifier = source.alias ~= "" and source.alias or source.name
    local t = resolve(state.catalog, source.schema, source.name)
    if t then
      if p.qualifier == "" and symbol ~= "" and equal(state.catalog, qualifier, symbol) then return t end
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
  return candidate
end
return M
