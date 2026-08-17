local core = require "core"
local BufferRegistry = require "core.buffer_registry"
local Editor = require "core.editor"
local layout = require "core.pane_layout"
local panes = require "core.panes"
local test = require "core.test"
local View = require "core.view"

local function write_file(path, text)
  local file = assert(io.open(path, "wb"))
  file:write(text)
  file:close()
end

test.describe("File opening through Panes", function()
  local saved
  local first_path
  local second_path

  test.before_each(function()
    panes.reset_for_tests()
    saved = {
      buffers = core.buffers,
      buffer_registry = core.buffer_registry,
      set_active_view = core.set_active_view,
    }
    core.buffers = {}
    core.buffer_registry = BufferRegistry(core.buffers)
    core.set_active_view = function(view) core.active_view = view end
    local suffix = system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    first_path = USERDIR .. PATHSEP .. "pane-open-first-" .. suffix .. ".lua"
    second_path = USERDIR .. PATHSEP .. "pane-open-second-" .. suffix .. ".lua"
    write_file(first_path, "first line\nsecond line\n")
    write_file(second_path, "other\n")
  end)

  test.after_each(function()
    panes.reset_for_tests()
    core.buffers = saved.buffers
    core.buffer_registry = saved.buffer_registry
    core.set_active_view = saved.set_active_view
    os.remove(first_path)
    os.remove(second_path)
  end)

  test.it("creates Pane 1 when opening with zero Panes", function()
    local view = core.open_file(first_path)
    test.ok(view:is(Editor))
    test.equal(panes.count(), 1)
    test.equal(panes.number(panes.active()), 1)
    test.equal(panes.active().current_view, view)
  end)

  test.it("replaces a suspendable Editor and Back restores its exact place", function()
    local first = core.open_file(first_path)
    first:set_selection_state { selections = { 2, 3, 2, 3 }, last_selection = 1 }
    first.scroll.x, first.scroll.y = 7, 11
    local second = core.open_file(second_path)
    test.not_equal(second, first)
    test.equal(panes.active().current_view, second)
    test.equal(panes.back(), first)
    local state = first:get_selection_state()
    test.same(state.selections, { 2, 3, 2, 3 })
    test.equal(first.scroll.x, 7)
    test.equal(first.scroll.y, 11)
  end)

  test.it("records a new Navigation Place when an open file is visited again", function()
    local first = core.open_file(first_path)
    local second = core.open_file(second_path)

    local revisited = core.open_file(first_path)

    test.equal(revisited, first)
    test.equal(panes.history_length(panes.active()), 3)
    test.equal(panes.back(), second)
    test.equal(panes.forward(), first)
  end)

  test.it("keeps a file Buffer alive while replacement approval is pending", function()
    local approve
    local PendingView = View:extend()
    function PendingView:can_suspend() return false end
    function PendingView:can_close(callback) approve = callback end

    local pane = panes.create { factory = function() return PendingView() end }
    test.is_nil(core.open_file(first_path))
    test.is_nil(core.buffer_registry:find(first_path))
    test.equal(core.buffer_registry:collect(), 0)

    test.not_nil(approve)
    approve()
    local editor = pane.current_view
    test.ok(editor:is(Editor))
    test.equal(editor.buffer.highlighter.buffer, editor.buffer)

    local original = table.concat(editor.buffer.lines)
    local ok, err = pcall(editor.buffer.insert, editor.buffer, 1, 1, "x")
    test.ok(ok, err)
    editor.buffer:undo()
    test.equal(table.concat(editor.buffer.lines), original)

    write_file(first_path, "changed on disk\n")
    editor.buffer:reload()
    test.equal(table.concat(editor.buffer.lines), "changed on disk\n")
  end)

  test.it("uses independent Editor Selection State for one Buffer in two Panes", function()
    local first = core.open_file(first_path)
    local second = core.open_file(first_path, { placement = "new" })
    test.not_equal(first, second)
    test.equal(first.buffer, second.buffer)
    first:set_selection_state { selections = { 1, 2, 1, 2 }, last_selection = 1 }
    second:set_selection_state { selections = { 2, 4, 2, 4 }, last_selection = 1 }
    test.same(first:get_selection_state().selections, { 1, 2, 1, 2 })
    test.same(second:get_selection_state().selections, { 2, 4, 2, 4 })
  end)

  test.it("targets the Pane under a file drop", function()
    local left = core.open_file(first_path)
    local left_pane = panes.active()
    local right_pane = panes.split(left_pane, "right", {
      factory = function() return Editor(core.open_buffer(first_path)) end,
    })
    layout.update_rects(left_pane.group.root, { x = 0, y = 0, w = 200, h = 100 })
    core.root_panel:on_file_dropped(second_path, 25, 50)
    test.equal(left_pane.current_view.buffer.abs_filename, core.open_buffer(second_path).abs_filename)
    test.equal(right_pane.current_view, right_pane.history.entries[1].view)
  end)

  test.it("creates Pane 1 for a file dropped on blank work area", function()
    test.equal(panes.count(), 0)
    core.root_panel:on_file_dropped(first_path, 50, 50)
    test.equal(panes.count(), 1)
    test.equal(panes.active().current_view.buffer.abs_filename, core.open_buffer(first_path).abs_filename)
  end)
end)
