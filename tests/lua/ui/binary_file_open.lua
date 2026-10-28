local command = require "core.command"
local common = require "core.common"
local core = require "core"
local NagView = require "core.nagview"
local panes = require "core.panes"
local RootPanel = require "core.rootpanel"
local test = require "core.test"

local function write_file(path, data)
  local file = assert(io.open(path, "wb"))
  file:write(data)
  file:close()
end

local function choose(nag, action)
  for i, option in ipairs(nag.options or {}) do
    if option.action == action then
      nag:change_hovered(i)
      return command.perform("core:select_dialog_entry")
    end
  end
  error("dialog has no option " .. action)
end

test.describe("Binary file open", function()
  local saved, dir

  test.before_each(function()
    panes.reset_for_tests()
    saved = {
      root_panel = core.root_panel, nag_view = core.nag_view,
      set_active_view = core.set_active_view, active_view = core.active_view,
      open_in_system = common.open_in_system,
    }
    core.set_active_view = function(view) core.active_view = view end
    core.root_panel = RootPanel()
    core.root_panel.size.x, core.root_panel.size.y = 900, 600
    core.nag_view = NagView()
    dir = USERDIR .. PATHSEP .. "binary-open-" .. system.get_process_id()
    common.mkdirp(dir)
  end)

  test.after_each(function()
    local nag = core.nag_view
    nag.queue = {}
    if nag.visible then nag:next() end
    panes.reset_for_tests()
    core.root_panel, core.nag_view = saved.root_panel, saved.nag_view
    core.set_active_view, core.active_view = saved.set_active_view, saved.active_view
    common.open_in_system = saved.open_in_system
    test.ok(test.remove_tree(dir))
  end)

  test.it("asks how to open a binary file instead of showing its bytes", function()
    local path = dir .. PATHSEP .. "tool.exe"
    write_file(path, "MZ\144\0\3\0\0\0\4\0\0\0\255\255")
    test.equal(core.open_file(path), false)
    test.equal(panes.count(), 0)
    test.ok(core.nag_view.visible)
  end)

  test.it("opens a binary file with the default app", function()
    local path = dir .. PATHSEP .. "data.bin"
    write_file(path, "header\0payload")
    local opened
    common.open_in_system = function(resource) opened = resource; return true end
    core.open_file(path)
    choose(core.nag_view, "system")
    test.equal(opened, system.absolute_path(path))
    test.equal(panes.count(), 0)
  end)

  test.it("opens a binary file as text on request", function()
    local path = dir .. PATHSEP .. "data.bin"
    write_file(path, "header\0payload")
    core.open_file(path)
    choose(core.nag_view, "text")
    test.equal(panes.count(), 1)
    test.equal(panes.active().current_view.buffer.abs_filename, system.absolute_path(path))
  end)

  test.it("opens UTF-16 text without asking", function()
    local path = dir .. PATHSEP .. "notes.txt"
    write_file(path, "\255\254h\0i\0\n\0")
    test.ok(core.open_file(path))
    test.not_ok(core.nag_view.visible)
    test.equal(panes.count(), 1)
  end)
end)
