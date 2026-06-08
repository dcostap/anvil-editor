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

  test.it("line comment at start comments selected lines in one document change", function(context)
    local view, doc = open_editor(context, "aa\nbb\ncc")
    set_view_selections(view, { 1, 2, 3, 3 })
    local changes = 0
    function doc:on_text_change()
      changes = changes + 1
    end

    test.ok(command.perform("user:comment-with-line-comment-at-start"))

    test.equal(table.concat(doc.lines), "//aa\n//bb\n//cc\n")
    test.equal(changes, 1)
    test.same(view_selections(view), { 1, 4, 3, 5 })
  end)

  test.it("line comment at start uncomments selected lines in one document change", function(context)
    local view, doc = open_editor(context, "//aa\n//bb\n//cc")
    set_view_selections(view, { 1, 4, 3, 5 })
    local changes = 0
    function doc:on_text_change()
      changes = changes + 1
    end

    test.ok(command.perform("user:comment-with-line-comment-at-start"))

    test.equal(table.concat(doc.lines), "aa\nbb\ncc\n")
    test.equal(changes, 1)
    test.same(view_selections(view), { 1, 2, 3, 3 })
  end)

  test.it("clone caret below until last line adds carets in one bulk selection update", function(context)
    local view, doc = open_editor(context, "aa\nbb\ncc\ndd")
    set_view_selections(view, { 2, 2, 2, 2 })

    test.ok(command.perform("user:clone-caret-below-until-last-line-intellij"))

    test.same(view_selections(view), {
      2, 2, 2, 2,
      3, 2, 3, 2,
      4, 2, 4, 2,
    })
    test.equal(view.selection_state.last_selection, 3)
  end)

  test.it("select all occurrences replaces selections in bulk", function(context)
    local view = open_editor(context, "aa xx aa\naa")
    set_view_selections(view, { 1, 1, 1, 3 })

    test.ok(command.perform("user:select-all-occurrences"))

    test.same(view_selections(view), {
      1, 3, 1, 1,
      1, 9, 1, 7,
      2, 3, 2, 1,
    })
    test.equal(view.selection_state.last_selection, 1)
  end)

  test.it("select all occurrences builds many selections without per-occurrence set_selections", function(context)
    local lines = {}
    for i = 1, 200 do lines[i] = "aa xx" end
    local view, doc = open_editor(context, table.concat(lines, "\n"))
    set_view_selections(view, { 1, 1, 1, 3 })

    local original_set_selections = doc.set_selections
    doc.set_selections = function()
      error("user:select-all-occurrences should use batched selection replacement")
    end

    local ok, err = pcall(function()
      test.ok(command.perform("user:select-all-occurrences"))
      local selections = view_selections(view)
      test.equal(#selections / 4, 200)
      test.same({ selections[1], selections[2], selections[3], selections[4] }, { 1, 3, 1, 1 })
      test.same({ selections[#selections - 3], selections[#selections - 2], selections[#selections - 1], selections[#selections] }, { 200, 3, 200, 1 })
      test.equal(view.selection_state.last_selection, 1)
    end)
    doc.set_selections = original_set_selections
    if not ok then error(err) end
  end)
end)
