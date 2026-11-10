local core = require "core"
local panes = require "core.panes"
local Editor = require "core.editor"
local support = require "scenes.support"
local scene = {}

-- Fixed suggestions isolate prompt input and drawing from filesystem timing.
local folder = "plans" .. PATHSEP
local child = folder .. "child" .. PATHSEP
local folder_items, child_items = { folder }, { child }
local input = "plans" .. PATHSEP .. "CHILD" .. PATHSEP

function scene.setup(context)
  local buffer = core.open_buffer()
  local view = panes.place(function() return Editor(buffer) end, { placement = "new", focus = true })
  local bar = core.global_prompt_bar
  bar:enter("Save As", {
    suggest = function(text)
      if #text < #folder then return folder_items end
      if #text < #child then return child_items end
      return {}
    end,
  })
  context.bar = bar
  return view
end

function scene.ready(context) return support.background_settled(context) end

function scene.dispatch(context, index)
  local pos = (index - 1) % #input + 1
  if pos == 1 then context.bar:set_text("") end
  context.bar:on_text_input(input:sub(pos, pos))
end

function scene.action_ready() return true end

return scene
