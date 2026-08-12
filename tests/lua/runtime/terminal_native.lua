local test = require "core.test"

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
    while system.get_time() < deadline and not text:find("ANVIL_TERMINAL_TEST", 1, true) do
      local changed = session:update()
      if changed then changed_count = changed_count + 1 end
      local snapshot = session:snapshot()
      local parts = {}
      for _, row in ipairs(snapshot.rows or {}) do
        for _, cell in ipairs(row) do
          if type(cell) == "table" and cell.text then parts[#parts + 1] = cell.text end
        end
        parts[#parts + 1] = "\n"
      end
      text = table.concat(parts)
      if not text:find("ANVIL_TERMINAL_TEST", 1, true) then coroutine.yield(0.01) end
    end
    session:close()

    test.ok(
      text:find("ANVIL_TERMINAL_TEST", 1, true),
      string.format("changed=%d snapshot=%q", changed_count, text)
    )
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
    test.ok(session:write("Write-Output ANVIL_TERMINAL_INPUT"))
    test.ok(session:key("return", {}))

    local deadline = system.get_time() + 8
    local text = ""
    while system.get_time() < deadline and not text:find("ANVIL_TERMINAL_INPUT", 1, true) do
      session:update()
      local snapshot = session:snapshot()
      local parts = {}
      for _, row in ipairs(snapshot.rows or {}) do
        for _, cell in ipairs(row) do
          if type(cell) == "table" and cell.text then parts[#parts + 1] = cell.text end
        end
        parts[#parts + 1] = "\n"
      end
      text = table.concat(parts)
      if not text:find("ANVIL_TERMINAL_INPUT", 1, true) then coroutine.yield(0.01) end
    end
    session:close()

    test.ok(text:find("ANVIL_TERMINAL_INPUT", 1, true), text)
  end)
end)
