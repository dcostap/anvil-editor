local core = require "core"
local ime = require "core.ime"
local RootPanel = require "core.rootpanel"
local test = require "core.test"

test.describe("Keyboard input diagnostics", function()
  local saved, lines

  test.before_each(function()
    saved = {
      root = core.root_panel,
      logger = core.session_log,
      editing = ime.editing,
    }
    core.root_panel = RootPanel()
    lines = {}
    core.session_log = {
      write = function(_, _, text)
        lines[#lines + 1] = text
        return true
      end,
    }
    ime.editing = false
  end)

  test.after_each(function()
    core.root_panel = saved.root
    core.session_log = saved.logger
    ime.editing = saved.editing
  end)

  local function contains(text)
    for _, line in ipairs(lines) do
      if line:find(text, 1, true) then return true end
    end
    return false
  end

  test.it("records a received key and its modal route", function()
    core.root_panel:push_modal_input({}, {
      label = "trace-test",
      handlers = { key_pressed = function() return true end },
    })
    core.on_event("keypressed", "f24", {
      scancode = 115, keycode = 1073741939, modifiers = 0, ["repeat"] = true,
    })
    test.ok(contains("Input trace: lua received event=keypressed key=f24"))
    test.ok(contains("scancode=115 keycode=1073741939 modifiers=0 repeat=true"))
    test.ok(contains("Input trace: lua route event=keypressed key=f24 route=modal-consumed"))
    test.ok(contains("owner=trace-test"))
  end)

  test.it("records keys rejected during IME composition", function()
    ime.editing = true
    core.on_event("keypressed", "f24", {})
    test.ok(contains("Input trace: lua received event=keypressed key=f24"))
    test.ok(contains("route=ime-composition"))
  end)

  test.it("records key releases without running a key command", function()
    core.root_panel:push_modal_input({}, { label = "trace-test" })
    core.on_event("keyreleased", "f24", { scancode = 115 })
    test.ok(contains("Input trace: lua received event=keyreleased key=f24"))
    test.ok(contains("Input trace: lua route event=keyreleased key=f24 route=modal-release"))
  end)
end)
