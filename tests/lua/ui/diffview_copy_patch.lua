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
    test.equal(command.perform("diff:copy_diff_patch_for_file"), true)
    test.equal(system.get_clipboard(),
      "--- a/Before\n+++ b/After\n@@ -1,2 +1,2 @@\n same\n-old\n+  old\n")
  end)

  test.it("keeps the clipboard when there are no changes", function(context)
    context.view = diffview.string_to_string("same", "same", "Before", "After", true)
    core.active_view = context.view
    system.set_clipboard("keep me")
    test.equal(command.perform("diff:copy_diff_patch_for_file"), true)
    test.equal(system.get_clipboard(), "keep me")
  end)

  test.it("copies an addition against an empty source", function(context)
    context.view = diffview.string_to_string("", "new", "Before", "After", true)
    core.active_view = context.view
    test.equal(command.perform("diff:copy_diff_patch_for_file"), true)
    test.equal(system.get_clipboard(),
      "--- a/Before\n+++ b/After\n@@ -0,0 +1,1 @@\n+new\n")
    test.equal(command.perform("diff:swap_sides"), true)
    test.equal(command.perform("diff:copy_diff_patch_for_file"), true)
    test.equal(system.get_clipboard(),
      "--- a/After\n+++ b/Before\n@@ -1,1 +0,0 @@\n-new\n")
  end)
end)

test.describe("Copy scoped diff patches", function()
  test.before_each(function(context)
    context.active = core.active_view
    context.clipboard = system.get_clipboard()
  end)
  test.after_each(function(context)
    core.active_view = context.active
    system.set_clipboard(context.clipboard or "")
    if context.view then context.view:on_close() end
    if context.buffer then context.buffer:on_close() end
    if context.root then require("core.common").rm(context.root, true) end
  end)

  local function comparison(context, side, line1, col1, line2, col2)
    context.view = diffview.string_to_string("old\nkeep\nend", "new\nkeep\nchanged", "file.txt", "file.txt", true)
    local view = side == "left" and context.view.buffer_view_a or context.view.buffer_view_b
    core.active_view = view
    view:with_selection_state(function()
      view.buffer:set_selection(line1, col1, line2, col2)
    end)
    return view
  end

  for _, side in ipairs({ "left", "right" }) do
    test.it("copies only the cursor block from the " .. side .. " side", function(context)
      comparison(context, side, 1, 1)
      test.ok(command.perform("diff:copy_diff_patch_under_cursor"))
      test.equal(system.get_clipboard(),
        "--- a/file.txt\n+++ b/file.txt\n@@ -1,3 +1,3 @@\n-old\n+new\n keep\n end\n")
    end)
  end

  test.it("copies complete blocks that intersect selected lines", function(context)
    comparison(context, "right", 1, 2, 3, 1)
    test.ok(command.perform("diff:copy_diff_patch_for_selection"))
    test.equal(system.get_clipboard(),
      "--- a/file.txt\n+++ b/file.txt\n@@ -1,3 +1,3 @@\n-old\n+new\n keep\n end\n")
  end)

  test.it("keeps the clipboard outside a block or without a selection", function(context)
    comparison(context, "right", 2, 1)
    system.set_clipboard("keep")
    command.perform("diff:copy_diff_patch_under_cursor")
    test.equal(system.get_clipboard(), "keep")
    command.perform("diff:copy_diff_patch_for_selection")
    test.equal(system.get_clipboard(), "keep")
  end)

  test.it("copies unsaved Editor changes against its Git baseline", function(context)
    local Buffer = require "core.buffer"
    local Editor = require "core.editor"
    local gitdiff = require "plugins.gitdiff_highlight"
    local buffer = Buffer()
    context.buffer = buffer
    buffer:insert(1, 1, "new\nkeep\nchanged")
    local editor = Editor(buffer)
    core.active_view = editor
    gitdiff._set_state_for_tests(buffer, {
      is_in_repo = true, base_lines = { "old\n", "keep\n", "end\n" },
      rel_path = "file.txt", ranges = {}, line_index = {},
    })
    editor:with_selection_state(function() buffer:set_selection(1, 1) end)
    test.ok(command.perform("diff:copy_diff_patch_under_cursor"))
    test.equal(system.get_clipboard(),
      "--- a/file.txt\n+++ b/file.txt\n@@ -1,3 +1,3 @@\n-old\n+new\n keep\n end\n")
    test.ok(command.perform("diff:copy_diff_patch_for_file"))
    test.equal(system.get_clipboard(),
      "--- a/file.txt\n+++ b/file.txt\n@@ -1,3 +1,3 @@\n-old\n+new\n keep\n-end\n+changed\n")
    test.equal(buffer:get_text(1, 1, 3, 8), "new\nkeep\nchanged")
  end)

  test.it("copies a whole replacement when only part of it is selected", function(context)
    context.view = diffview.string_to_string("old one\nold two\nkeep", "new one\nnew two\nkeep", "file.txt", "file.txt", true)
    local view = context.view.buffer_view_b
    core.active_view = view
    view:with_selection_state(function() view.buffer:set_selection(2, 2, 2, 4) end)
    test.ok(command.perform("diff:copy_diff_patch_for_selection"))
    local patch = system.get_clipboard()
    test.contains(patch, "-old one\n")
    test.contains(patch, "-old two\n")
    test.contains(patch, "+new one\n")
    test.contains(patch, "+new two\n")
  end)

  test.it("copies a deletion at its right-side end marker", function(context)
    context.view = diffview.string_to_string("keep\ndeleted", "keep", "file.txt", "file.txt", true)
    local view = context.view.buffer_view_b
    core.active_view = view
    view:with_selection_state(function() view.buffer:set_selection(1, 1) end)
    test.ok(command.perform("diff:copy_diff_patch_under_cursor"))
    test.equal(system.get_clipboard(),
      "--- a/file.txt\n+++ b/file.txt\n@@ -1,2 +1,1 @@\n keep\n-deleted\n")
  end)

  test.it("creates a Git-applicable patch without earlier unselected additions", function(context)
    local common = require "core.common"
    local process = require "core.process"
    local before = "start\none\ntwo\nthree\nfour\nfive\nsix\nend"
    local after = "added\nstart\none\ntwo\nthree\nfour\nfive\nsix\nchanged\nextra"
    context.view = diffview.string_to_string(before, after, "file.txt", "file.txt", true)
    local view = context.view.buffer_view_b
    core.active_view = view
    view:with_selection_state(function() view.buffer:set_selection(9, 1) end)
    test.ok(command.perform("diff:copy_diff_patch_under_cursor"))
    context.root = USERDIR .. PATHSEP .. "copy-patch-" .. system.get_process_id()
    test.ok(common.mkdirp(context.root))
    local function write(name, text)
      local file = assert(io.open(context.root .. PATHSEP .. name, "wb"))
      assert(file:write(text))
      file:close()
    end
    write("file.txt", before .. "\n")
    write("change.patch", system.get_clipboard())
    local proc = assert(process.start({
      "git", "-c", "core.autocrlf=false", "apply", "change.patch",
    }, {
      cwd = context.root, stdin = process.REDIRECT_DISCARD,
      stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_PIPE,
    }))
    test.equal(proc:wait(process.WAIT_INFINITE, 0.01), 0, proc:read_stderr() or "Git apply failed")
    local file = assert(io.open(context.root .. PATHSEP .. "file.txt", "rb"))
    local applied = file:read("*a")
    file:close()
    test.equal(applied, "start\none\ntwo\nthree\nfour\nfive\nsix\nchanged\nextra\n")
  end)
end)
