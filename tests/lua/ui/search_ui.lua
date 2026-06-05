local core = require "core"
local command = require "core.command"
local config = require "core.config"
local test = require "core.test"

require "plugins.search_ui"

local function track(context, kind, value)
  context[kind] = context[kind] or {}
  table.insert(context[kind], value)
  return value
end

local function remove_doc(doc)
  for i = #core.docs, 1, -1 do
    if core.docs[i] == doc then
      table.remove(core.docs, i)
      doc:on_close()
      return
    end
  end
end

local function open_editor(context, text)
  local doc = track(context, "docs", core.open_doc())
  if text and text ~= "" then doc:text_input(text) end
  local view = track(context, "views", core.root_panel:open_doc(doc))
  core.set_active_view(view)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 360, 180
  view.scroll.x, view.scroll.to.x = 0, 0
  view.scroll.y, view.scroll.to.y = 0, 0
  return view, doc
end

local function type_into_active_view(text)
  core.root_panel:on_text_input(text)
end

test.describe("Search UI replace", function()
  test.after_each(function(context)
    config.plugins.search_ui.replace_core_find = false
    if command.map["search-replace:hide"] then
      command.perform("search-replace:hide")
    end

    local root = core.root_panel.root_node
    for _, view in ipairs(context.views or {}) do
      local node = root:get_node_for_view(view)
      if node then node:remove_view(root, view) end
    end
    for _, doc in ipairs(context.docs or {}) do
      if doc:is_dirty() then doc:clean() end
      remove_doc(doc)
    end
  end)

  test.it("replace all applies multiple replacements as one document change", function(context)
    local view, doc = open_editor(context, "alpha beta alpha\nalpha")
    local changes = 0
    function doc:on_text_change()
      changes = changes + 1
    end

    config.plugins.search_ui.replace_core_find = true
    test.ok(command.perform("find-replace:replace"))
    type_into_active_view("alpha")
    test.ok(command.perform("search-replace:switch-input"))
    type_into_active_view("omega")

    test.ok(command.perform("search-replace:perform-replace"))

    test.equal(table.concat(doc.lines), "omega beta omega\nomega\n")
    test.equal(changes, 1)
  end)
end)
