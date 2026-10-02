local command = require "core.command"
local core = require "core"
local config = require "core.config"
local style = require "core.style"
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
  local old_clip = renderer.set_clip_rect
  local calls = { text = {}, rect = {} }
  renderer.draw_text = function(...) calls.text[#calls.text + 1] = { ... } end
  renderer.draw_text_known_bounds = renderer.draw_text
  renderer.draw_rect = function(...) calls.rect[#calls.rect + 1] = { ... } end
  renderer.draw_rounded_rect = function(...) calls.rect[#calls.rect + 1] = { ... } end
  renderer.set_clip_rect = function() end
  local ok, err = pcall(function() view:draw() end)
  renderer.draw_text, renderer.draw_text_known_bounds, renderer.draw_rect = old_text, old_known, old_rect
  renderer.draw_rounded_rect = old_rounded
  renderer.set_clip_rect = old_clip
  if not ok then error(err) end
  return calls
end

test.describe("Terminal contrast display", function()
  test.before_each(function(context)
    context.minimum = style.terminal_minimum_contrast
    context.animated = config.animated_caret
  end)
  test.after_each(function(context)
    if context.view then context.view:on_close() end
    terminal._set_native_for_tests(nil)
    style.terminal_minimum_contrast = context.minimum
    config.animated_caret = context.animated
  end)

  test.it("applies contrast setting changes to an existing Terminal View", function(context)
    local session, view = fake_session(context)
    test.equal(session.options.minimum_contrast, style.terminal_minimum_contrast)
    style.terminal_minimum_contrast = 1
    view:update()
    test.equal(session.colors.minimum_contrast, 1)
    style.terminal_minimum_contrast = 7
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

  test.it("does not reveal concealed text under a filled cursor", function(context)
    local session, view = fake_session(context)
    session.image.rows = {{ backgrounds = {}, text_runs = {{
      col = 0, columns = 1, text = "M", fg = 0x080808, alpha = 0,
    }} }}
    session.image.cursor = { visible = true, style = "block", x = 0, y = 0, color = 0 }
    view.size.x, view.size.y = 800, 300
    view.focused, view.running = true, true
    config.animated_caret = false
    local calls = record_draw(view)
    for _, call in ipairs(calls.text) do
      test.equal(call[#call][4], 0, "Cursor contrast revealed concealed text")
    end
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

test.describe("Terminal color settings by theme", function()
  test.before_each(function(context)
    core.global_prompt_bar:exit(true)
    context.theme_module = core.color_theme_module or "colors.default"
    context.active_view = core.active_view
    context.clipboard = system.get_clipboard() or ""
    for name, values in pairs({ terminal_test_light = { 5, 20 }, terminal_test_dark = { 3, 40 } }) do
      package.preload["colors." .. name] = function()
        style.terminal_minimum_contrast = values[1]
        style.terminal_color_vividness = values[2]
        return style
      end
      os.remove(USERDIR .. "/colors/edits/" .. name .. ".lua")
    end
  end)

  test.after_each(function(context)
    core.global_prompt_bar:exit(true)
    if context.view then context.view:on_close() end
    terminal._set_native_for_tests(nil)
    for _, name in ipairs({ "terminal_test_light", "terminal_test_dark" }) do
      package.preload["colors." .. name] = nil
      package.loaded["colors." .. name] = nil
      os.remove(USERDIR .. "/colors/edits/" .. name .. ".lua")
    end
    core.reload_module(context.theme_module)
    system.set_clipboard(context.clipboard)
    if context.active_view then core.set_active_view(context.active_view) end
  end)

  test.it("restores each theme's saved terminal values without changing other theme edits", function(context)
    local edits = require "core.theme_edits"
    test.ok(edits.save("terminal_test_light", { palette = {}, rules = {
      ["syntax.comment"] = { enabled = true, color = { 10, 20, 30, 255 } },
    } }, false))
    core.reload_module("colors.terminal_test_light")
    local session, view = fake_session(context)
    test.equal(session.options.minimum_contrast, 5)
    test.equal(session.options.color_vividness, 20)
    test.ok(command.perform("terminal:set_minimum_text_contrast"))
    core.global_prompt_bar:set_text("6.25")
    core.global_prompt_bar:submit()
    test.ok(command.perform("terminal:set_color_vividness"))
    core.global_prompt_bar:set_text("75")
    core.global_prompt_bar:submit()

    core.reload_module("colors.terminal_test_dark")
    view:update_suspended()
    test.equal(session.colors.minimum_contrast, 3)
    test.equal(session.colors.color_vividness, 40)
    core.reload_module("colors.terminal_test_light")
    view:update()
    test.equal(session.colors.minimum_contrast, 6.25)
    test.equal(session.colors.color_vividness, 75)
    test.same(style.syntax.comment, { 10, 20, 30, 255 })
  end)

  test.it("copies the displayed theme and effective terminal values without writing source files", function()
    core.reload_module("colors.light")
    style.terminal_minimum_contrast = 6.25
    style.terminal_color_vividness = 75
    local path = assert(package.searchpath("colors.light", package.path))
    local function read_source()
      local file = assert(io.open(path, "rb"))
      local text = file:read("*a")
      file:close()
      return text
    end
    local before = read_source()
    test.ok(command.perform("terminal:copy_color_settings"))
    local copied = system.get_clipboard()
    test.contains(copied, "Theme: light")
    test.contains(copied, "data/colors/light.lua")
    test.contains(copied, "style.terminal_minimum_contrast = 6.25")
    test.contains(copied, "style.terminal_color_vividness = 75")
    test.contains(copied, "defaults")
    test.equal(read_source(), before)
  end)
end)

test.describe("Terminal contrast command", function()
  test.before_each(function(context)
    core.global_prompt_bar:exit(true)
    context.active_view = core.active_view
    context.theme_module = core.color_theme_module
    context.path = USERDIR .. "/colors/edits/terminal_prompt_test.lua"
    os.remove(context.path)
    package.preload["colors.terminal_prompt_test"] = function() return style end
    core.reload_module("colors.terminal_prompt_test")
    context.minimum = style.terminal_minimum_contrast
    context.vividness = style.terminal_color_vividness
  end)

  test.after_each(function(context)
    core.global_prompt_bar:exit(true)
    if context.view then context.view:on_close() end
    terminal._set_native_for_tests(nil)
    os.remove(context.path)
    package.preload["colors.terminal_prompt_test"] = nil
    package.loaded["colors.terminal_prompt_test"] = nil
    core.reload_module(context.theme_module)
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

    test.equal(style.terminal_minimum_contrast, 7.25)
    test.not_equal(core.active_view, bar)
    view:update()
    test.equal(session.colors.minimum_contrast, 7.25)
    local saved = dofile(context.path)
    test.equal(saved.terminal.minimum_contrast, 7.25)
  end)

  test.it("sets and saves vividness for an existing Terminal View", function(context)
    local session, view = fake_session(context)
    local bar = core.global_prompt_bar
    test.equal(session.options.color_vividness, context.vividness)
    test.ok(command.perform("terminal:set_color_vividness"))
    test.equal(bar:get_text(), tostring(context.vividness))
    bar:set_text("72.5")
    bar:submit()

    test.equal(style.terminal_color_vividness, 72.5)
    view:update()
    test.equal(session.colors.color_vividness, 72.5)
    local saved = dofile(context.path)
    test.equal(saved.terminal.color_vividness, 72.5)
    test.equal(style.terminal_minimum_contrast, context.minimum)
  end)

  test.it("accepts both ends of the vividness range", function()
    for _, value in ipairs({ 0, 100 }) do
      test.ok(command.perform("terminal:set_color_vividness"))
      core.global_prompt_bar:set_text(tostring(value))
      core.global_prompt_bar:submit()
      test.equal(style.terminal_color_vividness, value)
    end
  end)

  test.it("applies vividness changes while a Terminal View is suspended", function(context)
    local session, view = fake_session(context)
    style.terminal_color_vividness = 60
    view:update_suspended()
    test.equal(session.colors.color_vividness, 60)
  end)

  test.it("keeps invalid vividness input in the prompt without changing settings", function(context)
    local bar = core.global_prompt_bar
    test.ok(command.perform("terminal:set_color_vividness"))
    for _, text in ipairs({ "-0.1", "100.1", "", "not a number", "nan", "inf", "1e309" }) do
      bar:set_text(text)
      bar:submit()
      test.equal(style.terminal_color_vividness, context.vividness)
      test.ok(core.active_view == bar, "Invalid vividness input closed the prompt: " .. text)
      test.equal(system.get_file_info(context.path), nil)
    end
  end)

  test.it("accepts correction off and the maximum contrast ratio", function()
    local bar = core.global_prompt_bar
    for _, value in ipairs({ 1, 21 }) do
      test.ok(command.perform("terminal:set_minimum_text_contrast"))
      bar:set_text(tostring(value))
      bar:submit()
      test.equal(style.terminal_minimum_contrast, value)
      test.not_equal(core.active_view, bar)
    end
  end)

  test.it("keeps invalid contrast input in the prompt without changing settings", function(context)
    local bar = core.global_prompt_bar
    test.ok(command.perform("terminal:set_minimum_text_contrast"))
    for _, text in ipairs({ "0.5", "21.1", "", "not a number", "nan", "inf", "1e309" }) do
      bar:set_text(text)
      bar:submit()
      test.equal(style.terminal_minimum_contrast, context.minimum)
      test.ok(core.active_view == bar, "Invalid contrast input closed the prompt: " .. text)
      test.equal(system.get_file_info(context.path), nil)
    end
  end)

  test.it("keeps terminal contrast unchanged when the prompt is canceled", function(context)
    local bar = core.global_prompt_bar
    test.ok(command.perform("terminal:set_minimum_text_contrast"))
    bar:set_text("7.25")
    bar:exit(false)

    test.equal(style.terminal_minimum_contrast, context.minimum)
    test.equal(system.get_file_info(context.path), nil)
  end)
end)
