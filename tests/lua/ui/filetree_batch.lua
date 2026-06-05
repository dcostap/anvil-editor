local core = require "core"
local test = require "core.test"
local filetree = require "plugins.filetree"

local function set_filetree_lines(lines)
  filetree.doc.lines = {}
  filetree.line_meta = {}
  for i, line in ipairs(lines) do
    filetree.doc.lines[i] = line
    filetree.line_meta[i] = { id = i }
  end
  filetree.doc:clear_undo_redo()
  filetree.doc:clean()
  filetree:snapshot_lines()
end

local function set_selections(selections)
  filetree:with_selection_state(function()
    filetree.doc:set_selection(selections[1], selections[2], selections[3], selections[4])
    for i = 5, #selections, 4 do
      filetree.doc:set_selections((i - 1) / 4 + 1, selections[i], selections[i + 1], selections[i + 2], selections[i + 3], nil, 0)
    end
  end)
end

local function text()
  return table.concat(filetree.doc.lines)
end

test.describe("File Tree batch behavior", function()
  test.after_each(function(context)
    core.filetree_clipboard = nil
    system.set_clipboard(context.previous_clipboard or "")
    if context.previous_on_text_change then
      filetree.doc.on_text_change = context.previous_on_text_change
    end
    filetree:refresh(false, false)
  end)

  test.before_each(function(context)
    context.previous_clipboard = system.get_clipboard()
    context.previous_on_text_change = filetree.doc.on_text_change
  end)

  test.it("cutting disjoint whole-line selections removes them in one document change", function()
    set_filetree_lines({ "aa\n", "bb\n", "cc\n", "dd\n" })
    set_selections({
      1, 1, 1, 1,
      3, 1, 3, 1,
    })
    local changes = 0
    function filetree.doc:on_text_change(...)
      changes = changes + 1
    end

    test.ok(filetree:copy_or_cut_lines(true))

    test.equal(text(), "bb\ndd\n")
    test.equal(changes, 1)
    test.equal(system.get_clipboard(), "aa\ncc\n")
    test.equal(filetree.line_meta[1].id, 2)
    test.equal(filetree.line_meta[2].id, 4)
  end)

  test.it("pasting metadata lines at multiple carets inserts them in one document change", function()
    set_filetree_lines({ "bb\n", "dd\n" })
    set_selections({
      1, 1, 1, 1,
      2, 1, 2, 1,
    })
    core.filetree_clipboard = {
      text = "aa\ncc\n",
      items = {
        { text = "aa", meta = { id = 10 } },
        { text = "cc", meta = { id = 30 } },
      },
    }
    system.set_clipboard("aa\ncc\n")
    local changes = 0
    function filetree.doc:on_text_change(...)
      changes = changes + 1
    end

    test.ok(filetree:paste_lines_with_metadata())

    test.equal(text(), "aa\ncc\nbb\naa\ncc\ndd\n")
    test.equal(changes, 1)
    test.equal(filetree.line_meta[1].id, 10)
    test.equal(filetree.line_meta[2].id, 30)
    test.equal(filetree.line_meta[3].id, 1)
    test.equal(filetree.line_meta[4].id, 10)
    test.equal(filetree.line_meta[5].id, 30)
    test.equal(filetree.line_meta[6].id, 2)
  end)
end)
