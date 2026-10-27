local load_preview = dofile("tests/fixtures/fuzzy_preview.lua")
local core = require "core"
local command = require "core.command"
local config = require "core.config"
local panes = require "core.panes"
local test = require "core.test"
local diffview = require "plugins.diffview"
local git_view = require "plugins.git_view"
local backend = require "plugins.git.backend"
local fuzzy_searcher = require "plugins.fuzzy_searcher"
local View = require "core.view"

require "plugins.intellij_find"

local function type_into_find(surface)
  test.equal(core.active_view, surface)
  local before = table.concat(surface.buffer.lines)
  test.ok(command.perform("editor:find"))
  local input = core.active_view
  test.ok(input.local_find_input)
  input:set_text("")
  core.root_panel:on_text_input("query")
  test.equal(input:get_text(), "query", "typed text must reach the Find input")
  test.equal(table.concat(surface.buffer.lines), before)
end

local function open_diff()
  local view = diffview.open({
    contents = {
      diffview.content.text(("left line\n"):rep(12)),
      diffview.content.text(("right line\n"):rep(12)),
    },
    auto_reveal_first_change = false,
  }, true)
  panes.place(function() return view end, { placement = "new", focus = true })
  local deadline = system.get_time() + 15
  while view.updater_idx do
    test.ok(system.get_time() < deadline, "comparison did not finish")
    coroutine.yield(0.01)
  end
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 1200, 600
  view:update()
  return view
end

test.describe("Local Find keyboard routing", function()
  test.before_each(function(context)
    context.layout = config.plugins.diffview.layout
    panes.reset_for_tests()
  end)

  test.after_each(function(context)
    command.perform("editor:find_close")
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    panes.reset_for_tests()
    config.plugins.diffview.layout = context.layout
    if context.file then pcall(os.remove, context.file) end
  end)

  test.it("leaves Find closed in a one-line text field", function()
    panes.create { factory = function() return View() end }
    fuzzy_searcher.open("")
    local field = core.fuzzy_searcher_active_view.input.textview
    test.equal(core.active_view, field)
    command.perform("editor:find")
    test.equal(core.active_view, field)
  end)

  test.it("types into Find in a focused Fuzzy Searcher preview", function(context)
    local path = system.absolute_path(".") .. PATHSEP .. "find-keys-preview.txt"
    context.file = path
    local file = assert(io.open(path, "wb"))
    file:write("first\nsecond\n")
    file:close()
    panes.create { factory = function() return View() end }
    fuzzy_searcher.open("")
    local picker = core.fuzzy_searcher_active_view
    picker.results = { { kind = "file", file = path, text = path } }
    picker.selected = 1
    local preview = test.not_nil(load_preview(picker))
    test.ok(picker:cycle_local_focus(1))
    test.ok(command.perform("editor:find"))
    local input = core.active_view
    test.ok(input.local_find_input)
    input:set_text("")
    core.on_event("textinput", "sec")
    test.equal(input:get_text(), "sec", "typed text must reach the preview's Find input")
    test.equal(picker.input:get_text(), "")
    test.equal(core.active_view, input)
    picker:close()
  end)

  test.it("types into Find on the unified Diff surface after a layout change", function()
    local view = open_diff()
    config.plugins.diffview.layout = "side-by-side"
    view:update()
    local side = view.buffer_view_b
    local x, y = side:get_line_screen_position(1, 1)
    view:on_mouse_pressed("left", x + 1, y + 1, 1)
    view:on_mouse_released("left", x + 1, y + 1)
    test.equal(core.active_view, side)
    config.plugins.diffview.layout = "unified"
    view:update()
    type_into_find(view.unified_view)
  end)

  test.it("types into Find in the Git Log details after a click", function()
    local _, view = git_view.open_log({ path = "C:/find-keys-repo" }, {
      git_view_opts = { defer_refresh = true },
    })
    view.refresh_pending = nil
    view.model.repo = { root = "C:/find-keys-repo" }
    view.refresh_started = true
    view.model.backend = setmetatable({
      changed_files = function(_, _, _, _, done) done({}, nil) end,
    }, { __index = backend })
    view.model:log_tab().commits = {
      { hash = "cccc", parents = {}, subject = "Newest", changed_files = {} },
    }
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 900, 600
    view:update_pane_buffers()
    view:focus_list_pane()
    view:update()
    local details = view:pane_view("details")
    details.position.x, details.position.y = 600, 0
    details.size.x, details.size.y = 300, 600
    local x, y = details.position.x + 20, details.position.y + 10
    view:on_mouse_pressed("left", x, y, 1)
    view:on_mouse_released("left", x, y)
    type_into_find(details)
  end)
end)
