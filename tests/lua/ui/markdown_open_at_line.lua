local core = require "core"
local config = require "core.config"
local panes = require "core.panes"
local test = require "core.test"

-- A long note with blocks that Live Preview draws at other heights.
local function note_text()
  local lines = {}
  local function add(line) lines[#lines + 1] = line end
  for section = 1, 24 do
    add("# Section " .. section)
    add("")
    for _ = 1, 4 do add(string.rep("Paragraph text that wraps. ", 12)) end
    add("")
    add("```lua")
    for i = 1, 6 do add(("local value_%d = %d"):format(i, i)) end
    add("```")
    add("")
    add("| Name | Value |")
    add("| --- | --- |")
    for i = 1, 3 do add(("| row %d | %d |"):format(i, i)) end
    add("")
    add("- item one")
    add("- item two")
    add("")
  end
  return table.concat(lines, "\n")
end

local function wait_until(predicate)
  local deadline = system.get_time() + 10
  repeat
    if predicate() then return true end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  return predicate()
end

test.describe("Opening a Markdown file at a line", function()
  test.before_each(function(context)
    context.old_markdown_live_editor = config.markdown_live_editor
    config.markdown_live_editor = true
    context.dir = USERDIR .. PATHSEP .. "markdown-open-at-line"
    test.ok(test.remove_tree(context.dir))
    test.ok(system.mkdir(context.dir))
  end)

  test.after_each(function(context)
    panes.reset_for_tests()
    config.markdown_live_editor = context.old_markdown_live_editor
    test.ok(test.remove_tree(context.dir))
  end)

  test.it("shows the destination line after Live Preview renders", function(context)
    local path = context.dir .. PATHSEP .. "note.md"
    local file = assert(io.open(path, "wb"))
    file:write(note_text())
    file:close()

    -- Small layout corrections above this line used to cancel the jump.
    local target = 560
    local view = core.root_panel:open_file(path, { line = target, col = 1 })
    test.ok(wait_until(function()
      return view.size.y > 0 and not view.__async_wrap_reconstruction
    end), "the view did not finish its layout")
    -- Let the scroll animation and later layout passes settle.
    for _ = 1, 60 do coroutine.yield(0.01) end

    local y = test.not_nil(view:get_position_highlight_geometry(target, 1))
    local top, bottom = view.position.y, view.position.y + view.size.y
    test.ok(y >= top and y < bottom, ("line %d is outside the view: y=%.1f view=%.1f-%.1f")
      :format(target, y, top, bottom))
  end)
end)
