local core = require "core"
local common = require "core.common"
local config = require "core.config"
local markdown = require "core.markdown"
local Project = require "core.project"
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

local function write_file(path, text)
  local file = assert(io.open(path, "wb"))
  file:write(text)
  file:close()
end

local function click_first_line(view)
  local x, y = view:get_line_screen_position(1)
  core.root_panel:on_mouse_pressed("left", x + 2, y + 2, 1)
  core.root_panel:on_mouse_released("left", x + 2, y + 2)
end

local function layout_ready(view)
  local model = markdown.model.peek(view.buffer)
  return view.size.y > 0 and model and model.status == "ready" and not view.__async_wrap_reconstruction
end

local function line_is_visible(view, line)
  local top = view:get_position_highlight_geometry(line, 1)
  return top and top >= view.position.y and top + view:get_line_height() <= view.position.y + view.size.y
end

test.describe("Opening a Markdown file at a line", function()
  test.before_each(function(context)
    context.old_markdown_live_editor = config.markdown_live_editor
    context.old_projects = core.projects
    context.old_active_view = core.active_view
    context.cwd = system.getcwd()
    context.old_buffers = {}
    for _, buffer in ipairs(core.buffers) do context.old_buffers[buffer] = true end
    config.markdown_live_editor = true
    context.dir = USERDIR .. PATHSEP .. "markdown-open-at-line-" .. math.floor(system.get_time() * 1000000)
    test.ok(system.mkdir(context.dir))
    core.projects = { Project(context.dir) }
  end)

  test.after_each(function(context)
    panes.reset_for_tests()
    for i = #core.buffers, 1, -1 do
      local buffer = core.buffers[i]
      if not context.old_buffers[buffer] then core.buffer_registry:remove(buffer, true) end
    end
    core.projects = context.old_projects
    core.active_view = context.old_active_view
    system.chdir(context.cwd)
    config.markdown_live_editor = context.old_markdown_live_editor
    test.ok(test.remove_tree(context.dir))
  end)

  test.it("shows the destination line after Live Preview renders", function(context)
    local path = context.dir .. PATHSEP .. "note.md"
    write_file(path, note_text())

    -- Small layout corrections above this line used to cancel the jump.
    local target = 560
    local view = core.root_panel:open_file(path, { line = target, col = 1 })
    test.ok(wait_until(function()
      if view.size.y <= 0 then return false end
      local y = view:get_position_highlight_geometry(target, 1)
      local top, bottom = view.position.y, view.position.y + view.size.y
      return y and y >= top and y < bottom
    end), "the destination line did not become visible")
  end)

  test.it("shows a linked heading after the target note finishes layout on the first click", function(context)
    local path = context.dir .. PATHSEP .. "Target.md"
    local source = context.dir .. PATHSEP .. "Source.md"
    local text = note_text()
    local heading = assert(text:find("# Section 24", 1, true))
    local _, preceding_lines = text:sub(1, heading - 1):gsub("\n", "")
    local target = preceding_lines + 1
    write_file(path, text)
    write_file(source, "[[Target#Section 24|Go to section]]\n\nSource text\n")
    markdown.vault_index.get_index(context.dir):rebuild("heading-click-test")
    local source_view = core.root_panel:open_file(source, { line = 3 })
    test.ok(wait_until(function() return layout_ready(source_view) end))
    test.is_nil(core.buffer_registry:find(path), "the target note should not be open yet")

    click_first_line(source_view)
    local view = core.active_view
    test.not_nil(view.buffer)
    test.ok(common.path_equals(view.buffer.abs_filename, path))
    test.ok(wait_until(function() return layout_ready(view) end), "the target note did not finish layout")
    test.equal(view.buffer:get_selection(), target)
    test.ok(wait_until(function() return line_is_visible(view, target) end),
      "the linked heading did not scroll into view on the first click")
  end)

  local function click_moved_heading(context)
    local path = context.dir .. PATHSEP .. "Target.md"
    local source = context.dir .. PATHSEP .. "Source.md"
    write_file(path, "# Target\n\n## Destination\n\nBody\n")
    write_file(source, "[[Target#Destination|Go to section]]\n\nSource text\n")
    local index = markdown.vault_index.get_index(context.dir):rebuild("moved-heading-click-test")
    local buffer = core.root_panel:open_file(path).buffer
    local source_view = core.root_panel:open_file(source, { line = 3 })
    test.ok(wait_until(function()
      local entry = index:note(path)
      return layout_ready(source_view) and entry and entry.buffer == buffer
        and entry.buffer_revision == buffer.text_revision
    end), "the target's initial headings did not publish")

    -- Keep the old index entry but move the heading past the first screen.
    buffer:insert(1, 1, string.rep("Filler text.\n", 150))
    local link = markdown.links.from_target("wiki", "Target#Destination")
    test.equal(index:resolve(link, source).line, 3)
    click_first_line(source_view)
    return buffer, source_view, index, link
  end

  test.it("follows a moved heading with one click while the index still has its old line", function(context)
    local buffer = click_moved_heading(context)
    local view
    test.ok(wait_until(function()
      view = core.active_view
      return view.buffer == buffer and layout_ready(view)
    end), "the first click did not open the target note")
    test.equal(view.buffer:get_selection(), 153)
    test.ok(wait_until(function() return line_is_visible(view, 153) end),
      "the moved heading did not scroll into view on the first click")
  end)

  test.it("does not follow a waiting link after the source caret moves", function(context)
    local _, source_view, index, link = click_moved_heading(context)
    test.equal(core.active_view, source_view)
    source_view.buffer:set_selection(3, 1)
    test.ok(wait_until(function()
      return index:resolve(link, source_view.buffer.abs_filename).line == 153
    end), "the new heading position did not publish")
    -- Give the waiting activation a chance to run after the index publishes.
    coroutine.yield(0.1)
    test.equal(core.active_view, source_view)
    test.equal(source_view.buffer:get_selection(), 3)
  end)
end)
