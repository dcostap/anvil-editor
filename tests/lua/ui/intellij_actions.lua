local core = require "core"
local command = require "core.command"
local test = require "core.test"

require "plugins.intellij_actions"

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
  return view, doc
end

local function set_view_selections(view, selections)
  view:with_selection_state(function()
    view.doc:set_selection(selections[1], selections[2], selections[3], selections[4])
    for i = 5, #selections, 4 do
      view.doc:set_selections((i - 1) / 4 + 1, selections[i], selections[i + 1], selections[i + 2], selections[i + 3], nil, 0)
    end
  end)
end

local function view_selections(view)
  return view:with_selection_state(function()
    return { table.unpack(view.doc.selections) }
  end)
end

test.describe("IntelliJ actions batch behavior", function()
  test.after_each(function(context)
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

  test.it("duplicate current line handles multiple selections in one document change", function(context)
    local view, doc = open_editor(context, "aa\nbb\ncc\ndd")
    set_view_selections(view, {
      1, 1, 1, 1,
      3, 1, 3, 1,
    })
    local changes = 0
    function doc:on_text_change()
      changes = changes + 1
    end

    test.ok(command.perform("user:duplicate-current-line"))

    test.equal(table.concat(doc.lines), "aa\naa\nbb\ncc\ncc\ndd\n")
    test.equal(changes, 1)
    test.same(view_selections(view), {
      2, 1, 2, 1,
      5, 1, 5, 1,
    })
  end)
end)
