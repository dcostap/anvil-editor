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

  test.it("follows the host layout, publishes a split and keeps edits across a remote close", function(context)
    local sync = require "core.shared_layout"
    local function request(method, params)
      params.project = context.project
      local done, reply
      fs.machine:request(method, params, nil, function(err, r) done, reply = true, r or err end)
      wait_until({}, function() return done end, "Layout request timed out")
      return reply
    end
    wait_until({},function() return fs.machine.state == "ready" end,"Machine not ready")
    test.is_nil(fs.wait(fs.write, context.project .. PATHSEP .. "layout.txt", "on the host\n", nil, nil))
    test.equal(request("layout.set", {base=0, layout={groups={{file="layout.txt"}}, active=1}}).revision,1)
    local restored = core.workspace_restored
    core.workspace_restored = true
    local ok, err = pcall(function()
      sync.start(context.project)
      wait_until({},function() return sync.capture(context.project).active == 1 end,"Missing host file")
      local original = panes.active().current_view
      local buffer = original.buffer
      wait_until({},function() return buffer.lines[1] == "on the host\n" end,"File did not load")
      panes.split(panes.active(), "right", {factory=function() return require("core.editor")(buffer) end})
      local published
      wait_until({},function()
        published = request("layout.get", {})
        return published.revision == 2
      end,"Client did not publish the split")
      test.equal(published.layout.groups[1].axis,"x")
      test.equal(published.layout.active,2)
      local split = published.layout.groups[1]
      local second = panes.active().current_view
      split.a, split.b = split.b, split.a
      test.equal(request("layout.set", {base=2,layout=published.layout}).revision,3)
      wait_until({},function() return panes.active().current_view == original end,
        "Swapping two Panes of the same file lost their View identities")
      test.ok(panes.pane_for_view(second))
      buffer:insert(1,1,"unsaved")
      test.equal(request("layout.set",{base=3,layout={groups={},active=0}}).revision,4)
      test.not_ok(sync.apply(context.project,{groups={},active=0}))
      test.ok(panes.pane_for_view(original))
      test.ok(buffer.lines[1]:find("unsaved",1,true))
      buffer:undo()
      wait_until({},function() return #sync.capture(context.project).groups == 0 end,"Close did not reach this PC")
      -- Another PC reopened both Panes before this PC ran Reopen Closed Pane.
      test.ok(sync.apply(context.project,published.layout))
      local count = panes.count()
      test.ok(panes.reopen_last_closed())
      test.equal(panes.count(),count,"Reopen duplicated a shared Pane")
      test.ok(sync.apply(context.project,{groups={},active=0}))
      -- Open a live Terminal from the host layout, then close its Pane without replacing the shell.
      local host = open(context,{})
      wait_text(host,"ANVIL_ECHO_READY:project")
      local session = host.session_id
      local sessions = require "core.machine_terminal"
      wait_until(host,function()
        sessions.sessions(fs.machine,context.project)
        return sessions.listed(session)
      end,"The host did not list its Terminal")
      test.equal(request("layout.set",{base=4, layout={groups={{terminal=session}},active=1}}).revision,5)
      wait_until(host,function() return panes.active() and panes.active().current_view.session_id == session end,
        "Shared Terminal was not opened")
      local mirror = panes.active().current_view
      context.views[#context.views+1] = mirror
      wait_text(mirror,"ANVIL_ECHO_READY:project")
      test.equal(request("layout.set",{base=5,layout={groups={},active=0}}).revision,6)
      wait_until(host,function() return not panes.pane_for_view(mirror) end,"Remote Terminal close did not remove its Pane")
      test.ok(host:write_input("still-running\r"))
      wait_text(host,"ECHO:still-running")
    end)
    core.workspace_restored = restored
    assert(ok,err)
  end)

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

    local report = require "core.pane_report"
    local function listed()
      for _, item in ipairs(report.build().terminals or {}) do
        if item.id == id then return true end
      end
    end
    wait_until(view, listed, "The Machine did not list the session")
    view:on_close(true)
    test.not_ok(listed(), "Closing the last View left a stale session in the Sidebar report")
    wait_until(view, function()
      return not require("terminal_link").host_alive(record.host_pid, record.host_creation_time)
    end, "The Machine kept the closed shell")
  end)

  test.it("ends a Terminal shown by two copies of one shared Pane", function(context)
    local first = open(context,{})
    wait_text(first,"ANVIL_ECHO_READY:project")
    panes.create {factory=function() return first end}
    local layout = require("core.shared_layout").capture(context.project)
    local pane = layout.groups[#layout.groups].pane
    local mirror = open(context,{session_id=first.session_id})
    wait_text(mirror,"ANVIL_ECHO_READY:project")
    mirror:bind_shared_pane(pane)
    local independent = open(context,{session_id=first.session_id})
    wait_text(independent,"ANVIL_ECHO_READY:project")
    wait_until(first,function()
      local status = first:close_status()
      return status.clients == 3 and status.views == 2
    end,"The host lost the separate View")
    independent:detach_session()
    wait_until(first,function()
      local status = first:close_status()
      return status.clients == 2 and status.views == 1
    end,"The host counted a mirror as another View")
    local record = machine_record(context,first.session_id)
    first:on_close(true)
    wait_until(mirror,function()
      return not require("terminal_link").host_alive(record.host_pid,record.host_creation_time)
    end,"Closing the shared Pane kept the shell running")
  end)

  test.it("keeps the live grid when a remote View attaches before layout", function(context)
    local first = open(context,{})
    wait_text(first,"ANVIL_ECHO_READY:project")
    test.ok(first.session:resize(117,31,8,16))
    test.ok(first:write_input("sized\r"))
    wait_text(first,"ECHO:sized")
    local id = first.session_id
    first:detach_session()
    wait_until({},function()
      local record = machine_record(context,id)
      return record and record.attached == false
    end,"The original View did not detach")
    local restored = open(context,{session_id=id})
    wait_text(restored,"ECHO:sized")
    local grid = restored.session:snapshot(nil,false)
    test.equal(grid.cols,117,"Attach replaced the live grid with the placeholder width")
    test.equal(grid.row_count,31)
  end)

  test.it("types the path of a copy on the Machine for a dropped file", function(context)
    local view = open(context, {})
    wait_text(view, "ANVIL_ECHO_READY:project")
    local source = context.root .. PATHSEP .. "here" .. PATHSEP .. "shot.png"
    test.ok(common.mkdirp(common.dirname(source)))
    local file = assert(io.open(source, "wb"))
    file:write("picture bytes\0\255")
    file:close()

    test.ok(view:on_drop({ files = { source }, text = "" }))
    -- The shell shows the typed path before Enter. Its lines can wrap.
    local function flat() return (text_of(view):gsub("[\r\n]", "")) end
    wait_until(view, function() return flat():find("shot.png", 1, true) end, "No path was typed:\n" .. text_of(view))
    test.ok(view:write_input("\r"))
    local path
    wait_until(view, function()
      path = flat():match('ECHO:"?(.-shot%.png)')
      return path
    end, "The shell did not read the path:\n" .. text_of(view))
    test.ok(path:find("anvil-pastes", 1, true), "The path must name the Machine's copy, not this PC's file: " .. path)
    local copy = io.open(path, "rb")
    test.ok(copy, "The Machine has no file at " .. path)
    test.equal(copy:read("*a"), "picture bytes\0\255")
    copy:close()
    common.rm(common.dirname(path), true)
  end)

  test.it("closes a busy session without a question while another device shows it, and keeps its shell", function(context)
    -- The shell's child process keeps the session busy.
    config.plugins.terminal.shell = [[cmd.exe /d /c ping -n 600 127.0.0.1]]
    local first = open(context, {})
    -- ping prints its target when it runs.
    wait_text(first, "127.0.0.1")
    wait_until(first, function() return first:close_status().busy == true end,
      "The session does not report busy")
    local second = open(context, { session_id = first.session_id })
    local function clients(view) return view.session and view:close_status().clients end
    wait_until(second, function() return clients(first) == 2 and clients(second) == 2 end,
      "The Views do not count two devices")

    local approved = false
    first:can_close(function() approved = true end)
    test.ok(approved, "The close asked a question")
    first:on_close()
    table.remove(context.views, 1)
    wait_until(second, function() return clients(second) == 1 end, "The other device lost the shell")
    test.equal(second.state, "running")
  end)

  test.it("traces the hostname shell through selection of an unattached session", function(context)
    local other = open(context, {})
    wait_text(other, "ANVIL_ECHO_READY:project")
    local id = other.session_id
    other:detach_session()
    config.plugins.terminal.shell = "cmd.exe /d /q"
    local shell = assert(terminal.open { placement = "new", focus = true })
    context.views[#context.views + 1] = shell
    wait_until(shell, function() return shell.state == "running" end, "cmd did not attach")
    test.ok(shell:write_input("hostname\r"))
    wait_text(shell, assert(os.getenv("COMPUTERNAME")))
    local hostname = shell.session_id
    local sidebar = require("core.sidebar_view")(function(action, _, target)
      test.equal(action, "select_terminal")
      test.ok(require("core.pane_requests").perform(common.serialize({action="terminal_focus", session=target})))
    end)
    local function refresh()
      local report = require("core.pane_report").build()
      sidebar:set_model({{row_id=1,id=1,path=context.project,state="ready",window_id=1,
        terminals=report.terminals or {},panes=report},windows={{id=1,selected_project=1}}}, 1)
      return report
    end
    local function row(target)
      for _, item in ipairs(sidebar.rows) do
        if item.terminal and item.terminal.id == target or item.tab and item.tab.terminal
            and item.tab.terminal.session == target then return item end
      end
    end
    wait_until(shell, function()
      refresh()
      return require("core.machine_terminal").listed(hostname) and row(id) and row(hostname)
    end, "Missing rows before selection")
    sidebar:activate_row(row(id), false)
    local selected = panes.active().current_view
    context.views[#context.views + 1] = selected
    wait_text(selected, "ANVIL_ECHO_READY:project")
    test.equal(selected.session_id, id)
    local report = refresh()
    test.ok(require("core.machine_terminal").listed(hostname), "Session missing from Machine list")
    test.contains(report.held or {}, hostname)
    local previous = test.not_nil(row(hostname), "The Sidebar hid the Machine session in Pane history")
    local reply
    fs.machine:request("terminal.list", { project = context.project }, nil, function(err, result)
      reply = err and {} or result.sessions
    end)
    wait_until(selected, function() return reply end, "Machine did not reply")
    local ids = {}
    for _, session in ipairs(reply) do ids[#ids + 1] = session.id end
    test.contains(ids, hostname)
    sidebar:activate_row(previous, false)
    test.equal(panes.active().current_view.session_id, hostname)
    wait_text(panes.active().current_view, assert(os.getenv("COMPUTERNAME")))
  end)

  test.it("lists the Machine's sessions that no Pane shows, and opens them", function(context)
    local view = open(context, {})
    wait_text(view, "ANVIL_ECHO_READY:project")
    test.ok(view:write_input("before\r"))
    wait_text(view, "ECHO:before")
    local id = view.session_id
    -- The shell keeps running on the Machine.
    view:detach_session()

    local listed
    wait_until(view, function()
      for _, item in ipairs(require("core.pane_report").build().terminals or {}) do
        if item.id == id then listed = item end
      end
      return listed
    end, "The Pane report does not list the Machine's session")
    test.equal(listed.state, "running")

    local opened = assert(terminal.open_session(id))
    context.views[#context.views + 1] = opened
    wait_text(opened, "ECHO:before")
    test.is_nil(terminal.open_session(string.rep("0", 32)), "A session that the Machine does not list opened")
    local record = assert(machine_record(context, id))
    opened:on_close(true)
    test.not_ok(require("core.machine_terminal").listed(id), "The closed session can still be selected")
    wait_until(opened, function()
      return not require("terminal_link").host_alive(record.host_pid, record.host_creation_time)
    end, "Closing the reattached View kept its shell running")
  end)

  test.it("keeps an opened session's Pane until its host reports that no command runs", function(context)
    local ids = {}
    for i = 1, 2 do
      local view = open(context, {})
      wait_text(view, "ANVIL_ECHO_READY:project")
      ids[i] = view.session_id
      view:detach_session()
    end
    wait_until(context.views[1], function()
      local listed = 0
      for _, item in ipairs(require("core.pane_report").build().terminals or {}) do
        if item.id == ids[1] or item.id == ids[2] then listed = listed + 1 end
      end
      return listed == 2
    end, "The Pane report does not list both sessions")

    -- The Sidebar opens each session in the current Pane. The first one can run Pi, so it must keep its Pane.
    local first = assert(terminal.open_session(ids[1]))
    context.views[#context.views + 1] = first
    test.is_nil(first.busy, "The host reported its state too early for this check")
    local second = assert(terminal.open_session(ids[2]))
    context.views[#context.views + 1] = second
    test.equal(panes.pane_for_view(first).current_view, first, "The second session replaced the first")
    test.ok(panes.pane_for_view(second) ~= panes.pane_for_view(first))
    -- A View ends its shell on the Machine only after it attached.
    wait_text(first, "ANVIL_ECHO_READY")
    wait_text(second, "ANVIL_ECHO_READY")
    first:on_close(true)
    second:on_close(true)
  end)

  test.it("starts a new shell on the Machine when the restored session is gone", function(context)
    local gone = string.rep("0", 32)
    local stale = terminal.from_state({cwd=context.project, shell=ECHO_SHELL, session_id=gone}, nil, "workspace")
    context.views[#context.views+1] = stale
    wait_until(stale,function() return stale.state == "failed" end,"A cached Workspace revived a closed shared Terminal")
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
