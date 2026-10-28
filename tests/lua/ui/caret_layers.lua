local core = require "core"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local config = require "core.config"
local context_menu = require "core.context_menu"
local panes = require "core.panes"
local style = require "core.style"
local test = require "core.test"

-- Draws one frame and returns the order of the caret and the marked layers above the editor.
local function draw_order(mark_popup)
  local root = core.root_panel
  local order = {}
  local caret = root.caret_renderer
  local caret_draw, menu_draw = caret.draw, context_menu.draw
  caret.draw = function(self, ...)
    if self.target then order[#order + 1] = "caret" end
    return caret_draw(self, ...)
  end
  context_menu.draw = function()
    if context_menu.is_open() then order[#order + 1] = "menu" end
    return menu_draw()
  end
  if mark_popup then
    -- Like a card that a View draws above other Views, with its own text field.
    root:defer_draw(function()
      order[#order + 1] = "popup"
      root:submit_keyboard_caret { x = 20, y = 20, width = 2, height = 14, color = style.caret, owner = order }
    end)
  end
  local window = renwindow.create("caret-layers", 800, 600)
  local old_clip = core.clip_rect_stack[1]
  renderer.begin_frame(window)
  core.clip_rect_stack[1] = { 0, 0, 800, 600 }
  renderer.set_clip_rect(0, 0, 800, 600)
  local ok, err = pcall(root.draw, root)
  renderer.end_frame()
  core.clip_rect_stack[1] = old_clip
  caret.draw, context_menu.draw = nil, menu_draw
  assert(ok, err)
  return order
end

test.describe("Keyboard caret layers", function()
  local saved

  test.before_each(function()
    panes.reset_for_tests()
    saved = {
      set_active_view = core.set_active_view, buffer_registry = core.buffer_registry,
      animated_caret = config.animated_caret, size = { core.root_panel.size.x, core.root_panel.size.y },
    }
    core.buffer_registry = nil
    core.set_active_view = function(view) core.active_view = view end
    config.animated_caret = true
    core.root_panel.size.x, core.root_panel.size.y = 800, 600
    local buffer = Buffer()
    buffer:insert(1, 1, "alpha beta")
    local pane = panes.create { factory = function() return Editor(buffer) end }
    panes.focus(pane)
    core.root_panel:update()
  end)

  test.after_each(function()
    context_menu.close()
    panes.reset_for_tests()
    core.set_active_view = saved.set_active_view
    core.buffer_registry = saved.buffer_registry
    config.animated_caret = saved.animated_caret
    core.root_panel.size.x, core.root_panel.size.y = saved.size[1], saved.size[2]
  end)

  test.it("draws the editor's caret below an open Context Menu", function()
    context_menu.open(20, 20, { { label = "Select All", command = "core:select_all" } })
    test.same(draw_order(), { "caret", "menu" })
  end)

  test.it("draws the caret of a focused popup above that popup", function()
    -- The popup's text field has keyboard focus, so the editor submits no caret.
    core.active_view = nil
    local order = draw_order(true)
    test.equal(order[1], "popup")
    test.equal(order[2], "caret", "the popup's own caret must draw above the popup")
  end)
end)
