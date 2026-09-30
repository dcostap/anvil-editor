local worker = {}

function worker.run(payload, context)
  local started = system.get_time()
  local write_ms, sync_ms
  if context.cancelled() then return end
  local fp = assert(io.open(payload.path, "wb"))
  local ok, err = pcall(function()
    if payload.bom then assert(fp:write(payload.bom)) end
    local text = payload.text
    if payload.crlf then text = text:gsub("\n", "\r\n") end
    local stage = system.get_time()
    assert(fp:write(text))
    assert(fp:flush())
    write_ms = (system.get_time() - stage) * 1000
    stage = system.get_time()
    assert(system.sync_file(fp))
    sync_ms = (system.get_time() - stage) * 1000
  end)
  local closed, close_err = fp:close()
  if not ok or not closed or context.cancelled() then
    os.remove(payload.path)
    if not ok then error(err) end
    if not closed then error(close_err) end
    return
  end
  -- A cancelled send must not leave a complete but unused temporary file.
  if not context.send { type = "final", write_ms = write_ms, sync_ms = sync_ms,
    queue_ms = payload.queued_at and (started - payload.queued_at) * 1000,
    finished_at = system.get_time(), prepared_ms = (system.get_time() - started) * 1000 } then os.remove(payload.path) end
end

return worker
