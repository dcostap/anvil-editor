-- Read and decode away from the UI. The worker channel supplies backpressure.
require "core.encoding"
local worker = {}

function worker.run(payload, context)
  local started = system.get_time()
  local info, err = system.get_file_info(payload.path)
  assert(info and info.type == "file", err or "source file is unavailable")
  local charset, bom = payload.encoding, payload.bom
  local detection_error
  if not charset then
    charset, bom, detection_error = encoding.detect(payload.path)
    charset = charset or "UTF-8"
  elseif bom then
    bom = encoding.get_charset_bom(charset)
  end
  if context.cancelled() then return end
  local file = assert(io.open(payload.path, "rb"))
  local text, read_error = file:read("*a")
  local closed, close_error = file:close()
  assert(text, read_error or "could not read file text")
  assert(closed, close_error)
  if context.cancelled() then return end
  if charset ~= "UTF-8" and charset ~= "ASCII" then
    text = assert(encoding.convert("UTF-8", charset, text, {
      strict = false, handle_from_bom = true,
    }))
  else
    text = encoding.strip_bom(text, "UTF-8")
  end
  local read_ms = (system.get_time() - started) * 1000
  local current = system.get_file_info(payload.path)
  assert(current and current.file_id == info.file_id and current.size == info.size
    and current.modified == info.modified, "source changed during loading")
  -- Count before delivery so the UI can reserve its line arrays once.
  local ends, line_count, first, scan, batch_lines = {}, 0, 1, 1, 0
  while true do
    local newline = text:find("\n", scan, true)
    if not newline then break end
    line_count, batch_lines, scan = line_count + 1, batch_lines + 1, newline + 1
    if batch_lines >= 16384 or newline - first + 1 >= 1024 * 1024 then
      if context.cancelled() then return end
      ends[#ends + 1], first, batch_lines = newline, newline + 1, 0
    end
  end
  if #text == 0 or text:sub(-1) ~= "\n" then line_count = line_count + 1 end
  if ends[#ends] ~= #text then ends[#ends + 1] = #text end
  if not context.send { type = "chunk", payload = { line_count = line_count } } then return end
  first = 1
  for _, last in ipairs(ends) do
    -- Keep complete lines. One very long line can exceed the transfer size.
    -- Transfer text, not line tables: table serialization repeats line creation.
    if not context.send { type = "result", payload = text:sub(first, last) } then return end
    first = last + 1
  end
  context.send { type = "final", payload = {
    encoding = charset, bom = bom,
    info = info, detection_error = detection_error,
    read_ms = read_ms,
  } }
end

return worker
