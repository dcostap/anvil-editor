-- Type short lines into a small source file, one character per action.
-- This is the baseline: the cheapest frame the editor draws for real input.
local core = require "core"
local command = require "core.command"
local support = require "scenes.support"

local scene = {}
-- One-letter words stay below the autocomplete threshold, so typing draws no popup.
local TYPED_TEXT = "a b c d e f g h i j "

function scene.setup(context)
  local path = context.path(context.settings.targets[1])
  local view = assert(core.open_file(path, { placement = "current", focus = true }))
  local line = math.min(3, #view.buffer.lines)
  view:with_selection_state(function() view.buffer:set_selection(line, math.huge) end)
  view:scroll_to_line(1, false, true)
  return view
end

-- The baseline starts after the Project's startup scans and indexes finish.
-- With `settings.during_startup`, typing starts while they still run.
function scene.ready(context)
  if context.settings.during_startup then return true end
  return support.git_settled(context.root, true) and support.background_settled(context)
end

-- Each typed line ends with a new line, so lines stay as short as typical code.
local function is_newline(index)
  return index % (#TYPED_TEXT + 1) == 0
end

function scene.action_name(_, index)
  return is_newline(index) and "newline" or "type-char"
end

function scene.dispatch(context, index)
  local view = context.view
  assert(core.active_view == view, "the editor lost input focus")
  context.revision = view.buffer.text_revision
  if is_newline(index) then
    assert(command.perform("core:newline"), "the editor did not accept a new line")
  else
    local offset = index % (#TYPED_TEXT + 1)
    core.on_event("textinput", TYPED_TEXT:sub(offset, offset))
  end
end

function scene.action_ready(context)
  return context.view.buffer.text_revision ~= context.revision, "typed"
end

return scene
