local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
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
  end)
end)
