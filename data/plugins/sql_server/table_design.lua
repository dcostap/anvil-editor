-- Table Design: the plain model of one table's design, its catalog read, and the CREATE or ALTER script
-- that changes the table to the design. The script only changes what differs from the table that the
-- catalog showed. Items with options that the design does not show, such as a filtered index, are locked:
-- the design keeps them as they are, or drops them.
local M = {}

M.ACTIONS = { "NO ACTION", "CASCADE", "SET NULL", "SET DEFAULT" }

local function quote(name) return "[" .. name:gsub("]", "]]") .. "]" end
local function literal(text) return "N'" .. text:gsub("'", "''") .. "'" end
local function copy(item)
  local out = {}
  for k, v in pairs(item) do
    if k ~= "original" then out[k] = type(v) == "table" and copy(v) or v end
  end
  return out
end
local function same_list(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end

-- Whether an expression is one parenthesized group, such as SQL Server's own "((0))". Strings and quoted
-- names do not count.
local function grouped(text)
  if text:sub(1, 1) ~= "(" then return false end
  local depth, i, n = 0, 1, #text
  while i <= n do
    local ch = text:sub(i, i)
    if ch == "'" or ch == "[" or ch == '"' then
      local close = ch == "[" and "]" or ch
      i = i + 1
      while i <= n do
        if text:sub(i, i) == close then
          if text:sub(i + 1, i + 1) == close then i = i + 1 else break end
        end
        i = i + 1
      end
    elseif ch == "(" then depth = depth + 1
    elseif ch == ")" then
      depth = depth - 1
      if depth == 0 and i < n then return false end
    end
    i = i + 1
  end
  return depth == 0
end
local function expression(text) return grouped(text) and text or "(" .. text .. ")" end

-- The catalog read. One batch returns the table, its columns, its keys and indexes, its foreign keys
-- and its check constraints, with the columns that each check and computed column uses.
function M.read_sql(schema, name)
  return table.concat({
    "SET NOCOUNT ON;",
    "DECLARE @id int = (SELECT o.object_id FROM sys.objects o JOIN sys.schemas s ON s.schema_id = o.schema_id",
    "  WHERE s.name = " .. literal(schema) .. " AND o.name = " .. literal(name) .. " AND o.type = 'U');",
    "SELECT @id AS object_id;",
    "SELECT c.column_id, c.name,",
    "  CASE WHEN ty.is_user_defined = 1 THEN QUOTENAME(SCHEMA_NAME(ty.schema_id)) + '.' + QUOTENAME(ty.name) ELSE ty.name +",
    "  CASE WHEN ty.name IN ('varchar','char','varbinary','binary','nvarchar','nchar') THEN '(' + CASE WHEN c.max_length = -1 THEN 'max'",
    "  ELSE CONVERT(varchar(10), CASE WHEN ty.name IN ('nvarchar','nchar') THEN c.max_length / 2 ELSE c.max_length END) END + ')'",
    "  WHEN ty.name IN ('decimal','numeric') THEN '(' + CONVERT(varchar(10), c.precision) + ',' + CONVERT(varchar(10), c.scale) + ')'",
    "  WHEN ty.name IN ('time','datetime2','datetimeoffset') THEN '(' + CONVERT(varchar(10), c.scale) + ')' ELSE '' END END AS type,",
    "  c.collation_name, c.is_nullable, c.is_identity, CONVERT(nvarchar(40), ic.seed_value) AS seed,",
    "  CONVERT(nvarchar(40), ic.increment_value) AS increment, dc.name AS default_name, dc.definition AS default_definition,",
    "  cc.definition AS computed, cc.is_persisted,",
    "  CASE WHEN c.is_rowguidcol = 1 OR c.generated_always_type <> 0 OR c.is_sparse = 1 OR c.is_column_set = 1",
    "    OR c.is_filestream = 1 OR c.is_hidden = 1 OR c.is_masked = 1 OR ic.is_not_for_replication = 1 THEN 1 ELSE 0 END AS locked",
    "FROM sys.columns c JOIN sys.types ty ON ty.user_type_id = c.user_type_id",
    "LEFT JOIN sys.identity_columns ic ON ic.object_id = c.object_id AND ic.column_id = c.column_id",
    "LEFT JOIN sys.computed_columns cc ON cc.object_id = c.object_id AND cc.column_id = c.column_id",
    "LEFT JOIN sys.default_constraints dc ON dc.object_id = c.default_object_id",
    "WHERE c.object_id = @id ORDER BY c.column_id;",
    "SELECT i.index_id, i.name, CASE WHEN i.is_primary_key = 1 THEN 'primary' WHEN i.is_unique_constraint = 1 THEN 'unique'",
    "  ELSE 'index' END AS kind, i.is_unique, i.type, k.column_id,",
    "  CASE WHEN i.has_filter = 1 OR i.is_disabled = 1 OR i.ignore_dup_key = 1 OR i.fill_factor <> 0 OR i.is_padded = 1",
    "    OR i.allow_row_locks = 0 OR i.allow_page_locks = 0 OR i.type NOT IN (1, 2)",
    "    OR EXISTS (SELECT 1 FROM sys.index_columns x WHERE x.object_id = i.object_id AND x.index_id = i.index_id",
    "      AND (x.is_included_column = 1 OR x.is_descending_key = 1))",
    "    OR EXISTS (SELECT 1 FROM sys.partitions p WHERE p.object_id = i.object_id AND p.index_id = i.index_id",
    "      AND (p.data_compression <> 0 OR p.partition_number > 1)) THEN 1 ELSE 0 END AS locked",
    "FROM sys.indexes i LEFT JOIN sys.index_columns k ON k.object_id = i.object_id AND k.index_id = i.index_id AND k.key_ordinal > 0",
    "WHERE i.object_id = @id AND i.type <> 0 AND i.is_hypothetical = 0 ORDER BY i.index_id, k.key_ordinal;",
    "SELECT f.object_id, f.name, SCHEMA_NAME(r.schema_id) AS ref_schema, r.name AS ref_table, x.parent_column_id,",
    "  COL_NAME(x.referenced_object_id, x.referenced_column_id) AS ref_column,",
    "  f.delete_referential_action_desc AS on_delete, f.update_referential_action_desc AS on_update,",
    "  CASE WHEN f.is_disabled = 1 OR f.is_not_trusted = 1 OR f.is_not_for_replication = 1 THEN 1 ELSE 0 END AS locked",
    "FROM sys.foreign_keys f JOIN sys.objects r ON r.object_id = f.referenced_object_id",
    "JOIN sys.foreign_key_columns x ON x.constraint_object_id = f.object_id",
    "WHERE f.parent_object_id = @id ORDER BY f.name, x.constraint_column_id;",
    "SELECT k.object_id, k.name, k.definition,",
    "  CASE WHEN k.is_disabled = 1 OR k.is_not_trusted = 1 OR k.is_not_for_replication = 1 THEN 1 ELSE 0 END AS locked",
    "FROM sys.check_constraints k WHERE k.parent_object_id = @id ORDER BY k.name;",
    "SELECT d.referencing_id AS object_id, d.referencing_minor_id AS minor_id, d.referenced_minor_id AS column_id",
    "FROM sys.sql_expression_dependencies d WHERE d.referenced_id = @id AND d.referenced_minor_id > 0",
    "  AND (d.referencing_id = @id OR d.referencing_id IN (SELECT object_id FROM sys.check_constraints WHERE parent_object_id = @id));",
  }, "\n")
end

-- Rows of one result as tables keyed by header.
local function records(result)
  local out = {}
  if not result then return out end
  for r, row in ipairs(result.rows) do
    local record = {}
    for i, header in ipairs(result.headers) do
      local value = row.cells[i]
      if value ~= false then record[header] = value end
    end
    out[r] = record
  end
  return out
end

local function finish(design)
  for _, list in ipairs({ design.columns, design.indexes, design.foreign_keys, design.checks }) do
    for _, item in ipairs(list) do item.original = copy(item) end
  end
  if design.primary_key.id then design.primary_key.original = copy(design.primary_key) end
  design.original = { schema = design.schema, name = design.name }
  return design
end

-- A design from the catalog read's results, or nil and a reason.
function M.from_results(schema, name, data)
  if data.error then return nil, (data.error:gsub("\n.*", "")) end
  local results = data.results or {}
  local id = records(results[1])[1]
  if not id or not id.object_id then return nil, string.format("Table %s.%s does not exist.", quote(schema), quote(name)) end
  if #results < 6 then return nil, "SQL Server did not describe this table." end
  for _, r in ipairs(results) do
    if r.truncated then return nil, "This table has too many columns, keys or indexes to design here." end
    for _, row in ipairs(r.rows or {}) do
      if row.cut then return nil, "A definition in this table is longer than 32,768 characters." end
    end
  end
  local design = { existing = true, schema = schema, name = name, columns = {}, indexes = {}, foreign_keys = {},
    checks = {}, primary_key = { key = "primary", kind = "primary", name = "PK_" .. name, columns = {} } }
  local by_id = {}
  for _, r in ipairs(records(results[2])) do
    local column = { key = "c" .. r.column_id, name = r.name, type = r.type or "", collation = r.collation_name or "",
      nullable = r.is_nullable == "1", identity = r.is_identity == "1", seed = r.seed, increment = r.increment,
      default = r.default_definition or "", default_name = r.default_name, computed = r.computed,
      persisted = r.is_persisted == "1", locked = r.locked == "1" or r.computed ~= nil }
    design.columns[#design.columns + 1] = column
    by_id[r.column_id] = column
  end
  local index
  for _, r in ipairs(records(results[3])) do
    if not index or index.id ~= r.index_id then
      index = { id = r.index_id, key = "i" .. r.index_id, name = r.name, columns = {}, unique = r.is_unique == "1",
        clustered = r.type == "1", locked = r.locked == "1",
        kind = r.kind == "primary" and "primary" or (r.kind == "unique" and "constraint" or "index") }
      if r.kind == "primary" then
        index.key = "primary"
        design.primary_key = index
      else
        design.indexes[#design.indexes + 1] = index
      end
    end
    local column = r.column_id and by_id[r.column_id]
    if column then index.columns[#index.columns + 1] = column.key end
  end
  local foreign_key
  for _, r in ipairs(records(results[4])) do
    if not foreign_key or foreign_key.id ~= r.object_id then
      foreign_key = { id = r.object_id, key = "f" .. r.object_id, name = r.name, columns = {}, ref_columns = {},
        ref_schema = r.ref_schema, ref_table = r.ref_table, locked = r.locked == "1",
        on_delete = (r.on_delete or "NO_ACTION"):gsub("_", " "), on_update = (r.on_update or "NO_ACTION"):gsub("_", " ") }
      design.foreign_keys[#design.foreign_keys + 1] = foreign_key
    end
    local column = by_id[r.parent_column_id]
    foreign_key.columns[#foreign_key.columns + 1] = column and column.key or ""
    foreign_key.ref_columns[#foreign_key.ref_columns + 1] = r.ref_column or ""
  end
  local checks = {}
  for _, r in ipairs(records(results[5])) do
    local check = { id = r.object_id, key = "k" .. r.object_id, name = r.name, condition = r.definition or "",
      locked = r.locked == "1", uses = {} }
    design.checks[#design.checks + 1] = check
    checks[r.object_id] = check
  end
  -- The columns that each check and computed column uses.
  for _, r in ipairs(records(results[6])) do
    local column = by_id[r.column_id]
    local user = r.object_id == id.object_id and r.minor_id ~= r.column_id and by_id[r.minor_id] or checks[r.object_id]
    if user and column then
      user.uses = user.uses or {}
      user.uses[#user.uses + 1] = column.key
    end
  end
  return finish(design)
end

-- A design for a new table with one key column.
function M.new_table(schema, name)
  return { existing = false, schema = schema, name = name, next_key = 2,
    columns = { { key = "n1", name = "id", type = "int", collation = "", nullable = false, identity = true, default = "" } },
    primary_key = { key = "primary", kind = "primary", name = "PK_" .. name, columns = { "n1" } },
    indexes = {}, foreign_keys = {}, checks = {} }
end

-- A key for a new item, unique in its design.
function M.new_key(design)
  design.next_key = (design.next_key or 1) + 1
  return "n" .. design.next_key
end

function M.column(design, key)
  for _, column in ipairs(design.columns) do if column.key == key then return column end end
end

local function column_names(design, keys)
  local names = {}
  for i, key in ipairs(keys) do
    local column = M.column(design, key)
    names[i] = quote(column and column.name or "?")
  end
  return table.concat(names, ", ")
end

-- The keys of the columns whose type, collation or nullability changes.
local function altered_columns(design)
  local altered = {}
  for _, column in ipairs(design.columns) do
    local original = column.original
    if original and not column.locked and (column.type ~= original.type or column.collation ~= original.collation
        or column.nullable ~= original.nullable) then
      altered[column.key] = true
    end
  end
  return altered
end

-- What is wrong with the design, as sentences. A design with problems makes no script.
function M.problems(design)
  local out = {}
  local function add(...) out[#out + 1] = string.format(...) end
  local altered = altered_columns(design)
  local gone = {}
  for _, column in ipairs(design.removed_columns or {}) do gone[column.key] = column.name end
  for _, column in ipairs(design.columns) do
    for _, key in ipairs(column.computed and column.uses or {}) do
      local used = M.column(design, key)
      if gone[key] or (used and altered[key]) then
        add("Computed column %s uses %s, so %s cannot change.", quote(column.name), quote(gone[key] or used.name),
          quote(gone[key] or used.name))
      end
    end
  end
  -- A rebuild would lose the options of a locked item, so the columns that it uses cannot change.
  local function locked_uses(item, keys)
    if not item.locked then return end
    for _, key in ipairs(keys) do
      local used = M.column(design, key)
      if gone[key] or (used and altered[key]) then
        add("%s has options that Table Design does not show, so %s cannot change.", quote(item.name),
          quote(gone[key] or used.name))
      end
    end
  end
  for _, index in ipairs(design.indexes) do locked_uses(index, index.columns) end
  for _, fk in ipairs(design.foreign_keys) do locked_uses(fk, fk.columns) end
  for _, check in ipairs(design.checks) do locked_uses(check, check.uses) end
  if design.schema == "" then add("Type a schema.") end
  if design.name == "" then add("Type a table name.") end
  if #design.columns == 0 then add("Add a column.") end
  local names, identities = {}, 0
  for _, column in ipairs(design.columns) do
    local lower = column.name:lower()
    if column.name == "" then add("Each column needs a name.")
    elseif names[lower] then add("Two columns are named %s.", quote(column.name)) end
    names[lower] = true
    if column.type == "" and not column.computed then add("Column %s needs a data type.", quote(column.name)) end
    if column.identity then identities = identities + 1 end
  end
  if identities > 1 then add("Only one column can be an identity.") end
  local constraints = {}
  local function named(item, kind)
    if item.name == "" then add("Each %s needs a name.", kind); return end
    local lower = item.name:lower()
    if constraints[lower] then add("Two constraints or indexes are named %s.", quote(item.name)) end
    constraints[lower] = true
  end
  if #design.primary_key.columns > 0 then
    named(design.primary_key, "primary key")
    for _, key in ipairs(design.primary_key.columns) do
      local column = M.column(design, key)
      if column and column.nullable then add("Primary key column %s cannot be nullable.", quote(column.name)) end
    end
  end
  for _, index in ipairs(design.indexes) do
    named(index, "index")
    if #index.columns == 0 then add("Index %s needs a column.", quote(index.name)) end
  end
  for _, fk in ipairs(design.foreign_keys) do
    named(fk, "foreign key")
    if (fk.ref_table or "") == "" then add("Foreign key %s needs a referenced table.", quote(fk.name))
    elseif #fk.columns == 0 then add("Foreign key %s needs a column.", quote(fk.name)) end
    for _, ref in ipairs(fk.ref_columns) do
      if ref == "" then add("Each column of foreign key %s needs a referenced column.", quote(fk.name)); break end
    end
  end
  for _, check in ipairs(design.checks) do
    named(check, "check constraint")
    if check.condition == "" then add("Check constraint %s needs a condition.", quote(check.name)) end
    for _, key in ipairs(check.uses or {}) do
      if gone[key] then add("Check constraint %s uses the removed column %s.", quote(check.name), quote(gone[key])) end
    end
  end
  return out
end

-- A column's definition. ALTER COLUMN takes no identity or default.
local function column_sql(column, default_name, alter)
  if column.computed then
    return quote(column.name) .. " AS " .. column.computed .. (column.persisted and " PERSISTED" or "")
  end
  local parts = { quote(column.name), column.type }
  if column.collation ~= "" then parts[#parts + 1] = "COLLATE " .. column.collation end
  if column.identity and not alter then
    parts[#parts + 1] = string.format("IDENTITY(%s,%s)", column.seed or "1", column.increment or "1")
  end
  parts[#parts + 1] = column.nullable and "NULL" or "NOT NULL"
  if column.default ~= "" and default_name and not alter then
    parts[#parts + 1] = "CONSTRAINT " .. quote(default_name) .. " DEFAULT " .. expression(column.default)
  end
  return table.concat(parts, " ")
end

local function default_name(design, column)
  return column.default_name or ("DF_" .. design.name .. "_" .. column.name)
end

local function clustered(item)
  if item.clustered == nil then return "" end
  return item.clustered and " CLUSTERED" or " NONCLUSTERED"
end

local function key_sql(design, item)
  return "CONSTRAINT " .. quote(item.name) .. (item.kind == "primary" and " PRIMARY KEY" or " UNIQUE") .. clustered(item)
    .. " (" .. column_names(design, item.columns) .. ")"
end

local function foreign_key_sql(design, fk)
  local refs = {}
  for i, name in ipairs(fk.ref_columns) do refs[i] = quote(name) end
  local text = "CONSTRAINT " .. quote(fk.name) .. " FOREIGN KEY (" .. column_names(design, fk.columns) .. ") REFERENCES "
    .. quote(fk.ref_schema) .. "." .. quote(fk.ref_table) .. " (" .. table.concat(refs, ", ") .. ")"
  if fk.on_delete ~= "NO ACTION" then text = text .. " ON DELETE " .. fk.on_delete end
  if fk.on_update ~= "NO ACTION" then text = text .. " ON UPDATE " .. fk.on_update end
  return text
end

local function index_sql(design, target, index)
  return "CREATE " .. (index.unique and "UNIQUE " or "") .. (index.clustered and "CLUSTERED " or "") .. "INDEX "
    .. quote(index.name) .. " ON " .. target .. " (" .. column_names(design, index.columns) .. ");"
end

function M.create_script(design)
  local target = quote(design.schema) .. "." .. quote(design.name)
  local lines = {}
  for _, column in ipairs(design.columns) do
    lines[#lines + 1] = "    " .. column_sql(column, default_name(design, column))
  end
  if #design.primary_key.columns > 0 then lines[#lines + 1] = "    " .. key_sql(design, design.primary_key) end
  for _, index in ipairs(design.indexes) do
    if index.kind == "constraint" then lines[#lines + 1] = "    " .. key_sql(design, index) end
  end
  for _, check in ipairs(design.checks) do
    lines[#lines + 1] = "    CONSTRAINT " .. quote(check.name) .. " CHECK " .. expression(check.condition)
  end
  for _, fk in ipairs(design.foreign_keys) do lines[#lines + 1] = "    " .. foreign_key_sql(design, fk) end
  local out = { "CREATE TABLE " .. target .. " (", table.concat(lines, ",\n"), ");" }
  for _, index in ipairs(design.indexes) do
    if index.kind ~= "constraint" then out[#out + 1] = index_sql(design, target, index) end
  end
  return table.concat(out, "\n") .. "\n"
end

-- The ALTER script. Each statement uses the table's original name; a rename of the table comes last.
-- A column whose type, collation or nullability changes is altered. Its default and the keys, indexes and
-- checks that use it are dropped first and added again, because SQL Server refuses to alter a column
-- that they use.
function M.alter_script(design)
  local o = design.original
  local target = quote(o.schema) .. "." .. quote(o.name)
  local lines = {}
  local function add(text) lines[#lines + 1] = text end
  local function drop(name) add("ALTER TABLE " .. target .. " DROP CONSTRAINT " .. quote(name) .. ";") end
  local function rename(object, name, kind)
    add("EXEC sp_rename " .. literal(object) .. ", " .. literal(name) .. (kind and ", " .. literal(kind) or "") .. ";")
  end
  local function rename_constraint(item) rename(quote(o.schema) .. "." .. quote(item.original.name), item.name, "OBJECT") end

  local altered, removed = altered_columns(design), {}
  for _, column in ipairs(design.removed_columns or {}) do removed[column.key] = true end
  local function state(item, fields, keys)
    if not item.original then return "new" end
    for _, key in ipairs(keys) do if altered[key] or removed[key] then return "rebuild" end end
    for _, field in ipairs(fields) do
      local a, b = item[field], item.original[field]
      if type(a) == "table" then
        if not same_list(a, b) then return "rebuild" end
      elseif a ~= b then return "rebuild" end
    end
    return item.name ~= item.original.name and "rename" or "same"
  end
  local pk = design.primary_key
  local pk_state = state(pk, { "columns" }, pk.columns)
  if #pk.columns == 0 then pk_state = pk.original and "drop" or "same" end
  local states = {}
  for _, index in ipairs(design.indexes) do states[index] = state(index, { "columns", "unique" }, index.columns) end
  for _, fk in ipairs(design.foreign_keys) do
    states[fk] = state(fk, { "columns", "ref_schema", "ref_table", "ref_columns", "on_delete", "on_update" }, fk.columns)
  end
  for _, check in ipairs(design.checks) do states[check] = state(check, { "condition" }, check.uses or {}) end

  -- Drops: foreign keys, checks, indexes and unique constraints, the primary key, defaults, then columns.
  local dropped = design.dropped or {}
  local function drop_index(kind, name)
    if kind == "index" then add("DROP INDEX " .. quote(name) .. " ON " .. target .. ";") else drop(name) end
  end
  for _, item in ipairs(dropped) do if item.kind == "foreign_key" then drop(item.name) end end
  for _, fk in ipairs(design.foreign_keys) do if states[fk] == "rebuild" then drop(fk.original.name) end end
  for _, item in ipairs(dropped) do if item.kind == "check" then drop(item.name) end end
  for _, check in ipairs(design.checks) do if states[check] == "rebuild" then drop(check.original.name) end end
  for _, item in ipairs(dropped) do
    if item.kind == "index" or item.kind == "constraint" then drop_index(item.kind, item.name) end
  end
  for _, index in ipairs(design.indexes) do
    if states[index] == "rebuild" then drop_index(index.original.kind, index.original.name) end
  end
  if pk_state == "drop" or pk_state == "rebuild" then drop(pk.original.name) end
  local function default_changes(column) return altered[column.key] or column.default ~= column.original.default end
  for _, column in ipairs(design.removed_columns or {}) do if column.default_name then drop(column.default_name) end end
  for _, column in ipairs(design.columns) do
    if column.original and column.original.default_name and default_changes(column) then drop(column.original.default_name) end
  end
  for _, column in ipairs(design.removed_columns or {}) do
    add("ALTER TABLE " .. target .. " DROP COLUMN " .. quote(column.name) .. ";")
  end

  -- Column renames, column changes, new columns and new defaults.
  for _, column in ipairs(design.columns) do
    if column.original and column.name ~= column.original.name then
      rename(target .. "." .. quote(column.original.name), column.name, "COLUMN")
    end
  end
  for _, column in ipairs(design.columns) do
    if altered[column.key] then add("ALTER TABLE " .. target .. " ALTER COLUMN " .. column_sql(column, nil, true) .. ";") end
  end
  for _, column in ipairs(design.columns) do
    if not column.original then
      add("ALTER TABLE " .. target .. " ADD " .. column_sql(column, default_name(design, column)) .. ";")
    elseif column.default ~= "" and default_changes(column) then
      add("ALTER TABLE " .. target .. " ADD CONSTRAINT " .. quote(default_name(design, column)) .. " DEFAULT "
        .. expression(column.default) .. " FOR " .. quote(column.name) .. ";")
    end
  end

  -- Adds: the primary key, unique constraints and indexes, checks, then foreign keys.
  if pk_state == "new" or pk_state == "rebuild" then add("ALTER TABLE " .. target .. " ADD " .. key_sql(design, pk) .. ";")
  elseif pk_state == "rename" then rename_constraint(pk) end
  for _, index in ipairs(design.indexes) do
    local s = states[index]
    if s == "new" or s == "rebuild" then
      if index.kind == "constraint" then add("ALTER TABLE " .. target .. " ADD " .. key_sql(design, index) .. ";")
      else add(index_sql(design, target, index)) end
    elseif s == "rename" then
      if index.kind == "constraint" then rename_constraint(index)
      else rename(target .. "." .. quote(index.original.name), index.name, "INDEX") end
    end
  end
  for _, check in ipairs(design.checks) do
    local s = states[check]
    if s == "new" or s == "rebuild" then
      add("ALTER TABLE " .. target .. " ADD CONSTRAINT " .. quote(check.name) .. " CHECK " .. expression(check.condition) .. ";")
    elseif s == "rename" then rename_constraint(check) end
  end
  for _, fk in ipairs(design.foreign_keys) do
    local s = states[fk]
    if s == "new" or s == "rebuild" then add("ALTER TABLE " .. target .. " ADD " .. foreign_key_sql(design, fk) .. ";")
    elseif s == "rename" then rename_constraint(fk) end
  end
  if design.name ~= o.name then rename(target, design.name) end
  if design.schema ~= o.schema then
    add("ALTER SCHEMA " .. quote(design.schema) .. " TRANSFER " .. quote(o.schema) .. "." .. quote(design.name) .. ";")
  end
  if #lines == 0 then return nil end
  return "SET XACT_ABORT ON;\nBEGIN TRANSACTION;\n" .. table.concat(lines, "\n") .. "\nCOMMIT TRANSACTION;\n"
end

-- The design's script: CREATE for a new table, ALTER for an existing one. Returns nil and the problems
-- when the design has problems, and nil for an unchanged table.
function M.script(design)
  local problems = M.problems(design)
  if #problems > 0 then return nil, problems end
  if design.existing then return M.alter_script(design) end
  return M.create_script(design)
end

-- Removes an item from its list. The script drops an item that the table has. A removed column also
-- leaves the keys, indexes and foreign keys, and an index or foreign key without columns goes too.
function M.remove(design, list, item, kind)
  for i, other in ipairs(list) do
    if other == item then table.remove(list, i); break end
  end
  if kind ~= "column" then
    if item.original then
      design.dropped = design.dropped or {}
      design.dropped[#design.dropped + 1] = { kind = kind == "index" and item.original.kind or kind, name = item.original.name }
    end
    return
  end
  if item.original then
    design.removed_columns = design.removed_columns or {}
    design.removed_columns[#design.removed_columns + 1] = item.original
  end
  local keyed = { design.primary_key }
  for _, index in ipairs(design.indexes) do keyed[#keyed + 1] = index end
  for _, other in ipairs(keyed) do
    for i = #other.columns, 1, -1 do if other.columns[i] == item.key then table.remove(other.columns, i) end end
  end
  for _, fk in ipairs(design.foreign_keys) do
    for i = #fk.columns, 1, -1 do
      if fk.columns[i] == item.key then table.remove(fk.columns, i); table.remove(fk.ref_columns, i) end
    end
  end
  for i = #design.indexes, 1, -1 do
    if #design.indexes[i].columns == 0 then M.remove(design, design.indexes, design.indexes[i], "index") end
  end
  for i = #design.foreign_keys, 1, -1 do
    if #design.foreign_keys[i].columns == 0 then M.remove(design, design.foreign_keys, design.foreign_keys[i], "foreign_key") end
  end
end

return M
