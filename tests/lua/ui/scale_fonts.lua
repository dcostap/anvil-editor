local scale = require "plugins.scale"
local style = require "core.style"
local test = require "core.test"

test.describe("font scaling", function()
  test.after_each(function(context)
    if context.interface_scale then scale.set(context.interface_scale) end
    if context.code_scale then scale.set_code(context.code_scale) end
  end)

  test.it("scales shared interface fallbacks once", function(context)
    context.interface_scale = scale.get()
    local factor = 1.1
    local fallback = style.font[2]
    local fallback_size = fallback:get_size()
    local prose_size = style.prose_font:get_size()

    scale.set(context.interface_scale * factor)

    test.near(fallback:get_size(), fallback_size * factor, 0.001)
    test.near(style.prose_font:get_size(), prose_size * factor, 0.001)
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
end)
