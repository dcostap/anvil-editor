local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local panes = require "core.panes"
local test = require "core.test"
local git_view = require "plugins.git_view"
local backend = require "plugins.git.backend"

local function open_history(kind)
  local session, log = git_view.open_log({ path = "C:/history-row-selection-repo" }, {
    git_view_opts = { defer_refresh = true },
  })
  log.refresh_pending = nil
  log.refresh_started = true
  log.model.repo = { root = "C:/history-row-selection-repo" }
  log.model.backend = setmetatable({
    file_at = function(_, revision, _, _, done)
      done(revision .. "\n", nil)
      return { cancel = function() end }
    end,
  }, { __index = backend })
  local tab = {
    id = "history-row-selection", kind = "file_history", title = "History: file.lua",
    relpath = "file.lua", history_context = { type = kind, start_line = 1, end_line = 1 },
    selected_commit = 1,
    commits = {
      { hash = "cccc", parents = { "bbbb" }, subject = "Newest" },
      { hash = "bbbb", parents = { "aaaa" }, subject = "Middle" },
      { hash = "aaaa", parents = {}, subject = "Oldest" },
    },
  }
  log.model.tabs[#log.model.tabs + 1] = tab
  local view = git_view.ensure_tab_view(session, tab, true)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 900, 600
  view:focus_list_pane()
  local list = view:pane_view("history-list")
  list.position.x, list.position.y = 0, 0
  list.size.x, list.size.y = 600, 300
  return view, list, tab
end

test.describe("Git History row selection", function()
  test.before_each(function(context)
    context.active_view = core.active_view
    panes.reset_for_tests()
  end)

  test.after_each(function(context)
    keymap.modkeys.shift, keymap.modkeys.ctrl = false, false
    panes.reset_for_tests()
    core.active_view = context.active_view
  end)

  for _, kind in ipairs { "file", "selection" } do
    test.it("starts " .. kind .. " history with complete rows and permits text navigation when toggled", function()
      local view, list, tab = open_history(kind)
      test.same(list:get_selection_state().selections, { 1, #list.buffer.lines[1], 1, 1 })
      test.ok(command.perform("core:move_to_next_line"))
      test.same(list:get_selection_state().selections, { 2, #list.buffer.lines[2], 2, 1 })
      view:sync_selection_from_pane()
      test.equal(tab.selected_commit, 2)
      test.equal(tab.preview_right_text:gsub("\n$", ""), "bbbb")
      test.ok(command.perform("core:select_to_next_line"))
      test.same(list:get_selected_rows(), { 2, 3 })
      test.ok(command.perform("git:toggle_row_selection_mode"))
      command.perform("core:move_to_start_of_line")
      command.perform("core:move_to_next_char")
      test.same(list:get_selection_state().selections, { 3, 2, 3, 2 })
      local text = table.concat(list.buffer.lines)
      list:on_text_input("not editable")
      test.equal(table.concat(list.buffer.lines), text)
      test.ok(command.perform("git:toggle_row_selection_mode"))
      test.same(list:get_selection_state().selections, { 3, #list.buffer.lines[3], 3, 1 })
    end)
  end

  test.it("retains selected commits when history receives a new revision", function()
    local view, list, tab = open_history("file")
    command.perform("core:select_to_next_line")
    view:sync_selection_from_pane()
    table.insert(tab.commits, 1, { hash = "dddd", parents = { "cccc" }, subject = "New HEAD" })
    tab.selected_commit = 3
    view:update_pane_buffers()
    test.same(list:get_selected_rows(), { 2, 3 })
    view:sync_selection_from_pane()
    test.equal(tab.commits[tab.selected_commit].hash, "bbbb")
  end)
end)
