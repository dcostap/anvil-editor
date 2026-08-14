local core = require "core"
local config = require "core.config"
local test = require "core.test"

test.describe("Global Prompt Bar pointer interception", function()
  test.it("routes pointer movement when no View owns focus", function()
    local active = core.active_view
    core.active_view = nil
    local ok, err = pcall(core.root_panel.on_mouse_moved, core.root_panel, 0, 0, 0, 0)
    core.active_view = active
    test.ok(ok, err)
  end)
end)

local function capture_overlay_rects()
  local rects = {}
  local alphas = {}
  local root = core.root_panel
  local old_draw_rect = renderer.draw_rect
  local old_draw_text = renderer.draw_text
  local old_draw_text_known_bounds = renderer.draw_text_known_bounds
  local old_set_clip_rect = renderer.set_clip_rect
  local old_draw_app_overlay = root.draw_app_overlay
  local drawing_overlay = false
  renderer.draw_rect = function(x, y, w, h, color)
    if drawing_overlay then
      rects[#rects + 1] = { x = x, y = y, w = w, h = h }
    end
  end
  renderer.draw_text = function(font, text, x)
    return x + font:get_width(text)
  end
  renderer.draw_text_known_bounds = function(_, _, x, _, _, _, w)
    return x + w
  end
  renderer.set_clip_rect = function() end
  root.draw_app_overlay = function(self, color, ...)
    alphas[#alphas + 1] = color[4]
    drawing_overlay = true
    local result = old_draw_app_overlay(self, color, ...)
    drawing_overlay = false
    return result
  end

  local ok, err = pcall(function()
    root:draw_active_app_overlay()
  end)
  renderer.draw_rect = old_draw_rect
  renderer.draw_text = old_draw_text
  renderer.draw_text_known_bounds = old_draw_text_known_bounds
  renderer.set_clip_rect = old_set_clip_rect
  root.draw_app_overlay = old_draw_app_overlay
  if not ok then error(err, 0) end
  return rects, alphas
end

test.describe("Global Prompt Bar attention overlay", function()
  test.before_each(function(context)
    local bar = core.global_prompt_bar
    bar:exit(true)
    context.active_view = core.active_view
    context.transitions_disabled = config.disabled_transitions.global_prompt_bar
    context.statusbar_transitions_disabled = config.disabled_transitions.statusbar
    config.disabled_transitions.global_prompt_bar = true
    config.disabled_transitions.statusbar = true

    bar:enter("Attention", { show_suggestions = false })
    core.root_panel:update()
  end)

  test.after_each(function(context)
    config.disabled_transitions.global_prompt_bar = true
    config.disabled_transitions.statusbar = true
    core.root_panel.deferred_draws = {}
    core.global_prompt_bar:exit(true)
    if context.active_view then core.set_active_view(context.active_view) end
    core.root_panel:update()
    config.disabled_transitions.global_prompt_bar = context.transitions_disabled
    config.disabled_transitions.statusbar = context.statusbar_transitions_disabled
  end)

  test.it("dims the app around the focused prompt without dimming the prompt", function(context)
    local root = core.root_panel
    local bar = core.global_prompt_bar
    local root_bottom = root.position.y + root.size.y
    local bar_bottom = bar.position.y + bar.size.y
    local expected = {
      { x = root.position.x, y = root.position.y, w = root.size.x,
        h = math.max(0, bar.position.y - root.position.y) },
      { x = root.position.x, y = bar_bottom, w = root.size.x,
        h = math.max(0, root_bottom - bar_bottom) },
    }

    local rects = capture_overlay_rects()
    local visible_expected = {}
    for _, rect in ipairs(expected) do
      if rect.h > 0 then visible_expected[#visible_expected + 1] = rect end
    end

    test.same(rects, visible_expected)

    core.set_active_view(context.active_view)
    bar:update()
    core.root_panel:update_app_overlay()
    test.equal(#capture_overlay_rects(), 0)
  end)

  test.it("replaces the Status Bar at the bottom of the app", function()
    local root = core.root_panel
    local bar = core.global_prompt_bar

    test.equal(core.status_bar.size.y, 0)
    test.equal(bar.position.y + bar.size.y, root.position.y + root.size.y)
  end)

end)
