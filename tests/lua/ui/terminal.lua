local command = require "core.command"
local common = require "core.common"
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
      traces = {},
      closed = false,
      state = "running",
      revision = 1,
    }
    function session:update()
      self.update_calls = (self.update_calls or 0) + 1
      local changed = self.next_changed or false
      self.next_changed = false
      local running = self.next_running
      self.next_running = nil
      local status = self.next_status
      self.next_status = nil
      if running == false then
        self.state = "exited"
        self.revision = self.revision + 1
      end
      if status then
        self.state = status.kind or self.state
        self.revision = status.revision or (self.revision + 1)
        self.status = {
          kind = self.state,
          revision = self.revision,
          exit_code = status.exit_code,
          error = status.error,
        }
      end
      self.status = self.status or { kind = self.state, revision = self.revision }
      return changed, self.status
    end
    function session:snapshot(previous, include_rows)
      self.snapshot_calls = (self.snapshot_calls or 0) + 1
      self.snapshot_include_rows = include_rows
      self.snapshot_requests = self.snapshot_requests or {}
      self.snapshot_requests[#self.snapshot_requests + 1] = include_rows
      local snapshot = previous or {
        rows = {},
        cols = 80,
        row_count = 24,
        foreground = 0xffffff,
        background = 0x000000,
        cursor = { visible = true, x = 0, y = 0, style = "block" },
        events = {},
      }
      snapshot.state = self.state
      return snapshot
    end
    function session:write(text) self.writes[#self.writes + 1] = text; return true end
    function session:clear() self.cleared = true; return true end
    function session:key(key, mods, action, event)
      self.keys[#self.keys + 1] = { key, mods, action, event }
      if self.key_failures and self.key_failures > 0 then
        self.key_failures = self.key_failures - 1
        return false, "queue_full"
      end
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
    function session:text_capture()
      return self.capture or {
        text = "",
        cursor_line = 1,
        cursor_col = 1,
        viewport_line = 1,
      }
    end
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
    function session:row_text() return self.row_text_data end
    function session:trace(path)
      self.traces[#self.traces + 1] = path or false
      if path then
        self.trace_path = path
        return true
      end
      self.trace_path = nil
      return true, 17
    end
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
    context.terminal_font_sizes = {}
    for _, font in ipairs({
      style.terminal_font, style.terminal_bold_font,
      style.terminal_italic_font, style.terminal_bold_italic_font,
    }) do
      context.terminal_font_sizes[font] = font:get_size()
    end
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
    for font, size in pairs(context.terminal_font_sizes) do font:set_size(size) end
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

  test.it("keeps a failed shell start visible in the requested Pane", function(context)
    context.native.next_error = "The shell executable was not found"
    local pane = panes.create()
    local view, err = terminal.open({
      pane = pane,
      focus = true,
      cwd = "C:/missing-shell-test",
      shell = "missing-shell.exe",
    })

    test.ok(view, err)
    test.equal(pane.current_view, view)
    test.equal(view.state, "failed")
    test.contains(view:get_name(), "failed")
    test.contains(view.launch_error, "not found")
    local calls = draw_calls(function() view:draw() end)
    local text = {}
    for _, call in ipairs(calls.text) do text[#text + 1] = tostring(call[2] or "") end
    test.contains(table.concat(text, " "), "not found")
    test.ok(command.perform("terminal:restart"))
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

  test.it("opens terminal output as navigable text while the session keeps running", function(context)
    local terminal_view = terminal.open()
    local pane = panes.active()
    local session = context.sessions[1]
    session.capture = {
      text = "first row\nsecond row\nthird row\nfourth row\nfifth row\n",
      cursor_line = 4,
      cursor_col = 3,
      viewport_line = 2,
    }
    terminal_view.position.x, terminal_view.position.y = 0, 0
    terminal_view.size.x, terminal_view.size.y = 800, 64

    test.ok(command.perform("core:open_text_capture"))

    local capture = pane.current_view
    test.ok(capture and capture:extends(require "core.textview"))
    test.ok(capture.buffer.read_only)
    test.equal(capture.buffer:get_selection(), 4)
    local line, col = capture.buffer:get_selection()
    test.equal(line, 4)
    test.equal(col, 3)
    test.equal(capture.terminal_source_view, nil)
    test.equal(capture.scroll.y, capture:get_line_height())

    local updates = session.update_calls or 0
    core.root_panel:update()
    test.ok((session.update_calls or 0) > updates)
    test.equal(capture.buffer:get_selection(), 4)
    test.ok(command.perform("core:move_to_previous_line"))
    test.equal(capture.buffer:get_selection(), 3)

    test.equal(panes.back(pane), terminal_view)
    test.equal(terminal_view.session, session)
    test.not_ok(session.closed)
  end)

  test.it("renders captured terminal text with its terminal colors and font style", function(context)
    local terminal_view = terminal.open()
    local session = context.sessions[1]
    session.capture = {
      text = "plain\ncolored\n",
      cursor_line = 2,
      cursor_col = 1,
      viewport_line = 1,
      foreground = 0x102030,
      background = 0x010203,
      styles = {
        [1] = { { col1 = 1, col2 = 6, fg = 0x102030 } },
        [2] = { {
          col1 = 1, col2 = 8, fg = 0xa1b2c3, background = 0x112233,
          bold = true, italic = true, underline = 1, strikethrough = true,
        } },
      },
    }

    test.ok(command.perform("core:open_text_capture"))

    local capture = panes.active().current_view
    local render_line = test.not_nil(capture:get_line_render(2))
    local fragment = test.not_nil(render_line.fragments[1])
    test.same(fragment.color, { 0xa1, 0xb2, 0xc3, 255 })
    test.same(fragment.background, { 0x11, 0x22, 0x33, 255 })
    test.equal(fragment.font, style.terminal_bold_italic_font)
    test.ok(fragment.underline)
    test.ok(fragment.strikethrough)
    test.same(capture.terminal_background, { 1, 2, 3, 255 })
    test.equal(capture.terminal_source_view, nil)
  end)

  test.it("starts and stops an explicit VT trace with a terminal model capture", function(context)
    local view = terminal.open()
    local session = context.sessions[1]
    session.capture = {
      text = "ANVIL_TRACE_MODEL\n",
      cursor_line = 1,
      cursor_col = 1,
      viewport_line = 1,
    }

    test.ok(command.perform("terminal:start_vt_trace"))
    local trace_path = test.not_nil(view.vt_trace_path)
    test.equal(session.traces[1], trace_path)
    test.ok(command.perform("terminal:stop_vt_trace"))
    test.equal(session.traces[2], false)
    test.is_nil(view.vt_trace_path)

    local model_path = trace_path .. ".model.txt"
    local file = test.not_nil(io.open(model_path, "rb"))
    local model = file:read("*a")
    file:close()
    os.remove(model_path)
    os.remove(trace_path)
    test.equal(model, "ANVIL_TRACE_MODEL\n")
  end)

  test.it("copies a frozen terminal text capture into an independent split", function(context)
    local terminal_view = terminal.open()
    context.sessions[1].capture = {
      text = "plain\ncolored\n",
      cursor_line = 2,
      cursor_col = 3,
      viewport_line = 1,
      foreground = 0x102030,
      background = 0x010203,
      styles = {
        [2] = { { col1 = 1, col2 = 8, fg = 0xa1b2c3, bold = true } },
      },
    }
    test.ok(command.perform("core:open_text_capture"))
    local source_pane = panes.active()
    local capture = source_pane.current_view

    test.ok(command.perform("pane:copy_view_to_split_right"))

    local copy_pane = panes.active()
    local copy = copy_pane.current_view
    test.not_equal(copy, capture)
    test.not_equal(copy.buffer, capture.buffer)
    test.same(copy.buffer.lines, capture.buffer.lines)
    test.equal(copy.terminal_source_view, nil)
    test.same(copy:get_line_render(2).fragments[1].color, { 0xa1, 0xb2, 0xc3, 255 })
    test.equal(panes.history_length(source_pane), 2)
    test.equal(panes.history_length(copy_pane), 1)
  end)

  test.it("does not retain a closed Terminal View through its text capture", function(context)
    local source = terminal.TerminalView()
    context.sessions[1].capture = {
      text = "frozen output",
      cursor_line = 1,
      cursor_col = 1,
      viewport_line = 1,
      title = "Frozen Terminal",
    }
    local capture = terminal.TerminalTextCaptureView(source, context.sessions[1].capture)
    local weak = setmetatable({ source }, { __mode = "v" })
    source:on_close()
    source = nil
    collectgarbage("collect")
    collectgarbage("collect")

    test.equal(weak[1], nil)
    test.equal(capture.buffer.lines[1]:gsub("\n$", ""), "frozen output")
    test.equal(capture:get_name(), "Terminal Text — Frozen Terminal")
  end)

  test.it("updates live and captured terminal row geometry after a font scale change", function(context)
    local terminal_view = terminal.open()
    local session = context.sessions[1]
    session.capture = {
      text = "first\nsecond\n",
      cursor_line = 1,
      cursor_col = 1,
      viewport_line = 1,
    }
    test.ok(command.perform("core:open_text_capture"))
    local capture = panes.active().current_view
    local old_cell_width = terminal_view.cell_width
    local old_cell_height = terminal_view.cell_height
    local old_line_height = capture:get_line_height()

    style.terminal_font:set_size(style.terminal_font:get_size() * 1.5)
    core.root_panel:update()

    test.ok(terminal_view.cell_width > old_cell_width)
    test.ok(terminal_view.cell_height > old_cell_height)
    test.ok(capture:get_line_height() > old_line_height)
    local resize = test.not_nil(session.resizes[#session.resizes])
    test.equal(resize[3], terminal_view.native_cell_width)
    test.equal(resize[4], terminal_view.cell_height)
  end)

  test.it("services a terminal while its Pane Group is hidden", function(context)
    local view = terminal.open()
    local session = view.session
    panes.create { factory = function() return View() end }
    session.snapshot_requests = {}
    view.size.x = view.size.x + 100
    local before = session.update_calls or 0
    core.root_panel:update()
    test.ok((session.update_calls or 0) > before)
    test.equal(session.snapshot_requests[#session.snapshot_requests], false)
    test.not_ok(session.closed)
  end)

  test.it("services hidden output without rebuilding rows or repeating state work", function(context)
    local view = terminal.open()
    local session = context.sessions[1]

    view:service_session(false)
    session.snapshot_calls = 0
    session.snapshot_requests = {}
    session.next_changed = true
    view.hover_point = { uri = "https://old.test" }
    view.hover_cell = "0:0"
    view.cursor = "hand"
    view.snapshot.events = { { type = "bell", count = 2 } }
    view:service_session(false)
    test.equal(session.snapshot_calls, 1)
    test.equal(session.snapshot_requests[1], false)
    test.equal(view.bell_count, 2)
    test.equal(view.cursor, "ibeam")

    view:service_session(true)
    test.equal(session.snapshot_calls, 2)
    test.equal(session.snapshot_requests[2], true)
    view:service_session(true)
    test.equal(session.snapshot_calls, 2)

    session.state = "exited"
    session.revision = 2
    session.status = { kind = "exited", revision = 2, exit_code = 0 }
    view:service_session(false)
    local after_exit = session.snapshot_calls
    core.redraw = false
    view:service_session(false)
    test.equal(session.snapshot_calls, after_exit)
    test.not_ok(core.redraw)
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

  test.it("focuses every Pane-owned Terminal View through one command", function()
    local first = terminal.open({ focus = true })
    local pane = panes.pane_for_view(first)
    local second = terminal.open({ pane = pane, focus = true })
    local other_pane = panes.create()
    local third = terminal.open({ pane = other_pane, focus = true })
    local expected = { [first] = true, [second] = true, [third] = true }
    local seen = {}

    for _ = 1, 6 do
      test.ok(command.perform("terminal:focus_next"))
      seen[core.active_view] = true
      test.equal(panes.pane_for_view(core.active_view).current_view, core.active_view)
    end
    for view in pairs(expected) do
      test.ok(seen[view], "a Pane-owned Terminal View was not reachable")
    end
  end)

  test.it("restores Workspace launch state as a new shell session", function(context)
    local previous_info = system.get_file_info
    system.get_file_info = function(path)
      if path == "C:/workspace" then return { type = "dir" } end
      return previous_info(path)
    end
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
    system.get_file_info = previous_info
  end)

  test.it("copy-splits into a new terminal at the current directory", function(context)
    local source = terminal.open { cwd = "C:/initial", shell = "pwsh.exe" }
    source.snapshot.pwd = system.getcwd()

    test.ok(command.perform("pane:copy_view_to_split_right"))

    local copy = panes.active().current_view
    test.ok(copy.terminal_view)
    test.not_equal(copy, source)
    test.not_equal(copy.session, source.session)
    test.equal(#context.sessions, 2)
    test.equal(context.sessions[2].options.cwd, system.getcwd())
    test.equal(copy.launch_options.shell, "pwsh.exe")
  end)

  test.it("uses only validated local terminal directories", function()
    local previous_info = system.get_file_info
    system.get_file_info = function(path)
      if path == "C:/valid" or path == [[\\server\share]] then return { type = "dir" } end
      return nil
    end
    local view = terminal.open({ cwd = "C:/fallback" })

    view.snapshot.pwd = "file:///C:/valid"
    test.equal(view:get_cwd(), "C:/valid")
    view.snapshot.pwd = "file://server/share"
    test.equal(view:get_cwd(), [[\\server\share]])
    for _, reported in ipairs({
      "file://bad/C:/missing", "/home/user", "C:/missing", "C:/bad\0path",
    }) do
      view.snapshot.pwd = reported
      test.equal(view:get_cwd(), system.getcwd())
    end
    system.get_file_info = previous_info
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

  test.it("sanitizes terminal titles before showing them in the UI", function()
    local view = terminal.open()
    view.snapshot.title = "  build\n\tstatus\0" .. string.rep("x", 1000) .. "  "
    local title = view:get_name()
    test.equal(title:find("[%c]"), nil)
    test.contains(title, "build status")
    test.ok(#title < 1000)
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

  test.it("keeps encoded text ownership when another text event arrives first", function(context)
    local view = terminal.open()
    test.ok(view:on_key_pressed("/", {
      shift = true, modifiers = 1, scancode = 36, text = "/",
      unshifted_codepoint = string.byte("7"), consumed_modifiers = 1,
    }))
    test.ok(view:on_text_input("x"))
    test.ok(view:on_text_input("/"))
    test.same({ "x" }, context.sessions[1].writes)
  end)

  test.it("expires encoded text ownership when its key is released", function(context)
    local view = terminal.open()
    local event = { modifiers = 0, scancode = 36, text = "/" }
    test.ok(view:on_key_pressed("/", event))
    test.ok(view:on_key_released("/", event))
    test.ok(view:on_text_input("/"))
    test.same({ "/" }, context.sessions[1].writes)
  end)

  test.it("runs valid Anvil shortcuts before terminal input", function(context)
    local first = panes.create { factory = function() return View() end }
    local second = panes.create { factory = function() return View() end }
    terminal.open { pane = second }
    keymap.modkeys.alt = true

    core.on_event("keypressed", "1", {
      alt = true, modifiers = 0, scancode = 30,
    })
    keymap.modkeys.alt = false

    test.equal(panes.active(), first)
    test.equal(#context.sessions[1].keys, 0)
  end)

  test.it("does not send a key release for a press owned by Anvil", function(context)
    local view = terminal.open({ focus = true })
    local event = { ctrl = true, modifiers = 2, scancode = 14 }
    test.ok(view:on_key_released("k", event))
    test.equal(#context.sessions[1].keys, 0)
  end)

  test.it("releases terminal-owned keys when focus leaves the View", function(context)
    local view = terminal.open({ focus = true })
    local event = { ctrl = true, modifiers = 2, scancode = 14 }
    test.ok(view:on_key_pressed("k", event))
    core.set_active_view(context.previous_active_view)
    view:sync_focus()
    test.equal(context.sessions[1].keys[#context.sessions[1].keys][3], "release")
  end)

  test.it("retries a terminal-owned release after input backpressure", function(context)
    local view = terminal.open({ focus = true })
    local session = context.sessions[1]
    local event = { ctrl = true, modifiers = 2, scancode = 14 }
    test.ok(view:on_key_pressed("k", event))
    session.key_failures = 1
    test.ok(view:on_key_released("k", event))
    test.equal(#view.pending_key_releases, 1)
    view:service_session(true)
    test.equal(#view.pending_key_releases, 0)
    test.equal(session.keys[#session.keys][3], "release")
  end)

  test.it("sends unhandled shell control keys to the terminal", function(context)
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

    keymap.modkeys.ctrl = true
    keymap.modkeys.shift = true
    test.ok(core.on_event("keypressed", "home", {
      ctrl = true, shift = true, modifiers = 3,
    }))
    test.ok(core.on_event("keypressed", "end", {
      ctrl = true, shift = true, modifiers = 3,
    }))
    keymap.modkeys.ctrl = false
    keymap.modkeys.shift = false
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
    context.sessions[1].update = function()
      return false, { kind = "exited", revision = 2, exit_code = 7 }
    end
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

  test.it("clears transient input state when it restarts", function(context)
    local view = terminal.open()
    view.key_owners = { stale = "ghostty" }
    view.encoded_text_queue = { "stale" }
    view.composition = { text = "stale", start = 0, length = 0 }
    view.state = "exited"
    test.ok(view:restart())
    test.same({}, view.key_owners)
    test.same({}, view.encoded_text_queue)
    test.equal(view.composition, nil)
  end)

  test.it("does not restart a running terminal", function(context)
    local view = terminal.open({ focus = true })
    local session = context.sessions[1]
    test.not_ok(view:restart())
    test.equal(#context.sessions, 1)
    test.not_ok(session.closed)
  end)

  test.it("keeps the exited session when restart fails", function(context)
    local view = terminal.open()
    local previous = context.sessions[1]
    previous.update = function()
      return false, { kind = "exited", revision = 2, exit_code = 2 }
    end
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
      return false, { kind = "failed", revision = 2, error = "ConPTY input failed" }
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

  test.it("shows found and no-match terminal search states", function()
    local view = terminal.open()
    test.not_ok(view:search("missing", false))
    test.equal(view.search_state, "no_match")
    test.ok(view:search("needle", false))
    test.equal(view.search_state, "found")
    test.equal(view.search_query, "needle")
  end)

  test.it("cancels pending terminal search when the query is cleared", function(context)
    local view = terminal.open()
    context.sessions[1].search = function() return false, "pending" end
    test.ok(view:search("needle", false))
    test.ok(view.search_pending)
    test.not_ok(view:search("", false))
    test.equal(view.search_pending, nil)
    view:update()
    test.equal(view.search_query, nil)
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

  test.it("maps fractional mouse geometry to the same native cell", function(context)
    local view = terminal.open()
    view.position.x, view.position.y = 0, 0
    view.cell_width = 7.5
    view.native_cell_width = 8
    view.cols = 80
    view.snapshot.mouse_tracking = true
    local x = 6 + view.cell_width * 70 + 1
    local y = 6 + view.cell_height * 2 + 1
    local expected_col, expected_row = view:mouse_position(x, y)
    view:on_mouse_pressed("left", x, y)
    local mouse = context.sessions[1].mouse_events[1]
    test.equal(math.floor(mouse[3] / view.native_cell_width), expected_col)
    test.equal(math.floor(mouse[4] / view.cell_height), expected_row)
  end)

  test.it("activates only a safe URI after one complete mouse gesture", function(context)
    local previous_open = system.open_in_system
    local opened = {}
    system.open_in_system = function(uri) opened[#opened + 1] = uri; return true end
    local view = terminal.open()
    local session = context.sessions[1]
    session.hyperlink_uri = "https://example.test/path"
    view.snapshot.mouse_tracking = true
    keymap.modkeys.ctrl = true

    local x, y = 7, 7
    view:on_mouse_pressed("left", x, y)
    test.equal(#opened, 0)
    view:on_mouse_moved(x + view.cell_width * 3, y, view.cell_width * 3, 0)
    view:on_mouse_released("left", x + view.cell_width * 3, y)
    test.equal(#opened, 0)
    test.equal(#session.mouse_events, 0)

    view:on_mouse_pressed("left", x, y)
    view:on_mouse_released("left", x, y)
    test.same(opened, { "https://example.test/path" })
    test.equal(#session.mouse_events, 0)

    session.hyperlink_uri = [[https://example.test/" & echo unsafe]]
    view:on_mouse_pressed("left", x, y)
    view:on_mouse_released("left", x, y)
    test.equal(opened[2], session.hyperlink_uri)

    session.hyperlink_uri = "javascript:alert(1)"
    test.equal(view:point_of_interest_at(0, 0), nil)
    view:on_mouse_pressed("left", x, y)
    view:on_mouse_released("left", x, y)
    test.equal(#opened, 2)
    keymap.modkeys.ctrl = false
    system.open_in_system = previous_open
  end)

  test.it("accepts URI schemes without case-sensitive matching", function(context)
    local previous_open = system.open_in_system
    local opened
    system.open_in_system = function(uri) opened = uri return true end
    local view = terminal.open()
    local session = context.sessions[1]
    session.hyperlink_uri = "HTTPS://example.test/path"
    test.ok(view:activate_point_of_interest(view:point_of_interest_at(0, 0)))
    session.hyperlink_uri = nil
    local text = "HTTP://example.test/text"
    local columns = {}
    for index = 1, #text do columns[index] = index - 1 end
    session.row_text_data = { text = text, columns = columns, generation = 1 }
    test.equal(view:point_of_interest_at(0, 0).uri, text)
    system.open_in_system = previous_open
    test.equal(opened, "HTTPS://example.test/path")
  end)

  test.it("detects plain HTTP text and clears its hover when Ctrl is released", function(context)
    local view = terminal.open()
    local text = "http://example.test/path"
    local columns = {}
    for index = 1, #text do columns[index] = index - 1 end
    context.sessions[1].row_text_data = {
      text = text, columns = columns, generation = 1,
    }
    keymap.modkeys.ctrl = true
    view:on_mouse_moved(7, 7, 0, 0)
    test.equal(view.cursor, "hand")
    keymap.modkeys.ctrl = false
    view:on_key_released("left ctrl", { scancode = 224 })
    test.equal(view.hover_point, nil)
    test.equal(view.cursor, "ibeam")
  end)

  test.it("cancels URI activation when the pointer leaves terminal cells", function(context)
    local previous_open = system.open_in_system
    local opened = 0
    system.open_in_system = function() opened = opened + 1 return true end
    local view = terminal.open()
    context.sessions[1].hyperlink_uri = "https://example.test/path"
    keymap.modkeys.ctrl = true
    view:on_mouse_pressed("left", 7, 7)
    view:on_mouse_moved(-10, 7, -17, 0)
    view:on_mouse_released("left", 7, 7)
    view:on_mouse_pressed("left", 7, 7)
    view:on_mouse_left()
    keymap.modkeys.ctrl = false
    view:on_mouse_released("left", 7, 7)
    system.open_in_system = previous_open
    test.equal(opened, 0)
  end)

  test.it("ignores malformed file locations during hover", function(context)
    local view = terminal.open({ cwd = system.getcwd() })
    local text = "C:/../../file.lua:1"
    local columns = {}
    for index = 1, #text do columns[index] = index - 1 end
    context.sessions[1].row_text_data = {
      text = text, columns = columns, generation = 1,
    }
    local ok, point = pcall(view.point_of_interest_at, view, 1, 0)
    test.ok(ok)
    test.equal(point, nil)
  end)

  test.it("bounds terminal location candidates before filesystem probes", function()
    local locations = require "core.text_poi_locations"
    local rows = {}
    for index = 1, 300 do rows[index] = "file" .. index .. ".lua:1" end
    test.equal(#locations.extract_candidates(table.concat(rows, " "), 32), 32)
  end)

  test.it("opens a validated file location from one terminal row", function(context)
    local previous_info = system.get_file_info
    local previous_open = core.open_file
    local target = common.normalize_path("C:/valid/file.lua")
    system.get_file_info = function(path)
      if common.path_equals(path, target) then return { type = "file" } end
    end
    local opened
    core.open_file = function(path, options)
      opened = { path = path, options = options }
      return View()
    end
    local view = terminal.open({ cwd = "C:/root" })
    local text = "C:/valid/file.lua:12:3"
    local columns = {}
    for index = 1, #text do columns[index] = index - 1 end
    context.sessions[1].row_text_data = {
      text = text, columns = columns, generation = 3,
    }
    keymap.modkeys.ctrl = true
    local x, y = 6 + view.cell_width * 5 + 1, 7
    view:on_mouse_pressed("left", x, y)
    view:on_mouse_released("left", x, y)
    keymap.modkeys.ctrl = false

    core.open_file = previous_open
    system.get_file_info = previous_info
    test.ok(opened)
    test.ok(common.path_equals(opened.path, target))
    test.equal(opened.options.line, 12)
    test.equal(opened.options.col, 3)
  end)

  test.it("cancels a file gesture when its target position changes", function(context)
    local previous_info = system.get_file_info
    local previous_open = core.open_file
    system.get_file_info = function() return { type = "file" } end
    local opened = 0
    core.open_file = function() opened = opened + 1 return View() end
    local view = terminal.open({ cwd = system.getcwd() })
    local session = context.sessions[1]
    local function set_row(line)
      local text = "file.lua:" .. line .. ":1"
      local columns = {}
      for index = 1, #text do columns[index] = index - 1 end
      session.row_text_data = { text = text, columns = columns, generation = line }
    end
    keymap.modkeys.ctrl = true
    set_row(1)
    view:on_mouse_pressed("left", 7, 7)
    set_row(999)
    view:on_mouse_released("left", 7, 7)
    keymap.modkeys.ctrl = false
    core.open_file = previous_open
    system.get_file_info = previous_info
    test.equal(opened, 0)
  end)

  test.it("sanitizes Terminal Text Capture titles", function(context)
    local source = terminal.open()
    context.sessions[1].capture = {
      text = "output", cursor_line = 1, cursor_col = 1, viewport_line = 1,
      title = "bad\n\ttitle\0" .. string.rep("x", 1000),
    }
    test.ok(source:open_text_capture())
    local name = panes.active().current_view:get_name()
    test.equal(name:find("[%c]"), nil)
    test.ok(#name < 300)
  end)

  test.it("reports Terminal View focus changes", function(context)
    local view = terminal.open()
    local session = context.sessions[1]
    view:update()
    core.set_active_view(context.previous_active_view)
    view:update()

    test.same({ true, false }, session.focus_events)
  end)

  test.it("reports exact View, Pane, and application focus", function(context)
    local previous_window_has_focus = system.window_has_focus
    local window_focused = true
    system.window_has_focus = function() return window_focused end

    local view = terminal.open({ focus = true })
    local pane = panes.pane_for_view(view)
    local session = context.sessions[1]
    view:update()

    panes.place(function() return Editor(Buffer(nil, nil, true)) end, {
      pane = pane, placement = "current", focus = true,
    })
    view:update_suspended()

    panes.back(pane)
    core.set_active_view(view)
    view:update()

    local other = panes.split(pane, "right", { factory = function()
      return Editor(Buffer(nil, nil, true))
    end, focus = true })
    core.set_active_view(other.current_view)
    view:update_suspended()
    panes.focus(pane)
    view:update()

    window_focused = false
    view:update()
    window_focused = true
    view:update()
    system.window_has_focus = previous_window_has_focus

    test.same({ true, false, true, false, true, false, true }, session.focus_events)
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
    local previous_active_view = core.active_view
    local previous_flash_window = system.flash_window
    local flash_count = 0
    core.active_view = nil
    system.flash_window = function() flash_count = flash_count + 1 end
    view.snapshot.events = {
      { type = "bell" },
      { type = "clipboard", text = "terminal clipboard" },
    }
    local previous_show = core.nag_view.show
    core.nag_view.show = function() end
    view:handle_events()
    core.nag_view.show = previous_show
    core.active_view = previous_active_view
    system.flash_window = previous_flash_window
    test.equal(view.bell_count, 1)
    test.equal(flash_count, 0)
    test.equal(view.active_clipboard_request.text, "terminal clipboard")
  end)

  test.it("binds clipboard approval to one immutable request", function()
    local view = terminal.open()
    local previous_show = core.nag_view.show
    local previous_clipboard = system.get_clipboard()
    local prompts = {}
    core.nag_view.show = function(_, title, message, buttons, callback)
      prompts[#prompts + 1] = { title, message, buttons, callback }
    end

    view.snapshot.events = { { type = "clipboard", text = "first request" } }
    view:handle_events()
    view.snapshot.events = { { type = "clipboard", text = "second request" } }
    view:handle_events()
    test.equal(#prompts, 1)
    prompts[1][4]({ text = "Allow" })
    test.equal(system.get_clipboard(), "first request")
    test.equal(#prompts, 2)
    prompts[2][4]({ text = "Allow" })
    test.equal(system.get_clipboard(), "second request")

    core.nag_view.show = previous_show
    system.set_clipboard(previous_clipboard or "")
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
