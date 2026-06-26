local core = require "core"
local keymap = require "core.keymap"
local test = require "core.test"
local tool_window = require "core.tool_window"

test.describe("Project Tool Window", function()
  test.before_each(function()
    tool_window.reset_for_tests()
  end)

  test.after_each(function()
    tool_window.reset_for_tests()
  end)

  local function fake_root()
    return {
      size = { x = 0, y = 0 },
      events = {},
      updates = 0,
      draws = 0,
      on_mouse_pressed = function(self, ...)
        self.events[#self.events + 1] = { "mousepressed", ... }
        return true
      end,
      on_text_input = function(self, ...)
        self.events[#self.events + 1] = { "textinput", ... }
        return true
      end,
      update = function(self) self.updates = self.updates + 1 end,
      draw = function(self) self.draws = self.draws + 1 end,
    }
  end

  local function fake_window(id)
    return {
      id = id,
      raised = 0,
      get_size = function() return 320, 200 end,
    }
  end

  test.test("open reuses one window per project and kind", function()
    local project = { path = "C:/repo" }
    local created = 0
    local first, first_created = tool_window.open(project, "git", {
      window_id = 101,
      create_window = function()
        created = created + 1
        return fake_window(101)
      end,
      create_root = fake_root,
    })
    local second, second_created = tool_window.open(project, "git", {
      window_id = 202,
      create_window = function()
        created = created + 1
        return fake_window(202)
      end,
      create_root = fake_root,
    })

    test.equal(first, second)
    test.equal(first_created, true)
    test.equal(second_created, false)
    test.equal(created, 1)
    test.equal(tool_window.get(project, "git"), first)
  end)

  test.test("routes events by window id and ignores hidden windows", function()
    local root = fake_root()
    local tw = tool_window.open({ path = "C:/repo" }, "git", {
      window = fake_window(303),
      window_id = 303,
      root = root,
    })

    test.equal(tool_window.handle_event(303, "mousepressed", "left", 10, 20, 1), true)
    test.equal(#root.events, 1)
    test.equal(root.events[1][1], "mousepressed")
    test.equal(root.events[1][3], 10)

    tw:hide()
    test.equal(tool_window.handle_event(303, "textinput", "x"), true)
    test.equal(#root.events, 1)
  end)

  test.test("routes key events through keymap", function()
    local old_key_pressed = keymap.on_key_pressed
    local seen_key
    keymap.on_key_pressed = function(key)
      seen_key = key
      return true
    end

    tool_window.open({ path = "C:/repo" }, "git", {
      window = fake_window(505),
      window_id = 505,
      root = fake_root(),
    })
    test.equal(tool_window.handle_event(505, "keypressed", "escape"), true)
    test.equal(seen_key, "escape")
    test.equal(tool_window.last_did_keymap, true)

    keymap.on_key_pressed = old_key_pressed
  end)

  test.test("window close events hide the tool window", function()
    local tw = tool_window.open({ path = "C:/repo" }, "git", {
      window = fake_window(606),
      window_id = 606,
      root = fake_root(),
    })
    test.equal(tw.hidden, false)
    test.equal(tool_window.handle_event(606, "windowclose"), true)
    test.equal(tw.hidden, true)
  end)

  test.test("hiding a focused tool window restores main input ownership", function()
    local old_active_view = core.active_view
    local old_active_window = core.active_window
    local old_text_input = system.text_input
    system.text_input = function() return true end
    local hidden_view = { supports_text_input = function() return true end, extends = function() return false end }
    local fallback_view = { supports_text_input = function() return false end, extends = function() return false end }
    core.last_active_view = fallback_view

    local tw = tool_window.open({ path = "C:/repo" }, "git", {
      window = fake_window(707),
      window_id = 707,
      root = fake_root(),
    })
    tw.root.root_node = { get_node_for_view = function(_, view) return view == hidden_view and {} or nil end }
    core.active_view = hidden_view
    core.active_window = tw.window

    tw:hide()
    test.equal(tw.hidden, true)
    test.equal(core.active_window, core.window)
    test.equal(core.last_active_view, fallback_view)

    core.active_view = old_active_view
    core.active_window = old_active_window
    system.text_input = old_text_input
  end)

  test.test("activates tool root before direct text input", function()
    local old_active_view = core.active_view
    local old_active_window = core.active_window
    local old_text_input = system.text_input
    system.text_input = function() return true end

    local tool_view = { supports_text_input = function() return true end, extends = function() return false end }
    local root = fake_root()
    root.root_node = { type = "leaf", active_view = tool_view, views = { tool_view } }
    local tw = tool_window.open({ path = "C:/repo" }, "git", {
      window = fake_window(808),
      window_id = 808,
      root = root,
    })
    core.active_view = old_active_view
    core.active_window = core.window

    test.equal(tool_window.handle_event(808, "textinput", "x"), true)
    test.equal(core.active_view, tool_view)
    test.equal(core.active_window, tw.window)

    core.active_view = old_active_view
    core.active_window = old_active_window
    system.text_input = old_text_input
  end)

  test.test("show updates active input window even when view is already active", function()
    local old_active_view = core.active_view
    local old_active_window = core.active_window
    local old_text_input = system.text_input
    local calls = {}
    system.text_input = function(window, enabled)
      calls[#calls + 1] = { window = window, enabled = enabled }
      return true
    end

    local active_view = { supports_text_input = function() return true end, extends = function() return false end }
    core.active_view = active_view
    core.active_window = core.window
    local root = fake_root()
    root.root_node = { type = "leaf", active_view = active_view, views = { active_view } }
    local tw = tool_window.open({ path = "C:/repo" }, "git", {
      window = fake_window(909),
      window_id = 909,
      root = root,
    })

    test.equal(core.active_view, active_view)
    test.equal(core.active_window, tw.window)
    test.equal(calls[#calls].window, tw.window)
    test.equal(calls[#calls].enabled, true)

    core.active_view = old_active_view
    core.active_window = old_active_window
    system.text_input = old_text_input
  end)

  test.test("serializes lightweight state", function()
    local tw = tool_window.open({ path = "C:/repo" }, "git", {
      window = fake_window(404),
      window_id = 404,
      root = fake_root(),
      state = { selected_tab = "log" },
    })
    tw:hide()

    local state = tw:get_state()
    test.equal(state.project_key, "C:/repo")
    test.equal(state.kind, "git")
    test.equal(state.hidden, true)
    test.equal(state.state.selected_tab, "log")
  end)
end)
