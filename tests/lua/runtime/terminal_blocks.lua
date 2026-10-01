local test = require "core.test"

local function row_text(row)
  local text = {}
  for _, run in ipairs(row.text_runs) do text[#text + 1] = run.text end
  return table.concat(text)
end

local function start_session(context)
  local session, err = require("terminal_native").new {
    cols = 40, rows = 8, cell_width = 10, cell_height = 22,
    foreground = 0xffffff, background = 0,
    minimum_contrast = 1,
    cwd = system.getcwd(),
    shell = "powershell.exe -NoLogo -NoProfile -File tests/fixtures/terminal_blocks.ps1",
  }
  test.ok(session, err)
  context.session = session
  local snapshot
  local deadline = system.get_time() + 8
  repeat
    session:update()
    snapshot = session:snapshot(snapshot)
    for _, row in ipairs(snapshot.rows) do
      if row_text(row):find("ANVIL_BLOCKS_DONE", 1, true) then return snapshot end
    end
    coroutine.yield(0.005)
  until system.get_time() > deadline
  error("Terminal block fixture did not finish")
end

test.describe("Terminal block output", function()
  test.before_each(function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY requires Windows")
  end)
  test.after_each(function(context)
    if context.session then context.session:close() end
  end)

  test.it("publishes cell-aligned block graphics without changing captured text", function(context)
    local snapshot = start_session(context)
    local row = snapshot.rows[1]
    test.equal(row_text(row), "A██▀▄▛▜░▒▓B")
    local expected = { 0x2588, 0x2588, 0x2580, 0x2584, 0x259b, 0x259c, 0x2591, 0x2592, 0x2593 }
    local covered = {}
    for _, run in ipairs(row.text_runs) do
      for col = run.col, run.col + run.columns - 1 do
        test.equal(run.block, expected[col], "Wrong graphics kind at column " .. col)
        test.not_ok(covered[col], "Overlapping terminal output columns")
        covered[col] = true
      end
    end
    for col = 0, 10 do test.ok(covered[col], "Missing terminal output column " .. col) end
    local capture, err = context.session:text_capture()
    test.ok(capture, err)
    test.ok(capture.text:find("A██▀▄▛▜░▒▓B", 1, true))
  end)

  test.it("keeps block attributes and sends combined graphemes through the font path", function(context)
    local snapshot = start_session(context)
    local run = snapshot.rows[2].text_runs[1]
    test.equal(run.block, 0x2588)
    test.ok(run.bold)
    test.ok(run.italic)
    test.ok(run.faint)
    test.ok(run.alpha < 255)
    test.equal(run.underline, 1)
    test.equal(run.fg, 0)
    test.equal(snapshot.rows[3].text_runs[1].text, "█́")
    test.equal(snapshot.rows[3].text_runs[1].block, nil)
  end)
end)
