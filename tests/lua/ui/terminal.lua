local ready = dofile("tests/fixtures/terminal_ready.lua")
local command = require "core.command"
local common = require "core.common"
local core = require "core"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local keymap = require "core.keymap"
local NagView = require "core.nagview"
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
  local previous_cells = renderer.draw_text_cells
  local previous_rect = renderer.draw_rect
  local previous_rounded_rect = renderer.draw_rounded_rect
  local calls = { text = {}, rect = {} }
  renderer.draw_text = function(...) calls.text[#calls.text + 1] = { ... } end
  renderer.draw_text_known_bounds = function(...) calls.text[#calls.text + 1] = { ... } end
  renderer.draw_text_cells = function(...) calls.text[#calls.text + 1] = { ... } end
  renderer.draw_rect = function(...) calls.rect[#calls.rect + 1] = { ... } end
  renderer.draw_rounded_rect = function(...) calls.rect[#calls.rect + 1] = { ... } end
  local ok, err = pcall(fn, calls)
  renderer.draw_text = previous_text
  renderer.draw_text_known_bounds = previous_known
  renderer.draw_text_cells = previous_cells
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
      find_calls = {},
      find_shift = 0,
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
    function session:image(id) return self.images and self.images[id] end
    function session:clear() self.cleared = true; return true end
    function session:key(key, mods, action, event)
      self.keys[#self.keys + 1] = { key, mods, action, event }
      if self.key_failures and self.key_failures > 0 then
        self.key_failures = self.key_failures - 1
        return false, "queue_full"
      end
      if self.key_result ~= nil then return self.key_result end
      return true
    end
    function session:paste(text, allow_unsafe)
      if not allow_unsafe and text:find("[\r\n]") then return false, "unsafe" end
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
      return true, self.report_mouse ~= false
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
    function session:find(query, case_sensitive)
      self.find_calls[#self.find_calls + 1] = { query, case_sensitive }
      if query == "" then return nil, false, nil end
      local matches = self.find_pending
      self.find_pending = nil
      return matches, false, self.find_shift
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
    function session:detach() self.detached = true end
    function session:stats() return { host_pid = 0, shell_pid = 0, replay_bytes = 0 } end
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
    require("core.image_overlay").close()
    if context.previous_time then system.get_time = context.previous_time end
    if context.previous_defer_draw then core.root_panel.defer_draw = context.previous_defer_draw end
    if context.previous_clipboard ~= nil then
      system.set_clipboard(context.previous_clipboard)
    end
    if context.previous_nag_show then core.nag_view.show = context.previous_nag_show end
    if context.previous_nag_view then
      if core.nag_view.visible then core.nag_view:next() end
      core.nag_view = context.previous_nag_view
    end
    for _, view in ipairs(terminal.open_views()) do
      local pane = panes.pane_for_view(view)
      if pane then panes.close(pane, { force = true }) else view:on_close() end
    end
    panes.reset_for_tests()
    if context.link_buffer then core.buffer_registry:remove(context.link_buffer, true) end
    if context.link_cwd then system.chdir(context.link_cwd) end
    if context.activation_path then os.remove(context.activation_path) end
    if context.drop_folder then test.ok(test.remove_tree(context.drop_folder)) end
    if context.link_folder then test.ok(test.remove_tree(context.link_folder)) end
    if context.backpressure_path then
      local deadline = system.get_time() + 5
      while not os.remove(context.backpressure_path) and system.get_time() < deadline do
        coroutine.yield(0.01)
      end
    end
    terminal._set_native_for_tests(nil)
    for font, size in pairs(context.terminal_font_sizes) do font:set_size(size) end
    if context.previous_active_view then core.set_active_view(context.previous_active_view) end
  end)

  test.it("starts a new Terminal of the Scratch Project at home and keeps it in that Project", function(context)
    local Project = require "core.project"
    local scratch = USERDIR .. PATHSEP .. "scratch"
    test.ok(system.mkdir(scratch))
    local projects = core.projects
    core.projects = { Project(scratch) }
    local ok, err = pcall(function()
      test.ok(terminal.open())
      local options = context.sessions[1].options
      test.ok(common.path_equals(options.cwd, HOME), "the Terminal started in " .. tostring(options.cwd))
      test.ok(common.path_equals(options.project_path, scratch))
    end)
    core.projects = projects
    test.ok(test.remove_tree(scratch))
    test.ok(ok, err)
  end)

  test.it("replaces an unused terminal without keeping it in Pane history", function(context)
    local view = terminal.open()
    local pane = panes.pane_for_view(view)
    local session = context.sessions[1]
    -- Startup output does not make a terminal used.
    view.snapshot.title = "PowerShell"
    view:service_session(true)
    local editor = Editor(Buffer())
    test.equal(panes.present(editor), pane)
    test.equal(pane.current_view, editor)
    test.equal(#pane.history.entries, 1)
    test.equal(pane.history.entries[1].view, editor)
    test.is_nil(panes.pane_for_view(view))
    test.ok(session.closed)
    test.equal(panes.visible_group(), pane.group)
  end)

  test.it("keeps an idle terminal in history after typed input is deleted", function(context)
    local view = terminal.open()
    local pane = panes.pane_for_view(view)
    test.ok(view:on_text_input("x"))
    test.ok(view:on_key_pressed("backspace"))
    view:apply_status { kind = "running", busy = false }
    local tree = require("plugins.filetree").new(system.getcwd())
    local opened = panes.present(tree)
    test.equal(opened, pane)
    test.equal(pane.current_view, tree)
    test.equal(panes.back(pane), view)
    test.ok(not context.sessions[1].closed)
    test.ok(panes.validate())
  end)

  test.it("keeps an idle terminal after paste or a submitted command", function(context)
    for _, send in ipairs {
      function(view) return view:paste("echo hello") end,
      function(view) return view:run_command_line("echo hello") end,
    } do
      local view = terminal.open()
      local pane = panes.pane_for_view(view)
      local session = view.session
      test.ok(send(view))
      view:apply_status { kind = "running", busy = false }
      local opened = panes.present(View())
      test.equal(opened, pane)
      test.equal(panes.back(pane), view)
      test.ok(not session.closed)
    end
  end)

  test.it("keeps an unused terminal replaceable after rejected input", function(context)
    local view = terminal.open()
    local pane = panes.pane_for_view(view)
    context.sessions[1].key_failures = 1
    test.not_ok(view:on_key_pressed("return"))
    test.equal(panes.present(Editor(Buffer())), pane)
    test.ok(context.sessions[1].closed)
  end)

  test.it("retains an idle restored terminal in history without a saved session identifier", function()
    local view = terminal.TerminalView.from_state { cwd = system.getcwd() }
    local pane = panes.present(view)
    view:apply_status { kind = "running", busy = false }
    local opened = panes.present(View())
    test.equal(opened, pane)
    test.equal(panes.back(pane), view)
    test.ok(view.session)
  end)

  test.it("opens elsewhere only while the current terminal is busy", function(context)
    local view = terminal.open()
    local pane = panes.active()
    test.ok(view:on_text_input("command"))
    view:apply_status { kind = "running", busy = true }
    local _, elsewhere = panes.place(function() return View() end, { pane = pane })
    test.not_equal(elsewhere.group, pane.group)
    test.equal(pane.current_view, view)
    view:apply_status { kind = "running", busy = false }
    local next_view, destination = panes.place(function() return View() end, { pane = pane })
    test.equal(destination, pane)
    test.equal(pane.current_view, next_view)
    test.equal(panes.back(pane), view)
    test.not_ok(context.sessions[1].closed)
    test.ok(panes.validate())
  end)

  test.it("does not rearrange history when a hidden terminal becomes busy", function()
    local original = View()
    local pane = panes.create { factory = function() return original end }
    local view = terminal.open()
    test.equal(panes.active(), pane)
    test.ok(view:on_text_input("command"))
    view:apply_status { kind = "running", busy = false }
    local next_view = View()
    test.equal(panes.present(next_view), pane)
    view:apply_status { kind = "running", busy = true }
    test.equal(panes.count(), 1)
    test.equal(pane.current_view, next_view)
    test.equal(panes.back(pane), view)
    test.equal(panes.back(pane), original)
    test.ok(panes.validate())
  end)

  test.it("opens a busy terminal's text capture in the same Pane", function(context)
    local view = terminal.open()
    local pane = panes.active()
    test.ok(view:on_text_input("command"))
    view:apply_status { kind = "running", busy = true }
    context.sessions[1].capture = { text = "running output" }
    test.ok(view:open_text_capture())
    test.equal(panes.active(), pane)
    test.ok(pane.current_view.terminal_text_capture)
    test.equal(panes.back(pane), view)
    test.not_ok(context.sessions[1].closed)
    test.ok(panes.validate())
  end)

  test.it("keeps an unused terminal visible while its shell runs a command", function(context)
    local view = terminal.open()
    local pane = panes.active()
    view:apply_status { kind = "running", busy = true }
    local _, destination = panes.place(function() return View() end)
    test.not_equal(destination.group, pane.group)
    test.equal(pane.current_view, view)
    test.not_ok(context.sessions[1].closed)
  end)

  test.it("opens a previously visited file elsewhere from a busy terminal", function(context)
    local buffer = Buffer()
    buffer:set_filename("saved.lua", "C:/saved.lua")
    context.link_buffer = buffer
    local editor = core.root_panel:open_buffer(buffer)
    local pane = panes.active()
    local view = terminal.open()
    test.ok(view:on_text_input("command"))
    view:apply_status { kind = "running", busy = true }
    local opened = core.root_panel:open_buffer(buffer)
    test.not_nil(opened)
    test.not_equal(panes.active().group, pane.group)
    test.equal(pane.current_view, view)
    test.equal(panes.active().current_view, opened)
    test.equal(opened.buffer, buffer)
    test.not_equal(opened, editor)
    test.ok(panes.validate())
  end)

  test.it("opens a previously visited File Tree elsewhere from a busy terminal", function()
    local filetree = require "plugins.filetree"
    local tree = filetree.open(system.getcwd())
    local pane = panes.active()
    local view = terminal.open()
    test.ok(view:on_text_input("command"))
    view:apply_status { kind = "running", busy = true }
    test.ok(command.perform("filetree:open_at_choose_path", system.getcwd()))
    test.not_equal(panes.active().group, pane.group)
    test.equal(pane.current_view, view)
    test.equal(panes.active().current_view.root_dir, tree.root_dir)
    test.ok(panes.validate())
  end)

  test.it("restores older Terminal history without retaining its old Pane constraint", function()
    local view = terminal.open()
    local pane = panes.active()
    local state = panes.save_workspace_state(function(candidate)
      return { module = candidate:get_module(), state = candidate:get_state() }
    end)
    local record = state.panes[1]
    -- Earlier Workspaces stored Terminal history as constrained related Views.
    record.related_views, record.history_views = record.history_views, nil
    test.ok(panes.restore_workspace_state(state, function(saved)
      return require(saved.module).from_state(saved.state)
    end))
    pane = panes.active()
    view = pane.current_view
    view:apply_status { kind = "running", busy = false }
    local _, destination = panes.place(function() return View() end)
    test.equal(destination, pane)
    test.equal(panes.back(pane), view)
    test.ok(panes.validate())
  end)

  test.it("opens the file at the terminal cursor in a new Pane Group", function(context)
    local path = USERDIR .. PATHSEP .. "terminal-activation.txt"
    context.activation_path = path
    local file = assert(io.open(path, "wb"))
    file:write("first\nsecond\n")
    file:close()
    local view = terminal.open { focus = true }
    local source = panes.active()
    local group = source.group
    view.session.hyperlink = function() return "file:///" .. path:gsub("\\", "/") end

    test.ok(command.perform("core:activate_point_of_interest_alternate"))

    test.not_equal(panes.active().group, group)
    test.equal(source.current_view, view)
    test.ok(common.path_equals(core.active_view.buffer.abs_filename, path))
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

  test.it("keeps the Editor and exact idle Terminal session in the same Pane history", function(context)
    local pane = panes.create { factory = function() return Editor(Buffer(nil, nil, true)) end }
    pane.current_view.buffer:set_filename("saved.lua", "C:/saved.lua")
    local editor = pane.current_view
    local view = terminal.open { pane = pane }
    local session = view.session
    local terminal_pane = panes.pane_for_view(view)
    test.equal(terminal_pane, pane)
    test.equal(panes.back(pane), editor)
    test.not_ok(session.closed)
    test.equal(panes.forward(pane), view)
    test.equal(terminal_pane.current_view, view)
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

  test.it("returns directly to the terminal after navigating and searching captured text", function(context)
    local source = terminal.open()
    local pane = panes.active()
    local session = context.sessions[1]
    session.capture = { text = "first\n" .. string.rep("output\n", 30) .. "needle\nlast" }
    context.previous_clipboard = system.get_clipboard()
    test.ok(command.perform("core:open_text_capture"))
    local capture = pane.current_view

    test.ok(command.perform("core:move_to_end_of_buffer"))
    test.ok(command.perform("core:move_to_start_of_buffer"))
    test.ok(command.perform("editor:find"))
    core.active_view:set_text("needle")
    test.ok(command.perform("editor:find_close"))
    test.equal(capture.buffer:get_selection(), 32)
    test.ok(command.perform("core:copy"))
    test.equal(system.get_clipboard(), "needle")

    test.ok(command.perform("core:navigate_back"))
    test.equal(pane.current_view, source)
    test.equal(source.session, session)
    test.not_ok(session.closed)
    test.ok(command.perform("core:navigate_forward"))
    test.equal(pane.current_view, capture)
    test.equal(capture.buffer:get_selection(), 32)
  end)

  test.it("closes Terminal Text on Escape without closing its terminal session", function(context)
    local source = terminal.open()
    local pane = panes.active()
    local session = context.sessions[1]
    session.capture = { text = "first\nneedle\nlast" }
    test.ok(command.perform("core:open_text_capture"))
    local capture = pane.current_view
    test.ok(command.perform("editor:find"))
    core.active_view:set_text("needle")

    -- The first Escape closes Find. The next closes the capture, even with selected text.
    core.on_event("keypressed", "escape", {})
    test.equal(core.active_view, capture)
    test.equal(pane.current_view, capture)
    core.on_event("keyreleased", "escape", {})
    core.on_event("keypressed", "escape", {})
    test.equal(pane.current_view, source)
    test.equal(core.active_view, source)
    test.equal(panes.pane_for_view(capture), nil)
    test.not_ok(panes.is_forward_available(pane))
    test.equal(source.session, session)
    test.not_ok(session.closed)
    test.equal(#session.keys, 0)
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

  test.it("restores Terminal Text and its Terminal in ordinary Pane history", function(context)
    local source = terminal.open()
    context.sessions[1].capture = { text = "saved output", title = "Saved Terminal" }
    test.ok(source:open_text_capture())
    local state = panes.save_workspace_state(function(view)
      return { module = view:get_module(), state = view:get_state() }
    end)
    test.ok(panes.restore_workspace_state(state, function(saved)
      return require(saved.module).from_state(saved.state)
    end))
    local pane = panes.active()
    test.ok(pane.current_view.terminal_text_capture)
    test.contains(table.concat(pane.current_view.buffer.lines), "saved output")
    local restored = panes.back(pane)
    test.ok(restored.terminal_view)
    test.not_equal(restored, source)
    test.ok(panes.forward(pane).terminal_text_capture)
    local _, other = panes.place(function() return View() end, { pane = pane })
    test.equal(other, pane)
    test.ok(panes.validate())
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

  test.it("opens an Editor in a copied Terminal Text Capture's Pane", function(context)
    local source = terminal.open()
    context.sessions[1].capture = { text = "frozen output" }
    test.ok(source:open_text_capture())
    local source_pane = panes.active()
    local original = source_pane.current_view

    test.ok(command.perform("pane:copy_view_to_new_group"))
    local copy_pane = panes.active()
    local copy = copy_pane.current_view
    test.not_equal(copy_pane, source_pane)
    test.ok(copy.buffer.read_only)

    local path = DATADIR .. "/core/commands/core.lua"
    local editor = core.root_panel:open_buffer(Buffer(path, path), { pane = copy_pane })
    test.ok(editor:extends(Editor))
    test.equal(copy_pane.current_view, editor)
    test.equal(panes.count(), 2)
    test.equal(panes.back(copy_pane), copy)
    test.ok(copy.buffer.read_only)
    test.equal(source_pane.current_view, original)
    test.equal(panes.back(source_pane), source)
    test.ok(panes.validate())
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
    test.ok(capture:get_line_height() > old_line_height)

    -- The capture opened in the Terminal's Pane. Show the Terminal again.
    panes.present(terminal_view)
    core.root_panel:update()
    test.ok(terminal_view.cell_width > old_cell_width)
    test.ok(terminal_view.cell_height > old_cell_height)
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
    local normal_cursor = view.cursor
    local session = context.sessions[1]

    view:service_session(false)
    session.snapshot_calls = 0
    session.snapshot_requests = {}
    session.next_changed = true
    view.hover_point = { uri = "https://old.test" }
    view.hover_cell = { col = 0, row = 0 }
    view.cursor = "hand"
    view.snapshot.events = { { type = "bell", count = 2 } }
    view:service_session(false)
    test.equal(session.snapshot_calls, 1)
    test.equal(session.snapshot_requests[1], false)
    test.not_nil(require("core.tab").describe({current_view = view}, 1).terminal.bell, "The Tab does not report the bell")
    test.equal(view.cursor, normal_cursor)

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

  test.it("replaces an exited Terminal with a blank Editor in the same Pane", function(context)
    local view = terminal.open()
    local pane = panes.pane_for_view(view)
    local session = view.session
    session.next_running = false
    session.next_status = { exit_code = 0 }
    view:update()

    test.equal(panes.count(), 1)
    test.equal(panes.active(), pane)
    test.ok(pane.current_view:extends(Editor))
    test.is_nil(pane.current_view.buffer.filename)
    test.same(pane.current_view.buffer.lines, { "\n" })
    test.equal(core.active_view, pane.current_view)
    test.is_nil(panes.pane_for_view(view))
    test.is_nil(view.session)
    test.ok(session.closed)
    test.equal(panes.history_length(pane), 1)
    test.ok(panes.validate())
  end)

  test.it("replaces a hidden exited Terminal without changing focus or Pane Group", function(context)
    local view = terminal.open()
    local pane = panes.pane_for_view(view)
    local session = view.session
    local other = panes.create { factory = function() return View() end }
    session.next_status = { kind = "exited", exit_code = 7 }

    view:update_suspended()

    test.ok(panes.contains(pane))
    test.ok(pane.current_view:extends(Editor))
    test.equal(panes.active(), other)
    test.equal(panes.visible_group(), other.group)
    test.equal(core.active_view, other.current_view)
    test.ok(session.closed)
    test.is_nil(panes.pane_for_view(view))
    test.ok(panes.validate())
  end)

  for _, show_terminal in ipairs { true, false } do
    test.it(show_terminal and "reveals retained text when the current Terminal exits"
      or "keeps current text when its suspended Terminal exits", function(context)
      local view = terminal.open()
      local pane = panes.pane_for_view(view)
      local session = view.session
      session.capture = { text = "retained output", cursor_line = 1, cursor_col = 1, viewport_line = 1 }
      test.ok(command.perform("core:open_text_capture"))
      local capture = pane.current_view
      if show_terminal then test.equal(panes.back(pane), view) end
      session.next_status = { kind = "exited", exit_code = 0 }

      if show_terminal then view:update() else view:update_suspended() end

      test.equal(panes.count(), 1)
      test.equal(panes.active(), pane)
      test.equal(pane.current_view, capture)
      test.equal(core.active_view, capture)
      test.contains(table.concat(capture.buffer.lines), "retained output")
      test.equal(panes.history_length(pane), 1)
      test.is_nil(panes.pane_for_view(view))
      test.ok(session.closed)
      test.ok(panes.validate())
    end)
  end

  test.it("keeps Terminal sessions in separate Panes and closes only the selected session", function(context)
    local first = terminal.open()
    test.ok(first:on_text_input("work"))
    local pane = panes.active()
    local second = terminal.open { pane = pane, placement = "new" }
    local first_session, second_session = first.session, second.session
    test.not_ok(first_session.closed)
    test.not_ok(second_session.closed)
    test.ok(panes.close(pane, { force = true }))
    test.ok(first_session.closed)
    test.not_ok(second_session.closed)
    test.ok(panes.close(panes.pane_for_view(second), { force = true }))
    test.ok(second_session.closed)
  end)

  test.it("focuses every Pane-owned Terminal View through one command", function()
    local first = terminal.open({ focus = true })
    test.ok(first:on_text_input("work"))
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

  test.it("encodes a text key with its text input, not the keymap text", function(context)
    local view = terminal.open()
    local session = context.sessions[1]
    -- A stale SDL keymap can hold U+FFFD for Shift+8 on a Spanish layout.
    local event = {
      shift = true, modifiers = 1, scancode = 37, text = "\239\191\189",
      unshifted_codepoint = string.byte("8"), consumed_modifiers = 1,
    }
    test.not_ok(view:on_key_pressed("8", event))
    test.equal(#session.keys, 0)
    test.ok(view:on_text_input("("))
    test.equal(session.keys[1][1], "8")
    test.equal(session.keys[1][3], "press")
    test.equal(session.keys[1][4].text, "(")
    test.equal(session.keys[1][4].scancode, 37)

    event["repeat"] = true
    test.not_ok(view:on_key_pressed("8", event))
    test.ok(view:on_text_input("("))
    test.equal(session.keys[2][3], "repeat")
    test.equal(session.keys[2][4].text, "(")
    test.equal(#session.writes, 0)
  end)

  test.it("types the text of a key that the terminal does not encode", function(context)
    local view = terminal.open()
    local session = context.sessions[1]
    session.key_result = false
    test.not_ok(view:on_key_pressed("8", {
      shift = true, modifiers = 1, scancode = 37, text = "(",
    }))
    test.ok(view:on_text_input("("))
    test.same({ "(" }, session.writes)
  end)

  test.it("sends no key for a dead key and encodes the composed character once", function(context)
    local view = terminal.open()
    local session = context.sessions[1]
    test.not_ok(view:on_key_pressed("[", { modifiers = 0, scancode = 40, text = "\194\180" }))
    test.not_ok(view:on_key_pressed("e", { modifiers = 0, scancode = 18, text = "e" }))
    test.ok(view:on_text_input("\195\169"))
    test.equal(#session.keys, 1)
    test.equal(session.keys[1][1], "e")
    test.equal(session.keys[1][4].text, "\195\169")
    test.equal(#session.writes, 0)
  end)

  test.it("gives a key to the IME composition that it starts", function(context)
    local view = terminal.open()
    local session = context.sessions[1]
    test.not_ok(view:on_key_pressed("a", { modifiers = 0, scancode = 4, text = "a" }))
    view:on_ime_text_editing("\227\129\130", 3, 0)
    test.ok(view:on_text_input("\227\129\130"))
    test.equal(#session.keys, 0)
    test.same({ "\227\129\130" }, session.writes)
  end)

  test.it("drops the text of a key that the terminal encoded with Alt", function(context)
    local view = terminal.open()
    local session = context.sessions[1]
    local event = {
      alt = true, modifiers = 0x100, scancode = 4, text = "a",
      unshifted_codepoint = string.byte("a"), consumed_modifiers = 0,
    }
    test.ok(view:on_key_pressed("a", event))
    test.ok(view:on_text_input("\195\165"))
    test.equal(#session.writes, 0)
    test.ok(view:on_key_released("a", event))
    test.ok(view:on_text_input("x"))
    test.same({ "x" }, session.writes)
  end)

  test.it("types text that arrives after its key was released", function(context)
    local view = terminal.open()
    local event = { modifiers = 0, scancode = 36, text = "/" }
    test.not_ok(view:on_key_pressed("/", event))
    test.ok(view:on_key_released("/", event))
    test.ok(view:on_text_input("/"))
    test.equal(#context.sessions[1].keys, 0)
    test.same({ "/" }, context.sessions[1].writes)
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

  test.it("restarts a failed terminal with the same launch options", function(context)
    local view = terminal.open({ cwd = "C:/terminal-test", shell = "cmd.exe" })
    context.sessions[1].update = function()
      return false, { kind = "failed", revision = 2 }
    end
    view:update()

    test.equal(view:get_name(), "Terminal (failed)")
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
    test.ok(view:on_key_pressed("a", { alt = true, modifiers = 0x100, scancode = 4, text = "a" }))
    view.composition = { text = "stale", start = 0, length = 0 }
    view.state = "exited"
    test.ok(view:restart())
    test.same({}, view.key_owners)
    test.equal(view.composition, nil)
    test.ok(view:on_text_input("x"))
    test.same({ "x" }, context.sessions[#context.sessions].writes)
  end)

  test.it("does not restart a running terminal", function(context)
    local view = terminal.open({ focus = true })
    local session = context.sessions[1]
    test.not_ok(view:restart())
    test.equal(#context.sessions, 1)
    test.not_ok(session.closed)
  end)

  test.it("keeps the failed session when restart fails", function(context)
    local view = terminal.open()
    local previous = context.sessions[1]
    previous.update = function()
      return false, { kind = "failed", revision = 2 }
    end
    view:update()
    context.native.next_error = "missing shell"
    local previous_error = core.error
    core.error = function() end
    local restarted = view:restart()
    core.error = previous_error
    test.equal(restarted, false)
    test.ok(view.session == previous)
    test.equal(view:get_name(), "Terminal (failed)")
    test.equal(previous.closed, false)
  end)

  test.it("shows terminal transport failures once", function(context)
    local view = terminal.open()
    local pane = panes.pane_for_view(view)
    local session = view.session
    context.sessions[1].update = function()
      return false, { kind = "failed", revision = 2, error = "ConPTY input failed" }
    end
    local previous_error = core.error
    local errors = {}
    core.error = function(message) errors[#errors + 1] = message end
    view:update()
    view:update()
    core.error = previous_error
    test.equal(pane.current_view, view)
    test.equal(view.session, session)
    test.not_ok(session.closed)
    test.same({ "ConPTY input failed" }, errors)
  end)

  test.it("pastes clipboard text through the terminal encoder", function(context)
    local previous = system.get_clipboard()
    system.set_clipboard("terminal paste")
    local view = terminal.open()

    test.ok(command.perform("terminal:paste"))
    test.equal(context.sessions[1].pastes[1][1], "terminal paste")

    system.set_clipboard(previous or "")
  end)

  test.it("pastes ordinary multiline Unicode text without confirmation", function(context)
    local view = terminal.open()
    context.previous_nag_view = core.nag_view
    core.nag_view = NagView()
    local text = string.rep("é\n", 2000)

    test.ok(view:paste(text))

    test.not_ok(core.nag_view.visible)
    test.equal(context.sessions[1].pastes[1][1], text)
  end)

  test.it("waits for confirmation of a large single-line paste and accepts by default", function(context)
    local view = terminal.open()
    context.previous_nag_view = core.nag_view
    core.nag_view = NagView()
    local text = string.rep("x", 6000)

    test.ok(view:paste(text))

    test.ok(core.nag_view.visible)
    test.equal(#context.sessions[1].pastes, 0)
    test.ok(command.perform("core:select_dialog_entry"))
    test.not_ok(core.nag_view.visible)
    test.equal(context.sessions[1].pastes[1][1], text)
  end)

  test.it("pastes dropped file paths instead of opening the files", function(context)
    local view = terminal.open { focus = true }
    local pane = panes.pane_for_view(view)
    core.root_panel:update()
    local folder = USERDIR .. PATHSEP .. "terminal-drop-" .. system.get_process_id()
    context.drop_folder = folder
    test.ok(common.mkdirp(folder))
    local spaced, plain = folder .. PATHSEP .. "my shot.png", folder .. PATHSEP .. "plain.txt"
    for _, path in ipairs({ spaced, plain }) do
      local file = assert(io.open(path, "wb")); file:write("x"); file:close()
    end
    local x, y = pane.position.x + 20, pane.position.y + 20

    core.on_event("dropbegin")
    core.on_event("dropmoved", x, y)
    core.on_event("filedropped", spaced, x, y)
    core.on_event("filedropped", plain, x, y)
    core.on_event("dropcomplete")

    test.equal(pane.current_view, view)
    test.equal(panes.count(), 1)
    test.equal(#context.sessions[1].pastes, 1)
    test.equal(context.sessions[1].pastes[1][1],
      '"' .. system.absolute_path(spaced) .. '" ' .. system.absolute_path(plain))
  end)

  test.it("pastes dropped text", function(context)
    local view = terminal.open { focus = true }
    local pane = panes.pane_for_view(view)
    core.root_panel:update()
    local x, y = pane.position.x + 20, pane.position.y + 20

    core.on_event("dropbegin")
    core.on_event("dropmoved", x, y)
    core.on_event("textdropped", "echo one\r\necho two", x, y)
    core.on_event("dropcomplete")

    test.equal(pane.current_view, view)
    test.equal(context.sessions[1].pastes[1][1], "echo one\necho two")
  end)

  test.it("does not send a large paste when confirmation is cancelled", function(context)
    local view = terminal.open()
    context.previous_nag_view = core.nag_view
    core.nag_view = NagView()

    test.ok(view:paste(string.rep("line\n", 1200)))
    test.ok(core.nag_view.visible)
    test.ok(command.perform("core:select_dialog_no"))

    test.not_ok(core.nag_view.visible)
    test.equal(#context.sessions[1].pastes, 0)
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

  test.it("applies only the latest of many selection drag motions in a frame", function(context)
    local view = terminal.open()
    view.position.x, view.position.y = 0, 0
    local session = context.sessions[1]
    -- The pointer stays inside the Terminal, so the selection does not scroll.
    local gesture = session.selection_gesture
    function session:selection_gesture(...)
      gesture(self, ...)
      return true, "none"
    end
    view:on_mouse_pressed("left", 6, 6)
    for step = 1, 200 do
      view:on_mouse_moved(6 + view.cell_width * (step % 5), 6 + view.cell_height * 2)
    end
    view:on_mouse_moved(6 + view.cell_width * 7, 6 + view.cell_height * 3)
    view:update()
    local drags = {}
    for _, event in ipairs(session.gesture_events) do
      if event[1] == "drag" then drags[#drags + 1] = event end
    end
    test.equal(#drags, 1)
    test.equal(drags[1][2], 7)
    test.equal(drags[1][3], 3)
    view:on_mouse_released("left", 6 + view.cell_width * 7, 6 + view.cell_height * 3)
  end)

  test.it("copies and clears the selection at a right-click", function(context)
    local previous = system.get_clipboard()
    system.set_clipboard("before")
    local view = terminal.open()
    view.position.x, view.position.y = 0, 0
    local session = context.sessions[1]
    session.selection_text = "selected output"
    -- A program that tracks the mouse does not get a right-click that copies.
    view.snapshot.mouse_tracking = true
    test.ok(view:on_mouse_pressed("right", 20, 30))
    test.ok(view:on_mouse_released("right", 20, 30))
    test.equal(system.get_clipboard(), "selected output")
    test.ok(session.selection_cleared, "the copied selection stayed")
    test.same(session.mouse_events, {})
    system.set_clipboard(previous or "")
  end)

  test.it("leaves the clipboard alone at a right-click without a selection", function(context)
    local previous = system.get_clipboard()
    system.set_clipboard("before")
    local view = terminal.open()
    view.position.x, view.position.y = 0, 0
    local session = context.sessions[1]
    view.snapshot.mouse_tracking = true
    view:on_mouse_pressed("right", 20, 30)
    view:on_mouse_released("right", 20, 30)
    test.equal(system.get_clipboard(), "before")
    test.equal(#session.mouse_events, 2, "the program lost its right-click")
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

  local function open_find(context, matches)
    local view = terminal.open()
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 800, 400
    view:update()
    view.snapshot.scrollbar = { total = 100, offset = 80, len = 20 }
    test.ok(command.perform("terminal:find"))
    test.equal(core.active_view, view.find.input)
    core.active_view:on_text_input("needle")
    context.sessions[1].find_pending = matches
    view:update()
    return view, context.sessions[1]
  end

  local function match(row, col1) return { row = row, col1 = col1 or 0, col2 = (col1 or 0) + 6 } end

  test.it("counts the matches of the typed query and starts at the last one on the screen", function(context)
    local view, session = open_find(context, { match(10), match(50), match(90), match(99, 20) })
    test.same({ "needle", false }, session.find_calls[#session.find_calls])
    test.equal(view.find:info(), "4 / 4")
    -- The current match is on the screen, so the screen stays.
    test.equal(#session.scrolls, 0)
  end)

  test.it("moves between matches and scrolls only to a match off the screen", function(context)
    local view, session = open_find(context, { match(10), match(50), match(90) })
    test.ok(command.perform("terminal:find_field_next"))
    test.equal(view.find:info(), "1 / 3")
    test.same({ "row", 0 }, session.scrolls[#session.scrolls])
    view.snapshot.scrollbar.offset = 0
    test.ok(command.perform("terminal:find_field_previous"))
    test.equal(view.find:info(), "3 / 3")
    test.same({ "row", 80 }, session.scrolls[#session.scrolls])
  end)

  test.it("keeps the current match on its line when new output arrives", function(context)
    local view, session = open_find(context, { match(10), match(50), match(90) })
    view.snapshot.scrollbar.offset = 40
    test.ok(command.perform("terminal:find_previous"))
    test.equal(view.find:info(), "2 / 3")
    local scrolls = #session.scrolls
    -- Output pruned 5 rows. The next scan finds the same lines 5 rows higher, and a new match.
    session.find_shift = 5
    view:update()
    session.find_shift = 0
    session.find_pending = { match(5), match(45), match(85), match(98) }
    view:update()
    test.equal(view.find:info(), "2 / 4")
    test.equal(#session.scrolls, scrolls)
  end)

  test.it("reports no results", function(context)
    local view = open_find(context, {})
    test.equal(view.find:info(), "No results")
  end)

  test.it("starts with a one-line terminal selection as its query", function(context)
    local view = terminal.open()
    context.sessions[1].selection_text = "selected words"
    test.ok(command.perform("terminal:find"))
    test.equal(view.find:query(), "selected words")
  end)

  test.it("closes from its field and gives the focus back to the terminal", function(context)
    local view = open_find(context, { match(90) })
    test.ok(command.perform("terminal:find_close"))
    test.equal(core.active_view, view)
    test.not_ok(view.find.visible)
  end)

  test.it("leaves field keys to the shell while the terminal has focus", function(context)
    local view = open_find(context, { match(90) })
    core.set_active_view(view)
    test.not_ok(command.perform("terminal:find_field_next"))
    test.not_ok(command.perform("terminal:find_close"))
    test.ok(view.find.visible)
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

  test.it("sends wheel input when application mouse mode changes before the display snapshot", function(context)
    local view = terminal.open()
    view.snapshot.mouse_tracking = false
    local session = context.sessions[1]
    session.report_mouse = true

    test.ok(view:on_mouse_wheel(1))

    test.equal(#session.scrolls, 0)
    test.equal(#session.mouse_events, 1)
    test.equal(session.mouse_events[1][2], "four")
  end)

  test.it("scrolls terminal history when the application does not accept wheel input", function(context)
    local view = terminal.open()
    view.snapshot.mouse_tracking = true
    local session = context.sessions[1]
    session.report_mouse = false

    test.ok(view:on_mouse_wheel(-1))

    test.equal(#session.scrolls, 1)
    test.equal(session.scrolls[1][1], "delta")
    test.ok(session.scrolls[1][2] > 0)
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

  test.it("opens a relative hyperlink with a normal click using the terminal directory", function(context)
    context.link_cwd = system.getcwd()
    local folder = USERDIR .. PATHSEP .. "terminal-relative-link"
    context.link_folder = folder
    test.ok(common.mkdirp(folder .. PATHSEP .. "plans"))
    local path = folder .. PATHSEP .. "plans" .. PATHSEP .. "SPARE_PROJECT_PROCESS_PLAN.md"
    local file = assert(io.open(path, "wb"))
    file:write("# Spare Project process\n")
    file:close()
    local view = terminal.open { cwd = folder, focus = true }
    local session = context.sessions[1]
    session.hyperlink = function(_, col, row)
      if row == 0 and col >= 9 and col <= 16 then
        return "plans/SPARE_PROJECT_PROCESS_PLAN.md"
      end
    end
    view.snapshot.mouse_tracking = true
    keymap.modkeys.ctrl = false
    local x, y = 7 + view.cell_width * 10, 7
    view:on_mouse_moved(x, y, 0, 0)
    local cursor, point = view.cursor, view.hover_point
    view:on_mouse_pressed("left", x, y)
    view:on_mouse_released("left", x, y)
    keymap.modkeys.ctrl = false
    view:clear_point_hover()
    context.link_buffer = core.active_view.buffer

    test.equal(cursor, "hand")
    test.ok(point and common.path_equals(point.path, path))
    test.same({ point.col, point.end_col, point.row }, { 9, 16, 0 })
    for _, event in ipairs(session.mouse_events) do test.equal(event[1], "motion") end
    test.ok(core.active_view.buffer)
    test.ok(common.path_equals(core.active_view.buffer.abs_filename, path))
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

  test.it("opens local image hyperlinks in the Image Overlay without leaving the Terminal", function(context)
    local overlay = require "core.image_overlay"
    context.link_cwd = system.getcwd()
    context.link_folder = USERDIR .. PATHSEP .. "terminal-image-link"
    test.ok(common.mkdirp(context.link_folder))
    local path = context.link_folder .. PATHSEP .. "linked image.png"
    test.ok(canvas.new(80, 40, { 255, 0, 0, 255 }, true):save_image(path))
    local view = terminal.open { cwd = context.link_folder, focus = true }
    local pane = panes.active()
    view.snapshot.mouse_tracking = true
    keymap.modkeys.ctrl = false
    for _, uri in ipairs({
      "file:///" .. path:gsub("\\", "/"):gsub(" ", "%%20"),
      "linked image.png",
    }) do
      view.session.hyperlink_uri = uri
      view:on_mouse_moved(7, 7, 0, 0)
      view:on_mouse_pressed("left", 7, 7)
      view:on_mouse_released("left", 7, 7)
      test.ok(overlay.is_open(), "image links must use the same overlay as drawn images")
      test.ok(common.path_equals(overlay.get_view().path, path))
      test.same({ overlay.get_view().image:get_size() }, { 80, 40 })
      test.equal(core.active_view, view)
      test.equal(pane.current_view, view)
      overlay.close()
    end
  end)

  test.it("detects plain HTTP text and clears its hover when Ctrl is released", function(context)
    local view = terminal.open()
    local normal_cursor = view.cursor
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
    test.equal(view.cursor, normal_cursor)
  end)

  test.it("covers every cell of a hyperlink that wraps to the next row", function(context)
    local view = terminal.open()
    local uri = "https://example.test/wrapped"
    -- The label fills the last 3 cells of row 0 and the first 5 cells of row 1.
    context.sessions[1].hyperlink = function(_, col, row)
      if (row == 0 and col >= view.cols - 3) or (row == 1 and col <= 4) then return uri end
    end
    local point = view:point_of_interest_at(2, 1)
    test.equal(point.uri, uri)
    test.same({ point.col, point.row, point.end_col, point.end_row }, { view.cols - 3, 0, 4, 1 })
    test.same(view:point_of_interest_at(view.cols - 1, 0), point)
  end)

  test.it("covers a hyperlink that its program wraps inside padded rows", function(context)
    local view = terminal.open()
    local session = context.sessions[1]
    local uri = "https://example.test/wrapped-label"
    -- Like Pi, the program ends the link at each row end and pads each row by 2 blank cells.
    local label_end = { [0] = view.cols - 3, [1] = 6, [2] = 6 }
    local text = { [2] = "x" }
    session.hyperlink = function(_, col, row)
      if label_end[row] and col >= 2 and col <= label_end[row] then return uri end
    end
    session.row_text = function(_, row)
      if not label_end[row] then return { text = "", columns = {}, generation = 1 } end
      local value = "  " .. string.rep("a", label_end[row] - 1)
      if text[row] then value = text[row] .. value:sub(2) end
      local columns = {}
      for index = 1, #value do columns[index] = index - 1 end
      return { text = value, columns = columns, generation = 1 }
    end
    local point = view:point_of_interest_at(3, 1)
    test.same({ point.col, point.row, point.end_col, point.end_row }, { 2, 0, 6, 1 })
    test.same(view:point_of_interest_at(5, 0), point)
    -- Text in the padding ends the link, so row 2 is a separate link.
    point = view:point_of_interest_at(3, 2)
    test.same({ point.col, point.row, point.end_col, point.end_row }, { 2, 2, 6, 2 })
  end)

  test.it("previews terminal images during mouse tracking but preserves drags and other program clicks", function(context)
    local overlay = require "core.image_overlay"
    local view = terminal.open()
    local session = context.sessions[1]
    local image = canvas.new(80, 40, { 255, 0, 0, 255 }, true)
    view.snapshot.images = {
      { canvas = image, x = 0, y = 0, width = 80, height = 40,
        z = 1, id = 1, placement_id = 1 },
    }
    view.snapshot.mouse_tracking = true
    keymap.modkeys.ctrl = false
    view:on_mouse_moved(7, 7, 0, 0)
    test.equal(view.cursor, "hand")
    local mouse_events_before_click = #session.mouse_events
    view:on_mouse_pressed("left", 7, 7)
    test.ok(not overlay.is_open())
    view:on_mouse_released("left", 7, 7)
    test.ok(overlay.is_open())
    test.equal(overlay.get_view().image, image)
    test.equal(#session.mouse_events, mouse_events_before_click,
      "Image clicks must not reach the terminal program")
    overlay.close()

    view:on_mouse_pressed("left", 7, 7)
    view:on_mouse_moved(7 + view.cell_width * 3, 7, view.cell_width * 3, 0)
    view:on_mouse_released("left", 7 + view.cell_width * 3, 7)
    test.ok(not overlay.is_open())
    test.equal(session.gesture_events[#session.gesture_events - 1][1], "drag")

    local outside_y = 7 + view.cell_height * 4
    view:on_mouse_moved(7, outside_y, 0, 0)
    test.equal(view.cursor, "arrow")
    view:on_mouse_pressed("left", 7, outside_y)
    view:on_mouse_released("left", 7, outside_y)
    test.ok(not overlay.is_open())
    test.equal(session.mouse_events[#session.mouse_events - 1][1], "press")
    test.equal(session.mouse_events[#session.mouse_events][1], "release")
    keymap.modkeys.ctrl = true
    view:on_mouse_pressed("left", 7, 7)
    view:on_mouse_released("left", 7, 7)
    test.ok(overlay.is_open())
  end)

  test.it("previews the complete image when the program shows only part of it", function(context)
    local overlay = require "core.image_overlay"
    local view = terminal.open()
    local complete = canvas.new(20, 60, { 255, 0, 0, 255 }, true)
    local visible = complete:copy(0, 0, 20, 20)
    context.sessions[1].images = { [7] = complete }
    view.snapshot.images = {
      { canvas = visible, x = 0, y = 0, width = 20, height = 20,
        z = 1, id = 7, placement_id = 1 },
    }
    keymap.modkeys.ctrl = false
    view:on_mouse_moved(10, 10, 0, 0)
    view:on_mouse_pressed("left", 10, 10)
    view:on_mouse_released("left", 10, 10)
    test.ok(overlay.is_open())
    test.same({ overlay.get_view().image:get_size() }, { 20, 60 })
    overlay.close()
  end)

  test.it("previews the top image only inside its bounds and cancels when it disappears", function()
    local overlay = require "core.image_overlay"
    local view = terminal.open()
    local back = canvas.new(20, 20, { 255, 0, 0, 255 }, true)
    local front = canvas.new(20, 20, { 0, 255, 0, 255 }, true)
    local scale = view.cell_width / view.native_cell_width
    view.snapshot.images = {
      { canvas = front, x = 10, y = 10, width = 20, height = 20,
        z = 2, id = 2, placement_id = 1 },
      { canvas = back, x = 10, y = 10, width = 20, height = 20,
        z = 1, id = 1, placement_id = 1 },
    }
    keymap.modkeys.ctrl = false
    view:on_mouse_moved(7, 7, 0, 0)
    test.equal(view.cursor, "arrow")
    local x, y = 7 + 15 * scale, 22
    view:on_mouse_moved(x, y, 0, 0)
    test.equal(view.cursor, "hand")
    view:on_mouse_pressed("left", x, y)
    view:on_mouse_released("left", x, y)
    test.equal(overlay.get_view().image, front)
    overlay.close()
    view:on_mouse_pressed("left", x, y)
    view.snapshot.images = {}
    view:on_mouse_released("left", x, y)
    test.ok(not overlay.is_open())
    view:on_mouse_moved(x, y, 0, 0)
    test.equal(view.cursor, "arrow")
  end)

  test.it("opens explicit links without Ctrl instead of sending the click to the program", function(context)
    local previous_open = system.open_in_system
    local opened = {}
    system.open_in_system = function(uri) opened[#opened + 1] = uri; return true end
    local view = terminal.open()
    local session = context.sessions[1]
    session.hyperlink_uri = "https://example.test/hidden-target"
    view.snapshot.mouse_tracking = true
    keymap.modkeys.ctrl = false
    view:on_mouse_moved(7, 7, 0, 0)
    test.equal(view.cursor, "hand")
    test.ok(not core.status_bar.tooltip_mode)
    view:on_mouse_pressed("left", 7, 7)
    local opened_on_press = #opened
    view:on_mouse_released("left", 7, 7)
    system.open_in_system = previous_open
    test.equal(opened_on_press, 0)
    test.same(opened, { session.hyperlink_uri })
    for _, event in ipairs(session.mouse_events) do test.equal(event[1], "motion") end
    session.hyperlink_uri = nil
    local text = "https://example.test/plain"
    local columns = {}
    for index = 1, #text do columns[index] = index - 1 end
    session.row_text_data = { text = text, columns = columns, generation = 1 }
    session.next_changed = true
    view:service_session(true)
    test.equal(view.hover_point, nil)
    test.equal(view.cursor, "arrow")
    test.ok(not core.status_bar.tooltip_mode)
  end)

  test.it("selects text when dragging from an explicit link without opening it", function(context)
    local previous_open = system.open_in_system
    local opened = 0
    system.open_in_system = function() opened = opened + 1; return true end
    local view = terminal.open()
    local session = context.sessions[1]
    session.hyperlink_uri = "https://example.test/path"
    view.snapshot.mouse_tracking = true
    keymap.modkeys.ctrl = false
    local x, y = 7, 7
    local end_x = x + view.cell_width * 3
    view:on_mouse_pressed("left", x, y)
    view:on_mouse_moved(end_x, y, end_x - x, 0)
    view:on_mouse_released("left", end_x, y)
    system.open_in_system = previous_open
    test.equal(opened, 0)
    test.equal(#session.mouse_events, 0)
    test.equal(session.gesture_events[1][1], "press")
    test.equal(session.gesture_events[2][1], "drag")
    test.equal(session.gesture_events[2][2], 3)
    test.equal(session.gesture_events[3][1], "release")
  end)

  test.it("keeps an explicit link target after Ctrl is released and clears it on leave", function(context)
    local view = terminal.open()
    context.sessions[1].hyperlink_uri = "https://example.test/hidden-target"
    keymap.modkeys.ctrl = true
    view:on_mouse_moved(7, 7, 0, 0)
    test.equal(view.hover_point.uri, "https://example.test/hidden-target")
    test.ok(not core.status_bar.tooltip_mode)
    keymap.modkeys.ctrl = false
    view:on_key_released("left ctrl", { scancode = 224 })
    test.equal(view.cursor, "hand")
    test.equal(view.hover_point.uri, "https://example.test/hidden-target")
    test.ok(not core.status_bar.tooltip_mode)
    view:on_mouse_left()
    test.ok(not core.status_bar.tooltip_mode)
  end)

  test.it("shows the hidden link destination only in a hover popup and removes it on leave", function(context)
    local view = terminal.open()
    view:update()
    local session = context.sessions[1]
    local uri = "https://example.test/" .. string.rep("long-path/", 16) .. "destination"
    session.hyperlink_uri = uri
    context.previous_time = system.get_time
    context.previous_defer_draw = core.root_panel.defer_draw
    local now = system.get_time()
    system.get_time = function() return now end
    -- Execute overlays at the renderer boundary, without drawing unrelated Views.
    core.root_panel.defer_draw = function(_, fn, ...) fn(...) end
    local function popup_text()
      local calls = draw_calls(function() view:draw() end)
      local text = {}
      for _, call in ipairs(calls.text) do text[#text + 1] = call[2] end
      return table.concat(text)
    end
    keymap.modkeys.ctrl = false
    local x, y = view.position.x + 7, view.position.y + 7
    view:on_mouse_moved(x, y, 0, 0)
    test.equal(popup_text(), "", "the popup appeared before the hover delay")
    test.ok(not core.status_bar.tooltip_mode, "the link target appeared in the Status Bar before the popup")
    now = now + 1
    view:update()
    test.equal(popup_text(), uri, "the popup did not show the complete destination")
    test.ok(not core.status_bar.tooltip_mode, "the link target appeared in both the popup and the Status Bar")
    view:on_mouse_left()
    test.equal(popup_text(), "", "the popup remained after the pointer left")
  end)

  test.it("shows no hover popup over an image", function(context)
    local view = terminal.open()
    view:update()
    context.previous_time = system.get_time
    context.previous_defer_draw = core.root_panel.defer_draw
    local now = system.get_time()
    system.get_time = function() return now end
    core.root_panel.defer_draw = function(_, fn, ...) fn(...) end
    local scale = view.cell_width / view.native_cell_width
    view.snapshot.images = {
      { canvas = canvas.new(20, 20, { 255, 0, 0, 255 }, true), x = 10, y = 10, width = 20, height = 20,
        z = 1, id = 1, placement_id = 1 },
    }
    keymap.modkeys.ctrl = false
    local x, y = view.position.x + 7 + 15 * scale, view.position.y + 22
    view:on_mouse_moved(x, y, 0, 0)
    test.equal(view.cursor, "hand")
    now = now + 1
    view:update()
    -- The test window cannot draw image canvases. The popup keeps its state from the hover.
    view.snapshot.images = {}
    local calls = draw_calls(function() view:draw() end)
    for _, call in ipairs(calls.text) do test.equal(call[2], nil, "a popup showed over the image") end
  end)

  test.it("keeps the link hover while terminal output changes", function(context)
    local view = terminal.open()
    local session = context.sessions[1]
    session.hyperlink_uri = "https://example.test/path"
    keymap.modkeys.ctrl = true
    view:on_mouse_moved(7, 7, 0, 0)
    session.next_changed = true
    view:service_session(true)
    test.equal(view.hover_point and view.hover_point.uri, "https://example.test/path")
    session.hyperlink_uri = nil
    session.next_changed = true
    view:service_session(true)
    test.equal(view.hover_point, nil)
    test.ok(not core.status_bar.tooltip_mode)
    keymap.modkeys.ctrl = false
    view:clear_point_hover()
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
    local x, y = 6 + view.cell_width * 5 + 1, 7
    keymap.modkeys.ctrl = false
    view:on_mouse_pressed("left", x, y)
    view:on_mouse_released("left", x, y)
    local opened_without_ctrl = opened
    keymap.modkeys.ctrl = true
    view:on_mouse_pressed("left", x, y)
    view:on_mouse_released("left", x, y)
    keymap.modkeys.ctrl = false

    core.open_file = previous_open
    system.get_file_info = previous_info
    test.equal(opened_without_ctrl, nil)
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
    test.ok(view:on_text_input("work"))
    view:update()

    panes.place(function() return Editor(Buffer(nil, nil, true)) end, {
      pane = pane, placement = "current", focus = true,
    })
    view:update_suspended()

    panes.focus(pane)
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
            { text = "ab", cells = "\1\1\1\1", col = 0, columns = 2, fg = 0xffffff },
            { text = "c界", cells = "\1\1\3\2", col = 2, columns = 3, fg = 0xff0000 },
            { text = "d", cells = "\1\1", col = 6, columns = 1, fg = 0x00ff00 },
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
    test.equal(calls.text[2][3], "\1\1\3\2")
    test.equal(calls.text[2][4], 6 + 2 * view.cell_width)
    test.equal(calls.text[2][6], view.cell_width)
    test.equal(calls.text[3][4], 6 + 6 * view.cell_width)
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
          text = "x", cells = "\1\1", col = 0, columns = 1, fg = 0xffffff,
          faint = true, overline = true, underline = 2,
          underline_color = 0xff0000,
        }},
        backgrounds = {},
      }},
      cursor = { visible = true, x = 2, y = 0, style = "hollow" },
    }
    local calls = draw_calls(function() view:draw() end)
    test.ok(#calls.rect >= 7)
    test.equal(calls.text[1][#calls.text[1]][4], 140)
  end)

  test.it("copies terminal text without a permission prompt", function(context)
    local view = terminal.open()
    context.previous_clipboard = system.get_clipboard() or ""
    context.previous_nag_show = core.nag_view.show
    local prompted = false
    core.nag_view.show = function() prompted = true end
    local previous_active_view = core.active_view
    local previous_flash_window = system.flash_window
    local flash_count = 0
    core.active_view = nil
    system.flash_window = function() flash_count = flash_count + 1 end
    view.snapshot.events = {
      { type = "bell" },
      { type = "clipboard", text = "terminal clipboard" },
    }
    view:handle_events()
    core.active_view = previous_active_view
    system.flash_window = previous_flash_window
    test.not_nil(require("core.tab").describe({current_view = view}, 1).terminal.bell, "The Tab does not report the bell")
    test.equal(flash_count, 0)
    test.equal(system.get_clipboard(), "terminal clipboard")
    test.ok(not prompted)
  end)

  test.it("applies later terminal clipboard writes and clear requests directly", function(context)
    local view = terminal.open()
    context.previous_clipboard = system.get_clipboard() or ""
    context.previous_nag_show = core.nag_view.show
    local prompted = false
    core.nag_view.show = function() prompted = true end

    view.snapshot.events = { { type = "clipboard", text = "first request" } }
    view:handle_events()
    test.equal(system.get_clipboard(), "first request")
    view.snapshot.events = { { type = "clipboard", text = "second request" } }
    view:handle_events()
    test.equal(system.get_clipboard(), "second request")
    view.snapshot.events = { { type = "clipboard", text = "", clear = true } }
    view:handle_events()
    test.equal(system.get_clipboard() or "", "")
    test.ok(not prompted)
  end)

  test.it("keeps a busy terminal live after the UI stops reading output", function(context)
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    terminal._set_native_for_tests(nil)
    local path = USERDIR .. PATHSEP .. "terminal-backpressure.txt"
    context.backpressure_path = path
    local file = assert(io.open(path, "wb"))
    local block = (string.rep("x", 78) .. "\r\n"):rep(1024)
    for _ = 1, 640 do assert(file:write(block)) end -- 50 MiB
    assert(file:close())
    local view = ready(terminal.open { cwd = system.getcwd(), shell = "cmd.exe /d /q" })
    test.ok(view and view.session)
    test.ok(view.session:write('type "' .. path .. '"\r'))
    local parsed_before = view.session:stats().output_bytes_parsed
    local resume_at = system.get_time() + 10
    while system.get_time() < resume_at do end -- Do not yield or drain the UI.
    local deadline = system.get_time() + 5
    repeat
      view:update()
      if view.state == "failed" then break end
      coroutine.yield(0.001)
    until system.get_time() >= deadline
    test.not_equal(view.state, "failed", view.launch_error)
    test.ok(view.session:stats().output_bytes_parsed > parsed_before,
      "terminal output did not resume")
  end)

  test.it("shows a failed terminal when its host process ends", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    terminal._set_native_for_tests(nil)
    local view = ready(terminal.open { cwd = system.getcwd(), shell = "cmd.exe /d /q" })
    test.ok(view and view.session)
    local stats = view.session:stats()
    test.ok(stats.host_pid and stats.host_pid > 0, "session has no host PID")
    test.ok(stats.shell_pid and stats.shell_pid > 0 and stats.shell_pid ~= stats.host_pid)
    local ffi = require "ffi"
    ffi.cdef [[
      void * __stdcall OpenProcess(unsigned long access, int inherit, unsigned long pid);
      int __stdcall TerminateProcess(void *process, unsigned int code);
      int __stdcall CloseHandle(void *handle);
    ]]
    local kernel = ffi.load("kernel32")
    local process = kernel.OpenProcess(1, 0, stats.host_pid)
    test.ok(process ~= nil)
    local ended = kernel.TerminateProcess(process, 99)
    kernel.CloseHandle(process)
    test.ok(ended ~= 0)
    local deadline = system.get_time() + 5
    repeat
      view:update()
      if view.state == "failed" then break end
      coroutine.yield(0.001)
    until system.get_time() >= deadline
    test.equal(view.state, "failed")
    test.contains(view.launch_error, "The Terminal Session process ended unexpectedly")
  end)

  test.it("closes the client without waiting for or killing a suspended host", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    terminal._set_native_for_tests(nil)
    local view = ready(terminal.open { cwd = system.getcwd(), shell = "cmd.exe /d /q" })
    test.ok(view and view.session)
    local ffi = require "ffi"
    ffi.cdef [[
      void * __stdcall OpenProcess(unsigned long access, int inherit, unsigned long pid);
      int __stdcall TerminateProcess(void *process, unsigned int code);
      int __stdcall CloseHandle(void *handle);
      unsigned long __stdcall WaitForSingleObject(void *handle, unsigned long milliseconds);
      long __stdcall NtSuspendProcess(void *process);
      long __stdcall NtResumeProcess(void *process);
    ]]
    local kernel, nt = ffi.load("kernel32"), ffi.load("ntdll")
    local process = kernel.OpenProcess(0x100801, 0, view.session:stats().host_pid)
    test.ok(process ~= nil)
    local ok, failure = pcall(function()
      test.equal(nt.NtSuspendProcess(process), 0)
      local started = system.get_time()
      view:on_close()
      -- Allow scheduling noise, but reject waiting seconds for a stopped host.
      test.ok(system.get_time() - started < 1,
        "closing the client waited for the suspended host")
      -- A stopped host cannot finish until the test resumes it.
      test.equal(kernel.WaitForSingleObject(process, 0), 258,
        "normal close killed the host instead of releasing the client")
    end)
    nt.NtResumeProcess(process)
    if kernel.WaitForSingleObject(process, 6000) == 258 then kernel.TerminateProcess(process, 1) end
    kernel.CloseHandle(process)
    if not ok then error(failure) end
  end)

  test.it("keeps the Pane as a blank Editor after typing exit in a real shell", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    terminal._set_native_for_tests(nil)
    local view = ready(terminal.open { cwd = system.getcwd(), shell = "cmd.exe /d /q" })
    test.ok(view and view.session)
    local pane = panes.pane_for_view(view)
    test.ok(view.session:write("exit\r"))
    local deadline = system.get_time() + 20
    repeat
      view:update()
      if pane.current_view ~= view then break end
      coroutine.yield(0.01)
    until system.get_time() >= deadline

    test.ok(panes.contains(pane))
    test.equal(panes.active(), pane)
    test.ok(pane.current_view:extends(Editor), "the exited Terminal stayed in its Pane")
    test.same(pane.current_view.buffer.lines, { "\n" })
    test.is_nil(view.session)
    test.is_nil(panes.pane_for_view(view))
    test.ok(panes.validate())
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
