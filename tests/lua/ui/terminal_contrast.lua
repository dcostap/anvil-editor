local config = require "core.config"
local command = require "core.command"
local core = require "core"
local settings = require "plugins.settings"
local test = require "core.test"
local terminal = require "plugins.terminal"

local function fake_session(context)
  local session = {
    image = {
      rows = {}, cols = 80, row_count = 24,
      foreground = 0x080808, background = 0xffffff,
      cursor = { visible = false }, events = {},
    },
  }
  function session:snapshot() return self.image end
  function session:set_colors(colors) self.colors = colors; return true end
  function session:resize() return true end
  function session:focus() return true end
  function session:update() return false, { kind = "running", revision = 1 } end
  function session:close() end
  terminal._set_native_for_tests({
    new = function(options) session.options = options; return session end,
  })
  context.view = terminal.TerminalView { cwd = system.getcwd() }
  return session, context.view
end

local function record_draw(view)
  local old_text, old_known, old_rect = renderer.draw_text, renderer.draw_text_known_bounds, renderer.draw_rect
  local old_rounded = renderer.draw_rounded_rect
  local calls = { text = {}, rect = {} }
  renderer.draw_text = function(...) calls.text[#calls.text + 1] = { ... } end
  renderer.draw_text_known_bounds = renderer.draw_text
  renderer.draw_rect = function(...) calls.rect[#calls.rect + 1] = { ... } end
  renderer.draw_rounded_rect = function(...) calls.rect[#calls.rect + 1] = { ... } end
  local ok, err = pcall(function() view:draw() end)
  renderer.draw_text, renderer.draw_text_known_bounds, renderer.draw_rect = old_text, old_known, old_rect
  renderer.draw_rounded_rect = old_rounded
  if not ok then error(err) end
  return calls
end

test.describe("Terminal contrast display", function()
  test.before_each(function(context)
    context.minimum = config.plugins.terminal.minimum_contrast
  end)
  test.after_each(function(context)
    if context.view then context.view:on_close() end
    terminal._set_native_for_tests(nil)
    config.plugins.terminal.minimum_contrast = context.minimum
  end)

  test.it("applies contrast setting changes to an existing Terminal View", function(context)
    local session, view = fake_session(context)
    test.equal(session.options.minimum_contrast, config.plugins.terminal.minimum_contrast)
    config.plugins.terminal.minimum_contrast = 1
    view:update()
    test.equal(session.colors.minimum_contrast, 1)
    config.plugins.terminal.minimum_contrast = 7
    view:update()
    test.equal(session.colors.minimum_contrast, 7)
  end)

  test.it("draws corrected dim text without applying dim opacity twice", function(context)
    local session, view = fake_session(context)
    session.image.rows = { {
      backgrounds = { { col = 0, columns = 3, selected = true, color = 0x112233 } },
      text_runs = { { col = 0, columns = 3, text = "DIM", fg = 0x005000, faint = true, alpha = 255 } },
    } }
    view.size.x, view.size.y = 800, 300
    local calls = record_draw(view)
    test.same(calls.text[1][#calls.text[1]], { 0, 80, 0, 255 })
    local found_background = false
    for _, call in ipairs(calls.rect) do
      local color = call[#call]
      if color[1] == 0x11 and color[2] == 0x22 and color[3] == 0x33 then
        found_background = color[4] == 255
      end
    end
    test.ok(found_background, "Selected text did not use its resolved background")
  end)

  test.it("keeps corrected and hidden opacity in Terminal Text Capture", function()
    local capture = terminal.TerminalTextCaptureView(nil, {
      text = "DIM\nHIDDEN\n",
      foreground = 0x080808, background = 0xffffff,
      styles = {
        { { col1 = 1, col2 = 4, fg = 0x005000, faint = true, alpha = 255 } },
        { { col1 = 1, col2 = 7, fg = 0xa6e3a1, alpha = 0 } },
      },
    })
    test.same(capture:get_line_render(1).fragments[1].color, { 0, 80, 0, 255 })
    test.equal(capture:get_line_render(2).fragments[1].color[4], 0)
    capture:on_close()
  end)
end)

test.describe("Terminal contrast command", function()
  test.before_each(function(context)
    core.global_prompt_bar:exit(true)
    context.active_view = core.active_view
    context.minimum = config.plugins.terminal.minimum_contrast
    context.vividness = config.plugins.terminal.color_vividness
    context.settings_config = settings.config
    settings.config = {}
    os.remove(USERDIR .. "/user_settings.lua")
  end)

  test.after_each(function(context)
    core.global_prompt_bar:exit(true)
    if context.view then context.view:on_close() end
    terminal._set_native_for_tests(nil)
    config.plugins.terminal.minimum_contrast = context.minimum
    config.plugins.terminal.color_vividness = context.vividness
    settings.config = context.settings_config
    os.remove(USERDIR .. "/user_settings.lua")
    if context.active_view then core.set_active_view(context.active_view) end
  end)

  test.it("sets and saves terminal contrast through the Global Prompt Bar", function(context)
    local session, view = fake_session(context)
    local bar = core.global_prompt_bar

    test.ok(command.perform("terminal:set_minimum_text_contrast"))
    test.equal(core.active_view, bar)
    test.equal(bar:get_text(), tostring(context.minimum))
    bar:set_text("7.25")
    bar:submit()

    test.equal(config.plugins.terminal.minimum_contrast, 7.25)
    test.not_equal(core.active_view, bar)
    view:update()
    test.equal(session.colors.minimum_contrast, 7.25)
    local saved = dofile(USERDIR .. "/user_settings.lua")
    test.equal(saved.config.plugins.terminal.minimum_contrast, 7.25)
  end)

  test.it("sets and saves vividness for an existing Terminal View", function(context)
    local session, view = fake_session(context)
    local bar = core.global_prompt_bar
    test.equal(session.options.color_vividness, context.vividness)
    test.ok(command.perform("terminal:set_color_vividness"))
    test.equal(bar:get_text(), tostring(context.vividness))
    bar:set_text("72.5")
    bar:submit()

    test.equal(config.plugins.terminal.color_vividness, 72.5)
    view:update()
    test.equal(session.colors.color_vividness, 72.5)
    local saved = dofile(USERDIR .. "/user_settings.lua")
    test.equal(saved.config.plugins.terminal.color_vividness, 72.5)
    test.equal(config.plugins.terminal.minimum_contrast, context.minimum)
  end)

  test.it("accepts both ends of the vividness range", function()
    for _, value in ipairs({ 0, 100 }) do
      test.ok(command.perform("terminal:set_color_vividness"))
      core.global_prompt_bar:set_text(tostring(value))
      core.global_prompt_bar:submit()
      test.equal(config.plugins.terminal.color_vividness, value)
    end
  end)

  test.it("applies vividness changes while a Terminal View is suspended", function(context)
    local session, view = fake_session(context)
    config.plugins.terminal.color_vividness = 60
    view:update_suspended()
    test.equal(session.colors.color_vividness, 60)
  end)

  test.it("keeps invalid vividness input in the prompt without changing settings", function(context)
    local bar = core.global_prompt_bar
    test.ok(command.perform("terminal:set_color_vividness"))
    for _, text in ipairs({ "-0.1", "100.1", "", "not a number", "nan", "inf", "1e309" }) do
      bar:set_text(text)
      bar:submit()
      test.equal(config.plugins.terminal.color_vividness, context.vividness)
      test.ok(core.active_view == bar, "Invalid vividness input closed the prompt: " .. text)
      test.equal(system.get_file_info(USERDIR .. "/user_settings.lua"), nil)
    end
  end)

  test.it("accepts correction off and the maximum contrast ratio", function()
    local bar = core.global_prompt_bar
    for _, value in ipairs({ 1, 21 }) do
      test.ok(command.perform("terminal:set_minimum_text_contrast"))
      bar:set_text(tostring(value))
      bar:submit()
      test.equal(config.plugins.terminal.minimum_contrast, value)
      test.not_equal(core.active_view, bar)
    end
  end)

  test.it("keeps invalid contrast input in the prompt without changing settings", function(context)
    local bar = core.global_prompt_bar
    test.ok(command.perform("terminal:set_minimum_text_contrast"))
    for _, text in ipairs({ "0.5", "21.1", "", "not a number", "nan", "inf", "1e309" }) do
      bar:set_text(text)
      bar:submit()
      test.equal(config.plugins.terminal.minimum_contrast, context.minimum)
      test.ok(core.active_view == bar, "Invalid contrast input closed the prompt: " .. text)
      test.equal(system.get_file_info(USERDIR .. "/user_settings.lua"), nil)
    end
  end)

  test.it("keeps terminal contrast unchanged when the prompt is canceled", function(context)
    local bar = core.global_prompt_bar
    test.ok(command.perform("terminal:set_minimum_text_contrast"))
    bar:set_text("7.25")
    bar:exit(false)

    test.equal(config.plugins.terminal.minimum_contrast, context.minimum)
    test.equal(system.get_file_info(USERDIR .. "/user_settings.lua"), nil)
  end)
end)
