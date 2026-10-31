local core = require "core"
local Buffer = require "core.buffer"
local config = require "core.config"
local context_menu = require "core.context_menu"
local Editor = require "core.editor"
local panes = require "core.panes"
local RootPanel = require "core.rootpanel"
local style = require "core.style"
local test = require "core.test"

local function render(root, window)
  local old_clip = core.clip_rect_stack[1]
  renderer.begin_frame(window)
  core.clip_rect_stack[1] = { 0, 0, 800, 600 }
  renderer.set_clip_rect(0, 0, 800, 600)
  local ok, err = pcall(root.draw, root)
  renderer.end_frame()
  core.clip_rect_stack[1] = old_clip
  test.ok(ok, err)
end

local function matches_color(a, b)
  if not a or not b then return false end
  for index = 1, 3 do
    if math.abs(a[index] - b[index]) > 12 then return false end
  end
  return true
end

local function defer_caret(root)
  root:defer_draw(function()
    root:submit_keyboard_caret {
      x = 20, y = 20, width = 4, height = 20,
      color = style.caret, owner = root, line = 1, col = 1,
    }
  end)
end

test.describe("Keyboard caret layers", function()
  local saved

  test.before_each(function(context)
    panes.reset_for_tests()
    saved = {
      active_view = core.active_view,
      buffer_registry = core.buffer_registry,
      set_active_view = core.set_active_view,
      root_panel = core.root_panel,
      animated_caret = config.animated_caret,
      transitions = config.transitions,
      caret_color = style.caret,
    }
    core.root_panel = RootPanel()
    core.root_panel.size.x, core.root_panel.size.y = 800, 600
    core.buffer_registry = nil
    core.set_active_view = function(view) core.active_view = view end
    config.animated_caret = true
    config.transitions = false
    style.caret = { 241, 17, 41, 255 }
    context.window = renwindow.create("caret-layers", 800, 600)
    local buffer = Buffer()
    buffer:insert(1, 1, "caret layer")
    context.editor = Editor(buffer)
    local pane = panes.create { factory = function() return context.editor end }
    panes.focus(pane)
    core.root_panel:update()
  end)

  test.after_each(function(context)
    context_menu.close()
    if context.window then renwindow.close(context.window) end
    panes.reset_for_tests()
    core.active_view = saved.active_view
    core.buffer_registry = saved.buffer_registry
    core.set_active_view = saved.set_active_view
    core.root_panel = saved.root_panel
    config.animated_caret = saved.animated_caret
    config.transitions = saved.transitions
    style.caret = saved.caret_color
  end)

  test.it("lets a Context Menu cover the keyboard caret", function(context)
    local root, window = core.root_panel, context.window
    local editor = context.editor
    local caret_x, caret_y = editor:get_caret_screen_position(1, 1)
    local x, y, width, height = editor:get_caret_rect(caret_x, caret_y, 1, 1)
    test.not_nil(x, "expected the editor caret to be visible")
    local sample_x = math.floor(x + width / 2)
    local sample_y = math.floor(y + height / 2)
    core.active_view = editor

    render(root, window)
    local caret_pixel = renwindow.get_color(window, sample_x, sample_y)
    test.ok(matches_color(caret_pixel, style.caret), "expected the keyboard caret to be visible")

    test.ok(context_menu.open(x - 4, y - 4, {
      { label = "Select All", command = "core:select_all" },
    }), "expected the Context Menu to open")
    render(root, window)

    local covered_pixel = renwindow.get_color(window, sample_x, sample_y)
    test.not_ok(matches_color(covered_pixel, style.caret),
      "the menu must cover the keyboard caret at their overlapping point")
  end)

  test.it("draws a focused popup caret above its popup", function(context)
    local root, window = core.root_panel, context.window
    local popup_color = { 24, 193, 120, 255 }
    core.active_view = nil
    root:defer_draw(function()
      renderer.draw_rect(10, 10, 60, 60, popup_color)
      root:submit_keyboard_caret {
        x = 20, y = 20, width = 4, height = 20,
        color = style.caret, owner = {},
      }
    end)

    render(root, window)

    local pixel = renwindow.get_color(window, 21, 21)
    test.ok(matches_color(pixel, style.caret), "the popup caret must remain visible over its background")
  end)
end)
