local test = require "core.test"
local terminal = require "plugins.terminal"
local tab = require "core.tab"

local function wait_record(view, predicate)
  local deadline = system.get_time() + 20
  repeat
    view.session:update()
    local path = USERDIR .. PATHSEP .. "terminal-sessions" .. PATHSEP .. view.session_id .. ".lua"
    local file = io.open(path, "rb")
    if file then
      local text = file:read("*a")
      file:close()
      local chunk = load(text, "=record", "t", {})
      local ok, value = pcall(chunk or error)
      if ok and predicate(value) then return value end
    end
    coroutine.yield(0.05)
  until system.get_time() >= deadline
  error("command status did not arrive")
end

test.describe("Terminal command status", function()
  test.it("shows the submitted command, elapsed time and completed duration", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    terminal._set_native_for_tests(nil)
    local view = terminal.open { cwd = system.getcwd(), shell = "powershell.exe -NoLogo -NoProfile" }
    local ok, err = pcall(function()
      wait_record(view, function(r) return r.busy == false end)
      test.ok(view.session:write("Start-Sleep -Seconds 4\r"))
      local running = wait_record(view, function(r)
        return r.command_started and r.command_started > 0 and r.title == "Start-Sleep -Seconds 4"
      end)
      test.equal(running.title, "Start-Sleep -Seconds 4")
      local status = tab.agent(running)
      local text, elapsed = tab.agent_line(status, running.command_started + 2, false)
      test.equal(text, "Running")
      test.equal(elapsed, tab.duration_text(2))
      local ended = wait_record(view, function(r) return r.command_finished and r.command_finished > 0 end)
      test.equal(ended.title, running.title)
      test.equal(ended.command_exit, 0)
      test.ok(ended.command_finished >= ended.command_started)
      local result = tab.agent(ended)
      local label, duration = tab.agent_line(result, ended.command_finished + 100, false)
      test.equal(label, "Done")
      test.equal(duration, tab.duration_text(ended.command_finished - ended.command_started))
      test.ok(view.session:write("Write-Error 'failed'\r"))
      local failed = wait_record(view, function(r) return r.command_exit and r.command_exit ~= 0 end)
      test.equal(tab.agent(failed).state, "error")
    end)
    view:on_close()
    test.ok(ok, err)
  end)
end)
