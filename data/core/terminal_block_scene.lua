-- Private renderer checks for terminal Block Elements.
local common = require "core.common"
local style = require "core.style"
local View = require "core.view"
local TerminalView = require("plugins.terminal").TerminalView

local Scene = View:extend()
function Scene:get_name() return "Terminal Block Elements" end

function Scene:new()
  Scene.super.new(self)
  self.fonts = {}
  for _, size in ipairs {14, 15, 16, 17, 18, 24} do
    self.fonts[size] = renderer.font.load(DATADIR .. "/fonts/JetBrainsMono-Regular.ttf", size / SCALE,
      { antialiasing = "subpixel", hinting = "full", ligatures = false })
  end
end

local function terminal(font, x, y, background)
  local view = setmetatable({}, TerminalView)
  View.new(view)
  view.font = font
  view.cell_width, view.cell_height = font:get_width("M"), math.ceil(font:get_height())
  view.position.x, view.position.y = x, y
  view.size.x, view.size.y = 600, view.cell_height * 4 + 12
  view.color_cache = {}
  view.running = false
  view.snapshot = { background = background, rows = {} }
  view.draw_scrollbar = function() end
  return view
end

local function channels(value)
  return { math.floor(value / 65536) % 256, math.floor(value / 256) % 256, value % 256 }
end

local function draw_terminal(view)
  -- Remove wallpaper variation from expected pixels without changing the View.
  local background = channels(view.snapshot.background)
  background[4] = 255
  renderer.draw_rect(view.position.x, view.position.y, view.size.x, view.size.y, background)
  view:draw()
end

function Scene:draw()
  renderer.draw_rect(self.position.x, self.position.y, self.size.x, self.size.y, {32,36,42,255})
  local samples = { "kind,name,x,y,w,h,r,g,b,count" }
  local function pixel(name, x, y, color)
    samples[#samples + 1] = string.format("pixel,%s,%d,%d,1,1,%d,%d,%d,0",
      name, x, y, color[1], color[2], color[3])
  end
  local foreground = 0x7788cc
  local fg = channels(foreground)
  for column, background in ipairs {0x101824, 0xf2f4f8} do
    local bg = channels(background)
    for index, size in ipairs {14, 15, 16, 17, 18, 24} do
      local font = self.fonts[size]
      local view = terminal(font, self.position.x + 25 + (column - 1) * 670 + 1 / 3,
        self.position.y + 25 + (index - 1) * 142, background)
      for row, codepoint in ipairs {0x2588, 0x2580, 0x2584, 0x2588} do
        view.snapshot.rows[row] = { backgrounds = {}, text_runs = {{
          text = string.rep(({"█", "▀", "▄", "█"})[row], 24),
          col = 0, columns = 24, block = codepoint, fg = foreground,
          alpha = row == 4 and 140 or 255, bold = row == 2, italic = row == 2,
        }} }
      end
      draw_terminal(view)
      if not self.metadata_written then
        local x1 = math.floor(view.position.x + 6 + 0.5)
        local x2 = math.floor(view.position.x + 6 + 24 * view.cell_width + 0.5)
        local y1 = math.floor(view.position.y + 6 + 0.5)
        for row = 0, 3 do
          local top = y1 + row * view.cell_height
          local split = top + math.floor(view.cell_height / 2 + 0.5)
          for y = top, top + view.cell_height - 1 do
            local color = (row == 1 and y >= split or row == 2 and y < split) and bg or fg
            if row == 3 then
              color = {}
              for channel = 1, 3 do
                color[channel] = math.floor((fg[channel] * 140 + bg[channel] * 115 + 127) / 255)
              end
            end
            for x = x1, x2 - 1 do pixel("bar", x, y, color) end
            pixel("outside", x1 - 1, y, bg)
            pixel("outside", x2, y, bg)
          end
        end
      end
    end
  end

  -- Worked 16x16 examples. These values follow Unicode's block fractions.
  local expected = {
    {{0,0,16,8}}, {{0,14,16,2}}, {{0,12,16,4}}, {{0,10,16,6}},
    {{0,8,16,8}}, {{0,6,16,10}}, {{0,4,16,12}}, {{0,2,16,14}},
    {{0,0,16,16}}, {{0,0,14,16}}, {{0,0,12,16}}, {{0,0,10,16}},
    {{0,0,8,16}}, {{0,0,6,16}}, {{0,0,4,16}}, {{0,0,2,16}},
    {{8,0,8,16}}, 64, 128, 192, {{0,0,16,2}}, {{14,0,2,16}},
    {{0,8,8,8}}, {{8,8,8,8}}, {{0,0,8,8}},
    {{0,0,8,16},{8,8,8,8}}, {{0,0,8,8},{8,8,8,8}},
    {{0,0,16,8},{0,8,8,8}}, {{0,0,16,8},{8,8,8,8}},
    {{8,0,8,8}}, {{8,0,8,8},{0,8,8,8}}, {{8,0,8,16},{0,8,8,8}},
  }
  local chars = {}
  for char in common.utf8_chars("▀▁▂▃▄▅▆▇█▉▊▋▌▍▎▏▐░▒▓▔▕▖▗▘▙▚▛▜▝▞▟") do chars[#chars + 1] = char end
  local view = terminal(self.fonts[14], self.position.x + 25, self.position.y + 890, 0x101824)
  view.cell_width, view.cell_height = 16, 16
  view.size.y = 44
  for row = 1, 2 do
    local runs = {}
    for col = 0, 15 do
      local index = (row - 1) * 16 + col + 1
      runs[#runs + 1] = {text=chars[index], col=col, columns=1, block=0x257f+index, fg=foreground}
    end
    view.snapshot.rows[row] = { backgrounds = {}, text_runs = runs }
  end
  draw_terminal(view)
  if self.metadata_written then return end
  for index, example in ipairs(expected) do
    local left = math.floor(view.position.x + 6 + 0.5) + ((index - 1) % 16) * 16
    local top = math.floor(view.position.y + 6 + 0.5) + math.floor((index - 1) / 16) * 16
    if type(example) == "number" then
      samples[#samples + 1] = string.format("coverage,shade,%d,%d,16,16,%d,%d,%d,%d",
        left, top, fg[1], fg[2], fg[3], example)
    else
      for y = 0, 15 do
        for x = 0, 15 do
          local color = channels(0x101824)
          for _, rect in ipairs(example) do
            if x >= rect[1] and x < rect[1] + rect[3] and y >= rect[2] and y < rect[2] + rect[4] then color = fg end
          end
          pixel("block", left + x, top + y, color)
        end
      end
    end
  end
  if not self.metadata_written then
    local file = assert(io.open(os.getenv("ANVIL_PERF_BENCHMARK_IMAGE_METADATA"), "wb"))
    file:write(table.concat(samples, "\n")); file:close()
    self.metadata_written = true
  end
end

return Scene
