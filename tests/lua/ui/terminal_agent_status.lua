local ready = dofile("tests/fixtures/terminal_ready.lua")
local test = require "core.test"
local terminal = require "plugins.terminal"

-- The Terminal host reads program status reports (OSC 7501) from the session's output and keeps them in the
-- session record, which the Project Sidebar reads.
local function record(view)
  local file = io.open(USERDIR .. PATHSEP .. "terminal-sessions" .. PATHSEP .. view.session_id .. ".lua", "rb")
  if not file then return nil end
  local text = file:read("*a")
  file:close()
  local chunk = load(text, "=record", "t", {})
  local ok, value = pcall(chunk or error)
  return ok and value or nil
end

local function wait_for(view, predicate, seconds)
  local deadline = system.get_time() + seconds
  repeat
    local _, status = view.session:update()
    view:apply_status(status)
    local value = record(view)
    if value and predicate(value) then return value end
    coroutine.yield(0.05)
  until system.get_time() >= deadline
  return record(view)
end

test.describe("Terminal agent status", function()
  test.it("keeps a program's status and step while it runs and drops them when it ends", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    terminal._set_native_for_tests(nil)
    local view = ready(terminal.open { cwd = system.getcwd(), shell = "powershell.exe -NoLogo -NoProfile" })
    local ok, err = pcall(function()
      test.ok(wait_for(view, function(value) return value.busy == false end, 20), "idle shell missing")
      -- "my session" and "bash: npm test" in base64.
      test.ok(view.session:write(
        "$e=[char]27; [Console]::Write(\"$e]7501;state=working:app=pi:msg=bXkgc2Vzc2lvbg==$e\\\");" ..
        " [Console]::Write(\"$e]7501;state=working:id=step:msg=YmFzaDogbnBtIHRlc3Q=$e\\\");" ..
        " [Console]::Write(\"$e]7501;state=idle:id=model:msg=R1BUIFRlc3Q=$e\\\"); Start-Sleep 4\r"))
      local running = wait_for(view, function(value) return value.agent_step ~= nil and value.agent_model ~= nil end, 4)
      test.equal(running and running.agent_state, "working")
      test.equal(running and running.agent_app, "pi")
      test.equal(running and running.agent_model, "GPT Test")
      local deadline = system.get_time() + 5
      while (view.agent_app ~= "pi" or view.agent_model ~= "GPT Test") and system.get_time() < deadline do
        local _, status = view.session:update()
        view:apply_status(status)
        coroutine.yield(0.05)
      end
      local item = require("core.tab").describe({current_view = view}, 1)
      test.equal(item.terminal.app, "pi", "The Tab lost its program identity")
      test.equal(item.terminal.model, "GPT Test")
      test.equal(running and running.agent_message, "my session")
      test.equal(running and running.agent_step, "bash: npm test")
      test.ok(running and running.agent_since > 0 and running.agent_step_since >= running.agent_since)
      local ended = wait_for(view, function(value)
        return value.busy == false and not value.agent_state and not view.agent_app and not view.agent_model
      end, 10)
      test.equal(ended and ended.agent_state, nil, "The status outlived its program")
      test.equal(ended and ended.agent_step, nil)
      test.equal(ended and ended.agent_app, nil)
      test.equal(ended and ended.agent_model, nil)
      test.equal(view.agent_model, nil, "The Tab kept an ended program's model")
      test.equal(view.agent_app, nil, "The Tab kept an ended program's identity")
    end)
    view:on_close()
    test.ok(ok, err)
  end)

  test.it("ends a step when its program reports that it rests", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    terminal._set_native_for_tests(nil)
    local view = ready(terminal.open { cwd = system.getcwd(), shell = "powershell.exe -NoLogo -NoProfile" })
    local ok, err = pcall(function()
      test.ok(wait_for(view, function(value) return value.busy == false end, 20), "idle shell missing")
      -- "Thinking" in base64. The program reports "done" but does not clear its step.
      test.ok(view.session:write(
        "$e=[char]27; [Console]::Write(\"$e]7501;state=working$e\\\");" ..
        " [Console]::Write(\"$e]7501;state=working:id=step:msg=VGhpbmtpbmc=$e\\\"); Start-Sleep 1;" ..
        " [Console]::Write(\"$e]7501;state=done$e\\\"); Start-Sleep 4\r"))
      test.ok(wait_for(view, function(value) return value.agent_step == "Thinking" end, 4), "step missing")
      local done = wait_for(view, function(value) return value.agent_state == "done" end, 4)
      test.equal(done and done.agent_state, "done")
      test.equal(done and done.agent_step, nil, "The step outlived its run")
    end)
    view:on_close()
    test.ok(ok, err)
  end)

  test.it("ignores a malformed report", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    terminal._set_native_for_tests(nil)
    local view = ready(terminal.open { cwd = system.getcwd(), shell = "powershell.exe -NoLogo -NoProfile" })
    local ok, err = pcall(function()
      test.ok(wait_for(view, function(value) return value.busy == false end, 20), "idle shell missing")
      -- The second report's message is not base64, so the first report stays.
      test.ok(view.session:write(
        "$e=[char]27; [Console]::Write(\"$e]7501;state=working$e\\\");" ..
        " [Console]::Write(\"$e]7501;state=blocked:msg=%%%$e\\\"); Start-Sleep 3\r"))
      test.ok(wait_for(view, function(value) return value.agent_state ~= nil end, 4), "status missing")
      -- Both reports arrive within a moment. Give the host time to record the second one too.
      local value = wait_for(view, function() return false end, 1)
      test.equal(value and value.agent_state, "working")
    end)
    view:on_close()
    test.ok(ok, err)
  end)
end)
