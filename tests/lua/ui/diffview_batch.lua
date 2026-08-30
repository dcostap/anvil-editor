local core = require "core"
local command = require "core.command"
local config = require "core.config"
local file_context = require "core.file_context"
local test = require "core.test"
local diffview = require "plugins.diffview"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local Editor = require "core.editor"
local panes = require "core.panes"

local function track(context, kind, value)
  context[kind] = context[kind] or {}
  table.insert(context[kind], value)
  return value
end

local function wait_until(predicate, timeout, message)
  local deadline = system.get_time() + (timeout or 1)
  while not predicate() do
    if system.get_time() >= deadline then
      test.fail(message or "timed out waiting for condition", 2)
    end
    coroutine.yield(0.01)
  end
end

local function text(buffer)
  return table.concat(buffer.lines)
end

local function write_file(path, content)
  local file, err = io.open(path, "wb")
  test.ok(file, err)
  file:write(content or "")
  file:close()
end

local function file_exists(path)
  local file = io.open(path, "rb")
  if file then file:close(); return true end
  return false
end

local function read_file(path)
  local file, err = io.open(path, "rb")
  test.ok(file, err)
  local content = file:read("*a")
  file:close()
  return content
end

test.describe("DiffView batch behavior", function()
  test.before_each(function(context)
    context.original_active_view = core.active_view
    panes.reset_for_tests()
  end)

  test.after_each(function(context)
    core.active_view = context.original_active_view
    if context.restore_diff_folding_config then context.restore_diff_folding_config() end
    if context.cleanup_readonly_file then pcall(os.remove, context.cleanup_readonly_file) end
    if context.cleanup_replace_file then pcall(os.remove, context.cleanup_replace_file) end
    if context.cleanup_cancel_replace_file then pcall(os.remove, context.cleanup_cancel_replace_file) end
    if context.cleanup_dirty_file_close then pcall(os.remove, context.cleanup_dirty_file_close) end
    if context.cleanup_adopt_left then pcall(os.remove, context.cleanup_adopt_left) end
    if context.cleanup_adopt_right then pcall(os.remove, context.cleanup_adopt_right) end
    if context.cleanup_shared_file then pcall(os.remove, context.cleanup_shared_file) end
    for _, view in ipairs(context.diffviews or {}) do
      local pane = panes.pane_for_view(view)
      if pane then panes.close_view(pane, { view = view, force = true }) end
      view.buffer_view_a.buffer:on_close()
      view.buffer_view_b.buffer:on_close()
    end
    panes.reset_for_tests()
  end)

  test.it("normalizes left/right request sugar and opens a side-by-side view", function(context)
    local view, err = diffview.open({
      title = "Sugar Diff",
      contents = {
        left = diffview.content.text("left", { name = "Left" }),
        right = diffview.content.text("right", { name = "Right" }),
      },
      content_titles = { left = "Old", right = "New" },
    }, true)
    test.ok(view, err)
    track(context, "diffviews", view)
    test.equal("Sugar Diff", view:get_name())
    test.equal("left\n", text(view.buffer_view_a.buffer))
    test.equal("right\n", text(view.buffer_view_b.buffer))
    test.equal("Old", view.request.content_titles[1])
    test.equal("New", view.request.content_titles[2])
  end)

  test.it("reuses the canonical Buffer for a file-backed Diff Side", function(context)
    local path = core.project_absolute_path("tmp-diff-shared-buffer.txt")
    pcall(os.remove, path)
    write_file(path, "original\n")
    context.cleanup_shared_file = path
    local canonical = core.open_buffer(path)
    local editor = TextView(canonical)
    local view = track(context, "diffviews", diffview.open({
      contents = {
        diffview.content.file(path),
        diffview.content.text("comparison", { editable = false }),
      },
      editable_policy = "content",
    }, true))

    test.equal(view.buffer_view_a.buffer, canonical)
    view.buffer_view_a:on_text_input("diff ")
    test.equal(text(editor.buffer), "diff original\n")
    editor.buffer:apply_edits({ {
      line1 = 1, col1 = 1, line2 = 1, col2 = 6, text = "editor ",
    } }, { type = "test" })
    test.equal(text(view.buffer_view_a.buffer), "editor original\n")
  end)

  test.it("keeps a selected fragment connected to its source Buffer", function(context)
    local source = Buffer(nil, nil, true)
    source:insert(1, 1, "one target three")
    source:clean()
    local view = track(context, "diffviews", diffview.open({
      contents = {
        diffview.content.text("comparison", { editable = false }),
        diffview.content.fragment(source, 1, 5, 1, 11, { name = "Selection" }),
      },
      editable_policy = "content",
    }, true))

    view.buffer_view_b:with_selection_state(function()
      view.buffer_view_b.buffer:set_selection(1, 1, 1, 7)
    end)
    view.buffer_view_b:on_text_input("new")
    test.equal(text(source), "one new three\n")

    source:apply_edits({ {
      line1 = 1, col1 = 5, line2 = 1, col2 = 8, text = "fresh",
    } }, { type = "test" })
    test.equal(text(view.buffer_view_b.buffer), "fresh\n")
  end)

  test.it("keeps a selected fragment mapped after source text is inserted before it", function(context)
    local source = Buffer("source.lua", core.project_absolute_path("source.lua"), true)
    source:insert(1, 1, "before\nselected\nafter")
    local view = track(context, "diffviews", diffview.open({
      contents = {
        diffview.content.text("old"),
        diffview.content.fragment(source, 2, 1, 2, 9),
      },
    }, true))

    source:insert(1, 1, "new first line\n")
    test.equal(text(view.buffer_view_b.buffer), "selected\n")
    test.equal(view.buffer_view_b:get_path_target().line, 3)
    view.buffer_view_b.buffer:remove(1, 1, 1, 9)
    view.buffer_view_b.buffer:insert(1, 1, "updated")
    test.equal(source:get_utf8_line(3), "updated\n")
    view:dispose_integrations()
    view:dispose_owned_buffers()
    source:on_close()
  end)

  test.it("swaps Diff Sides while keeping focus with its source", function(context)
    local left = Buffer(nil, nil, true)
    local right = Buffer(nil, nil, true)
    left:insert(1, 1, "left")
    right:insert(1, 1, "right")
    local view = track(context, "diffviews", diffview.open({
      contents = {
        diffview.content.buffer(left),
        diffview.content.buffer(right),
      },
    }, true))
    core.active_view = view.buffer_view_b

    test.ok(command.perform("diff:swap_sides"))
    test.equal(view.buffer_view_a.buffer, right)
    test.equal(view.buffer_view_b.buffer, left)
    test.equal(core.active_view.buffer, right)
  end)

  test.it("keeps controller side order after a swap and reload", function(context)
    local chain = diffview.MutableDiffRequestChain({
      title = "Swap",
      contents = {
        diffview.content.text("left", { name = "Left" }),
        diffview.content.text("right", { name = "Right" }),
      },
      content_titles = { "Left", "Right" },
    })
    local controller = diffview.DiffRequestController(chain, { noshow = true })
    local view = track(context, "diffviews", controller:get_view())
    view.buffer_view_a.diff_view_parent = view
    core.active_view = view.buffer_view_a

    test.ok(command.perform("diff:swap_sides"))
    local swapped = controller:get_view()
    test.equal(text(swapped.buffer_view_a.buffer), "right\n")
    local reloaded = controller:reload({ noshow = true })
    test.equal(text(reloaded.buffer_view_a.buffer), "right\n")
    controller:dispose()
  end)

  test.it("opens the current Diff source at its mapped line", function(context)
    local path = core.project_absolute_path("tmp-diff-open-source.txt")
    pcall(os.remove, path)
    write_file(path, "one\ntwo\nthree\n")
    context.cleanup_shared_file = path
    local view = track(context, "diffviews", diffview.open({
      contents = {
        diffview.content.file(path),
        diffview.content.text("other", { editable = false }),
      },
    }, true))
    panes.place(function() return view end, { placement = "current", focus = true })
    view.buffer_view_a:with_selection_state(function()
      view.buffer_view_a.buffer:set_selection(2, 1)
    end)
    core.set_active_view(view.buffer_view_a)

    test.ok(command.perform("diff:open_file_at_caret"))
    local editor = panes.active().current_view
    test.ok(editor:is(Editor))
    test.equal(editor.buffer, core.open_buffer(path))
    local line = editor:with_selection_state(function() return editor.buffer:get_selection() end)
    test.equal(line, 2)
  end)

  test.it("compares clipboard text with an editable mapped selection", function(context)
    local source = Buffer("source.lua", "C:/virtual/source.lua", true)
    source:insert(1, 1, "before selected after")
    local editor = TextView(source)
    editor:with_selection_state(function()
      source:set_selection(1, 8, 1, 16)
    end)
    core.active_view = editor
    local old_clipboard = system.get_clipboard()
    system.set_clipboard("clipboard text")

    test.ok(command.perform("diff:compare_selection_with_clipboard"))
    system.set_clipboard(old_clipboard or "")
    local view = core.active_view.diff_view_parent
    track(context, "diffviews", view)
    test.equal(text(view.buffer_view_a.buffer), "clipboard text\n")
    test.equal(text(view.buffer_view_b.buffer), "selected\n")
    view.buffer_view_b:with_selection_state(function()
      view.buffer_view_b.buffer:set_selection(1, 1, 1, 9)
    end)
    view.buffer_view_b:on_text_input("changed")
    test.equal(text(source), "before changed after\n")
  end)

  test.it("gives generated Diff Sides their source Path Targets", function(context)
    local left_path = system.absolute_path("old-name.lua")
    local right_path = system.absolute_path("new-name.lua")
    local view = track(context, "diffviews", diffview.open({
      title = "Generated Diff",
      contents = {
        diffview.content.text("old one\nold two", { source_path = left_path }),
        diffview.content.text("new one\nnew two", { source_path = right_path }),
      },
      editable_policy = "read-only",
    }, true))

    view.buffer_view_b:with_selection_state(function() view.buffer_view_b.buffer:set_selection(2, 1) end)
    local left = test.not_nil(file_context.view_path_target(view.buffer_view_a))
    local right = test.not_nil(file_context.view_path_target(view.buffer_view_b))
    local outer = test.not_nil(file_context.view_path_target(view))
    test.equal(left.path, left_path)
    test.equal(left.line, 2)
    test.equal(right.path, right_path)
    test.equal(right.line, 2)
    test.equal(outer.path, left_path)
  end)

  test.it("shows a non-text state instead of diffing binary content", function(context)
    local view = track(context, "diffviews", diffview.open({
      contents = {
        diffview.content.text("text\0binary"),
        diffview.content.text("other"),
      },
    }, true))
    test.equal(view.comparison_message, "Binary content cannot use the text Diff View")
    test.equal(view.diff_model, nil)
  end)

  test.it("clears an in-flight updater when edited content becomes binary", function(context)
    local view = track(context, "diffviews", diffview.open({
      contents = {
        diffview.content.text(string.rep("left line\n", 200)),
        diffview.content.text(string.rep("right line\n", 200)),
      },
    }, true))
    test.not_nil(view.updater_idx)

    view.buffer_view_b.buffer:insert(1, 1, "\0")

    test.equal(view.comparison_message, "Binary content cannot use the text Diff View")
    test.equal(view.updater_idx, nil)
  end)

  test.it("reveals the first change when a Diff View opens", function(context)
    local prefix = {}
    for i = 1, 40 do prefix[i] = "unchanged " .. i end
    local left = table.concat(prefix, "\n") .. "\nold value\n"
    local right = table.concat(prefix, "\n") .. "\nnew value\n"
    local view = track(context, "diffviews", diffview.open({
      contents = { diffview.content.text(left), diffview.content.text(right) },
    }, true))
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 800, 200
    wait_until(function() return view.updater_idx == nil end, 1, "expected diff computation to finish")
    view:update()

    local line = view.buffer_view_b.buffer:get_selection()
    test.equal(line, 41)
    test.ok(view.buffer_view_b.scroll.to.y > 0)
  end)

  test.it("rejects invalid diff requests deterministically", function()
    local view, err = diffview.open({ contents = { diffview.content.text("a") } }, true)
    test.equal(nil, view)
    test.ok(err and err:find("exactly two contents", 1, true))

    view, err = diffview.open({ contents = {
      diffview.content.text("a"),
      { kind = "mystery" },
    } }, true)
    test.equal(nil, view)
    test.ok(err and err:find("unknown diff content kind", 1, true))

    view, err = diffview.open({
      contents = { diffview.content.text("a"), diffview.content.text("b") },
      content_titles = "bad",
    }, true)
    test.equal(nil, view)
    test.ok(err and err:find("content_titles must be a table", 1, true))

    view, err = diffview.open({
      contents = { diffview.content.text("a"), diffview.content.text("b") },
      content_titles = { 42, "right" },
    }, true)
    test.equal(nil, view)
    test.ok(err and err:find("content title 1 must be a string", 1, true))

    view, err = diffview.open({
      contents = { diffview.content.text("a"), diffview.content.text("b") },
      editable_policy = "readonly",
    }, true)
    test.equal(nil, view)
    test.ok(err and err:find("editable_policy", 1, true))

    view, err = diffview.open({ contents = {
      diffview.content.text("a", { editable = "no" }),
      diffview.content.text("b"),
    } }, true)
    test.equal(nil, view)
    test.ok(err and err:find("editable must be a boolean", 1, true))

    view, err = diffview.open({ contents = {
      { kind = "buffer", buffer = {} },
      diffview.content.blank(),
    } }, true)
    test.equal(nil, view)
    test.ok(err and err:find("requires a Buffer", 1, true))

    view, err = diffview.open({ contents = {
      diffview.content.file("same/path.txt"),
      diffview.content.file("same/./path.txt"),
    } }, true)
    test.equal(nil, view)
    test.ok(err and err:find("same file", 1, true))

    local file_buffer = Buffer("path.txt", "same/path.txt", true)
    view, err = diffview.open({ contents = {
      diffview.content.buffer(file_buffer),
      diffview.content.file("same/./path.txt"),
    } }, true)
    test.equal(nil, view)
    test.ok(err and err:find("same file", 1, true))

    local abs_buffer = Buffer("path.txt", core.project_absolute_path("same/path.txt"), true)
    view, err = diffview.open({ contents = {
      diffview.content.buffer(abs_buffer),
      diffview.content.file("same/path.txt"),
    } }, true)
    test.equal(nil, view)
    test.ok(err and err:find("same file", 1, true))
  end)

  test.it("uses side title precedence and closes only owned transient buffers", function(context)
    local left_closed, right_closed = 0, 0
    local left_buffer = Buffer("caller", "caller", true)
    local old_left_close = left_buffer.on_close
    left_buffer.on_close = function(buffer, ...)
      left_closed = left_closed + 1
      return old_left_close(buffer, ...)
    end

    local right = diffview.content.text("owned text", { name = "Content Name" })
    local view, err = diffview.open({
      contents = {
        diffview.content.buffer(left_buffer, { name = "Buffer Content Name" }),
        right,
      },
      content_titles = { nil, "Title Override" },
    }, true)
    test.ok(view, err)
    track(context, "diffviews", view)

    local old_right_close = view.buffer_view_b.buffer.on_close
    view.buffer_view_b.buffer.on_close = function(buffer, ...)
      right_closed = right_closed + 1
      return old_right_close(buffer, ...)
    end

    test.equal("caller", view.buffer_view_a.buffer:get_name())
    test.equal("Title Override", view.buffer_view_b.buffer:get_name())

    local closed = false
    view:try_close(function() closed = true end)
    test.ok(closed)
    test.equal(0, left_closed)
    test.equal(1, right_closed)
  end)

  test.it("blank diff controller opens editable Buffers and replaces a side in place", function(context)
    test.ok(command.perform("diff:open"))
    local view = core.active_view.diff_view_parent
    local controller = view and view.request_controller
    test.ok(controller and controller.get_view, "expected blank diff controller")
    view = controller:get_view()
    local pane = panes.pane_for_view(view)
    track(context, "diffviews", view)
    test.equal(panes.active(), panes.pane_for_view(view))
    test.equal(view.buffer_view_a, core.active_view)

    view.buffer_view_b:on_text_input("right")
    wait_until(function() return view.updater_idx == nil end, 1, "expected edited diff computation to finish")

    local path = core.project_absolute_path("tmp-diff-replace-left.txt")
    pcall(os.remove, path)
    write_file(path, "file left\n")
    context.cleanup_replace_file = path

    local new_view, err = controller:replace_content("left", diffview.content.file(path), { title = "File Left" })
    test.ok(new_view, err)
    track(context, "diffviews", new_view)
    test.equal(pane, panes.pane_for_view(new_view))
    test.equal("file left\n", text(new_view.buffer_view_a.buffer))
    test.equal("right\n", text(new_view.buffer_view_b.buffer))
  end)

  test.it("adopted sides preserve dirty-confirmation and editability metadata", function(context)
    local left_path = core.project_absolute_path("tmp-diff-adopt-left.txt")
    local right_path = core.project_absolute_path("tmp-diff-adopt-right.txt")
    pcall(os.remove, left_path)
    pcall(os.remove, right_path)
    write_file(left_path, "left file\n")
    write_file(right_path, "right file\n")
    context.cleanup_adopt_left = left_path
    context.cleanup_adopt_right = right_path

    local controller = diffview.DiffRequestController(diffview.MutableDiffRequestChain({
      contents = { diffview.content.file(left_path), diffview.content.blank({ name = "Right" }) },
      editable_policy = "editable",
    }), { noshow = true })
    local view = controller:get_view()
    track(context, "diffviews", view)
    local new_view, err = controller:replace_content("right", diffview.content.file(right_path))
    test.ok(new_view, err)
    track(context, "diffviews", new_view)
    new_view.buffer_view_a:on_text_input("dirty ")

    local old_nag_view = core.nag_view
    local nag_callback
    core.nag_view = {
      show = function(_, title, message, buttons, callback)
        nag_callback = callback
      end,
    }
    local closed = false
    new_view:try_close(function() closed = true end)
    core.nag_view = old_nag_view
    test.ok(nag_callback, "expected adopted file side to require dirty confirmation")
    nag_callback({ text = "Cancel" })
    test.equal(false, closed)

    local ro_controller = diffview.DiffRequestController(diffview.MutableDiffRequestChain({
      contents = {
        diffview.content.text("read only", { editable = false, read_only_reason = "kept readonly" }),
        diffview.content.blank({ name = "Right" }),
      },
      editable_policy = "content",
    }), { noshow = true })
    local ro_view = ro_controller:get_view()
    track(context, "diffviews", ro_view)
    ro_view, err = ro_controller:replace_content("right", diffview.content.blank({ name = "New Right" }))
    test.ok(ro_view, err)
    track(context, "diffviews", ro_view)
    ro_view.buffer_view_a:on_text_input("X")
    test.equal("read only\n", text(ro_view.buffer_view_a.buffer))
  end)

  test.it("controller reload balances reused content assignment hooks", function(context)
    local left_events, right_events = {}, {}
    local left = diffview.content.blank({ name = "Left" })
    local right = diffview.content.blank({ name = "Right" })
    left.on_assigned = function(_, assigned)
      left_events[#left_events + 1] = assigned and "left on" or "left off"
    end
    right.on_assigned = function(_, assigned)
      right_events[#right_events + 1] = assigned and "right on" or "right off"
    end
    local controller = diffview.DiffRequestController(diffview.MutableDiffRequestChain({
      contents = { left, right },
      editable_policy = "editable",
    }), { noshow = true })
    local view = controller:get_view()
    track(context, "diffviews", view)
    test.same({ "left on" }, left_events)
    test.same({ "right on" }, right_events)

    local new_view, err = controller:reload({ noshow = true })
    test.ok(new_view, err)
    track(context, "diffviews", new_view)
    test.same({ "left on", "left off", "left on" }, left_events)
    test.same({ "right on", "right off", "right on" }, right_events)
  end)

  test.it("dirty editable file-backed diff sides prompt on close", function(context)
    local path = core.project_absolute_path("tmp-diff-dirty-file-close.txt")
    pcall(os.remove, path)
    write_file(path, "file left\n")
    context.cleanup_dirty_file_close = path

    local view, err = diffview.open({
      contents = { diffview.content.file(path), diffview.content.blank({ name = "Right" }) },
      editable_policy = "editable",
    }, true)
    test.ok(view, err)
    track(context, "diffviews", view)
    view.buffer_view_a:on_text_input("dirty ")

    local old_nag_view = core.nag_view
    local nag_callback
    core.nag_view = {
      show = function(_, title, message, buttons, callback)
        nag_callback = callback
      end,
    }
    local closed = false
    view:try_close(function() closed = true end)
    core.nag_view = old_nag_view
    test.ok(nag_callback, "expected dirty file close confirmation")
    test.equal(false, closed)
    nag_callback({ text = "Cancel" })
    test.equal(false, closed)
  end)

  test.it("blank diff side replacement can be cancelled for dirty owned Buffers", function(context)
    local controller = diffview.DiffRequestController(diffview.MutableDiffRequestChain({
      title = "Blank Diff View",
      kind = "blank",
      contents = { diffview.content.blank({ name = "Left" }), diffview.content.blank({ name = "Right" }) },
      editable_policy = "editable",
    }), { noshow = true })
    local view = controller:get_view()
    track(context, "diffviews", view)
    view.buffer_view_a:on_text_input("dirty")

    local path = core.project_absolute_path("tmp-diff-cancel-replace.txt")
    pcall(os.remove, path)
    write_file(path, "file left\n")
    context.cleanup_cancel_replace_file = path

    local old_nag_view = core.nag_view
    local nag_callback
    core.nag_view = {
      show = function(_, title, message, buttons, callback)
        nag_callback = callback
      end,
    }
    local replaced, err = controller:replace_content("left", diffview.content.file(path))
    core.nag_view = old_nag_view
    test.equal(nil, replaced)
    test.equal("pending-confirmation", err)
    test.equal(view, controller:get_view())
    test.ok(nag_callback, "expected dirty replacement confirmation")
    nag_callback({ text = "Cancel" })
    test.equal(view, controller:get_view())
    test.equal("dirty\n", text(view.buffer_view_a.buffer))
  end)

  test.it("read-only diff guards block view-routed edits without locking caller Buffers", function(context)
    local buffer = Buffer("caller", "caller", true)
    buffer:insert(1, 1, "left")
    buffer:clear_undo_redo()
    local view, err = diffview.open({
      contents = {
        diffview.content.buffer(buffer, { read_only_reason = "snapshot" }),
        diffview.content.blank(),
      },
      editable_policy = "read-only",
    }, true)
    test.ok(view, err)
    track(context, "diffviews", view)

    view.buffer_view_a:on_text_input("X")
    test.equal("left\n", text(buffer))

    core.active_view = view.buffer_view_a
    view.buffer_view_a.buffer:set_selection(1, 1, 1, 2)
    command.perform("core:delete")
    test.equal("left\n", text(buffer))
    command.perform("editor:delete_lines")
    test.equal("left\n", text(buffer))
    command.perform("editor:upper_case")
    test.equal("left\n", text(buffer))
    command.perform("editor:quote")
    test.equal("left\n", text(buffer))
    view.buffer_view_a:on_ime_text_editing("Z", 0, 1)
    test.equal("left\n", text(buffer))

    local normal = TextView(buffer)
    normal:on_text_input("Y")
    test.equal(text(buffer), "Yeft\n")
  end)

  test.it("read-only file diff guards block destructive file commands", function(context)
    local path = core.project_absolute_path("tmp-diff-readonly-delete.txt")
    pcall(os.remove, path)
    write_file(path, "left\n")
    context.cleanup_readonly_file = path

    local view, err = diffview.open({
      contents = {
        diffview.content.file(path, { read_only_reason = "snapshot file" }),
        diffview.content.text("right"),
      },
      editable_policy = "read-only",
    }, true)
    test.ok(view, err)
    track(context, "diffviews", view)
    core.active_view = view.buffer_view_a

    local old_crlf = view.buffer_view_a.buffer.crlf
    command.perform("editor:toggle_line_ending")
    test.equal(view.buffer_view_a.buffer.crlf, old_crlf)
    view.buffer_view_a.buffer:insert(1, 1, "dirty ")
    command.perform("editor:save")
    test.equal(read_file(path), "left\n")
    command.perform("editor:delete")
    test.ok(file_exists(path), "read-only file delete should be blocked")
  end)

  test.it("does not expose hunk application as a Diff View action", function()
    test.equal(nil, command.map["diff:sync_change"])
  end)

  test.it("rejects same buffer requests and balances assignment hooks", function(context)
    local buffer = Buffer("shared", "shared", true)
    local events = {}
    local request = {
      contents = {
        diffview.content.buffer(buffer),
        diffview.content.buffer(buffer),
      },
      on_assigned = function(_, assigned)
        events[#events + 1] = assigned and "request assigned" or "request unassigned"
      end,
    }
    local view, err = diffview.open(request, true)
    test.equal(nil, view)
    test.ok(err and err:find("same buffer", 1, true))
    test.equal(0, #events)

    local left_events, right_events = {}, {}
    local left = diffview.content.blank({ name = "Blank Left" })
    local right = diffview.content.empty({ name = "Blank Right" })
    left.on_assigned = function(_, assigned, _, side)
      left_events[#left_events + 1] = { assigned, side }
    end
    right.on_assigned = function(_, assigned, _, side)
      right_events[#right_events + 1] = { assigned, side }
    end
    view, err = diffview.open({ contents = { left, right } }, true)
    test.ok(view, err)
    track(context, "diffviews", view)
    test.same({ { true, "left" } }, left_events)
    test.same({ { true, "right" } }, right_events)
    view:dispose_integrations()
    test.same({ { true, "left" }, { false, "left" } }, left_events)
    test.same({ { true, "right" }, { false, "right" } }, right_events)
  end)

  test.it("uses Text Diff View wording for arbitrary text comparisons", function(context)
    local view = track(context, "diffviews", diffview.string_to_string(
      "left",
      "right",
      "left",
      "right",
      true
    ))
    test.equal(view:get_name(), "Text Diff View")
  end)

  test.it("shows long unchanged regions expanded by default", function(context)
    test.equal(config.plugins.diffview.fold_unchanged_by_default, false)

    local left, right = {}, {}
    for i = 1, 14 do left[i], right[i] = "same " .. i, "same " .. i end
    left[7], right[7] = "old", "new"
    local view = track(context, "diffviews", diffview.string_to_string(
      table.concat(left, "\n"),
      table.concat(right, "\n"),
      "left",
      "right",
      true
    ))
    wait_until(function() return view.updater_idx == nil end, 1, "expected diff computation to finish")

    test.equal(view.folding_enabled, false)
    test.equal(#view.diff_folds_a, 0)
    test.equal(#view.diff_folds_b, 0)
  end)

  test.it("folds long unchanged regions and toggles them from diff TextViews", function(context)
    local old_context = config.plugins.diffview.fold_context_lines
    local old_min = config.plugins.diffview.fold_min_lines
    local old_default = config.plugins.diffview.fold_unchanged_by_default
    config.plugins.diffview.fold_context_lines = 1
    config.plugins.diffview.fold_min_lines = 3
    config.plugins.diffview.fold_unchanged_by_default = true
    context.restore_diff_folding_config = function()
      config.plugins.diffview.fold_context_lines = old_context
      config.plugins.diffview.fold_min_lines = old_min
      config.plugins.diffview.fold_unchanged_by_default = old_default
    end

    local left, right = {}, {}
    for i = 1, 14 do left[i], right[i] = "same " .. i, "same " .. i end
    left[7], right[7] = "old", "new"
    local view = track(context, "diffviews", diffview.string_to_string(
      table.concat(left, "\n"),
      table.concat(right, "\n"),
      "left",
      "right",
      true
    ))
    wait_until(function() return view.updater_idx == nil end, 1, "expected diff computation to finish")

    test.ok(#view.diff_folds_a > 0)
    test.ok(#view.diff_folds_b > 0)
    test.ok(view.diff_folds_a[1].core_fold ~= nil, "expected diff folds to be backed by core TextView folds")
    test.equal(view.buffer_view_a:get_collapsed_fold_at_line(view.diff_folds_a[1].hidden_start), view.diff_folds_a[1].core_fold)
    local folded_size = view.buffer_view_a:get_scrollable_size()
    core.active_view = view.buffer_view_a
    test.equal(command.perform("diff:toggle_folding"), true)
    test.equal(#view.diff_folds_a, 0)
    test.ok(view.buffer_view_a:get_scrollable_size() > folded_size)
    core.active_view = view
    test.equal(command.perform("diff:toggle_folding"), true)
    test.ok(#view.diff_folds_a > 0)
  end)

  test.it("preserves expanded diff fold by content identity after insertion before it", function(context)
    local old_context = config.plugins.diffview.fold_context_lines
    local old_min = config.plugins.diffview.fold_min_lines
    local old_default = config.plugins.diffview.fold_unchanged_by_default
    config.plugins.diffview.fold_context_lines = 1
    config.plugins.diffview.fold_min_lines = 3
    config.plugins.diffview.fold_unchanged_by_default = true
    context.restore_diff_folding_config = function()
      config.plugins.diffview.fold_context_lines = old_context
      config.plugins.diffview.fold_min_lines = old_min
      config.plugins.diffview.fold_unchanged_by_default = old_default
    end

    local left, right = {}, {}
    for i = 1, 18 do left[i], right[i] = "same " .. i, "same " .. i end
    left[7], right[7] = "old", "new"
    local view = track(context, "diffviews", diffview.string_to_string(
      table.concat(left, "\n"),
      table.concat(right, "\n"),
      "left",
      "right",
      true
    ))
    wait_until(function() return view.updater_idx == nil end, 1, "expected diff computation to finish")

    local after_fold
    for _, fold in ipairs(view.diff_folds_a) do
      if fold.hidden_start > 7 then after_fold = fold; break end
    end
    test.not_nil(after_fold)
    view:expand_fold(after_fold)
    test.ok(view.request.user_data.diff_fold_state, "expected request-scoped fold state")
    for _, fold in ipairs(view.diff_folds_a) do
      test.ok(not (fold.hidden_start > 7), "expected after-change fold to be expanded")
    end

    local before_generation = view.diff_generation
    view.buffer_view_a.buffer:apply_edits({ { line1 = 8, col1 = 1, line2 = 8, col2 = 1, text = "inserted before fold\n" } }, { type = "insert" })
    view.buffer_view_b.buffer:apply_edits({ { line1 = 8, col1 = 1, line2 = 8, col2 = 1, text = "inserted before fold\n" } }, { type = "insert" })
    wait_until(function() return view.diff_generation > before_generation and view.updater_idx == nil end, 1, "expected rediff after insertion")

    for _, fold in ipairs(view.diff_folds_a) do
      test.ok(not (fold.hidden_start > 8), "expected expanded after-change fold to survive insertion before it")
    end
  end)

  test.it("allows expanding one ambiguous repeated diff fold without persisting it by identity", function(context)
    local old_context = config.plugins.diffview.fold_context_lines
    local old_min = config.plugins.diffview.fold_min_lines
    local old_default = config.plugins.diffview.fold_unchanged_by_default
    config.plugins.diffview.fold_context_lines = 0
    config.plugins.diffview.fold_min_lines = 3
    config.plugins.diffview.fold_unchanged_by_default = true
    context.restore_diff_folding_config = function()
      config.plugins.diffview.fold_context_lines = old_context
      config.plugins.diffview.fold_min_lines = old_min
      config.plugins.diffview.fold_unchanged_by_default = old_default
    end

    local repeated = { "repeat a", "repeat b", "repeat tail" }
    local left = { "old 1" }
    local right = { "new 1" }
    for _, line in ipairs(repeated) do left[#left + 1], right[#right + 1] = line, line end
    left[#left + 1], right[#right + 1] = "old 2", "new 2"
    for _, line in ipairs(repeated) do left[#left + 1], right[#right + 1] = line, line end
    left[#left + 1], right[#right + 1] = "old 3", "new 3"

    local view = track(context, "diffviews", diffview.string_to_string(
      table.concat(left, "\n"),
      table.concat(right, "\n"),
      "left",
      "right",
      true
    ))
    wait_until(function() return view.updater_idx == nil end, 1, "expected diff computation to finish")
    local initial = #view.diff_folds_a
    test.ok(initial >= 2, "expected repeated fold candidates")
    view:expand_fold(view.diff_folds_a[1])
    test.equal(initial - 1, #view.diff_folds_a)
    local cache = view.request.user_data and view.request.user_data.diff_fold_state
    test.ok(not cache or #(cache.states or {}) == 0, "ambiguous expansion should not be persisted by identity")
  end)

  test.it("resets ambiguous fold index expansion on rediff", function(context)
    local old_context = config.plugins.diffview.fold_context_lines
    local old_min = config.plugins.diffview.fold_min_lines
    local old_default = config.plugins.diffview.fold_unchanged_by_default
    config.plugins.diffview.fold_context_lines = 0
    config.plugins.diffview.fold_min_lines = 3
    config.plugins.diffview.fold_unchanged_by_default = true
    context.restore_diff_folding_config = function()
      config.plugins.diffview.fold_context_lines = old_context
      config.plugins.diffview.fold_min_lines = old_min
      config.plugins.diffview.fold_unchanged_by_default = old_default
    end

    local repeated = { "repeat a", "repeat b", "repeat tail" }
    local left, right = { "old 1" }, { "new 1" }
    for _, line in ipairs(repeated) do left[#left + 1], right[#right + 1] = line, line end
    left[#left + 1], right[#right + 1] = "old 2", "new 2"
    for _, line in ipairs(repeated) do left[#left + 1], right[#right + 1] = line, line end
    left[#left + 1], right[#right + 1] = "old 3", "new 3"
    local view = track(context, "diffviews", diffview.string_to_string(table.concat(left, "\n"), table.concat(right, "\n"), "left", "right", true))
    wait_until(function() return view.updater_idx == nil end, 1, "expected diff computation to finish")
    local initial = #view.diff_folds_a
    test.ok(initial >= 2)
    view:expand_fold(view.diff_folds_a[1])
    test.equal(initial - 1, #view.diff_folds_a)
    local before_generation = view.diff_generation
    view.buffer_view_a.buffer:apply_edits({ { line1 = 1, col1 = 1, line2 = 1, col2 = 1, text = "same inserted\n" } }, { type = "insert" })
    view.buffer_view_b.buffer:apply_edits({ { line1 = 1, col1 = 1, line2 = 1, col2 = 1, text = "same inserted\n" } }, { type = "insert" })
    wait_until(function() return view.diff_generation > before_generation and view.updater_idx == nil end, 1, "expected rediff")
    test.equal(initial, #view.diff_folds_a)
  end)

  test.it("preserves fold state through request controller reload", function(context)
    local old_context = config.plugins.diffview.fold_context_lines
    local old_min = config.plugins.diffview.fold_min_lines
    local old_default = config.plugins.diffview.fold_unchanged_by_default
    config.plugins.diffview.fold_context_lines = 1
    config.plugins.diffview.fold_min_lines = 3
    config.plugins.diffview.fold_unchanged_by_default = true
    context.restore_diff_folding_config = function()
      config.plugins.diffview.fold_context_lines = old_context
      config.plugins.diffview.fold_min_lines = old_min
      config.plugins.diffview.fold_unchanged_by_default = old_default
    end

    local left, right = {}, {}
    for i = 1, 14 do left[i], right[i] = "same " .. i, "same " .. i end
    left[7], right[7] = "old", "new"
    local controller = diffview.DiffRequestController(diffview.MutableDiffRequestChain({
      contents = { diffview.content.text(table.concat(left, "\n")), diffview.content.text(table.concat(right, "\n")) },
      editable_policy = "content",
    }), { noshow = true })
    local view = controller:get_view()
    track(context, "diffviews", view)
    wait_until(function() return view.updater_idx == nil end, 1, "expected diff computation to finish")
    local initial = #view.diff_folds_a
    test.ok(initial > 0)
    view:expand_fold(view.diff_folds_a[1])
    local expanded_count = #view.diff_folds_a
    local new_view, err = controller:reload({ noshow = true })
    test.ok(new_view, err)
    track(context, "diffviews", new_view)
    wait_until(function() return new_view.updater_idx == nil end, 1, "expected reloaded diff computation to finish")
    test.equal(expanded_count, #new_view.diff_folds_a)
  end)

  test.it("keeps diff fold state scoped to each request", function(context)
    local old_context = config.plugins.diffview.fold_context_lines
    local old_min = config.plugins.diffview.fold_min_lines
    local old_default = config.plugins.diffview.fold_unchanged_by_default
    config.plugins.diffview.fold_context_lines = 1
    config.plugins.diffview.fold_min_lines = 3
    config.plugins.diffview.fold_unchanged_by_default = true
    context.restore_diff_folding_config = function()
      config.plugins.diffview.fold_context_lines = old_context
      config.plugins.diffview.fold_min_lines = old_min
      config.plugins.diffview.fold_unchanged_by_default = old_default
    end

    local left, right = {}, {}
    for i = 1, 14 do left[i], right[i] = "same " .. i, "same " .. i end
    left[7], right[7] = "old", "new"
    local text_left, text_right = table.concat(left, "\n"), table.concat(right, "\n")
    local view1 = track(context, "diffviews", diffview.string_to_string(text_left, text_right, "left", "right", true))
    local view2 = track(context, "diffviews", diffview.string_to_string(text_left, text_right, "left", "right", true))
    wait_until(function() return view1.updater_idx == nil and view2.updater_idx == nil end, 1, "expected diff computations to finish")
    local initial2 = #view2.diff_folds_a
    test.ok(#view1.diff_folds_a > 0 and initial2 > 0)
    view1:expand_fold(view1.diff_folds_a[1])
    test.ok(#view1.diff_folds_a < initial2)
    test.equal(initial2, #view2.diff_folds_a)
  end)

  test.it("uses core folding for caret movement and scroll synchronization", function(context)
    local old_context = config.plugins.diffview.fold_context_lines
    local old_min = config.plugins.diffview.fold_min_lines
    local old_default = config.plugins.diffview.fold_unchanged_by_default
    config.plugins.diffview.fold_context_lines = 1
    config.plugins.diffview.fold_min_lines = 3
    config.plugins.diffview.fold_unchanged_by_default = true
    context.restore_diff_folding_config = function()
      config.plugins.diffview.fold_context_lines = old_context
      config.plugins.diffview.fold_min_lines = old_min
      config.plugins.diffview.fold_unchanged_by_default = old_default
    end

    local left, right = {}, {}
    for i = 1, 14 do left[i], right[i] = "same " .. i, "same " .. i end
    left[7], right[7] = "old", "new"
    local view = track(context, "diffviews", diffview.string_to_string(
      table.concat(left, "\n"),
      table.concat(right, "\n"),
      "left",
      "right",
      true
    ))
    wait_until(function() return view.updater_idx == nil end, 1, "expected diff computation to finish")

    local fold = view.diff_folds_a[1]
    test.not_nil(fold)
    panes.create { factory = function() return view end }
    view.buffer_view_a.buffer:set_selection(fold.hidden_start + 1, 1)
    local line = view.buffer_view_a.buffer:get_selection()
    test.equal(line, fold.hidden_start + 1)

    core.active_view = view.buffer_view_a
    view.buffer_view_a.buffer:set_selection(fold.hidden_start, 1)
    test.equal(command.perform("core:move_to_next_line"), true)
    line = view.buffer_view_a.buffer:get_selection()
    test.equal(line, fold.hidden_end + 1)
    test.equal(view.buffer_view_b.buffer:get_selection(), fold.hidden_end + 1)
    local _, y1 = view.buffer_view_a:get_line_screen_position(line, 1)
    test.equal(command.perform("core:move_to_next_line"), true)
    line = view.buffer_view_a.buffer:get_selection()
    test.equal(line, fold.hidden_end + 2)
    local _, y2 = view.buffer_view_a:get_line_screen_position(line, 1)
    test.ok(y2 > y1)

    view.buffer_view_a.position.y, view.buffer_view_a.size.y = 0, 80
    view.buffer_view_b.position.y, view.buffer_view_b.size.y = 0, 80
    view.buffer_view_a:scroll_to_make_visible(7, 1, true)
    test.equal(view.buffer_view_b.scroll.to.y, view.buffer_view_a.scroll.to.y)
  end)

  test.it("expands folded regions when clicking their widget line", function(context)
    local old_context = config.plugins.diffview.fold_context_lines
    local old_min = config.plugins.diffview.fold_min_lines
    local old_default = config.plugins.diffview.fold_unchanged_by_default
    config.plugins.diffview.fold_context_lines = 1
    config.plugins.diffview.fold_min_lines = 3
    config.plugins.diffview.fold_unchanged_by_default = true
    context.restore_diff_folding_config = function()
      config.plugins.diffview.fold_context_lines = old_context
      config.plugins.diffview.fold_min_lines = old_min
      config.plugins.diffview.fold_unchanged_by_default = old_default
    end

    local left, right = {}, {}
    for i = 1, 14 do left[i], right[i] = "same " .. i, "same " .. i end
    left[7], right[7] = "old", "new"
    local view = track(context, "diffviews", diffview.string_to_string(
      table.concat(left, "\n"),
      table.concat(right, "\n"),
      "left",
      "right",
      true
    ))
    wait_until(function() return view.updater_idx == nil end, 1, "expected diff computation to finish")

    local fold = view.diff_folds_a[1]
    test.not_nil(fold)
    local fold_count = #view.diff_folds_a
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 800, 400
    view:update()
    local x, y = view.buffer_view_a:get_line_screen_position(fold.hidden_start, 1)

    test.equal(view:on_mouse_pressed("left", x + 1, y + 1, 1), true)
    test.equal(#view.diff_folds_a, fold_count - 1)
    test.equal(#view.diff_folds_b, fold_count - 1)
    for _, remaining in ipairs(view.diff_folds_a) do
      test.ok(remaining.index ~= fold.index)
    end
    for _, remaining in ipairs(view.diff_folds_b) do
      test.ok(remaining.index ~= fold.index)
    end
  end)

  test.it("restores both Blank Diff Buffers from Workspace state", function(context)
    local controller = diffview.DiffRequestController(diffview.MutableDiffRequestChain({
      title = "Blank Diff View",
      kind = "blank",
      contents = { diffview.content.blank({ name = "Left" }), diffview.content.blank({ name = "Right" }) },
      content_titles = { "Left", "Right" },
      editable_policy = "editable",
      user_data = { blank_diff = true },
    }, { blank_diff = true }), { noshow = true })
    local view = track(context, "diffviews", controller:get_view())
    view.buffer_view_a:on_text_input("left restored")
    view.buffer_view_b:on_text_input("right restored")

    local state = test.not_nil(view:get_state())
    local restored = track(context, "diffviews", diffview.from_state(state))
    test.equal(restored:get_module(), "plugins.diffview")
    test.equal(text(restored.buffer_view_a.buffer), "left restored\n")
    test.equal(text(restored.buffer_view_b.buffer), "right restored\n")
    test.equal(restored.buffer_view_a.buffer.intellij_untitled, true)
    test.equal(restored.buffer_view_a.buffer.new_file, true)
    test.not_nil(restored.buffer_view_a.buffer.intellij_untitled_backing_path)
  end)

  test.it("keeps small insert-only hunks compact", function(context)
    local view = track(context, "diffviews", diffview.string_to_string(
      "before\nafter",
      "before\ninsert one\ninsert two\nafter",
      "left",
      "right",
      true
    ))
    wait_until(function() return view.updater_idx == nil end, 1, "expected diff computation to finish")
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 800, 300
    view:update()

    local _, left_after_y = view.buffer_view_a:get_line_screen_position(2, 1)
    local _, right_after_y = view.buffer_view_b:get_line_screen_position(4, 1)
    test.ok(left_after_y < right_after_y, "a small hunk should not add Diff Gap Rows")
  end)

  test.it("keeps diff colors visible on the current line", function(context)
    local view = track(context, "diffviews", diffview.string_to_string(
      "before",
      "before\ninserted",
      "left",
      "right",
      true
    ))
    wait_until(function() return view.updater_idx == nil end, 1, "expected diff computation to finish")

    local right = view.buffer_view_b
    right:with_selection_state(function() right.buffer:set_selection(2, 1) end)
    local highlight_count = 0
    local old_draw_rect = renderer.draw_rect
    renderer.draw_rect = function() end
    local ok, err = pcall(function()
      right:draw_current_line_highlights(1, 2, function()
        highlight_count = highlight_count + 1
      end)
    end)
    renderer.draw_rect = old_draw_rect
    if not ok then error(err, 0) end

    test.equal("insert", view.diff_model:line_state("b", 2))
    test.equal(0, highlight_count)
  end)

  test.it("routes horizontal wheel input to the hovered Diff Side", function(context)
    local long_left = "left " .. string.rep("a", 200)
    local long_right = "right " .. string.rep("b", 200)
    local view = track(context, "diffviews", diffview.string_to_string(
      long_left,
      long_right,
      "left",
      "right",
      true
    ))
    wait_until(function() return view.updater_idx == nil end, 1, "expected diff computation to finish")
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 600, 120
    view:update()

    local right = view.buffer_view_b
    view:on_mouse_moved(right.position.x + 10, right.position.y + 10, 0, 0)
    local handled = view:on_mouse_wheel(0, -1)

    test.equal(view.buffer_view_a.scroll.to.x, 0)
    test.ok(right.scroll.to.x > 0)
    test.equal(handled, true)
  end)

  test.it("keeps a large final hunk compact", function(context)
    local inserted = { "before" }
    for i = 1, 6 do inserted[#inserted + 1] = "insert " .. i end
    inserted[#inserted + 1] = "after"
    local view = track(context, "diffviews", diffview.string_to_string(
      "before\nafter",
      table.concat(inserted, "\n"),
      "left",
      "right",
      true
    ))
    wait_until(function() return view.updater_idx == nil end, 1, "expected diff computation to finish")
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 800, 300
    view:update()

    local _, left_after_y = view.buffer_view_a:get_line_screen_position(2, 1)
    local _, right_after_y = view.buffer_view_b:get_line_screen_position(8, 1)
    test.ok(left_after_y < right_after_y, "a final hunk should not add Diff Gap Rows")
    test.ok(view.buffer_view_a:get_scrollable_line_count() < view.buffer_view_b:get_scrollable_line_count())
  end)

  test.it("aligns later lines after a large insert-only hunk", function(context)
    local inserted = { "before" }
    for i = 1, 12 do inserted[#inserted + 1] = "insert " .. i end
    for i = 1, 4 do inserted[#inserted + 1] = "shared " .. i end
    local view = track(context, "diffviews", diffview.string_to_string(
      "before\nshared 1\nshared 2\nshared 3\nshared 4",
      table.concat(inserted, "\n"),
      "left",
      "right",
      true
    ))
    wait_until(function() return view.updater_idx == nil end, 1, "expected diff computation to finish")
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 800, 300
    view:update()

    local _, left_shared_y = view.buffer_view_a:get_line_screen_position(2, 1)
    local _, right_shared_y = view.buffer_view_b:get_line_screen_position(14, 1)
    test.equal(left_shared_y, right_shared_y, "a large hunk should align a substantial shared section")
  end)

  test.it("keeps minor wrapped replacement offsets compact", function(context)
    local old_message = '    message = "Pi rechazó el mensaje, pero no confirmó la retirada de su correlación.",'
    local new_message = '    message = "El asistente IA rechazó el mensaje, pero no confirmó la retirada de su correlación.",'
    local view = track(context, "diffviews", diffview.string_to_string(
      table.concat({ "before", old_message, "retirement.exceptionOrNull()", "after" }, "\n"),
      table.concat({ "before", new_message, "retirement.exceptionOrNull()", "after" }, "\n"),
      "left",
      "right",
      true
    ))
    wait_until(function() return view.updater_idx == nil end, 1, "expected diff computation to finish")
    view.buffer_view_a:set_wrapping_enabled(true)
    view.buffer_view_b:set_wrapping_enabled(true)
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 620, 300
    view:update()

    local left_rows = view.buffer_view_a:get_visual_row_count_for_line(2)
    local right_rows = view.buffer_view_b:get_visual_row_count_for_line(2)
    test.ok(left_rows ~= right_rows, "fixture should wrap the replacement to different heights")
    local _, left_y = view.buffer_view_a:get_line_screen_position(3, 1)
    local _, right_y = view.buffer_view_b:get_line_screen_position(3, 1)
    test.ok(left_y < right_y, "a minor wrap difference should not add Diff Gap Rows")
  end)

  test.it("builds matching folds around insert-only hunks", function(context)
    local old_context = config.plugins.diffview.fold_context_lines
    local old_min = config.plugins.diffview.fold_min_lines
    local old_default = config.plugins.diffview.fold_unchanged_by_default
    config.plugins.diffview.fold_context_lines = 2
    config.plugins.diffview.fold_min_lines = 3
    config.plugins.diffview.fold_unchanged_by_default = true
    context.restore_diff_folding_config = function()
      config.plugins.diffview.fold_context_lines = old_context
      config.plugins.diffview.fold_min_lines = old_min
      config.plugins.diffview.fold_unchanged_by_default = old_default
    end

    local left, right = {}, { "inserted" }
    for i = 1, 20 do
      left[#left + 1] = "same " .. i
      right[#right + 1] = "same " .. i
    end
    local view = track(context, "diffviews", diffview.string_to_string(
      table.concat(left, "\n"),
      table.concat(right, "\n"),
      "left",
      "right",
      true
    ))
    wait_until(function() return view.updater_idx == nil end, 1, "expected diff computation to finish")

    test.equal(#view.diff_folds_a, #view.diff_folds_b)
    test.equal(view.diff_folds_a[1].hidden_count, view.diff_folds_b[1].hidden_count)
  end)

  test.it("does not wrap change navigation within one file", function(context)
    local view = track(context, "diffviews", diffview.string_to_string(
      "aa\nleft-one\nbb\nleft-two\ncc",
      "aa\nbb\ncc",
      "left",
      "right",
      true
    ))
    wait_until(function() return view.updater_idx == nil end, 1, "expected diff computation to finish")

    local left = view.buffer_view_a
    core.set_active_view(left)
    left.buffer:set_selection(4, 1)
    test.ok(command.perform("diff:next_change"))
    test.equal(left.buffer:get_selection(), 4)
    test.ok(command.perform("diff:prev_change"))
    test.equal(left.buffer:get_selection(), 2)
  end)

  test.it("uses providers and listeners without replacing child TextView or Buffer methods", function(context)
    local view = track(context, "diffviews", diffview.string_to_string(
      "aa\nleft\nbb",
      "aa\nright\nbb",
      "left",
      "right",
      true
    ))
    wait_until(function() return view.updater_idx == nil end, 1, "expected diff computation to finish")

    test.equal(rawget(view.buffer_view_a, "draw_line_text"), nil)
    test.equal(rawget(view.buffer_view_a, "scroll_to_line"), nil)
    test.equal(rawget(view.buffer_view_a, "scroll_to_make_visible"), nil)
    test.equal(view.buffer_view_a.buffer.set_selection, Buffer.set_selection)
    test.equal(view.buffer_view_a.buffer.raw_insert, Buffer.raw_insert)
    test.equal(view.buffer_view_a.buffer.raw_remove, Buffer.raw_remove)
    test.ok(view.buffer_view_a.decoration_providers["diff-view"] ~= nil)
    test.ok(view.buffer_view_a.poi_providers["diff-view"] ~= nil)
  end)

end)
