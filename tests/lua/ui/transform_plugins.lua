local core = require "core"
local command = require "core.command"
local config = require "core.config"
local test = require "core.test"
local Editor = require "core.editor"
local panes = require "core.panes"

require "plugins.quote"
require "plugins.reflow"
require "plugins.tabularize"

local function track(context, kind, value)
  context[kind] = context[kind] or {}
  table.insert(context[kind], value)
  return value
end

local function remove_buffer(buffer)
  for i = #core.buffers, 1, -1 do
    if core.buffers[i] == buffer then
      table.remove(core.buffers, i)
      buffer:on_close()
      return
    end
  end
end

local function open_editor(context, text)
  local buffer = track(context, "buffers", core.open_buffer())
  if text and text ~= "" then buffer:text_input(text) end
  local view = track(context, "views", panes.place(function() return Editor(buffer) end,
    { placement = "new", focus = true }))
  return view, buffer
end

local function text(buffer)
  return table.concat(buffer.lines)
end

local function count_buffer_changes(buffer)
  local changes = 0
  function buffer:on_text_change()
    changes = changes + 1
  end
  return function() return changes end
end

test.describe("transform plugin batch behavior", function()
  test.after_each(function(context)
    if core.active_view == core.global_prompt_bar then
      core.global_prompt_bar:exit(false)
    end
    if context.old_line_limit then config.line_limit = context.old_line_limit end

    panes.reset_for_tests()
    for _, buffer in ipairs(context.buffers or {}) do
      if buffer:is_dirty() then buffer:clean() end
      remove_buffer(buffer)
    end
  end)

  test.it("quote transforms the selected text in one buffer change", function(context)
    local view, buffer = open_editor(context, "a\tb")
    view:with_selection_state(function()
      buffer:set_selection(1, 1, 1, 4)
    end)
    local changes = count_buffer_changes(buffer)

    test.ok(command.perform("quote:quote"))

    test.equal(text(buffer), '"a\\tb"\n')
    test.equal(changes(), 1)
  end)

  test.it("reflow transforms selected text through Buffer:replace in one buffer change", function(context)
    context.old_line_limit = config.line_limit
    config.line_limit = 12
    local view, buffer = open_editor(context, "alpha beta gamma delta")
    view:with_selection_state(function()
      buffer:set_selection(1, 1, 1, math.huge)
    end)
    local changes = count_buffer_changes(buffer)

    test.ok(command.perform("reflow:reflow"))

    test.equal(text(buffer), "alpha beta\ngamma delta\n")
    test.equal(changes(), 1)
  end)

  test.it("tabularize transforms selected lines through Buffer:replace in one buffer change", function(context)
    local view, buffer = open_editor(context, "a=1\nbb=22")
    view:with_selection_state(function()
      buffer:set_selection(1, 1, 2, math.huge)
    end)
    local changes = count_buffer_changes(buffer)

    test.ok(command.perform("tabularize:tabularize"))
    test.equal(core.active_view, core.global_prompt_bar)
    core.global_prompt_bar:set_text("=")
    core.global_prompt_bar:submit()

    test.equal(text(buffer), "a =1\nbb=22\n")
    test.equal(changes(), 1)
  end)
end)
