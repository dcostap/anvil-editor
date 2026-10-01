local test = require "core.test"
local style = require "core.style"
local View = require "core.view"
local TerminalView = require("plugins.terminal").TerminalView

-- The renderer is the boundary. Record coverage without testing private helpers.
local function draw(runs, width, height)
  local view = setmetatable({}, TerminalView)
  View.new(view)
  view.font = style.terminal_font
  view.cell_width, view.cell_height = width, height
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 400, 100
  view.color_cache = {}
  view.running = false
  view.snapshot = { background = 0, rows = {{ backgrounds = {}, text_runs = runs }} }
  view.draw_scrollbar = function() end
  local previous_rect, previous_text, previous_known = renderer.draw_rect,
    renderer.draw_text, renderer.draw_text_known_bounds
  local pixels, texts = {}, {}
  renderer.draw_rect = function(x, y, w, h, color)
    if color[1] ~= 17 or color[2] ~= 34 or color[3] ~= 51 then return end
    for py = y, y + h - 1 do
      pixels[py] = pixels[py] or {}
      for px = x, x + w - 1 do
        local pixel = pixels[py][px] or { coverage = 0, alpha = color[4] }
        pixel.coverage = pixel.coverage + 1
        pixels[py][px] = pixel
      end
    end
  end
  renderer.draw_text = function(font, text, x, y)
    texts[#texts + 1] = { text = text, x = x, y = y }
  end
  renderer.draw_text_known_bounds = renderer.draw_text
  local ok, err = pcall(view.draw, view)
  renderer.draw_rect, renderer.draw_text, renderer.draw_text_known_bounds =
    previous_rect, previous_text, previous_known
  if not ok then error(err) end
  return pixels, texts
end

local function coverage(pixels, x, y)
  local pixel = pixels[y] and pixels[y][x]
  return pixel and pixel.coverage or 0
end

test.describe("Terminal block rendering", function()
  test.it("fills fractional cells once while keeping adjacent ordinary text", function()
    local pixels, texts = draw({
      { text="A", col=0, columns=1, fg=0x112233 },
      { text="██", col=1, columns=2, block=0x2588, fg=0x112233, alpha=140 },
      { text="B", col=3, columns=1, fg=0x112233 },
    }, 10.2, 19)
    test.equal(texts[1].text, "A")
    test.equal(texts[2].text, "B")
    test.near(texts[2].x, 36.6, 0.00001)
    for y = 6, 24 do
      for x = 16, 36 do
        test.equal(coverage(pixels, x, y), 1)
        test.equal(pixels[y][x].alpha, 140)
      end
      test.equal(coverage(pixels, 15, y), 0)
      test.equal(coverage(pixels, 37, y), 0)
    end
  end)

  test.it("aligns complementary halves and quadrants at odd cell sizes", function()
    local pixels = draw({
      { text="▀", col=0, columns=1, block=0x2580, fg=0x112233 },
      { text="▄", col=1, columns=1, block=0x2584, fg=0x112233 },
      { text="▖", col=2, columns=1, block=0x2596, fg=0x112233 },
    }, 9.6, 19)
    for y = 6, 24 do
      test.equal(coverage(pixels, 8, y) + coverage(pixels, 18, y), 1)
      test.equal(coverage(pixels, 18, y), coverage(pixels, 26, y))
    end
  end)
end)
