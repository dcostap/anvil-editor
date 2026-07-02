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
  test.before_each(function()
    fuzzy_searcher._test.clear_prompt_history()
  end)

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

  test.it("restores the last prompt for a reopened empty mode and selects the query", function()
    fuzzy_searcher.open(">")
    core.fuzzy_searcher_active_view.input:set_text(">line wrapping")
    core.fuzzy_searcher_active_view:close()

    fuzzy_searcher.open(">")
    local picker = core.fuzzy_searcher_active_view

    test.equal(picker.input:get_text(), ">line wrapping")
    test.same({ picker.input.textview.doc:get_selection() }, { 1, 2, 1, #">line wrapping" + 1 })
  end)

  test.it("does not replace an auto-seeded grep prompt with saved history", function(context)
    fuzzy_searcher.open("#")
    core.fuzzy_searcher_active_view.input:set_text("#old grep")
    core.fuzzy_searcher_active_view:close()

    local view, doc = open_editor(context, "selected grep text\n")
    doc:set_selection(1, 1, 1, #"selected grep text" + 1)
    core.set_active_view(view)

    fuzzy_searcher.open("#")

    test.equal(picker_text(), '#"selected grep text"')
  end)

  test.it("cycles current mode prompt history without wrapping and keeps current text", function()
    fuzzy_searcher.open(">")
    core.fuzzy_searcher_active_view.input:set_text(">first")
    core.fuzzy_searcher_active_view:close()

    fuzzy_searcher.open(">")
    core.fuzzy_searcher_active_view.input:set_text(">second")
    core.fuzzy_searcher_active_view:close()

    fuzzy_searcher.open(">")
    local picker = core.fuzzy_searcher_active_view
    picker.input:set_text(">draft")

    command.perform("fuzzy-searcher:prompt-history-previous")
    test.equal(picker.input:get_text(), ">second")

    command.perform("fuzzy-searcher:prompt-history-previous")
    test.equal(picker.input:get_text(), ">first")

    command.perform("fuzzy-searcher:prompt-history-previous")
    test.equal(picker.input:get_text(), ">first")

    command.perform("fuzzy-searcher:prompt-history-next")
    test.equal(picker.input:get_text(), ">second")

    command.perform("fuzzy-searcher:prompt-history-next")
    test.equal(picker.input:get_text(), ">draft")

    command.perform("fuzzy-searcher:prompt-history-next")
    test.equal(picker.input:get_text(), ">draft")
  end)

  test.it("records the previous mode prompt when switching modes before close", function()
    fuzzy_searcher.open(">")
    local picker = core.fuzzy_searcher_active_view
    picker.input:set_text(">build")

    command.perform("fuzzy-searcher:open-projects")
    picker:close()

    fuzzy_searcher.open(">")
    picker = core.fuzzy_searcher_active_view

    test.equal(picker.input:get_text(), ">build")
    test.same(fuzzy_searcher._test.prompt_history(">"), { "build" })
  end)

  test.it("restores target mode history when switching from an empty query", function()
    fuzzy_searcher.open(">")
    core.fuzzy_searcher_active_view.input:set_text(">build")
    core.fuzzy_searcher_active_view:close()

    fuzzy_searcher.open("")
    command.perform("fuzzy-searcher:open-commands")
    local picker = core.fuzzy_searcher_active_view

    test.equal(picker.input:get_text(), ">build")
    test.same({ picker.input.textview.doc:get_selection() }, { 1, 2, 1, #">build" + 1 })
  end)
end)
