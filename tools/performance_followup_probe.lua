local core = require "core"
local test = require "core.test"
local command = require "core.command"
local config = require "core.config"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local panes = require "core.panes"
local treesitter = require "core.treesitter"
local perf = require "core.perf"
local pool = require "core.worker_pool"
local autosave = require "plugins.autosave_fast"
require "plugins.intellij_actions"

local function report(name, samples)
  table.sort(samples)
  print(string.format("PROBE %s median=%.3f p95=%.3f max=%.3f", name,
    samples[math.ceil(#samples / 2)], samples[math.ceil(#samples * .95)], samples[#samples]))
end

local function settle(buffer)
  local started = system.get_time()
  repeat
    treesitter.poll_buffer(buffer)
    local ts = buffer.treesitter
    if not ts or (not ts.pending_parse_thread and not ts.latest_parse_pending
      and ts.status ~= "queued" and ts.status ~= "parsing" and ts.status ~= "stale") then return end
    coroutine.yield(.001)
    assert(system.get_time() - started < 60, "parse exceeded one minute")
  until false
end

test.it("measures snapshots, next occurrence, open, and save on 450000 lines", function()
  local path = USERDIR .. PATHSEP .. "performance-large.c"
  local autosave_enabled = autosave.enabled
  autosave.enabled = false
  local f = assert(io.open(path, "wb"))
  local text = "int input = input + 1; /* input */\n"
  for _ = 1, 450000 do f:write(text) end
  f:close()
  print("PROBE fixture lines=450000 bytes=" .. #text * 450000)
  local stages = {}
  local begin, finish = perf.file_open_stage_begin, perf.file_open_stage_end
  perf.file_open_stage_begin = function(name) return { name, system.get_time() } end
  perf.file_open_stage_end = function(token)
    if not token then return end
    stages[token[1]] = (stages[token[1]] or 0) + (system.get_time() - token[2]) * 1000
  end
  local started = system.get_time()
  local buffer = core.open_buffer(path)
  print(string.format("PROBE open_ms=%.3f", (system.get_time() - started) * 1000))
  for name, ms in pairs(stages) do print(string.format("PROBE open_stage %s=%.3f", name, ms)) end
  perf.file_open_stage_begin, perf.file_open_stage_end = begin, finish
  local view = panes.place(function() return Editor(buffer) end, { placement = "new", focus = true })
  view.size.x, view.size.y = 1100, 800
  view:set_wrapping_enabled(false)
  treesitter.attach_or_update_buffer(buffer, "probe")
  settle(buffer)
  local ts = buffer.treesitter
  local bytes, snapshot_ms, constructed, completed, canceled, failed = 0, 0, 0, 0, 0, 0
  local mt = debug.getmetatable(ts.native).__index
  local schedule, poll = mt.schedule_parse, mt.poll
  local generation, failed_generation = ts.native:tree_generation(), nil
  mt.schedule_parse = function(state, lines, ...)
    if state ~= ts.native then return schedule(state, lines, ...) end
    local status = state:status()
    local t = system.get_time()
    local results = table.pack(schedule(state, lines, ...))
    snapshot_ms = snapshot_ms + (system.get_time() - t) * 1000
    if results[1] then
      constructed = constructed + 1
      bytes = bytes + (type(results[2]) == "number" and results[2]
        or #text * 450000 + #lines[100] - #text)
      if status == "queued" or status == "parsing" then canceled = canceled + 1 end
    end
    return table.unpack(results, 1, results.n)
  end
  mt.poll = function(state, ...)
    local results = table.pack(poll(state, ...))
    if state == ts.native then
      local current = state:tree_generation()
      if current ~= generation then completed = completed + 1; generation = current end
      local status = state:status()
      current = state:generation()
      if status == "failed" and current ~= failed_generation then
        failed = failed + 1; failed_generation = current
      end
    end
    return table.unpack(results, 1, results.n)
  end
  local edits, frames = {}, {}
  for _ = 1, 20 do
    started = system.get_time()
    buffer:insert(100, 1, " ")
    edits[#edits + 1] = (system.get_time() - started) * 1000
    started = system.get_time()
    treesitter.poll_all()
    frames[#frames + 1] = (system.get_time() - started) * 1000 + edits[#edits]
    coroutine.yield(.001)
  end
  settle(buffer)
  mt.schedule_parse, mt.poll = schedule, poll
  print(string.format("PROBE snapshots bytes=%d ui_ms=%.3f constructed=%d status=%s reason=%s completed=%d canceled=%d failed=%d",
    bytes, snapshot_ms, constructed, ts.status, tostring(ts.reason), completed, canceled, failed))
  report("treesitter_edit_ms", edits)
  report("treesitter_edit_poll_ms", frames)
  local previous = config.select_add_next_no_case
  core.set_active_view(view)
  for _, no_case in ipairs { false, true } do
    config.select_add_next_no_case = no_case
    local samples = {}
    view:with_selection_state(function() buffer:set_selection(200000, 10, 200000, 5) end)
    for _ = 1, 76 do
      started = system.get_time()
      test.ok(command.perform("editor:add_selection_next_occurrence"))
      samples[#samples + 1] = (system.get_time() - started) * 1000
    end
    report(no_case and "next_no_case_ms" or "next_ms", samples)
  end
  config.select_add_next_no_case = previous
  local io_times = {}
  local sync, replace = system.sync_file, system.atomic_replace_file
  system.sync_file = function(...)
    local t = system.get_time()
    local results = table.pack(sync(...))
    io_times.sync = (io_times.sync or 0) + (system.get_time() - t) * 1000
    return table.unpack(results, 1, results.n)
  end
  system.atomic_replace_file = function(...)
    local t = system.get_time()
    local results = table.pack(replace(...))
    io_times.replace = (io_times.replace or 0) + (system.get_time() - t) * 1000
    return table.unpack(results, 1, results.n)
  end
  started = system.get_time()
  buffer:save()
  print(string.format("PROBE save_ms=%.3f sync_ms=%.3f replace_ms=%.3f dirty=%s", (system.get_time() - started) * 1000,
    io_times.sync or 0, io_times.replace or 0, tostring(buffer:is_dirty())))
  system.sync_file, system.atomic_replace_file = sync, replace
  if buffer.save_async then
    buffer:insert(100, 1, " ")
    started = system.get_time()
    local committed_ms
    local request = assert(buffer:save_async(function()
      committed_ms = (system.get_time() - started) * 1000
    end))
    local dispatch = (system.get_time() - started) * 1000
    repeat request.pool:drain { max_ms = 5 }; coroutine.yield(.001) until request.status ~= "pending"
    test.equal(request.status, "saved", request.error)
    print(string.format("PROBE async_save dispatch_ms=%.3f complete_ms=%.3f dirty=%s", dispatch,
      (system.get_time() - started) * 1000, tostring(buffer:is_dirty())))
    print(string.format("PROBE async_save worker_ms=%.3f write_ms=%.3f sync_ms=%.3f completion_ms=%.3f",
      request.worker_ms or 0, request.write_ms or 0, request.sync_ms or 0, request.completion_ms or 0))
    print(string.format("PROBE async_save queue_ms=%.3f delivery_ms=%.3f", request.queue_ms or 0, request.delivery_ms or 0))
    print(string.format("PROBE async_save committed_ms=%.3f resumed_ms=%.3f", committed_ms or -1,
      (system.get_time() - started) * 1000))
    autosave.enabled = autosave_enabled
    buffer:insert(100, 1, " ")
    started = system.get_time()
    local approved, approved_ms = false, nil
    view:can_close(function()
      approved, approved_ms = true, (system.get_time() - started) * 1000
    end)
    dispatch = (system.get_time() - started) * 1000
    local deadline = system.get_time() + 30
    repeat
      pool.system():drain { max_ms = 5 }; coroutine.yield(.001)
      assert(system.get_time() < deadline, "close did not finish")
    until approved
    print(string.format("PROBE close dispatch_ms=%.3f approved_ms=%.3f dirty=%s", dispatch,
      approved_ms, tostring(buffer:is_dirty())))
  else
    autosave.enabled = autosave_enabled
    buffer:insert(100, 1, " ")
    started = system.get_time()
    local approved = false
    view:can_close(function() approved = true end)
    test.ok(approved)
    print(string.format("PROBE close dispatch_ms=%.3f dirty=%s", (system.get_time() - started) * 1000,
      tostring(buffer:is_dirty())))
  end
  buffer:clean()
  panes.reset_for_tests()
  treesitter.close_buffer(buffer)
  os.remove(path)
  autosave.enabled = autosave_enabled
end)
