-- Random batch edits, undo and redo on a Buffer, checked against a history
-- model. Set ANVIL_EDIT_HISTORY_RUNS and ANVIL_EDIT_HISTORY_SEED to run more
-- or other seeds. A failure prints its smallest scenario; keep it in
-- `regressions` below.
local Buffer = require "core.buffer"
local config = require "core.config"
local test = require "core.test"
local history = dofile("tests/fixtures/edit_history.lua")

-- Lines with indentation, tabs, table pipes and a multi-byte character.
local LINES = { "", "", "ab", "  x", "| a | b |", "é", "\tz", "abc def", "漢字🙂", string.rep("long\t", 80) }
-- Mostly deletions, because touching deletions undo as inserts at one place.
local TEXTS = { "", "", "", "", "x", "\n", "yz\n", "é", "\n\n", "|", "漢字🙂", "a\r\nb" }

local function set_text(buffer, text)
  buffer.lines = {}
  for line in (text .. "\n"):gmatch("(.-\n)") do
    buffer.lines[#buffer.lines + 1] = line
  end
  buffer:clear_undo_redo()
  buffer:set_selection(1, 1)
end

local function text_of(buffer) return table.concat(buffer.lines) end

-- Offsets between characters, with the positions next to line breaks twice,
-- so that edits often start or end there.
local function boundaries(text)
  local offsets = {}
  local i = 0
  while i <= #text do
    offsets[#offsets + 1] = i
    local byte = text:byte(i + 1)
    if byte == 10 then
      offsets[#offsets + 1] = i
      offsets[#offsets + 1] = i + 1
    end
    if not byte then break end
    local size = byte >= 0xF0 and 4 or byte >= 0xE0 and 3 or byte >= 0xC0 and 2 or 1
    i = i + size
  end
  return offsets
end

local function position(text, offset)
  local before = text:sub(1, offset)
  local _, breaks = before:gsub("\n", "")
  local line_start = before:match(".*\n()") or 1
  return breaks + 1, offset - line_start + 2
end

-- Up to four edits in text order. They never overlap, and often touch.
local function make_edits(rng, text)
  local offsets = boundaries(text:sub(1, -2))
  local count = rng:chance(0.1) and rng:int(17, 24) or rng:int(1, 4)
  local picked = {}
  for i = 1, count * 2 do picked[i] = rng:pick(offsets) end
  table.sort(picked)
  local edits = {}
  for i = 1, count do
    local start, finish = picked[i * 2 - 1], picked[i * 2]
    if i > 1 and rng:chance(0.5) then start = picked[i * 2 - 2] end
    local line1, col1 = position(text, start)
    local line2, col2 = position(text, finish)
    edits[i] = { line1, col1, line2, col2, rng:pick(TEXTS) }
  end
  return edits
end

local function make_step(rng, text)
  if rng:chance(0.15) then return { undo = true } end
  if rng:chance(0.1) then return { redo = true } end
  if rng:chance(0.08) then return { save = true } end
  if rng:chance(0.15) then
    local lines = {}
    for i = 1, rng:int(1, 5) do lines[i] = rng:pick(LINES) .. "\n" end
    return { reload = lines }
  end
  return { edits = make_edits(rng, text) }
end

-- A burst is one user-visible undo group. Long gaps separate bursts;
-- edits inside a burst use the real merge timeout and a controlled clock.
local function run_bursts(scenario, rng)
  local buffer = Buffer()
  set_text(buffer, scenario.text)
  local model = history.model(text_of(buffer))
  local clock = 100
  local timeout = config.undo_merge_timeout
  for i = 1, (rng and scenario.length or #scenario.steps) do
    local step = scenario.steps[i]
    if not step then
      if rng:chance(0.2) then step = { undo = true }
      elseif rng:chance(0.15) then step = { redo = true }
      else step = { batches = {}, count = rng:int(1, 5) } end
      scenario.steps[i] = step
    end
    local err
    if step.undo then
      buffer:undo()
      err = history.compare("burst undo", model:undo(), text_of(buffer))
    elseif step.redo then
      buffer:redo()
      err = history.compare("burst redo", model:redo(), text_of(buffer))
    else
      clock = clock + timeout * 2
      local changed = false
      for j = 1, (rng and step.count or #step.batches) do
        local edits = step.batches[j] or make_edits(rng, text_of(buffer))
        step.batches[j] = edits
        local batch = {}
        for k, edit in ipairs(edits) do
          batch[k] = { line1 = edit[1], col1 = edit[2], line2 = edit[3], col2 = edit[4], text = edit[5] }
        end
        local tx = buffer:apply_edits(batch, { time = clock })
        changed = changed or tx.changed
        clock = clock + timeout / 10
      end
      if changed then model:changed(text_of(buffer)) end
    end
    if err then return err end
  end
  return history.walk(model, function() buffer:undo() end, function() buffer:redo() end,
    function() return text_of(buffer) end)
end

local function play(scenario, rng)
  local buffer = Buffer()
  set_text(buffer, scenario.text)
  buffer.new_file = false
  buffer:clean()
  local model = history.model(text_of(buffer))
  local saved = 1
  local function changed()
    if saved and saved > model.index then saved = nil end
    model:changed(text_of(buffer))
  end
  local function validate()
    -- Saved Buffers track history positions, not text equality. A separate
    -- edit that restores identical bytes can still count as unsaved.
    if buffer:is_dirty() ~= (model.index ~= saved) then return "wrong saved history state" end
  end
  local length = rng and scenario.length or #scenario.steps
  for i = 1, length do
    local step = scenario.steps[i] or make_step(rng, text_of(buffer))
    scenario.steps[i] = step
    local before = text_of(buffer)
    local err
    if step.undo then
      buffer:undo()
      err = history.compare("step " .. i .. " undo", model:undo(), text_of(buffer))
    elseif step.redo then
      buffer:redo()
      err = history.compare("step " .. i .. " redo", model:redo(), text_of(buffer))
    elseif step.save then
      buffer:clean()
      saved = model.index
    elseif step.reload then
      local tx = buffer:apply_lines(step.reload, "reload")
      if tx.rejected then return "reload rejected: " .. tostring(tx.reason) end
      err = history.compare("reload text", table.concat(step.reload), text_of(buffer))
      if err then return err end
      if tx.changed then changed() end
      buffer:clean()
      saved = model.index
    else
      local edits = {}
      for j, edit in ipairs(step.edits) do
        edits[j] = { line1 = edit[1], col1 = edit[2], line2 = edit[3], col2 = edit[4], text = edit[5] }
      end
      local tx = buffer:apply_edits(edits)
      if tx.rejected then
        err = history.compare("step " .. i .. " rejected edits", before, text_of(buffer))
      elseif tx.changed then
        -- Each changed batch is one step, also when its edits give the same text.
        changed()
      end
    end
    if err then return err end
    err = validate()
    if err then return "step " .. i .. ": " .. err end
    -- Batch APIs take byte positions. A shrink can supply positions inside
    -- UTF-8, so only command tests require character-boundary selections.
    for _, line in ipairs(buffer.lines) do
      if line:sub(-1) ~= "\n" then return "line has no final newline" end
    end
  end
  return history.walk(model, function() buffer:undo() end, function() buffer:redo() end,
    function() return text_of(buffer) end, validate)
end

local function run(scenario, rng)
  local ok, result = pcall(play, scenario, rng)
  if not ok then return "error: " .. tostring(result) end
  return result
end

local function generate(rng)
  local lines = {}
  for i = 1, rng:int(1, 6) do lines[i] = rng:pick(LINES) end
  return { text = table.concat(lines, "\n"), length = rng:int(1, 12), steps = {} }
end

-- Scenarios that failed once. Each one stays as a fixed case.
local regressions = {
  -- Inserts on both sides of the final empty line share one Buffer position.
  { text = "", steps = { { reload = { "a\n", "\n", "b\n" } } } },
  -- Backspace with carets at a line's end and at the next line's start.
  { text = "| a |\n| b |", steps = { { edits = { { 1, 5, 1, 6, "" }, { 1, 6, 2, 1, "" } } } } },
  -- Touching edits that cancel out: their undo must still give a redo step.
  {
    text = "",
    steps = {
      { edits = { { 1, 1, 1, 1, "yz\n" } } },
      { edits = { { 1, 1, 1, 3, "yz\n" } } },
      { edits = { { 1, 3, 2, 1, "\n\n" }, { 2, 1, 3, 1, "" } } },
      { edits = { { 2, 1, 2, 1, "|" } } },
    },
  },
}

test.describe("Buffer edit history", function()
  test.before_each(function(context)
    context.merge = config.undo_merge_timeout
    config.undo_merge_timeout = 0
  end)

  test.after_each(function(context)
    config.undo_merge_timeout = context.merge
  end)

  test.it("undoes and redoes each kept scenario through every state", function()
    local report = history.replay(regressions, run)
    test.ok(not report, report)
  end)

  test.it("undoes and redoes random batch edits through every state", function()
    local report = history.fuzz({ runs = 400, generate = generate, run = run })
    test.ok(not report, report)
  end)

  test.it("undoes and redoes timed edit bursts without unseen states", function(context)
    config.undo_merge_timeout = context.merge
    local report = history.fuzz({ runs = 100, generate = generate, run = run_bursts })
    test.ok(not report, report)
  end)

  test.it("restores the caret before a legacy insert beside Unicode", function(context)
    config.undo_merge_timeout = context.merge
    local buffer = Buffer()
    set_text(buffer, "🙂b")
    buffer:set_selection(1, 5)
    -- raw_insert also writes a selection-only undo entry.
    buffer:raw_insert(1, 1, "x", buffer.undo_stack, 100)
    buffer:undo()
    test.equal(text_of(buffer), "🙂b\n")
    test.same(buffer.selections, { 1, 5, 1, 5 })
    test.ok(not history.validate(buffer))
    buffer:redo()
    test.equal(text_of(buffer), "x🙂b\n")
    test.same(buffer.selections, { 1, 6, 1, 6 })
    test.ok(not history.validate(buffer))
  end)
end)
