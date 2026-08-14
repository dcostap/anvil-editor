local common = require "core.common"
local process = require "core.process"
local shell = require "core.shell"
local test = require "core.test"

local function await(done, timeout)
  local deadline = system.get_time() + (timeout or 5)
  while not done() and system.get_time() < deadline do coroutine.yield(0.01) end
  test.ok(done(), "shell capture timed out")
end

test.describe("shell capture", function()
  test.it("builds independent shell adapter argument lists", function()
    local one = shell.capture_args("Write-Output one", "pwsh.exe")
    local two = shell.capture_args("Write-Output two", "pwsh.exe")
    test.same(one, { "pwsh.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", "Write-Output one" })
    test.equal(two[6], "Write-Output two")
    test.not_equal(one, two)
    test.same(shell.capture_args("echo ok", "cmd.exe"), { "cmd.exe", "/d", "/s", "/c", "echo ok" })
    test.same(shell.capture_args("printf ok", "bash"), { "bash", "-lc", "printf ok" })
  end)

  test.it("captures PowerShell output, working directory, and exit code", function(context)
    test.skip_if(PLATFORM ~= "Windows", "PowerShell capture test")
    local root = USERDIR .. PATHSEP .. "shell-capture-" .. system.get_process_id()
    test.ok(common.mkdirp(root))
    context.root = root
    local output, result = ""
    shell.capture("Write-Output $PWD.Path; [Console]::Error.WriteLine('stderr-line'); exit 7", {
      shell = "powershell.exe",
      cwd = root,
      on_output = function(chunk) output = output .. chunk end,
      on_exit = function(value) result = value end,
    })
    await(function() return result ~= nil end)
    test.contains(output, common.normalize_path(root))
    test.contains(output, "stderr-line")
    test.equal(result.code, 7)
    test.ok(result.elapsed >= 0)
    common.rm(root, true)
  end)

  test.it("caps delivered output while draining the process", function()
    local output, result = ""
    local command = PLATFORM == "Windows"
      and "[Console]::Write('abcdefghij')"
      or "printf abcdefghij"
    shell.capture(command, {
      shell = PLATFORM == "Windows" and "powershell.exe" or "sh",
      max_output_bytes = 5,
      on_output = function(chunk) output = output .. chunk end,
      on_exit = function(value) result = value end,
    })
    await(function() return result ~= nil end)
    test.equal(output, "abcde")
    test.ok(result.truncated)
  end)

  test.it("rejects stale output after cancellation", function()
    local output, result = "", nil
    local command = PLATFORM == "Windows"
      and "Start-Sleep -Milliseconds 300; Write-Output stale"
      or "sleep 0.3; printf stale"
    local run = shell.capture(command, {
      shell = PLATFORM == "Windows" and "powershell.exe" or "sh",
      on_output = function(chunk) output = output .. chunk end,
      on_exit = function(value) result = value end,
    })
    run:cancel()
    await(function() return result ~= nil end)
    test.equal(output, "")
    test.ok(result.cancelled)
  end)

  test.it("reports one normalized start error", function()
    local errors = {}
    shell.capture("echo unreachable", {
      shell = "anvil-shell-that-does-not-exist-9f27",
      on_error = function(value) errors[#errors + 1] = value end,
    })
    await(function() return #errors > 0 end)
    test.equal(#errors, 1)
    test.equal(errors[1].kind, "start")
    test.type(errors[1].message, "string")
  end)
end)
