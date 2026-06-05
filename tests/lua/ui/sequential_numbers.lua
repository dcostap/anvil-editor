local core = require "core"
local command = require "core.command"
local Doc = require "core.doc"
local DocView = require "core.docview"
local test = require "core.test"

require "plugins.sequential_numbers"

local function set_text(doc, text)
  doc.lines = {}
  for line in (text .. "\n"):gmatch("(.-\n)") do
    doc.lines[#doc.lines + 1] = line
  end
  if #doc.lines == 0 then doc.lines[1] = "\n" end
  doc:clear_undo_redo()
  doc:clean()
  doc:set_selection(1, 1)
end

local function text(doc)
  return table.concat(doc.lines)
end

local function selection(view)
  return view:get_selection_state().selections
end

local function new_view(context, source)
  local doc = Doc()
  set_text(doc, source)
  local view = DocView(doc)
  context.docs = context.docs or {}
  context.docs[#context.docs + 1] = doc
  core.set_active_view(view)
  return view, doc
end

local function set_view_selections(view, selections)
  view:with_selection_state(function()
    local doc = view.doc
    doc.selections = {}
    for i = 1, #selections, 4 do
      doc:set_selections((i - 1) / 4 + 1, selections[i], selections[i + 1], selections[i + 2], selections[i + 3], nil, i == 1 and nil or 0)
    end
    doc.last_selection = 1
  end)
end

local function run_command(initial, stride)
  test.ok(command.perform("doc:insert-sequential-numbers-on-cursors"))
  test.equal(core.active_view, core.global_prompt_bar)
  core.global_prompt_bar:set_text(tostring(initial))
  core.global_prompt_bar:submit()
  test.equal(core.active_view, core.global_prompt_bar)
  core.global_prompt_bar:set_text(tostring(stride))
  core.global_prompt_bar:submit()
end

test.describe("Sequential Numbers", function()
  test.before_each(function(context)
    context.previous_active_view = core.active_view
    if core.active_view == core.global_prompt_bar then
      core.global_prompt_bar:exit(false)
    end
  end)

  test.after_each(function(context)
    if core.active_view == core.global_prompt_bar then
      core.global_prompt_bar:exit(false)
    end
    for _, doc in ipairs(context.docs or {}) do
      doc:on_close()
    end
    if context.previous_active_view then
      core.set_active_view(context.previous_active_view)
    end
  end)

  test.it("inserts increasing numbers at collapsed carets", function(context)
    local view, doc = new_view(context, "a b c")
    set_view_selections(view, {
      1, 1, 1, 1,
      1, 3, 1, 3,
      1, 5, 1, 5,
    })
    local changes = 0
    function doc:on_text_change()
      changes = changes + 1
    end

    run_command(10, 5)

    test.equal(text(doc), "10a 15b 20c\n")
    test.equal(changes, 1)
    test.same(selection(view), {
      1, 3, 1, 3,
      1, 7, 1, 7,
      1, 11, 1, 11,
    })
  end)

  test.it("replaces selected ranges with decreasing numbers", function(context)
    local view, doc = new_view(context, "xx yy zz")
    set_view_selections(view, {
      1, 1, 1, 3,
      1, 4, 1, 6,
      1, 7, 1, 9,
    })

    run_command(3, -1)

    test.equal(text(doc), "3 2 1\n")
    test.same(selection(view), {
      1, 2, 1, 2,
      1, 4, 1, 4,
      1, 6, 1, 6,
    })
  end)
end)
