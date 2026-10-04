local test = require "core.test"
local terminal = require "plugins.terminal"

test.describe("Terminal Windows Rerun", function()
  test.it("does not save prompt helpers as interrupted commands", function()
    test.skip_if(PLATFORM ~= "Windows", "Windows process probes are Windows-specific")
    terminal._set_native_for_tests(nil)
    local native = require "terminal_native"
    local root = system.getcwd()
    for _, name in ipairs { "starship.exe", "oh-my-posh.exe" } do
      local path = USERDIR .. "/" .. name
      local source = assert(io.open(root .. "/tests/fixtures/terminal argv's.exe", "rb"))
      local file = assert(io.open(path, "wb"))
      file:write(source:read("*a")); source:close(); file:close()
      local view = terminal.open { cwd = root, shell = "cmd.exe /D /Q" }
      local ok, err = pcall(function()
        test.ok(view.session:write(string.format('"%s" "%s/tests/fixtures/terminal_prompt_helper.lua"\r', path, root)))
        local ready, started = false, system.get_time()
        repeat
          view:service_session(true)
          local capture = view.session:text_capture()
          ready = capture and capture.text:find("PROMPT_HELPER_READY", 1, true)
          coroutine.yield(.01)
        until ready or system.get_time() - started > 10
        test.ok(ready, "prompt helper did not start")
        local deadline = system.get_time() + 1.5
        repeat view:service_session(true); coroutine.yield(.01) until system.get_time() >= deadline
        local record = assert(load(assert(native.read_session_record(view.session_id)), "record", "t", {}))()
        test.equal(record.interrupted_command or "", "", "prompt helper became a Rerun command")
      end)
      view:on_close()
      native.finish_close_commands()
      os.remove(path)
      test.ok(ok, err)
    end
  end)

  test.it("preserves native arguments under PowerShell", function()
    test.skip_if(PLATFORM ~= "Windows", "Windows command lines are Windows-specific")
    terminal._set_native_for_tests(nil)
    local root = system.getcwd()
    local output = USERDIR .. "/rerun-arguments.txt"
    os.remove(output)
    local view = terminal.open { cwd = root, shell = "powershell.exe -NoLogo -NoProfile" }
    local literal = "literal $env:ANVIL_RERUN_UNSET | & `t %TEMP% ' value"
    local ok, err = pcall(function()
      local deadline = system.get_time() + 10
      repeat
        view:service_session(true)
        coroutine.yield(.01)
      until view.state == "running" and view.session:text_capture() or system.get_time() >= deadline
      view.interrupted_command = string.format('"%s/tests/fixtures/terminal argv\'s.exe" "%s/tests/fixtures/terminal_rerun_arguments.lua" "%s" "%s" "" "quote\\\"value"', root, root, output, literal)
      test.ok(view:rerun_interrupted_command())
      local actual
      deadline = system.get_time() + 15
      repeat
        view:service_session(true)
        local file = io.open(output, "rb")
        if file then actual = file:read("*a"); file:close() end
        if actual then break end
        coroutine.yield(.01)
      until system.get_time() >= deadline
      test.equal(actual, #literal .. ":" .. literal .. '\n0:\n11:quote"value\n')
    end)
    view:on_close()
    os.remove(output)
    test.ok(ok, err)
  end)
end)
