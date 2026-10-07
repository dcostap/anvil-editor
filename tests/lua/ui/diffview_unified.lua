local core = require "core"
local command = require "core.command"
local config = require "core.config"
local diffview = require "plugins.diffview"
local test = require "core.test"

local function ready(view)
  local deadline = system.get_time() + 3
  while view.updater_idx do
    test.ok(system.get_time() < deadline, "comparison did not finish")
    coroutine.yield(0.01)
  end
  view:update()
end

local function open(context, before, after)
  local view = diffview.open({
    contents = { diffview.content.text(before), diffview.content.text(after) },
    auto_reveal_first_change = false,
  }, true)
  context.view = view
  view.size.x, view.size.y = 800, 600
  ready(view)
  return view, view:get_focus_view()
end

test.describe("Unified Diff View", function()
  test.before_each(function(context)
    context.layout = config.plugins.diffview.layout
    config.plugins.diffview.layout = "unified"
    context.active_view = core.active_view
    context.set_active_view = core.set_active_view
    context.get_clipboard, context.set_clipboard = system.get_clipboard, system.set_clipboard
    core.set_active_view = function(view) core.active_view = view end
  end)

  test.after_each(function(context)
    config.plugins.diffview.layout = context.layout
    if context.view then context.view:on_close() end
    if context.other_view then context.other_view:on_close() end
    core.active_view, core.set_active_view = context.active_view, context.set_active_view
    system.get_clipboard, system.set_clipboard = context.get_clipboard, context.set_clipboard
  end)

  test.it("uses Unified Diff at every width until the Project layout is toggled", function(context)
    local view, surface = open(context, "top\nold\nbottom\n", "top\nnew\nbottom\n")
    view.size.x = 2400
    view:update()
    test.equal(#view:get_surface_focus_targets(), 1)
    core.set_active_view(surface)
    test.ok(command.perform("diff:toggle_layout"))
    view:update()
    test.equal(#view:get_surface_focus_targets(), 2)
    view.size.x = 300
    view:update()
    test.equal(#view:get_surface_focus_targets(), 2)
    local other = diffview.string_to_string("before", "after", "Before", "After", true)
    context.other_view = other
    other.size.x, other.size.y = 2400, 600
    ready(other)
    test.equal(#other:get_surface_focus_targets(), 2)
    test.ok(command.perform("diff:toggle_layout"))
    view:update()
    other:update()
    test.equal(#view:get_surface_focus_targets(), 1)
    test.equal(#other:get_surface_focus_targets(), 1)
  end)

  test.it("shows context once and removals before additions on one read-only surface", function(context)
    local view, surface = open(context, "top\nold one\nold two\nbottom\n", "top\nnew one\nnew two\nbottom\n")
    test.equal(#view:get_surface_focus_targets(), 1)
    test.equal(table.concat(surface.buffer.lines), "top\nold one\nold two\nnew one\nnew two\nbottom\n")
    test.ok(not surface:can_edit("test"))
    core.set_active_view(surface)
    surface:with_selection_state(function() surface.buffer:set_selection(2, 1, 6, 1) end)
    local copied
    system.set_clipboard = function(text) copied = text end
    command.perform("core:copy")
    test.equal(copied, "old one\nold two\nnew one\nnew two\n")
    system.get_clipboard = function() return "edited" end
    command.perform("core:paste")
    test.equal(table.concat(surface.buffer.lines), "top\nold one\nold two\nnew one\nnew two\nbottom\n")
    test.equal(table.concat(view.buffer_view_a.buffer.lines), "top\nold one\nold two\nbottom\n")
    test.equal(table.concat(view.buffer_view_b.buffer.lines), "top\nnew one\nnew two\nbottom\n")
  end)

  test.it("keeps the selected source location and focus when the layout changes", function(context)
    local view, surface = open(context, "top\nold\nbottom\n", "top\nnew\nbottom\n")
    core.set_active_view(surface)
    surface:with_selection_state(function() surface.buffer:set_selection(3, 2) end)
    test.ok(command.perform("diff:toggle_layout"))
    view:update()
    test.equal(#view:get_surface_focus_targets(), 2)
    test.equal(core.active_view, view.buffer_view_b)
    test.equal(core.active_view:get_selection_state().selections[1], 2)
    test.equal(core.active_view:get_selection_state().selections[2], 2)
    test.ok(command.perform("diff:toggle_layout"))
    view:update()
    test.equal(core.active_view, view:get_focus_view())
    test.equal(core.active_view:get_selection_state().selections[1], 3)
    test.equal(core.active_view:get_selection_state().selections[2], 2)
  end)

  test.it("navigates deletion-only changes and copies their patch", function(context)
    local view, surface = open(context, "top\nremoved\nbottom\n", "top\nbottom\n")
    core.set_active_view(surface)
    test.ok(command.perform("diff:next_change"))
    test.equal(surface:get_selection_state().selections[1], 2)
    local copied
    system.set_clipboard = function(text) copied = text end
    command.perform("diff:copy_diff_patch_under_cursor")
    test.ok(copied and copied:find("\n-removed\n", 1, true))
    local target = view:get_path_target()
    test.equal(target, nil)
  end)

  test.it("refreshes when a source changes without making either source read-only", function(context)
    local view, surface = open(context, "top\nold\n", "top\nnew\n")
    local source = view.buffer_view_b
    test.ok(source:can_edit("test"))
    source.buffer:insert(2, 1, "extra\n")
    ready(view)
    test.equal(table.concat(surface.buffer.lines), "top\nold\nextra\nnew\n")
    test.ok(not surface:can_edit("test"))
  end)

  test.it("keeps the source location when a unified comparison finishes after focus changes", function(context)
    local view = diffview.open({
      contents = { diffview.content.text("top\nold\nbottom\n"), diffview.content.text("top\nnew\nbottom\n") },
      auto_reveal_first_change = false,
    }, true)
    context.view = view
    view.buffer_view_b:with_selection_state(function() view.buffer_view_b.buffer:set_selection(3, 2) end)
    core.set_active_view(view.buffer_view_b)
    view.size.x, view.size.y = 800, 600
    view:update()
    ready(view)
    test.equal(core.active_view, view:get_focus_view())
    test.equal(core.active_view:get_selection_state().selections[1], 4)
    test.equal(core.active_view:get_selection_state().selections[2], 2)
  end)

  test.it("restores the unified location through Navigation History", function(context)
    local view, surface = open(context, "top\nold\nbottom\n", "top\nnew\nbottom\n")
    core.set_active_view(surface)
    surface:with_selection_state(function() surface.buffer:set_selection(3, 2) end)
    local state = view:get_navigation_state()
    surface:with_selection_state(function() surface.buffer:set_selection(1, 1) end)
    view:set_navigation_state(state)
    test.equal(surface:get_selection_state().selections[1], 3)
    test.equal(surface:get_selection_state().selections[2], 2)
  end)

  test.it("maps removed and added rows to their own source paths and line offsets", function(context)
    local view = diffview.open({
      contents = {
        diffview.content.text("top\nold\nbottom\n", { source_path = USERDIR .. "/before.lua", source_line = 10 }),
        diffview.content.text("top\nnew\nbottom\n", { source_path = USERDIR .. "/after.lua", source_line = 20 }),
      }, auto_reveal_first_change = false,
    }, true)
    context.view = view
    view.size.x, view.size.y = 800, 600
    ready(view)
    local surface = view:get_focus_view()
    core.set_active_view(surface)
    surface:with_selection_state(function() surface.buffer:set_selection(2, 1) end)
    local target = view:get_path_target()
    test.equal(target.path:gsub("\\", "/"), USERDIR:gsub("\\", "/") .. "/before.lua")
    test.equal(target.line, 11)
    surface:with_selection_state(function() surface.buffer:set_selection(3, 1) end)
    target = view:get_path_target()
    test.equal(target.path:gsub("\\", "/"), USERDIR:gsub("\\", "/") .. "/after.lua")
    test.equal(target.line, 21)
  end)

  test.it("copies only change blocks touched by the unified selection", function(context)
    local _, surface = open(context, "top\nold\na\nb\nc\nd\nlast old\nend\n",
      "top\nnew\na\nb\nc\nd\nlast new\nend\n")
    core.set_active_view(surface)
    surface:with_selection_state(function() surface.buffer:set_selection(2, 1, 4, 1) end)
    local copied
    system.set_clipboard = function(text) copied = text end
    test.ok(command.perform("diff:copy_diff_patch_for_selection"))
    test.ok(copied and copied:find("\n-old\n", 1, true))
    test.ok(copied:find("\n+new\n", 1, true))
    test.ok(not copied:find("\n-last old\n", 1, true))
    test.ok(not copied:find("\n+last new\n", 1, true))
  end)

  test.it("scrolls the visible unified text when the mouse wheel moves", function(context)
    local text = string.rep("context line\n", 200)
    local view, surface = open(context, "removed\n" .. text, "added\n" .. text)
    core.set_active_view(surface)
    surface.scroll.y, surface.scroll.to.y = 0, 0
    local _, initial_y = surface:get_content_offset()
    test.ok(view:on_mouse_wheel(-1, 0), "the Diff View must consume the wheel event")
    local deadline = system.get_time() + 2
    repeat
      coroutine.yield(0.01)
      view:update()
      test.ok(system.get_time() < deadline, "the wheel did not move the visible text")
    until surface.scroll.y > 0
    local _, scrolled_y = surface:get_content_offset()
    test.ok(scrolled_y < initial_y, "scrolling down must move the visible text upward")
    local target_y = surface.scroll.to.y
    test.ok(view:on_mouse_wheel(1, 0))
    test.ok(surface.scroll.to.y < target_y, "scrolling up must reduce the scroll target")
  end)
end)
