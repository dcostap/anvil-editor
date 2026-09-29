local core = require "core"
local command = require "core.command"
local test = require "core.test"
local panes = require "core.panes"
local Editor = require "core.editor"
require "plugins.intellij_find"

local function open(context, text)
  local buffer = core.open_buffer()
  context.buffer = buffer
  buffer:text_input(text)
  local view = panes.place(function() return Editor(buffer) end, { placement = "new", focus = true })
  view.size.x, view.size.y = 800, 600
  view:set_wrapping_enabled(false)
  view:with_selection_state(function() buffer:set_selection(1, 1) end)
  command.perform("editor:find")
  return view, buffer, core.active_view
end

local function settle(view, state)
  for _ = 1, 10000 do
    view:update()
    if not state.pending then return end
    coroutine.yield()
  end
  error("Find did not finish")
end

test.describe("Local Find sliced results", function()
  test.after_each(function(context)
    command.perform("editor:find_close")
    panes.reset_for_tests()
    if context.buffer then
      context.buffer:clean()
      for i, b in ipairs(core.buffers) do
        if b == context.buffer then table.remove(core.buffers, i); b:on_close(); break end
      end
    end
  end)

  test.it("shows pending results and never publishes an old query or Buffer revision", function(context)
    local view, buffer, input = open(context, ("nothing here\n"):rep(12000) .. "old NEW new\n")
    local state = input.local_find_state
    input:set_text("old")
    test.ok(state.info:find("Searching", 1, true), "a full scan must show pending status")
    input:set_text("new")
    buffer:apply_edits({ { line1 = 12001, col1 = 1, line2 = 12001, col2 = 12, text = "new NEW" } })
    settle(view, state)
    test.same(state.matches, {
      { line = 12001, col1 = 1, col2 = 4 }, { line = 12001, col1 = 5, col2 = 8 },
    })
    test.equal(state.info, "1 / 2")
    test.equal(state.current, 1)
    test.same(view:with_selection_state(function()
      local l1, c1, l2, c2 = buffer:get_selection(true)
      return { l1, c1, l2, c2 }
    end),
      { 12001, 1, 12001, 4 })
  end)

  test.it("keeps regex rules, errors, and current-match choice after a sliced scan", function(context)
    local view, buffer, input = open(context, ("----\n"):rep(12000) .. "aA aa\n")
    local state = input.local_find_state
    input:set_text("a")
    settle(view, state)
    test.equal(state.info, "1 / 4")
    command.perform("editor:toggle_sensitivity")
    settle(view, state)
    test.equal(state.info, "1 / 3")
    command.perform("editor:toggle_regex")
    input:set_text("^a")
    settle(view, state)
    test.same(state.matches, {
      { line = 12001, col1 = 1, col2 = 3 },
    })
    test.equal(state.info, "1 / 1")
    input:set_text("^")
    settle(view, state)
    test.equal(#state.matches, 48005)
    test.same(state.matches[48001], { line = 12001, col1 = 1, col2 = 2 })
    test.equal(state.info, "48001 / 48005")
    input:set_text("[")
    settle(view, state)
    test.equal(state.info, "Invalid regex")
    test.equal(state.current, 0)
    test.same(state.matches, {})
  end)

  test.it("keeps navigation requested before the final count arrives", function(context)
    local view, _, input = open(context, ("----\n"):rep(12000) .. "hit hit hit\n")
    local state = input.local_find_state
    input:set_text("hit")
    test.ok(state.info:find("Searching", 1, true))
    test.ok(command.perform("editor:find_field_next"))
    test.ok(command.perform("editor:find_field_next"))
    settle(view, state)
    test.same(state.matches, {
      { line = 12001, col1 = 1, col2 = 4 }, { line = 12001, col1 = 5, col2 = 8 },
      { line = 12001, col1 = 9, col2 = 12 },
    })
    test.equal(state.current, 3)
    test.equal(state.info, "3 / 3")
    command.perform("editor:find_field_next")
    test.equal(state.current, 1)
    test.equal(state.info, "1 / 3")
    command.perform("editor:find_field_previous")
    test.equal(state.current, 3)
    test.equal(state.info, "3 / 3")
  end)

  test.it("keeps the count and current match through range edits and undo", function(context)
    local view, buffer, input = open(context, ("----\n"):rep(12000) .. "hit\nmiss\nhit\n")
    local state = input.local_find_state
    input:set_text("hit")
    settle(view, state)
    test.equal(state.info, "1 / 2")
    buffer:apply_edits({ { line1 = 12002, col1 = 1, line2 = 12002, col2 = 5, text = "hit\nhit" } },
      { merge_undo = false })
    settle(view, state)
    test.same(state.matches, {
      { line = 12001, col1 = 1, col2 = 4 }, { line = 12002, col1 = 1, col2 = 4 },
      { line = 12003, col1 = 1, col2 = 4 }, { line = 12004, col1 = 1, col2 = 4 },
    })
    test.equal(state.current, 1)
    test.equal(state.info, "1 / 4")
    buffer:undo()
    settle(view, state)
    test.same(state.matches, {
      { line = 12001, col1 = 1, col2 = 4 }, { line = 12003, col1 = 1, col2 = 4 },
    })
    test.equal(state.current, 1)
    test.equal(state.info, "1 / 2")
  end)

  test.it("clears pending results when the query becomes empty or Find closes", function(context)
    local view, _, input = open(context, ("hit miss\n"):rep(12000))
    local state = input.local_find_state
    input:set_text("hit")
    test.ok(state.info:find("Searching", 1, true))
    input:set_text("")
    settle(view, state)
    test.same(state.matches, {})
    test.equal(state.current, 0)
    test.equal(state.info, "")
    input:set_text("hit")
    command.perform("editor:find_close")
    settle(view, state)
    test.same(state.matches, {})
    test.equal(state.current, 0)
  end)

  test.it("does not move a caret that the user moved during a pending scan", function(context)
    local view, buffer, input = open(context, ("----\n"):rep(12000) .. "hit\n")
    local state = input.local_find_state
    input:set_text("hit")
    view:with_selection_state(function() buffer:set_selection(7, 1) end)
    settle(view, state)
    test.same(state.matches, { { line = 12001, col1 = 1, col2 = 4 } })
    test.equal(state.info, "1 / 1")
    test.equal(state.current, 1)
    test.equal(view:with_selection_state(function() return buffer:get_selection() end), 7)
  end)

  test.it("keeps a long-line scan pending and applies the same plain and regex ranges", function(context)
    local view, buffer, input = open(context, ("x"):rep(1000000) .. "aA aa\n")
    local state = input.local_find_state
    input:set_text("aa")
    test.ok(state.info:find("Searching", 1, true))
    settle(view, state)
    test.same(state.matches, {
      { line = 1, col1 = 1000001, col2 = 1000003 },
      { line = 1, col1 = 1000004, col2 = 1000006 },
    })
    test.equal(state.info, "1 / 2")
    command.perform("editor:toggle_regex")
    settle(view, state)
    test.same(state.matches, {
      { line = 1, col1 = 1000001, col2 = 1000004 },
      { line = 1, col1 = 1000004, col2 = 1000006 },
    })
    test.equal(state.info, "1 / 2")
    test.equal(state.current, 1)
    input:set_text("x")
    input:set_text("aa")
    buffer:apply_edits({ { line1 = 1, col1 = 1000004, line2 = 1, col2 = 1000006, text = "zz" } },
      { record_undo = false })
    settle(view, state)
    test.same(state.matches, { { line = 1, col1 = 1000001, col2 = 1000004 } })
    test.equal(state.info, "1 / 1")
    test.equal(state.current, 1)
  end)
end)
