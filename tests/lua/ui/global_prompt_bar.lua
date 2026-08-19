local core = require "core"
local config = require "core.config"
local style = require "core.style"
local test = require "core.test"

test.describe("Global Prompt Bar drawing", function()
  test.it("does not draw a current-line highlight while hidden", function()
    local bar = core.global_prompt_bar
    bar:exit(true)
    bar.size.y = 0

    local old_rect = renderer.draw_rect
    local old_rounded_rect = renderer.draw_rounded_rect
    local old_text = renderer.draw_text
    local old_push = core.push_clip_rect
    local old_pop = core.pop_clip_rect
    local highlights = 0
    renderer.draw_rect = function(_, _, _, _, color)
      if color == style.line_highlight then highlights = highlights + 1 end
    end
    renderer.draw_rounded_rect = function() end
    renderer.draw_text = function(font, text, x)
      return x + (font and font:get_width(text) or 0)
    end
    core.push_clip_rect = function() end
    core.pop_clip_rect = function() end

    local ok, err = pcall(function() bar:draw() end)
    renderer.draw_rect = old_rect
    renderer.draw_rounded_rect = old_rounded_rect
    renderer.draw_text = old_text
    core.push_clip_rect = old_push
    core.pop_clip_rect = old_pop
    if not ok then error(err, 0) end

    test.equal(highlights, 0)
  end)
end)

test.describe("Global Prompt Bar pointer interception", function()
  test.it("routes pointer movement when no View owns focus", function()
    local active = core.active_view
    core.active_view = nil
    local ok, err = pcall(core.root_panel.on_mouse_moved, core.root_panel, 0, 0, 0, 0)
    core.active_view = active
    test.ok(ok, err)
  end)

  test.it("records the input event that moves focus away", function()
    local bar = core.global_prompt_bar
    bar:exit(true)
    local target = core.panes.active().current_view
    bar:enter("Focus", { show_suggestions = false })
    core.root_panel:update()
    local first_log = #core.log_items + 1

    local x = target.position.x + math.min(5, target.size.x / 2)
    local y = target.position.y + math.min(5, target.size.y / 2)
    core.on_event("mousepressed", "left", x, y, 1)
    core.on_event("mousereleased", "left", x, y, 1)

    local focus_log
    for index = first_log, #core.log_items do
      local text = core.log_items[index].text
      if text:find("Focus change:", 1, true) then focus_log = text end
    end
    test.ok(focus_log, "expected a focus-change diagnostic")
    test.ok(focus_log:find("event=mousepressed", 1, true), focus_log)
    test.ok(focus_log:find("button=left", 1, true), focus_log)
    test.ok(focus_log:find("target=", 1, true), focus_log)
    bar:exit(true)
  end)
end)

test.describe("Global Prompt Bar typeahead", function()
  test.it("completes a suggestion without matching letter case", function()
    local bar = core.global_prompt_bar
    bar:exit(true)
    local previous_view = core.active_view
    local ok, err = pcall(function()
      bar:enter("Open File", {
        suggest = function()
          return { "Coding-Conventions.md" }
        end,
      })
      bar:on_text_input("coding")
      bar:update()

      test.equal(bar:get_text(), "Coding-Conventions.md")
      local line1, col1, line2, col2 = bar.buffer:get_selection()
      test.equal(line1, 1)
      test.equal(col1, #"coding" + 1)
      test.equal(line2, 1)
      test.equal(col2, #"Coding-Conventions.md" + 1)
    end)
    bar:exit(true)
    if previous_view then core.set_active_view(previous_view) end
    if not ok then error(err, 0) end
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
    local bar_bottom = core.status_bar.position.y + core.status_bar.size.y
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

  test.it("stacks above the Status Bar at the bottom of the app", function()
    local root = core.root_panel
    local bar = core.global_prompt_bar
    local status = core.status_bar

    test.ok(status.size.y > 0)
    test.equal(bar.position.y + bar.size.y, status.position.y)
    test.equal(status.position.y + status.size.y, root.position.y + root.size.y)
  end)

end)
