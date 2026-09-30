local core = require "core"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local wrapping = require "core.linewrapping"
local test = require "core.test"

test.it("finishes a pending wrapped layout while Enter adds lines", function()
  local buffer = Buffer()
  buffer:insert(1, 1, ("words words words words words words\n"):rep(16))
  local view = TextView(buffer)
  view.size.x, view.size.y = 400, 500
  view:set_wrapping_enabled(true)
  wrapping.complete_async_reconstruction(view)
  local add_thread, get_time = core.add_thread, system.get_time
  local clock, jobs, completed = get_time(), {}, false
  core.add_thread = function(fn) jobs[#jobs + 1] = coroutine.create(fn) end
  system.get_time = function() clock = clock + .001; return clock end
  local ok, err = pcall(function()
    view.size.x = 200
    wrapping.reconstruct_breaks_async(view, view:get_font(), wrapping.compute_wrap_width(view), {
      on_complete = function(success) completed = success end,
    })
    for _ = 1, 60 do
      view:with_selection_state(function() buffer:set_selection(1, 1) end)
      view:on_text_input("\n")
      local scheduled = jobs
      jobs = {}
      for _, job in ipairs(scheduled) do
        local resumed, failure = coroutine.resume(job)
        if not resumed then error(failure, 0) end
        if coroutine.status(job) ~= "dead" then jobs[#jobs + 1] = job end
      end
      if completed then break end
    end
  end)
  core.add_thread, system.get_time = add_thread, get_time
  local fresh = TextView(buffer)
  fresh.size.x, fresh.size.y = view.size.x, view.size.y
  fresh:set_wrapping_enabled(true)
  wrapping.complete_async_reconstruction(fresh)
  if ok then
    ok, err = pcall(function()
      test.ok(completed, "Enter kept restarting the pending layout")
      for line = 1, #buffer.lines do
        test.equal(view:get_visual_row_count_for_line(line), fresh:get_visual_row_count_for_line(line))
      end
    end)
  end
  view:release_owned_features("test")
  fresh:release_owned_features("test")
  if not ok then error(err, 0) end
end)
