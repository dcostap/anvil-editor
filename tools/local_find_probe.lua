local core = require "core"
local command = require "core.command"
local test = require "core.test"
local panes = require "core.panes"
local Editor = require "core.editor"
require "plugins.intellij_find"

local function report(name, samples)
  table.sort(samples)
  local sum = 0
  for _, n in ipairs(samples) do sum = sum + n end
  print(string.format("PROBE %s avg=%.3f p95=%.3f max=%.3f", name,
    sum / #samples, samples[math.ceil(#samples * .95)], samples[#samples]))
end

test.it("measures Local Find on a generated C file", function()
  local path = USERDIR .. PATHSEP .. "find-large.c"
  local f = assert(io.open(path, "wb"))
  local line = "int input = input + 1; /* input */\n"
  for _ = 1, 450000 do f:write(line) end
  f:close()
  print(string.format("PROBE fixture lines=450000 bytes=%d", #line * 450000))
  local buffer = core.open_buffer(path)
  local view = panes.place(function() return Editor(buffer) end, { placement = "new", focus = true })
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 1100, 800
  view:set_wrapping_enabled(false)
  view:with_selection_state(function() buffer:set_selection(200000, 1) end)
  command.perform("editor:find")
  local input = core.active_view
  local state = input.local_find_state
  local times, draws, counts, updates, frames = {}, {}, {}, {}, {}
  local window = renwindow.create("Local Find probe", 1100, 800)
  local function settle()
    repeat
      local t = system.get_time()
      view:update()
      updates[#updates + 1] = (system.get_time() - t) * 1000
      coroutine.yield()
    until not state.pending and (not state.overview or state.overview.complete)
  end
  for _ = 1, 3 do
    input:set_text("")
    local query = ""
    for char in ("input"):gmatch(".") do
      core.set_active_view(input)
      local t = system.get_time()
      core.root_panel:on_text_input(char)
      times[#times + 1] = (system.get_time() - t) * 1000
      query = query .. char
      test.equal(input:get_text(), query)
      settle()
      test.equal(#state.matches, 450000 * ((query == "i" or query == "in") and 4 or 3))
      for _ = 1, 3 do
        local calls = 0
        local old = renderer.draw_rect
        renderer.draw_rect = function(...) calls = calls + 1; return old(...) end
        local frame_start = system.get_time()
        renderer.begin_frame(window)
        t = system.get_time()
        view:draw()
        draws[#draws + 1] = (system.get_time() - t) * 1000
        renderer.end_frame()
        frames[#frames + 1] = (system.get_time() - frame_start) * 1000
        renderer.draw_rect = old
        counts[#counts + 1] = calls
      end
    end
  end
  report("input_ms", times)
  report("draw_ms", draws)
  report("draw_rect", counts)
  report("frame_ms", frames)
  report("update_ms", updates)
  command.perform("editor:find_close")
  panes.reset_for_tests()
  os.remove(path)
end)
