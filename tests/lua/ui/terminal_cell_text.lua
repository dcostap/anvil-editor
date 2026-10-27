local test = require "core.test"
local style = require "core.style"
local View = require "core.view"
local TerminalView = require("plugins.terminal").TerminalView
local TerminalFind = require "plugins.terminal.find"

local WIDTH, HEIGHT = 400, 60

local function cells(...)
  local bytes = {}
  for _, value in ipairs { ... } do bytes[#bytes + 1] = string.char(value) end
  return table.concat(bytes)
end

-- The renderer is the boundary. A canvas stands in for the window, so the
-- test reads the pixels that a Terminal View actually draws.
local function draw_to_canvas(view)
  local target = canvas.new(WIDTH, HEIGHT, { 0, 0, 0, 255 }, false)
  local saved = {}
  for _, name in ipairs {
    "draw_rect", "draw_rounded_rect", "draw_text", "draw_text_known_bounds",
    "draw_text_cells", "set_clip_rect",
  } do saved[name] = renderer[name] end
  renderer.draw_rect = function(...) target:draw_rect(...) end
  renderer.draw_rounded_rect = function(x, y, w, h, _, color)
    target:draw_rect(x, y, w, h, color)
  end
  renderer.draw_text = function(font, text, x, y, color)
    return target:draw_text(font, text, x, y, color)
  end
  renderer.draw_text_known_bounds = function(font, text, x, y, _, _, _, _, color)
    return target:draw_text(font, text, x, y, color)
  end
  renderer.draw_text_cells = function(...) return target:draw_text_cells(...) end
  renderer.set_clip_rect = function(...) target:set_clip_rect(...) end
  local ok, err = pcall(view.draw, view)
  for name, fn in pairs(saved) do renderer[name] = fn end
  if not ok then error(err) end
  target:render()
  return target:get_pixels(0, 0, WIDTH, HEIGHT)
end

local function ink_between(pixels, x1, x2)
  for y = 0, HEIGHT - 1 do
    for x = math.max(0, math.floor(x1)), math.min(WIDTH, math.ceil(x2)) - 1 do
      local offset = (y * WIDTH + x) * 4
      if pixels:byte(offset + 1) > 96 then return true end
    end
  end
  return false
end

local function terminal_view(runs, cell_width)
  local view = setmetatable({}, TerminalView)
  View.new(view)
  view.find = TerminalFind(view)
  view.font = style.terminal_font
  view.cell_width = cell_width
  view.cell_height = math.ceil(style.terminal_font:get_height())
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = WIDTH, HEIGHT
  view.color_cache = {}
  view.running = false
  view.snapshot = {
    background = 0, foreground = 0xffffff,
    rows = {{ backgrounds = {}, text_runs = runs }},
  }
  view.draw_scrollbar = function() end
  return view
end

test.describe("Terminal cell text", function()
  test.it("draws each cell at its grid column when glyphs are narrower than cells", function()
    -- A glyph whose advance differs from the cell width must not move the
    -- cells after it. Fallback symbols cause this in practice.
    local advance = style.terminal_font:get_width("M")
    local cell_width = advance * 3
    local origin = 6
    local view = terminal_view({
      { text = "MM", cells = cells(1, 1, 1, 1), col = 0, columns = 2, fg = 0xffffff },
    }, cell_width)

    local pixels = draw_to_canvas(view)

    test.ok(ink_between(pixels, origin, origin + cell_width), "First cell is empty")
    test.ok(
      ink_between(pixels, origin + cell_width, origin + cell_width * 2),
      "Second cell is empty; its glyph followed the first glyph's advance"
    )
  end)
end)
