local core = require "core"
local command = require "core.command"
local config = require "core.config"
local Doc = require "core.doc"
local DocView = require "core.docview"
local test = require "core.test"

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

local function new_shared_views(context, text)
  local doc = Doc()
  set_text(doc, text)
  local main = DocView(doc)
  local side = DocView(doc)
  context.docs = context.docs or {}
  context.views = context.views or {}
  context.docs[#context.docs + 1] = doc
  context.views[#context.views + 1] = main
  context.views[#context.views + 1] = side
  main.__test_name = "main characterization DocView"
  side.__test_name = "side characterization DocView"
  return doc, main, side
end

local function set_view_selection(view, line1, col1, line2, col2)
  view:with_selection_state(function()
    view.doc:set_selection(line1, col1, line2, col2)
  end)
end

local function set_view_selections(view, selections, last_selection)
  view:with_selection_state(function()
    local doc = view.doc
    doc.selections = {}
    for i = 1, #selections, 4 do
      doc:set_selections((i - 1) / 4 + 1, selections[i], selections[i + 1], selections[i + 2], selections[i + 3], nil, i == 1 and nil or 0)
    end
    doc.last_selection = last_selection or 1
  end)
end

local function selection(view)
  return view:get_selection_state().selections
end

local function text(doc)
  return table.concat(doc.lines)
end

test.describe("Document View Selection State edit characterization", function()
  test.before_each(function(context)
    context.previous_active_view = core.active_view
    context.previous_clipboard = system.get_clipboard()
    context.previous_cursor_clipboard = core.cursor_clipboard
    context.previous_cursor_clipboard_whole_line = core.cursor_clipboard_whole_line
    context.previous_tab_type = config.tab_type
    context.previous_indent_size = config.indent_size
    config.tab_type = "soft"
    config.indent_size = 2
  end)

  test.after_each(function(context)
    config.tab_type = context.previous_tab_type
    config.indent_size = context.previous_indent_size
    system.set_clipboard(context.previous_clipboard or "")
    core.cursor_clipboard = context.previous_cursor_clipboard
    core.cursor_clipboard_whole_line = context.previous_cursor_clipboard_whole_line
    if context.previous_active_view then
      core.set_active_view(context.previous_active_view)
    end
    for _, doc in ipairs(context.docs or {}) do
      doc:on_close()
    end
  end)

  test.it("an insert in one Document View moves inactive Selection States through the same document change", function(context)
    local doc, main, side = new_shared_views(context, "alpha\nbeta")
    set_view_selection(main, 1, 1, 1, 1)
    set_view_selection(side, 2, 2, 2, 2)

    main:with_selection_state(function()
      doc:text_input("new\n")
    end)

    test.equal(text(doc), "new\nalpha\nbeta\n")
    test.same(selection(main), { 2, 1, 2, 1 })
    test.same(selection(side), { 3, 2, 3, 2 })
  end)

  test.it("a remove in one Document View moves inactive Selection States upward", function(context)
    local doc, main, side = new_shared_views(context, "alpha\nbeta")
    set_view_selection(main, 1, 1, 1, 1)
    set_view_selection(side, 2, 3, 2, 3)

    main:with_selection_state(function()
      doc:remove(1, 1, 2, 1)
    end)

    test.equal(text(doc), "beta\n")
    test.same(selection(main), { 1, 1, 1, 1 })
    test.same(selection(side), { 1, 3, 1, 3 })
  end)

  test.it("undo from another Document View does not restore the edit owner's selection into the active view", function(context)
    local doc, main, side = new_shared_views(context, "abc")
    set_view_selection(main, 1, 2, 1, 2)
    set_view_selection(side, 1, 4, 1, 4)

    main:with_selection_state(function()
      doc:text_input("X")
    end)
    test.equal(text(doc), "aXbc\n")
    test.same(selection(main), { 1, 3, 1, 3 })
    test.same(selection(side), { 1, 5, 1, 5 })

    side:with_selection_state(function()
      doc:undo()
    end)

    test.equal(text(doc), "abc\n")
    test.same(selection(side), { 1, 4, 1, 4 })
    test.same(selection(main), { 1, 2, 1, 2 })
  end)

  test.it("paste inserts one external clipboard payload at each collapsed caret", function(context)
    local doc, main = new_shared_views(context, "ab\ncd")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 2, 1, 2,
      2, 2, 2, 2,
    })
    core.cursor_clipboard = { full = "" }
    core.cursor_clipboard_whole_line = {}
    system.set_clipboard("X")
    local changes = 0
    function doc:on_text_change()
      changes = changes + 1
    end

    test.ok(command.perform("doc:paste"))

    test.equal(text(doc), "aXb\ncXd\n")
    test.equal(changes, 1)
    test.same(selection(main), {
      1, 3, 1, 3,
      2, 3, 2, 3,
    })
  end)

  test.it("paste inserts matching per-caret clipboard payloads", function(context)
    local doc, main = new_shared_views(context, "ab\ncd")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 2, 1, 2,
      2, 2, 2, 2,
    })
    core.cursor_clipboard = {
      [1] = "A",
      [2] = "B",
      full = "A\nB",
    }
    core.cursor_clipboard_whole_line = {
      [1] = false,
      [2] = false,
    }
    system.set_clipboard("A\nB")

    test.ok(command.perform("doc:paste"))

    test.equal(text(doc), "aAb\ncBd\n")
    test.same(selection(main), {
      1, 3, 1, 3,
      2, 3, 2, 3,
    })
  end)

  test.it("whole-line paste inserts each payload at the start of each caret line", function(context)
    local doc, main = new_shared_views(context, "aa\nbb")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 1, 1, 1,
      2, 1, 2, 1,
    })
    core.cursor_clipboard = {
      [1] = "XX",
      [2] = "YY",
      full = "XX\nYY\n",
    }
    core.cursor_clipboard_whole_line = {
      [1] = true,
      [2] = true,
    }
    system.set_clipboard("XX\nYY\n")

    test.ok(command.perform("doc:paste"))

    test.equal(text(doc), "XX\naa\nYY\nbb\n")
    test.same(selection(main), {
      2, 1, 2, 1,
      4, 1, 4, 1,
    })
  end)

  test.it("duplicate-lines preserves independent multi-line selections after duplication", function(context)
    local doc, main = new_shared_views(context, "aa\nbb\ncc\ndd")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 2, 1, 2,
      3, 2, 4, 2,
    })

    test.ok(command.perform("doc:duplicate-lines"))

    test.equal(text(doc), "aa\naa\nbb\ncc\ndd\ncc\ndd\n\n")
    test.same(selection(main), {
      2, 2, 2, 2,
      6, 2, 7, 2,
    })
  end)

  test.it("delete-lines removes each selected line block and leaves carets at removal points", function(context)
    local doc, main = new_shared_views(context, "aa\nbb\ncc\ndd\nee")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 2, 1, 2,
      3, 1, 4, 2,
    })

    test.ok(command.perform("doc:delete-lines"))

    test.equal(text(doc), "bb\nee\n")
    test.same(selection(main), {
      1, 2, 1, 2,
      2, 1, 2, 1,
    })
  end)

  test.it("join-lines joins each selected line range with spaces", function(context)
    local doc, main = new_shared_views(context, "aa\n  bb\ncc")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 1, 1, 1,
      2, 1, 3, 1,
    })

    test.ok(command.perform("doc:join-lines"))

    test.equal(text(doc), "aa bb cc\n")
    test.same(selection(main), {
      1, 9, 1, 9,
      1, 9, 1, 9,
    })
  end)

  test.it("join-lines batches independent selected line ranges", function(context)
    local doc, main = new_shared_views(context, "aa\n  bb\ncc\n  dd\nee")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 1, 2, 1,
      4, 1, 5, 1,
    })

    test.ok(command.perform("doc:join-lines"))

    test.equal(text(doc), "aa bb\ncc\n  dd ee\n")
    test.same(selection(main), {
      1, 6, 1, 6,
      3, 8, 3, 8,
    })
  end)

  test.it("move-lines-up moves selected line blocks upward", function(context)
    local doc, main = new_shared_views(context, "aa\nbb\ncc\ndd")
    core.set_active_view(main)
    set_view_selections(main, {
      2, 1, 2, 1,
      4, 1, 4, 1,
    })

    test.ok(command.perform("doc:move-lines-up"))

    test.equal(text(doc), "bb\naa\ndd\ncc\n\n")
    test.same(selection(main), {
      1, 1, 1, 1,
      3, 1, 3, 1,
    })
  end)

  test.it("move-lines-down moves selected line blocks downward", function(context)
    local doc, main = new_shared_views(context, "aa\nbb\ncc\ndd")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 1, 1, 1,
      3, 1, 3, 1,
    })

    test.ok(command.perform("doc:move-lines-down"))

    test.equal(text(doc), "bb\naa\ndd\ncc\n\n")
    test.same(selection(main), {
      2, 1, 2, 1,
      4, 1, 4, 1,
    })
  end)

  test.it("move-lines-up batches independent non-final selected lines", function(context)
    local doc, main = new_shared_views(context, "aa\nbb\ncc\ndd\nee")
    core.set_active_view(main)
    set_view_selections(main, {
      2, 1, 2, 1,
      4, 1, 4, 1,
    })

    test.ok(command.perform("doc:move-lines-up"))

    test.equal(text(doc), "bb\naa\ndd\ncc\nee\n")
    test.same(selection(main), {
      1, 1, 1, 1,
      3, 1, 3, 1,
    })
  end)

  test.it("move-lines-down batches independent non-final selected lines", function(context)
    local doc, main = new_shared_views(context, "aa\nbb\ncc\ndd\nee")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 1, 1, 1,
      3, 1, 3, 1,
    })

    test.ok(command.perform("doc:move-lines-down"))

    test.equal(text(doc), "bb\naa\ndd\ncc\nee\n")
    test.same(selection(main), {
      2, 1, 2, 1,
      4, 1, 4, 1,
    })
  end)

  test.it("toggle-block-comments wraps and unwraps a selected range", function(context)
    local doc, main = new_shared_views(context, "aa")
    doc.syntax.block_comment = { "/*", "*/" }
    core.set_active_view(main)
    set_view_selection(main, 1, 1, 1, 3)

    test.ok(command.perform("doc:toggle-block-comments"))
    test.equal(text(doc), "/* aa */\n")
    test.same(selection(main), { 1, 1, 1, 9 })

    test.ok(command.perform("doc:toggle-block-comments"))
    test.equal(text(doc), "aa\n")
    test.same(selection(main), { 1, 1, 1, 3 })
  end)

  test.it("toggle-line-comments comments and uncomments multiple selected line ranges", function(context)
    local doc, main = new_shared_views(context, "aa\nbb\ncc")
    doc.syntax.comment = "//"
    core.set_active_view(main)
    set_view_selections(main, {
      1, 1, 1, 1,
      2, 1, 3, 1,
    })

    test.ok(command.perform("doc:toggle-line-comments"))
    test.equal(text(doc), "// aa\n// bb\ncc\n")
    test.same(selection(main), {
      1, 1, 1, 1,
      2, 1, 2, 6,
    })

    test.ok(command.perform("doc:toggle-line-comments"))
    test.equal(text(doc), "aa\nbb\ncc\n")
    test.same(selection(main), {
      1, 1, 1, 1,
      2, 1, 2, 3,
    })
  end)

  test.it("indent at a collapsed caret in leading whitespace indents the line and jumps to text", function(context)
    local doc, main = new_shared_views(context, "  aa")
    core.set_active_view(main)
    set_view_selection(main, 1, 2, 1, 2)

    test.ok(command.perform("doc:indent"))

    test.equal(text(doc), "    aa\n")
    test.same(selection(main), { 1, 5, 1, 5 })
  end)

  test.it("indent at a collapsed caret after leading text inserts the stop text", function(context)
    local doc, main = new_shared_views(context, "aa")
    core.set_active_view(main)
    set_view_selection(main, 1, 2, 1, 2)

    test.ok(command.perform("doc:indent"))

    test.equal(text(doc), "a a\n")
    test.same(selection(main), { 1, 3, 1, 3 })
  end)

  test.it("indent and unindent adjust multiple selected line ranges", function(context)
    local doc, main = new_shared_views(context, "aa\nbb\ncc")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 1, 1, 1,
      2, 1, 3, 1,
    })

    test.ok(command.perform("doc:indent"))
    test.equal(text(doc), "  aa\n  bb\ncc\n")
    test.same(selection(main), {
      1, 3, 1, 3,
      2, 3, 2, 5,
    })

    test.ok(command.perform("doc:unindent"))
    test.equal(text(doc), "aa\nbb\ncc\n")
    test.same(selection(main), {
      1, 1, 1, 1,
      2, 1, 2, 3,
    })
  end)

  test.it("movement commands preserve multi-caret state and subsequent text input edits moved selections", function(context)
    local doc, main = new_shared_views(context, "abcd\nwxyz")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 1, 1, 1,
      2, 2, 2, 2,
    })

    test.ok(command.perform("doc:move-to-next-char"))
    test.same(selection(main), {
      1, 2, 1, 2,
      2, 3, 2, 3,
    })

    test.ok(command.perform("doc:select-to-next-char"))
    test.same(selection(main), {
      1, 3, 1, 2,
      2, 4, 2, 3,
    })

    core.root_panel:on_text_input("X")

    test.equal(text(doc), "aXcd\nwxXz\n")
    test.same(selection(main), {
      1, 3, 1, 3,
      2, 4, 2, 4,
    })
  end)

  test.it("paste handles mixed collapsed carets and selected ranges through the document command", function(context)
    local doc, main = new_shared_views(context, "abc def ghi\none two three")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 1, 1, 4,
      1, 5, 1, 5,
      2, 5, 2, 8,
    })
    core.cursor_clipboard = { full = "" }
    core.cursor_clipboard_whole_line = {}
    system.set_clipboard("P")

    test.ok(command.perform("doc:paste"))

    test.equal(text(doc), "P Pdef ghi\none P three\n")
    test.same(selection(main), {
      1, 2, 1, 2,
      1, 4, 1, 4,
      2, 6, 2, 6,
    })

  end)
end)
