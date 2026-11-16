local core = require "core"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local command = require "core.command"
local config = require "core.config"
local menu = require "core.context_menu"
local diffview = require "plugins.diffview"
local test = require "core.test"

local function contains(labels, wanted)
  for _, label in ipairs(labels) do
    if label == wanted then return true end
  end
  return false
end

test.describe("Diff Context Menu", function()
  test.before_each(function(context)
    context.active = core.active_view
    context.layout = config.plugins.diffview.layout
    context.clipboard = system.get_clipboard()
  end)

  test.after_each(function(context)
    menu.close()
    if context.view then context.view:on_close() end
    if context.buffer then context.buffer:on_close() end
    core.active_view = context.active
    config.plugins.diffview.layout = context.layout
    system.set_clipboard(context.clipboard or "")
  end)

  local function comparison(context, layout)
    config.plugins.diffview.layout = layout
    local view = diffview.string_to_string("old\nkeep\nend", "new\nkeep\nchanged", "file.txt", "file.txt", true)
    context.view = view
    view.size.x, view.size.y = 800, 600
    local deadline = system.get_time() + 10
    while view.updater_idx do
      test.ok(system.get_time() < deadline, "comparison did not finish")
      coroutine.yield(0.01)
    end
    view:update()
    return view
  end

  for _, layout in ipairs { "unified", "side-by-side" } do
    test.it("copies the caret's change from the " .. layout .. " menu", function(context)
      local view = comparison(context, layout)
      local surface = view:get_focus_view()
      core.active_view = surface
      surface:with_selection_state(function() surface.buffer:set_selection(1, 1) end)
      test.ok(command.perform("core:show_context_menu"))
      test.ok(not contains(menu.labels(), "Copy Selection Patch"))
      test.ok(menu.choose("Copy Change Patch"))
      test.equal(system.get_clipboard(),
        "--- a/file.txt\n+++ b/file.txt\n@@ -1,3 +1,3 @@\n-old\n+new\n keep\n end\n")
    end)
  end

  test.it("copies selected changes from a read-only side without changing its selection", function(context)
    local view = comparison(context, "side-by-side")
    local surface = view.buffer_view_a
    surface.buffer.read_only = true
    core.active_view = surface
    surface:with_selection_state(function() surface.buffer:set_selection(1, 1, 2, 1) end)
    test.ok(command.perform("core:show_context_menu"))
    test.ok(not contains(menu.labels(), "Paste"))
    test.ok(not contains(menu.labels(), "Copy Change Patch"))
    test.ok(menu.choose("Copy Selection Patch"))
    test.contains(system.get_clipboard(), "-old\n+new\n")
    test.ok(not system.get_clipboard():find("+changed", 1, true))
    surface:with_selection_state(function()
      local l1, c1, l2, c2 = surface.buffer:get_selection(true)
      test.same({ l1, c1, l2, c2 }, { 1, 1, 2, 1 })
    end)
  end)

  test.it("keeps a removed-text selection when its Context Menu opens", function(context)
    local view = comparison(context, "unified")
    local surface = view:get_focus_view()
    core.active_view = surface
    surface:select_unified({ other = true, line = 1, col = 1 }, { other = true, line = 1, col = 3 })
    local x, y = surface:get_source_screen_position(1, 1, 2)
    test.ok(command.perform("core:show_context_menu", x + 1, y + 1))
    test.ok(menu.choose("Copy Selection Patch"))
    test.contains(system.get_clipboard(), "-old\n+new\n")
    test.ok(not system.get_clipboard():find("+changed", 1, true))
    test.equal(surface:get_copy_text(), "ol")
  end)

  test.it("runs diff options through their existing commands", function(context)
    local view = comparison(context, "unified")
    core.active_view = view:get_focus_view()
    test.ok(command.perform("core:show_context_menu"))
    test.ok(not contains(menu.labels(), "Open File at Caret"))
    test.ok(menu.choose("Diff Options"))
    test.ok(menu.choose("Swap Sides"))
    test.ok(command.perform("core:show_context_menu"))
    test.ok(menu.choose("Copy File Patch"))
    test.contains(system.get_clipboard(), "-new\n+old\n")
  end)

  test.it("copies the whole comparison from a right-clicked change", function(context)
    local view = comparison(context, "side-by-side")
    local surface = view.buffer_view_b
    core.active_view = surface
    local x, y = surface:get_line_screen_position(3, 2)
    test.ok(command.perform("core:show_context_menu", x + 1, y + 1))
    test.ok(menu.choose("Copy File Patch"))
    test.contains(system.get_clipboard(), "-old\n+new\n")
    test.contains(system.get_clipboard(), "-end\n+changed\n")
    surface:with_selection_state(function() test.equal(surface.buffer:get_selection(), 3) end)
  end)

  for _, filename in ipairs { "sample.lua", "note.md" } do
    test.it("offers selection comparisons in " .. filename .. " without replacing its text actions", function(context)
      local buffer = Buffer()
      context.buffer = buffer
      buffer:set_filename(filename, filename)
      buffer:insert(1, 1, "alpha beta")
      local editor = Editor(buffer)
      core.active_view = editor
      test.ok(command.perform("core:show_context_menu"))
      test.ok(not contains(menu.labels(), "Compare Selection with Clipboard"))
      menu.close()
      editor:with_selection_state(function() buffer:set_selection(1, 1, 1, 6) end)
      test.ok(command.perform("core:show_context_menu"))
      test.ok(contains(menu.labels(), "Compare Selection with Clipboard"))
      test.ok(contains(menu.labels(), filename == "note.md" and "Bold" or "Copy"))
      test.ok(menu.choose("Select Text for Comparison"))
      editor:with_selection_state(function() test.equal(buffer:get_selection_text(), "alpha") end)
    end)
  end
end)
