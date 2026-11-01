-- Text Search runs ripgrep. In a Project on a Machine, the Machine runs it (`search.start` in `core.serve_search`).
-- Both give the same stream as `core.process_stream`, so callers read lines from either the same way.
local fs = require "core.fs"
local process_stream = require "core.process_stream"

local text_search = {}

local MachineStream = {}
MachineStream.__index = MachineStream

-- Reads from the Machine until the search ends. Each reply carries the output that the Machine has.
local function machine_stream(args, cwd)
  local self = setmetatable({done = false, cancelled = false, buffer = "", pos = 1, parts = {},
    last_output_time = system.get_time()}, MachineStream)
  local function finish(code, err)
    if self.done then return end
    self.done, self.exit_code, self.error = true, code, err
  end
  local function read()
    fs.machine:request("search.read", {id = self.id}, nil, function(err, result, bytes)
      if self.cancelled then return end
      if err then return finish(nil, err.message or err.code) end
      if bytes and bytes ~= "" then
        self.parts[#self.parts + 1] = bytes
        self.last_output_time = system.get_time()
      end
      if result.done then return finish(result.code, result.error) end
      read()
    end)
  end
  fs.machine:request("search.start", {args = args, cwd = cwd}, nil, function(err, result)
    if err then return finish(nil, err.message or err.code) end
    self.id = result.id
    if self.cancelled then
      fs.machine:request("search.cancel", {id = self.id}, nil, function() end)
      return
    end
    read()
  end)
  return self
end

MachineStream.read_until = process_stream.Stream.read_until
MachineStream.read_line = process_stream.Stream.read_line

function MachineStream:take_stderr() end

function MachineStream:cancel()
  if self.done then return end
  self.cancelled, self.done, self.error = true, true, "cancelled"
  self.parts, self.buffer, self.pos = {}, "", 1
  if self.id then fs.machine:request("search.cancel", {id = self.id}, nil, function() end) end
end

-- Starts a ripgrep command in `options.cwd`, as `process_stream.start` does. In a Project on a Machine, the
-- Machine runs it with its own ripgrep.
function text_search.start(args, options)
  if fs.machine and fs.on_machine(options.cwd) then return machine_stream(args, options.cwd) end
  return process_stream.start(args, options)
end

return text_search
