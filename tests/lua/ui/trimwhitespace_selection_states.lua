local core = require "core"
local Doc = require "core.doc"
local DocView = require "core.docview"
local test = require "core.test"
local trimwhitespace = require "plugins.trimwhitespace"

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

test.describe("trimwhitespace selection states", function()
  test.before_each(function(context)
    context.previous_active_view = core.active_view
  end)

  test.after_each(function(context)
    if context.previous_active_view then
      core.set_active_view(context.previous_active_view)
    end
    for _, doc in ipairs(context.docs or {}) do
      doc:on_close()
    end
  end)

  test.it("preserves trailing whitespace before inactive view carets", function(context)
    local doc = Doc()
    set_text(doc, "aa   \nbb   \ncc   ")
    local main = DocView(doc)
    local side = DocView(doc)
    context.docs = { doc }

    main:with_selection_state(function()
      doc:set_selection(1, 1, 1, 1)
    end)
    side:with_selection_state(function()
      doc:set_selection(2, 5, 2, 5)
    end)
    core.set_active_view(main)

    trimwhitespace.trim(doc)

    test.equal(text(doc), "aa\nbb  \ncc\n")
    test.same(side:get_selection_state().selections, { 2, 5, 2, 5 })
  end)
end)
