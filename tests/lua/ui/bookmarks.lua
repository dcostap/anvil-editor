local core = require "core"
local common = require "core.common"
local command = require "core.command"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local Project = require "core.project"
local panes = require "core.panes"
local storage = require "core.storage"
local bookmarks = require "core.bookmarks"
local fuzzy_searcher = require "plugins.fuzzy_searcher"
local test = require "core.test"
local style = require "core.style"
local sequence = 0

test.describe("Bookmark commands", function()
  test.before_each(function(context)
    sequence = sequence + 1
    context.projects, context.active_view = core.projects, core.active_view
    context.root = USERDIR .. PATHSEP .. "bookmark-ui-" .. sequence
    test.ok(common.mkdirp(context.root))
    core.projects = { Project(context.root) }
    panes.reset_for_tests()
    local path = context.root .. PATHSEP .. "source.txt"
    local file = test.not_nil(io.open(path, "wb"))
    file:write("first\ntarget\nlast\n")
    file:close()
    context.buffer = Buffer(path, path)
    context.editor = Editor(context.buffer)
    context.pane = panes.create { factory = function() return context.editor end }
    panes.focus(context.pane)
    context.editor:set_selection_state { selections = { 2, 1, 2, 1 }, last_selection = 1 }
  end)

  test.after_each(function(context)
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close("replaced") end
    core.global_prompt_bar:exit()
    panes.reset_for_tests()
    if context.editor then context.editor:on_close() end
    core.buffer_registry:remove(context.buffer, true)
    if context.opened_buffer then core.buffer_registry:remove(context.opened_buffer, true) end
    bookmarks.close_project(context.root)
    storage.clear("bookmarks", common.path_compare_key(context.root))
    core.projects, core.active_view = context.projects, context.active_view
    common.rm(context.root, true)
  end)

  test.it("moves bookmarks with their lines rather than their previous positions", function(context)
    local target = bookmarks.add(context.buffer, 2, "Target")
    local first = bookmarks.add(context.buffer, 1, "First")
    test.ok(command.perform("editor:move_lines_up"))
    bookmarks.list()
    test.equal(target.line, 1)
    test.equal(first.line, 2)
    test.equal(target.status, "ready")
    test.equal(first.status, "ready")
    context.buffer:undo()
    bookmarks.list()
    test.equal(target.line, 2)
    test.equal(first.line, 1)
    context.buffer:redo()
    bookmarks.list()
    test.equal(target.line, 1)
    test.equal(first.line, 2)
  end)

  test.it("adds and renames through the Global Prompt Bar and confirms removal", function(context)
    test.ok(command.perform("bookmark:toggle"))
    test.equal(core.active_view, core.global_prompt_bar)
    core.global_prompt_bar:set_text("Parser entry")
    core.global_prompt_bar:submit()
    test.equal(bookmarks.list()[1].name, "Parser entry")
    test.equal(core.active_view, context.editor)
    test.ok(command.perform("bookmark:rename"))
    test.equal(core.global_prompt_bar:get_text(), "Parser entry")
    core.global_prompt_bar:set_text("")
    core.global_prompt_bar:submit()
    test.equal(bookmarks.list()[1].name, "")
    test.ok(command.perform("bookmark:toggle"))
    test.equal(#bookmarks.list(), 1)
    test.ok(command.perform("core:select_dialog_no"))
    test.equal(#bookmarks.list(), 1)
    test.ok(command.perform("bookmark:toggle"))
    test.ok(command.perform("core:select_dialog_yes"))
    test.equal(#bookmarks.list(), 0)
  end)

  test.it("searches bookmark names and activates the saved line in its source Pane", function(context)
    local mark = bookmarks.add(context.buffer, 2, "Parser entry")
    test.ok(command.perform("fuzzy:open_bookmarks"))
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    test.equal(picker.input:get_text(), "º")
    picker.input:set_text("ºParser")
    picker:refresh()
    test.equal(#picker.results, 1)
    test.equal(picker.results[1].bookmark.id, mark.id)
    picker:confirm()
    test.equal(context.pane.current_view.buffer, context.buffer)
    test.equal(context.pane.current_view:get_selection_state().selections[1], 2)
  end)

  test.it("does not recreate a missing file and allows renaming its search result", function(context)
    local mark = bookmarks.add(context.buffer, 2, "Missing")
    local picker = fuzzy_searcher.open("ºMissing")
    test.ok(os.remove(context.buffer.abs_filename))
    picker:confirm()
    test.equal(core.fuzzy_searcher_active_view, picker)
    test.equal(system.get_file_info(mark.path), nil)
    test.equal(mark.status, "file_missing")
    test.ok(command.perform("bookmark:rename"))
    core.global_prompt_bar:set_text("Still useful")
    core.global_prompt_bar:submit()
    test.equal(mark.name, "Still useful")
  end)

  test.it("validates newly opened text before one confirmation navigates a closed Bookmark", function(context)
    local path = context.buffer.abs_filename
    local mark = bookmarks.add(context.buffer, 2, "Target")
    panes.reset_for_tests()
    core.buffer_registry:remove(context.buffer, true)
    bookmarks.refresh()
    local deadline = system.get_time() + 10
    while bookmarks.is_refreshing() do
      require("core.worker_pool").system():drain { budget_ms = 10, max_messages = 100 }
      test.ok(system.get_time() < deadline)
      coroutine.yield(0.01)
    end
    local file = test.not_nil(io.open(path, "wb"))
    file:write("new\nfirst\ntarget\nlast\n")
    file:close()
    local source_path = context.root .. PATHSEP .. "other.txt"
    file = test.not_nil(io.open(source_path, "wb"))
    file:write("source\n")
    file:close()
    context.buffer = Buffer(source_path, source_path)
    context.editor = Editor(context.buffer)
    context.pane = panes.create { factory = function() return context.editor end }
    panes.focus(context.pane)
    local picker = fuzzy_searcher.open("ºTarget")
    picker:confirm()
    while core.fuzzy_searcher_active_view == picker do
      require("core.worker_pool").system():drain { budget_ms = 10, max_messages = 100 }
      test.ok(system.get_time() < deadline, "Bookmark activation did not finish")
      coroutine.yield(0.01)
    end
    context.opened_buffer = context.pane.current_view.buffer
    test.ok(common.path_equals(context.opened_buffer.abs_filename, path))
    test.equal(context.pane.current_view:get_selection_state().selections[1], 3)
    test.equal(mark.line, 3)
  end)

  test.it("keeps mode markers and modifier-like bookmark names literal", function(context)
    bookmarks.add(context.buffer, 2, "#literal size:20")
    local picker = fuzzy_searcher.open("º#literal size:20")
    test.equal(#picker.results, 1)
    test.equal(picker.results[1].kind, "bookmark")
    test.equal(picker.query_modifiers.active, false)
  end)

  test.it("draws a bookmark beside the line number without using its lane", function(context)
    bookmarks.add(context.buffer, 2, "Target")
    local rectangles, labels = {}, {}
    local draw_rect, draw_text = renderer.draw_rect, common.draw_text
    renderer.draw_rect = function(x, y, w, h, color)
      if color == style.bookmark then rectangles[#rectangles + 1] = { x = x, width = w } end
    end
    common.draw_text = function(_, _, text) labels[#labels + 1] = text end
    local ok, err = pcall(function()
      local width, padding = context.editor:get_gutter_width()
      context.editor:draw_line_gutter(1, 0, 0, width - padding)
      test.equal(#rectangles, 0)
      context.editor:draw_line_gutter(2, 0, 0, width - padding)
      test.ok(#rectangles > 0)
      test.equal(labels[#labels], 2)
      for _, rect in ipairs(rectangles) do
        test.ok(rect.x >= 0 and rect.x + rect.width <= context.editor:bookmark_gutter_width())
      end
    end)
    renderer.draw_rect, common.draw_text = draw_rect, draw_text
    if not ok then error(err, 0) end
  end)

  test.it("keeps the original target when its line moves while naming", function(context)
    test.ok(command.perform("bookmark:toggle"))
    context.buffer:insert(1, 1, "new\n")
    core.global_prompt_bar:set_text("Target")
    core.global_prompt_bar:submit()
    test.equal(bookmarks.list()[1].line, 3)
    test.equal(bookmarks.list()[1].text, "target")
  end)

  test.it("does not create a Bookmark from a Buffer that closed while naming", function(context)
    test.ok(command.perform("bookmark:toggle"))
    context.editor:on_close()
    core.buffer_registry:collect()
    core.global_prompt_bar:set_text("Closed target")
    core.global_prompt_bar:submit()
    test.equal(#bookmarks.list(), 0)
  end)

  test.it("cancels creation or accepts a blank name without creating a named bookmark", function(context)
    test.ok(command.perform("bookmark:toggle"))
    core.global_prompt_bar:exit()
    test.equal(#bookmarks.list(), 0)
    test.ok(command.perform("bookmark:toggle"))
    core.global_prompt_bar:submit()
    test.equal(bookmarks.list()[1].name, "")
    test.equal(bookmarks.list()[1].line, 2)
  end)
end)
