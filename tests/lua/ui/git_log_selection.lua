local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local config = require "core.config"
local style = require "core.style"
local panes = require "core.panes"
local test = require "core.test"
local git_view = require "plugins.git_view"
local backend = require "plugins.git.backend"

local function open_log()
  local _, view = git_view.open_log({ path = "C:/row-selection-repo" }, {
    git_view_opts = { defer_refresh = true },
  })
  view.refresh_pending = nil
  view.model.repo = { root = "C:/row-selection-repo" }
  view.refresh_started = true
  view.model.backend = setmetatable({
    changed_files = function(_, _, _, _, done) done({}, nil) end,
  }, { __index = backend })
  view.model:log_tab().commits = {
    { hash = "cccc", parents = { "bbbb" }, subject = "Newest", changed_files = {} },
    { hash = "bbbb", parents = { "aaaa" }, subject = "Middle", changed_files = {} },
    { hash = "aaaa", parents = {}, subject = "Oldest", changed_files = {} },
  }
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 900, 600
  view:update_pane_buffers()
  view:focus_list_pane()
  local list = view:pane_view("log-list")
  list.position.x, list.position.y = 0, 0
  list.size.x, list.size.y = 600, 300
  list.scroll.y, list.scroll.to.y = 0, 0
  return view, list
end

local function selection(list)
  return list:get_selection_state().selections
end

test.describe("Git Log row selection", function()
  test.before_each(function(context)
    context.active_view = core.active_view
    panes.reset_for_tests()
  end)

  test.after_each(function(context)
    keymap.modkeys.shift = false
    keymap.modkeys.ctrl = false
    panes.reset_for_tests()
    core.active_view = context.active_view
  end)

  test.it("moves and extends complete rows, then restores normal text navigation", function()
    local _, list = open_log()
    test.same(selection(list), { 1, #list.buffer.lines[1], 1, 1 })

    command.perform("core:move_to_next_line")
    test.same(selection(list), { 2, #list.buffer.lines[2], 2, 1 })
    command.perform("core:select_to_next_line")
    test.same(selection(list), { 3, #list.buffer.lines[3], 2, 1 })
    command.perform("core:select_to_previous_line")
    command.perform("core:select_to_previous_line")
    test.same(selection(list), { 1, 1, 2, #list.buffer.lines[2] })
    command.perform("core:move_to_next_char")
    test.same(selection(list), { 1, 1, 2, #list.buffer.lines[2] })

    test.ok(command.perform("git:toggle_row_selection_mode"))
    command.perform("core:move_to_start_of_line")
    command.perform("core:move_to_next_char")
    test.same(selection(list), { 1, 2, 1, 2 })
    local before = table.concat(list.buffer.lines)
    list:on_text_input("not editable")
    test.equal(table.concat(list.buffer.lines), before)
    command.perform("git:toggle_row_selection_mode")
    test.same(selection(list), { 1, #list.buffer.lines[1], 1, 1 })
  end)

  test.it("selects complete rows with mouse dragging and Shift-click", function()
    local _, list = open_log()
    local x, y = list:get_line_screen_position(2)
    list:on_mouse_pressed("left", x + 15, y + 1, 1)
    test.same(selection(list), { 2, #list.buffer.lines[2], 2, 1 })
    local _, y3 = list:get_line_screen_position(3)
    list:on_mouse_moved(x + 50, y3 + 1, 35, y3 - y)
    list:on_mouse_released("left", x + 50, y3 + 1)
    test.same(selection(list), { 3, #list.buffer.lines[3], 2, 1 })
    keymap.modkeys.shift = true
    local _, y1 = list:get_line_screen_position(1)
    list:on_mouse_pressed("left", x + 20, y1 + 1, 1)
    list:on_mouse_released("left", x + 20, y1 + 1)
    test.same(selection(list), { 1, 1, 2, #list.buffer.lines[2] })
  end)

  test.it("keeps selected commits when the log inserts a new row", function()
    local view, list = open_log()
    command.perform("core:select_to_next_line")
    view:sync_selection_from_pane()
    table.insert(view.model:log_tab().commits, 1, {
      hash = "dddd", parents = { "cccc" }, subject = "New HEAD", changed_files = {},
    })
    view:update_pane_buffers()
    test.same(list:get_selected_rows(), { 2, 3 })
  end)

  test.it("routes row dragging and text selection through the Git Log surface", function()
    local view, list = open_log()
    local x, y = list:get_line_screen_position(1)
    view:on_mouse_pressed("left", x + 5, y + 1, 1)
    local _, y2 = list:get_line_screen_position(2)
    view:on_mouse_moved(x + 15, y2 + 1, 10, y2 - y)
    view:on_mouse_released("left", x + 15, y2 + 1)
    test.same(list:get_selected_rows(), { 1, 2 })
    command.perform("git:toggle_row_selection_mode")
    view:on_mouse_pressed("left", x + 5, y + 1, 1)
    view:on_mouse_released("left", x + 5, y + 1)
    local s = selection(list)
    test.equal(s[1], s[3])
    test.equal(s[2], s[4])
    keymap.modkeys.shift = true
    view:on_mouse_pressed("left", x + 15, y2 + 1, 1)
    view:on_mouse_released("left", x + 15, y2 + 1)
    test.same(list:get_selected_rows(), { 1, 2 })
  end)

  test.it("uses the selected range for details and the Commit Diff command", function()
    local view, list = open_log()
    view.model.backend.changed_files = function(_, left, right, _, done)
      done({ { status = "modified", old_path = "range.txt", new_path = "range.txt" } })
    end
    view.model.backend.file_at = function(_, revision, _, _, done)
      done(revision == "aaaa" and "before\n" or "after\n")
    end
    command.perform("core:select_to_next_line")
    view:sync_selection_from_pane()
    view:update_pane_buffers()
    local details = table.concat(view:pane_view("details").buffer.lines)
    test.ok(details:find("2 commits", 1, true), details)
    test.ok(details:find("range.txt", 1, true), details)
    command.perform("git:open_selected_commit_diff")
    local diff = panes.active().current_view:model_tab()
    test.equal(diff.kind, "commit_diff")
    test.equal(diff.left, "aaaa")
    test.equal(diff.right, "cccc")
    test.same(list:get_selected_rows(), { 1, 2 })
  end)

  test.it("shows an unsupported selection instead of opening one selected commit", function()
    local view, list = open_log()
    list:set_selection_state({ selections = { 1, 1, 1, 1, 3, 1, 3, 1 }, last_selection = 2 })
    view:sync_selection_from_pane()
    view:update_pane_buffers()
    local details = table.concat(view:pane_view("details").buffer.lines)
    test.ok(details:find("gaps", 1, true), details)
    local opened, err = view:activate_selected()
    test.equal(opened, nil)
    test.ok(err and err.kind == "non_contiguous")
    opened, err = view:activate_selected_point()
    test.equal(opened, nil)
    test.ok(err and err.kind == "non_contiguous")
    test.same(list:get_selected_rows(), { 1, 3 })
    test.equal(#view.model.tabs, 1)
  end)

  test.it("keeps separate selected rows during an added mouse selection", function()
    local _, list = open_log()
    keymap.modkeys.ctrl = true
    local x, y = list:get_line_screen_position(3)
    list:on_mouse_pressed("left", x + 5, y + 1, 1)
    list:on_mouse_moved(x + 6, y + 1, 1, 0)
    list:on_mouse_released("left", x + 6, y + 1)
    test.same(list:get_selected_rows(), { 1, 3 })
  end)

  test.it("compares text-selected commits without including an untouched final row", function()
    local view, list = open_log()
    command.perform("git:toggle_row_selection_mode")
    list:set_selection_state({ selections = { 3, 1, 1, 1 } })
    view:sync_selection_from_pane()
    local revision = view.model:selected_log_revision()
    test.equal(revision.left, "aaaa")
    test.equal(revision.right, "cccc")
    command.perform("git:toggle_row_selection_mode")
    test.same(list:get_selected_rows(), { 1, 2 })
  end)

  test.it("includes the selected range and its changed files in a Text Capture", function()
    local view = open_log()
    view.model.backend.changed_files = function(_, _, _, _, done)
      done({ { status = "modified", old_path = "range.txt", new_path = "range.txt" } })
    end
    command.perform("core:select_to_next_line")
    view:sync_selection_from_pane()
    local capture = view:text_capture()
    test.ok(capture.text:find("2 commits", 1, true), capture.text)
    test.ok(capture.text:find("range.txt", 1, true), capture.text)
  end)

  for _, source in ipairs { "log-list", "details" } do
    test.it("opens a range file comparison through " .. source .. " activation", function()
      local view = open_log()
      view.model.backend.changed_files = function(_, _, _, _, done)
        done({ { status = "modified", old_path = "range.txt", new_path = "range.txt" } })
      end
      view.model.backend.file_at = function(_, revision, _, _, done)
        done(revision .. "\n")
      end
      command.perform("core:select_to_next_line")
      view:sync_selection_from_pane()
      view:update_pane_buffers()
      if source == "details" then
        view:focus_pane_view("details")
        view:select_detail_file_point(view:detail_file_points()[1])
      end
      command.perform("git:activate_selected_row")
      local comparison = panes.active().current_view
      test.not_nil(comparison.buffer_view_a)
      test.equal(comparison.buffer_view_a.buffer:get_utf8_line(1), "aaaa\n")
      test.equal(comparison.buffer_view_b.buffer:get_utf8_line(1), "cccc\n")
    end)
  end

  for _, surface in ipairs { "log-list", "details" } do
  test.it(surface .. " paints only selectable rows without a caret, then restores the text caret", function()
    local view, list = open_log()
    if surface == "details" then
      view.model:log_tab().commits[1].changed_files = {
        { status = "modified", old_path = "alpha/a.txt", new_path = "alpha/a.txt" },
        { status = "modified", old_path = "beta/b.txt", new_path = "beta/b.txt" },
      }
      view:update_pane_buffers()
      view:focus_pane_view("details")
      list = view:pane_view("details")
      list.position.x, list.position.y = 0, 0
      list.size.x, list.size.y = 600, 500
      list.scroll.y, list.scroll.to.y = 0, 0
    end
    command.perform("core:select_to_next_line")
    test.equal(#list:get_selected_rows(), 2)
    local saved, paints, carets = {}, {}, {}
    local root = core.root_panel
    local submit, clip, blink = root.submit_keyboard_caret, core.clip_rect_stack, config.disable_blink
    local function restore()
      for name, fn in pairs(saved) do renderer[name] = fn end
      root.submit_keyboard_caret, core.clip_rect_stack, config.disable_blink = submit, clip, blink
    end
    for _, name in ipairs {
      "draw_rect", "draw_poly", "draw_rect_grid", "draw_rounded_rect", "draw_text",
      "draw_text_known_bounds", "set_clip_rect", "display_packet",
    } do
      saved[name] = renderer[name]
      renderer[name] = function() end
    end
    renderer.display_packet = nil
    renderer.draw_text = function(font, text, x, _, _, opts) return x + font:get_width(text, opts) end
    renderer.draw_rect = function(x, y, w, h, color)
      local bounds = core.clip_rect_stack[#core.clip_rect_stack]
      if color == style.selection then
        paints[#paints + 1] = {
          math.max(x, bounds[1]), math.max(y, bounds[2]),
          math.min(x + w, bounds[1] + bounds[3]), math.min(y + h, bounds[2] + bounds[4]),
        }
      end
      if color == style.caret then carets[#carets + 1] = { x, y } end
    end
    root.submit_keyboard_caret = function(_, target) carets[#carets + 1] = target end
    core.clip_rect_stack = { { 0, 0, 900, 600 } }
    config.disable_blink = true
    list.active_window_has_focus = function() return true end
    local ok, err = pcall(function()
      list:draw()
      test.equal(#carets, 0)
      local function selected_at(x, y)
        for _, rect in ipairs(paints) do
          if x >= rect[1] and x < rect[3] and y >= rect[2] and y < rect[4] then return true end
        end
      end
      for _, row in ipairs(list:get_selected_rows()) do
        local _, y = list:get_line_screen_position(row)
        y = y + list:get_line_height() / 2
        test.ok(selected_at(list.position.x + 1, y), "the row highlight must include the gutter")
        test.ok(selected_at(list.position.x + list.size.x - 1, y), "the row highlight must reach the right edge")
      end
      for row = 1, #list.buffer.lines do
        if not list:is_selectable_row(row) then
          local x, y = list:get_line_screen_position(row)
          test.ok(not selected_at(x + 1, y + list:get_line_height() / 2), "non-selectable rows must not be highlighted")
        end
      end
      command.perform("git:toggle_row_selection_mode")
      list:draw()
      test.ok(#carets > 0, "normal text mode must show a caret")
    end)
    restore()
    if not ok then error(err, 0) end
  end)
  end
end)
