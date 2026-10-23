local test = require "core.test"
local native = require "terminal_native"
local session, previous

local function shell_protocol()
  local err
  session, err = native.new {
    cols = 80, rows = 8, cell_width = 8, cell_height = 16,
    cwd = system.getcwd(),
    shell = [[powershell.exe -NoLogo -NoProfile -Command "[Console]::Write('IMAGE_PROTOCOL=' + $env:PI_IMAGE_PROTOCOL + '|')"]],
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
    local value = table.concat(parts):match("IMAGE_PROTOCOL=(.-)|")
    if value then return value end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  test.fail("Shell did not report its image protocol")
end

test.describe("Terminal Pi image environment", function()
  test.before_each(function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    previous = os.getenv("PI_IMAGE_PROTOCOL") or ""
  end)
  test.after_each(function()
    if session then session:close(); session = nil end
    if previous then system.setenv("PI_IMAGE_PROTOCOL", previous) end
  end)

  test.it("enables Kitty images when no protocol was selected", function()
    test.ok(system.setenv("PI_IMAGE_PROTOCOL", ""))
    test.equal(shell_protocol(), "kitty")
  end)

  test.it("preserves an explicit image protocol choice", function()
    test.ok(system.setenv("PI_IMAGE_PROTOCOL", "none"))
    test.equal(shell_protocol(), "none")
  end)
end)
