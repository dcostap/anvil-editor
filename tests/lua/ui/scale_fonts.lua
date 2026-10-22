local core = require "core"
local scale = require "plugins.scale"
local style = require "core.style"
local test = require "core.test"

test.describe("font scaling", function()
  test.after_each(function(context)
    if context.original_status_message then
      core.status_bar.show_message = context.original_status_message
    end
    if context.default_scale then DEFAULT_SCALE = context.default_scale end
    if context.interface_scale then scale.set(context.interface_scale) end
    if context.code_scale then scale.set_code(context.code_scale) end
  end)

  test.it("applies a Zoom that another Project reports", function(context)
    context.interface_scale = scale.get()
    context.code_scale = scale.get_code()
    scale.set(DEFAULT_SCALE)
    scale.set_code(DEFAULT_SCALE)
    scale.increase()
    scale.increase_code()
    local interface, code = scale.get(), scale.get_code()

    -- Another process starts at the display scale, then the shell reports the saved Zoom.
    scale.set(DEFAULT_SCALE)
    scale.set_code(DEFAULT_SCALE)
    core.on_event("zoomchanged", interface / DEFAULT_SCALE, code / DEFAULT_SCALE)

    test.near(scale.get(), interface, 0.000001)
    test.near(scale.get_code(), code, 0.000001)
  end)

  test.it("keeps a saved Zoom relative to the display scale", function(context)
    context.interface_scale = scale.get()
    context.code_scale = scale.get_code()
    context.default_scale = DEFAULT_SCALE
    DEFAULT_SCALE = 1
    scale.set(1)
    scale.set_code(1)
    scale.increase()
    local ratio = scale.get()

    -- A process on a display at twice the scale.
    DEFAULT_SCALE = 2
    scale.set(2)
    scale.set_code(2)
    core.on_event("zoomchanged", ratio, ratio)

    test.near(scale.get(), 2 * ratio, 0.000001)
    test.near(scale.get_code(), 2 * ratio, 0.000001)
  end)

  test.it("scales shared interface fallbacks once", function(context)
    context.interface_scale = scale.get()
    local factor = 1.1
    local fallback = style.font[2]
    local fallback_size = fallback:get_size()
    local view_text_size = style.view_text_font:get_size()
    local markdown_body_size = style.markdown_body_font:get_size()

    scale.set(context.interface_scale * factor)

    test.near(fallback:get_size(), fallback_size * factor, 0.001)
    test.near(style.view_text_font:get_size(), view_text_size * factor, 0.001)
    test.near(style.markdown_body_font:get_size(), markdown_body_size * factor, 0.001)
  end)

  test.it("scales terminal fonts with code fonts", function(context)
    context.code_scale = scale.get_code()
    local factor = 1.1
    local code_size = style.code_font:get_size()
    local terminal_size = style.terminal_font:get_size()
    local fallback = style.code_font[2]
    local fallback_size = fallback:get_size()

    scale.set_code(context.code_scale * factor)

    test.near(style.code_font:get_size(), code_size * factor, 0.001)
    test.near(style.terminal_font:get_size(), terminal_size * factor, 0.001)
    test.near(fallback:get_size(), fallback_size * factor, 0.001)
  end)

  test.it("moves global zoom by one logical font point", function(context)
    context.interface_scale = scale.get()
    context.code_scale = scale.get_code()

    scale.set(DEFAULT_SCALE)
    scale.set_code(DEFAULT_SCALE)
    local ui_size = style.font:get_size()
    local code_size = style.code_font:get_size()

    scale.increase()

    test.near(style.font:get_size(), ui_size + DEFAULT_SCALE, 0.001)
    test.near(style.code_font:get_size(), code_size + DEFAULT_SCALE, 0.001)
  end)

  test.it("takes larger Zoom steps at large font sizes", function(context)
    context.interface_scale = scale.get()
    context.code_scale = scale.get_code()
    scale.set(DEFAULT_SCALE * 3)
    scale.set_code(DEFAULT_SCALE * 3)
    local size = style.code_font:get_size()

    scale.increase()
    test.ok(style.code_font:get_size() - size >= 2 * DEFAULT_SCALE - 0.001,
      "a step at three times the default size added only one point")
    scale.decrease()

    test.near(style.code_font:get_size(), size, 0.001)
  end)

  test.it("returns to the default size after the same number of Zoom steps out", function(context)
    context.interface_scale = scale.get()
    context.code_scale = scale.get_code()
    scale.set(DEFAULT_SCALE)
    scale.set_code(DEFAULT_SCALE)
    local size = style.code_font:get_size()

    for _ = 1, 15 do scale.increase() end
    for _ = 1, 15 do scale.decrease() end

    test.near(style.code_font:get_size(), size, 0.001)
  end)

  test.it("reports the new font size after global zoom", function(context)
    context.interface_scale = scale.get()
    context.code_scale = scale.get_code()
    context.original_status_message = core.status_bar.show_message
    local message
    core.status_bar.show_message = function(_, _, _, text)
      message = text
    end

    scale.set(DEFAULT_SCALE)
    scale.set_code(DEFAULT_SCALE)
    scale.increase()

    test.equal(message, "Font size: 15")
  end)

  test.it("restores Fuzzy Search row spacing after a theme change while zoomed", function(context)
    context.interface_scale = scale.get()
    local row_padding = style.fuzzy_searcher_result_row_padding

    scale.set(context.interface_scale * 1.1)
    core.reload_module "colors.default"
    scale.set(context.interface_scale)

    test.near(style.fuzzy_searcher_result_row_padding, row_padding, 0.001)
  end)
end)
