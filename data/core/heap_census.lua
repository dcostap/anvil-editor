-- Heap Census: the live Lua heap, grouped by the data that holds it.
--
-- LuaJIT's GC marks every live object in each cycle, so large live data makes
-- each cycle longer. The census walks the object graph from the loaded
-- modules, the globals, and the registry, and gives each object to the first
-- owner that reaches it. A breadth-first walk gives the shortest path.
--
-- An owner is a path of at most OWNER_DEPTH keys below a root. Roots are
-- module names, `_G`, `registry`, and function upvalues. A module keeps its
-- private state in upvalues, so an upvalue starts a new root that names its
-- source file and variable, such as `core/markdown/model.lua:cache`.
--
-- Lua cannot read the allocated size of a table, so sizes are estimates from
-- the key counts. Userdata and prototypes count as objects with no size.
local heap_census = {}

local OWNER_DEPTH = 3
local LARGE_TABLE_BYTES = 256 * 1024
local KEY_LABEL_BYTES = 40

-- LuaJIT with 64-bit GC references.
local TABLE_BYTES = 64
local ARRAY_SLOT_BYTES = 8
local HASH_NODE_BYTES = 24
local STRING_BYTES = 25
local CLOSURE_BYTES = 48
local UPVALUE_BYTES = 8

local function power_of_two(count)
  if count <= 0 then return 0 end
  local size = 1
  while size < count do size = size * 2 end
  return size
end

local function key_label(key)
  local kind = type(key)
  if kind == "string" then
    if #key > KEY_LABEL_BYTES then key = key:sub(1, KEY_LABEL_BYTES) .. "..." end
    return "." .. key
  elseif kind == "number" then
    return "[n]"
  end
  return "[" .. kind .. "]"
end

local function source_name(fn)
  local info = debug.getinfo(fn, "S")
  local source = (info and info.short_src or "?"):gsub("\\", "/")
  return source:match("/data/(.+)$") or source:match("/anvil/(.+)$") or source
end

---Walk the live heap. Returns the owners by estimated size, the tables above
---LARGE_TABLE_BYTES, the totals, and the walk time.
function heap_census.run()
  collectgarbage("forcecollect")
  -- The second collection frees nothing, so its time is the cost of marking
  -- and sweeping the live heap: the least work of one GC cycle.
  local collect_started = system.get_time()
  collectgarbage("forcecollect")
  local collect_ms = (system.get_time() - collect_started) * 1000
  local started = system.get_time()
  local heap_kb = collectgarbage("count")

  local seen = {}
  local queue, labels, depths = {}, {}, {}
  local tail = 0
  local owners = {}
  local large = {}
  local total_bytes, total_objects = 0, 0
  -- The walk's own tables and the coroutine that runs it are not editor data.
  for _, own in ipairs { seen, queue, labels, depths, owners, large } do seen[own] = true end
  local running = coroutine.running()
  if running then seen[running] = true end

  local function owner(label)
    local row = owners[label]
    if not row then
      row = { owner = label, bytes = 0, objects = 0, tables = 0, strings = 0, functions = 0 }
      owners[label] = row
    end
    return row
  end

  local function count(label, kind, bytes)
    local row = owner(label)
    row.bytes = row.bytes + bytes
    row.objects = row.objects + 1
    if kind == "table" then row.tables = row.tables + 1
    elseif kind == "string" then row.strings = row.strings + 1
    elseif kind == "function" then row.functions = row.functions + 1 end
    total_bytes = total_bytes + bytes
    total_objects = total_objects + 1
  end

  local function visit(value, label, depth)
    local kind = type(value)
    if kind == "string" then
      if not seen[value] then
        seen[value] = true
        count(label, "string", STRING_BYTES + #value)
      end
    elseif kind == "table" or kind == "function" or kind == "thread" or kind == "userdata" then
      if not seen[value] then
        seen[value] = true
        tail = tail + 1
        queue[tail], labels[tail], depths[tail] = value, label, depth
      end
    end
  end

  local function child_label(label, depth, suffix)
    if depth >= OWNER_DEPTH then return label, depth end
    return label .. suffix, depth + 1
  end

  -- Modules first, so module tables carry their own names.
  local loaded = package.loaded
  local names = {}
  for name in pairs(loaded) do
    if type(name) == "string" and name ~= "_G" then names[#names + 1] = name end
  end
  table.sort(names)
  for _, name in ipairs(names) do visit(loaded[name], name, 0) end
  visit(_G, "_G", 0)
  visit(debug.getregistry(), "registry", 0)

  local head = 0
  while head < tail do
    head = head + 1
    local value, label, depth = queue[head], labels[head], depths[head]
    queue[head], labels[head], depths[head] = nil, nil, nil
    local kind = type(value)
    if kind == "table" then
      local entries, array = 0, rawlen(value)
      for key, item in next, value do
        entries = entries + 1
        visit(key, label, depth)
        local item_label, item_depth = child_label(label, depth, key_label(key))
        visit(item, item_label, item_depth)
      end
      local bytes = TABLE_BYTES + array * ARRAY_SLOT_BYTES
        + power_of_two(math.max(0, entries - array)) * HASH_NODE_BYTES
      count(label, "table", bytes)
      if bytes >= LARGE_TABLE_BYTES then
        large[#large + 1] = { owner = label, bytes = bytes, entries = entries }
      end
      local metatable = debug.getmetatable(value)
      if metatable then visit(metatable, child_label(label, depth, ".<metatable>")) end
    elseif kind == "function" then
      local upvalues = 0
      local index = 1
      while true do
        local name, item = debug.getupvalue(value, index)
        if not name then break end
        upvalues = index
        if type(item) == "table" or type(item) == "function" or type(item) == "thread"
          or type(item) == "string"
        then
          visit(item, source_name(value) .. ":" .. (name ~= "" and name or "?"), 0)
        end
        index = index + 1
      end
      count(label, "function", CLOSURE_BYTES + upvalues * UPVALUE_BYTES)
    elseif kind == "thread" then
      count(label, "thread", 0)
      local level = 0
      while debug.getinfo(value, level, "f") do
        local index = 1
        while true do
          local name, item = debug.getlocal(value, level, index)
          if not name then break end
          visit(item, child_label(label, depth, ".<thread>." .. name))
          index = index + 1
        end
        visit(debug.getinfo(value, level, "f").func, child_label(label, depth, ".<thread>"))
        level = level + 1
      end
    else
      count(label, kind, 0)
      local metatable = debug.getmetatable(value)
      if metatable then visit(metatable, child_label(label, depth, ".<metatable>")) end
    end
  end

  local rows = {}
  for _, row in pairs(owners) do rows[#rows + 1] = row end
  table.sort(rows, function(a, b) return a.bytes > b.bytes end)
  table.sort(large, function(a, b) return a.bytes > b.bytes end)
  local report = {
    owners = rows,
    large_tables = large,
    heap_kb = heap_kb,
    collect_ms = collect_ms,
    estimate_bytes = total_bytes,
    objects = total_objects,
    walk_ms = (system.get_time() - started) * 1000,
  }
  seen, queue, labels, depths = nil, nil, nil, nil
  collectgarbage("forcecollect")
  return report
end

local function mb(bytes) return bytes / (1024 * 1024) end

---Write a report as text. Owners and large tables are cut to `limit` rows.
function heap_census.format(report, limit)
  limit = limit or 60
  local lines = {
    "Lua heap census",
    string.format("Heap after a full collection: %.1f MB. A full collection of it: %.0f ms.",
      report.heap_kb / 1024, report.collect_ms),
    string.format("Census estimate: %.1f MB in %d objects. Walk: %.0f ms.",
      mb(report.estimate_bytes), report.objects, report.walk_ms),
    "Sizes are estimates. Each object counts once, for the shortest path that reaches it.",
    "",
    string.format("%9s %10s %9s %9s %9s  %s", "MB", "objects", "tables", "strings", "functions", "owner"),
  }
  for index = 1, math.min(limit, #report.owners) do
    local row = report.owners[index]
    lines[#lines + 1] = string.format("%9.2f %10d %9d %9d %9d  %s",
      mb(row.bytes), row.objects, row.tables, row.strings, row.functions, row.owner)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Largest single tables:"
  lines[#lines + 1] = string.format("%9s %10s  %s", "MB", "entries", "owner")
  for index = 1, math.min(limit, #report.large_tables) do
    local row = report.large_tables[index]
    lines[#lines + 1] = string.format("%9.2f %10d  %s", mb(row.bytes), row.entries, row.owner)
  end
  return table.concat(lines, "\n") .. "\n"
end

return heap_census
