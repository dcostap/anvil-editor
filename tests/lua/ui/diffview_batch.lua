local core = require "core"
local command = require "core.command"
local config = require "core.config"
local style = require "core.style"
local test = require "core.test"
local diffview = require "plugins.diffview"
local Doc = require "core.doc"
local DocView = require "core.docview"

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

local function text(doc)
  return table.concat(doc.lines)
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
    for _, view in ipairs(context.diffviews or {}) do
      local node = core.root_panel.root_node:get_node_for_view(view)
      if node then node:remove_view(core.root_panel.root_node, view) end
      view.doc_view_a.doc:on_close()
      view.doc_view_b.doc:on_close()
    end
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
    test.equal("left\n", text(view.doc_view_a.doc))
    test.equal("right\n", text(view.doc_view_b.doc))
    test.equal("Old", view.request.content_titles[1])
    test.equal("New", view.request.content_titles[2])
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
      { kind = "document", doc = {} },
      diffview.content.blank(),
    } }, true)
    test.equal(nil, view)
    test.ok(err and err:find("requires a Doc", 1, true))

    view, err = diffview.open({ contents = {
      diffview.content.file("same/path.txt"),
      diffview.content.file("same/./path.txt"),
    } }, true)
    test.equal(nil, view)
    test.ok(err and err:find("same file", 1, true))

    local file_doc = Doc("path.txt", "same/path.txt", true)
    view, err = diffview.open({ contents = {
      diffview.content.document(file_doc),
      diffview.content.file("same/./path.txt"),
    } }, true)
    test.equal(nil, view)
    test.ok(err and err:find("same file", 1, true))

    local abs_doc = Doc("path.txt", core.project_absolute_path("same/path.txt"), true)
    view, err = diffview.open({ contents = {
      diffview.content.document(abs_doc),
      diffview.content.file("same/path.txt"),
    } }, true)
    test.equal(nil, view)
    test.ok(err and err:find("same file", 1, true))
  end)

  test.it("uses side title precedence and closes only owned transient docs", function(context)
    local left_closed, right_closed = 0, 0
    local left_doc = Doc("caller", "caller", true)
    local old_left_close = left_doc.on_close
    left_doc.on_close = function(doc, ...)
      left_closed = left_closed + 1
      return old_left_close(doc, ...)
    end

    local right = diffview.content.text("owned text", { name = "Content Name" })
    local view, err = diffview.open({
      contents = {
        diffview.content.document(left_doc, { name = "Document Content Name" }),
        right,
      },
      content_titles = { nil, "Title Override" },
    }, true)
    test.ok(view, err)
    track(context, "diffviews", view)

    local old_right_close = view.doc_view_b.doc.on_close
    view.doc_view_b.doc.on_close = function(doc, ...)
      right_closed = right_closed + 1
      return old_right_close(doc, ...)
    end

    test.equal("caller", view.doc_view_a.doc:get_name())
    test.equal("Title Override", view.doc_view_b.doc:get_name())

    local closed = false
    view:try_close(function() closed = true end)
    test.ok(closed)
    test.equal(0, left_closed)
    test.equal(1, right_closed)
  end)

  test.it("blank diff controller opens editable documents and replaces a side in place", function(context)
    local node = core.root_panel:get_active_node_default()
    test.ok(command.perform("diff-view:open-blank-diff"))
    local view = core.active_view.diff_view_parent
    local controller = view and view.request_controller
    test.ok(controller and controller.get_view, "expected blank diff controller")
    view = controller:get_view()
    track(context, "diffviews", view)
    test.equal(node, core.root_panel.root_node:get_node_for_view(view))
    test.equal(view.doc_view_a, core.active_view)

    view.doc_view_a:on_text_input("left")
    wait_until(function() return view.updater_idx == nil end, 1, "expected initial diff computation to finish")
    local before_generation = view.diff_generation
    view.doc_view_b:on_text_input("right")
    wait_until(function() return view.diff_generation > before_generation and view.updater_idx == nil end, 1, "expected edit to schedule one rediff")

    view.doc_view_a.doc:clean()

    local path = core.project_absolute_path("tmp-diff-replace-left.txt")
    pcall(os.remove, path)
    write_file(path, "file left\n")
    context.cleanup_replace_file = path

    local old_idx = node:get_view_idx(view)
    local new_view, err = controller:replace_content("left", diffview.content.file(path), { title = "File Left" })
    test.ok(new_view, err)
    track(context, "diffviews", new_view)
    test.equal(node, core.root_panel.root_node:get_node_for_view(new_view))
    test.equal(old_idx, node:get_view_idx(new_view))
    test.equal("file left\n", text(new_view.doc_view_a.doc))
    test.equal("right\n", text(new_view.doc_view_b.doc))
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
    new_view.doc_view_a:on_text_input("dirty ")

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
    ro_view.doc_view_a:on_text_input("X")
    test.equal("read only\n", text(ro_view.doc_view_a.doc))
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
    view.doc_view_a:on_text_input("dirty ")

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

  test.it("blank diff side replacement can be cancelled for dirty owned documents", function(context)
    local controller = diffview.DiffRequestController(diffview.MutableDiffRequestChain({
      title = "Blank Diff View",
      kind = "blank",
      contents = { diffview.content.blank({ name = "Left" }), diffview.content.blank({ name = "Right" }) },
      editable_policy = "editable",
    }), { noshow = true })
    local view = controller:get_view()
    track(context, "diffviews", view)
    view.doc_view_a:on_text_input("dirty")

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
    test.equal("dirty\n", text(view.doc_view_a.doc))
  end)

  test.it("read-only diff guards block view-routed edits without locking caller documents", function(context)
    local doc = Doc("caller", "caller", true)
    doc:insert(1, 1, "left")
    doc:clear_undo_redo()
    local view, err = diffview.open({
      contents = {
        diffview.content.document(doc, { read_only_reason = "snapshot" }),
        diffview.content.blank(),
      },
      editable_policy = "read-only",
    }, true)
    test.ok(view, err)
    track(context, "diffviews", view)

    view.doc_view_a:on_text_input("X")
    test.equal("left\n", text(doc))

    core.active_view = view.doc_view_a
    view.doc_view_a.doc:set_selection(1, 1, 1, 2)
    command.perform("doc:delete")
    test.equal("left\n", text(doc))
    command.perform("doc:delete-lines")
    test.equal("left\n", text(doc))
    command.perform("doc:upper-case")
    test.equal("left\n", text(doc))
    command.perform("quote:quote")
    test.equal("left\n", text(doc))
    view.doc_view_a:on_ime_text_editing("Z", 0, 1)
    test.equal("left\n", text(doc))

    local normal = DocView(doc)
    normal:on_text_input("Y")
    test.equal(text(doc), "Yeft\n")
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
    core.active_view = view.doc_view_a

    local old_crlf = view.doc_view_a.doc.crlf
    command.perform("doc:toggle-line-ending")
    test.equal(view.doc_view_a.doc.crlf, old_crlf)
    view.doc_view_a.doc:insert(1, 1, "dirty ")
    command.perform("doc:save")
    test.equal(read_file(path), "left\n")
    command.perform("file:delete")
    test.ok(file_exists(path), "read-only file delete should be blocked")
  end)

  test.it("does not expose hunk application as a Diff View action", function()
    test.equal(nil, command.map["diff-view:sync-change"])
  end)

  test.it("rejects same document requests and balances assignment hooks", function(context)
    local doc = Doc("shared", "shared", true)
    local events = {}
    local request = {
      contents = {
        diffview.content.document(doc),
        diffview.content.document(doc),
      },
      on_assigned = function(_, assigned)
        events[#events + 1] = assigned and "request assigned" or "request unassigned"
      end,
    }
    local view, err = diffview.open(request, true)
    test.equal(nil, view)
    test.ok(err and err:find("same document", 1, true))
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

  test.it("folds long unchanged regions and toggles them from diff DocViews", function(context)
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
    test.ok(view.diff_folds_a[1].core_fold ~= nil, "expected diff folds to be backed by core DocView folds")
    test.equal(view.doc_view_a:get_collapsed_fold_at_line(view.diff_folds_a[1].hidden_start), view.diff_folds_a[1].core_fold)
    local folded_size = view.doc_view_a:get_scrollable_size()
    core.active_view = view.doc_view_a
    test.equal(command.perform("diff-view:toggle-folding"), true)
    test.equal(#view.diff_folds_a, 0)
    test.ok(view.doc_view_a:get_scrollable_size() > folded_size)
    core.active_view = view
    test.equal(command.perform("diff-view:toggle-folding"), true)
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
    view.doc_view_a.doc:apply_edits({ { line1 = 8, col1 = 1, line2 = 8, col2 = 1, text = "inserted before fold\n" } }, { type = "insert" })
    view.doc_view_b.doc:apply_edits({ { line1 = 8, col1 = 1, line2 = 8, col2 = 1, text = "inserted before fold\n" } }, { type = "insert" })
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
    view.doc_view_a.doc:apply_edits({ { line1 = 1, col1 = 1, line2 = 1, col2 = 1, text = "same inserted\n" } }, { type = "insert" })
    view.doc_view_b.doc:apply_edits({ { line1 = 1, col1 = 1, line2 = 1, col2 = 1, text = "same inserted\n" } }, { type = "insert" })
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
    view.doc_view_a.doc:set_selection(fold.hidden_start + 1, 1)
    local line = view.doc_view_a.doc:get_selection()
    test.equal(line, fold.hidden_start + 1)

    core.active_view = view.doc_view_a
    view.doc_view_a.doc:set_selection(fold.hidden_start, 1)
    test.equal(command.perform("doc:move-to-next-line"), true)
    line = view.doc_view_a.doc:get_selection()
    test.equal(line, fold.hidden_end + 1)
    test.equal(view.doc_view_b.doc:get_selection(), fold.hidden_end + 1)
    local _, y1 = view.doc_view_a:get_line_screen_position(line, 1)
    test.equal(command.perform("doc:move-to-next-line"), true)
    line = view.doc_view_a.doc:get_selection()
    test.equal(line, fold.hidden_end + 2)
    local _, y2 = view.doc_view_a:get_line_screen_position(line, 1)
    test.ok(y2 > y1)

    view.doc_view_a.position.y, view.doc_view_a.size.y = 0, 80
    view.doc_view_b.position.y, view.doc_view_b.size.y = 0, 80
    view.doc_view_a:scroll_to_make_visible(7, 1, true)
    test.equal(view.doc_view_b.scroll.to.y, view.doc_view_a.scroll.to.y)
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
    local x, y = view.doc_view_a:get_line_screen_position(fold.hidden_start, 1)

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

  test.it("draws polished central line numbers, curved connectors, and gap markers", function(context)
    local view = track(context, "diffviews", diffview.string_to_string(
      "aa\nbb",
      "aa\ninserted\nbb",
      "left",
      "right",
      true
    ))
    wait_until(function() return view.updater_idx == nil end, 1, "expected diff computation to finish")
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 800, 400
    view:update()
    test.equal(view.doc_view_a:get_scrollable_line_count(), view.doc_view_b:get_scrollable_line_count())
    test.equal(view.doc_view_a:get_scrollable_line_count(), 3)

    local old_draw_poly = renderer.draw_poly
    local old_draw_rect = renderer.draw_rect
    local old_push_clip_rect = core.push_clip_rect
    local old_pop_clip_rect = core.pop_clip_rect
    local old_draw_text = renderer.draw_text
    local polygons = {}
    local markers = {}
    local arrows = {}
    local line_numbers = {}
    renderer.draw_poly = function(points, color)
      polygons[#polygons + 1] = { points = points, color = color }
    end
    renderer.draw_rect = function(x, y, w, h, color)
      markers[#markers + 1] = { x = x, y = y, w = w, h = h, color = color }
    end
    renderer.draw_text = function(font, text, x, y, color)
      if text == ">" or text == "<" then arrows[#arrows + 1] = { text = text, x = x, y = y, color = color } end
      if tostring(text):match("^%d+$") then line_numbers[#line_numbers + 1] = { text = tostring(text), x = x, y = y, color = color } end
      return x
    end
    core.push_clip_rect = function() end
    core.pop_clip_rect = function() end
    local ok, err = pcall(function() view:draw_divider_changes() end)
    renderer.draw_poly = old_draw_poly
    renderer.draw_rect = old_draw_rect
    core.push_clip_rect = old_push_clip_rect
    core.pop_clip_rect = old_pop_clip_rect
    renderer.draw_text = old_draw_text
    if not ok then error(err, 0) end

    test.ok(#polygons >= 1, "expected an inserted hunk connector in the divider")
    test.ok(#polygons[1].points > 4, "expected a curved connector, not a simple rectangle")
    test.ok(#markers >= 1, "expected a thin gap marker on the side without inserted lines")
    test.same(style.background, markers[1].color, "central line-number columns should match a standard DocView")
    local has_thin_marker = false
    for _, marker in ipairs(markers) do
      if marker.h <= math.max(1, SCALE) + 0.01 then has_thin_marker = true; break end
    end
    test.ok(has_thin_marker, "expected a thin marker line")
    test.ok(#line_numbers >= 2, "expected both Diff Side line numbers in the central divider")
    test.equal(false, view.doc_view_a.show_line_numbers)
    test.equal(false, view.doc_view_b.show_line_numbers)
    local left_gutter_width = view.doc_view_a:get_gutter_width()
    local right_gutter_width = view.doc_view_b:get_gutter_width()
    test.equal(left_gutter_width, 0, "the left Diff Side should not retain an empty inner gutter; got " .. tostring(left_gutter_width)
      .. ", configured " .. tostring(view.doc_view_a.gutter_padding)
      .. ", numbers " .. tostring(view.doc_view_a:line_number_gutter_visible()))
    test.equal(right_gutter_width, 0, "the right Diff Side should not retain an empty inner gutter; got " .. tostring(right_gutter_width))
    test.equal(false, view.scrollable, "the Diff View should not add a third parent scrollbar")
    test.equal(
      view.position.x + view.size.x,
      view.doc_view_b.position.x + view.doc_view_b.size.x,
      "the right Diff Side should extend to the view edge"
    )
    test.equal(0, #arrows, "hunk apply arrows should not clutter the divider")
  end)

  test.it("uses dedicated subdued colors for diff overview markers", function(context)
    local left, right = {}, {}
    for i = 1, 60 do left[i], right[i] = "same " .. i, "same " .. i end
    left[30] = 'description: "old managed extension bundle"'
    right[30] = 'description: "new managed assistant extensions"'
    local view = track(context, "diffviews", diffview.string_to_string(
      table.concat(left, "\n"),
      table.concat(right, "\n"),
      "left",
      "right",
      true
    ))
    wait_until(function() return view.updater_idx == nil end, 1, "expected diff computation to finish")
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 800, 100
    view:update()

    local old_draw_rect = renderer.draw_rect
    local saw_overview_color = false
    renderer.draw_rect = function(x, y, w, h, color)
      if color == style.diff_overview_modify then saw_overview_color = true end
    end
    local ok, err = pcall(function() view:draw_scrollbar() end)
    renderer.draw_rect = old_draw_rect
    if not ok then error(err, 0) end
    test.ok(saw_overview_color, "expected the theme's subdued modify overview color")
  end)

  test.it("uses a neutral changed-line background before inline old/new emphasis", function(context)
    local view = track(context, "diffviews", diffview.string_to_string(
      '    description: "Verifies that APPi loaded its managed Pi extension bundle",',
      '    description: "Comprueba que APPi cargó las extensiones administradas del asistente IA",',
      "left",
      "right",
      true
    ))
    wait_until(function() return view.updater_idx == nil end, 1, "expected diff computation to finish")

    local left_provider = view.doc_view_a.decoration_providers["diff-view"].provider
    local right_provider = view.doc_view_b.decoration_providers["diff-view"].provider
    test.same(style.diff_modify_background, left_provider:line_background(view.doc_view_a, 1))
    test.same(style.diff_modify_background, right_provider:line_background(view.doc_view_b, 1))

    local left_ranges = left_provider:inline_ranges(view.doc_view_a, 1)
    local right_ranges = right_provider:inline_ranges(view.doc_view_b, 1)
    test.ok(#left_ranges <= 3 and #right_ranges <= 3, "expected grouped inline emphasis")
    test.same(left_ranges[1].color, style.diff_modify_inline)
    test.same(right_ranges[1].color, style.diff_modify_inline)

    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 800, 200
    view:update()
    local old_draw_poly = renderer.draw_poly
    local old_draw_rect = renderer.draw_rect
    local old_draw_text = renderer.draw_text
    local old_push_clip_rect = core.push_clip_rect
    local old_pop_clip_rect = core.pop_clip_rect
    local connectors = 0
    local connector_color
    renderer.draw_poly = function(_, color)
      connectors = connectors + 1
      connector_color = color
    end
    renderer.draw_rect = function() end
    renderer.draw_text = function(_, _, x) return x end
    core.push_clip_rect = function() end
    core.pop_clip_rect = function() end
    local ok, err = pcall(function() view:draw_divider_changes() end)
    renderer.draw_poly = old_draw_poly
    renderer.draw_rect = old_draw_rect
    renderer.draw_text = old_draw_text
    core.push_clip_rect = old_push_clip_rect
    core.pop_clip_rect = old_pop_clip_rect
    if not ok then error(err, 0) end
    test.equal(1, connectors, "paired modified lines should have one coherent connector")
    test.same(style.diff_modify_background, connector_color)
  end)

  test.it("keeps later lines aligned when paired replacements wrap to different row counts", function(context)
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
    view.doc_view_a:set_wrapping_enabled(true)
    view.doc_view_b:set_wrapping_enabled(true)
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 620, 300
    view:update()

    local left_rows = view.doc_view_a:get_visual_row_count_for_line(2)
    local right_rows = view.doc_view_b:get_visual_row_count_for_line(2)
    test.ok(left_rows ~= right_rows, "fixture should wrap the replacement to different heights")
    local _, left_y = view.doc_view_a:get_line_screen_position(3, 1)
    local _, right_y = view.doc_view_b:get_line_screen_position(3, 1)
    test.equal(left_y, right_y, "the line after a differently wrapped replacement should remain aligned")
    test.equal(view.doc_view_a:get_scrollable_line_count(), view.doc_view_b:get_scrollable_line_count())
  end)

  test.it("renders an expanded comment replacement as one compact modification", function(context)
    local old_comment = "// Let Swing paint the lightweight loading surface before cold Compose/Skiko initialization occupies the EDT."
    local new_comments = table.concat({
      "// First let the loading Canvas become displayable and create its native buffers. ComposePanel",
      "// then has to initialize and compose on the AWT event thread, so the Canvas renders actively",
      "// on its own thread until the complete chat tree is ready.",
    }, "\n")
    local timer = "Timer(AI_CHAT_COMPOSE_START_DELAY_MILLIS) {"
    local view = track(context, "diffviews", diffview.string_to_string(
      old_comment .. "\n" .. timer,
      new_comments .. "\n" .. timer,
      "left",
      "right",
      true
    ))
    wait_until(function() return view.updater_idx == nil end, 1, "expected diff computation to finish")
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 1000, 300
    view:update()

    local old_draw_poly = renderer.draw_poly
    local old_draw_rect = renderer.draw_rect
    local old_draw_text = renderer.draw_text
    local old_push_clip_rect = core.push_clip_rect
    local old_pop_clip_rect = core.pop_clip_rect
    local connector_colors = {}
    renderer.draw_poly = function(_, color) connector_colors[#connector_colors + 1] = color end
    renderer.draw_rect = function() end
    renderer.draw_text = function(_, _, x) return x end
    core.push_clip_rect = function() end
    core.pop_clip_rect = function() end
    local ok, err = pcall(function() view:draw_divider_changes() end)
    renderer.draw_poly = old_draw_poly
    renderer.draw_rect = old_draw_rect
    renderer.draw_text = old_draw_text
    core.push_clip_rect = old_push_clip_rect
    core.pop_clip_rect = old_pop_clip_rect
    if not ok then error(err, 0) end

    test.ok(#connector_colors >= 2, "expected paired and continuation connectors")
    for _, color in ipairs(connector_colors) do
      test.same(color, style.diff_modify_background)
    end
    local _, left_timer_y = view.doc_view_a:get_line_screen_position(2, 1)
    local _, right_timer_y = view.doc_view_b:get_line_screen_position(4, 1)
    test.equal(left_timer_y, right_timer_y)
  end)

  test.it("keeps folded panes synchronized around insert-only hunks", function(context)
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
    test.equal(view.doc_view_a:get_scrollable_size(), view.doc_view_b:get_scrollable_size())
  end)

  test.it("wraps diff change navigation across file boundaries", function(context)
    local view = track(context, "diffviews", diffview.string_to_string(
      "aa\nleft-one\nbb\nleft-two\ncc",
      "aa\nbb\ncc",
      "left",
      "right",
      true
    ))
    wait_until(function() return view.updater_idx == nil end, 1, "expected diff computation to finish")

    local left = view.doc_view_a
    core.set_active_view(left)
    left.doc:set_selection(4, 1)
    test.ok(command.perform("diff-view:next-change"))
    test.equal(left.doc:get_selection(), 2)
    test.ok(command.perform("diff-view:prev-change"))
    test.equal(left.doc:get_selection(), 4)
  end)

  test.it("uses providers and listeners without replacing child DocView or Doc methods", function(context)
    local view = track(context, "diffviews", diffview.string_to_string(
      "aa\nleft\nbb",
      "aa\nright\nbb",
      "left",
      "right",
      true
    ))
    wait_until(function() return view.updater_idx == nil end, 1, "expected diff computation to finish")

    test.equal(rawget(view.doc_view_a, "draw_line_text"), nil)
    test.equal(rawget(view.doc_view_a, "scroll_to_line"), nil)
    test.equal(rawget(view.doc_view_a, "scroll_to_make_visible"), nil)
    test.equal(view.doc_view_a.doc.set_selection, Doc.set_selection)
    test.equal(view.doc_view_a.doc.raw_insert, Doc.raw_insert)
    test.equal(view.doc_view_a.doc.raw_remove, Doc.raw_remove)
    test.ok(view.doc_view_a.decoration_providers["diff-view"] ~= nil)
    test.ok(view.doc_view_a.poi_providers["diff-view"] ~= nil)
  end)

end)
