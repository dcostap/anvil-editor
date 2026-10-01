local core = require "core"
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

local function check_missing_end_recovery(arguments, require_running)
  test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
  local terminal_native = require "terminal_native"
  local session, start_error = terminal_native.new {
    cols = 80, rows = 8, cell_width = 8, cell_height = 16,
    cwd = system.getcwd(),
    shell = [[powershell.exe -NoLogo -NoProfile -File tests/fixtures/terminal_cursor_sync.ps1 -OmitEnd ]] .. arguments,
  }
  test.ok(session, start_error)
  local snapshot, text
  local deadline = system.get_time() + 8
  local complete = false
  while system.get_time() < deadline do
    session:update()
    snapshot = session:snapshot(snapshot)
    text = snapshot_text(snapshot)
    if text:find("ANVIL_SYNC_COMPLETE", 1, true) then
      complete = true
      break
    end
    coroutine.yield(0.005)
  end
  session:close()
  test.ok(complete, "The terminal remained frozen after the application omitted its end marker: " .. text)
  test.equal(snapshot.cursor.x, 4)
  test.equal(snapshot.cursor.y, 2)
  if require_running then test.ok(snapshot.running, "Recovery must not depend on the application exiting") end
end

test.describe("Terminal synchronized screen updates", function()
  test.it("keeps drawing positions out of the visible cursor until the update ends", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    local terminal_native = require "terminal_native"
    local trace_path = core.temp_filename(".vt")
    local session, start_error = terminal_native.new {
      cols = 80, rows = 8, cell_width = 8, cell_height = 16,
      cwd = system.getcwd(),
      shell = [[powershell.exe -NoLogo -NoProfile -File tests/fixtures/terminal_cursor_sync.ps1]],
    }
    test.ok(session, start_error)
    local traced, trace_error = session:trace(trace_path)
    test.ok(traced, trace_error)

    local snapshot, text
    local ready, complete, saw_drawing, saw_wrong_cursor = false, false, false, false
    local deadline = system.get_time() + 8
    while system.get_time() < deadline do
      session:update()
      snapshot = session:snapshot(snapshot)
      text = snapshot_text(snapshot)
      if text:find("ANVIL_SYNC_COMPLETE", 1, true) then
        complete = true
        break
      end
      if text:find("ANVIL_SYNC_READY", 1, true) then ready = true end
      if ready then
        saw_drawing = saw_drawing or text:find("ANVIL_SYNC_DRAWING", 1, true) ~= nil
        saw_wrong_cursor = saw_wrong_cursor or
          snapshot.cursor.x ~= 4 or snapshot.cursor.y ~= 2
      end
      coroutine.yield(0.005)
    end
    session:trace()
    session:close()
    local file = test.not_nil(io.open(trace_path, "rb"))
    local raw = file:read("*a")
    file:close()
    os.remove(trace_path)

    test.ok(ready, text)
    test.ok(complete, text)
    test.ok(raw:find("\27[?2026h", 1, true), "ConPTY did not forward the synchronized update start")
    test.ok(raw:find("\27[?2026l", 1, true), "ConPTY did not forward the synchronized update end")
    test.not_ok(saw_drawing, "The terminal displayed an unfinished screen update")
    test.not_ok(saw_wrong_cursor, "The terminal displayed the drawing cursor instead of the input cursor")
    test.equal(snapshot.cursor.x, 4)
    test.equal(snapshot.cursor.y, 2)
  end)

  test.it("recovers when a running application omits the update end marker", function()
    check_missing_end_recovery("", true)
  end)

  test.it("publishes final output when an application exits without ending its update", function()
    check_missing_end_recovery("-ExitAfterUpdate", false)
  end)
end)
