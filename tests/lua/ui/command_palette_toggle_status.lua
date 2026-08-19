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

    fuzzy_searcher.open(">toggle_line_wrapping")
    local picker = core.fuzzy_searcher_active_view
    test.not_nil(picker)
    picker:refresh(">toggle_line_wrapping")

    local item
    for _, result in ipairs(picker.results or {}) do
      if result.command == "editor:toggle_line_wrapping" then
        item = result
        break
      end
    end

    test.not_nil(item)
    test.equal(item.label, "editor:toggle_line_wrapping")
    test.same(item.status, {
      prefix = " [Currently: ",
      value = "ON",
      suffix = "]",
      state = true,
    })
  end)

  test.it("opens the command palette with zero Panes", function()
    panes.reset_for_tests()
    core.active_view = nil
    local ok, err = pcall(fuzzy_searcher.open, ">")
    test.ok(ok, err)
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    picker:close()
    test.is_nil(core.active_view)
  end)

  test.it("restores the source Pane when the command palette closes", function(context)
    local view = open_editor(context, "source\n")
    fuzzy_searcher.open(">")
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    picker:close()
    test.equal(core.active_view, view)
  end)
end)
