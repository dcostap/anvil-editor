local core = require "core"
local command = require "core.command"
local test = require "core.test"

local fuzzy_searcher = require "plugins.fuzzy_searcher"

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

local function cleanup_editor_views(context)
  local root = core.root_panel.root_node
  for _, view in ipairs(context.views or {}) do
    local node = root:get_node_for_view(view)
    if node then node:remove_view(root, view) end
  end
  for _, doc in ipairs(context.docs or {}) do
    if doc:is_dirty() then doc:clean() end
    remove_doc(doc)
  end
end

local function picker_text()
  local picker = core.fuzzy_searcher_active_view
  return picker and picker.input and picker.input:get_text() or nil
end

test.describe("Fuzzy Searcher mode switching", function()
  test.it("recognizes command mode prefixes in prompt text", function()
    local split = fuzzy_searcher._test.split_mode_prefix
    test.same({ split(">commands") }, { ">", "commands" })
    test.same({ split("@projects") }, { "@", "projects" })
    test.same({ split("#grep") }, { "#", "grep" })
    test.same({ split("$symbols") }, { "$", "symbols" })
    test.same({ split("$$document symbols") }, { "$$", "document symbols" })
    test.same({ split("files") }, { "", "files" })
  end)

  test.after_each(function(context)
    if core.fuzzy_searcher_active_view then
      core.fuzzy_searcher_active_view:close()
    end
    cleanup_editor_views(context)
  end)

  test.it("places the caret after the initial mode prefix when opened", function()
    fuzzy_searcher.open("#")

    local picker = core.fuzzy_searcher_active_view

    test.same({ picker.input.textview.doc:get_selection() }, { 1, 2, 1, 2 })
  end)

  test.it("preserves prompt text and replaces the mode prefix when another fuzzy mode is opened", function(context)
    local view, doc = open_editor(context, "underlying selection should not be copied\n")
    doc:set_selection(1, 1, 1, 20)
    core.set_active_view(view)

    fuzzy_searcher.open("#")
    local picker = core.fuzzy_searcher_active_view
    picker.input:set_text("#typed query")
    picker.input.textview.doc:set_selection(1, 8, 1, 8)

    test.ok(command.perform("fuzzy-searcher:open-projects"), "expected project mode command to run")

    test.equal(picker_text(), "@typed query")
    test.equal(core.fuzzy_searcher_active_view, picker, "expected the existing picker to stay open")
    test.same({ picker.input.textview.doc:get_selection() }, { 1, 8, 1, 8 })
  end)

  test.it("does not reseed grep mode from the underlying editor selection while the picker is active", function(context)
    local view, doc = open_editor(context, "copy me from editor\n")
    doc:set_selection(1, 1, 1, 8)
    core.set_active_view(view)

    fuzzy_searcher.open("@")
    local picker = core.fuzzy_searcher_active_view
    picker.input:set_text("@project query")

    command.perform("fuzzy-searcher:open-grep")

    test.equal(picker_text(), "#project query")
  end)

  test.it("adds the requested mode prefix when the active picker text has no mode prefix", function()
    fuzzy_searcher.open("")
    core.fuzzy_searcher_active_view.input:set_text("plain query")

    command.perform("fuzzy-searcher:open-commands")

    test.equal(picker_text(), ">plain query")
  end)
end)
