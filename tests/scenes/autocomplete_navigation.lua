local core = require "core"
local config = require "core.config"
local command = require "core.command"
local panes = require "core.panes"
local Editor = require "core.editor"
local autocomplete = require "plugins.autocomplete"
local support = require "scenes.support"
local scene = {}

function scene.setup(context)
  config.transitions = false
  local buffer = core.open_buffer()
  buffer:text_input("test")
  local view = panes.place(function() return Editor(buffer) end, { placement = "new", focus = true })
  autocomplete.add_provider("response-navigation", function(active)
    if active ~= view then return end
    return { query = "test", line = 1, query_col = 1, items = {
      { text = "test01" }, { text = "test02" }, { text = "test03" },
    } }
  end)
  autocomplete.trigger()
  assert(autocomplete.is_open(), "the autocomplete popup did not open")
  local draw = autocomplete.draw
  autocomplete.draw = function(active, ...)
    local selected = autocomplete.get_selected_suggestion()
    local result = draw(active, ...)
    if active == view and selected then context.drawn_selection = selected.text end
    return result
  end
  return view
end

function scene.ready(context)
  return context.drawn_selection == "test01" and support.background_settled(context)
end

function scene.action_name(_, index) return index % 2 == 1 and "next" or "previous" end

function scene.dispatch(context, index)
  context.expected = index % 2 == 1 and "test02" or "test01"
  assert(command.perform("autocomplete:" .. scene.action_name(context, index)))
end

function scene.action_ready(context)
  local selected = autocomplete.get_selected_suggestion()
  return selected and selected.text == context.expected, context.expected
end

function scene.action_visible(context) return context.drawn_selection == context.expected end
function scene.state(context) return { drawn_selection = context.drawn_selection } end

return scene
