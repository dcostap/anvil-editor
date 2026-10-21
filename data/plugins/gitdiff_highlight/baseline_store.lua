-- Shared by the editor and the Project Changes Baseline worker.
local common = require "core.common"
local json = require "core.json"
local bit_ok, bit = pcall(require, "bit")
local store = {}

local function u32(n)
  n = tonumber(n) or 0
  if n < 0 then n = n + 4294967296 end
  return n % 4294967296
end

local function hash_text(text)
  local h1, h2 = 2166136261, 5381
  for i = 1, #text do
    local byte = text:byte(i)
    if bit_ok and bit then
      h1 = bit.tobit(bit.bxor(h1, byte) * 16777619)
      h2 = bit.tobit(h2 * 33 + byte)
    else
      h1 = (h1 * 16777619 + byte) % 4294967296
      h2 = (h2 * 33 + byte) % 4294967296
    end
  end
  return string.format("%08x%08x", u32(h1), u32(h2))
end

function store.identity(buffer)
  if buffer.abs_filename then
    local path = common.normalize_path(buffer.abs_filename)
    if PLATFORM == "Windows" then path = path:lower() end
    return "file:" .. path
  end
  if buffer.intellij_untitled_id then
    local project = common.normalize_path(buffer.intellij_untitled_project_path or "default")
    if PLATFORM == "Windows" then project = project:lower() end
    return "untitled:" .. project .. ":" .. tostring(buffer.intellij_untitled_id)
  end
end

function store.path(directory, identity)
  return identity and (directory .. PATHSEP .. hash_text(identity) .. ".json")
end

function store.in_roots(identity, roots)
  if not identity then return false end
  for _, root in ipairs(roots) do
    local file = identity:match("^file:(.*)$")
    if file and common.path_belongs_to(file, root) then return true end
    local project = common.normalize_path(root)
    if PLATFORM == "Windows" then project = project:lower() end
    local prefix = "untitled:" .. project .. ":"
    if identity:sub(1, #prefix) == prefix then return true end
  end
  return false
end

-- Baseline files are sidecars, not user files. Replace each complete JSON atomically.
function store.write(directory, identity, text, origin, file_id, writer)
  local path = store.path(directory, identity)
  if not path then return false, "Changes Baseline has no identity" end
  local info = system.get_file_info(directory)
  if not (info and info.type == "dir") then
    local made, err = common.mkdirp(directory)
    if not made then return false, err end
  end
  local body = json.encode {
    version = 1, identity = identity, origin = origin, text = text, file_id = file_id,
  }
  if writer then return pcall(writer, path, body) end
  local temporary = path .. ".tmp-" .. tostring(system.get_time())
  local file, err = io.open(temporary, "wb")
  if not file then return false, err end
  local written, write_err = file:write(body)
  local closed, close_err = file:close()
  if not written or not closed then
    os.remove(temporary)
    return false, write_err or close_err
  end
  local replaced, replace_err = system.atomic_replace_file(temporary, path, false)
  if not replaced then os.remove(temporary) end
  return replaced, replace_err
end

return store
