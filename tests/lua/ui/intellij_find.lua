local core = require "core"
local command = require "core.command"
local test = require "core.test"

require "plugins.intellij_find"

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

local function selection_range(view)
  return view:with_selection_state(function()
    local line1, col1, line2, col2 = view.doc:get_selection(true)
    return { line1, col1, line2, col2 }
  end)
end

local function assert_selection(view, line1, col1, line2, col2)
  test.same({ line1, col1, line2, col2 }, selection_range(view))
end

test.describe("DocView Prompt Bar find", function()
  test.after_each(function(context)
    if core.active_view and core.active_view.local_find_input then
      command.perform("user:find-close")
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

  test.it("refines incremental input from the search origin instead of preserving a global match ordinal", function(context)
    local prefix = {}
    for i = 1, 12 do prefix[#prefix + 1] = "i before\n" end
    local origin_line = #prefix + 1
    local view, doc = open_editor(
      context,
      table.concat(prefix) .. "cursor input middle\n" .. "cursor input last\n"
    )
    doc:set_selection(origin_line, 1, origin_line, 1)

    test.ok(command.perform("find-replace:find"))
    core.root_panel:on_text_input("i")
    core.root_panel:on_text_input("n")

    assert_selection(view, origin_line, 8, origin_line, 10)
  end)

  test.it("opens on the currently selected match when the caret is at the selection end", function(context)
    local view, doc = open_editor(context, "input first\ninput second\n")
    doc:set_selection(1, 6, 1, 1)

    test.ok(command.perform("find-replace:find"))

    assert_selection(view, 1, 1, 1, 6)
  end)
end)
