local test = require "core.test"

local function snapshot_text(snapshot)
  local parts = {}
  for _, row in ipairs(snapshot.rows or {}) do
    for _, run in ipairs(row.text_runs or {}) do
      parts[#parts + 1] = run.text
    end
    parts[#parts + 1] = "\n"
  end
  return table.concat(parts)
end

-- Runs the fixture and reports the published frames that had no cursor after
-- the application first showed it.
local function run_fixture(arguments, done_marker)
  local terminal_native = require "terminal_native"
  local session, start_error = terminal_native.new {
    cols = 80, rows = 8, cell_width = 8, cell_height = 16,
    cwd = system.getcwd(),
    shell = [[powershell.exe -NoLogo -NoProfile -File tests/fixtures/terminal_cursor_hide_repaint.ps1 ]] .. arguments,
  }
  test.ok(session, start_error)
  local snapshot, text
  local ready, shown, done = false, false, false
  local hidden_during_repaint, hidden_at_end = 0, false
  local deadline = system.get_time() + 10
  while system.get_time() < deadline do
    session:update()
    snapshot = session:snapshot(snapshot)
    text = snapshot_text(snapshot)
    if text:find("ANVIL_REPAINT_READY", 1, true) then ready = true end
    if ready and snapshot.cursor.visible then shown = true end
    if text:find(done_marker, 1, true) then
      done = true
      hidden_at_end = not snapshot.cursor.visible
      break
    elseif shown and not snapshot.cursor.visible then
      hidden_during_repaint = hidden_during_repaint + 1
    end
    coroutine.yield(0.001)
  end
  session:close()
  test.ok(ready, text)
  return done, hidden_during_repaint, hidden_at_end, text
end

test.describe("Terminal cursor visibility during repaints", function()
  test.it("keeps the cursor visible while an application briefly hides it to repaint", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    local done, hidden_frames, _, text = run_fixture("", "ANVIL_REPAINT_DONE")
    test.ok(done, text)
    test.equal(hidden_frames, 0, "The terminal published frames without a cursor during repaints")
  end)

  test.it("hides the cursor when an application leaves it hidden", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    local done, _, hidden_at_end, text = run_fixture("-StayHidden", "ANVIL_REPAINT_HIDDEN")
    test.ok(done, text)
    test.ok(hidden_at_end, "The terminal kept showing a cursor the application hid")
  end)
end)
