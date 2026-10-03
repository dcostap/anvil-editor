local core = require "core"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local panes = require "core.panes"
local command = require "core.command"
local test = require "core.test"

local function select_line(view, line)
  view:set_selection_state { selections = { line, 1, line, 1 }, last_selection = 1 }
end

local function editor(name, line)
  local buffer = Buffer(nil, nil, true)
  buffer:insert(1, 1, string.rep("line\n", 100))
  buffer.abs_filename = USERDIR .. PATHSEP .. name
  local view = Editor(buffer)
  select_line(view, line)
  return view
end

local function record(pane, view, line)
  select_line(view, line)
  panes.record_location(pane)
end

local function check_place(pane, view, line)
  test.equal(pane.current_view, view)
  test.equal(view:get_selection_state().selections[1], line)
end

test.describe("File navigation history commands", function()
  local set_active_view

  test.before_each(function()
    panes.reset_for_tests()
    set_active_view = core.set_active_view
    core.set_active_view = function(view) core.active_view = view end
  end)

  test.after_each(function()
    panes.reset_for_tests()
    core.set_active_view = set_active_view
  end)

  test.it("skips current-file places and stops at the nearest different file in both directions", function()
    local a = editor("navigation-a.txt", 10)
    local pane = panes.create { factory = function() return a end }
    record(pane, a, 20)
    local b = editor("navigation-b.txt", 30)
    panes.present(b, { pane = pane })
    record(pane, b, 40)
    record(pane, b, 50)
    local c = editor("navigation-c.txt", 60)
    panes.present(c, { pane = pane })
    record(pane, c, 70)

    test.ok(command.perform("core:navigate_back_file"))
    check_place(pane, b, 50)
    test.ok(command.perform("core:navigate_back_file"))
    check_place(pane, a, 20)
    test.ok(command.perform("core:navigate_forward_file"))
    check_place(pane, b, 30)
    test.ok(command.perform("core:navigate_forward_file"))
    check_place(pane, c, 60)

    -- Skipped places remain available to ordinary navigation.
    test.ok(command.perform("core:navigate_forward"))
    check_place(pane, c, 70)
    test.ok(command.perform("core:navigate_back"))
    check_place(pane, c, 60)
  end)

  test.it("reaches history ends when all places share a file, even across Views", function()
    local a = editor("navigation-same.txt", 10)
    local pane = panes.create { factory = function() return a end }
    record(pane, a, 20)
    local other = a:duplicate()
    select_line(other, 30)
    panes.present(other, { pane = pane })
    record(pane, other, 40)
    local unrelated = editor("navigation-other-pane.txt", 50)
    panes.create { factory = function() return unrelated end }
    panes.focus(pane)

    test.ok(command.perform("core:navigate_back_file"))
    check_place(pane, a, 10)
    test.not_ok(command.perform("core:navigate_back_file"))
    test.ok(command.perform("core:navigate_forward_file"))
    check_place(pane, other, 40)
    test.not_ok(command.perform("core:navigate_forward_file"))
    test.equal(panes.active_pane, pane)
  end)

  test.it("returns to the only recorded place after moving away", function()
    local a = editor("navigation-end.txt", 10)
    local pane = panes.create { factory = function() return a end }
    select_line(a, 11)

    test.ok(command.perform("core:navigate_back_file"))
    check_place(pane, a, 10)
    test.not_ok(command.perform("core:navigate_back_file"))
  end)
end)
