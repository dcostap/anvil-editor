-- Diagnostic-only capture. Scoring runs never load this module.
local perf = require "core.perf"
local Profile = {}
Profile.__index = Profile

local function quote(value)
  return '"' .. tostring(value or ""):gsub('"', '""') .. '"'
end

function Profile.start(directory, context)
  local self = setmetatable({ directory = directory, rows = {}, keys = 0, samples = 0 }, Profile)
  perf.start_recording {
    base_path = directory .. PATHSEP .. "profile", quiet = true,
    instruction_samples = false, detail_interval = 1,
    context = context,
  }
  local ok, profiler = pcall(require, "jit.profile")
  if ok then
    local started, err = pcall(profiler.start, "li1", function(thread, samples, state)
      local phase, action = context()
      -- Root first; keep full source paths and line numbers for code inspection.
      local stack = profiler.dumpstack(thread, "plZ\n", -64)
      local key = phase .. "\0" .. action .. "\0" .. state .. "\0" .. stack
      local row = self.rows[key]
      if not row and self.keys >= 50000 then
        key = "overflow"
        row = self.rows[key]
        phase, action, state, stack = "overflow", "", "?", "[stack limit reached]"
      end
      if not row then
        row = { phase = phase, action = action, state = state, stack = stack, samples = 0 }
        self.rows[key] = row
        self.keys = self.keys + 1
      end
      row.samples = row.samples + samples
      self.samples = self.samples + samples
    end)
    if started then self.profiler = profiler else self.unavailable = tostring(err) end
  else
    self.unavailable = tostring(profiler)
  end
  return self
end

function Profile:stop()
  if self.stopped then return end
  self.stopped = true
  if self.profiler then self.profiler.stop() end
  perf.stop_recording()
  local file = assert(io.open(self.directory .. PATHSEP .. "stacks.csv", "wb"))
  file:write("phase,action,vmstate,stack,samples\n")
  local keys = {}
  for key in pairs(self.rows) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local row = self.rows[key]
    file:write(table.concat({ quote(row.phase), quote(row.action), quote(row.state),
      quote(row.stack), row.samples }, ","), "\n")
  end
  file:close()
  file = assert(io.open(self.directory .. PATHSEP .. "profile-status.txt", "wb"))
  file:write("sampler=", self.profiler and "LuaJIT" or "unavailable", "\n")
  file:write("samples=", self.samples, "\n")
  file:write("note=", tostring(self.unavailable or "Native stacks are not captured"):gsub("[\r\n]", " "), "\n")
  file:close()
end

return Profile
