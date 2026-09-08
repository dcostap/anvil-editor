local core = require "core"
local command = require "core.command"
local test = require "core.test"
local diffview = require "plugins.diffview"

test.describe("Copy Diff View patch", function()
  test.before_each(function(context)
    context.active_view = core.active_view
    context.clipboard = system.get_clipboard()
  end)
  test.after_each(function(context)
    core.active_view = context.active_view
    system.set_clipboard(context.clipboard or "")
    if context.view then context.view:on_close() end
  end)

  test.it("copies current Buffer edits from a Diff Side", function(context)
    local view = diffview.string_to_string("same\nold", "same\nold", "Before", "After", true)
    context.view = view
    view.buffer_view_b.buffer:insert(2, 1, "  ")
    core.active_view = view.buffer_view_b
    test.equal(command.perform("diff:copy_patch"), true)
    test.equal(system.get_clipboard(),
      "--- a/Before\n+++ b/After\n@@ -1,2 +1,2 @@\n same\n-old\n+  old\n")
  end)

  test.it("keeps the clipboard when there are no changes", function(context)
    context.view = diffview.string_to_string("same", "same", "Before", "After", true)
    core.active_view = context.view
    system.set_clipboard("keep me")
    test.equal(command.perform("diff:copy_patch"), true)
    test.equal(system.get_clipboard(), "keep me")
  end)

  test.it("copies an addition against an empty source", function(context)
    context.view = diffview.string_to_string("", "new", "Before", "After", true)
    core.active_view = context.view
    test.equal(command.perform("diff:copy_patch"), true)
    test.equal(system.get_clipboard(),
      "--- a/Before\n+++ b/After\n@@ -0,0 +1,1 @@\n+new\n")
    test.equal(command.perform("diff:swap_sides"), true)
    test.equal(command.perform("diff:copy_patch"), true)
    test.equal(system.get_clipboard(),
      "--- a/After\n+++ b/Before\n@@ -1,1 +0,0 @@\n-new\n")
  end)
end)
