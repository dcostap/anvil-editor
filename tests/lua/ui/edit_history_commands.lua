-- Random carets and editing commands, then undo and redo, checked against a
-- history model. Set ANVIL_EDIT_HISTORY_RUNS and ANVIL_EDIT_HISTORY_SEED to
-- run more or other seeds. A failure prints its smallest scenario; keep it in
-- `regressions` below.
local core = require "core"
local command = require "core.command"
local config = require "core.config"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local Editor = require "core.editor"
local markdown = require "core.markdown"
local markdown_model = require "core.markdown.model"
local worker_pool = require "core.worker_pool"
local linewrapping = require "core.linewrapping"
local test = require "core.test"
local history = dofile("tests/fixtures/edit_history.lua")

local FILES = { "fuzz.lua", "fuzz.txt", "fuzz.md", "fuzz.c" }
local LINES = {
  "", "", "if ok then", "  x = 1", "end", "  -- note", "\tz", "é", "abc def", "| a | b |", "  ",
  "- [ ] task", "> quote", "- list", "| --- | --- |", "漢字 🙂 é", "\t{ value(); }", "/* x */", "ABC def",
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
  "core:paste_as_plain_text", "editor:toggle_block_comments", "editor:auto_indent_lines",
  "core:select_word", "core:select_lines",
  "markdown:table_edit_source",
}
local TYPED = { "x", "ab", "(", ")", "\"", "{", "}", " ", "é", "[", "]", "'", "`", "\t", "🙂" }
local CLIPBOARDS = { "y", "two\nlines", "line\n", "\n", "  indented\n  block", "a\r\nb\r\n", "漢字\t🙂" }

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

-- Up to 24 carets or selections in text order. They never overlap, and
-- often touch.
local function make_carets(rng, buffer)
  local all = positions(buffer)
  local count = rng:chance(0.15) and rng:int(17, 24) or rng:int(1, 5)
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
  -- Keep the previous selections too: selection commands and clipboard
  -- round trips must affect the next edit.
  local step = {}
  if not rng:chance(0.35) then step.carets = make_carets(rng, buffer) end
  if rng:chance(0.25) then
    step.type = rng:pick(TYPED)
  else
    step.command = rng:pick(COMMANDS)
    if (step.command == "core:paste" or step.command == "core:paste_as_plain_text") and rng:chance(0.5) then
      step.clipboard = rng:pick(CLIPBOARDS)
    end
  end
  return step
end

local function set_carets(buffer, carets)
  local flat = {}
  for _, caret in ipairs(carets) do
    for i = 1, 4, 2 do
      -- A shrink can move a saved coordinate into another character.
      -- Keep test input at character boundaries, as mouse and key input do.
      local line, col = buffer:sanitize_position(caret[i], caret[i + 1])
      while col > 1 and buffer.lines[line]:byte(col) >= 128 and buffer.lines[line]:byte(col) < 192 do
        col = col - 1
      end
      flat[#flat + 1], flat[#flat + 2] = line, col
    end
  end
  buffer:set_selection_list(flat, #carets)
  buffer:merge_cursors()
end

local function play(scenario, rng)
  local buffer = Buffer()
  local rejected
  local apply_edits = buffer.apply_edits
  function buffer:apply_edits(edits, opts)
    local tx = apply_edits(self, edits, opts)
    if tx.rejected then
      rejected = "command rejected edits: " .. tostring(tx.reason)
      error(rejected)
    end
    return tx
  end
  set_text(buffer, scenario.text)
  -- The name selects syntax. No disk file exists for these buffers.
  buffer:set_filename(scenario.file)
  local view = scenario.live and Editor(buffer) or TextView(buffer)
  view.size.x, view.size.y = 800, 600
  local function update()
    if scenario.live then
      markdown.live_render.refresh_view(view)
      local instance = markdown_model.peek(buffer)
      local deadline = system.get_time() + 10
      while instance and instance.status ~= "ready" and system.get_time() < deadline do
        local pool = worker_pool.current_system()
        if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
        if instance.status ~= "ready" then system.sleep(0.001) end
      end
      if not instance or instance.status ~= "ready" then error("Markdown parse did not finish") end
      linewrapping.complete_async_reconstruction(view)
    end
    view:update()
  end
  core.set_active_view(view)
  core.cursor_clipboard, core.cursor_clipboard_whole_line = {}, {}
  system.set_clipboard("")
  update()

  local model = history.model(text_of(buffer))
  local length = rng and scenario.length or #scenario.steps
  for i = 1, length do
    local step = scenario.steps[i] or make_step(rng, buffer)
    scenario.steps[i] = step
    local err
    if step.undo then
      command.perform("core:undo")
      update()
      err = history.compare("step " .. i .. " undo", model:undo(), text_of(buffer))
    elseif step.redo then
      command.perform("core:redo")
      update()
      err = history.compare("step " .. i .. " redo", model:redo(), text_of(buffer))
    else
      if step.carets then set_carets(buffer, step.carets) end
      update()
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
      if step.type then
        -- RootPanel binds the View's selections before calling plugin input
        -- handlers. Direct calls must use the same public binding.
        view:with_selection_state(function() view:on_text_input(step.type) end)
      else
        local performed = command.perform(step.command)
        if step.required and not performed then return "command unavailable: " .. step.command end
      end
      local command_text = text_of(buffer)
      update()
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
    if rejected then return rejected end
    if err then return err end
    if step.expected then
      err = history.compare("step " .. i .. " text", step.expected, text_of(buffer))
      if err then return err end
    end
    err = history.validate(buffer)
    if err then return "step " .. i .. ": " .. err end
  end
  return history.walk(model,
    function() command.perform("core:undo"); update() end,
    function() command.perform("core:redo"); update() end,
    function() return text_of(buffer) end, function() return rejected or history.validate(buffer) end)
end

local function run(scenario, rng)
  local previous = core.active_view
  local log_error, errors = core.error, {}
  core.error = function(fmt, ...) errors[#errors + 1] = string.format(fmt, ...):match("^[^\n]+") end
  local ok, result = pcall(play, scenario, rng)
  core.error = log_error
  if previous then core.set_active_view(previous) end
  if not ok then return "error: " .. tostring(result):match("^[^\n]+") end
  if #errors > 0 then return table.concat(errors, "\n") end
  return result
end

local function generate(rng)
  local lines = {}
  for i = 1, rng:int(1, 6) do lines[i] = rng:pick(LINES) end
  return { file = rng:pick(FILES), text = table.concat(lines, "\n"), length = rng:int(1, 10), steps = {} }
end

local function generate_live(rng)
  return {
    live = true, file = "fuzz.md", length = rng:int(2, 8), steps = {},
    text = rng:pick({
      "| A | B |\n| --- | --- |\n| one | two |\n| é | 🙂 |\n\nplain",
      "- first\n  - nested\n- [ ] task\n- [x] done\n\n> quote\n> next\n\nplain",
    }),
  }
end

-- Scenarios that failed once. Each one stays as a fixed case.
local regressions = {
  -- Expanding touching selections to lines can make nested ranges.
  { live = true, file = "fuzz.md", text = "a\nb\nc", steps = {
    { carets = { { 1, 1, 1, 2 }, { 1, 2, 2, 2 } }, command = "core:select_lines" },
    { type = "x", expected = "xc\n" },
  } },
  -- Delete Lines keeps its caret outside a multi-byte character on the next line.
  { file = "fuzz.txt", text = "abc\n🙂", steps = {
    { carets = { { 1, 2, 1, 2 } }, command = "editor:delete_lines" },
    { type = "x", expected = "x🙂\n" },
  } },
  -- A replacement can collapse a selected range onto another caret.
  { file = "fuzz.txt", text = "ab", steps = {
    { carets = { { 1, 1, 1, 1 }, { 1, 2, 1, 1 } }, command = "editor:upper_case" },
    { command = "core:paste_as_plain_text", clipboard = "x", expected = "xAb\n" },
  } },
  -- Empty block comments share the whitespace beside their delimiters.
  { file = "fuzz.c", text = "/* */", steps = {
    { carets = { { 1, 1, 1, 1 } }, command = "editor:toggle_block_comments", expected = "\n" },
  } },
  -- Removing indentation can put two carets at the start of the content.
  { file = "fuzz.c", text = "\tz", steps = {
    { carets = { { 1, 1, 1, 1 }, { 1, 2, 1, 2 } }, command = "editor:auto_indent_lines" },
    { type = "}", expected = "}z\n" },
  } },
  -- Keep the per-caret clipboard through Copy, Cut and Paste.
  { file = "fuzz.txt", text = "ab\ncd", steps = {
    { carets = { { 1, 1, 1, 3 }, { 2, 1, 2, 3 } }, command = "core:copy" },
    { command = "core:cut", expected = "\n\n" },
    { command = "core:paste", expected = "ab\ncd\n" },
  } },
  -- Typing after Selection Surrounding replaces the selected inner text.
  { file = "fuzz.c", text = "abc def", steps = {
    { carets = { { 1, 1, 1, 4 }, { 1, 5, 1, 8 } }, type = "(", expected = "(abc) (def)\n" },
    { type = "x", expected = "(x) (x)\n" },
  } },
  { file = "fuzz.txt", text = "abc\n", steps = {
    { carets = { { 1, 4, 1, 4 }, { 2, 1, 1, 4 } }, command = "editor:move_lines_down" },
    { type = "x", expected = "\nabcx\n" },
  } },
  { file = "fuzz.txt", text = "\nabc\n", steps = {
    { carets = { { 2, 4, 2, 4 }, { 3, 1, 2, 4 } }, command = "editor:move_lines_up" },
    { type = "x", expected = "abcx\n\n\n" },
  } },
  -- Joining lines can map several carets to the same position.
  { file = "fuzz.txt", text = "a\nb", steps = {
    { carets = { { 1, 1, 1, 1 }, { 1, 2, 1, 2 } }, command = "editor:join_lines" },
    { type = "x", expected = "a bx\n" },
  } },
  -- A line-end caret and a selected line break can land on the same copy.
  { file = "fuzz.txt", text = "abc\n", steps = {
    { carets = { { 1, 4, 1, 4 }, { 2, 1, 1, 4 } }, command = "editor:duplicate_lines" },
    { type = "x", expected = "abc\nabcx\n\n" },
  } },
  -- Two closers in one indentation use normal input, not overlapping dedents.
  { file = "fuzz.c", text = "  ", steps = {
    { carets = { { 1, 2, 1, 2 }, { 1, 3, 1, 3 } }, type = ")", expected = " ) )\n" },
  } },
  -- Delete's line-end path must also merge overlapping character removals.
  { file = "fuzz.txt", text = "abc\n", steps = {
    { carets = { { 1, 1, 1, 1 }, { 1, 3, 1, 1 }, { 2, 1, 2, 1 } }, command = "core:delete", expected = "c\n\n" },
  } },
  -- The last empty line and the line above insert their copies at one point.
  { file = "fuzz.txt", text = "abc\n", steps = {
    { carets = { { 1, 1, 1, 1 }, { 2, 1, 2, 1 } }, command = "editor:duplicate_lines", expected = "abc\nabc\n\n\n" },
  } },
  -- Expanded selections on the same line must not reject the next paste.
  { file = "fuzz.lua", text = "abc", steps = {
    { carets = { { 1, 1, 1, 1 }, { 1, 3, 1, 3 } }, command = "core:select_lines" },
    { command = "core:paste_as_plain_text", clipboard = "x", expected = "x\n" },
  } },
  { file = "fuzz.lua", text = "abc", steps = {
    { carets = { { 1, 1, 1, 1 }, { 1, 3, 1, 3 } }, command = "core:select_word" },
    { type = "x", expected = "x\n" },
  } },
  -- Unindent can move two carets to one place. The next input types once.
  { file = "fuzz.c", text = "abc", steps = {
    { carets = { { 1, 2, 1, 2 }, { 1, 3, 1, 3 } }, command = "core:unindent" },
    { type = "x", expected = "xabc\n" },
  } },
  -- A line action inserts one line even with several carets on that line.
  { file = "fuzz.txt", text = "abc", steps = {
    { carets = { { 1, 1, 1, 1 }, { 1, 3, 1, 3 } }, command = "core:newline_above", expected = "\nabc\n" },
    { carets = { { 2, 1, 2, 1 }, { 2, 3, 2, 3 } }, command = "core:newline_below", expected = "\nabc\n\n" },
  } },
  -- Deletion ranges can overlap even when their carets do not.
  { file = "fuzz.txt", text = "abc def", steps = {
    { carets = { { 1, 3, 1, 3 }, { 1, 5, 1, 5 } }, command = "core:delete_to_start_of_line", expected = "def\n" },
  } },
  -- Whole-line block comments must not toggle twice for two carets.
  { file = "fuzz.c", text = "abc", steps = {
    { carets = { { 1, 1, 1, 1 } }, type = "x" },
    { carets = { { 1, 1, 1, 1 }, { 1, 3, 1, 3 } }, command = "editor:toggle_block_comments", expected = "/* xabc */\n" },
  } },
  -- Separate block comments from one command undo together.
  { file = "fuzz.c", text = "abc def", steps = {
    { carets = { { 1, 1, 1, 4 }, { 1, 5, 1, 8 } }, command = "editor:toggle_block_comments", expected = "/* abc */ /* def */\n" },
  } },
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

-- Exercise the original table-source workflow with 17 carets in a real
-- Live Preview. The random runs also use its table cell input handlers.
do
  local lines, carets = { "| a | b |", "| --- | --- |" }, {}
  for line = 3, 9 do lines[line] = "| a | b |" end
  for line = 1, 9 do
    if line ~= 2 then
      carets[#carets + 1] = { line, 1, line, 2 }
      carets[#carets + 1] = { line, 5, line, 6 }
    end
  end
  carets[#carets + 1] = { 9, 9, 9, 10 }
  regressions[#regressions + 1] = {
    live = true, file = "fuzz.md", text = table.concat(lines, "\n"),
    steps = {
      { carets = { { 1, 3, 1, 3 } }, command = "markdown:table_edit_source", required = true },
      { carets = carets, command = "core:backspace" },
      { command = "core:backspace" },
      { undo = true }, { redo = true },
    },
  }
end

test.describe("Editing command history", function()
  test.before_each(function(context)
    context.merge = config.undo_merge_timeout
    context.live = config.markdown_live_editor
    context.tables = config.markdown_live_interactive_tables
    config.markdown_live_editor = true
    config.markdown_live_interactive_tables = true
    context.autosave = config.plugins.autosave_fast.enabled
    config.plugins.autosave_fast.enabled = false
    context.clipboard = system.get_clipboard()
    context.cursor_clipboard = core.cursor_clipboard
    context.whole_line = core.cursor_clipboard_whole_line
    config.undo_merge_timeout = 0
  end)

  test.after_each(function(context)
    config.undo_merge_timeout = context.merge
    config.markdown_live_editor = context.live
    config.markdown_live_interactive_tables = context.tables
    config.plugins.autosave_fast.enabled = context.autosave
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

  test.it("undoes and redoes Markdown Live Preview edits through every state", function()
    local report = history.fuzz({ runs = 12, generate = generate_live, run = run })
    test.ok(not report, report)
  end)
end)
