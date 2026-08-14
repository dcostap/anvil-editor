local core = require "core"
local test = require "core.test"
local fuzzy_searcher = require "plugins.fuzzy_searcher"

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
  local view = core.root_panel:open_buffer(buffer)
  context.buffers = context.buffers or {}
  context.views = context.views or {}
  table.insert(context.buffers, buffer)
  table.insert(context.views, view)
  core.set_active_view(view)
  return view, buffer
end

local function cleanup_editor_views(context)
  local root = core.root_panel.root_node
  for _, view in ipairs(context.views or {}) do
    local node = root:get_node_for_view(view)
    if node then node:remove_view(root, view) end
  end
  for _, buffer in ipairs(context.buffers or {}) do
    if buffer:is_dirty() then buffer:clean() end
    remove_buffer(buffer)
  end
end

test.describe("command palette toggle status", function()
  local saved_active_view

  test.before_each(function()
    saved_active_view = core.active_view
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
    if saved_active_view then core.set_active_view(saved_active_view) end
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
