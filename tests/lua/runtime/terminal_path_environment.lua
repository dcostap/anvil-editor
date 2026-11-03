local test = require "core.test"
local native = require "terminal_native"
local session, previous

-- Reports whether the shell's PATH has the stale entry and the Windows system folder.
local function shell_path()
  local err
  session, err = native.new {
    cols = 200, rows = 8, cell_width = 8, cell_height = 16,
    cwd = system.getcwd(),
    shell = [[powershell.exe -NoLogo -NoProfile -Command "[Console]::Write('PATH_VALUE=stale=' + ($env:Path -like '*anvil-stale-path-entry*') + ',system=' + ($env:Path -like '*system32*') + '|')"]],
  }
  test.ok(session, err)
  local deadline = system.get_time() + 30
  repeat
    session:update()
    local snapshot = session:snapshot()
    local parts = {}
    for _, row in ipairs(snapshot and snapshot.rows or {}) do
      for _, run in ipairs(row.text_runs or {}) do parts[#parts + 1] = run.text end
    end
    local value = table.concat(parts):match("PATH_VALUE=(.-)|")
    if value then return value end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  test.fail("Shell did not report its PATH")
end

test.describe("Terminal PATH environment", function()
  test.before_each(function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    previous = os.getenv("PATH")
  end)
  test.after_each(function()
    if session then session:close(); session = nil end
    if previous then system.setenv("PATH", previous) end
  end)

  test.it("gives a new shell the Windows PATH, not the PATH that Anvil started with", function()
    test.ok(system.setenv("PATH", [[C:\anvil-stale-path-entry;]] .. previous))
    test.equal(shell_path(), "stale=False,system=True")
  end)
end)
