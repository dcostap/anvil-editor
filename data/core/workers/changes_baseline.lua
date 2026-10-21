local store = require "plugins.gitdiff_highlight.baseline_store"
local json = require "core.json"
require "core.encoding"
local worker = {}

local function read_text(path, limit)
  local info = system.get_file_info(path)
  if not info or info.type ~= "file" or info.size > limit then return nil end
  local file, err = io.open(path, "rb")
  if not file then return nil, err end
  local text = file:read(limit + 1)
  file:close()
  if not text then return nil, "Cannot read " .. path end
  if #text > limit then return nil end
  local charset = encoding.detect(path)
  if not charset then return nil end
  if charset ~= "UTF-8" then
    text, err = encoding.convert("UTF-8", charset, text, { strict = true, handle_from_bom = true })
    if not text then return nil, err end
  else
    text = encoding.strip_bom(text, "UTF-8")
  end
  if text:find("\0", 1, true) then return nil end
  local lines, _, _, _, binary = encoding.split_lines(text)
  if binary then return nil end
  text = table.concat(lines)
  if #text > limit then return nil end
  local current = system.get_file_info(path)
  if not current or current.file_id ~= info.file_id or current.modified ~= info.modified
    or current.size ~= info.size then return nil, "File changed during capture: " .. path end
  return text, nil, info.file_id
end

function worker.run(payload, context)
  local count, skipped, failed, first_error = 0, 0, 0, nil
  local function failure(err)
    failed, first_error = failed + 1, first_error or tostring(err)
  end
  if payload.operation == "set" then
    for _, entry in ipairs(payload.entries) do
      if context.cancelled() then return end
      local text, err, file_id = read_text(entry.path, payload.max_file_size)
      if text then
        local ok
        ok, err = store.write(payload.directory, entry.identity, text, "manual", file_id)
        if ok then count = count + 1 else failure(err) end
      elseif err then failure(err)
      else skipped = skipped + 1 end
    end
  else
    assert(payload.operation == "clear", "Unknown Changes Baseline operation")
    for _, name in ipairs(system.list_dir(payload.directory) or {}) do
      if context.cancelled() then return end
      if name:match("%.json$") then
        local path = payload.directory .. PATHSEP .. name
        local file = io.open(path, "rb")
        if file then
          local body = file:read(payload.max_file_size * 6 + 4097)
          file:close()
          local ok, data = pcall(json.decode, body or "")
          if ok and type(data) == "table" and type(data.identity) == "string"
            and store.in_roots(data.identity, payload.roots) then
            local removed, err = os.remove(path)
            if removed then count = count + 1 else failure(err) end
          end
        else failure("Cannot read Changes Baseline: " .. path) end
      end
    end
  end
  context.send { type = "result", payload = {
    count = count, skipped = skipped, failed = failed, error = first_error,
  } }
end

return worker
