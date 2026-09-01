local command = require "core.command"
local core = require "core"
local fuzzy_searcher = require "plugins.fuzzy_searcher"
local panes = require "core.panes"
local test = require "core.test"
local View = require "core.view"

local function temp_file_path(name)
  return system.absolute_path(".") .. PATHSEP .. name
end

local function write_file(path, text)
  local file = assert(io.open(path, "wb"))
  file:write(text)
  file:close()
end

local function selection_state(view)
  return view:get_selection_state().selections
end

test.describe("Fuzzy Searcher preview interaction", function()
  test.before_each(function(context)
    panes.reset_for_tests()
    panes.create { factory = function() return View() end }
    context.files = {}
  end)

  test.after_each(function(context)
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    panes.reset_for_tests()
    for _, path in ipairs(context.files) do pcall(os.remove, path) end
  end)

  test.it("does not show a Current Line Highlight in a passive file preview", function(context)
    local path = temp_file_path("fuzzy-passive-preview-highlight-test.txt")
    context.files = { path }
    write_file(path, "first\nsecond\n")

    fuzzy_searcher.open("")
    local picker = core.fuzzy_searcher_active_view
    picker.results = { { kind = "file", file = path, text = path } }
    picker.selected = 1

    local preview = test.not_nil(picker:update_preview_view())

    test.equal(preview:get_current_line_highlight_mode(), false)
    test.equal(preview.buffer.read_only, true)
  end)

  test.it("cycles local focus into the preview for cursor movement", function(context)
    local path = temp_file_path("fuzzy-preview-local-focus-test.txt")
    context.files = { path }
    write_file(path, "first\nsecond\n")

    fuzzy_searcher.open("")
    local picker = core.fuzzy_searcher_active_view
    picker.results = { { kind = "file", file = path, text = path } }
    picker.selected = 1
    local preview = test.not_nil(picker:update_preview_view())

    test.ok(picker:cycle_local_focus(1))
    test.equal(core.active_view, preview)
    test.not_equal(preview:get_current_line_highlight_mode(), false)
    test.ok(command.perform("core:move_to_next_char"))
    test.same(selection_state(preview), { 1, 2, 1, 2 })

    test.ok(picker:cycle_local_focus(1))
    test.equal(core.active_view, picker.input.textview)
    test.equal(preview:get_current_line_highlight_mode(), false)
  end)

  test.it("does not let picker-local commands steal focused preview input", function(context)
    local path = temp_file_path("fuzzy-preview-command-routing-test.txt")
    context.files = { path }
    write_file(path, "first\nsecond\n")

    fuzzy_searcher.open("")
    local picker = core.fuzzy_searcher_active_view
    picker.results = {
      { kind = "file", file = path, text = path },
      { kind = "file", file = path, text = path },
    }
    picker.selected = 1
    local preview = test.not_nil(picker:update_preview_view())
    test.ok(picker:cycle_local_focus(1))

    test.not_ok(command.perform("fuzzy:next"))
    test.equal(picker.selected, 1)
    test.equal(core.active_view, preview)

    test.ok(command.perform("fuzzy:open_files"))
    test.equal(core.fuzzy_searcher_active_view, picker)
    test.equal(core.active_view, picker.input.textview)
  end)

  test.it("focuses the preview and places its caret on a text click", function(context)
    local path = temp_file_path("fuzzy-preview-click-focus-test.txt")
    context.files = { path }
    write_file(path, "first\nsecond\nthird\n")

    fuzzy_searcher.open("")
    local picker = core.fuzzy_searcher_active_view
    picker.results = { { kind = "file", file = path, text = path } }
    picker.selected = 1
    local preview = test.not_nil(picker:update_preview_view())
    local x, y = preview:get_line_screen_position(2)

    picker:on_mouse_pressed("left", x + preview:get_font():get_width("se"),
      y + preview:get_line_height() / 2, 1)

    test.equal(core.active_view, preview)
    local line, col = preview.buffer:get_selection()
    test.equal(line, 2)
    test.ok(col > 1)

    local drag_x = x + preview:get_font():get_width("second")
    picker:on_mouse_moved(drag_x, y + preview:get_line_height() / 2, 0, 0)
    picker:on_mouse_released("left", drag_x, y)
    test.ok(preview.buffer:has_selection())
  end)

  test.it("opens an accepted text match at the previewed range", function(context)
    local path = temp_file_path("fuzzy-preview-accepted-match-test.txt")
    context.files = { path }
    local lines = {}
    for line = 1, 120 do
      lines[line] = line == 90 and "alpha NEEDLE omega" or ("line " .. line)
    end
    write_file(path, table.concat(lines, "\n") .. "\n")

    fuzzy_searcher.open("#NEEDLE")
    local picker = core.fuzzy_searcher_active_view
    picker.results = { {
      kind = "grep", file = path, line = 90, col = 7,
      grep_query = "NEEDLE", exact = true,
      content_selection_span = { 7, 12 }, content_match_start = 7,
      text = "alpha NEEDLE omega",
    } }
    picker.selected = 1
    picker:update_preview_view()

    test.ok(command.perform("core:activate_point_of_interest"))

    local view = core.active_view
    test.equal(view.buffer.abs_filename, path)
    test.same(selection_state(view), { 90, 7, 90, 13 })
    test.ok(view.scroll.y > 0, "expected the accepted match to be in the opened viewport")
  end)

  test.it("places the caret at the first separated match chunk", function(context)
    local path = temp_file_path("fuzzy-preview-separated-match-test.txt")
    context.files = { path }
    local lines = {}
    for line = 1, 60 do lines[line] = line == 40 and "alpha beta" or ("line " .. line) end
    write_file(path, table.concat(lines, "\n") .. "\n")

    fuzzy_searcher.open("#ab")
    local picker = core.fuzzy_searcher_active_view
    picker.results = { {
      kind = "grep", file = path, line = 40, col = 1,
      grep_query = "ab", exact = false,
      content_spans = { { 1, 1 }, { 7, 7 } }, content_match_start = 1,
      text = "alpha beta",
    } }
    picker.selected = 1

    test.ok(command.perform("core:activate_point_of_interest"))

    local view = core.active_view
    test.same(selection_state(view), { 40, 1, 40, 1 })
    test.ok(view.scroll.y > 0)
  end)

  test.it("opens a focused preview at its current selection and viewport", function(context)
    local path = temp_file_path("fuzzy-preview-focused-activation-test.txt")
    context.files = { path }
    local lines = {}
    for line = 1, 120 do lines[line] = "line " .. line end
    write_file(path, table.concat(lines, "\n") .. "\n")

    fuzzy_searcher.open("")
    local picker = core.fuzzy_searcher_active_view
    picker.results = { { kind = "file", file = path, text = path, line = 80 } }
    picker.selected = 1
    local preview = test.not_nil(picker:update_preview_view())
    test.ok(picker:cycle_local_focus(1))
    preview.buffer:set_selection(82, 3, 82, 6)
    preview.scroll.x, preview.scroll.to.x = 14, 14
    preview.scroll.y, preview.scroll.to.y = 900, 900

    test.ok(command.perform("core:activate_point_of_interest"))

    local view = core.active_view
    test.equal(view.buffer.abs_filename, path)
    test.same(selection_state(view), { 82, 3, 82, 6 })
    test.equal(view.scroll.x, 14)
    test.equal(view.scroll.y, 900)
  end)
end)
