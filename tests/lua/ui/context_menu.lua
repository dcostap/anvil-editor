local core = require "core"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local command = require "core.command"
local context_menu = require "core.context_menu"
local linewrapping = require "core.linewrapping"
local markdown = require "core.markdown"
local markdown_model = require "core.markdown.model"
local panes = require "core.panes"
local test = require "core.test"
local worker_pool = require "core.worker_pool"

-- Waits until the Markdown model of the view is ready.
local function refresh_markdown(view)
  markdown.live_render.refresh_view(view)
  local instance = markdown_model.peek(view.buffer)
  local deadline = system.get_time() + 10
  while instance and instance.status ~= "ready" and system.get_time() < deadline do
    local pool = worker_pool.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if instance.status ~= "ready" then system.sleep(0.001) end
  end
  test.equal(test.not_nil(instance).status, "ready", instance.reason)
  linewrapping.complete_async_reconstruction(view)
end

local function open_editor(text, filename)
  local buffer = Buffer()
  if filename then buffer:set_filename(filename, filename) end
  buffer:insert(1, 1, text)
  buffer:set_selection(1, 1)
  local pane = panes.create { factory = function() return Editor(buffer) end }
  panes.focus(pane)
  core.root_panel:update()
  return pane.current_view
end

-- The screen point of a Buffer position, a little inside its character.
local function point(view, line, col)
  local x, y = view:get_line_screen_position(line, col)
  return x + 1, y + view:get_line_height() / 2
end

local function right_click(x, y)
  core.on_event("mousepressed", "right", x, y, 1)
  core.on_event("mousereleased", "right", x, y)
end

local function contains(list, wanted)
  for _, value in ipairs(list) do
    if value == wanted then return true end
  end
  return false
end

test.describe("Context Menu", function()
  local saved

  test.before_each(function()
    panes.reset_for_tests()
    saved = {
      set_active_view = core.set_active_view, buffer_registry = core.buffer_registry,
      get_clipboard = system.get_clipboard, set_clipboard = system.set_clipboard,
      size = { core.root_panel.size.x, core.root_panel.size.y },
    }
    core.buffer_registry = nil
    core.set_active_view = function(view) core.active_view = view end
    core.root_panel.size.x, core.root_panel.size.y = 800, 600
    local clipboard = ""
    system.get_clipboard = function() return clipboard end
    system.set_clipboard = function(text) clipboard = text end
  end)

  test.after_each(function()
    context_menu.close()
    panes.reset_for_tests()
    core.set_active_view = saved.set_active_view
    core.buffer_registry = saved.buffer_registry
    system.get_clipboard, system.set_clipboard = saved.get_clipboard, saved.set_clipboard
    core.root_panel.size.x, core.root_panel.size.y = saved.size[1], saved.size[2]
  end)

  test.it("pastes at the right-clicked place when Paste is chosen", function()
    local view = open_editor("alpha beta")
    system.set_clipboard("X")
    right_click(point(view, 1, 7))
    test.ok(context_menu.is_open())
    -- Type ahead selects Paste; Enter runs it.
    core.on_event("keypressed", "p", {})
    test.equal(context_menu.selected_label(), "Paste")
    core.on_event("keypressed", "return", {})
    test.ok(not context_menu.is_open())
    test.equal(view.buffer:get_text(1, 1, 1, math.huge), "alpha Xbeta")
  end)

  test.it("keeps the selection for a right-click inside it", function()
    local view = open_editor("alpha beta")
    view.buffer:set_selection(1, 1, 1, 6)
    right_click(point(view, 1, 3))
    test.ok(context_menu.choose("Copy"))
    test.equal(system.get_clipboard(), "alpha")
  end)

  test.it("does not show editing items for a read-only Buffer", function()
    local view = open_editor("alpha")
    view.buffer.read_only = true
    right_click(point(view, 1, 2))
    local labels = context_menu.labels()
    test.ok(contains(labels, "Copy"))
    test.ok(not contains(labels, "Cut"))
    test.ok(not contains(labels, "Paste"))
  end)

  test.it("opens no menu for a right-click left of the reading lane, such as on the heading outline", function()
    core.root_panel.size.x = 1400
    local view = open_editor("# One\n\nalpha\n\n## Two\n\nbeta", "note.md")
    refresh_markdown(view)
    core.root_panel:update()
    view.buffer:set_selection(3, 2)
    local text_x, y = point(view, 5, 1)
    test.ok(text_x > view.position.x + 100, "the note has a margin left of its lane")
    right_click(view.position.x + 20, y)
    test.ok(not context_menu.is_open())
    test.same({ view.buffer:get_selection() }, { 3, 2, 3, 2 })
  end)

  test.it("opens no menu for a right-click on the gutter", function()
    local view = open_editor("alpha\nbeta")
    test.ok(view:get_gutter_width() > 0)
    local _, y = point(view, 2, 1)
    right_click(view.position.x + 2, y)
    test.ok(not context_menu.is_open())
  end)

  test.it("opens no menu for a right-click on the scrollbar", function()
    local view = open_editor(string.rep("alpha\n", 400))
    view:update()
    local y = view.position.y + view.size.y / 2
    local x = view.position.x + view.size.x
    while x > view.position.x and not view:scrollbar_overlaps_point(x, y) do x = x - 1 end
    test.ok(view:scrollbar_overlaps_point(x, y), "the view shows a scrollbar")
    right_click(x, y)
    test.ok(not context_menu.is_open())
  end)

  test.it("closes with Escape without running a command", function()
    local view = open_editor("alpha")
    system.set_clipboard("X")
    right_click(point(view, 1, 2))
    core.on_event("keypressed", "escape", {})
    test.ok(not context_menu.is_open())
    test.equal(view.buffer:get_text(1, 1, 1, math.huge), "alpha")
  end)

  test.it("opens from the keyboard at the caret", function()
    local view = open_editor("alpha")
    test.ok(command.perform("core:show_context_menu"))
    test.ok(context_menu.is_open())
    test.ok(contains(context_menu.labels(), "Select All"))
  end)

  test.it("keeps the caret where it is when opened from the keyboard", function()
    local view = open_editor("alpha\nbeta\ngamma")
    view.buffer:set_selection(1, 3)
    test.ok(command.perform("core:show_context_menu"))
    test.ok(context_menu.is_open())
    test.same({ view.buffer:get_selection() }, { 1, 3, 1, 3 })
  end)

  test.it("formats selected Markdown text instead of offering code commands", function()
    local view = open_editor("say hello", "note.md")
    view.buffer:set_selection(1, 5, 1, 10)
    right_click(point(view, 1, 7))
    test.ok(not contains(context_menu.labels(), "Go to Definition"))
    test.ok(context_menu.choose("Bold"))
    test.equal(view.buffer:get_text(1, 1, 1, math.huge), "say **hello**")
  end)

  test.it("inserts a table at the caret from the Insert submenu", function()
    local view = open_editor("Intro\n\n", "note.md")
    view.buffer:set_selection(3, 1)
    refresh_markdown(view)
    test.ok(command.perform("core:show_context_menu"))
    test.ok(context_menu.choose("Insert"))
    test.ok(context_menu.choose("Table"))
    test.ok(table.concat(view.buffer.lines):find("|", 1, true), "no table was inserted")
  end)

  test.it("makes the caret's line a heading from the Paragraph submenu", function()
    local view = open_editor("Title", "note.md")
    view.buffer:set_selection(1, 3)
    test.ok(command.perform("core:show_context_menu"))
    test.ok(context_menu.choose("Paragraph"))
    test.ok(context_menu.choose("Heading 2"))
    test.equal(view.buffer:get_text(1, 1, 1, math.huge), "## Title")
  end)

  test.it("runs a Markdown table command from the Table submenu", function()
    local view = open_editor("| a | b |\n| - | - |\n| 1 | 2 |\n", "note.md")
    view.buffer:set_selection(3, 3)
    refresh_markdown(view)
    test.ok(command.perform("core:show_context_menu"))
    test.ok(contains(context_menu.labels(), "Table"))
    test.ok(context_menu.choose("Table"))
    test.ok(context_menu.choose("Insert Row Below"))
    test.equal(#view.buffer.lines, 5)
  end)

  test.it("glides the highlight to the next row like other lists", function()
    local config = require "core.config"
    local style = require "core.style"
    local saved_transitions = config.transitions
    config.transitions = true
    command.add(nil, {
      ["context_menu_test:first_item"] = function() end,
      ["context_menu_test:second_item"] = function() end,
    })
    context_menu.open(20, 20, {
      { label = "One", command = "context_menu_test:first_item" },
      { label = "Two", command = "context_menu_test:second_item" },
    })
    -- Draws one frame and returns the top of the drawn selection highlight.
    local window = renwindow.create("context-menu-highlight", 800, 600)
    local function highlight_top()
      local top
      local draw_rounded_rect = renderer.draw_rounded_rect
      renderer.draw_rounded_rect = function(x, y, w, h, radius, color, ...)
        if color and color[1] == style.card_selection[1] and color[2] == style.card_selection[2]
          and color[3] == style.card_selection[3] then top = y end
        return draw_rounded_rect(x, y, w, h, radius, color, ...)
      end
      local old_clip = core.clip_rect_stack[1]
      renderer.begin_frame(window)
      core.clip_rect_stack[1] = { 0, 0, 800, 600 }
      renderer.set_clip_rect(0, 0, 800, 600)
      local ok, err = pcall(context_menu.draw)
      renderer.end_frame()
      core.clip_rect_stack[1] = old_clip
      renderer.draw_rounded_rect = draw_rounded_rect
      if not ok then error(err, 0) end
      return top
    end
    local ok, err = pcall(function()
      core.on_event("keypressed", "down", {})
      local first
      for _ = 1, 120 do first = highlight_top() end
      core.on_event("keypressed", "down", {})
      local moving = highlight_top()
      for _ = 1, 120 do highlight_top() end
      local second = highlight_top()
      test.ok(second > first)
      test.ok(moving > first and moving < second,
        string.format("expected the highlight between %s and %s, got %s", first, second, moving))
    end)
    config.transitions = saved_transitions
    if not ok then error(err, 0) end
  end)
end)
