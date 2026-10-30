-- Measure Terminal history scrolling through the middle-click scrolling API.
local core = require "core"
local panes = require "core.panes"
local terminal = require "plugins.terminal"
local support = require "scenes.support"

local scene = {}

function scene.setup(context)
  local view = assert(terminal.open {
    cwd = context.root,
    shell = [[powershell.exe -NoLogo -NoProfile -NoExit -Command "1..1000 | ForEach-Object { [Console]::WriteLine('History line ' + $_) }; [Console]::WriteLine('SCROLL_READY')"]],
  })
  -- Close only this benchmark's shell before the normal quit prompt.
  local quit = core.quit
  core.quit = function(...)
    core.quit = quit
    panes.close(panes.pane_for_view(view), { force = true })
    return quit(...)
  end
  return view
end

function scene.ready(context)
  local view = context.view
  local bar = view.snapshot and view.snapshot.scrollbar
  if not bar or bar.total - bar.len < 900 then return false end
  return view.session:text_capture().text:find("SCROLL_READY", 1, true) ~= nil
    and support.background_settled(context)
end

function scene.action_name(_, index)
  return index <= 40 and "history-up" or "history-down"
end

function scene.dispatch(context, index)
  local view = context.view
  assert(core.active_view == view, "the Terminal lost input focus")
  context.before = view.snapshot.scrollbar.offset
  view:autoscroll((index <= 40 and -3 or 3) * view.cell_height)
end

function scene.action_ready(context)
  local offset = context.view.snapshot.scrollbar.offset
  assert(offset ~= context.before, "the Terminal history did not scroll")
  return true, tostring(offset)
end

function scene.state(context)
  return { offset = context.view.snapshot.scrollbar.offset }
end

return scene
