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
    test.ok(wait_until(function() return core.active_view ~= source_view end), "the link did not open its note")
    local view = core.active_view
    test.not_nil(view.buffer)
    test.ok(common.path_equals(view.buffer.abs_filename, path))
    test.ok(wait_until(function() return layout_ready(view) end), "the target note did not finish layout")
    test.equal(view.buffer:get_selection(), target)
    test.ok(wait_until(function() return line_is_visible(view, target) end),
      "the linked heading did not scroll into view on the first click")
  end)

  local function click_moved_heading(context, at_caret)
    local path = context.dir .. PATHSEP .. "Target.md"
    local source = context.dir .. PATHSEP .. "Source.md"
    write_file(path, "# Target\n\n## Destination\n\nBody\n")
    write_file(source, "[[Target#Destination|Go to section]]\n\nSource text\n" .. string.rep("\nSource filler\n", 100))
    local index = markdown.vault_index.get_index(context.dir):rebuild("moved-heading-click-test")
    local buffer = core.root_panel:open_file(path).buffer
    local source_view = core.root_panel:open_file(source, { line = at_caret and 1 or 3 })
    test.ok(wait_until(function()
      local entry = index:note(path)
      return layout_ready(source_view) and entry and entry.buffer == buffer
        and entry.buffer_revision == buffer.text_revision
    end), "the target's initial headings did not publish")

    -- Keep the old index entry but move the heading past the first screen.
    buffer:insert(1, 1, string.rep("Filler text.\n", 150))
    local link = markdown.links.from_target("wiki", "Target#Destination")
    test.equal(index:resolve(link, source).line, 3)
    if at_caret then
      test.ok(require("core.markdown.live_render").open_link(source_view))
    else
      click_first_line(source_view)
    end
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

  test.it("does not follow a waiting link after the source scrolls", function(context)
    local _, source_view, index, link = click_moved_heading(context, true)
    core.root_panel:on_mouse_left()
    test.ok(require("core.command").perform("core:scroll", -4))
    test.ok(source_view.scroll.to.y > 0, "the source did not scroll")
    test.ok(wait_until(function()
      return index:resolve(link, source_view.buffer.abs_filename).line == 153
    end))
    coroutine.yield(0.1)
    test.equal(core.active_view, source_view)
  end)

  test.it("replaces a waiting link with the next activation", function(context)
    local buffer, source_view = click_moved_heading(context)
    require("core.markdown.live_render").open_link(source_view, {
      link = markdown.links.from_target("wiki", "Target#Target"),
    })
    test.ok(wait_until(function()
      return core.active_view.buffer == buffer and buffer:get_selection() == 151
    end))
    coroutine.yield(0.1)
    test.equal(buffer:get_selection(), 151)
  end)

  for _, fragment in ipairs({ "Destination", "^destination" }) do
    test.it("follows an unopened note's current " .. fragment .. " after a disk edit", function(context)
      local path = context.dir .. PATHSEP .. "Target.md"
      local source = context.dir .. PATHSEP .. "Source.md"
      local text = "# Target\n\n## Destination\nBody ^destination\n"
      write_file(path, text)
      write_file(source, "[[Target#" .. fragment .. "|Go]]\n\nSource\n")
      markdown.vault_index.get_index(context.dir):rebuild("disk-edit-link")
      local source_view = core.root_panel:open_file(source, { line = 3 })
      test.ok(wait_until(function() return layout_ready(source_view) end))
      write_file(path, string.rep("Filler\n", 150) .. text)
      click_first_line(source_view)
      local target = fragment == "Destination" and 153 or 154
      test.ok(wait_until(function()
        local view = core.active_view
        return view.buffer and common.path_equals(view.buffer.abs_filename or "", path)
          and view.buffer:get_selection() == target and line_is_visible(view, target)
      end), "the first click did not reach the current target")
    end)
  end

  for _, cold in ipairs({ true, false }) do
    test.it("follows a large note heading with a " .. (cold and "cold" or "ready") .. " index", function(context)
      local path = context.dir .. PATHSEP .. "Target.md"
      local source = context.dir .. PATHSEP .. "Source.md"
      -- Exceed both indexing limits without making a very long visual document.
      write_file(path, "<!-- " .. string.rep("padding ", 140000) .. " -->\n\n## Destination\n")
      write_file(source, "[[Target#Destination|Go]]\n\nSource\n")
      local source_view = core.root_panel:open_file(source, { line = 3 })
      local index = markdown.vault_index.get_index(context.dir)
      if cold then
        require("core.project_files").list(context.dir)
        test.equal(index:can_resolve(), false)
        require("core.markdown.live_render").open_link(source_view, {
          link = markdown.links.from_target("wiki", "Target#Destination"),
        })
      else
        index:rebuild("large-link-test")
        test.ok(wait_until(function() return layout_ready(source_view) end))
        click_first_line(source_view)
      end
      test.ok(wait_until(function()
        local view = core.active_view
        return view.buffer and common.path_equals(view.buffer.abs_filename or "", path)
          and view.buffer:get_selection() == 3
      end), "the first click did not reach the large note's heading")
    end)
  end

  test.it("follows a Markdown heading added after the disk index was built", function(context)
    local path = context.dir .. PATHSEP .. "Target.md"
    local source = context.dir .. PATHSEP .. "Source.md"
    write_file(path, "# Target\n")
    write_file(source, "[Go](Target.md#Destination)\n\nSource\n")
    markdown.vault_index.get_index(context.dir):rebuild("new-heading-link")
    local source_view = core.root_panel:open_file(source, { line = 3 })
    test.ok(wait_until(function() return layout_ready(source_view) end))
    write_file(path, string.rep("Filler\n", 150) .. "## Destination\n")
    click_first_line(source_view)
    test.ok(wait_until(function()
      local view = core.active_view
      return view ~= source_view and view.buffer:get_selection() == 151 and line_is_visible(view, 151)
    end), "the stale missing-heading entry blocked activation")
  end)

  test.it("follows a heading in the current note", function(context)
    local path = context.dir .. PATHSEP .. "Source.md"
    write_file(path, "[Go](#Destination)\n\n" .. string.rep("Filler\n", 150) .. "## Destination\n")
    markdown.vault_index.get_index(context.dir):rebuild("same-note-heading")
    local view = core.root_panel:open_file(path, { line = 3 })
    test.ok(wait_until(function() return layout_ready(view) end))
    click_first_line(view)
    test.ok(wait_until(function()
      return view.buffer:get_selection() == 153 and line_is_visible(view, 153)
    end), "the current note's heading did not become visible")
  end)

  test.it("follows a link from a scrolled source note", function(context)
    local path = context.dir .. PATHSEP .. "Target.md"
    local source = context.dir .. PATHSEP .. "Source.md"
    write_file(path, string.rep("Filler\n", 150) .. "## Destination\n")
    write_file(source, string.rep("Source filler\n\n", 75)
      .. "# Around the link\n[[Target#Destination|Go]]\n\n" .. string.rep("Tail\n\n", 75))
    markdown.vault_index.get_index(context.dir):rebuild("scrolled-source-link")
    local source_view = core.root_panel:open_file(source, { line = 151 })
    test.ok(wait_until(function() return layout_ready(source_view) and line_is_visible(source_view, 152) end))
    test.ok(source_view.scroll.to.y > 0)
    local x, y = source_view:get_line_screen_position(152)
    core.root_panel:on_mouse_pressed("left", x + 2, y + 2, 1)
    core.root_panel:on_mouse_released("left", x + 2, y + 2)
    test.ok(wait_until(function()
      local view = core.active_view
      return view ~= source_view and view.buffer:get_selection() == 151 and line_is_visible(view, 151)
    end), "source layout cancelled the link")
  end)

  test.it("keeps a linked heading visible when a row grows after layout", function(context)
    local path = context.dir .. PATHSEP .. "Target.md"
    local source = context.dir .. PATHSEP .. "Source.md"
    write_file(path, string.rep("Filler\n", 150) .. "## Destination\n" .. string.rep("Tail\n", 150))
    write_file(source, "[[Target#Destination|Go]]\n\nSource\n")
    markdown.vault_index.get_index(context.dir):rebuild("late-layout-link")
    local source_view = core.root_panel:open_file(source, { line = 3 })
    test.ok(wait_until(function() return layout_ready(source_view) end))
    click_first_line(source_view)
    test.ok(wait_until(function()
      local view = core.active_view
      return view ~= source_view and layout_ready(view) and line_is_visible(view, 151)
    end))
    local view = core.active_view
    local old_height = view:get_scrollable_size()
    local row_height = view.size.y * 3
    view:add_visual_metric_provider("late-row", {
      line_height = function(_, _, line)
        if line == 140 then return row_height end
      end,
    }, { priority = 1000 })
    view:invalidate_visual_metrics("late-row")
    coroutine.yield(0.1)
    test.ok(view:get_scrollable_size() > old_height + view.size.y * 2,
      "the test row did not grow")
    test.equal(view.buffer:get_selection(), 151)
    test.ok(wait_until(function() return line_is_visible(view, 151) end),
      "late layout moved the linked heading offscreen")
    core.root_panel:on_mouse_left()
    test.ok(require("core.command").perform("core:scroll", 10000))
    test.ok(wait_until(function() return view.scroll.y == 0 end))
    row_height = row_height * 2
    view:invalidate_visual_metrics("late-row")
    coroutine.yield(0.1)
    test.equal(view.scroll.to.y, 0, "layout restored a jump after the user scrolled away")
  end)

  test.it("waits for a loading note before resolving a cold-index heading", function(context)
    local path = context.dir .. PATHSEP .. "Target.md"
    local source = context.dir .. PATHSEP .. "Source.md"
    write_file(path, string.rep("Filler\n", 150) .. "## Destination\n")
    write_file(source, "[[Target#Destination|Go]]\n\nSource\n")
    require("core.project_files").list(context.dir)
    local source_view = core.root_panel:open_file(source, { line = 3 })
    local buffer = require("core.buffer")(path, path, true)
    core.buffer_registry:register(buffer, path)
    buffer:load_async(path)
    test.ok(buffer:is_loading())
    test.equal(markdown.vault_index.get_index(context.dir):can_resolve(), false)
    require("core.markdown.live_render").open_link(source_view, {
      link = markdown.links.from_target("wiki", "Target#Destination"),
    })
    local reached = wait_until(function()
      local view = core.active_view
      return view.buffer == buffer and buffer:get_selection() == 151 and line_is_visible(view, 151)
    end)
    test.ok(reached, string.format("activation did not wait for the loaded heading: active=%s line=%s loading=%s error=%s",
      tostring(core.active_view.buffer and core.active_view.buffer.abs_filename), tostring(buffer:get_selection()),
      tostring(buffer:is_loading()), tostring(buffer.load_error)))
  end)
end)
