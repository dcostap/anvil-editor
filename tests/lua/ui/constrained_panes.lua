local core = require "core"
local panes = require "core.panes"
local View = require "core.view"
local test = require "core.test"

local function view(owner)
  local result = View()
  result.pane_constraint = owner
  return result
end

test.describe("Constrained Panes", function()
  test.before_each(function() panes.reset_for_tests() end)
  test.after_each(function() panes.reset_for_tests() end)

  test.it("keeps related Views together and sends unrelated Views to another group", function()
    local owner = {}
    local terminal = view(owner)
    local pane = panes.create { factory = function() return terminal end }
    local capture = view(owner)
    panes.place(function() return capture end, { pane = pane })
    test.equal(pane.current_view, capture)
    test.equal(panes.back(pane), terminal)
    test.equal(panes.forward(pane), capture)
    local other = view()
    local opened, destination = panes.place(function() return other end, { pane = pane })
    test.equal(opened, other)
    test.not_equal(destination.group, pane.group)
    test.equal(pane.current_view, capture)
    test.same(panes.views(pane), { terminal, capture })
  end)

  test.it("keeps different owners separate even when their View types match", function()
    local first = panes.create { factory = function() return view({}) end }
    local original = first.current_view
    local _, second = panes.place(function() return view({}) end, { pane = first })
    test.not_equal(first, second)
    test.equal(first.current_view, original)
  end)

  test.it("does not bury an ordinary View when opening a constrained activity", function()
    local first = panes.create { factory = function() return view() end }
    local original = first.current_view
    local _, second = panes.place(function() return view({}) end, { pane = first })
    test.not_equal(first.group, second.group)
    test.equal(first.current_view, original)
  end)

  test.it("keeps a non-suspendable constrained View when opening an unrelated View", function()
    local original = view({})
    function original:can_suspend() return false end
    local pane = panes.create { factory = function() return original end }
    local opened, destination = panes.place(function() return view() end, { pane = pane })
    test.not_nil(opened)
    test.not_equal(destination.group, pane.group)
    test.equal(pane.current_view, original)
    test.ok(panes.validate())
  end)

  test.it("rejects incompatible merges and moves without changing either Pane", function()
    local first = panes.create { factory = function() return view({}) end }
    local second = panes.create { factory = function() return view() end }
    local a, b = first.current_view, second.current_view
    test.not_ok(panes.move_and_merge(first, second))
    test.not_ok(panes.move_current_view(first, second))
    test.equal(first.current_view, a)
    test.equal(second.current_view, b)
    test.equal(panes.count(), 2)
    test.ok(panes.validate())
  end)

  test.it("returns to an activity Pane when opening another related View", function()
    local owner = {}
    local first = panes.create { factory = function() return view(owner) end }
    local other = panes.create { factory = function() return view() end }
    local next_view = view(owner)
    local opened, destination = panes.place(function() return next_view end, { pane = other })
    test.equal(opened, next_view)
    test.equal(destination, first)
    test.equal(panes.count(), 2)
    test.equal(panes.active(), first)
  end)

  test.it("opens a blank split without copying the source activity", function()
    local pane = panes.create { factory = function() return view({}) end }
    test.ok(require("core.command").perform("pane:split_right"))
    local split = panes.active()
    test.not_equal(split, pane)
    test.equal(split.group, pane.group)
    local tree = view()
    local _, destination = panes.place(function() return tree end, { pane = split })
    test.equal(destination, split)
    test.equal(split.current_view, tree)
    test.equal(panes.count(), 2)
  end)

  test.it("reuses an activity without replacing a non-suspendable unrelated View", function()
    local owner = {}
    local activity = panes.create { factory = function() return view(owner) end }
    local original = view()
    function original:can_suspend() return false end
    local other = panes.create { factory = function() return original end }
    local related = view(owner)
    local opened, destination = panes.place(function() return related end, { pane = other })
    test.equal(opened, related)
    test.equal(destination, activity)
    test.equal(other.current_view, original)
    test.equal(panes.count(), 2)
    test.ok(panes.validate())
  end)

  test.it("restores a constrained activity and its current capture together", function()
    local owner = {}
    local original = view(owner)
    original.label = "owner"
    local pane = panes.create { factory = function() return original end }
    local capture = view(owner)
    capture.label = "capture"
    panes.present(capture, { pane = pane })
    local state = panes.save_workspace_state(function(candidate) return { label = candidate.label } end)
    test.ok(panes.restore_workspace_state(state, function(saved)
      local candidate = view(saved.label == "owner" and {} or nil)
      candidate.label = saved.label
      return candidate
    end))
    pane = panes.active()
    test.equal(pane.current_view.label, "capture")
    test.equal(panes.back(pane).label, "owner")
    test.equal(panes.forward(pane).label, "capture")
    local _, elsewhere = panes.place(function() return view() end, { pane = pane })
    test.not_equal(elsewhere, pane)
    test.ok(panes.validate())
  end)

  test.it("rejects splitting one activity across Panes", function()
    local owner = {}
    local pane = panes.create { factory = function() return view(owner) end }
    panes.present(view(owner), { pane = pane })
    test.not_ok(panes.move_current_view_to_split(pane, "right"))
    test.not_ok(panes.split(pane, "right", { factory = function() return view(owner) end }))
    test.equal(panes.count(), 1)
    test.ok(panes.validate())
  end)

  test.it("reuses one comparison Pane for files activated from the same Git commit", function()
    local GitView = require "plugins.git.view"
    local source = GitView(core.root_project(), { defer_refresh = true, backend = {
      WORKING_TREE = "WORKING_TREE", EMPTY_TREE = "EMPTY_TREE",
      diff_endpoint_for_commit = function(commit) return { left = "before", right = commit.hash } end,
      file_at = function(_, revision, path, _, callback) callback(revision .. " " .. path .. "\n") end,
    } })
    source.model.repo = { root = core.root_project().path }
    local files = {
      { status = "modified", old_path = "a.lua", new_path = "a.lua" },
      { status = "modified", old_path = "b.lua", new_path = "b.lua" },
    }
    local log = source.model:log_tab()
    log.commits = {
      { hash = "first", changed_files = files, changed_files_loaded = true },
      { hash = "second", changed_files = files, changed_files_loaded = true },
    }
    log.selected_commit = 1
    local origin = panes.create { factory = function() return source end }
    source:update_pane_buffers(true)
    local poi = require "core.poi"
    local tree = source:pane_view("details")
    test.ok(poi.activate(tree, source:detail_file_points()[1]))
    local destination = panes.active()
    test.not_equal(destination.group, origin.group)
    test.equal(origin.current_view, source)
    panes.focus(origin)
    test.ok(poi.activate(tree, source:detail_file_points()[2]))
    test.equal(panes.active(), destination)
    test.equal(panes.count(), 2)
    test.contains(table.concat(destination.current_view.buffer_view_b.buffer.lines), "first b.lua")
    log.selected_commit = 2
    source:update_pane_buffers(true)
    panes.focus(origin)
    test.ok(poi.activate(tree, source:detail_file_points()[1]))
    test.not_equal(panes.active(), destination)
    test.equal(panes.count(), 3)
    test.ok(panes.close(destination, { force = true }))
    log.selected_commit = 1
    source:update_pane_buffers(true)
    panes.focus(origin)
    test.ok(poi.activate(tree, source:detail_file_points()[1]))
    test.not_equal(panes.active(), destination)
    test.equal(panes.count(), 3)
    local comparison = panes.active().current_view
    test.ok(comparison:open_text_capture())
    local capture = panes.active().current_view
    test.equal(panes.back(panes.active()), comparison)
    test.equal(panes.forward(panes.active()), capture)
    test.ok(panes.validate())
  end)
end)
