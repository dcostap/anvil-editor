local core = require "core"
local test = require "core.test"
local terminal = require "plugins.terminal"
local config = require "core.config"
local common = require "core.common"
local panes = require "core.panes"
local json = require "core.json"
local native

local function wait_for(predicate)
  local deadline = system.get_time() + 30
  repeat
    if predicate() then return true end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  return false
end

local function text(view)
  return view.session:text_capture().text
end

local function service(view)
  view:service_session(true)
  return view.state == "running" and view.agent_app == "pi" and text(view):find("PREPARED_PI_READY", 1, true)
end

local dir, shell_command, views, previous_log, previous_config, previous_root
local function track(view)
  views[#views + 1] = view
  return view
end

local function open_pi(cwd)
  return track(terminal.open { cwd = cwd or dir, pi = true, placement = "new" })
end

local function open_shell()
  local view = track(terminal.open { cwd = dir, placement = "new" })
  test.ok(wait_for(function()
    view:service_session(true)
    return view.state == "running" and text(view):find("PREPARED_PI_SHELL_READY", 1, true)
  end), "The private test shell did not start")
  return view
end

local function copy(source)
  return track(panes.place(function() return source:duplicate() end, { placement = "new" }))
end

-- Records the prepared session of each native launch.
local function watch_preparation()
  local slot = {}
  terminal._set_native_for_tests {
    new = function(options)
      local session, err, code = native.new(options)
      if options.prepared then slot.session = session end
      return session, err, code
    end,
  }
  return slot
end

local function launches()
  local result = {}
  for _, name in ipairs(system.list_dir(dir) or {}) do
    if name:find("%.json$") then
      local file = assert(io.open(dir .. "/" .. name, "rb"))
      local contents = file:read("*a"):gsub("^\239\187\191", "")
      file:close()
      result[#result + 1] = json.decode(contents)
    end
  end
  return result
end

test.describe("Prepared Pi", function()
  test.before_each(function()
    dir = nil
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    native = require "terminal_native"
    dir = USERDIR .. "/prepared pi " .. tostring(system.get_time()):gsub("%.", "-")
    test.ok(system.mkdir(dir))
    local fixture = system.getcwd() .. "/tests/fixtures/prepared-pi.ps1"
    local file = assert(io.open(dir .. "/pi.cmd", "wb"))
    file:write('@echo off\r\npowershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "' .. fixture .. '" %*\r\n')
    file:close()
    -- New shells read the registry PATH. Set the fixture PATH inside each test shell.
    file = assert(io.open(dir .. "/shell.cmd", "wb"))
    file:write('@echo off\r\nset "PATH=%~dp0;%SystemRoot%\\System32;%SystemRoot%\\System32\\WindowsPowerShell\\v1.0"\r\necho PREPARED_PI_SHELL_READY\r\n')
    file:close()
    shell_command = 'cmd.exe /D /Q /K ""' .. (dir .. "/shell.cmd"):gsub("/", "\\") .. '""'
    previous_log = os.getenv("ANVIL_TEST_PI_LOG")
    system.setenv("ANVIL_TEST_PI_LOG", dir)
    local terminal_config = config.plugins.terminal
    previous_config = {terminal_config.prepare_session, terminal_config.prepare_pi, terminal_config.shell}
    terminal_config.prepare_session, terminal_config.prepare_pi, terminal_config.shell = false, true, shell_command
    -- A new Pi starts at the Project's folder.
    previous_root = core.root_project
    core.root_project = function() return {path = dir} end
    views = {}
    terminal._set_native_for_tests(nil)
  end)

  test.after_each(function()
    if not dir then return end
    for _, view in ipairs(views or {}) do view:on_close() end
    terminal._set_native_for_tests(nil)
    native.finish_close_commands()
    local terminal_config = config.plugins.terminal
    terminal_config.prepare_session, terminal_config.prepare_pi, terminal_config.shell = table.unpack(previous_config)
    core.root_project = previous_root
    system.setenv("ANVIL_TEST_PI_LOG", previous_log or "")
    if dir then test.ok(test.remove_tree(dir)) end
  end)

  test.it("copies a Pi Terminal as a plain Terminal", function()
    config.plugins.terminal.prepare_pi = false
    local source = open_pi()
    test.ok(wait_for(function() return service(source) end), "Pi did not start: " .. text(source))
    local duplicate = copy(source)
    test.ok(wait_for(function()
      duplicate:service_session(true)
      return duplicate.state == "running" and text(duplicate):find("PREPARED_PI_SHELL_READY", 1, true)
    end), "Copy View did not start a shell")
    -- The shell runs this command only when no Pi reads the input.
    test.ok(duplicate:write_input("echo COPY_%OS%\r"))
    test.ok(wait_for(function() duplicate:service_session(true); return text(duplicate):find("COPY_Windows_NT", 1, true) end),
      "Copy View started Pi: " .. text(duplicate))
    test.is_nil(duplicate.agent_app)
    test.equal(#launches(), 1, "Copy View started Pi")
  end)

  test.it("gives a new Pi the prepared Pi and never gives it to a normal Terminal", function()
    local prepared = watch_preparation()
    test.ok(wait_for(function() return terminal.prepare_pi_session() end), "Pi preparation did not finish")
    local id = prepared.session:stats().session_id
    test.is_nil(native.read_session_record(id), "unused Pi appeared in the Sidebar's session records")
    local shell = open_shell()
    test.not_equal(shell.session_id, id, "normal Terminal received the prepared Pi")
    local started = system.get_time()
    local pi = open_pi()
    print(string.format("Prepared Pi open: %.1fms", (system.get_time() - started) * 1000))
    test.equal(pi.session_id, id, "New Pi did not use the prepared Pi")
    test.ok(text(pi):find("PREPARED_PI_READY", 1, true), "prepared Pi screen was lost")
    test.ok(wait_for(function() return service(pi) and native.read_session_record(id) ~= nil end))
    test.ok(wait_for(function() return terminal.prepare_pi_session() end), "replacement Pi did not become ready")
    test.not_equal(prepared.session:stats().session_id, id, "preparation reused an accepted Pi")
  end)

  test.it("does not use a prepared Pi from another directory", function()
    test.ok(wait_for(function() return terminal.prepare_pi_session() end))
    local other_dir = dir .. "/other"
    test.ok(system.mkdir(other_dir))
    local pi = open_pi(other_dir)
    test.ok(wait_for(function() return service(pi) end))
    local id = text(pi):match("PREPARED_PI_READY ([%w]+)")
    local found
    for _, launch in ipairs(launches()) do
      if launch.id == id then found = launch.cwd end
    end
    test.ok(found and common.path_equals(found, other_dir), "New Pi used Pi from another directory")
  end)

  for _, action in ipairs { "disable", "discard" } do
    test.it("closes the unused Pi on " .. action, function()
      local prepared = watch_preparation()
      test.ok(wait_for(function() return terminal.prepare_pi_session() end))
      local id = prepared.session:stats().session_id
      if action == "disable" then
        config.plugins.terminal.prepare_pi = false
        test.not_ok(terminal.prepare_pi_session())
      else
        terminal.discard_prepared_session()
      end
      local _, status = prepared.session:update()
      test.equal(status.kind, "closed")
      test.is_nil(native.read_session_record(id), "unused Pi left a saved Terminal")
    end)
  end

  test.it("starts normally if the prepared Pi has exited", function()
    local prepared = watch_preparation()
    test.ok(wait_for(function() return terminal.prepare_pi_session() end))
    local id = prepared.session:stats().session_id
    test.ok(prepared.session:write("exit\r"))
    test.ok(wait_for(function()
      local _, status = prepared.session:update()
      return status.agent_app == nil and status.busy == false
    end), "prepared host kept Pi's old status after Pi exited")
    local pi = open_pi()
    test.ok(wait_for(function() return service(pi) end), "failed preparation blocked a new Pi")
    test.not_equal(pi.session_id, id, "New Pi received the shell of a Pi that exited")
  end)
end)
