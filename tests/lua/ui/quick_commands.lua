local command = require "core.command"
local common = require "core.common"
local core = require "core"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local panes = require "core.panes"
local storage = require "core.storage"
local test = require "core.test"

local terminal = require "plugins.terminal"
local quick_commands = require "plugins.quick_commands"
require "plugins.autosave_fast"

local fake_native = require "scenes.quick_command_terminal"

local function open_terminal(placement)
  local view = terminal.open { placement = placement, focus = true, cwd = USERDIR }
  view:service_session(true)
  return view
end

local function open_editor(placement)
  return panes.place(function() return Editor(Buffer()) end, { placement = placement, focus = true })
end

local function set_quick_command(view, slot, text)
  core.set_active_view(view)
  test.ok(command.perform("quick_command:set_" .. slot))
  test.equal(core.active_view, core.global_prompt_bar)
  core.global_prompt_bar:set_text(text)
  core.global_prompt_bar:submit()
end

local function write_file(path, text)
  local file = assert(io.open(path, "wb"))
  assert(file:write(text))
  file:close()
end

local function read_file(path)
  local file = assert(io.open(path, "rb"))
  local text = file:read("*a")
  file:close()
  return text
end

local function file_buffer(context, name)
  if not context.temp_root then
    context.temp_root = USERDIR .. PATHSEP .. "quick-command-save-" .. system.get_process_id()
    test.ok(common.mkdirp(context.temp_root))
    context.buffers = {}
  end
  local path = context.temp_root .. PATHSEP .. name
  write_file(path, "original\n")
  local buffer = core.open_buffer(path)
  context.buffers[#context.buffers + 1] = buffer
  return buffer, path
end

test.describe("Quick Commands", function()
  test.before_each(function(context)
    panes.reset_for_tests()
    storage.clear("quick-commands")
    context.sessions = {}
    context.records = {}
    terminal._set_native_for_tests(fake_native(context))
    context.warn = core.warn
    context.nag_show = core.nag_view.show
    context.sync_file = system.sync_file
    context.cwd = system.getcwd()
    context.warnings = {}
    core.warn = function(format, ...) context.warnings[#context.warnings + 1] = string.format(format, ...) end
  end)

  test.after_each(function(context)
    core.warn = context.warn
    core.nag_view.show = context.nag_show
    system.sync_file = context.sync_file
    core.global_prompt_bar:exit()
    for _, view in ipairs(terminal.open_views()) do
      local pane = panes.pane_for_view(view)
      if pane then panes.close(pane, { force = true }) else view:on_close() end
    end
    panes.reset_for_tests()
    for _, buffer in ipairs(context.buffers or {}) do core.buffer_registry:remove(buffer, true) end
    terminal._set_native_for_tests(nil)
    storage.clear("quick-commands")
    for _, path in ipairs(context.files or {}) do os.remove(path) end
    system.chdir(context.cwd)
    if context.temp_root then test.ok(test.remove_tree(context.temp_root)) end
  end)

  for _, suffix in ipairs { "", "_without_moving_focus" } do
    local run = "quick_command:run_a" .. suffix
    test.it("saves focused and hidden file edits before terminal input via " .. run, function(context)
      local shell = open_terminal("current")
      set_quick_command(shell, "a", "make build")
      local buffer, path = file_buffer(context, "focused.txt")
      local hidden, hidden_path = file_buffer(context, "hidden.txt")
      local editor = panes.place(function() return Editor(buffer) end, { placement = "new", focus = true })
      buffer:insert(1, 1, "edited ")
      hidden:insert(1, 1, "hidden ")
      local captured
      context.on_write = function() captured = { read_file(path), read_file(hidden_path) } end

      test.ok(command.perform(run))

      test.same(captured, { "edited original\n", "hidden original\n" })
      test.not_ok(buffer:is_dirty())
      test.not_ok(hidden:is_dirty())
      test.equal(core.active_view, suffix == "" and shell or editor)
    end)

    test.it("cancels on a disk conflict without selecting the terminal via " .. run, function(context)
      local shell = open_terminal("current")
      set_quick_command(shell, "a", "make build")
      local buffer, path = file_buffer(context, "conflict.txt")
      local editor = panes.place(function() return Editor(buffer) end, { placement = "new", focus = true })
      local pane, group = panes.active(), panes.visible_group()
      buffer:insert(1, 1, "Anvil ")
      write_file(path, "external replacement\n")
      local resolve
      core.nag_view.show = function(_, _, _, _, callback) resolve = callback end

      test.ok(command.perform(run))

      test.same(context.sessions[1].writes, {})
      test.equal(core.active_view, editor)
      test.equal(panes.active(), pane)
      test.equal(panes.visible_group(), group)
      test.equal(read_file(path), "external replacement\n")
      test.ok(buffer:is_dirty())
      test.equal(#context.warnings, 1)
      test.ok(resolve, "the existing disk conflict prompt must remain available")

      resolve { text = "Overwrite Disk" }
      coroutine.yield(0)
      test.equal(read_file(path), "Anvil original\n")
      test.same(context.sessions[1].writes, {}, "resolving the conflict must not run the cancelled command")

      test.ok(command.perform(run))
      test.same(context.sessions[1].writes, { "make build\r" })
    end)

    test.it("cancels on a save error without selecting the terminal via " .. run, function(context)
      local shell = open_terminal("current")
      set_quick_command(shell, "a", "make build")
      local buffer, path = file_buffer(context, "save-error.txt")
      local editor = panes.place(function() return Editor(buffer) end, { placement = "new", focus = true })
      buffer:insert(1, 1, "edited ")
      system.sync_file = function() return false, "test write failure" end

      test.ok(command.perform(run))
      system.sync_file = context.sync_file

      test.same(context.sessions[1].writes, {})
      test.equal(core.active_view, editor)
      test.equal(read_file(path), "original\n")
      test.ok(buffer:is_dirty())
      test.equal(#context.warnings, 1)
    end)

    test.it("cancels on a conflict during terminal startup via " .. run, function(context)
      context.connecting = true
      local shell = open_terminal("current")
      set_quick_command(shell, "a", "make build")
      local buffer, path = file_buffer(context, "startup-conflict.txt")
      local editor = panes.place(function() return Editor(buffer) end, { placement = "new", focus = true })
      local pane, group = panes.active(), panes.visible_group()
      core.nag_view.show = function() end

      test.ok(command.perform(run))
      buffer:insert(1, 1, "Anvil ")
      write_file(path, "external replacement\n")
      context.connecting = false
      shell:service_session(true)
      local deadline = system.get_time() + 10
      while #context.sessions[1].writes == 0 and #context.warnings == 0 and system.get_time() < deadline do
        coroutine.yield(0.01)
      end

      test.same(context.sessions[1].writes, {})
      test.equal(core.active_view, editor)
      test.equal(panes.active(), pane)
      test.equal(panes.visible_group(), group)
      test.equal(read_file(path), "external replacement\n")
      test.equal(#context.warnings, 1)
    end)
  end

  test.it("saves the latest text when an older background save is pending", function(context)
    local shell = open_terminal("current")
    set_quick_command(shell, "a", "make build")
    local buffer, path = file_buffer(context, "pending.txt")
    open_editor("new")
    buffer:insert(1, 1, "earlier ")
    local request = assert(buffer:save_async())
    buffer:insert(1, 1, "latest ")
    local captured
    context.on_write = function() captured = read_file(path) end

    test.ok(command.perform("quick_command:run_a_without_moving_focus"))

    test.equal(captured, "latest earlier original\n")
    test.not_ok(buffer:is_dirty())
    test.equal(request.status, "cancelled")
  end)

  test.it("focuses its terminal in another Pane Group and enters the command", function(context)
    local shell = open_terminal("current")
    set_quick_command(shell, "a", "make build")
    open_editor("new")
    test.ok(panes.visible_group() ~= panes.pane_for_view(shell).group)

    test.ok(command.perform("quick_command:run_a"))

    test.equal(core.active_view, shell)
    test.equal(panes.visible_group(), panes.pane_for_view(shell).group)
    test.same(context.sessions[1].writes, { "make build\r" })
  end)

  test.it("warns and enters nothing while its terminal is busy", function(context)
    local shell = open_terminal("current")
    set_quick_command(shell, "s", "make test")
    open_editor("new")
    context.sessions[1].busy = true
    shell:service_session(true)

    command.perform("quick_command:run_s")

    test.equal(core.active_view, shell)
    test.same(context.sessions[1].writes, {})
    test.equal(#context.warnings, 1)
  end)

  for _, slot in ipairs { "a", "s", "d", "f" } do
    test.it("runs Quick Command " .. slot:upper() .. " without changing focus or Pane Group", function(context)
      local shell = open_terminal("current")
      set_quick_command(shell, slot, "make build")
      local editor = open_editor("new")
      local pane, group = panes.active(), panes.visible_group()
      test.ok(group ~= panes.pane_for_view(shell).group)

      test.ok(command.perform("quick_command:run_" .. slot .. "_without_moving_focus"))

      test.equal(core.active_view, editor)
      test.equal(panes.active(), pane)
      test.equal(panes.visible_group(), group)
      test.same(context.sessions[1].writes, { "make build\r" })
    end)
  end

  test.it("keeps the editor focused when its terminal is visible in another Pane", function(context)
    local shell = open_terminal("current")
    set_quick_command(shell, "a", "make build")
    local editor = open_editor("split")
    local pane = panes.active()
    local group = panes.visible_group()
    test.equal(panes.pane_for_view(shell).group, group)

    test.ok(command.perform("quick_command:run_a_without_moving_focus"))

    test.equal(core.active_view, editor)
    test.equal(panes.active(), pane)
    test.equal(panes.visible_group(), group)
    test.equal(pane.current_view, editor)
    test.same(context.sessions[1].writes, { "make build\r" })
  end)

  test.it("reattaches an unseen Terminal Session without replacing the editor or moving focus", function(context)
    local shell = open_terminal("current")
    set_quick_command(shell, "a", "make build")
    local id = shell.session_id
    local editor = open_editor("new")
    panes.close(panes.pane_for_view(shell), { force = true })
    local pane, group = panes.active(), panes.visible_group()
    context.records[id] = string.format([[return {
      version = 1, session_id = %q, host_pid = 1, host_creation_time = "0000000000000001",
      pipe_name = %q, project_path = %q, cwd = %q, shell = "", status = "running",
    }]], id, "\\\\.\\pipe\\anvil-terminal-" .. id, USERDIR, USERDIR)

    test.ok(command.perform("quick_command:run_a_without_moving_focus"))
    local attached = terminal.open_views()[1]
    test.ok(attached)
    test.equal(attached.session_id, id)
    attached:service_session(true)
    local deadline = system.get_time() + 10
    while #context.sessions[2].writes == 0 and system.get_time() < deadline do coroutine.yield(0.01) end

    test.equal(core.active_view, editor)
    test.equal(panes.active(), pane)
    test.equal(panes.visible_group(), group)
    test.equal(pane.current_view, editor)
    test.same(context.sessions[2].writes, { "make build\r" })
  end)

  test.it("keeps focus and warns when a keep-focus command targets a busy terminal", function(context)
    local shell = open_terminal("current")
    set_quick_command(shell, "s", "make test")
    local editor = open_editor("new")
    local pane, group = panes.active(), panes.visible_group()
    context.sessions[1].busy = true
    shell:service_session(true)

    test.ok(command.perform("quick_command:run_s_without_moving_focus"))

    test.equal(core.active_view, editor)
    test.equal(panes.active(), pane)
    test.equal(panes.visible_group(), group)
    test.same(context.sessions[1].writes, {})
    test.equal(#context.warnings, 1)
  end)

  test.it("warns when the slot has no command", function(context)
    open_terminal("current")
    command.perform("quick_command:run_d")
    test.same(context.sessions[1].writes, {})
    test.equal(#context.warnings, 1)
  end)

  test.it("does not start a new terminal after its terminal closed", function(context)
    local shell = open_terminal("current")
    set_quick_command(shell, "f", "make run")
    local editor = open_editor("new")
    panes.close(panes.pane_for_view(shell), { force = true })

    command.perform("quick_command:run_f")

    test.equal(#context.sessions, 1)
    test.equal(#terminal.open_views(), 0)
    test.equal(core.active_view, editor)
    test.equal(#context.warnings, 1)
  end)

  test.it("navigates file locations from the latest run as remote Points of Interest", function(context)
    local old_path = USERDIR .. PATHSEP .. "quick-command-old.txt"
    local new_path = USERDIR .. PATHSEP .. "quick-command-new.txt"
    context.files = { old_path, new_path }
    for _, path in ipairs(context.files) do
      local file = assert(io.open(path, "wb"))
      file:write("one\ntwo\nthree\n")
      file:close()
    end
    local shell = open_terminal("current")
    set_quick_command(shell, "a", "make build")
    local editor = open_editor("new")
    test.ok(command.perform("quick_command:run_a_without_moving_focus"))
    test.equal(core.active_view, editor)
    context.sessions[1].capture = table.concat({
      "PS> make build",
      "quick-command-old.txt:1: error: old",
      "PS> make build",
      "quick-command-new.txt:3: error: new",
      "PS> ",
    }, "\n")
    test.ok(command.perform("core:next_remote_point_of_interest"))
    test.equal(core.active_view, editor, "navigation must let the UI run while output is checked")
    local deadline = system.get_time() + 30
    while core.active_view == editor and system.get_time() < deadline do coroutine.yield(0.01) end

    test.equal(common.normalize_path(core.active_view.buffer.abs_filename), common.normalize_path(new_path))
    test.equal(core.active_view.buffer:get_selection(), 3)
    command.perform("core:next_remote_point_of_interest")
    test.equal(common.normalize_path(core.active_view.buffer.abs_filename), common.normalize_path(new_path))
  end)

  test.it("does not take focus after the user leaves a pending output navigation", function(context)
    local _, path = file_buffer(context, "pending-result.txt")
    local shell = open_terminal("current")
    set_quick_command(shell, "a", "build")
    open_editor("new")
    test.ok(command.perform("quick_command:run_a_without_moving_focus"))
    context.sessions[1].capture = "PS> build\n" .. path .. ":1:1\n"
    test.ok(command.perform("core:next_remote_point_of_interest"))
    local other = open_editor("new")
    local source = require("core.poi").get_remote_source()
    local deadline = system.get_time() + 30
    while #source:get_points_of_interest() == 0 and system.get_time() < deadline do coroutine.yield(0.01) end
    test.equal(#source:get_points_of_interest(), 1)
    test.equal(core.active_view, other)
  end)

  test.it("keeps the output position when only earlier terminal history changes", function(context)
    local buffer, path = file_buffer(context, "stable-output.txt")
    buffer:insert(1, 1, "one\ntwo\nthree\n")
    buffer:save()
    local shell = open_terminal("current")
    set_quick_command(shell, "a", "build")
    local editor = open_editor("new")
    test.ok(command.perform("quick_command:run_a_without_moving_focus"))
    local output = "PS> build\n" .. path .. ":1:1\n" .. path .. ":3:1\n"
    context.sessions[1].capture = output
    test.ok(command.perform("core:next_remote_point_of_interest"))
    local deadline = system.get_time() + 30
    while core.active_view == editor and system.get_time() < deadline do coroutine.yield(0.01) end
    test.equal(common.normalize_path(core.active_view.buffer.abs_filename), common.normalize_path(path))
    buffer = core.active_view.buffer
    test.equal(buffer:get_selection(), 1)
    context.sessions[1].capture = "older output\n" .. output
    test.ok(command.perform("core:next_remote_point_of_interest"))
    deadline = system.get_time() + 30
    while buffer:get_selection() ~= 3 and system.get_time() < deadline do coroutine.yield(0.01) end
    test.equal(buffer:get_selection(), 3)
  end)

  test.it("discards a pending navigation when a new Quick Command replaces its output", function(context)
    local _, old_path = file_buffer(context, "replaced-result.txt")
    local _, new_path = file_buffer(context, "current-result.txt")
    local shell = open_terminal("current")
    set_quick_command(shell, "a", "first-build")
    local editor = open_editor("new")
    test.ok(command.perform("quick_command:run_a_without_moving_focus"))
    context.sessions[1].capture = "PS> first-build\n" .. old_path .. ":1:1\n"
    test.ok(command.perform("core:next_remote_point_of_interest"))
    set_quick_command(shell, "a", "second-build")
    core.set_active_view(editor)
    test.ok(command.perform("quick_command:run_a_without_moving_focus"))
    context.sessions[1].capture = "PS> second-build\n" .. new_path .. ":1:1\n"
    test.ok(command.perform("core:next_remote_point_of_interest"))
    local deadline = system.get_time() + 30
    while core.active_view == editor and system.get_time() < deadline do coroutine.yield(0.01) end
    test.equal(common.normalize_path(core.active_view.buffer.abs_filename), common.normalize_path(new_path))
  end)
end)
