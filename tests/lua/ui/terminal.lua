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
    function session:key(key, mods) self.keys[#self.keys + 1] = { key, mods }; return true end
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
    core.on_event("keypressed", "f13")

    test.same({ "echo hello" }, session.writes)
    test.equal(session.keys[1][1], "f13")
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
end)
