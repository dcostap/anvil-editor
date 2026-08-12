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


local function wait_for_text(session, expected, timeout)
  local deadline = system.get_time() + (timeout or 8)
  local text = ""
  local snapshot
  while system.get_time() < deadline and not text:find(expected, 1, true) do
    session:update()
    snapshot = session:snapshot(snapshot)
    text = snapshot_text(snapshot)
    if not text:find(expected, 1, true) then coroutine.yield(0.005) end
  end
  return text, snapshot
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
    coroutine.yield(0.2)
    local _, still_running, final_status = session:update()
    test.equal(still_running, false)
    test.equal(final_status.exit_code, 23)
    test.ok(session:snapshot())
    session:close()
    test.equal(running, false)
    test.equal(status.exit_code, 23)
  end)

  test.it("reports exit code 259 instead of treating it as active", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    local terminal_native = require "terminal_native"
    local session, start_error = terminal_native.new({
      cols = 80, rows = 24, cell_width = 8, cell_height = 16,
      cwd = system.getcwd(),
      shell = 'powershell.exe -NoLogo -NoProfile -Command "exit 259"',
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
    test.equal(status.exit_code, 259)
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

  test.it("searches repeated matches in terminal output", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    local terminal_native = require "terminal_native"
    local session, start_error = terminal_native.new({
      cols = 80, rows = 8, cell_width = 8, cell_height = 16,
      cwd = system.getcwd(),
      shell = 'cmd.exe /d /s /c "echo needle needle"',
    })
    test.ok(session, start_error)
    local deadline = system.get_time() + 5
    local text = ""
    while system.get_time() < deadline and not text:find("needle needle", 1, true) do
      session:update()
      text = snapshot_text(session:snapshot())
      if not text:find("needle needle", 1, true) then coroutine.yield(0.01) end
    end
    test.ok(text:find("needle needle", 1, true), text)
    test.ok(session:search("needle", false))
    local first = session:selected_text()
    test.ok(session:search("needle", false))
    local second = session:selected_text()
    session:close()
    test.equal(first, "needle")
    test.equal(second, "needle")
  end)

  test.it("reports bounded terminal bell and clipboard effects", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    local terminal_native = require "terminal_native"
    local session, start_error = terminal_native.new({
      cols = 80, rows = 8, cell_width = 8, cell_height = 16,
      cwd = system.getcwd(),
      shell = [[powershell.exe -NoLogo -NoProfile -Command "$e=[char]27; $b=[char]7; [Console]::Write($b); [Console]::Write($e + ']52;c;dGVzdA==' + $b)"]],
    })
    test.ok(session, start_error)
    local events = {}
    local deadline = system.get_time() + 5
    while system.get_time() < deadline and #events < 2 do
      session:update()
      local snapshot = session:snapshot()
      for _, event in ipairs(snapshot.events or {}) do events[#events + 1] = event end
      if #events < 2 then coroutine.yield(0.01) end
    end
    session:close()
    test.equal(events[1].type, "bell")
    test.equal(events[1].count, 1)
    test.equal(events[2].type, "clipboard")
    test.equal(events[2].text, "test")
  end)

  test.it("drains multi-megabyte output without losing the tail", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    local terminal_native = require "terminal_native"
    local session, start_error = terminal_native.new({
      cols = 100, rows = 12, cell_width = 8, cell_height = 16,
      cwd = system.getcwd(),
      shell = [[powershell.exe -NoLogo -NoProfile -Command "$chunk='x'*4096; 1..1280 | ForEach-Object { [Console]::Write($chunk) }; [Console]::WriteLine('ANVIL_STRESS_TAIL')"]],
    })
    test.ok(session, start_error)
    coroutine.yield(0.2)
    local text = wait_for_text(session, "ANVIL_STRESS_TAIL", 45)
    session:close()
    test.ok(text:find("ANVIL_STRESS_TAIL", 1, true),
      "expected the terminal tail after more than 4 MiB of output")
  end)

  test.it("handles alternate-screen TUI output", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    local terminal_native = require "terminal_native"
    local session, start_error = terminal_native.new({
      cols = 80, rows = 8, cell_width = 8, cell_height = 16,
      cwd = system.getcwd(),
      shell = [[powershell.exe -NoLogo -NoProfile -Command "$e=[char]27; [Console]::WriteLine('ANVIL_PRIMARY_SCREEN'); [Console]::Write($e+'[?1049h'+$e+'[2J'+$e+'[3;7H'+$e+'[1;34mANVIL_TUI_SCREEN'+$e+'[0m'); Start-Sleep -Milliseconds 300; [Console]::Write($e+'[?1049l'); [Console]::WriteLine('ANVIL_TUI_EXIT')"]],
    })
    test.ok(session, start_error)
    local text = wait_for_text(session, "ANVIL_TUI_SCREEN", 5)
    test.ok(text:find("ANVIL_TUI_SCREEN", 1, true), text)
    text = wait_for_text(session, "ANVIL_TUI_EXIT", 5)
    session:close()
    test.ok(text:find("ANVIL_TUI_EXIT", 1, true), text)
    test.ok(text:find("ANVIL_PRIMARY_SCREEN", 1, true), text)
    test.equal(text:find("ANVIL_TUI_SCREEN", 1, true), nil)
  end)

  test.it("answers an interactive shell prompt", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    local terminal_native = require "terminal_native"
    local session, start_error = terminal_native.new({
      cols = 80, rows = 8, cell_width = 8, cell_height = 16,
      cwd = system.getcwd(),
      shell = [[powershell.exe -NoLogo -NoProfile -Command "$answer=Read-Host 'ANVIL_INTERACTIVE_PROMPT'; Write-Output ('ANVIL_INTERACTIVE_REPLY='+$answer)"]],
    })
    test.ok(session, start_error)
    local text = wait_for_text(session, "ANVIL_INTERACTIVE_PROMPT", 5)
    test.ok(text:find("ANVIL_INTERACTIVE_PROMPT", 1, true), text)
    test.ok(session:write("terminal reply\r"))
    text = wait_for_text(session, "ANVIL_INTERACTIVE_REPLY=terminal reply", 5)
    session:close()
    test.ok(text:find("ANVIL_INTERACTIVE_REPLY=terminal reply", 1, true), text)
  end)

  test.it("repeatedly starts and closes native sessions", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    local terminal_native = require "terminal_native"
    for index = 1, 8 do
      local marker = "ANVIL_CYCLE_" .. index
      local session, start_error = terminal_native.new({
        cols = 40, rows = 4, cell_width = 8, cell_height = 16,
        cwd = system.getcwd(),
        shell = string.format('cmd.exe /d /s /c "echo %s"', marker),
      })
      test.ok(session, start_error)
      local text = wait_for_text(session, marker, 5)
      session:close()
      test.ok(text:find(marker, 1, true), text)
    end
  end)

  test.it("runs a command through the default WSL distribution", function()
    test.skip_if(PLATFORM ~= "Windows", "WSL is Windows-specific")
    local terminal_native = require "terminal_native"
    local session, start_error = terminal_native.new({
      cols = 80, rows = 8, cell_width = 8, cell_height = 16,
      cwd = system.getcwd(),
      shell = [[wsl.exe -e sh -lc "printf ANVIL_WSL_TERMINAL"]],
    })
    test.ok(session, start_error)
    local text = wait_for_text(session, "ANVIL_WSL_TERMINAL", 15)
    session:close()
    test.ok(text:find("ANVIL_WSL_TERMINAL", 1, true), text)
  end)

  test.it("runs the Windows OpenSSH client", function()
    test.skip_if(PLATFORM ~= "Windows", "OpenSSH test is Windows-specific")
    local windir = os.getenv("WINDIR") or "C:/Windows"
    local ssh = windir .. "/System32/OpenSSH/ssh.exe"
    test.skip_if(not system.get_file_info(ssh), "Windows OpenSSH is unavailable")
    local terminal_native = require "terminal_native"
    local session, start_error = terminal_native.new({
      cols = 80, rows = 8, cell_width = 8, cell_height = 16,
      cwd = system.getcwd(), shell = string.format('"%s" -V', ssh),
    })
    test.ok(session, start_error)
    local text = wait_for_text(session, "OpenSSH", 5)
    session:close()
    test.ok(text:find("OpenSSH", 1, true), text)
  end)
end)
