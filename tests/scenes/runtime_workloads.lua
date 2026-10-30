-- Preserve focused runtime workloads after their timing assertions move out of tests.
local Buffer = require "core.buffer"
local common = require "core.common"
local core = require "core"
local locations = require "core.text_poi_locations"
local support = require "scenes.support"

local scene = {}
local STREAM_LINE = string.rep("s", 1023)

local function shell_command(command)
  if PLATFORM == "Windows" then return { "cmd", "/V:ON", "/C", command } end
  return { "sh", "-lc", command }
end

local function open_measurement_view(context)
  local target = assert(context.settings.targets and context.settings.targets[1],
    "runtime workload needs a small fixture file")
  return assert(core.open_file(context.path(target), { placement = "current", focus = true }))
end

local function start_process_finalization_workload(context)
  context.processes = {}
  context.weak_processes = setmetatable({}, { __mode = "v" })
  for i = 1, 8 do
    local command = PLATFORM == "Windows"
      and { "ping", "-n", "31", "127.0.0.1" }
      or shell_command("trap '' TERM; exec sleep 30")
    local proc, err = process.start(command, {
      stdin = process.REDIRECT_DISCARD,
      stdout = process.REDIRECT_DISCARD,
      stderr = process.REDIRECT_DISCARD,
    })
    assert(proc, err)
    context.processes[i] = proc
    context.weak_processes[i] = proc
  end
end

local workloads = {
  process_finalize = {
    setup = function(context)
      context.processes_started = false
    end,
    ready = function(context)
      if not context.processes_started then
        start_process_finalization_workload(context)
        context.processes_started = true
      end
      return true
    end,
    run = function(context)
      context.processes = nil
      collectgarbage("collect")
      collectgarbage("collect")
    end,
    verify = function(context)
      for i = 1, 8 do
        if context.weak_processes[i] then return false end
      end
      return true, "8 process handles finalized"
    end,
  },

  process_read_lines = {
    setup = function(context)
      local command
      if PLATFORM == "Windows" then
        command = "for /L %i in (1,1,2048) do @echo " .. STREAM_LINE
      else
        command = "i=0; while [ \"$i\" -lt 2048 ]; do printf '%s\\n' " .. STREAM_LINE
          .. "; i=$((i + 1)); done"
      end
      local proc, err = process.start(shell_command(command), {
        stdin = process.REDIRECT_DISCARD,
        stdout = process.REDIRECT_PIPE,
        stderr = process.REDIRECT_DISCARD,
      })
      assert(proc, err)
      local exit_code, wait_error = proc:wait(process.WAIT_INFINITE, 0.01)
      assert(exit_code == 0, wait_error or ("process exited with " .. tostring(exit_code)))
      context.output_process = proc
    end,
    run = function(context)
      local lines, first_length, last_length = 0, nil, nil
      while true do
        local line, err = context.output_process.stdout:read("line")
        assert(not err, err)
        if not line then break end
        lines = lines + 1
        first_length = first_length or #line
        last_length = #line
      end
      context.output_result = { lines = lines, first_length = first_length, last_length = last_length }
    end,
    verify = function(context)
      local result = context.output_result or {}
      local ok = result.lines == 2048 and result.first_length >= #STREAM_LINE
        and result.last_length >= #STREAM_LINE
      return ok, string.format("%d lines", result.lines or 0)
    end,
  },

  poi_long_field = {
    setup = function(context)
      context.line = string.rep("x", 16000) .. ":2 target.lua:9:4"
    end,
    run = function(context)
      local candidates = locations.extract_line_candidates(context.line, 1, 32)
      local found
      for _, candidate in ipairs(candidates) do
        if candidate.source_path == "target.lua" then found = candidate end
      end
      context.poi_result = found and {
        path = found.source_path,
        line = found.target_line,
        col = found.target_col,
      }
    end,
    verify = function(context)
      local result = context.poi_result
      return result and result.path == "target.lua" and result.line == 9 and result.col == 4,
        "location after 16 KiB field"
    end,
  },

  poi_many_locations = {
    setup = function(context)
      context.line = string.rep("target.lua:9:4 ", 22000)
    end,
    run = function(context)
      local candidates = locations.extract_line_candidates(context.line, 1, 24000)
      local first, last = candidates[1], candidates[#candidates]
      context.poi_result = {
        count = #candidates,
        first_path = first and first.source_path,
        last_line = last and last.target_line,
      }
    end,
    verify = function(context)
      local result = context.poi_result or {}
      local ok = result.count == 22000 and result.first_path == "target.lua" and result.last_line == 9
      return ok, string.format("%d locations", result.count or 0)
    end,
  },

  trimwhitespace_long_line = {
    setup = function(context)
      context.buffer = Buffer()
      context.buffer:insert(1, 1, string.rep(string.rep(" ", 1300) .. "x", 2000))
      context.revision = context.buffer.text_revision
      context.length = #context.buffer.lines[1]
    end,
    run = function(context)
      require("plugins.trimwhitespace").trim(context.buffer)
    end,
    verify = function(context)
      local line = context.buffer.lines[1]
      local ok = context.buffer.text_revision == context.revision
        and #context.buffer.lines == 1
        and #line == context.length
        and line:sub(-2, -2) == "x"
      return ok, "2.6 million-byte line unchanged"
    end,
  },

  markdown_vault_long_padding = {
    setup = function(context)
      local root = USERDIR .. PATHSEP .. "scenario-vault-long-padding"
      local ok, err = common.mkdirp(root)
      assert(ok, err)
      local path = root .. PATHSEP .. "Padded.md"
      local file = assert(io.open(path, "wb"))
      assert(file:write("|" .. string.rep(" ", 20000) .. "|\n"))
      assert(file:close())
      context.vault_index = require("core.markdown.vault_index").get_index(root)
      context.vault_path = path
    end,
    run = function(context)
      context.update_done = false
      core.add_thread(function()
        context.updated = context.vault_index:update_path(context.vault_path)
        context.note_count = context.vault_index:note_count()
        context.update_done = true
      end)
    end,
    verify = function(context)
      if not context.update_done then return false end
      return context.updated == true and context.note_count == 1, "one padded table note indexed"
    end,
  },
}

function scene.setup(context)
  context.workload = assert(workloads[context.settings.workload],
    "unknown runtime workload: " .. tostring(context.settings.workload))
  local view = open_measurement_view(context)
  if context.workload.setup then context.workload.setup(context) end
  return view
end

function scene.ready(context)
  if not support.background_settled(context) then return false end
  return not context.workload.ready or context.workload.ready(context)
end

function scene.action_name(context)
  return context.settings.workload
end

function scene.dispatch(context)
  context.workload.run(context)
end

function scene.action_ready(context)
  return context.workload.verify(context)
end

return scene
