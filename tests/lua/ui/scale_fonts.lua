local scale = require "plugins.scale"
local style = require "core.style"
local test = require "core.test"

test.describe("font scaling", function()
  test.after_each(function(context)
    if context.project_zoom_state ~= nil then
      scale.load_workspace_state(context.project_zoom_state)
    end
    if context.interface_scale then scale.set(context.interface_scale) end
    if context.code_scale then scale.set_code(context.code_scale) end
  end)

  test.it("stores Project Zoom only after a user change", function(context)
    context.project_zoom_state = scale.save_workspace_state() or false
    context.interface_scale = scale.get()
    context.code_scale = scale.get_code()

    scale.load_workspace_state(nil)
    test.is_nil(scale.save_workspace_state())

    scale.increase()
    local saved = test.not_nil(scale.save_workspace_state())
    test.equal(saved.interface, scale.get())
    test.equal(saved.code, scale.get_code())

    scale.reset()
    test.is_nil(scale.save_workspace_state())
  end)

  test.it("scales shared interface fallbacks once", function(context)
    context.interface_scale = scale.get()
    local factor = 1.1
    local fallback = style.font[2]
    local fallback_size = fallback:get_size()
    local prose_size = style.prose_font:get_size()
    local markdown_body_size = style.markdown_body_font:get_size()

    scale.set(context.interface_scale * factor)

    test.near(fallback:get_size(), fallback_size * factor, 0.001)
    test.near(style.prose_font:get_size(), prose_size * factor, 0.001)
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
end)
