local core = require "core"
local command = require "core.command"
local config = require "core.config"
local test = require "core.test"

require "plugins.quote"
require "plugins.reflow"
require "plugins.tabularize"

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

local function text(doc)
  return table.concat(doc.lines)
end

local function count_doc_changes(doc)
  local changes = 0
  function doc:on_text_change()
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

  test.it("quote transforms the selected text in one document change", function(context)
    local view, doc = open_editor(context, "a\tb")
    view:with_selection_state(function()
      doc:set_selection(1, 1, 1, 4)
    end)
    local changes = count_doc_changes(doc)

    test.ok(command.perform("quote:quote"))

    test.equal(text(doc), '"a\\tb"\n')
    test.equal(changes(), 1)
  end)

  test.it("reflow transforms selected text through Doc:replace in one document change", function(context)
    context.old_line_limit = config.line_limit
    config.line_limit = 12
    local view, doc = open_editor(context, "alpha beta gamma delta")
    view:with_selection_state(function()
      doc:set_selection(1, 1, 1, math.huge)
    end)
    local changes = count_doc_changes(doc)

    test.ok(command.perform("reflow:reflow"))

    test.equal(text(doc), "alpha beta\ngamma delta\n")
    test.equal(changes(), 1)
  end)

  test.it("tabularize transforms selected lines through Doc:replace in one document change", function(context)
    local view, doc = open_editor(context, "a=1\nbb=22")
    view:with_selection_state(function()
      doc:set_selection(1, 1, 2, math.huge)
    end)
    local changes = count_doc_changes(doc)

    test.ok(command.perform("tabularize:tabularize"))
    test.equal(core.active_view, core.global_prompt_bar)
    core.global_prompt_bar:set_text("=")
    core.global_prompt_bar:submit()

    test.equal(text(doc), "a =1\nbb=22\n")
    test.equal(changes(), 1)
  end)
end)
