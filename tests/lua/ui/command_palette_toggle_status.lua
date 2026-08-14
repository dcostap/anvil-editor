local core = require "core"
local test = require "core.test"
local fuzzy_searcher = require "plugins.fuzzy_searcher"
local Editor = require "core.editor"
local panes = require "core.panes"

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
  local buffer = core.open_buffer()
  if text and text ~= "" then buffer:text_input(text) end
  local view = panes.place(function() return Editor(buffer) end, { placement = "new", focus = true })
  context.buffers = context.buffers or {}
  context.views = context.views or {}
  table.insert(context.buffers, buffer)
  table.insert(context.views, view)
  return view, buffer
end

local function cleanup_editor_views(context)
  panes.reset_for_tests()
  for _, buffer in ipairs(context.buffers or {}) do
    if buffer:is_dirty() then buffer:clean() end
    remove_buffer(buffer)
  end
end

test.describe("command palette toggle status", function()
  test.before_each(function()
    panes.reset_for_tests()
    if core.active_view == core.global_prompt_bar then
      core.global_prompt_bar:exit(false)
    end
  end)

  test.after_each(function(context)
    if core.active_view == core.global_prompt_bar then
      core.global_prompt_bar:exit(false)
    end
    if core.fuzzy_searcher_active_view then
      core.fuzzy_searcher_active_view:close()
    end
    cleanup_editor_views(context)
  end)

  test.it("shows status in the fuzzy command palette against the source view", function(context)
    local view = open_editor(context, "wrapped text\n")
    view:set_wrapping_enabled(true)

    fuzzy_searcher.open(">line-wrapping")
    local picker = core.fuzzy_searcher_active_view
    test.not_nil(picker)
    picker:refresh(">line-wrapping")

    local item
    for _, result in ipairs(picker.results or {}) do
      if result.command == "line-wrapping:toggle" then
        item = result
        break
      end
    end

    test.not_nil(item)
    test.equal(item.label, "line-wrapping:toggle")
    test.same(item.status, {
      prefix = " [Currently: ",
      value = "ON",
      suffix = "]",
      state = true,
    })
  end)
end)
