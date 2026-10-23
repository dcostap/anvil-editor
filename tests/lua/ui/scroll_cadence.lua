local core = require "core"
local config = require "core.config"
local panes = require "core.panes"
local View = require "core.view"
local test = require "core.test"

-- Run outside the test runner's coroutine so core.run_step owns its scheduler.
-- Seam: the real frame loop and View animation, with a controlled native clock
-- and event queue. No wall-clock timing or keyboard bindings are asserted.
local function probe()
  local now = system.get_time()
  local motion = false
  system.get_time = function() return now end
  system.idle = function() end
  system.window_has_focus = function() return true end
  system.has_pending_events = function() return motion end
  system.poll_event = function()
    if motion then
      motion = false
      return "mousemoved", -100, -100, 0, 0
    end
  end
  renderer.is_present_paced = function() return false end
  core.threads = {}
  core.background_threads = 0
  core.blink_start = now
  config.fps = 60
  config.transitions = true
  config.disabled_transitions.scroll = false

  local ScrollingView = View:extend()
  function ScrollingView:update()
    self:move_towards(self.scroll, "y", self.scroll.to.y, 0.2, "scroll")
  end
  function ScrollingView:draw()
    self.drawn_y = self.scroll.y
  end
  local view = ScrollingView()
  panes.place(function() return view end, {placement = "new", focus = true})
  core.on_event("mousemoved", -100, -100, 0, 0)
  core.run()
  core.run_step({immediate = true})

  view.scroll.to.y = 500
  core.redraw = true
  now = now + 1
  core.run_step()
  local drawn_y = view.drawn_y
  assert(view.scroll.y < view.scroll.to.y, "scroll should still be moving")

  -- Input wakes the loop before the next animation frame is due.
  now = now + 0.001
  motion = true
  core.run_step()
  assert(not core.performance_snapshot.did_redraw, "early wake should keep the frame limit")

  -- The due frame must run, not wait until the next caret blink.
  now = now + 1 / config.fps
  core.run_step()
  assert(view.drawn_y > drawn_y, "early pointer input stalled the scroll until the caret blink")
end

if os.getenv("ANVIL_SCROLL_CADENCE_PROBE") == "1" then
  -- CLI scripts load during initialization. Wait for the window and Views.
  local run = core.run
  core.run = function()
    core.run = run
    local ok, err = pcall(probe)
    if not ok then io.stderr:write(tostring(err), "\n") end
    os.exit(ok and 0 or 1)
  end
  return
end

test.describe("Scroll frame cadence", function()
  test.it("continues scrolling after input wakes the loop before a frame is due", function()
    local root = USERDIR .. PATHSEP .. "scroll-cadence"
    test.ok(require("core.common").mkdirp(root))
    local child
    local ok, err = pcall(function()
      child = process.start({EXEFILE, "--direct", "run", "--no-quit", "tests/lua/ui/scroll_cadence.lua"}, {
        stdout = process.REDIRECT_PIPE,
        stderr = process.REDIRECT_STDOUT,
        env = { ANVIL_USERDIR = root, ANVIL_SCROLL_CADENCE_PROBE = "1" },
      })
      local deadline = system.get_time() + 60
      while child:running() and system.get_time() < deadline do coroutine.yield(0.01) end
      test.not_ok(child:running(), "frame-loop probe did not finish")
      local output = child:read_stdout() or ""
      test.equal(child:returncode(), 0, output)
    end)
    if child and child:running() then child:kill() child:wait(process.WAIT_INFINITE, 0.01) end
    test.ok(test.remove_tree(root))
    if not ok then error(err, 0) end
  end)
end)
