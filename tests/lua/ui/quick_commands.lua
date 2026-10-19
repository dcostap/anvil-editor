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

local next_session = 0

local function fake_native(context)
  local native = {}
  function native.read_session_record() return nil, 2 end
  function native.new()
    next_session = next_session + 1
    local session = {
      id = string.format("%032x", next_session),
      writes = {},
      busy = false,
      capture = "",
    }
    function session:update()
      return false, { kind = "running", revision = 1, attach_count = 1, busy = self.busy }
    end
    function session:snapshot(previous)
      return previous or {
        rows = {}, cols = 80, row_count = 24, foreground = 0xffffff, background = 0,
        cursor = { visible = true, x = 0, y = 0, style = "block" }, events = {},
      }
    end
    function session:write(text) self.writes[#self.writes + 1] = text; return true end
    function session:text_capture()
      return { text = self.capture, cursor_line = 1, cursor_col = 1, viewport_line = 1 }
    end
    function session:stats()
      return { session_id = self.id, attach_count = 1, host_pid = 1, shell_pid = 1, replay_bytes = 0 }
    end
    setmetatable(session, { __index = function() return function() return true end end })
    context.sessions[#context.sessions + 1] = session
    return session
  end
  return native
end

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

test.describe("Quick Commands", function()
  test.before_each(function(context)
    panes.reset_for_tests()
    storage.clear("quick-commands")
    context.sessions = {}
    terminal._set_native_for_tests(fake_native(context))
    context.warn = core.warn
    context.warnings = {}
    core.warn = function(format, ...) context.warnings[#context.warnings + 1] = string.format(format, ...) end
  end)

  test.after_each(function(context)
    core.warn = context.warn
    core.global_prompt_bar:exit()
    for _, view in ipairs(terminal.open_views()) do
      local pane = panes.pane_for_view(view)
      if pane then panes.close(pane, { force = true }) else view:on_close() end
    end
    panes.reset_for_tests()
    terminal._set_native_for_tests(nil)
    storage.clear("quick-commands")
    for _, path in ipairs(context.files or {}) do os.remove(path) end
  end)

  test.it("focuses its terminal in another Pane Group and enters the command", function(context)
    local shell = open_terminal("current")
    set_quick_command(shell, "a", "make build")
    local editor = open_editor("new")
    test.ok(panes.visible_group() ~= panes.pane_for_view(shell).group)

    test.ok(command.perform("quick_command:run_a"))

    test.equal(core.active_view, shell)
    test.equal(panes.visible_group(), panes.pane_for_view(shell).group)
    test.same(context.sessions[1].writes, { "make build\r" })
    test.ok(editor)
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
    test.ok(command.perform("quick_command:run_a"))
    context.sessions[1].capture = table.concat({
      "PS> make build",
      "quick-command-old.txt:1: error: old",
      "PS> make build",
      "quick-command-new.txt:3: error: new",
      "PS> ",
    }, "\n")
    core.set_active_view(editor)

    test.ok(command.perform("core:next_remote_point_of_interest"))

    test.equal(common.normalize_path(core.active_view.buffer.abs_filename), common.normalize_path(new_path))
    test.equal(core.active_view.buffer:get_selection(), 3)
    command.perform("core:next_remote_point_of_interest")
    test.equal(common.normalize_path(core.active_view.buffer.abs_filename), common.normalize_path(new_path))
  end)
end)
