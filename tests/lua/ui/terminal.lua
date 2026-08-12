local command = require "core.command"
local core = require "core"
local panes = require "core.panes"
local test = require "core.test"

local terminal = require "plugins.terminal"

local function fake_native()
  local sessions = {}
  local native = {}

  function native.new(options)
    local session = {
      options = options,
      writes = {},
      keys = {},
      pastes = {},
      selections = {},
      mouse_events = {},
      focus_events = {},
      resizes = {},
      closed = false,
    }
    function session:update() return false, true end
    function session:snapshot()
      return {
        rows = {},
        cols = 80,
        row_count = 24,
        foreground = 0xffffff,
        background = 0x000000,
        cursor = { visible = true, x = 0, y = 0, style = "block" },
      }
    end
    function session:write(text) self.writes[#self.writes + 1] = text; return true end
    function session:key(key, mods, action, event)
      self.keys[#self.keys + 1] = { key, mods, action, event }
      return true
    end
    function session:paste(text, allow_unsafe)
      self.pastes[#self.pastes + 1] = { text, allow_unsafe }
      return true
    end
    function session:select(...)
      self.selections[#self.selections + 1] = { ... }
      return true
    end
    function session:clear_selection() self.selection_cleared = true; return true end
    function session:selected_text() return self.selection_text end
    function session:mouse(...)
      self.mouse_events[#self.mouse_events + 1] = { ... }
      return true, true
    end
    function session:focus(focused)
      self.focus_events[#self.focus_events + 1] = focused
      return true
    end
    function session:resize(cols, rows, cell_width, cell_height)
      self.resizes[#self.resizes + 1] = { cols, rows, cell_width, cell_height }
      return true
    end
    function session:scroll() return true end
    function session:close() self.closed = true end
    sessions[#sessions + 1] = session
    return session
  end

  return native, sessions
end

test.describe("Terminal View", function()
  test.before_each(function(context)
    context.previous_active_view = core.active_view
    context.native, context.sessions = fake_native()
    terminal._set_native_for_tests(context.native)
  end)

  test.after_each(function(context)
    for _, view in ipairs(terminal.open_views()) do
      view:try_close(function()
        panes.remove_view(view, { force = true, focus_left = false })
      end)
    end
    terminal._set_native_for_tests(nil)
    if context.previous_active_view then core.set_active_view(context.previous_active_view) end
  end)

  test.it("opens and focuses a Terminal View in the Right Pane", function(context)
    test.ok(command.perform("terminal:open"))

    local view = core.active_view
    test.ok(view and view.terminal_view)
    test.equal(panes.pane_for_view(view), "right")
    test.equal(#context.sessions, 1)
  end)

  test.it("sends text and unhandled keys to the focused terminal", function(context)
    test.ok(command.perform("terminal:open"))
    local session = context.sessions[1]

    core.on_event("textinput", "echo hello")
    local raw = { scancode = 104, keycode = 0, modifiers = 0, ["repeat"] = true }
    core.on_event("keypressed", "f13", raw)
    core.on_event("keyreleased", "f13", raw)

    test.same({ "echo hello" }, session.writes)
    test.equal(session.keys[1][1], "f13")
    test.equal(session.keys[1][3], "repeat")
    test.equal(session.keys[1][4], raw)
    test.equal(session.keys[2][3], "release")
  end)

  test.it("resizes the terminal from its visible cell geometry", function(context)
    local view = terminal.open()
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 800, 400

    view:update()

    local resize = context.sessions[1].resizes[#context.sessions[1].resizes]
    test.ok(resize[1] > 0)
    test.ok(resize[2] > 0)
    test.ok(resize[3] > 0)
    test.ok(resize[4] > 0)
  end)

  test.it("pastes clipboard text through the terminal encoder", function(context)
    local previous = system.get_clipboard()
    system.set_clipboard("terminal paste")
    local view = terminal.open()

    test.ok(command.perform("terminal:paste"))
    test.same({ "terminal paste", false }, context.sessions[1].pastes[1])

    system.set_clipboard(previous or "")
  end)

  test.it("selects visible cells and copies the selected terminal text", function(context)
    local previous = system.get_clipboard()
    local view = terminal.open()
    view.position.x, view.position.y = 10, 20
    local session = context.sessions[1]
    session.selection_text = "selected output"

    view:on_mouse_pressed("left", 10 + 6 + view.cell_width, 20 + 6 + view.cell_height)
    view:on_mouse_moved(10 + 6 + view.cell_width * 3, 20 + 6 + view.cell_height * 2)
    view:on_mouse_released("left", 0, 0)
    test.same({ 1, 1, 3, 2, false }, session.selections[#session.selections])
    test.ok(command.perform("terminal:copy"))
    test.equal(system.get_clipboard(), "selected output")

    system.set_clipboard(previous or "")
  end)

  test.it("reports mouse input when the terminal enables mouse tracking", function(context)
    local view = terminal.open()
    view.position.x, view.position.y = 0, 0
    view.snapshot.mouse_tracking = true
    local session = context.sessions[1]

    view:on_mouse_pressed("left", 20, 30)
    view:on_mouse_moved(24, 34)
    view:on_mouse_released("left", 24, 34)

    test.equal(session.mouse_events[1][1], "press")
    test.equal(session.mouse_events[2][1], "motion")
    test.equal(session.mouse_events[3][1], "release")
    test.ok(session.selection_cleared)
  end)

  test.it("reports Terminal View focus changes", function(context)
    local view = terminal.open()
    local session = context.sessions[1]
    view:update()
    core.set_active_view(context.previous_active_view)
    view:update()

    test.same({ true, false }, session.focus_events)
  end)
end)
