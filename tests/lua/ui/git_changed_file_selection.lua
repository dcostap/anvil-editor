local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local panes = require "core.panes"
local test = require "core.test"
local git_view = require "plugins.git_view"
local backend = require "plugins.git.backend"

local function open_details(files, collapsed)
  local _, view = git_view.open_log({ path = "C:/changed-file-selection" }, {
    git_view_opts = { defer_refresh = true },
  })
  view.refresh_started = true
  view.model.repo = { root = "C:/changed-file-selection" }
  view.model.backend = setmetatable({
    file_at = function(_, revision, path, _, done) done(revision .. ":" .. path .. "\n") end,
  }, { __index = backend })
  local commit = {
    hash = "newest", parents = { "parent" }, subject = "Changed files", author_name = "Anvil Test",
    body = "A message that must not be selected in row mode.", changed_files_loaded = true,
    details_tree_collapsed = collapsed,
    changed_files = files or {
      { status = "modified", old_path = "alpha/a.txt", new_path = "alpha/a.txt" },
      { status = "modified", old_path = "beta/b.txt", new_path = "beta/b.txt" },
      { status = "modified", old_path = "root.txt", new_path = "root.txt" },
    },
  }
  view.model:log_tab().commits = { commit }
  view:update_pane_buffers()
  view:focus_pane_view("details")
  local details = view:pane_view("details")
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 900, 600
  view:pane_view("log-list").size.x = 0
  details.position.x, details.position.y = 0, 0
  details.size.x, details.size.y = 600, 500
  details.scroll.y, details.scroll.to.y = 0, 0
  return view, details, commit
end

local function selected_paths(view)
  local result, seen = {}, {}
  local s = view:get_selection_state().selections
  for i = 1, #s, 4 do
    local first, last = math.min(s[i], s[i + 2]), math.max(s[i], s[i + 2])
    for line = first, last do
      local row = view:path_tree_row(line)
      test.ok(row and row.type == "file", "row mode selected a non-file row: " .. line)
      local record = view:path_tree_record_for_line(line)
      local path = record.new_path or record.old_path
      if not seen[path] then result[#result + 1], seen[path] = path, true end
    end
  end
  table.sort(result)
  return result
end

test.describe("Git Log changed-file row selection", function()
  test.before_each(function(context)
    context.active_view = core.active_view
    context.set_clipboard = system.set_clipboard
    panes.reset_for_tests()
  end)

  test.after_each(function(context)
    keymap.modkeys.shift, keymap.modkeys.ctrl = false, false
    system.set_clipboard = context.set_clipboard
    panes.reset_for_tests()
    core.active_view = context.active_view
  end)

  test.it("navigates and selects files without selecting folders or commit text", function()
    local view, details = open_details()
    test.same(selected_paths(details), { "alpha/a.txt" })
    command.perform("core:move_to_next_line")
    test.same(selected_paths(details), { "beta/b.txt" })
    command.perform("core:select_to_previous_line")
    test.same(selected_paths(details), { "alpha/a.txt", "beta/b.txt" })
    view:update_pane_buffers()
    command.perform("core:select_to_next_line")
    test.same(selected_paths(details), { "beta/b.txt" })
    command.perform("core:select_all")
    test.same(selected_paths(details), { "alpha/a.txt", "beta/b.txt", "root.txt" })
    local copied
    system.set_clipboard = function(text) copied = text end
    command.perform("core:copy")
    test.ok(copied:find("a.txt", 1, true))
    test.ok(copied:find("b.txt", 1, true))
    test.ok(copied:find("root.txt", 1, true))
    test.ok(not copied:find("alpha/", 1, true), copied)
    test.ok(not copied:find("beta/", 1, true), copied)
    test.ok(not copied:find("Changed files", 1, true), copied)
  end)

  test.it("commits the selected Local Unstaged Changes files with a prompted message", function()
    local view, details, commit = open_details()
    commit.kind = "working_tree"
    commit.local_scope = "unstaged"
    commit.subject = "Local Unstaged Changes"
    commit.hash = nil
    view.model:log_tab().selected_commit_hash = nil
    local request
    view.model.backend.commit_files = function(repo, paths, message, done)
      request = { repo = repo, paths = paths, message = message }
      done({}, nil)
    end
    view.model.refresh_log = function(_, done)
      if done then done(view.model, nil) end
    end
    command.perform("core:select_to_next_line")

    test.same(view:selected_unstaged_paths(details), { "alpha/a.txt", "beta/b.txt" })
    test.ok(command.perform("git:commit_selected_files"))
    test.equal(core.active_view, core.global_prompt_bar)
    core.global_prompt_bar:set_text("Commit selected files")
    core.global_prompt_bar:submit()

    test.equal(request.repo, view.model.repo)
    test.same(request.paths, { "alpha/a.txt", "beta/b.txt" })
    test.equal(request.message, "Commit selected files")
  end)

  test.it("does not offer selected-file commits for Local Staged Changes", function()
    local view, _, commit = open_details()
    commit.kind = "working_tree"
    commit.local_scope = "staged"
    commit.subject = "Local Staged Changes"
    commit.hash = nil
    view.model:log_tab().selected_commit_hash = nil
    test.equal(command.perform("git:commit_selected_files"), false)
  end)

  test.it("ignores commit text and keeps the selected file when a folder closes", function()
    local view, details = open_details()
    command.perform("core:move_to_end_of_buffer")
    local function click(line)
      local x, y = details:get_line_screen_position(line)
      view:on_mouse_pressed("left", x + 10, y + 1, 1)
      view:on_mouse_released("left", x + 10, y + 1)
    end
    click(1)
    test.same(selected_paths(details), { "root.txt" })
    click(details.path_tree_line_offset + details.path_tree:line_for_path("alpha", "dir"))
    test.equal(details.path_tree:is_expanded("alpha"), false)
    test.same(selected_paths(details), { "root.txt" })
    command.perform("core:move_to_start_of_buffer")
    test.same(selected_paths(details), { "beta/b.txt" })
  end)

  test.it("selects only file rows during mouse dragging across folders", function()
    local view, details = open_details()
    local a = details.path_tree_line_offset + details.path_tree:line_for_path("alpha/a.txt", "file")
    local b = details.path_tree_line_offset + details.path_tree:line_for_path("beta/b.txt", "file")
    local x, y = details:get_line_screen_position(a)
    local _, y2 = details:get_line_screen_position(b)
    view:on_mouse_pressed("left", x + 20, y + 1, 1)
    view:on_mouse_moved(x + 20, y2 + 1, 0, y2 - y)
    view:on_mouse_released("left", x + 20, y2 + 1)
    test.same(selected_paths(details), { "alpha/a.txt", "beta/b.txt" })
  end)

  test.it("keeps file selection by path when changed-file rows move", function()
    local view, details, commit = open_details()
    command.perform("core:move_to_next_line")
    commit.changed_files = {
      { status = "modified", old_path = "beta/b.txt", new_path = "beta/b.txt" },
      { status = "modified", old_path = "delta/d.txt", new_path = "delta/d.txt" },
    }
    view:update_pane_buffers()
    test.same(selected_paths(details), { "beta/b.txt" })
  end)

  test.it("leaves no selected file when all folders close", function()
    local view, details = open_details({
      { status = "modified", old_path = "alpha/a.txt", new_path = "alpha/a.txt" },
    })
    local line = details.path_tree_line_offset + details.path_tree:line_for_path("alpha", "dir")
    test.ok(view:toggle_details_tree_folder(details, line))
    command.perform("core:move_to_next_line")
    command.perform("core:select_all")
    test.same(details:get_selected_rows(), {})
    test.equal(view:activate_selected_point(), nil)
    test.equal(#view.model.tabs, 1)
    test.equal(panes.active().current_view, view)
  end)

  test.it("allows normal text selection after switching modes, without changing the commit list mode", function()
    local view, details = open_details()
    test.ok(command.perform("git:toggle_row_selection_mode"))
    command.perform("core:move_to_start_of_buffer")
    command.perform("core:select_to_next_char")
    test.same(details:get_selection_state().selections, { 1, 2, 1, 1 })
    local text = table.concat(details.buffer.lines)
    details:on_text_input("not editable")
    test.equal(table.concat(details.buffer.lines), text)
    command.perform("git:toggle_row_selection_mode")
    test.same(selected_paths(details), { "alpha/a.txt" })
    test.equal(view:pane_view("log-list").row_selection_mode, true)
  end)

  test.it("keeps the viewport still when a folder row is clicked", function()
    local files = {}
    for index = 1, 8 do
      local path = string.format("alpha/a-%02d.txt", index)
      files[#files + 1] = { status = "modified", old_path = path, new_path = path }
    end
    for index = 1, 30 do
      local path = string.format("beta/b-%02d.txt", index)
      files[#files + 1] = { status = "modified", old_path = path, new_path = path }
    end
    for index = 1, 30 do
      local path = string.format("gamma/g-%02d.txt", index)
      files[#files + 1] = { status = "modified", old_path = path, new_path = path }
    end
    local view, details = open_details(files, { beta = true })
    local offset = details.path_tree_line_offset
    details:select_row(offset + details.path_tree:line_for_path("gamma/g-05.txt", "file"))
    details:update()
    details:update()
    local scroll_before = details.scroll.to.y
    local folder_line = offset + details.path_tree:line_for_path("beta", "dir")
    local x, y = details:get_line_screen_position(folder_line)
    test.ok(y >= 0 and y < details.size.y, "the clicked folder must be visible")
    view:on_mouse_pressed("left", x + 10, y + 1, 1)
    view:on_mouse_released("left", x + 10, y + 1)
    test.equal(details.path_tree:is_expanded("beta"), true)
    for _ = 1, 4 do details:update() end
    test.equal(details.scroll.to.y, scroll_before)
    test.equal(details.scroll.y, scroll_before)
    -- The selected file moved below the viewport. The viewport must not follow
    -- it, so the click cannot replay a caret scroll.
    local selected_line = offset + details.path_tree:line_for_path("gamma/g-05.txt", "file")
    local _, selected_y = details:get_line_screen_position(selected_line)
    test.ok(selected_y >= details.size.y, "the selected file must be outside the viewport")
  end)

  test.it("opens the selected file after navigating across a folder row", function()
    open_details()
    command.perform("core:move_to_next_line")
    command.perform("git:activate_selected_row")
    local comparison = panes.active().current_view
    test.not_nil(comparison.buffer_view_a)
    test.equal(comparison.buffer_view_a.buffer:get_utf8_line(1), "parent:beta/b.txt\n")
    test.equal(comparison.buffer_view_b.buffer:get_utf8_line(1), "newest:beta/b.txt\n")
  end)
end)
