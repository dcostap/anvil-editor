-- Shared parts of the edit history tests: a seeded random source, the
-- history model, the shrinker and a printer for failing scenarios.
--
-- A scenario is plain data: { text = "...", steps = { step, ... } }. A test
-- file gives `run(scenario, rng)`. It plays the steps and returns an error
-- text, or nil. With `rng`, it also makes each missing step from the text of
-- that moment, and stores it in `scenario.steps`. So a scenario that fails
-- plays again in the same way from its printed steps.
local edit_history = {}

local MAX = 2 ^ 31

---A seeded random source (Park-Miller), the same on each run and platform.
function edit_history.rng(seed)
  local state = math.floor(seed) % (MAX - 1) + 1
  local rng = {}
  function rng:float()
    state = state * 16807 % (MAX - 1)
    return state / (MAX - 1)
  end
  function rng:int(a, b) return a + math.floor(self:float() * (b - a + 1)) end
  function rng:chance(p) return self:float() < p end
  function rng:pick(list) return list[self:int(1, #list)] end
  return rng
end

---Keys in the order that a scenario prints them.
local KEY_ORDER = { "seed", "text", "length", "undo", "redo", "carets", "edits", "command", "type", "clipboard" }

local function serialize(value, indent)
  indent = indent or ""
  if type(value) == "string" then return (string.format("%q", value):gsub("\\\n", "\\n")) end
  if type(value) ~= "table" then return tostring(value) end
  local parts, seen = {}, {}
  local is_list = #value > 0
  local inner = indent .. "  "
  for _, item in ipairs(value) do
    parts[#parts + 1] = serialize(item, inner)
  end
  local keys = {}
  for _, key in ipairs(KEY_ORDER) do
    if value[key] ~= nil then keys[#keys + 1] = key; seen[key] = true end
  end
  local extra = {}
  for key in pairs(value) do
    if type(key) == "string" and not seen[key] then extra[#extra + 1] = key end
  end
  table.sort(extra)
  for _, key in ipairs(extra) do keys[#keys + 1] = key end
  for _, key in ipairs(keys) do
    parts[#parts + 1] = key .. " = " .. serialize(value[key], inner)
  end
  local flat = "{ " .. table.concat(parts, ", ") .. " }"
  if #parts == 0 then return "{}" end
  if #flat <= 100 and not (is_list and type(value[1]) == "table" and #flat > 60) then return flat end
  return "{\n" .. inner .. table.concat(parts, ",\n" .. inner) .. ",\n" .. indent .. "}"
end
edit_history.serialize = serialize

---The history model. Each change of the text adds a state after the current
---one and drops the states that redo could reach. Undo and redo move between
---the states.
function edit_history.model(text)
  local model = { states = { text }, index = 1 }
  function model:changed(new_text)
    for i = #self.states, self.index + 1, -1 do self.states[i] = nil end
    self.states[#self.states + 1] = new_text
    self.index = #self.states
  end
  function model:undo()
    self.index = math.max(1, self.index - 1)
    return self.states[self.index]
  end
  function model:redo()
    self.index = math.min(#self.states, self.index + 1)
    return self.states[self.index]
  end
  return model
end

local function show(text)
  return (string.format("%q", text):gsub("\\\n", "\\n"))
end

---Checks that `actual` is `expected`, and returns an error text otherwise.
function edit_history.compare(what, expected, actual)
  if expected == actual then return nil end
  return string.format("%s: expected %s but got %s", what, show(expected), show(actual))
end

---Undoes back to the first state, then redoes to the last one. `undo` and
---`redo` change the text, and `text` reads it.
function edit_history.walk(model, undo, redo, text, validate)
  local last = #model.states
  while model.index > 1 do
    undo()
    local err = edit_history.compare("undo to state " .. (model.index - 1), model:undo(), text())
    if not err and validate then err = validate() end
    if err then return err end
  end
  undo()
  local err = edit_history.compare("undo at the oldest state", model.states[1], text())
  if not err and validate then err = validate() end
  if err then return err end
  while model.index < last do
    redo()
    local err = edit_history.compare("redo to state " .. (model.index + 1), model:redo(), text())
    if not err and validate then err = validate() end
    if err then return err end
  end
  -- Undo and redo at the ends of the history change nothing.
  redo()
  local err = edit_history.compare("redo at the newest state", model.states[last], text())
  if not err and validate then err = validate() end
  if err then return err end
end

---Check the public text and selection invariants after an edit or history move.
function edit_history.validate(buffer)
  if #buffer.lines == 0 then return "Buffer has no lines" end
  for i, line in ipairs(buffer.lines) do
    if line:sub(-1) ~= "\n" then return "line " .. i .. " has no final newline" end
  end
  for _, line1, col1, line2, col2 in buffer:get_selections() do
    for _, point in ipairs({ { line1, col1 }, { line2, col2 } }) do
      local line, col = point[1], point[2]
      if not buffer.lines[line] or col < 1 or col > #buffer.lines[line] then
        return "selection outside the text: " .. line .. ":" .. col
      end
      local byte = buffer.lines[line]:byte(col)
      if byte >= 128 and byte < 192 then return "selection inside a UTF-8 character" end
    end
  end
end

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[key] = copy(item) end
  return result
end

-- Smaller forms of a scenario: one step less, one item less in a list of a
-- step, or one line less in the start text.
local function smaller(scenario)
  local candidates = {}
  for i = #scenario.steps, 1, -1 do
    local candidate = copy(scenario)
    table.remove(candidate.steps, i)
    candidates[#candidates + 1] = candidate
  end
  for i, step in ipairs(scenario.steps) do
    for _, field in ipairs({ "carets", "edits", "batches" }) do
      local list = step[field]
      if type(list) == "table" and #list > 1 then
        for j = #list, 1, -1 do
          local candidate = copy(scenario)
          table.remove(candidate.steps[i][field], j)
          candidates[#candidates + 1] = candidate
        end
      end
    end
  end
  local lines = {}
  for line in (scenario.text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  if #lines > 1 then
    for i = #lines, 1, -1 do
      local candidate = copy(scenario)
      local kept = {}
      for j, line in ipairs(lines) do if j ~= i then kept[#kept + 1] = line end end
      candidate.text = table.concat(kept, "\n")
      candidates[#candidates + 1] = candidate
    end
  end
  return candidates
end

---Returns the smallest form of a failing scenario that still fails.
function edit_history.shrink(scenario, run)
  scenario = copy(scenario)
  scenario.length = nil
  local err = run(copy(scenario))
  local changed = true
  while changed do
    changed = false
    for _, candidate in ipairs(smaller(scenario)) do
      local candidate_err = run(copy(candidate))
      if candidate_err then
        scenario, err, changed = candidate, candidate_err, true
        break
      end
    end
  end
  return scenario, err
end

---Plays each kept scenario. Returns nil, or a report of all that fail.
function edit_history.replay(scenarios, run)
  local reports = {}
  for i, scenario in ipairs(scenarios) do
    local err = run(copy(scenario))
    if err then reports[#reports + 1] = "regression " .. i .. ": " .. err end
  end
  if #reports > 0 then return table.concat(reports, "\n") end
end

---Runs `run` for each seed. Returns nil, or a report with the smallest form of
---the first failing scenario as a Lua table that the test file can keep.
---ANVIL_EDIT_HISTORY_ALL=1 reports all failing seeds.
function edit_history.fuzz(opts)
  local first = tonumber(os.getenv("ANVIL_EDIT_HISTORY_SEED")) or 1
  local count = tonumber(os.getenv("ANVIL_EDIT_HISTORY_RUNS")) or opts.runs
  local all = os.getenv("ANVIL_EDIT_HISTORY_ALL") == "1"
  local reports = {}
  for seed = first, first + count - 1 do
    local rng = edit_history.rng(seed)
    local scenario = opts.generate(rng)
    scenario.seed = seed
    local err = opts.run(scenario, rng)
    if err then
      local small, small_err = edit_history.shrink(scenario, opts.run)
      reports[#reports + 1] = string.format(
        "seed %d: %s\nsmallest failing scenario (%s):\n%s",
        seed, err, small_err or "it passed when played again", serialize(small)
      )
      if not all then break end
    end
  end
  if #reports > 0 then return table.concat(reports, "\n\n") end
end

return edit_history
