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

-- Runs the fixture and returns the final cursor state.
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
  local hidden_at_end = false
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
    end
    coroutine.yield(0.001)
  end
  session:close()
  test.ok(ready, text)
  return done, shown, hidden_at_end, text
end

test.describe("Terminal cursor visibility during repaints", function()
  test.it("keeps the cursor visible while an application briefly hides it to repaint", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    local done, shown, hidden_at_end, text = run_fixture("", "ANVIL_REPAINT_DONE")
    test.ok(done, text)
    -- Check the published cursor state after the repaint completes.
    test.ok(shown, "The terminal did not show the cursor during the repaint")
    test.not_ok(hidden_at_end, "The terminal left the cursor hidden after the repaint")
  end)

  test.it("hides the cursor when an application leaves it hidden", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    local done, _, hidden_at_end, text = run_fixture("-StayHidden", "ANVIL_REPAINT_HIDDEN")
    test.ok(done, text)
    test.ok(hidden_at_end, "The terminal kept showing a cursor the application hid")
  end)
end)
