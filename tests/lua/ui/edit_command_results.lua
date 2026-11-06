-- Independent text results and an untouched selection in a second View.
-- The reference edits use immutable strings, not Buffer edit planners.
local core = require "core"
local command = require "core.command"
local config = require "core.config"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local test = require "core.test"
local history = dofile("tests/fixtures/edit_history.lua")
local MARKER = "[#]"

local function position(text, offset)
  local prefix = text:sub(1, offset)
  local _, breaks = prefix:gsub("\n", "")
  return breaks + 1, offset - (prefix:match(".*\n()") or 1) + 2
end

local function offset(buffer, line, col)
  local result = col - 1
  for i = 1, line - 1 do result = result + #buffer.lines[i] end
  return result
end

local function expected_text(buffer, step)
  local text, edits = table.concat(buffer.lines), {}
  for _, l1, c1, l2, c2 in buffer:get_selections(true) do
    local first, last = offset(buffer, l1, c1), offset(buffer, l2, c2)
    local replacement = step.type or step.clipboard
    if step.command == "editor:upper_case" then
      replacement = text:sub(first + 1, last):upper():gsub("é", "É")
    elseif step.command == "editor:lower_case" then
      replacement = text:sub(first + 1, last):lower():gsub("É", "é")
    elseif step.command == "core:delete" or step.command == "core:backspace" then
      replacement = ""
      if first == last then
        if step.command == "core:backspace" and first > 0 then
          first = first - 1
          while first > 0 and text:byte(first + 1) >= 128 and text:byte(first + 1) < 192 do first = first - 1 end
        elseif step.command == "core:delete" and last < #text - 1 then
          last = last + 1
          while last < #text - 1 and text:byte(last + 1) >= 128 and text:byte(last + 1) < 192 do last = last + 1 end
        end
      end
    end
    edits[#edits + 1] = { first = first, last = last, text = replacement }
  end
  table.sort(edits, function(a, b)
    return a.first < b.first or a.first == b.first and a.last < b.last
  end)
  if step.clipboard and #edits > 1 then
    local lines = {}
    for line in (step.clipboard:gsub("\n$", "") .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
    if #lines == #edits then
      for i, edit in ipairs(edits) do edit.text = lines[i] end
    end
  end
  local parts, cursor = {}, 0
  for _, edit in ipairs(edits) do
    if edit.first < cursor then
      -- Several deletions remove their union. No replacement ranges overlap.
      assert(edit.text == "", "invalid reference replacement ranges")
    else
      parts[#parts + 1] = text:sub(cursor + 1, edit.first)
      parts[#parts + 1] = edit.text
    end
    cursor = math.max(cursor, edit.last)
  end
  parts[#parts + 1] = text:sub(cursor + 1)
  return table.concat(parts)
end

local function make_step(rng, text)
  if rng:chance(.15) then return { undo = true, side = rng:chance(.5) } end
  if rng:chance(.1) then return { redo = true, side = rng:chance(.5) } end
  local first, last = assert(text:find(MARKER, 1, true))
  local boundaries = {}
  for col in text:gmatch("()[^\128-\191]") do
    local at = col - 1
    if at < first - 1 or at > last then boundaries[#boundaries + 1] = at end
  end
  if #boundaries == 0 then return { undo = true } end
  local points = {}
  local count = rng:chance(.1) and 20 or rng:int(1, 5)
  for i = 1, count * 2 do points[i] = rng:pick(boundaries) end
  table.sort(points)
  local step = { carets = {} }
  for i = 1, count do
    local a, b = points[i * 2 - 1], points[i * 2]
    if a < first and b >= first or rng:chance(.4) then b = a end
    local l1, c1 = position(text, a)
    local l2, c2 = position(text, b)
    if rng:chance(.5) then l1, c1, l2, c2 = l2, c2, l1, c1 end
    step.carets[i] = { l1, c1, l2, c2 }
  end
  local action = rng:int(1, 6)
  if action == 1 then step.type = rng:pick({ "q", "é", "🙂", "r\ns" })
  elseif action == 2 then
    step.command, step.clipboard = "core:paste_as_plain_text", rng:pick({ "X", "é", "Q\nR" })
  else
    step.command = ({ "core:delete", "core:backspace", "editor:upper_case", "editor:lower_case" })[action - 2]
  end
  return step
end

local function play(scenario, rng, resources)
  -- Removing this marker would change what the second View observes. A
  -- shrink that removes its line is not a valid scenario for this check.
  if not scenario.text:find(MARKER, 1, true) then return end
  local buffer = Buffer()
  resources.buffer = buffer
  buffer:replace_snapshot(scenario.text)
  buffer:set_filename("results.txt")
  local main, side = TextView(buffer), TextView(buffer)
  main.size.x, main.size.y, side.size.x, side.size.y = 800, 600, 800, 600
  local initial = table.concat(buffer.lines)
  local first, last = initial:find(MARKER, 1, true)
  -- Keep brackets around the observed text. Edits at a selection boundary
  -- follow insertion affinity; they need not keep the same selected text.
  local l1, c1 = position(initial, first)
  local l2, c2 = position(initial, last - 1)
  side:with_selection_state(function() buffer:set_selection(l2, c2, l1, c1) end)
  core.set_active_view(main)
  local model = history.model(initial)
  local function validate()
    local text = table.concat(buffer.lines)
    local start, finish = text:find(MARKER, 1, true)
    if not start then return "edit removed the untouched marker" end
    local a, b = position(text, start)
    local c, d = position(text, finish - 1)
    local actual = side:get_selection_state().selections
    if history.serialize(actual) ~= history.serialize({ c, d, a, b }) then
      return "second View lost its selection: " .. history.serialize(actual)
    end
    for _, view in ipairs({ main, side }) do
      local err = view:with_selection_state(function() return history.validate(buffer) end)
      if err then return err end
    end
  end
  local function perform_history(name, use_side)
    core.set_active_view(use_side and side or main)
    assert(command.perform(name), "history command unavailable")
  end
  for i = 1, (rng and scenario.length or #scenario.steps) do
    local step = scenario.steps[i] or make_step(rng, table.concat(buffer.lines))
    scenario.steps[i] = step
    local expected
    if step.undo then perform_history("core:undo", step.side); expected = model:undo()
    elseif step.redo then perform_history("core:redo", step.side); expected = model:redo()
    else
      core.set_active_view(main)
      local flat = {}
      for _, caret in ipairs(step.carets) do
        for j = 1, 4, 2 do
          local line, col = buffer:sanitize_position(caret[j], caret[j + 1])
          while col > 1 and buffer.lines[line]:byte(col) >= 128 and buffer.lines[line]:byte(col) < 192 do col = col - 1 end
          flat[#flat + 1], flat[#flat + 2] = line, col
        end
      end
      buffer:set_selection_list(flat, #flat / 4)
      buffer:merge_cursors()
      -- Case commands without a selection replace the whole Buffer. This
      -- generator checks a second View outside the edited ranges instead.
      if (step.command == "editor:upper_case" or step.command == "editor:lower_case")
        and not buffer:has_selection()
      then
        step.command, step.type = nil, "q"
      end
      local before = table.concat(buffer.lines)
      expected = expected_text(buffer, step)
      -- A shrink can move a saved range onto the protected marker.
      if not expected:find(MARKER, 1, true) then
        assert(not rng, "generated an edit inside the protected marker")
        return
      end
      if step.type then main:with_selection_state(function() main:on_text_input(step.type) end)
      else
        if step.clipboard then
          core.cursor_clipboard, core.cursor_clipboard_whole_line = {}, {}
          system.set_clipboard(step.clipboard)
        end
        assert(command.perform(step.command), "editing command unavailable")
      end
      if expected ~= before then model:changed(expected) end
    end
    local err = history.compare("step " .. i, expected, table.concat(buffer.lines)) or validate()
    if err then return err end
  end
  return history.walk(model,
    function() perform_history("core:undo", true) end,
    function() perform_history("core:redo", false) end,
    function() return table.concat(buffer.lines) end, validate)
end

local function run(scenario, rng)
  local previous, resources, errors = core.active_view, {}, {}
  local log_error = core.error
  core.error = function(fmt, ...) errors[#errors + 1] = string.format(fmt, ...):match("^[^\n]+") end
  local ok, result = pcall(play, scenario, rng, resources)
  core.error = log_error
  if previous then core.set_active_view(previous) end
  if resources.buffer then resources.buffer:on_close() end
  if not ok then return "error: " .. tostring(result):match("^[^\n]+") end
  if #errors > 0 then return table.concat(errors, "\n") end
  return result
end

local regressions = {}

test.describe("Editing command results", function()
  test.before_each(function(context)
    context.previous_view = core.active_view
    context.merge, context.autosave = config.undo_merge_timeout, config.plugins.autosave_fast.enabled
    context.clipboard = system.get_clipboard()
    context.cursors, context.whole = core.cursor_clipboard, core.cursor_clipboard_whole_line
    config.undo_merge_timeout, config.plugins.autosave_fast.enabled = 0, false
  end)
  test.after_each(function(context)
    config.undo_merge_timeout, config.plugins.autosave_fast.enabled = context.merge, context.autosave
    system.set_clipboard(context.clipboard or "")
    core.cursor_clipboard, core.cursor_clipboard_whole_line = context.cursors, context.whole
    if context.previous_view then core.set_active_view(context.previous_view) end
    if context.buffer then context.buffer:on_close() end
  end)
  test.it("matches independent text edits and keeps another View's selection", function()
    local report = history.replay(regressions, run) or history.fuzz({
      runs = 100, run = run,
      generate = function(rng)
        return { text = "abé🙂CD\n[#]\nEfGH\nijk", length = rng:int(3, 12), steps = {} }
      end,
    })
    test.ok(not report, report)
  end)

  test.it("copies each selected part once and restores cuts with plain paste", function(context)
    local buffer = Buffer()
    context.buffer = buffer
    buffer:set_filename("clipboard.txt")
    local view = TextView(buffer)
    core.set_active_view(view)
    local rng = history.rng(731)
    for trial = 1, 100 do
      local lines, parts, carets, cut_lines = {}, {}, {}, {}
      for line = 1, rng:int(2, 24) do
        local part = rng:pick({ "ab", "é", "🙂", "CD", "é🙂AB" })
        lines[line], parts[line], cut_lines[line] = "left" .. part .. "right", part, "leftright"
        local a, b = 5, 5 + #part
        if rng:chance(.5) then a, b = b, a end
        for _, value in ipairs({ line, a, line, b }) do carets[#carets + 1] = value end
      end
      local initial = table.concat(lines, "\n") .. "\n"
      local cut = table.concat(cut_lines, "\n") .. "\n"
      buffer:replace_snapshot(initial:sub(1, -2))
      buffer:clear_undo_redo()
      buffer:set_selection_list(carets, #parts)

      test.ok(command.perform("core:copy"))
      test.equal(system.get_clipboard(), table.concat(parts, "\n"), "copy trial " .. trial)
      test.ok(command.perform("core:cut"))
      test.equal(table.concat(buffer.lines), cut, "cut trial " .. trial)
      test.ok(command.perform("core:undo"))
      test.equal(table.concat(buffer.lines), initial)
      test.ok(command.perform("core:redo"))
      test.equal(table.concat(buffer.lines), cut)
      test.ok(command.perform("core:paste_as_plain_text"))
      test.equal(table.concat(buffer.lines), initial, "paste trial " .. trial)
      test.ok(command.perform("core:undo"))
      test.equal(table.concat(buffer.lines), cut)
      test.ok(command.perform("core:undo"))
      test.equal(table.concat(buffer.lines), initial)
    end
  end)
end)
