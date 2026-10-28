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
end)
