local core = require "core"
local config = require "core.config"
local style = require "core.style"
local test = require "core.test"

local function capture_overlay_rects()
  local rects = {}
  local old_draw_rect = renderer.draw_rect
  local old_draw_text = renderer.draw_text
  local old_draw_text_known_bounds = renderer.draw_text_known_bounds
  local old_set_clip_rect = renderer.set_clip_rect
  renderer.draw_rect = function(x, y, w, h, color)
    if color == style.global_prompt_bar_overlay_background then
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

  local ok, err = pcall(function()
    local root = core.root_panel
    root.deferred_draws = {}
    core.global_prompt_bar:draw()
    while #root.deferred_draws > 0 do
      local draw = table.remove(root.deferred_draws)
      draw.fn(table.unpack(draw))
    end
  end)
  renderer.draw_rect = old_draw_rect
  renderer.draw_text = old_draw_text
  renderer.draw_text_known_bounds = old_draw_text_known_bounds
  renderer.set_clip_rect = old_set_clip_rect
  if not ok then error(err, 0) end
  return rects
end

test.describe("Global Prompt Bar attention overlay", function()
  test.before_each(function(context)
    local bar = core.global_prompt_bar
    bar:exit(true)
    context.active_view = core.active_view
    context.transitions_disabled = config.disabled_transitions.global_prompt_bar
    config.disabled_transitions.global_prompt_bar = true

    bar:enter("Attention", { show_suggestions = false })
    core.root_panel:update()
  end)

  test.after_each(function(context)
    core.root_panel.deferred_draws = {}
    core.global_prompt_bar:exit(true)
    config.disabled_transitions.global_prompt_bar = context.transitions_disabled
    if context.active_view then core.set_active_view(context.active_view) end
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
    test.equal(#capture_overlay_rects(), 0)
  end)
end)
