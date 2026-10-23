-- Private renderer checks for terminal image placement, clipping, and layers.
local core = require "core"
local View = require "core.view"
local style = require "core.style"
local canvas = require "canvas"
local TerminalView = require("plugins.terminal").TerminalView
local Scene = View:extend()

function Scene:get_name() return "Terminal Images" end

local function solid(color)
  local image = canvas.new(2, 2, color, true)
  image:render()
  return image
end

function Scene:new()
  Scene.super.new(self)
  self.red = solid {255, 0, 0, 255}
  self.blue = solid {0, 0, 255, 255}
  self.alpha = solid {255, 0, 0, 128}
  self.crop = canvas.new(4, 2, {255, 0, 0, 255}, true)
  self.crop:draw_rect(2, 0, 2, 2, {0, 0, 255, 255}, true)
  self.crop:render()
  self.cropped = self.crop:copy(2, 0, 2, 2)
end

function Scene:draw()
  renderer.draw_rect(self.position.x, self.position.y, self.size.x, self.size.y, {255,255,255,255})
  local view = setmetatable({}, TerminalView)
  View.new(view)
  view.font = style.code_font
  view.cell_width, view.native_cell_width, view.cell_height = 8, 8, 16
  view.position.x, view.position.y = self.position.x + 30, self.position.y + 30
  view.size.x, view.size.y = 332, 172
  view.color_cache, view.running = {}, false
  view.draw_scrollbar = function() end
  -- Use an opaque base so wallpaper does not change expected alpha blends.
  view.draw_background = function(self)
    renderer.draw_rect(self.position.x, self.position.y, self.size.x, self.size.y, {255,255,255,255})
  end
  local images = {}
  local function image(source, x, y, z)
    images[#images + 1] = {
      canvas = source, id = #images + 1, placement_id = 1,
      x = x, y = y, width = 32, height = 32, z = z,
    }
  end
  image(self.red, 0, 0, 0)
  image(self.blue, 16, 0, 1) -- Higher z covers red.
  image(self.alpha, 64, 0, 0)
  image(self.cropped, 112, 0, 0) -- Only the blue half.
  image(self.red, 304, 0, 0) -- Clip to the terminal's right edge.
  image(self.red, 0, -16, -1) -- Clip above the terminal's first row.
  image(self.red, 0, 64, -1073741825) -- Below explicit cell backgrounds.
  image(self.red, 64, 64, -1) -- Above backgrounds, below text.
  image(self.red, 0, 96, -1)
  image(self.red, 64, 96, 0)
  view.snapshot = {
    cols = 40, row_count = 10, background = 0xffffff,
    images = images,
    rows = { {}, {}, {}, {}, {
      backgrounds = {{col = 0, columns = 12, color = 0x00ff00}},
      text_runs = {},
    }, {}, {
      text_runs = {{ text = string.rep("█", 12), col = 0, columns = 12,
        block = 0x2588, fg = 0x0000ff, alpha = 255 }},
    } },
  }
  core.push_clip_rect(view.position.x, view.position.y, view.size.x, view.size.y)
  view:draw()
  core.pop_clip_rect()
  if not self.metadata_written then
    local x, y = view.position.x + 6, view.position.y + 6
    local lines = {"name,x,y,r,g,b"}
    local function sample(name, dx, dy, r, g, b)
      lines[#lines + 1] = string.format("%s,%d,%d,%d,%d,%d", name, x + dx, y + dy, r,g,b)
    end
    sample("red", 8, 24, 255,0,0)
    sample("z-order", 24, 24, 0,0,255)
    sample("alpha", 80, 16, 255,127,127)
    sample("crop", 128, 16, 0,0,255)
    sample("crop-edge", 112, 16, 0,0,255)
    sample("right-inside", 312, 16, 255,0,0)
    sample("right-outside", 322, 16, 255,255,255)
    sample("top-outside", 8, -2, 255,255,255)
    sample("below-background", 8, 72, 0,255,0)
    sample("above-background", 72, 72, 255,0,0)
    sample("below-text", 8, 104, 0,0,255)
    sample("above-text", 72, 104, 255,0,0)
    local path = os.getenv("ANVIL_PERF_BENCHMARK_IMAGE_METADATA")
    local file = assert(io.open(path, "wb"))
    file:write(table.concat(lines, "\n"), "\n")
    file:close()
    self.metadata_written = true
  end
end

return Scene
