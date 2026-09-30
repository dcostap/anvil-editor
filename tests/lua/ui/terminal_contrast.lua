local config = require "core.config"
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
