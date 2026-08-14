local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local test = require "core.test"

local fuzzy_searcher = require "plugins.fuzzy_searcher"

local function press_copy_shortcut()
  local previous_ctrl = keymap.modkeys.ctrl
  keymap.modkeys.ctrl = true
  local handled = keymap.on_key_pressed("c")
  keymap.modkeys.ctrl = previous_ctrl
  return handled
end

local function same_rgb(a, b)
  return a and b and a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
end

test.describe("Fuzzy Searcher selected-result copy", function()
  test.before_each(function(context)
    context.previous_clipboard = system.get_clipboard()
    context.previous_cursor_clipboard = core.cursor_clipboard
    context.previous_cursor_clipboard_whole_line = core.cursor_clipboard_whole_line
    system.set_clipboard("")
  end)

  test.after_each(function(context)
    if core.fuzzy_searcher_active_view then
      core.fuzzy_searcher_active_view:close()
    end
    system.set_clipboard(context.previous_clipboard or "")
    core.cursor_clipboard = context.previous_cursor_clipboard
    core.cursor_clipboard_whole_line = context.previous_cursor_clipboard_whole_line
  end)

  test.it("copies the selected result's main text", function()
    local picker = fuzzy_searcher.open_static_results("Results", {
      { kind = "command", label = "build:run", command = "build:run" },
      { kind = "grep", file = "src/main.c", line = 4, col = 3, text = "needle content" },
      { kind = "project", label = "C:/Projects/example", project = "C:/Projects/example" },
    })
    picker.selected = 2

    test.ok(command.perform("fuzzy-searcher:copy-selected"), "expected copy command to run")

    test.equal(system.get_clipboard(), "needle content")
    test.not_nil(picker.copy_flash, "expected copy feedback state")
    test.equal(picker.copy_flash.text, "needle content")
    test.equal(picker.copy_flash.result, picker.results[2])
    local feedback_color = picker:copy_flash_color(2)
    test.ok(feedback_color and feedback_color[4] > 0, "expected visible copy feedback")
    test.same({ feedback_color[1], feedback_color[2], feedback_color[3] }, {
      style.fuzzy_searcher_copy_feedback[1],
      style.fuzzy_searcher_copy_feedback[2],
      style.fuzzy_searcher_copy_feedback[3],
    })
    test.ok(feedback_color[4] <= style.fuzzy_searcher_copy_feedback[4], "expected feedback opacity to respect its theme color")
  end)

  test.it("draws copy feedback over fuzzy match highlights", function()
    local original_feedback_color = style.fuzzy_searcher_copy_feedback
    local probe_color = { 251, 2, 3, 255 }
    style.fuzzy_searcher_copy_feedback = probe_color

    local picker = fuzzy_searcher.open_static_results("Results", {
      { kind = "command", label = "text:copy", command = "text:copy", match_spans = { { 1, 3 } } },
    })
    test.ok(picker:copy_selected())
    picker:update()

    local original_draw_rect = renderer.draw_rect
    local original_draw_text = renderer.draw_text
    local original_draw_text_known_bounds = renderer.draw_text_known_bounds
    local original_set_clip_rect = renderer.set_clip_rect
    local draw_order = {}
    local draw_count = 0
    renderer.draw_rect = function(x, y, w, h, color)
      draw_count = draw_count + 1
      if same_rgb(color, style.selectionhighlight) and not draw_order.match then
        draw_order.match = draw_count
      end
      if same_rgb(color, probe_color) then draw_order.copy = draw_count end
    end
    renderer.draw_text = function(font, text, x)
      return x + (font and font:get_width(text) or 0)
    end
    renderer.draw_text_known_bounds = function() end
    renderer.set_clip_rect = function() end
    local ok, err = pcall(function() picker:draw() end)
    renderer.draw_rect = original_draw_rect
    renderer.draw_text = original_draw_text
    renderer.draw_text_known_bounds = original_draw_text_known_bounds
    renderer.set_clip_rect = original_set_clip_rect
    style.fuzzy_searcher_copy_feedback = original_feedback_color
    if not ok then error(err, 0) end

    test.not_nil(draw_order.match, "expected a fuzzy match highlight")
    test.not_nil(draw_order.copy, "expected a copy-feedback overlay")
    test.ok(draw_order.copy > draw_order.match, "expected copy feedback to overlay fuzzy matches")
  end)

  test.it("copies a prompt text selection before the selected result", function()
    fuzzy_searcher.open("")
    local picker = core.fuzzy_searcher_active_view
    picker.input:set_text("alpha beta", true)
    picker.results = {
      { kind = "file", label = "src/result.lua", file = "src/result.lua" },
    }
    picker.selected = 1

    test.ok(press_copy_shortcut(), "expected copy shortcut to be handled")

    test.equal(system.get_clipboard(), "alpha beta")
    test.equal(picker.copy_flash, nil)
  end)

  test.it("copies the selected result when the prompt has no text selection", function()
    fuzzy_searcher.open("")
    local picker = core.fuzzy_searcher_active_view
    picker.input:set_text("query")
    picker.results = {
      { kind = "file", label = "src/result.lua", file = "src/result.lua" },
    }
    picker.selected = 1

    test.ok(press_copy_shortcut(), "expected copy shortcut to be handled")

    test.equal(system.get_clipboard(), "src/result.lua")
    test.not_nil(picker.copy_flash, "expected selected-result copy feedback")
  end)

  test.it("copies file result text as external clipboard text", function()
    core.cursor_clipboard = { full = "src/app.lua", [1] = "stale structured clipboard" }
    core.cursor_clipboard_whole_line = { true }

    local picker = fuzzy_searcher.open_static_results("Results", {
      { kind = "file", label = "src/app.lua", file = "src/app.lua" },
    })

    test.ok(command.perform("fuzzy-searcher:copy-selected"), "expected copy command to run")

    test.equal(system.get_clipboard(), "src/app.lua")
    test.same(core.cursor_clipboard, {})
    test.same(core.cursor_clipboard_whole_line, {})
    test.equal(picker.copy_flash.text, "src/app.lua")
  end)
end)
