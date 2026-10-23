-- Tests that need a live shell must wait for background startup to finish.
return function(view)
  local test = require "core.test"
  local deadline = system.get_time() + 30
  repeat
    view:service_session(true)
    if view.state == "running" then return view end
    if view.state == "failed" then break end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  view:on_close()
  test.fail(view.launch_error or "Terminal Session did not start")
end
