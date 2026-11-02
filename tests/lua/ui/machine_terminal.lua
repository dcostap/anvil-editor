local common = require "core.common"
local config = require "core.config"
local core = require "core"
local fs = require "core.fs"
local machine_server = dofile("tests/fixtures/machine_server.lua")
local panes = require "core.panes"
local Project = require "core.project"
local terminal = require "plugins.terminal"
local test = require "core.test"

-- Seam: Terminal Views in a Project process that uses a Machine. The Machine has its own user folder, so its
-- Terminal hosts write their records there, not in this process's user folder.
test.describe("Terminal on a Machine", function()
  local TIMEOUT = 30
  local ECHO_SHELL = [[powershell.exe -NoLogo -NoProfile -Command "[Console]::WriteLine('ANVIL_ECHO_READY:' + ]]
    .. [[(Split-Path -Leaf (Get-Location).Path)); while ($true) { $l = [Console]::ReadLine(); if ($l -eq $null) { break }; ]]
    .. [[[Console]::WriteLine('ECHO:' + $l) }"]]

  local function wait_until(view, predicate, message)
    local deadline = system.get_time() + TIMEOUT
    while system.get_time() < deadline do
      if view.session then view:service_session(true) end
      if predicate() then return end
      coroutine.yield(0.01)
    end
    test.fail(message)
  end

  local function text_of(view)
    return view.session and view.session:text_capture().text or ""
  end

  local function wait_text(view, expected)
    wait_until(view, function() return text_of(view):find(expected, 1, true) end,
      "Missing " .. expected .. ":\n" .. text_of(view))
  end

  -- The record that the Machine's host wrote, or nil.
  local function machine_record(context, id)
    local file = io.open(context.user .. PATHSEP .. "terminal-sessions" .. PATHSEP .. id .. ".lua", "rb")
    if not file then return nil end
    local text = file:read("*a")
    file:close()
    local ok, record = pcall(load(text, "=record", "t", {}))
    return ok and record or nil
  end

  test.before_each(function(context)
    test.skip_if(PLATFORM ~= "Windows", "Terminal hosts use ConPTY")
    context.root = system.absolute_path(USERDIR) .. PATHSEP .. "mterm" .. math.floor(system.get_time() * 1000) % 1000000
    context.user = context.root .. PATHSEP .. "user"
    context.project = context.root .. PATHSEP .. "project"
    test.ok(common.mkdirp(context.user))
    test.ok(common.mkdirp(context.project))
    context.projects, context.shell = core.projects, config.plugins.terminal.shell
    config.plugins.terminal.shell = ECHO_SHELL
    core.projects = { Project(context.project) }
    context.server = machine_server.start(context.user, { context.project })
    fs.use_machine(machine_server.discovery_path(context.user), { context.project })
    context.views = {}
  end)

  -- Waits until the Machine ended the shells of the closed Views. Closing sends the end to the Machine later.
  local function close_views(context)
    local alive, records = require("terminal_link").host_alive, {}
    for _, view in ipairs(context.views or {}) do
      records[#records + 1] = view.session_id and machine_record(context, view.session_id)
      view:on_close()
    end
    local deadline = system.get_time() + TIMEOUT
    for _, record in pairs(records) do
      while alive(record.host_pid, record.host_creation_time) and system.get_time() < deadline do
        coroutine.yield(0.01)
      end
      test.not_ok(alive(record.host_pid, record.host_creation_time), "The Machine kept a closed View's shell")
    end
  end

  test.after_each(function(context)
    close_views(context)
    panes.reset_for_tests()
    fs.use_local()
    if context.projects then core.projects = context.projects end
    if context.shell then config.plugins.terminal.shell = context.shell end
    machine_server.stop(context.server)
    if context.root then test.ok(test.remove_tree(context.root)) end
  end)

  local function open(context, options)
    local view = terminal.TerminalView(options)
    context.views[#context.views + 1] = view
    return view
  end

  test.it("runs its shell on the Machine, and closing the View ends that shell", function(context)
    local view = open(context, {})
    wait_text(view, "ANVIL_ECHO_READY:project")
    test.equal(view.state, "running")
    local id = view.session_id
    local record = machine_record(context, id)
    test.ok(record, "The Machine has no record of the session")
    test.ok(common.path_equals(record.project_path, context.project))
    test.is_nil(require("terminal_native").read_session_record(id), "This PC wrote a record of the Machine's session")

    test.ok(view:write_input("hello\r"))
    wait_text(view, "ECHO:hello")
    test.ok(view:move_refusal())

    -- The test's teardown checks that closing the View ends the shell.
  end)

  test.it("starts a new shell on the Machine when the restored session is gone", function(context)
    local gone = string.rep("0", 32)
    local view = terminal.from_state { cwd = context.project, shell = ECHO_SHELL, session_id = gone }
    context.views[#context.views + 1] = view
    wait_text(view, "ANVIL_ECHO_READY:project")
    test.ok(view.session_id and view.session_id ~= gone)
    test.equal(view:get_state().session_id, view.session_id)
  end)

  test.it("shows why the Machine did not start the shell", function(context)
    local view = open(context, { cwd = context.project .. PATHSEP .. "missing" })
    wait_until(view, function() return view.state == "failed" end, "The start did not fail: " .. tostring(view.state))
    test.ok(view.launch_error and view.launch_error ~= "")
    test.is_nil(view.session)
  end)
end)
