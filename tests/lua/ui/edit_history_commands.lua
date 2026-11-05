-- Random carets and editing commands, then undo and redo, checked against a
-- history model. Set ANVIL_EDIT_HISTORY_RUNS and ANVIL_EDIT_HISTORY_SEED to
-- run more or other seeds. A failure prints its smallest scenario; keep it in
-- `regressions` below.
local core = require "core"
local command = require "core.command"
local config = require "core.config"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local test = require "core.test"
local history = dofile("tests/fixtures/edit_history.lua")

local FILES = { "fuzz.lua", "fuzz.txt", "fuzz.md" }
local LINES = {
  "", "", "if ok then", "  x = 1", "end", "  -- note", "\tz", "é", "abc def", "| a | b |", "  ",
}
local COMMANDS = {
  "core:backspace", "core:backspace", "core:backspace", "core:delete", "core:delete",
  "core:delete_to_previous_word_start", "core:delete_to_next_word_end",
  "core:delete_to_start_of_line", "core:delete_to_end_of_line",
  "core:newline", "core:newline_below", "core:newline_above",
  "core:indent", "core:unindent", "editor:join_lines", "editor:duplicate_lines",
  "editor:delete_lines", "editor:move_lines_up", "editor:move_lines_down",
  "editor:toggle_line_comments", "editor:upper_case", "editor:lower_case",
  "core:cut", "core:copy", "core:paste",
}
local TYPED = { "x", "ab", "(", ")", "\"", "{", "}", " ", "é" }
local CLIPBOARDS = { "y", "two\nlines", "line\n", "\n", "  indented\n  block" }

local function set_text(buffer, text)
  buffer.lines = {}
  for line in (text .. "\n"):gmatch("(.-\n)") do
    buffer.lines[#buffer.lines + 1] = line
  end
  buffer:clear_undo_redo()
  buffer:clean()
  buffer:set_selection(1, 1)
end

local function text_of(buffer) return table.concat(buffer.lines) end

-- Caret positions that edits often meet: line starts, the end of the
-- indentation, line ends, and the other character boundaries.
local function positions(buffer)
  local result = {}
  for line, text in ipairs(buffer.lines) do
    local body = text:gsub("\n$", "")
    result[#result + 1] = { line, 1 }
    result[#result + 1] = { line, #(body:match("^[ \t]*")) + 1 }
    result[#result + 1] = { line, #body + 1 }
    for col in body:gmatch("()[^\128-\191]") do result[#result + 1] = { line, col } end
    result[#result + 1] = { line, #body + 1 }
  end
  return result
end

local function before(a, b) return a[1] < b[1] or a[1] == b[1] and a[2] < b[2] end

-- Up to five carets or selections in text order. They never overlap, and
-- often touch.
local function make_carets(rng, buffer)
  local all = positions(buffer)
  local count = rng:int(1, 5)
  local picked = {}
  for i = 1, count * 2 do picked[i] = rng:pick(all) end
  table.sort(picked, before)
  local carets = {}
  for i = 1, count do
    local a, b = picked[i * 2 - 1], picked[i * 2]
    if rng:chance(0.6) then b = a end
    if rng:chance(0.3) then a, b = b, a end
    carets[i] = { a[1], a[2], b[1], b[2] }
  end
  return carets
end

local function make_step(rng, buffer)
  if rng:chance(0.12) then return { undo = true } end
  if rng:chance(0.08) then return { redo = true } end
  local step = { carets = make_carets(rng, buffer) }
  if rng:chance(0.25) then
    step.type = rng:pick(TYPED)
  else
    step.command = rng:pick(COMMANDS)
    if step.command == "core:paste" and rng:chance(0.5) then
      step.clipboard = rng:pick(CLIPBOARDS)
    end
  end
  return step
end

local function set_carets(buffer, carets)
  local flat = {}
  for _, caret in ipairs(carets) do
    for i = 1, 4 do flat[#flat + 1] = caret[i] end
  end
  buffer:set_selection_list(flat, #carets)
  buffer:merge_cursors()
end

local function play(scenario, rng)
  local buffer = Buffer()
  set_text(buffer, scenario.text)
  buffer:set_filename(scenario.file, scenario.file)
  local view = TextView(buffer)
  view.size.x, view.size.y = 800, 600
  core.set_active_view(view)
  core.cursor_clipboard, core.cursor_clipboard_whole_line = {}, {}
  system.set_clipboard("")
  view:update()

  local model = history.model(text_of(buffer))
  local length = rng and scenario.length or #scenario.steps
  for i = 1, length do
    local step = scenario.steps[i] or make_step(rng, buffer)
    scenario.steps[i] = step
    local err
    if step.undo then
      command.perform("core:undo")
      view:update()
      err = history.compare("step " .. i .. " undo", model:undo(), text_of(buffer))
    elseif step.redo then
      command.perform("core:redo")
      view:update()
      err = history.compare("step " .. i .. " redo", model:redo(), text_of(buffer))
    else
      set_carets(buffer, step.carets)
      view:update()
      -- Moving the carets can empty a whitespace-only line. That cleanup
      -- undoes with the edit before it.
      if text_of(buffer) ~= model.states[model.index] then
        model.states[model.index] = text_of(buffer)
      end
      local before_text = text_of(buffer)
      if step.clipboard then
        system.set_clipboard(step.clipboard)
        core.cursor_clipboard, core.cursor_clipboard_whole_line = {}, {}
      end
      if step.type then view:on_text_input(step.type) else command.perform(step.command) end
      local command_text = text_of(buffer)
      view:update()
      -- A step that leaves the text as it was must leave no undo step.
      if text_of(buffer) == before_text then
      elseif command_text ~= before_text then
        model:changed(text_of(buffer))
      else
        -- The command only moved a caret off a whitespace-only line. Its
        -- cleanup undoes with the edit before it.
        model.states[model.index] = text_of(buffer)
      end
    end
    if err then return err end
  end
  return history.walk(model,
    function() command.perform("core:undo"); view:update() end,
    function() command.perform("core:redo"); view:update() end,
    function() return text_of(buffer) end)
end

local function run(scenario, rng)
  local previous = core.active_view
  local ok, result = pcall(play, scenario, rng)
  if previous then core.set_active_view(previous) end
  if not ok then return "error: " .. tostring(result) end
  return result
end

local function generate(rng)
  local lines = {}
  for i = 1, rng:int(1, 6) do lines[i] = rng:pick(LINES) end
  return { file = rng:pick(FILES), text = table.concat(lines, "\n"), length = rng:int(1, 10), steps = {} }
end

-- Scenarios that failed once. Each one stays as a fixed case.
local regressions = {
  -- Backspace with carets at the pipes of a table: the second Backspace joins rows.
  {
    file = "fuzz.md",
    text = "\n| a | b |\n| - | c |",
    steps = {
      { carets = { { 2, 1, 2, 2 }, { 2, 5, 2, 6 }, { 3, 1, 3, 2 }, { 3, 5, 3, 6 } }, command = "core:backspace" },
      { carets = { { 2, 1, 2, 1 }, { 2, 4, 2, 4 }, { 3, 1, 3, 1 }, { 3, 4, 3, 4 } }, command = "core:backspace" },
    },
  },
  -- Indent with two carets in one line's text is one undo step.
  { file = "fuzz.txt", text = "end", steps = { { carets = { { 1, 1, 1, 1 }, { 1, 2, 1, 2 } }, command = "core:indent" } } },
  -- Indent at the end of a whitespace-only first line empties the line. No
  -- line above gives the caret's level.
  { file = "fuzz.lua", text = "  ", steps = { { carets = { { 1, 3, 1, 3 } }, command = "core:indent" } } },
  -- Two carets on one line toggle its comment once.
  {
    file = "fuzz.md",
    text = "end",
    steps = {
      { carets = { { 1, 1, 1, 1 } }, type = ")" },
      { carets = { { 1, 1, 1, 1 }, { 1, 2, 1, 2 } }, command = "editor:toggle_line_comments" },
    },
  },
  -- Indent of a selected empty line writes nothing.
  {
    file = "fuzz.md",
    text = "",
    steps = {
      { carets = { { 1, 1, 1, 1 } }, command = "core:newline" },
      { carets = { { 1, 1, 2, 1 } }, command = "core:indent" },
    },
  },
  -- A space typed on an empty line moves its caret and makes no undo step.
  {
    file = "fuzz.txt",
    text = "x",
    steps = {
      { carets = { { 1, 1, 1, 1 } }, command = "core:delete_to_end_of_line" },
      { carets = { { 1, 1, 1, 1 } }, type = " " },
    },
  },
}

test.describe("Editing command history", function()
  test.before_each(function(context)
    context.merge = config.undo_merge_timeout
    context.clipboard = system.get_clipboard()
    context.cursor_clipboard = core.cursor_clipboard
    context.whole_line = core.cursor_clipboard_whole_line
    config.undo_merge_timeout = 0
  end)

  test.after_each(function(context)
    config.undo_merge_timeout = context.merge
    system.set_clipboard(context.clipboard or "")
    core.cursor_clipboard = context.cursor_clipboard
    core.cursor_clipboard_whole_line = context.whole_line
  end)

  test.it("undoes and redoes each kept scenario through every state", function()
    local report = history.replay(regressions, run)
    test.ok(not report, report)
  end)

  test.it("undoes and redoes random multi-caret commands through every state", function()
    local report = history.fuzz({ runs = 150, generate = generate, run = run })
    test.ok(not report, report)
  end)
end)
