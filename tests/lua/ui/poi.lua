local core = require "core"
local command = require "core.command"
local Doc = require "core.doc"
local DocView = require "core.docview"
local file_context = require "core.file_context"
local test = require "core.test"

local gitdiff = require "plugins.gitdiff_highlight"
local diffview = require "plugins.diffview"

local function wait_until(predicate, timeout, message)
  local deadline = system.get_time() + (timeout or 1)
  while not predicate() do
    if system.get_time() >= deadline then
      test.fail(message or "timed out waiting for condition", 2)
    end
    coroutine.yield(0.01)
  end
end

local function make_editor(text)
  local doc = Doc()
  doc:insert(1, 1, text)
  doc:clear_undo_redo()
  local view = DocView(doc)
  file_context.mark_editor_view(view)
  return view
end

test.describe("Point of Interest navigation", function()
  test.before_each(function(context)
    context.previous_active_view = core.active_view
  end)

  test.after_each(function(context)
    for _, view in ipairs(context.diffviews or {}) do
      view.doc_view_a.doc:on_close()
      view.doc_view_b.doc:on_close()
    end
    for _, doc in ipairs(context.docs or {}) do
      doc:on_close()
    end
    if context.previous_active_view then core.set_active_view(context.previous_active_view) end
  end)

  test.it("navigates an Editor's Git-change provider without wrapping", function()
    local view = make_editor("one\ntwo\nthree\nfour\n")
    gitdiff._set_state_for_tests(view.doc, {
      is_in_repo = true,
      ranges = {
        { type = "modification", current_start = 2, current_end = 3 },
        { type = "addition", current_start = 4, current_end = 5 },
      },
      line_index = {},
    })
    core.set_active_view(view)

    view.doc:set_selection(1, 3)
    test.ok(command.perform("poi:next"))
    test.same(view.doc.selections, { 2, 3, 2, 3 })

    test.ok(command.perform("poi:next"))
    test.same(view.doc.selections, { 4, 3, 4, 3 })

    test.ok(command.perform("poi:next"))
    test.same(view.doc.selections, { 4, 3, 4, 3 })

    test.ok(command.perform("poi:previous"))
    test.same(view.doc.selections, { 2, 3, 2, 3 })

    test.ok(command.perform("poi:previous"))
    test.same(view.doc.selections, { 2, 3, 2, 3 })
  end)

  test.it("does not expose language navigation commands without a symbol at the caret", function(context)
    local doc = Doc()
    doc:insert(1, 1, "!!!")
    doc:set_selection(1, 1)
    local view = DocView(doc)
    context.docs = { doc }
    core.set_active_view(view)

    test.not_ok(command.is_valid("language:show-references"))
    test.not_ok(command.is_valid("language:go-to-declaration"))
  end)

  test.it("treats DiffView hunk POIs as line-only region targets", function(context)
    local view = diffview.string_to_string(
      "aa\nleft-one\nbb\nleft-two\ncc",
      "aa\nbb\ncc",
      "left",
      "right",
      true
    )
    context.diffviews = { view }
    wait_until(function() return view.updater_idx == nil end, 1, "expected diff computation to finish")

    local left = view.doc_view_a
    core.set_active_view(left)
    left.doc:set_selection(4, 3)

    test.ok(command.perform("poi:previous"))
    test.same(left.doc.selections, { 2, 1, 2, 1 })
  end)

  test.it("keeps DiffView panes scroll-synchronized when navigating POIs", function(context)
    local left_lines, right_lines = {}, {}
    for i = 1, 120 do
      left_lines[#left_lines + 1] = i == 90 and "left-change" or ("same " .. i)
      right_lines[#right_lines + 1] = i == 90 and "right-change" or ("same " .. i)
    end
    local view = diffview.string_to_string(
      table.concat(left_lines, "\n"),
      table.concat(right_lines, "\n"),
      "left",
      "right",
      true
    )
    context.diffviews = { view }
    wait_until(function() return view.updater_idx == nil end, 1, "expected diff computation to finish")

    local left, right = view.doc_view_a, view.doc_view_b
    left.position.x, left.position.y = 0, 0
    right.position.x, right.position.y = 400, 0
    left.size.x, left.size.y = 300, 80
    right.size.x, right.size.y = 300, 80
    core.set_active_view(view)
    left.doc:set_selection(1, 1)

    test.ok(command.perform("poi:next"))
    test.same(left.doc.selections, { 90, 1, 90, 1 })
    test.equal(left.scroll.to.y, right.scroll.to.y)
  end)
end)
