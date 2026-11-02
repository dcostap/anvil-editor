local common = require "core.common"
local machine_server = dofile("tests/fixtures/machine_server.lua")
local MachineClient = require "core.machine_client"
local test = require "core.test"

-- Seam: the Companion app on the emulator, against a real `anvil serve`. The app pairs through its form and lists
-- a Project's Terminal Session with its Agent Status. Install the app and its test APK first:
-- `./gradlew installDebug installDebugAndroidTest` in `android/`.
test.describe("Companion Machines", function()
  local TIMEOUT = 30
  local PACKAGE = "io.github.dcostap.anvil"
  -- "Approve the edit" in base64. The shell is cmd, so PowerShell is its child and the session stays busy:
  -- the host drops the Agent Status of a session whose shell is idle.
  local BLOCKED_SHELL = [[cmd.exe /d /c powershell.exe -NoLogo -NoProfile -Command "$e=[char]27; ]]
    .. [[[Console]::Write(\"$e]7501;state=blocked:app=pi:msg=QXBwcm92ZSB0aGUgZWRpdA==$e\\\"); Start-Sleep 600"]]

  local function adb_path()
    local sdk = os.getenv("ANDROID_HOME") or (os.getenv("LOCALAPPDATA") or "") .. "\\Android\\Sdk"
    local path = sdk .. PATHSEP .. "platform-tools" .. PATHSEP .. "adb" .. (PLATFORM == "Windows" and ".exe" or "")
    return system.get_file_info(path) and path
  end

  local function run(args)
    local proc = process.start(args, {stdin = process.REDIRECT_DISCARD, stdout = process.REDIRECT_PIPE,
      stderr = process.REDIRECT_STDOUT})
    if not proc then return nil, "" end
    local parts = {}
    while proc:running() do
      parts[#parts + 1] = proc:read_stdout(64 * 1024) or ""
      coroutine.yield(0.05)
    end
    parts[#parts + 1] = proc:read_stdout(1024 * 1024) or ""
    return proc:returncode(), table.concat(parts)
  end

  -- The serial of a running emulator that has the app and its test APK, or nil. Tests never run on a phone.
  local function emulator(adb)
    local _, devices = run {adb, "devices"}
    for serial in (devices or ""):gmatch("(emulator%-%d+)%s+device") do
      local _, packages = run {adb, "-s", serial, "shell", "pm", "list", "packages", PACKAGE}
      if packages:find("package:" .. PACKAGE .. ".test", 1, true) then return serial end
    end
  end

  local function wait_until(predicate, message)
    local deadline = system.get_time() + TIMEOUT
    while system.get_time() < deadline do
      if predicate() then return end
      coroutine.yield(0.05)
    end
    test.fail(message)
  end

  local function call(client, method, params)
    local done, err, result
    client:request(method, params, nil, function(e, r) done, err, result = true, e, r end)
    wait_until(function() return done end, "No reply to " .. method)
    return err, result
  end

  test.before_each(function(context)
    test.skip_if(PLATFORM ~= "Windows", "Terminal hosts use ConPTY")
    context.adb = adb_path()
    test.skip_if(not context.adb, "The Android SDK has no adb")
    context.serial = emulator(context.adb)
    test.skip_if(not context.serial, "No emulator has the Companion and its test APK")
    context.project = USERDIR .. PATHSEP .. "companion-" .. math.floor(system.get_time() * 1000000)
    test.ok(common.mkdirp(context.project))
  end)

  test.after_each(function(context)
    if context.owner then context.owner:close() end
    machine_server.stop(context.server)
    if context.session then context.session:close() end
    if context.project then test.ok(test.remove_tree(context.project)) end
  end)

  test.it("pairs and shows a waiting agent in its Project", function(context)
    context.session = assert(require("terminal_native").new {cols = 80, rows = 10, cell_width = 8, cell_height = 16,
      cwd = context.project, project_path = context.project, shell = BLOCKED_SHELL})
    wait_until(function()
      local _, status = context.session:update()
      return status.agent_state == "blocked" and status.busy == true
    end, "The session did not report its agent")
    local found
    context.server, found = machine_server.start(USERDIR, {context.project})
    context.owner = MachineClient.new(machine_server.discovery_path(USERDIR))
    wait_until(function() return context.owner.state == "ready" end, "The owner did not connect")
    local err, pairing = call(context.owner, "pairing.start", {level = "view"})
    test.equal(err, nil)
    -- The emulator reaches this PC's loopback address through 10.0.2.2.
    local code, output = run {context.adb, "-s", context.serial, "shell", "am", "instrument", "-w",
      "-e", "host", "10.0.2.2", "-e", "port", tostring(found.port), "-e", "code", pairing.code,
      "-e", "project", common.basename(context.project), "-e", "class", PACKAGE .. ".MachinesTest",
      PACKAGE .. ".test/androidx.test.runner.AndroidJUnitRunner"}
    test.equal(code, 0, output)
    test.ok(output:find("OK (1 test)", 1, true), output)
  end)
end)
