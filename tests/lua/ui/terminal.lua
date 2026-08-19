local command = require "core.command"
local core = require "core"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local keymap = require "core.keymap"
local panes = require "core.panes"
local style = require "core.style"
local test = require "core.test"
local View = require "core.view"

local terminal = require "plugins.terminal"

local function packed_color(color)
  return color[1] * 0x10000 + color[2] * 0x100 + color[3]
end

local function draw_calls(fn)
  local previous_text = renderer.draw_text
  local previous_known = renderer.draw_text_known_bounds
  local previous_rect = renderer.draw_rect
  local previous_rounded_rect = renderer.draw_rounded_rect
  local calls = { text = {}, rect = {} }
  renderer.draw_text = function(...) calls.text[#calls.text + 1] = { ... } end
  renderer.draw_text_known_bounds = function(...) calls.text[#calls.text + 1] = { ... } end
  renderer.draw_rect = function(...) calls.rect[#calls.rect + 1] = { ... } end
  renderer.draw_rounded_rect = function(...) calls.rect[#calls.rect + 1] = { ... } end
  local ok, err = pcall(fn, calls)
  renderer.draw_text = previous_text
  renderer.draw_text_known_bounds = previous_known
  renderer.draw_rect = previous_rect
  renderer.draw_rounded_rect = previous_rounded_rect
  if not ok then error(err) end
  return calls
end

local function fake_native()
  local sessions = {}
  local native = {}

  function native.new(options)
    if native.next_error then
      local error = native.next_error
      native.next_error = nil
      return nil, error
    end
    local session = {
      options = options,
      writes = {},
      keys = {},
      pastes = {},
      selections = {},
      mouse_events = {},
      focus_events = {},
      resizes = {},
      scrolls = {},
      gesture_events = {},
      searches = {},
      closed = false,
    }
    function session:update()
      self.update_calls = (self.update_calls or 0) + 1
      local changed = self.next_changed or false
      self.next_changed = false
      local running = self.next_running
      self.next_running = nil
      local status = self.next_status
      self.next_status = nil
      return changed, running == nil and not self.closed or running, status
    end
    function session:snapshot()
      return {
        rows = {},
        cols = 80,
        row_count = 24,
        foreground = 0xffffff,
        background = 0x000000,
        cursor = { visible = true, x = 0, y = 0, style = "block" },
        events = {},
      }
    end
    function session:write(text) self.writes[#self.writes + 1] = text; return true end
    function session:clear() self.cleared = true; return true end
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
    function session:reset_selection_gesture() self.gesture_reset = true; return true end
    function session:selected_text() return self.selection_text end
    function session:mouse(...)
      self.mouse_events[#self.mouse_events + 1] = { ... }
      return true, true
    end
    function session:focus(focused)
      self.focus_events[#self.focus_events + 1] = focused
      return true
    end
    function session:set_colors(colors)
      self.colors = colors
      return true
    end
    function session:resize(cols, rows, cell_width, cell_height)
      self.resizes[#self.resizes + 1] = { cols, rows, cell_width, cell_height }
      return true
    end
    function session:scroll(kind, value)
      self.scrolls[#self.scrolls + 1] = { kind, value }
      return true
    end
    function session:selection_gesture(kind, col, row, pixel_x, pixel_y, clicks, rectangle)
      self.gesture_events[#self.gesture_events + 1] = {
        kind, col, row, pixel_x, pixel_y, clicks, rectangle,
      }
      return true, kind == "drag" and "down" or "none"
    end
    function session:search(query, reverse)
      self.searches[#self.searches + 1] = { query, reverse }
      return query == "needle"
    end
    function session:hyperlink() return self.hyperlink_uri end
    function session:open_hyperlink() return self.hyperlink_uri ~= nil end
    function session:close() self.closed = true end
    sessions[#sessions + 1] = session
    return session
  end

  return native, sessions
end

test.describe("Terminal View", function()
  test.before_each(function(context)
    panes.reset_for_tests()
    context.previous_active_view = core.active_view
    context.native, context.sessions = fake_native()
    terminal._set_native_for_tests(context.native)
  end)

  test.after_each(function(context)
    for _, view in ipairs(terminal.open_views()) do
      local pane = panes.pane_for_view(view)
      if pane then panes.close(pane, { force = true }) else view:on_close() end
    end
    panes.reset_for_tests()
    terminal._set_native_for_tests(nil)
    if context.previous_active_view then core.set_active_view(context.previous_active_view) end
  end)

  test.it("opens and focuses a Terminal View in Pane 1", function(context)
    test.ok(command.perform("terminal:open"))

    local view = core.active_view
    test.ok(view and view.terminal_view)
    test.equal(panes.pane_for_view(view), panes.active())
    test.equal(panes.number(panes.active()), 1)
    test.equal(#context.sessions, 1)
  end)

  test.it("suspends an Editor and restores the exact terminal session", function(context)
    local pane = panes.create { factory = function() return Editor(Buffer(nil, nil, true)) end }
    pane.current_view.buffer:set_filename("saved.lua", "C:/saved.lua")
    local editor = pane.current_view
    local view = terminal.open { pane = pane }
    local session = view.session
    test.equal(pane.current_view, view)
    test.equal(panes.back(pane), editor)
    test.not_ok(session.closed)
    test.equal(panes.forward(pane), view)
    test.equal(view.session, session)
  end)

  test.it("services a terminal while its Pane Group is hidden", function(context)
    local view = terminal.open()
    local session = view.session
    panes.create { factory = function() return View() end }
    local before = session.update_calls or 0
    core.root_panel:update()
    test.ok((session.update_calls or 0) > before)
    test.not_ok(session.closed)
  end)

  test.it("allows Pane history to discard an exited Terminal", function(context)
    local view = terminal.open()
    local session = view.session
    session.next_running = false
    session.next_status = { exit_code = 0 }
    view:update_suspended()

    test.not_ok(view.running)
    test.ok(view:can_discard_from_history())
    test.equal(view.exit_code, 0)
  end)

  test.it("closes all retained terminal sessions only when Pane close commits", function(context)
    local first = terminal.open()
    local pane = panes.active()
    local second = terminal.open { pane = pane }
    local first_session, second_session = first.session, second.session
    test.not_ok(first_session.closed)
    test.not_ok(second_session.closed)
    test.ok(panes.close(pane, { force = true }))
    test.ok(first_session.closed)
    test.ok(second_session.closed)
  end)

  test.it("restores Workspace launch state as a new shell session", function(context)
    local view = terminal.open { cwd = "C:/workspace", shell = "pwsh.exe" }
    local first_session = view.session
    local state = view:get_state()
    panes.close(panes.active(), { force = true })
    local restored = terminal.from_state(state)
    test.not_nil(restored)
    test.not_equal(restored.session, first_session)
    test.equal(restored.launch_options.cwd, "C:/workspace")
    test.equal(restored.launch_options.shell, "pwsh.exe")
    restored:on_close()
  end)

  test.it("uses the exact font advance for terminal cells", function()
    local view = terminal.open()
    local advance = style.terminal_font:get_width("M")
    test.equal(view.cell_width, advance)
    test.equal(view.native_cell_width, math.max(1, math.ceil(advance)))
  end)

  test.it("starts sessions with the active terminal theme", function(context)
    test.ok(type(style.terminal_foreground) == "table")
    test.ok(type(style.terminal_background) == "table")
    test.ok(type(style.terminal_cursor) == "table")
    test.equal(#style.terminal_palette, 16)

    terminal.open()
    local options = context.sessions[1].options
    test.equal(options.foreground, packed_color(style.terminal_foreground))
    test.equal(options.background, packed_color(style.terminal_background))
    test.equal(options.cursor_color, packed_color(style.terminal_cursor))
    for index, color in ipairs(style.terminal_palette) do
      test.equal(options.palette[index], packed_color(color))
    end
  end)

  test.it("updates a running session after a theme change", function(context)
    local view = terminal.open()
    local generation = core.color_theme_generation or 0
    core.color_theme_generation = generation + 1
    view:update()
    core.color_theme_generation = generation

    local colors = context.sessions[1].colors
    test.equal(colors.foreground, packed_color(style.terminal_foreground))
    test.equal(colors.background, packed_color(style.terminal_background))
    test.equal(colors.cursor_color, packed_color(style.terminal_cursor))
    test.equal(#colors.palette, 16)
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

  test.it("does not send shifted layout text twice after encoding its key", function(context)
    local view = terminal.open()
    local event = {
      shift = true,
      modifiers = 1,
      scancode = 36,
      text = "/",
      unshifted_codepoint = string.byte("7"),
      consumed_modifiers = 1,
    }
    test.ok(view:on_key_pressed("/", event))
    test.ok(view:on_text_input("/"))
    test.equal(#context.sessions[1].writes, 0)
  end)

  test.it("owns shell control keys before global editor shortcuts", function(context)
    local view = terminal.open()
    local event = { ctrl = true, modifiers = 0, scancode = 19 }
    test.ok(core.on_event("keypressed", "p", event))
    test.equal(context.sessions[1].keys[#context.sessions[1].keys][1], "p")
    local key_count = #context.sessions[1].keys
    core.on_event("keypressed", "q", {
      ctrl = true, alt = true, altgr = true, modifiers = 0, scancode = 20,
    })
    test.equal(#context.sessions[1].keys, key_count)
    core.on_event("keypressed", "left", {
      ctrl = true, alt = true, altgr = true, modifiers = 0, scancode = 80,
    })
    test.equal(#context.sessions[1].keys, key_count + 1)
    test.equal(view:on_key_pressed_before_keymap("f", {
      ctrl = true, shift = true, modifiers = 0,
    }), false)
  end)

  test.it("sends Shift Home and End to terminal applications", function(context)
    local view = terminal.open()
    local session = context.sessions[1]
    keymap.modkeys.shift = true
    test.ok(view:on_key_pressed("home", { shift = true, modifiers = 1 }))
    test.ok(view:on_key_pressed("end", { shift = true, modifiers = 1 }))
    keymap.modkeys.shift = false

    test.equal(session.keys[#session.keys - 1][1], "home")
    test.equal(session.keys[#session.keys][1], "end")
    test.equal(#session.scrolls, 2)

    test.ok(view:on_key_pressed_before_keymap("home", {
      ctrl = true, shift = true, modifiers = 3,
    }))
    test.ok(view:on_key_pressed_before_keymap("end", {
      ctrl = true, shift = true, modifiers = 3,
    }))
    test.equal(session.scrolls[#session.scrolls - 1][1], "top")
    test.equal(session.scrolls[#session.scrolls][1], "bottom")
  end)

  test.it("draws IME composition without sending partial text", function(context)
    local view = terminal.open()
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 800, 400
    view:on_ime_text_editing("日本", 3, 3)
    local calls = draw_calls(function() view:draw() end)
    test.equal(calls.text[#calls.text][2], "日本")
    test.equal(#context.sessions[1].writes, 0)
    view:on_text_input("日本")
    test.same({ "日本" }, context.sessions[1].writes)
    test.equal(view.composition, nil)
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

  test.it("clears the terminal through its native state", function(context)
    terminal.open()
    test.ok(command.perform("terminal:clear"))
    test.ok(context.sessions[1].cleared)
  end)

  test.it("restarts an exited terminal with the same launch options", function(context)
    local view = terminal.open({ cwd = "C:/terminal-test", shell = "cmd.exe" })
    context.sessions[1].update = function() return false, false, { exit_code = 7 } end
    view:update()

    test.equal(view:get_name(), "Terminal (exit 7)")
    test.ok(command.perform("terminal:restart"))
    test.equal(#context.sessions, 2)
    test.equal(context.sessions[2].options.cwd, "C:/terminal-test")
    test.equal(context.sessions[2].options.shell, "cmd.exe")
    test.ok(context.sessions[1].closed)
    test.ok(view.running)
    test.same({ true }, context.sessions[2].focus_events)
  end)

  test.it("keeps the exited session when restart fails", function(context)
    local view = terminal.open()
    local previous = context.sessions[1]
    previous.update = function() return false, false, { exit_code = 2 } end
    view:update()
    context.native.next_error = "missing shell"
    local previous_error = core.error
    core.error = function() end
    local restarted = view:restart()
    core.error = previous_error
    test.equal(restarted, false)
    test.ok(view.session == previous)
    test.equal(view:get_name(), "Terminal (exit 2)")
    test.equal(previous.closed, false)
  end)

  test.it("shows terminal transport failures once", function(context)
    local view = terminal.open()
    context.sessions[1].update = function()
      return false, true, { error = "ConPTY input failed" }
    end
    local previous_error = core.error
    local errors = {}
    core.error = function(message) errors[#errors + 1] = message end
    view:update()
    view:update()
    core.error = previous_error
    test.same({ "ConPTY input failed" }, errors)
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
    test.equal(session.gesture_events[1][1], "press")
    test.equal(session.gesture_events[2][1], "drag")
    test.equal(session.gesture_events[2][2], 3)
    test.equal(session.gesture_events[2][3], 2)
    test.ok(command.perform("terminal:copy"))
    test.equal(system.get_clipboard(), "selected output")

    system.set_clipboard(previous or "")
  end)

  test.it("uses word and line selection gestures for repeated clicks", function(context)
    local view = terminal.open()
    view.position.x, view.position.y = 0, 0
    local session = context.sessions[1]
    view:on_mouse_pressed("left", 20, 30, 2)
    view:on_mouse_released("left", 20, 30)
    view:on_mouse_pressed("left", 20, 30, 3)
    view:on_mouse_released("left", 20, 30)
    test.equal(session.gesture_events[1][6], 2)
    test.equal(session.gesture_events[3][6], 3)
  end)

  test.it("maps terminal scrollback state to its scrollbar", function(context)
    local view = terminal.open()
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 800, 400
    view.snapshot.scrollbar = { total = 100, offset = 40, len = 20 }
    view:update_scrollbar()
    test.equal(view:get_scrollable_size(), 100 * view.cell_height)
    test.equal(view.v_scrollbar.percent, 0.5)
    view:scroll_to_percent(0.25)
    test.same({ "row", 20 }, context.sessions[1].scrolls[#context.sessions[1].scrolls])
  end)

  test.it("searches terminal scrollback through commands", function(context)
    local view = terminal.open()
    view.search_query = "needle"
    test.ok(command.perform("terminal:search_next"))
    test.ok(command.perform("terminal:search_previous"))
    test.same({ "needle", false }, context.sessions[1].searches[1])
    test.same({ "needle", true }, context.sessions[1].searches[2])
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

  test.it("draws native terminal text runs with their exact columns", function()
    local view = terminal.open()
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 800, 400
    view.snapshot = {
      background = 0,
      foreground = 0xffffff,
      rows = {
        {
          text_runs = {
            { text = "ab", col = 0, columns = 2, fg = 0xffffff },
            { text = "c界", col = 2, columns = 3, fg = 0xff0000 },
            { text = "d", col = 6, columns = 1, fg = 0x00ff00 },
          },
          backgrounds = {
            { col = 1, columns = 2, color = 0x112233 },
            { col = 4, columns = 1, selected = true },
          },
        },
      },
      cursor = { visible = false },
    }

    local calls = draw_calls(function() view:draw() end)

    test.equal(#calls.text, 3)
    test.equal(calls.text[1][2], "ab")
    test.equal(calls.text[2][2], "c界")
    test.equal(calls.text[3][2], "d")
    test.equal(calls.text[2][3], 6 + 2 * view.cell_width)
    test.equal(calls.text[2][7], math.ceil(3 * view.cell_width))
    test.equal(calls.text[3][3], 6 + 6 * view.cell_width)
    local color_span = calls.rect[2]
    local selection_span = calls.rect[3]
    test.equal(color_span[1], 6 + view.cell_width)
    test.equal(color_span[3], 2 * view.cell_width)
    test.equal(selection_span[1], 6 + 4 * view.cell_width)
  end)

  test.it("draws hollow cursors and extended text decorations", function()
    local view = terminal.open()
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 800, 400
    view.snapshot = {
      background = 0, foreground = 0xffffff,
      rows = {{
        text_runs = {{
          text = "x", col = 0, columns = 1, fg = 0xffffff,
          faint = true, overline = true, underline = 2,
          underline_color = 0xff0000,
        }},
        backgrounds = {},
      }},
      cursor = { visible = true, x = 2, y = 0, style = "hollow" },
    }
    local calls = draw_calls(function() view:draw() end)
    test.ok(#calls.rect >= 7)
    test.equal(calls.text[1][9][4], 140)
  end)

  test.it("handles terminal bells and clipboard requests", function(context)
    local view = terminal.open()
    view.snapshot.events = {
      { type = "bell" },
      { type = "clipboard", text = "terminal clipboard" },
    }
    local previous_show = core.nag_view.show
    core.nag_view.show = function() end
    view:handle_events()
    core.nag_view.show = previous_show
    test.equal(view.bell_count, 1)
    test.equal(view.pending_clipboard.text, "terminal clipboard")
  end)

  test.it("renders real ConPTY output through Terminal View", function(context)
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    terminal._set_native_for_tests(nil)
    local view = terminal.open({
      cwd = system.getcwd(),
      shell = 'cmd.exe /d /s /c "echo ANVIL_TERMINAL_VIEW_INTEGRATION"',
    })
    test.ok(view)
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 800, 400
    local deadline = system.get_time() + 5
    local found = false
    while system.get_time() < deadline and not found do
      view:update()
      for _, row in ipairs(view.snapshot.rows or {}) do
        for _, run in ipairs(row.text_runs or {}) do
          if run.text:find("ANVIL_TERMINAL_VIEW_INTEGRATION", 1, true) then
            found = true
          end
        end
      end
      if not found then coroutine.yield(0.01) end
    end
    test.ok(found)
    local calls = draw_calls(function() view:draw() end)
    test.ok(#calls.text > 0)
    terminal._set_native_for_tests(context.native)
  end)
end)
