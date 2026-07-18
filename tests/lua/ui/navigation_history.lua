local core = require "core"
local command = require "core.command"
local common = require "core.common"
local test = require "core.test"
local panes = require "core.panes"
local file_context = require "core.file_context"
local DocView = require "core.docview"
local command_slots = require "plugins.command_slots"
local git_view = require "plugins.git_view"
local fuzzy_searcher = require "plugins.fuzzy_searcher"

local navigation_history = require "plugins.navigation_history"

local navigation_test_file_id = 0

local fake_git_backend = {
  repo_for_path = function(path) return { root = path } end,
  build_log_args = function() return { "log" } end,
  parse_status_z = function() return {} end,
  parse_log_page = function() return { commits = {} } end,
  file_history = function(_, _, _, callback)
    callback({ commits = {}, has_more = false }, nil)
    return { cancel = function() end }
  end,
  changed_files = function(_, _, _, _, callback)
    callback({}, nil)
    return { cancel = function() end }
  end,
  file_at = function(_, _, relpath, _, callback)
    callback("contents for " .. tostring(relpath) .. "\n", nil)
    return { cancel = function() end }
  end,
  run_git = function(_, _, _, callback)
    callback({ code = 0, stdout = "" }, nil)
    return { cancel = function() end }
  end,
}

local function track(context, kind, value)
  context[kind] = context[kind] or {}
  table.insert(context[kind], value)
  return value
end

local function remove_doc(doc)
  for i = #core.docs, 1, -1 do
    if core.docs[i] == doc then
      table.remove(core.docs, i)
      doc:on_close()
      return
    end
  end
end

local function open_editor(context, text)
  local doc = track(context, "docs", core.open_doc())
  if text and text ~= "" then doc:text_input(text) end
  local view = track(context, "views", require("core.panes").open_doc(doc, { pane = "left" }))
  core.set_active_view(view)
  return view, doc
end

local function write_navigation_file(context, label, text)
  navigation_test_file_id = navigation_test_file_id + 1
  local path = (os.getenv("TEMP") or os.getenv("TMP") or USERDIR)
    .. PATHSEP .. "anvil-navigation-history-test-"
    .. system.get_process_id() .. "-" .. navigation_test_file_id .. "-" .. label
  local fp = assert(io.open(path, "wb"))
  fp:write(text or "")
  fp:close()
  track(context, "navigation_files", path)
  return path
end

local function open_named_editor(context, label, text)
  local path = write_navigation_file(context, label, text)
  local doc = track(context, "docs", core.open_doc(path))
  local view = track(context, "views", require("core.panes").open_doc(doc, { pane = "left" }))
  core.set_active_view(view)
  return view, doc, path
end

local function track_active_editor(context)
  local view = core.active_view
  if view then track(context, "views", view) end
  if view and view.doc then track(context, "docs", view.doc) end
  return view
end

local function open_side_editor(context, name, text)
  local doc = track(context, "docs", core.open_doc())
  if text and text ~= "" then doc:text_input(text) end
  local view = track(context, "side_views", file_context.mark_editor_view(DocView(doc)))
  panes.register_view("right", name, view)
  return view, doc
end

local function set_caret(view, line, col)
  view:with_selection_state(function()
    view.doc:set_selection(line, col, line, col)
  end)
end

local function caret(view)
  return view:with_selection_state(function()
    local line, col = view.doc:get_selection()
    return line, col
  end)
end

test.describe("IntelliJ-style navigation history", function()
  test.after_each(function(context)
    navigation_history.clear_history()

    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end

    if context.original_fake_git_file_at then
      fake_git_backend.file_at = context.original_fake_git_file_at
    end

    if context.original_file_tree_dir then
      local filetree = require "plugins.filetree"
      filetree.current_dir = context.original_file_tree_dir
      filetree:refresh(false, true)
    end
    if context.file_tree_test_root then common.rm(context.file_tree_test_root, true) end

    for _, state in ipairs(context.output_slot_states or {}) do
      state.slot.output_history = state.output_history
      state.slot.output_history_index = state.output_history_index
      state.slot.view = state.view
    end

    local root = core.root_panel.root_node
    for _, view in ipairs(context.side_views or {}) do
      if panes.contains_view("right", view) then panes.remove_view(view, { force = true, focus_left = false }) end
    end
    panes.hide_right(false)

    for _, view in ipairs(context.views or {}) do
      local node = root:get_node_for_view(view)
      if node then node:remove_view(root, view) end
    end
    for _, key in ipairs(context.git_session_keys or {}) do
      if core.panes and core.panes.git_sessions then core.panes.git_sessions[key] = nil end
    end
    for _, doc in ipairs(context.docs or {}) do
      if doc:is_dirty() then doc:clean() end
      remove_doc(doc)
    end
    for _, path in ipairs(context.navigation_files or {}) do
      os.remove(path)
    end
    navigation_history.clear_history()
  end)

  test.it("returns directly to the departing singleton Editor", function(context)
    local first, _, first_path = open_named_editor(context, "singleton-first.txt", "one\ntwo\nthree\n")
    set_caret(first, 3, 2)
    navigation_history.clear_history()

    local _, _, second_path = open_named_editor(context, "singleton-second.txt", "alpha\nbeta\n")

    local back = navigation_history.back_places()
    test.equal(#back, 1)
    test.ok(common.path_equals(back[1].filename, first_path))
    test.equal(back[1].line, 3)
    test.equal(back[1].col, 2)

    test.ok(command.perform("navigation:back"))
    local restored = track_active_editor(context)
    test.ok(common.path_equals(restored.doc.abs_filename, first_path))
    local line, col = caret(restored)
    test.equal(line, 3)
    test.equal(col, 2)

    test.ok(command.perform("navigation:forward"))
    local restored_second = track_active_editor(context)
    test.ok(common.path_equals(restored_second.doc.abs_filename, second_path))
  end)

  test.it("branches singleton Editor history and clears stale forward places", function(context)
    local first = open_named_editor(context, "branch-first.txt", "first\nline\n")
    set_caret(first, 2, 3)
    navigation_history.clear_history()

    local second = open_named_editor(context, "branch-second.txt", "second\n")
    test.ok(command.perform("navigation:back"))
    local restored_first = track_active_editor(context)
    test.equal(restored_first.doc.abs_filename, first.doc.abs_filename)
    test.ok(navigation_history.is_forward_available())

    local third = open_named_editor(context, "branch-third.txt", "third\n")
    test.equal(core.active_view, third)
    test.not_ok(navigation_history.is_forward_available())

    local back = navigation_history.back_places()
    test.equal(#back, 1)
    test.equal(back[1].filename, first.doc.abs_filename)
    test.ok(not common.path_equals(back[1].filename, second.doc.abs_filename))
  end)

  test.it("records the source singleton Editor when a Fuzzy Searcher result replaces it", function(context)
    local first, _, first_path = open_named_editor(context, "fuzzy-source.txt", "source\nline\n")
    set_caret(first, 2, 4)
    local target_path = write_navigation_file(context, "fuzzy-target.txt", "target\n")
    navigation_history.clear_history()

    fuzzy_searcher.open_static_results("Navigation target", {
      { kind = "file", file = target_path, text = target_path },
    })
    local picker = core.fuzzy_searcher_active_view
    picker.selected = 1
    picker:confirm(false)

    test.ok(common.path_equals(core.active_view.doc.abs_filename, target_path))
    test.ok(command.perform("navigation:back"))
    local restored = track_active_editor(context)
    test.ok(common.path_equals(restored.doc.abs_filename, first_path))
    local line, col = caret(restored)
    test.equal(line, 2)
    test.equal(col, 4)
  end)

  test.it("records the active untitled Pane Tab instead of a hidden singleton Editor", function(context)
    open_named_editor(context, "hidden-singleton.txt", "hidden\n")
    local untitled = open_editor(context, "active untitled")
    navigation_history.clear_history()

    open_named_editor(context, "replacement-singleton.txt", "replacement\n")

    local back = navigation_history.back_places()
    test.equal(#back, 1)
    test.equal(back[1].doc, untitled.doc)
    test.equal(back[1].filename, nil)

    test.ok(command.perform("navigation:back"))
    test.equal(core.active_view, untitled)
  end)

  test.it("goes back and forward between editor places recorded by tab navigation", function(context)
    local first = open_editor(context, "one\ntwo\nthree")
    local second = open_editor(context, "alpha\nbeta\ngamma")
    local node = core.root_panel.root_node:get_node_for_view(first)

    set_caret(first, 2, 1)
    set_caret(second, 3, 1)
    node:set_active_view(first)
    navigation_history.clear_history()

    node:set_active_view(second)
    test.ok(navigation_history.is_back_available())

    test.ok(command.perform("navigation:back"))
    test.equal(core.active_view, first)
    local line, col = caret(first)
    test.equal(line, 2)
    test.equal(col, 1)
    test.ok(navigation_history.is_forward_available())

    test.ok(command.perform("navigation:forward"))
    test.equal(core.active_view, second)
    line, col = caret(second)
    test.equal(line, 3)
    test.equal(col, 1)
  end)

  test.it("keeps Editor history isolated while the File Tree is focused", function(context)
    local first = open_editor(context, "one")
    local second = open_editor(context, "two")
    local node = core.root_panel.root_node:get_node_for_view(first)

    node:set_active_view(first)
    navigation_history.clear_history()
    node:set_active_view(second)
    test.ok(navigation_history.is_back_available())

    local filetree = require "plugins.filetree"
    core.set_active_view(filetree)
    test.equal(core.active_view, filetree)
    test.ok(not navigation_history.is_back_available())

    test.ok(not command.perform("navigation:back"))
    test.equal(core.active_view, filetree)

    node:set_active_view(second)
    test.ok(command.perform("navigation:back"))
    test.equal(core.active_view, first)
  end)

  test.it("checkpoints a departing Editor without connecting it to the File Tree scope", function(context)
    local first = open_editor(context, "one")
    local second = open_editor(context, "two")
    local filetree = require "plugins.filetree"
    local node = core.root_panel.root_node:get_node_for_view(first)

    node:set_active_view(first)
    navigation_history.clear_history()
    core.set_active_view(filetree)
    node:set_active_view(second)

    test.ok(navigation_history.is_back_available())
    test.ok(command.perform("navigation:back"))
    test.equal(core.active_view, first)
  end)

  test.it("navigates File Tree selections inside the File Tree scope", function()
    local filetree = require "plugins.filetree"
    panes.show("right", { view = require("plugins.filetree"), focus = true })
    filetree.position.x, filetree.position.y = 0, 0
    filetree.size.x, filetree.size.y = 800, 600
    local entries = filetree:build_entries(false)
    test.ok(#entries >= 2, "expected at least two File Tree entries")
    local first = entries[1]
    local target = entries[2]
    set_caret(filetree, first.line, 1)
    local first_place = navigation_history.capture_current_place()
    navigation_history.clear_history()

    set_caret(filetree, target.line, 1)
    test.ok(navigation_history.record_place(first_place, { check_current = false, reason = "test-file-tree-selection" }))
    test.ok(navigation_history.is_back_available())

    test.ok(command.perform("navigation:back"))
    test.equal(core.active_view, filetree)
    test.equal(filetree.doc:get_selection(), first.line)
  end)

  test.it("restores the File Tree directory before restoring its selected path", function(context)
    local filetree = require "plugins.filetree"
    local root = core.root_project()
    local parent_dir = root.path .. PATHSEP .. "navigation-history-file-tree-test"
    local child_dir = parent_dir .. PATHSEP .. "child"
    test.ok(common.mkdirp(child_dir))
    local fixture_path = child_dir .. PATHSEP .. "fixture.txt"
    local fp = assert(io.open(fixture_path, "wb"))
    fp:write("fixture\n")
    fp:close()
    context.file_tree_test_root = parent_dir
    context.original_file_tree_dir = filetree.current_dir
    panes.show("right", { view = require("plugins.filetree"), focus = true })

    filetree.current_dir = child_dir
    filetree:refresh(false, true)
    local child_entry = filetree:build_entries(false)[1]
    test.not_nil(child_entry)
    set_caret(filetree, child_entry.line, 1)
    local child_place = navigation_history.capture_current_place()

    filetree.current_dir = parent_dir
    filetree:refresh(false, true)
    local parent_entry = filetree:build_entries(false)[1]
    test.not_nil(parent_entry)
    set_caret(filetree, parent_entry.line, 1)
    navigation_history.clear_history()
    test.ok(navigation_history.record_place(child_place, {
      check_current = false,
      reason = "test-file-tree-directory",
    }))

    test.ok(command.perform("navigation:back"))
    test.ok(common.path_equals(filetree.current_dir, child_dir))
    local restored = filetree:entry_for_line(filetree.doc:get_selection())
    test.not_nil(restored)
    test.ok(common.path_equals(restored.abs, child_entry.abs))
  end)

  test.it("navigates Command Output Views within their panel scope", function(context)
    local editor = open_editor(context, "editor")
    local panel = track(context, "side_views", command_slots.CommandOutputPanel())
    panes.register_view("right", "navigation output", panel)
    panes.show("right", { view = panel, focus = true })
    local first = panel:select_slot(1, { focus = true })
    local second = panel:slot_view(command_slots.slots[2])
    test.ok(first ~= second)

    navigation_history.clear_history()
    panel:select_slot(2, { focus = true })
    test.equal(core.active_view, second)
    test.ok(navigation_history.is_back_available())

    test.ok(command.perform("navigation:back"))
    test.equal(core.active_view, first)
    test.ok(core.active_view ~= editor)
  end)

  test.it("restores Command Output History entries as Navigation Places", function(context)
    local slot = command_slots.slots[1]
    track(context, "output_slot_states", {
      slot = slot,
      output_history = slot.output_history,
      output_history_index = slot.output_history_index,
      view = slot.view,
    })
    local first = { text = "first output\n" }
    local second = { text = "second output\n" }
    slot.output_history = { first, second }
    slot.output_history_index = 1

    local panel = track(context, "side_views", command_slots.CommandOutputPanel())
    panes.register_view("right", "navigation output history", panel)
    panes.show("right", { view = panel, focus = true })
    local view = panel:select_slot(1, { focus = true })
    view:show_entry(first)
    navigation_history.clear_history()

    test.ok(command.perform("command-slots:history-next"))
    test.equal(view.displayed_entry, second)
    test.ok(navigation_history.is_back_available())

    test.ok(command.perform("navigation:back"))
    test.equal(core.active_view, view)
    test.equal(view.displayed_entry, first)

    local evicted_place = navigation_history.capture_current_place()
    slot.output_history = { second }
    slot.output_history_index = 1
    view:show_entry(second)
    navigation_history.clear_history()
    test.ok(not navigation_history.record_place(evicted_place, {
      check_current = false,
      reason = "test-evicted-output",
    }))
  end)

  test.it("restores a blank Command Output place after newer output appears", function(context)
    local slot = command_slots.slots[1]
    track(context, "output_slot_states", {
      slot = slot,
      output_history = slot.output_history,
      output_history_index = slot.output_history_index,
      view = slot.view,
    })
    slot.output_history = {}
    slot.output_history_index = nil

    local panel = track(context, "side_views", command_slots.CommandOutputPanel())
    panes.register_view("right", "navigation blank output", panel)
    panes.show("right", { view = panel, focus = true })
    local view = panel:select_slot(1, { focus = true })
    view:show_entry(nil)
    local blank_place = navigation_history.capture_current_place()

    local newer = { text = "newer output\n" }
    slot.output_history = { newer }
    slot.output_history_index = 1
    view:show_entry(newer)
    navigation_history.clear_history()
    test.ok(navigation_history.record_place(blank_place, {
      check_current = false,
      reason = "test-blank-output",
    }))

    test.ok(command.perform("navigation:back"))
    test.equal(core.active_view, view)
    test.equal(view.displayed_entry, nil)
    test.equal(view.doc.output_text, "")
  end)

  test.it("navigates nested Git panes within one Project Git scope", function(context)
    local project = { path = "C:/navigation-history-git" }
    local tw, log_view = git_view.open_view(project, {
      root = core.root_panel,
      git_view_opts = { backend = fake_git_backend },
    })
    track(context, "views", log_view)
    track(context, "git_session_keys", project.path)
    log_view.model:log_tab().commits = {
      { hash = "first", short_hash = "first", subject = "First", parents = {} },
      { hash = "second", short_hash = "second", subject = "Second", parents = {} },
    }
    log_view:update_pane_docs()
    log_view:focus_list_pane()
    test.equal(core.active_view.git_owner_view, log_view)
    core.active_view.doc:set_selection(1, 1)
    navigation_history.clear_history()
    test.ok(command.perform("git:select-next-row"))
    test.equal(log_view.model:selected_commit().hash, "second")
    local commits = log_view.model:log_tab().commits
    log_view.model:log_tab().commits = { commits[2], commits[1] }
    log_view.model:log_tab().selected_commit = 1
    log_view.model:log_tab().selected_commit_hash = "second"
    log_view:update_pane_docs()
    core.active_view.doc:set_selection(1, 1)
    test.ok(command.perform("navigation:back"))
    test.equal(log_view.model:selected_commit().hash, "first")
    test.equal(core.active_view.doc:get_selection(), 2)

    local removed_commit_place = navigation_history.capture_current_place()
    log_view.model:select_log_index(1, function() end)
    log_view:update_pane_docs()
    core.active_view.doc:set_selection(1, 1)
    navigation_history.clear_history()
    test.ok(navigation_history.record_place(removed_commit_place, {
      check_current = false,
      reason = "test-removed-git-anchor",
    }))
    log_view.model:log_tab().commits = { log_view.model:log_tab().commits[1] }
    log_view:update_pane_docs()
    test.ok(not navigation_history.is_back_available())

    local history_tab = {
      id = "navigation-history-file-history",
      kind = "file_history",
      title = "History",
      closable = true,
      relpath = "file.lua",
      commits = {},
      selected_commit = 1,
    }
    log_view.model.tabs[#log_view.model.tabs + 1] = history_tab
    navigation_history.clear_history()
    local history_view = git_view.ensure_tab_view(tw, history_tab, true)
    track(context, "views", history_view)
    test.equal(core.active_view.git_owner_view, history_view)
    test.ok(navigation_history.is_back_available())

    test.ok(command.perform("navigation:back"))
    test.equal(core.active_view.git_owner_view, log_view)
    test.equal(core.active_view.git_pane, "log-list")
  end)

  test.it("restores the selected Git file before restoring a diff pane", function(context)
    local project = { path = "C:/navigation-history-git-diff" }
    local tw, log_view = git_view.open_view(project, {
      root = core.root_panel,
      git_view_opts = { backend = fake_git_backend },
    })
    track(context, "views", log_view)
    track(context, "git_session_keys", project.path)
    local tab = {
      id = "navigation-history-diff",
      kind = "commit_diff",
      title = "Diff",
      closable = true,
      left = "left",
      right = "right",
      changed_files = {
        { status = "modified", old_path = "first.lua", new_path = "first.lua" },
        { status = "modified", old_path = "second.lua", new_path = "second.lua" },
      },
      selected_file = 1,
      selected_file_path = "first.lua",
      left_text = "first old\n",
      right_text = "first new\n",
      left_name = "first.lua",
      right_name = "first.lua",
      diff_generation = 1,
    }
    log_view.model.tabs[#log_view.model.tabs + 1] = tab
    local diff_owner = git_view.ensure_tab_view(tw, tab, true)
    track(context, "views", diff_owner)
    test.ok(diff_owner:focus_diff_pane("left"))
    local first_file_place = navigation_history.capture_current_place()

    diff_owner.model:select_diff_file(tab, 2, function() end)
    diff_owner:update_pane_docs()
    test.ok(diff_owner:focus_diff_pane("left"))
    navigation_history.clear_history()
    test.ok(navigation_history.record_place(first_file_place, {
      check_current = false,
      reason = "test-git-diff-file",
    }))

    context.original_fake_git_file_at = fake_git_backend.file_at
    local pending_file_loads = {}
    fake_git_backend.file_at = function(_, _, relpath, _, callback)
      pending_file_loads[#pending_file_loads + 1] = function()
        callback("deferred contents for " .. tostring(relpath) .. "\n", nil)
      end
      return { cancel = function() end }
    end
    test.ok(command.perform("navigation:back"))
    test.equal(tab.selected_file_path, "first.lua")
    test.equal(#pending_file_loads, 2)
    for _, finish in ipairs(pending_file_loads) do finish() end
    fake_git_backend.file_at = context.original_fake_git_file_at
    context.original_fake_git_file_at = nil
    test.equal(core.active_view.git_owner_view, diff_owner)
    test.equal(core.active_view, tab.diff_view.doc_view_a)
  end)

  test.it("records editor mouse-style cursor jumps through document commands", function(context)
    local view = open_editor(context, "one\ntwo\nthree\nfour")
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 800, 600
    set_caret(view, 1, 1)
    navigation_history.clear_history()

    local x, y = view:get_line_screen_position(3, 1)
    test.ok(command.perform("doc:set-cursor", x + 1, y + math.floor(view:get_line_height() / 2)))
    local line = caret(view)
    test.equal(line, 3)
    test.ok(navigation_history.is_back_available())

    test.ok(command.perform("navigation:back"))
    line = caret(view)
    test.equal(line, 1)
  end)

  test.it("records same-line editor cursor jumps", function(context)
    local view = open_editor(context, "alpha beta gamma")
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 800, 600
    set_caret(view, 1, 1)
    navigation_history.clear_history()

    local x, y = view:get_line_screen_position(1, 13)
    test.ok(command.perform("doc:set-cursor", x + 1, y + math.floor(view:get_line_height() / 2)))
    local line, col = caret(view)
    test.equal(line, 1)
    test.ok(col > 5)
    test.ok(navigation_history.is_back_available())

    test.ok(command.perform("navigation:back"))
    line, col = caret(view)
    test.equal(line, 1)
    test.equal(col, 1)
  end)

  test.it("keeps automatic tracking connected after plugin reload", function(context)
    local first = open_editor(context, "one")
    local second = open_editor(context, "two")
    local node = core.root_panel.root_node:get_node_for_view(first)

    node:set_active_view(first)
    core.reload_module("plugins.navigation_history")
    navigation_history = require "plugins.navigation_history"
    navigation_history.clear_history()

    node:set_active_view(second)
    test.ok(navigation_history.is_back_available())
    test.ok(command.perform("navigation:back"))
    test.equal(core.active_view, first)
  end)

  test.it("clears forward history after a new navigation", function(context)
    local first = open_editor(context, "one")
    local second = open_editor(context, "two")
    local third = open_editor(context, "three")
    local node = core.root_panel.root_node:get_node_for_view(first)

    node:set_active_view(first)
    navigation_history.clear_history()

    node:set_active_view(second)
    test.ok(command.perform("navigation:back"))
    test.ok(navigation_history.is_forward_available())

    node:set_active_view(third)
    test.ok(not navigation_history.is_forward_available())
  end)

  test.it("shares Right Pane history across File Tree and Editor tabs", function(context)
    local panes = require "core.panes"
    local filetree = require "plugins.filetree"
    panes.show("right", { view = filetree, focus = true })
    local entries = filetree:build_entries(false)
    test.ok(#entries > 0)
    set_caret(filetree, entries[1].line, 1)
    navigation_history.clear_history()

    local doc = track(context, "docs", core.open_doc())
    doc:text_input("right one\nright two")
    local editor = panes.open_doc(doc, { pane = "right", focus = true })
    set_caret(editor, 2, 4)
    panes.show("right", { view = filetree, focus = true })

    test.ok(command.perform("navigation:back"))
    test.equal(core.active_view, editor)
    local line, col = caret(editor)
    test.equal(line, 2)
    test.equal(col, 4)
  end)

  test.it("restoring a hidden Right Pane place expands that pane", function(context)
    local panes = require "core.panes"
    local left = open_editor(context, "left")
    local doc = track(context, "docs", core.open_doc())
    doc:text_input("right one\nright two")
    local right = panes.open_doc(doc, { pane = "right", focus = true })
    set_caret(right, 2, 3)
    local place = navigation_history.capture_place(right)

    panes.hide_right(true)
    test.equal(core.active_view, left)
    test.equal(panes.right_visible(), false)
    test.ok(navigation_history.restore_place(place))
    test.equal(core.active_view, right)
    test.equal(panes.right_visible(), true)
  end)
end)
