-- Named colors and rule overrides for saved color themes.
local common = require "core.common"

local edits = {}

local function color(value)
  if type(value) ~= "table" then return nil end
  local copy = {}
  for i = 1, 4 do
    if type(value[i]) ~= "number" or value[i] < 0 or value[i] > 255 then return nil end
    copy[i] = math.floor(value[i] + 0.5)
  end
  return copy
end

local function is_color(value)
  return color(value) ~= nil
end

local function collect(entries, container, prefix, seen)
  if seen[container] then return end
  seen[container] = true
  for key, value in pairs(container) do
    if type(key) == "string" or type(key) == "number" then
      local path = prefix .. tostring(key)
      if is_color(value) then
        entries[#entries + 1] = {path = path, container = container, key = key, ref = value, value = color(value)}
      elseif type(value) == "table" and not seen[value] and not value.get_size then
        collect(entries, value, path .. ".", seen)
      end
    end
  end
end

function edits.capture(style)
  local base = {entries = {}, by_path = {}, palette = {}, palette_refs = {}}
  for name, value in pairs(style.theme_palette or {}) do
    if is_color(value) then
      base.palette[name] = color(value)
      base.palette_refs[value] = name
    end
  end
  local seen = {}
  for key, value in pairs(style) do
    if key ~= "theme_palette" and key ~= "syntax_fonts" and type(value) == "table" then
      if is_color(value) then
        base.entries[#base.entries + 1] = {
          path = tostring(key), container = style, key = key, ref = value, value = color(value)
        }
      elseif key == "syntax" then
        -- Never follow the syntax fallback metatable.
        collect(base.entries, value, "syntax.", seen)
      else
        collect(base.entries, value, tostring(key) .. ".", seen)
      end
    end
  end
  table.sort(base.entries, function(a, b) return a.path < b.path end)
  for _, entry in ipairs(base.entries) do
    entry.palette = base.palette_refs[entry.ref]
    base.by_path[entry.path] = entry
  end
  return base
end

function edits.apply(style, base, draft)
  draft = draft or {}
  for name, original in pairs(base.palette) do
    local ref = style.theme_palette[name]
    for i = 1, 4 do ref[i] = original[i] end
  end
  for _, entry in ipairs(base.entries) do
    entry.container[entry.key] = entry.ref
    if not entry.palette then
      for i = 1, 4 do entry.ref[i] = entry.value[i] end
    end
  end
  for name, value in pairs(draft.palette or {}) do
    local ref = style.theme_palette[name]
    local new = color(value)
    if ref and new then for i = 1, 4 do ref[i] = new[i] end end
  end
  for path, rule in pairs(draft.rules or {}) do
    if type(rule) == "table" then
      local entry = base.by_path[path]
      local container, key = entry and entry.container, entry and entry.key
      if not entry then
        key = path:match("^syntax%.(.+)$")
        container = key and style.syntax
      end
      if container then
        if rule.enabled == false then
          if container == style.syntax then container[key] = nil end
        elseif rule.enabled == true then
          local ref = rule.palette and style.theme_palette[rule.palette]
          container[key] = ref or color(rule.color) or (entry and entry.ref)
        end
      end
    end
  end
end

function edits.custom_syntax_keys(base, draft)
  local keys = {}
  for path in pairs(draft and draft.rules or {}) do
    if not base.by_path[path] then
      local key = path:match("^syntax%.(.+)$")
      if key then keys[key] = true end
    end
  end
  return keys
end

local function file_path(root, name)
  if type(name) ~= "string" or not name:match("^[%w_%-]+$") then return nil end
  return root .. "/colors/edits/" .. name .. ".lua"
end

function edits.load(name)
  for _, root in ipairs({USERDIR, DATADIR}) do
    local path = file_path(root, name)
    if path and system.get_file_info(path) then
      local ok, result = pcall(dofile, path)
      if ok and type(result) == "table" then
        return result
      end
      return nil, string.format("Cannot load theme edits from %s: %s", path, tostring(result))
    end
  end
  return {palette = {}, rules = {}}
end

function edits.source_available()
  local info = system.get_file_info(DATADIR .. "/colors")
  return info and info.symlink == true
end

function edits.save(name, draft, source)
  if source and not edits.source_available() then
    return nil, "Source save needs a linked source colors directory"
  end
  local root = source and DATADIR or USERDIR
  local dir = root .. "/colors/edits"
  local path = file_path(root, name)
  if not path then return nil, "Invalid theme name" end
  local colors_dir = root .. "/colors"
  if not system.get_file_info(colors_dir) and not system.mkdir(colors_dir) then
    return nil, "Cannot create " .. colors_dir
  end
  if not system.get_file_info(dir) and not system.mkdir(dir) then
    return nil, "Cannot create " .. dir
  end
  local tmp = path .. ".tmp"
  local fp, err = io.open(tmp, "wb")
  if not fp then return nil, err end
  local ok, write_err = fp:write("return ", common.serialize(draft, {
    pretty = true, escape = true, sort = true
  }), "\n")
  fp:close()
  if not ok then os.remove(tmp); return nil, write_err end
  -- Windows does not replace the target in os.rename. Keep a backup until the new file exists.
  local backup = path .. ".bak"
  os.remove(backup)
  if system.get_file_info(path) then
    local moved, move_err = os.rename(path, backup)
    if not moved then os.remove(tmp); return nil, move_err end
  end
  local moved, move_err = os.rename(tmp, path)
  if not moved then
    os.rename(backup, path)
    os.remove(tmp)
    return nil, move_err
  end
  os.remove(backup)
  if source then os.remove(file_path(USERDIR, name)) end
  return path
end

edits.color = color
return edits
