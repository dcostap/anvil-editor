local common = require "core.common"
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local panes = require "core.panes"
local test = require "core.test"
local filetree = require "plugins.filetree"
local Editor = require "core.editor"

require "plugins.intellij_find"

local function center(rect) return rect.x + rect.w / 2, rect.y + rect.h / 2 end

-- The Pane layout can move the View between frames, so each point comes from the current layout.
local function toggle_center(view, key)
  for _, item in ipairs(test.not_nil(view:get_local_find_layout()).toggles) do
    if item.key == key then return center(item) end
  end
  error("no toggle " .. key)
end

local function open_find(view)
  local deadline = system.get_time() + 10
  while view.size.x < 400 and system.get_time() < deadline do coroutine.yield(0.01) end
  test.ok(view.size.x >= 400, "the Pane layout did not size the View")
  test.ok(command.perform("editor:find"))
  view:update()
end

local function wait_for_tooltip(view)
  local deadline = system.get_time() + 10
  while not view:get_local_find_tooltip() and system.get_time() < deadline do
    view:update()
    coroutine.yield(0.01)
  end
  return view:get_local_find_tooltip()
end

test.describe("Local Find option toggles", function()
  test.before_each(function() panes.reset_for_tests() end)

  test.after_each(function(context)
    command.perform("editor:find_close")
    panes.reset_for_tests()
    if context.root then test.ok(test.remove_tree(context.root)) end
  end)

  test.it("names a toggle and its shortcut after the pointer rests on it", function()
    local buffer = core.open_buffer()
    buffer:text_input(("text\n"):rep(40))
    local view = panes.place(function() return Editor(buffer) end, { placement = "new", focus = true })
    open_find(view)

    test.ok(view:on_mouse_moved(toggle_center(view, "regex")))
    test.equal(view.cursor, "arrow")
    test.equal(view:get_local_find_tooltip(), nil, "the tooltip waits for the pointer to rest")
    local text, binding = wait_for_tooltip(view)
    test.equal(text, "Regular Expression")
    test.equal(binding, keymap.get_binding("editor:toggle_regex"))

    test.ok(view:on_mouse_moved(center(view:get_local_find_layout().find_input)))
    test.equal(view.cursor, "ibeam")
    test.equal(view:get_local_find_tooltip(), nil)

    test.ok(view:on_mouse_moved(toggle_center(view, "case_sensitive")))
    test.equal(wait_for_tooltip(view), "Match Case")
    view:on_mouse_left()
    test.equal(view:get_local_find_tooltip(), nil, "leaving the View hides the tooltip")
    buffer:clean()
  end)

  test.it("keeps File Tree entry hover out of the Find card", function(context)
    context.root = USERDIR .. PATHSEP .. "find-toggle-tree"
    test.ok(common.mkdirp(context.root))
    for i = 1, 8 do
      local file = assert(io.open(context.root .. PATHSEP .. string.rep("long-name-", 15) .. i .. ".txt", "wb"))
      file:write("content\n")
      file:close()
    end
    local view = assert(filetree.open(context.root, { placement = "new", focus = true }))
    open_find(view)
    local x, y = toggle_center(view, "regex")
    test.not_nil(view:entry_row_at_point(x, y), "the toggle must cover an entry")

    view:on_mouse_moved(x, y)
    test.equal(view.cursor, "arrow", "the toggle is not a link to the entry below")
    test.equal(wait_for_tooltip(view), "Regular Expression")
  end)
end)
