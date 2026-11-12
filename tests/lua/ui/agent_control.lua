local core = require "core"
local panes = require "core.panes"
local RootPanel = require "core.rootpanel"
local View = require "core.view"
local test = require "core.test"
local ready = dofile("tests/fixtures/terminal_ready.lua")

-- Seam: editor control operations, shared by MCP and other local clients.
test.describe("Agent editor control", function()
  local saved, control
  test.before_each(function()
    saved = { root = core.root_panel, active = core.active_view, focus = core.set_active_view }
    panes.reset_for_tests()
    core.set_active_view = function(view) core.active_view = view end
    core.root_panel = RootPanel()
    control = require("core.control").new()
  end)
  test.after_each(function()
    panes.reset_for_tests()
    core.root_panel, core.active_view, core.set_active_view = saved.root, saved.active, saved.focus
  end)
  test.it("creates a named split once without taking focus", function()
    local source = panes.create { factory = function() return View() end }
    local args = { action = "split", pane = source.id, direction = "right", request_id = "split-one" }
    local result = control:call("pane", args, "test-client")
    test.ok(result.pane and result.pane ~= source.id)
    test.equal(panes.find(result.pane).group, source.group)
    test.equal(panes.active(), source)
    test.equal(core.active_view, source.current_view)
    test.equal(control:call("pane", args, "test-client").pane, result.pane)
    test.equal(#panes.ordered(), 2)
    local state = control:call("workspace_state", {}, "test-client")
    test.ok(state.panes[result.pane])
    local ok = pcall(function()
      control:call("pane", { action = "create", request_id = "split-one" }, "test-client")
    end)
    test.equal(ok, false, "A retry key cannot describe different work")
  end)
  test.it("keeps close confirmation and rejects unrecognized fields", function()
    local approve
    local pane = panes.create { factory = function()
      local view = View()
      function view:can_close(done) approve = done end
      return view
    end }
    local result = control:call("pane", { action = "close", pane = pane.id, request_id = "close-one" }, "test-client")
    test.equal(result.status, "confirmation_required")
    test.ok(panes.find(pane.id))
    test.equal(pcall(function()
      control:call("pane", { action = "close", pane = pane.id, force = true, request_id = "close-force" }, "test-client")
    end), false)
    approve()
    test.is_nil(panes.find(pane.id))
  end)

  test.it("lists other Panes when a restored Terminal cannot open its session", function()
    local terminal = require "plugins.terminal"
    local id = "0123456789abcdef0123456789abcdef"
    local other = panes.create { factory = function() return View() end }
    -- The native record reader is the external boundary. Access failure leaves no native session.
    terminal._set_native_for_tests { read_session_record = function() return nil, 5 end }
    local view
    local ok, err = pcall(function()
      view = terminal.open { session_id = id, placement = "new" }
      local pane = panes.pane_for_view(view)
      local state = control:call("workspace_state", {}, id)
      test.ok(state.panes[other.id], "the failed Terminal hid another Pane")
      test.equal(state.panes[pane.id].terminal_state, "failed")
      test.equal(state.terminals[id].state, "failed")
      test.equal(state.caller_pane, pane.id)
    end)
    if view then view:on_close() end
    terminal._set_native_for_tests(nil)
    test.ok(ok, err)
  end)

  for _, case in ipairs {
    {tool = "pane"}, {tool = "terminal"},
    {tool = "pane", history = true}, {tool = "terminal", history = true},
  } do
    local tool = case.tool
    local name = case.history and " close preserves unsaved Views beside the caller's Terminal"
      or " close accepts the caller's own busy Terminal but asks for another caller"
    test.it(tool .. name, function()
      test.skip_if(PLATFORM ~= "Windows", "Windows Terminal test")
      local terminal = require "plugins.terminal"
      local command = require "core.command"
      local folder = USERDIR .. "/control-close-" .. tool
      require("core.common").mkdirp(folder)
      terminal._set_native_for_tests(nil)
      local view, pane, editor
      local ok, err = pcall(function()
        view = ready(terminal.open {cwd = folder, shell = "powershell.exe -NoLogo -NoProfile", placement = "new"})
        pane = panes.pane_for_view(view)
        if case.history then
          local Editor = require "core.editor"
          view:mark_input_used()
          editor = panes.place(function() return Editor(core.open_buffer()) end, {pane = pane, placement = "current"})
          editor.buffer:insert(1, 1, "keep this text")
          test.ok(panes.pane_for_view(view) == pane and pane.current_view == editor)
        end
        test.ok(view:write_input("Start-Sleep 60\r"))
        local deadline = system.get_time() + 30
        repeat
          view:service_session(true)
          if view:close_status().busy == true then break end
          coroutine.yield(0.01)
        until system.get_time() >= deadline
        test.equal(view:close_status().busy, true, "the shell did not report its running command")
        local args = {action = "close", request_id = "close-other"}
        args[tool] = tool == "pane" and pane.id or view.session_id
        local result
        if not case.history then
          result = control:call(tool, args, "another-terminal")
          test.equal(result.status, "confirmation_required")
          test.ok(core.nag_view.visible)
          test.ok(command.perform "core:select_dialog_no")
          test.ok(panes.contains(pane))
        end
        args.request_id = "close-self"
        result = control:call(tool, args, view.session_id)
        if case.history and tool == "pane" then
          test.equal(result.status, "confirmation_required")
          test.equal(core.active_view, core.global_prompt_bar)
          test.equal(view.state, "running")
          test.ok(command.perform "core:close_prompt")
          test.equal(editor.buffer:get_text(1, 1, 1, math.huge), "keep this text")
          test.ok(editor.buffer:is_dirty())
          -- Remove only the unsaved View. The next request must approve its Terminal again.
          test.ok(panes.close_view(pane, {view = editor, force = true}))
          args.request_id = "close-self-after-cancel"
          result = control:call(tool, args, view.session_id)
        end
        test.equal(result.status, "closed")
        test.equal(view.state, "closed")
        test.not_ok(core.nag_view.visible)
        if case.history and tool == "terminal" then
          test.equal(pane.current_view, editor)
          test.equal(editor.buffer:get_text(1, 1, 1, math.huge), "keep this text")
          test.ok(editor.buffer:is_dirty())
        else
          test.not_ok(panes.contains(pane))
        end
      end)
      if core.nag_view.visible then command.perform "core:select_dialog_no" end
      if core.active_view == core.global_prompt_bar then command.perform "core:close_prompt" end
      if pane and panes.contains(pane) then panes.close(pane, {force = true})
      elseif view then view:on_close() end
      test.ok(test.remove_tree(folder))
      assert(ok, err)
    end)
  end

  test.it("sets and removes the caller's Snooze through the Sidebar without taking another Pane's focus", function()
    local storage = require "core.storage"
    local SidebarView = require "core.sidebar_view"
    local snoozes, requests = {}, 0
    local source = panes.create {factory = function()
      local view = View()
      view.terminal_view, view.session_id = true, "caller-terminal"
      function view:close_status() return {} end
      return view
    end}
    local focused = panes.create {factory = function() return View() end}
    panes.focus(focused)
    local sidebar = SidebarView(function(action, route, path, value)
      if action == "snooze" then storage.save("sidebar", "snoozes", snoozes)
      elseif action == "request" then
        test.equal(route, "direct")
        test.equal(path, control.project)
        core.on_event("panerequest", require("core.common").serialize(value, {escape = true}), -1, -1, 0)
      end
    end, {}, {}, false, snoozes)
    local send = system.pane_request
    system.pane_request = function(route, path, text)
      test.equal(route, "sidebar")
      test.equal(path, control.project)
      requests = requests + 1
      return sidebar:on_snooze_request(text)
    end
    local ok, err = pcall(function()
      local before = os.time()
      local args = {action = "set", seconds = 5 * 3600, request_id = "snooze-self"}
      local result = control:call("snooze", args, "caller-terminal")
      test.equal(result.status, "accepted")
      test.equal(result.pane, source.id)
      test.equal(result.terminal, "caller-terminal")
      test.ok(result.until_time >= before + 5 * 3600 and result.until_time <= os.time() + 5 * 3600)
      test.equal(storage.load("sidebar", "snoozes")["caller-terminal"], result.until_time)
      test.ok(panes.is_snoozed(source))
      test.equal(panes.active(), focused)
      test.ok(control:call("workspace_state", {}, "caller-terminal").panes[source.id].snoozed)
      test.same(control:call("snooze", args, "caller-terminal"), result)
      test.equal(requests, 1, "A retry must not extend or resend the Snooze")
      control:call("snooze", {action = "remove", pane = source.id, request_id = "wake"}, "local")
      test.is_nil(storage.load("sidebar", "snoozes")["caller-terminal"])
      test.not_ok(panes.is_snoozed(source))
      test.equal(panes.active(), focused)
      test.equal(pcall(function()
        control:call("snooze", {action = "set", seconds = 60, pane = focused.id, request_id = "file"}, "local")
      end), false, "A file Pane cannot snooze")
      test.equal(pcall(function()
        control:call("snooze", {action = "set", seconds = 60, request_id = "no-caller"}, "local")
      end), false, "A client without a Terminal must name a target")
    end)
    system.pane_request = send
    storage.clear("sidebar", "snoozes")
    assert(ok, err)
  end)

  test.it("moves a Pane to another Project, which the shell selects only when focus is requested", function()
    local Capture = require("core.text_capture").View
    local sent = {}
    local send = system.pane_request
    system.pane_request = function(route, path, text)
      sent[#sent + 1] = {route = route, path = path, request = assert(load("return " .. text, "request", "t", {}))()}
      return true
    end
    local ok, err = pcall(function()
      local pane = panes.create {factory = function() return Capture {title = "Notes", text = "one"} end}
      local other = panes.create {factory = function() return Capture {title = "Other", text = "two"} end}
      local result = control:call("pane", {action = "move", pane = pane.id, target_project = "C:/Other",
        request_id = "move-out"}, "test-client")
      test.equal(result.status, "accepted")
      test.same({sent[1].route, sent[1].path, sent[1].request.action}, {"direct", "C:/Other", "import"})
      control:call("pane", {action = "move", pane = other.id, target_project = "C:/Other", focus = true,
        request_id = "move-focus"}, "test-client")
      test.equal(sent[2].route, "select")
      test.equal(pcall(function()
        control:call("pane", {action = "move", pane = pane.id, target_project = control.project,
          request_id = "move-same"}, "test-client")
      end), false, "A Pane cannot move to its own Project")
    end)
    system.pane_request = send
    assert(ok, err)
  end)

  test.it("opens Projects without selecting them and refuses to unload its own Project or Scratch", function()
    local saved_system = {hosted = system.is_hosted_surface, load = system.load_project,
      select = system.select_project, unload = system.unload_project}
    local calls = {}
    system.is_hosted_surface = function() return true end
    for _, name in ipairs {"load_project", "select_project", "unload_project"} do
      system[name] = function(path) calls[#calls + 1] = {name, path}; return true end
    end
    local folder = USERDIR .. PATHSEP .. "control-project"
    require("core.common").mkdirp(folder)
    local ok, err = pcall(function()
      local opened = control:call("project", {action = "open", path = folder, request_id = "open"}, "test-client")
      test.equal(opened.status, "accepted")
      test.ok(require("core.common").path_equals(opened.path, folder))
      control:call("project", {action = "open", path = folder, focus = true, request_id = "show"}, "test-client")
      control:call("project", {action = "unload", path = folder, request_id = "unload"}, "test-client")
      local path = opened.path
      test.same(calls, {{"load_project", path}, {"select_project", path}, {"unload_project", path}})
      for _, path in ipairs {control.project, USERDIR .. PATHSEP .. "scratch"} do
        test.equal(pcall(function()
          control:call("project", {action = "unload", path = path, request_id = "unload " .. path}, "test-client")
        end), false)
      end
      test.equal(pcall(function()
        control:call("project", {action = "open", path = folder .. PATHSEP .. "missing", request_id = "missing"}, "test-client")
      end), false, "A missing folder opens no Project")
      test.equal(#calls, 3)
    end)
    system.is_hosted_surface, system.load_project = saved_system.hosted, saved_system.load
    system.select_project, system.unload_project = saved_system.select, saved_system.unload
    test.ok(test.remove_tree(folder))
    assert(ok, err)
  end)

  test.it("opens a Git diff with Diff Notes and reports note paths outside the diff", function()
    local process = require "core.process"
    local git = require("plugins.git.backend").git_path()
    local root = USERDIR .. PATHSEP .. "control-diff-" .. system.get_process_id()
    local function run(...)
      local proc = process.start({git, "-C", root:gsub("\\", "/"), ...},
        {stdin = process.REDIRECT_DISCARD, stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_PIPE})
      test.equal(proc:wait(process.WAIT_INFINITE, 0.01), 0, proc:read_stderr(65536))
    end
    local function write(text)
      local file = assert(io.open(root .. PATHSEP .. "a.txt", "wb"))
      file:write(text)
      file:close()
    end
    require("core.common").mkdirp(root)
    local ok, err = pcall(function()
      run("init")
      run("config", "user.name", "Anvil Test")
      run("config", "user.email", "anvil@example.test")
      run("config", "core.autocrlf", "false")
      write("one\ntwo\nthree\n")
      run("add", "-A")
      run("commit", "-m", "Initial")
      write("one\ntwo changed\nthree\n")
      control = require("core.control").new(root)
      test.equal(pcall(function()
        control:call("diff_open", {base = "--output=x", request_id = "option"}, "test-client")
      end), false, "A revision cannot read as a Git option")
      local result = control:call("diff_open", {title = "Second line", request_id = "diff", notes = {
        {path = "a.txt", line = 2, text = "Explains the **change**"},
        {path = "missing.txt", line = 1, text = "Not in this diff"},
      }}, "test-client")
      local deadline = system.get_time() + 20
      while control:call("operation_read", {operation = result.operation}, "test-client").status == "opening" do
        test.ok(system.get_time() < deadline, "The diff did not open")
        coroutine.yield(0.02)
      end
      test.equal(result.status, "ready", result.error)
      test.same(result.files, {"a.txt"})
      test.same(result.unplaced, {"missing.txt"})
      local view = panes.find(result.pane).current_view
      local comparison = view:ensure_diff_view(view:model_tab())
      comparison.size.x, comparison.size.y = 1000, 1000
      deadline = system.get_time() + 5
      while comparison.updater_idx do
        test.ok(system.get_time() < deadline, "The comparison did not finish")
        coroutine.yield(0.01)
      end
      comparison:update()
      comparison:update()
      local side = comparison.buffer_view_b
      local _, y2 = side:get_line_screen_position(2, 1)
      local _, y3 = side:get_line_screen_position(3, 1)
      test.ok(y3 - y2 > side:get_line_height() * 2, "The note's card follows the changed line")
      comparison:on_close()
    end)
    test.ok(test.remove_tree(root))
    assert(ok, err)
  end)

  test.it("sends a task once to the selected Pi instance and keeps its result", function()
    control:exchange("terminal-b", {instance = "pi-one", session = "session.jsonl", busy = false,
      receipts = {}, tasks = {}})
    local args = {terminal = "terminal-b", instance = "pi-one", text = "Review the change",
      delivery = "queue", request_id = "review"}
    local sent = control:call("agent_send", args, "terminal-a")
    local response = control:exchange("terminal-b", {instance = "pi-one", busy = false, receipts = {}, tasks = {}})
    test.equal(#response.commands, 1)
    test.equal(response.commands[1].id, sent.task)
    test.equal(response.commands[1].from, "terminal-a")
    test.equal(control:call("agent_send", args, "terminal-a").task, sent.task)
    control:exchange("terminal-b", {instance = "pi-one", busy = false,
      receipts = {{id = sent.task, status = "accepted"}},
      tasks = {{id = sent.task, status = "completed", result = "No issues"}}})
    local result = control:call("agent_read", {terminal = "terminal-b", instance = "pi-one", task = sent.task}, "terminal-a")
    test.equal(result.status, "completed")
    test.equal(result.result, "No issues")
    control:exchange("terminal-b", {instance = "pi-two", busy = false, receipts = {}, tasks = {}})
    test.equal(pcall(function()
      control:call("agent_send", {terminal = "terminal-b", instance = "pi-one", text = "Again",
        delivery = "queue", request_id = "review-new"}, "terminal-a")
    end), false, "A stale request cannot target a replacement conversation")
  end)

  test.it("returns observed activity without treating stale commands as live work", function()
    control:exchange("terminal-b", {instance = "pi-one", busy = true, receipts = {}, tasks = {},
      session = "C:/sessions/pi-one.jsonl", capabilities = {transcript = true, activity = true},
      activity = {phase = "running_tools", since = 1767225600000, tool_count = 1, tools_truncated = false,
        tools = {{id = "call-a", name = "bash", detail = "npm test", started_at = 1767225600000, detail_truncated = false}}}})
    local result = control:call("agent_read", {terminal = "terminal-b", instance = "pi-one"}, "terminal-a")
    test.equal(result.activity.phase, "running_tools")
    test.equal(result.activity.tools[1].detail, "npm test")
    test.equal(result.activity_stale, false)
    test.ok(result.observation_age_ms >= 0)
    test.ok(result.capabilities.transcript)
    result = control:call("agent_read", {terminal = "terminal-b", instance = "pi-one", include_activity = false}, "terminal-a")
    test.is_nil(result.activity)
    -- A copied agent address names only the Terminal. A read then uses its current conversation.
    result = control:call("agent_read", {terminal = "terminal-b"}, "terminal-a")
    test.equal(result.instance, "pi-one")
    test.equal(result.session_file, "C:/sessions/pi-one.jsonl")
    -- A replaced conversation must not inherit the old one's tools or capabilities.
    control:exchange("terminal-b", {instance = "pi-two", busy = false, receipts = {}, tasks = {}})
    result = control:call("agent_read", {terminal = "terminal-b", instance = "pi-two"}, "terminal-a")
    test.is_nil(result.activity)
    test.equal(pcall(function()
      control:call("agent_transcript", {terminal = "terminal-b", instance = "pi-two"}, "terminal-a")
    end), false, "An older Pi must report that it needs a reload, not queue an unreadable request")
  end)

  test.it("opens a file and a Terminal in explicit Panes without changing focus", function()
    test.skip_if(PLATFORM ~= "Windows", "Windows Terminal test")
    local folder = USERDIR .. "/control-open"
    require("core.common").mkdirp(folder)
    local file = assert(io.open(folder .. "/note.txt", "wb"))
    file:write("first\nsecond\n"); file:close()
    local source = panes.create {factory = function() return View() end}
    local terminal
    local terminal_config = require("core.config").plugins.terminal
    local shell = terminal_config.shell
    -- The default shell is unset.
    terminal_config.shell = nil
    local ok, err = pcall(function()
      local opened = control:call("open_file", {path = folder .. "/note.txt", line = 2,
        pane = source.id, placement = "split", direction = "right", request_id = "open-note"}, "test-client")
      test.equal(panes.find(opened.pane).current_view.buffer.abs_filename:gsub("\\", "/"), folder .. "/note.txt")
      test.equal(panes.active(), source)
      terminal = control:call("terminal_start", {cwd = folder, executable = "hostname.exe", pane = source.id,
        placement = "split", direction = "down", request_id = "open-terminal"}, "test-client")
      test.equal(panes.active(), source)
      local deadline = system.get_time() + 30
      local result
      repeat
        panes.find(terminal.pane).current_view:update()
        control:tick()
        result = control:call("operation_read", {operation = terminal.operation}, "test-client")
        coroutine.yield()
      until result.status ~= "starting" or system.get_time() > deadline
      test.equal(result.status, "ready")
      test.ok(result.terminal)
      test.equal(panes.active(), source)
    end)
    terminal_config.shell = shell
    if terminal and panes.find(terminal.pane) then panes.close(terminal.pane, {force = true}) end
    test.ok(test.remove_tree(folder))
    assert(ok, err)
  end)
end)
