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

test.describe("Native terminal session", function()
  test.it("runs a ConPTY command and parses its VT output", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    local terminal_native = require "terminal_native"
    local session, start_error = terminal_native.new({
      cols = 80,
      rows = 24,
      cell_width = 8,
      cell_height = 16,
      cwd = system.getcwd(),
      shell = 'cmd.exe /d /s /c "echo ANVIL_TERMINAL_TEST"',
    })
    test.ok(session, start_error)

    local deadline = system.get_time() + 5
    local text = ""
    local changed_count = 0
    local snapshot
    while system.get_time() < deadline and not text:find("ANVIL_TERMINAL_TEST", 1, true) do
      local changed = session:update()
      if changed then changed_count = changed_count + 1 end
      snapshot = session:snapshot(snapshot)
      text = snapshot_text(snapshot)
      if not text:find("ANVIL_TERMINAL_TEST", 1, true) then coroutine.yield(0.01) end
    end
    test.ok(
      text:find("ANVIL_TERMINAL_TEST", 1, true),
      string.format("changed=%d snapshot=%q", changed_count, text)
    )
    local first_row = snapshot.rows[1]
    local clean_snapshot = session:snapshot(snapshot)
    test.ok(clean_snapshot.rows[1] == first_row)
    test.ok(type(first_row.text_runs) == "table")
    test.ok(type(first_row.backgrounds) == "table")
    test.equal(#first_row, 0)
    test.ok(session:select(0, 0, 79, 23, false))
    local selected = session:selected_text()
    test.ok(session:resize(80, 4, 8, 16))
    local resized_snapshot = session:snapshot(snapshot)
    test.equal(#resized_snapshot.rows, 4)
    session:close()
    test.ok(selected:find("ANVIL_TERMINAL_TEST", 1, true), selected)
  end)

  test.it("reports the child exit code", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    local terminal_native = require "terminal_native"
    local session, start_error = terminal_native.new({
      cols = 80, rows = 24, cell_width = 8, cell_height = 16,
      cwd = system.getcwd(),
      shell = 'cmd.exe /d /s /c "exit 23"',
    })
    test.ok(session, start_error)

    local running, status = true, nil
    local deadline = system.get_time() + 5
    while system.get_time() < deadline and running do
      local _
      _, running, status = session:update()
      if running then coroutine.yield(0.01) end
    end
    session:close()
    test.equal(running, false)
    test.equal(status.exit_code, 23)
  end)

  test.it("sends text and encoded keys to the default PowerShell", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    local terminal_native = require "terminal_native"
    local session, start_error = terminal_native.new({
      cols = 80,
      rows = 24,
      cell_width = 8,
      cell_height = 16,
      cwd = system.getcwd(),
    })
    test.ok(session, start_error)
    test.ok(session:paste("Write-Output ANVIL_TERMINAL_INPUT", false))
    test.ok(session:key("return", {}))

    local deadline = system.get_time() + 8
    local text = ""
    while system.get_time() < deadline and not text:find("ANVIL_TERMINAL_INPUT", 1, true) do
      session:update()
      text = snapshot_text(session:snapshot())
      if not text:find("ANVIL_TERMINAL_INPUT", 1, true) then coroutine.yield(0.01) end
    end
    session:close()

    test.ok(text:find("ANVIL_TERMINAL_INPUT", 1, true), text)
  end)
end)
