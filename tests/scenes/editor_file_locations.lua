local Buffer = require "core.buffer"
local Editor = require "core.editor"
local panes = require "core.panes"
local support = require "scenes.support"

local scene = {}

function scene.setup(context)
  local target = assert(context.settings.targets[1])
  local buffer = Buffer()
  buffer:insert(1, 1, string.rep("missing.lua:9:4 ", 2000) .. target .. ":1:1")
  buffer:set_selection(1, 1)
  buffer:clear_undo_redo()
  buffer:clean()
  context.target, context.buffer = target, buffer
  return panes.place(function() return Editor(buffer) end, { placement = "current", focus = true })
end

function scene.ready(context)
  return support.background_settled(context)
end

function scene.dispatch(context)
  context.buffer:insert(1, #context.buffer.lines[1], " " .. context.target .. ":3:1")
  context.buffer:clean()
end

function scene.action_ready(context)
  for _, point in ipairs(context.view:get_points_of_interest()) do
    if point.kind == "editor-file-location" and point.target_line == 3 then
      return true, "published the appended location"
    end
  end
  return false
end

return scene
