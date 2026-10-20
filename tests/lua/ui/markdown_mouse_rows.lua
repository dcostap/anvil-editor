local core = require "core"
local common = require "core.common"
local config = require "core.config"
local footnotes = require "core.markdown.footnotes"
local linewrapping = require "core.linewrapping"
local markdown = require "core.markdown"
local model = require "core.markdown.model"
local panes = require "core.panes"
local Project = require "core.project"
local test = require "core.test"
local workers = require "core.worker_pool"

local function write_file(path, text)
  local file = test.not_nil(io.open(path, "wb"))
  file:write(text)
  file:close()
end

local function open_source(context, text, width)
  local path = context.root .. PATHSEP .. "Source.md"
  write_file(path, text)
  write_file(context.root .. PATHSEP .. "Target.md", "Target contents.\n")
  local index = markdown.vault_index.get_index(context.root):rebuild("mouse-rows-test")
  local view = core.open_file(path, { placement = "new", focus = true })
  local instance = test.not_nil(model.peek(view.buffer))
  local deadline = system.get_time() + 30
  repeat
    local pool = workers.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if instance.status == "ready" and index.status == "ready" then break end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  test.equal(instance.status, "ready", instance.reason)
  test.equal(index.status, "ready", index.reason)
  core.root_panel.position.x, core.root_panel.position.y = 100, 100
  core.root_panel.size.x, core.root_panel.size.y = width, 800
  core.root_panel:update_layout()
  view:set_selection_state({
    selections = { #view.buffer.lines, 1, #view.buffer.lines, 1 }, last_selection = 1,
  })
  view:set_wrapping_enabled(true)
  -- Install hidden definitions and inline cards before checking mouse input.
  view:update()
  linewrapping.complete_async_reconstruction(view)
  return view
end

local function point_at(view, line, col)
  view:scroll_to_line(line, false, true)
  local x, y = view:get_line_screen_position(line, col)
  y = y + view:get_line_height() / 2
  test.equal(core.root_panel:view_at(x, y), view)
  return x, y
end

local function click(x, y)
  core.on_event("mousemoved", x, y, 0, 0)
  core.on_event("mousepressed", "left", x, y, 1)
  core.on_event("mousereleased", "left", x, y)
end

local function open_target_by_mouse(context, view, line, col)
  local x, y = point_at(view, line, col)
  core.on_event("mousemoved", x, y, 0, 0)
  test.equal(view.cursor, "hand")
  click(x, y)
  test.ok(common.path_equals(core.active_view.buffer.abs_filename,
    context.root .. PATHSEP .. "Target.md"))
  test.equal(core.active_view.buffer.lines[1], "Target contents.\n")
end

local next_root = 0
test.describe("Markdown mouse targets after display row changes", function()
  test.before_each(function(context)
    panes.reset_for_tests()
    context.projects, context.active_view = core.projects, core.active_view
    context.cwd = system.getcwd()
    context.live = config.markdown_live_editor
    context.root_rect = {
      core.root_panel.position.x, core.root_panel.position.y,
      core.root_panel.size.x, core.root_panel.size.y,
    }
    context.old_buffers = {}
    for _, buffer in ipairs(core.buffers) do context.old_buffers[buffer] = true end
    config.markdown_live_editor = true
    next_root = next_root + 1
    context.root = USERDIR .. PATHSEP .. "markdown-mouse-rows-" .. next_root
    test.ok(common.mkdirp(context.root))
    core.projects = { Project(context.root) }
  end)

  test.after_each(function(context)
    panes.reset_for_tests()
    for i = #core.buffers, 1, -1 do
      local buffer = core.buffers[i]
      if not context.old_buffers[buffer] then core.buffer_registry:remove(buffer, true) end
    end
    core.projects, core.active_view = context.projects, context.active_view
    system.chdir(context.cwd)
    config.markdown_live_editor = context.live
    core.root_panel.position.x, core.root_panel.position.y = context.root_rect[1], context.root_rect[2]
    core.root_panel.size.x, core.root_panel.size.y = context.root_rect[3], context.root_rect[4]
    test.ok(test.remove_tree(context.root))
  end)

  test.it("opens a relative link below hidden footnote definitions by mouse", function(context)
    local view = open_source(context,
      "A note[^1].\n\n[^1]: Footnote text.\n\nA [details](Target.md) link.\nnext\n", 2600)
    test.equal(test.not_nil(footnotes.layout(view)).mode, "margin")
    open_target_by_mouse(context, view, 5, 7)
  end)

  test.it("opens a relative link below inline footnote cards by mouse", function(context)
    local view = open_source(context,
      "A note^[Footnote text].\n\nA [details](Target.md) link.\nnext\n", 800)
    test.equal(test.not_nil(footnotes.layout(view)).mode, "inline")
    open_target_by_mouse(context, view, 3, 7)
  end)

  test.it("opens a link on a wrapped continuation row below hidden definitions", function(context)
    local prose = string.rep("Some prose before the link. ", 20)
    local view = open_source(context,
      "A note[^1].\n\n[^1]: Footnote text.\n\n" .. prose .. "[details](Target.md).\nnext\n", 2600)
    local col = #prose + 4
    test.ok(view:get_visual_row(5, col) > view:get_visual_row(5, 1),
      "the link must be on a continuation row")
    open_target_by_mouse(context, view, 5, col)
  end)

  test.it("opens a link below collapsed text by mouse", function(context)
    local view = open_source(context,
      "Visible\nhidden one\nhidden two\n\nA [details](Target.md) link.\nnext\n", 800)
    test.not_nil(view:add_fold_region {
      line1 = 1, line2 = 3, collapsed = true, show_widget = false,
    })
    open_target_by_mouse(context, view, 5, 7)
  end)

  for _, fixture in ipairs({
    { name = "hidden footnote definitions", prefix = "A note[^1].\n\n[^1]: Footnote text.\n\n", line = 5, width = 2600 },
    { name = "inline footnote cards", prefix = "A note^[Footnote text].\n\n", line = 3, width = 800 },
  }) do
    test.it("toggles a task below " .. fixture.name .. " by mouse", function(context)
      local view = open_source(context, fixture.prefix .. "- [ ] todo\nnext\n", fixture.width)
      local render = test.not_nil(view:get_line_render(fixture.line))
      local checkbox
      for _, fragment in ipairs(view:iter_line_render_fragments(render)) do
        if fragment.markdown_task_checkbox then checkbox = fragment break end
      end
      checkbox = test.not_nil(checkbox)
      local x, y = point_at(view, fixture.line, 1)
      x = x + view:get_line_render_col_x_offset(render, checkbox.source_col1)
        + checkbox.widget.width / 2
      local selection = view:get_selection_state()
      core.on_event("mousemoved", x, y, 0, 0)
      test.equal(view.cursor, "hand")
      click(x, y)
      test.equal(view.buffer.lines[fixture.line], "- [x] todo\n")
      test.same(view:get_selection_state(), selection)
    end)
  end
end)
