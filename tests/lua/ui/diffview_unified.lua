local core = require "core"
local command = require "core.command"
local config = require "core.config"
local diffview = require "plugins.diffview"
local keymap = require "core.keymap"
local test = require "core.test"
local style = require "core.style"

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

local function copy(surface)
  local copied
  system.set_clipboard = function(text) copied = text end
  command.perform("core:copy")
  return copied
end

local function click_source_line(surface, index, line, col)
  local x, y = surface:get_source_screen_position(index, line, col)
  test.ok(x, "the source line must be visible")
  surface:on_mouse_moved(x + 1, y + 1, 0, 0)
  surface:on_mouse_pressed("left", x + 1, y + 1, 1)
  surface:on_mouse_released("left", x + 1, y + 1)
end

local function drag_source_text(surface, from, to, clicks)
  local x1, y1 = surface:get_source_screen_position(from[1], from[2], from[3])
  local x2, y2 = surface:get_source_screen_position(to[1], to[2], to[3])
  test.ok(x1 and x2, "both source positions must be visible")
  surface:on_mouse_moved(x1 + 1, y1 + 1, 0, 0)
  -- Core gives a press the View leaves unhandled to the keymap's click commands.
  if not surface:on_mouse_pressed("left", x1 + 1, y1 + 1, clicks or 1) then
    keymap.on_mouse_pressed("left", x1 + 1, y1 + 1, clicks or 1)
  end
  surface:on_mouse_moved(x2 + 1, y2 + 1, 0, 0)
  surface:on_mouse_released("left", x2 + 1, y2 + 1)
end

local function normalize_path(path)
  return (path:gsub("\\", "/"))
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

  test.it("shows removed lines once above their replacements and copies them in that order", function(context)
    local view, surface = open(context, "top\nold one\nold two\nbottom\n", "top\nnew one\nnew two\nbottom\n")
    test.equal(#view:get_surface_focus_targets(), 1)
    test.equal(surface.buffer, view.buffer_view_b.buffer)
    local _, top_y = surface:get_source_screen_position(2, 1, 1)
    local _, removed_y = surface:get_source_screen_position(1, 3, 1)
    local _, added_y = surface:get_source_screen_position(2, 2, 1)
    test.ok(top_y < removed_y and removed_y < added_y, "removed lines must come before added lines")
    core.set_active_view(surface)
    surface:with_selection_state(function() surface.buffer:set_selection(1, 4, 4, 1) end)
    test.equal(copy(surface), "\nold one\nold two\nnew one\nnew two\n")
  end)

  test.it("edits the current Diff Side through the unified surface", function(context)
    local view, surface = open(context, "top\nold\nbottom\n", "top\nnew\nbottom\n")
    core.set_active_view(surface)
    test.ok(surface:can_edit("test"))
    surface:with_selection_state(function() surface.buffer:set_selection(2, 1) end)
    system.get_clipboard = function() return "edited " end
    command.perform("core:paste")
    test.equal(table.concat(view.buffer_view_b.buffer.lines), "top\nedited new\nbottom\n")
    test.equal(table.concat(view.buffer_view_a.buffer.lines), "top\nold\nbottom\n")
    ready(view)
    surface:with_selection_state(function() surface.buffer:set_selection(1, 4, 3, 1) end)
    test.equal(copy(surface), "\nold\nedited new\n")
  end)

  test.it("keeps the unified surface read-only when neither Diff Side is editable", function(context)
    local view = diffview.open({
      contents = {
        diffview.content.text("top\nold\n", { editable = false }),
        diffview.content.text("top\nnew\n", { editable = false, read_only_reason = "Committed text" }),
      }, auto_reveal_first_change = false,
    }, true)
    context.view = view
    view.size.x, view.size.y = 800, 600
    ready(view)
    local allowed, reason = view:get_focus_view():can_edit("test")
    test.ok(not allowed)
    test.equal(reason, "Committed text")
  end)

  test.it("edits the left Diff Side when only that side is editable", function(context)
    local view = diffview.open({
      contents = {
        diffview.content.text("top\nold\nbottom\n"),
        diffview.content.text("top\nnew\nbottom\n", { editable = false }),
      }, auto_reveal_first_change = false,
    }, true)
    context.view = view
    view.size.x, view.size.y = 800, 600
    ready(view)
    local surface = view:get_focus_view()
    test.equal(surface.buffer, view.buffer_view_a.buffer)
    local _, removed_y = surface:get_source_screen_position(1, 2, 1)
    local _, added_y = surface:get_source_screen_position(2, 2, 1)
    test.ok(removed_y < added_y, "removed lines must come before added lines")
    core.set_active_view(surface)
    surface:with_selection_state(function() surface.buffer:set_selection(1, 4, 3, 1) end)
    test.equal(copy(surface), "\nold\nnew\n")
    click_source_line(surface, 2, 2, 1)
    local allowed, reason = surface:can_edit("test")
    test.ok(not allowed)
    test.equal(reason, "Added lines are read-only")
  end)

  test.it("focuses a clicked removed line for copying and its source location", function(context)
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
    test.equal(normalize_path(target.path), normalize_path(USERDIR) .. "/after.lua")
    test.equal(target.line, 21)

    click_source_line(surface, 1, 2, 2)
    target = view:get_path_target()
    test.equal(normalize_path(target.path), normalize_path(USERDIR) .. "/before.lua")
    test.equal(target.line, 11)
    test.equal(copy(surface), "old\n")
    local allowed, reason = surface:can_edit("test")
    test.ok(not allowed, "removed lines are not part of the editable Buffer")
    test.equal(reason, "Removed lines are read-only")

    surface:with_selection_state(function() surface.buffer:set_selection(3, 1) end)
    test.ok(surface:can_edit("test"))
    target = view:get_path_target()
    test.equal(normalize_path(target.path), normalize_path(USERDIR) .. "/after.lua")
  end)

  test.it("selects part of a removed line with the mouse", function(context)
    local _, surface = open(context, "top\nold text\nbottom\n", "top\nnew text\nbottom\n")
    core.set_active_view(surface)
    drag_source_text(surface, { 1, 2, 1 }, { 1, 2, 4 })
    test.equal(copy(surface), "old")
    local allowed, reason = surface:can_edit("test")
    test.ok(not allowed)
    test.equal(reason, "Removed lines are read-only")
  end)

  test.it("selects across removed and added lines in either drag direction", function(context)
    local _, surface = open(context, "top\nold text\nbottom\n", "top\nnew text\nbottom\n")
    core.set_active_view(surface)
    drag_source_text(surface, { 1, 2, 5 }, { 2, 2, 4 })
    test.equal(copy(surface), "text\nnew")
    drag_source_text(surface, { 2, 2, 4 }, { 1, 2, 5 })
    test.equal(copy(surface), "text\nnew")
    drag_source_text(surface, { 2, 1, 2 }, { 1, 2, 4 })
    test.equal(copy(surface), "op\nold")
  end)

  test.it("selects text on a later wrapped row of a removed line", function(context)
    local words = {}
    for i = 1, 80 do words[i] = string.format("w%02d", i) end
    local long = table.concat(words, " ")
    local view, surface = open(context, "top\n" .. long .. "\nbottom\n", "top\nnew\nbottom\n")
    core.set_active_view(surface)
    surface:set_wrapping_enabled(true)
    view:update()
    local col = long:find("w70", 1, true)
    local _, first_y = surface:get_source_screen_position(1, 2, 1)
    local _, wrapped_y = surface:get_source_screen_position(1, 2, col)
    test.ok(wrapped_y > first_y, "the removed line must wrap at this width")
    drag_source_text(surface, { 1, 2, col }, { 1, 2, col + 7 })
    test.equal(copy(surface), "w70 w71")
  end)

  test.it("selects a word of a removed line on double-click", function(context)
    local _, surface = open(context, "top\nold text\nbottom\n", "top\nnew text\nbottom\n")
    core.set_active_view(surface)
    drag_source_text(surface, { 1, 2, 6 }, { 1, 2, 6 }, 2)
    test.equal(copy(surface), "text")
  end)

  test.it("moves the caret through removed lines with Up and Down", function(context)
    local _, surface = open(context, "top\nold one\nold two\nbottom\n", "top\nnew\nbottom\n")
    core.set_active_view(surface)
    surface:with_selection_state(function() surface.buffer:set_selection(2, 2) end)
    local function caret() return { surface:source_position() } end
    local expected_up = { { 1, 3, 2 }, { 1, 2, 2 }, { 2, 1, 2 } }
    for _, expected in ipairs(expected_up) do
      command.perform("core:move_to_previous_line")
      test.same(caret(), expected)
    end
    local expected_down = { { 1, 2, 2 }, { 1, 3, 2 }, { 2, 2, 2 } }
    for _, expected in ipairs(expected_down) do
      command.perform("core:move_to_next_line")
      test.same(caret(), expected)
    end
  end)

  test.it("moves the caret across removed lines with Left, Right and End", function(context)
    local _, surface = open(context, "top\nold one\nold two\nbottom\n", "top\nnew\nbottom\n")
    core.set_active_view(surface)
    surface:with_selection_state(function() surface.buffer:set_selection(1, 4) end)
    local function caret() return { surface:source_position() } end
    command.perform("core:move_to_next_char")
    test.same(caret(), { 1, 2, 1 })
    command.perform("core:move_to_end_of_line")
    test.same(caret(), { 1, 2, 8 })
    command.perform("core:move_to_next_char")
    test.same(caret(), { 1, 3, 1 })
    command.perform("core:move_to_next_word_end")
    test.same(caret(), { 1, 3, 4 })
    command.perform("core:move_to_end_of_line")
    command.perform("core:move_to_next_char")
    test.same(caret(), { 2, 2, 1 })
    command.perform("core:move_to_previous_char")
    test.same(caret(), { 1, 3, 8 })
    command.perform("core:move_to_start_of_line")
    command.perform("core:move_to_previous_char")
    test.same(caret(), { 1, 2, 8 })
  end)

  test.it("extends a selection from added lines into removed lines", function(context)
    local _, surface = open(context, "top\nold one\nold two\nbottom\n", "top\nnew\nbottom\n")
    core.set_active_view(surface)
    surface:with_selection_state(function() surface.buffer:set_selection(2, 1) end)
    command.perform("core:select_to_previous_line")
    command.perform("core:select_to_previous_line")
    test.equal(copy(surface), "old one\nold two\n")
    command.perform("core:select_to_next_line")
    command.perform("core:select_to_next_line")
    command.perform("core:select_to_next_char")
    test.equal(copy(surface), "n")
    local allowed = surface:can_edit("test")
    test.ok(allowed, "a selection back inside added lines is editable")
  end)

  test.it("moves the caret down into removed lines after the last line", function(context)
    local _, surface = open(context, "top\ngone", "top")
    core.set_active_view(surface)
    surface:with_selection_state(function() surface.buffer:set_selection(1, 2) end)
    command.perform("core:move_to_next_line")
    test.same({ surface:source_position() }, { 1, 2, 2 })
    command.perform("core:move_to_previous_line")
    test.same({ surface:source_position() }, { 2, 1, 2 })
  end)

  test.it("moves the caret through the wrapped rows of a removed line", function(context)
    local words = {}
    for i = 1, 80 do words[i] = string.format("w%02d", i) end
    local view, surface = open(context, "top\n" .. table.concat(words, " ") .. "\nbottom\n", "top\nnew\nbottom\n")
    core.set_active_view(surface)
    surface:set_wrapping_enabled(true)
    view:update()
    surface:with_selection_state(function() surface.buffer:set_selection(1, 1) end)
    command.perform("core:move_to_next_line")
    test.same({ surface:source_position() }, { 1, 2, 1 })
    command.perform("core:move_to_next_line")
    local index, line, col = surface:source_position()
    test.same({ index, line }, { 1, 2 })
    test.ok(col > 1, "the caret must reach the second row of the removed line")
  end)

  test.it("reveals a removed line the caret moves into", function(context)
    local removed = string.rep("removed line\n", 200)
    local view, surface = open(context, removed .. "kept\n", "kept\n")
    core.set_active_view(surface)
    surface:with_selection_state(function() surface:select_and_reveal(1, 1, 1, 1, { instant = true }) end)
    view:update()
    test.ok(surface.scroll.to.y > 0, "the kept line must start below the viewport top")
    command.perform("core:move_to_start_of_buffer")
    test.same({ surface:source_position() }, { 1, 1, 1 })
    surface.scroll.y = surface.scroll.to.y
    local _, y = surface:get_source_screen_position(1, 1, 1)
    test.ok(y >= surface.position.y and y < surface.position.y + surface.size.y,
      "the caret's removed line must be visible")
  end)

  test.it("keeps the selected source location and focus when the layout changes", function(context)
    local view, surface = open(context, "top\nold\nbottom\n", "top\nnew\nbottom\n")
    core.set_active_view(surface)
    surface:with_selection_state(function() surface.buffer:set_selection(2, 2) end)
    test.ok(command.perform("diff:toggle_layout"))
    view:update()
    test.equal(#view:get_surface_focus_targets(), 2)
    test.equal(core.active_view, view.buffer_view_b)
    test.equal(core.active_view:get_selection_state().selections[1], 2)
    test.equal(core.active_view:get_selection_state().selections[2], 2)
    test.ok(command.perform("diff:toggle_layout"))
    view:update()
    test.equal(core.active_view, view:get_focus_view())
    test.equal(core.active_view:get_selection_state().selections[1], 2)
    test.equal(core.active_view:get_selection_state().selections[2], 2)
  end)

  test.it("keeps a removed line selected when the layout changes", function(context)
    local view, surface = open(context, "top\nold\nbottom\n", "top\nnew\nbottom\n")
    core.set_active_view(surface)
    click_source_line(surface, 1, 2, 1)
    test.ok(command.perform("diff:toggle_layout"))
    view:update()
    test.equal(core.active_view, view.buffer_view_a)
    test.equal(core.active_view:get_selection_state().selections[1], 2)
    test.ok(command.perform("diff:toggle_layout"))
    view:update()
    test.equal(core.active_view, surface)
    test.equal(copy(surface), "old\n")
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

  test.it("refreshes when either source changes", function(context)
    local view, surface = open(context, "top\nold\n", "top\nnew\n")
    view.buffer_view_a.buffer:insert(2, 1, "gone\n")
    view.buffer_view_b.buffer:insert(2, 1, "extra\n")
    ready(view)
    core.set_active_view(surface)
    surface:with_selection_state(function() surface.buffer:set_selection(1, 4, 3, 4) end)
    test.equal(copy(surface), "\ngone\nold\nextra\nnew")
    test.ok(surface:can_edit("test"))
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
    test.equal(core.active_view:get_selection_state().selections[1], 3)
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

  for _, layout in ipairs { "unified", "side-by-side" } do
    test.it("restores the " .. layout .. " scroll position in a reopened Diff View", function(context)
      config.plugins.diffview.layout = layout
      local before, after = {}, {}
      for i = 1, 400 do
        before[i] = "line " .. i
        after[i] = (i % 40 == 0) and ("changed " .. i) or before[i]
      end
      local before_text, after_text = table.concat(before, "\n") .. "\n", table.concat(after, "\n") .. "\n"
      local view, surface = open(context, before_text, after_text)
      core.set_active_view(surface)
      -- The wheel scrolls without moving the caret.
      test.ok(view:on_mouse_wheel(-20, 0))
      for _ = 1, 20 do view:update() end
      for _, side in ipairs { view.buffer_view_a, view.buffer_view_b, view.unified_view } do
        side.scroll.y = side.scroll.to.y
      end
      view:update()
      local saved_y = surface.scroll.y
      test.ok(saved_y > 0, "the Diff View must scroll")
      local saved_top = surface:get_visible_line_range()
      local state = view:get_navigation_state()

      local reopened = diffview.open({
        contents = { diffview.content.text(before_text), diffview.content.text(after_text) },
        auto_reveal_first_change = false,
      }, true)
      context.other_view = reopened
      reopened:set_navigation_state(state)
      reopened.size.x, reopened.size.y = 800, 600
      ready(reopened)
      for _ = 1, 5 do reopened:update() end
      local restored = reopened:get_focus_view()
      test.equal(restored:get_visible_line_range(), saved_top)
      test.equal(restored.scroll.y, saved_y)
    end)
  end

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

  test.it("shows all change types inside the unified scrollbar track", function(context)
    local text = string.rep("context line\n", 100)
    local _, surface = open(context, "removed\n" .. text .. "old\n" .. text,
      text .. "new\n" .. text .. "added\n")
    local markers = {}
    local draw_rect = renderer.draw_rect
    renderer.begin_frame(core.window)
    renderer.draw_rect = function(x, y, w, h, color)
      if color == style.diff_overview_delete or color == style.diff_overview_insert
        or color == style.diff_overview_modify then
        markers[color] = { x = x, y = y, w = w, h = h }
      end
    end
    local ok, err = pcall(surface.draw_scrollbar, surface)
    renderer.draw_rect = draw_rect
    renderer.end_frame()
    if not ok then error(err, 0) end
    local removed = test.not_nil(markers[style.diff_overview_delete], "removed lines need an overview mark")
    local modified = test.not_nil(markers[style.diff_overview_modify], "replaced lines need an overview mark")
    local added = test.not_nil(markers[style.diff_overview_insert], "added lines need an overview mark")
    test.ok(removed.y < modified.y and modified.y < added.y,
      "overview marks must follow their positions in the Unified Diff")
    local x, y, w, h = surface.v_scrollbar:get_track_rect()
    for _, marker in pairs(markers) do
      test.ok(marker.x >= x and marker.x + marker.w <= x + w)
      test.ok(marker.y >= y and marker.y + marker.h <= y + h)
    end
  end)
end)
