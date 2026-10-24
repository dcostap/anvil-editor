local core = require "core"
local command = require "core.command"
local config = require "core.config"
local panes = require "core.panes"
local View = require "core.view"
local test = require "core.test"

-- Seam: input, commands, and worker results reach the real scheduler and View.draw.
-- A child process lets core.run_step own the coroutine scheduler.
-- Only native timing, input, and rendering permission are controlled.
local function probe(kind)
  local now = system.get_time()
  local get_time = system.get_time
  local events, visible = {}, true
  system.get_time = function() return now end
  system.idle = function() end
  system.window_has_focus = function() return true end
  system.window_should_render = function() return visible end
  system.has_pending_events = function() return #events > 0 end
  system.poll_event = function()
    local event = table.remove(events, 1)
    if event then return table.unpack(event) end
  end
  renderer.is_present_paced = function() return false end
  core.threads = {}
  core.background_threads = 0
  core.blink_start = now
  core.perf_cadence_uncapped = false
  core.window_resizing_until = nil
  config.draw_stats = false
  config.fps = 60
  config.transitions = false
  config.disable_blink = true
  config.animated_caret = false

  local buffer
  if kind == "save" then
    config.plugins.autosave_fast.enabled = false
    local path = USERDIR .. PATHSEP .. "save-result.txt"
    local file = assert(io.open(path, "wb"))
    file:write("original\n"); file:close()
    buffer = require("core.buffer")(path, path)
    buffer:insert(1, 1, "saved ")
  end
  local ResultView = View:extend()
  function ResultView:update() end
  function ResultView:draw()
    self.drawn_value = buffer and (buffer:is_dirty() and "before" or "after") or self.value
  end
  function ResultView:on_text_input(value) self.value = value end
  local view = ResultView()
  view.value = "before"
  panes.place(function() return view end, { placement = "new", focus = true })
  core.run()

  -- Finish focus feedback and layout. They must not supply the command's redraw.
  local idle = false
  for _ = 1, 10 do
    now = now + 1
    core.run_step()
    if not core.performance_snapshot.did_redraw then idle = true break end
  end
  assert(idle and view.drawn_value == "before", "the View did not reach idle")

  if kind == "save" then
    assert(buffer:is_dirty(), "the Buffer was saved before the measured request")
    local request = assert(buffer:save_async())
    local deadline = os.time() + 30
    now = now + 1
    repeat
      core.run_step()
      system.sleep(0.001)
    until request.status ~= "pending" or os.time() >= deadline
    assert(request.status == "saved", request.error or "the background save did not finish")
    assert(not buffer:is_dirty(), "the saved Buffer stayed dirty")
    core.run_step()
    assert(view.drawn_value == "after", "the background save left the dirty marker on screen")
    buffer:on_close()
    return
  end

  if kind == "worker" or kind == "hidden" then
    -- Start a frame through normal input, then deliver a result before the next frame.
    events[1] = { "textinput", "ready" }
    core.run_step()
    assert(view.drawn_value == "ready", "the initial input did not draw")
    now = now + 0.001
    visible = kind ~= "hidden"
    local pool = require("core.worker_pool").named("test-redraw", { worker_count = 1 })
    local ok, err = pcall(function()
      local complete, failure
      pool:submit({
        kind = "worker_pool_test",
        payload = { op = "echo", value = "after" },
        on_result = function(message)
          if message.type == "result" then
            view.value = message.payload.value
            -- A result handler owns its redraw. The probe adds none after delivery.
            core.redraw = true
          end
        end,
        on_complete = function() complete = true end,
        on_error = function(message) failure = tostring(message.error or message.payload) end,
      })
      -- Keep the UI clock fixed while the real worker starts and sends its result.
      local deadline = os.time() + 30
      while not complete and not failure and os.time() < deadline do
        core.run_step()
        system.sleep(0.001)
      end
      assert(complete, failure or "the worker result did not arrive")
      assert(view.value == "after", "the worker did not update the View")
      assert(view.drawn_value == "ready", "the result bypassed the frame limit or hidden state")
      now = now + 1 / config.fps
      if not visible then
        core.run_step()
        assert(view.drawn_value == "ready", "the hidden Project drew its result")
        visible = true
      end
      core.run_step()
      local snapshot = core.performance_snapshot
      assert(view.drawn_value == "after", string.format(
        "the worker result waited for another input event: drawn=%s value=%s pending=%s drew=%s frame_due=%s step_due=%s",
        tostring(view.drawn_value), tostring(view.value), tostring(core.redraw),
        tostring(snapshot.did_redraw), tostring(snapshot.next_frame_due_ms), tostring(snapshot.next_step_due_ms)))
    end)
    system.get_time = get_time
    pool:shutdown({ cancel_running = true, timeout_ms = 1000 })
    if not ok then error(err, 0) end
    return
  end

  command.add(nil, {
    ["test_redraw:set_value"] = function(value) view.value = value end,
  })
  local function change(value)
    if kind == "input" then
      events[1] = { "textinput", value }
    else
      assert(command.perform("test_redraw:set_value", value))
    end
  end
  change("after")
  core.run_step()
  assert(view.drawn_value == "after", kind .. " waited for another input event")

  -- Two changes arrive before the next frame. One frame must show the latest state.
  now = now + 0.001
  change("intermediate")
  core.run_step()
  change("latest")
  core.run_step()
  assert(view.drawn_value == "after", kind .. " bypassed the frame limit")
  now = now + 1 / config.fps
  core.run_step()
  assert(view.drawn_value == "latest", "the deferred " .. kind .. " lost its redraw")
end

local probe_kind = os.getenv("ANVIL_REDRAW_CADENCE_PROBE")
if probe_kind then
  local run = core.run
  core.run = function()
    core.run = run
    local ok, err = pcall(probe, probe_kind)
    if not ok then io.stderr:write(tostring(err), "\n") end
    os.exit(ok and 0 or 1)
  end
  return
end

test.describe("Redraw scheduling", function()
  local cases = {
    { "command", "draws programmatic commands without input and keeps the frame limit" },
    { "input", "retains input changes until the next frame without another event" },
    { "worker", "draws a worker result at the next frame without input" },
    { "hidden", "retains a hidden Project's worker result until rendering resumes" },
    { "save", "redraws the clean state after a background save without input" },
  }
  for _, case in ipairs(cases) do
    test.it(case[2], function()
      local root = USERDIR .. PATHSEP .. "redraw-cadence-" .. case[1]
      test.ok(require("core.common").mkdirp(root))
      local child
      local ok, err = pcall(function()
        child = process.start({ EXEFILE, "--direct", "run", "--no-quit", "tests/lua/ui/redraw_cadence.lua" }, {
          stdout = process.REDIRECT_PIPE,
          stderr = process.REDIRECT_STDOUT,
          env = { ANVIL_USERDIR = root, ANVIL_REDRAW_CADENCE_PROBE = case[1] },
        })
        local deadline = system.get_time() + 60
        while child:running() and system.get_time() < deadline do coroutine.yield(0.01) end
        test.not_ok(child:running(), "redraw probe did not finish")
        local output = child:read_stdout() or ""
        test.equal(child:returncode(), 0, output)
      end)
      if child and child:running() then child:kill(); child:wait(process.WAIT_INFINITE, 0.01) end
      test.ok(test.remove_tree(root))
      if not ok then error(err, 0) end
    end)
  end
end)
