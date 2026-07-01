local core = require "core"
local command = require "core.command"
local DocView = require "core.docview"
local config = require "core.config"
local style = require "core.style"
local test = require "core.test"
local treesitter = require "core.treesitter"

local function track(context, kind, value)
  context[kind] = context[kind] or {}
  table.insert(context[kind], value)
  return value
end

local function remove_doc(doc)
  for i = #core.docs, 1, -1 do
    if core.docs[i] == doc then
      table.remove(core.docs, i)
      doc:on_close()
      return
    end
  end
end

local function numbered_lines(count)
  local lines = {}
  for i = 1, count do lines[i] = "line " .. i end
  return table.concat(lines, "\n")
end

local function wait_treesitter_ready(doc, timeout)
  local deadline = system.get_time() + (timeout or 3)
  while system.get_time() < deadline do
    treesitter.poll_doc(doc)
    if doc.treesitter and doc.treesitter.status == "ready" then return true end
    coroutine.yield(0.01)
  end
  return false
end

local function open_editor(context, text, opts)
  local doc = track(context, "docs", core.open_doc())
  if text and text ~= "" then doc:text_input(text) end
  local view = track(context, "views", core.root_panel:open_doc(doc))
  core.set_active_view(view)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 320, 240
  view.scroll.x, view.scroll.to.x = 0, 0
  view.scroll.y, view.scroll.to.y = 0, 0
  if opts and opts.wrapping ~= nil then view:set_wrapping_enabled(opts.wrapping) end
  return view, doc
end

test.describe("DocView folding", function()
  test.before_each(function(context)
    context.linewrapping_default = config.plugins.linewrapping.enable_by_default
  end)

  test.after_each(function(context)
    config.plugins.linewrapping.enable_by_default = context.linewrapping_default
    local root = core.root_panel.root_node
    for _, view in ipairs(context.views or {}) do
      if view.clear_fold_regions then view:clear_fold_regions("test-cleanup") end
      local node = root:get_node_for_view(view)
      if node then node:remove_view(root, view) end
    end
    for _, doc in ipairs(context.docs or {}) do
      if doc:is_dirty() then doc:clean() end
      remove_doc(doc)
    end
  end)

  test.it("collapsed fold reduces visual row count", function(context)
    local view = open_editor(context, numbered_lines(10), { wrapping = false })

    local fold = assert(view:add_fold_region { line1 = 3, line2 = 6 })

    test.equal(fold.hidden_count, 4)
    test.equal(view:get_scrollable_line_count(), 7)
  end)

  test.it("maps a fold widget row at the folded range start", function(context)
    local view = open_editor(context, numbered_lines(8), { wrapping = false })
    view:add_fold_region { line1 = 3, line2 = 5 }
    local lh = view:get_line_height()

    local _, y2 = view:get_line_screen_position(2)
    local _, y3 = view:get_line_screen_position(3)
    local _, y4 = view:get_line_screen_position(4)
    local line, col = view:resolve_screen_position(view.position.x + view:get_gutter_width() + 8, y3 + lh / 2)

    test.equal(y3, y2 + lh)
    test.equal(y4, y3)
    test.equal(line, 3)
    test.equal(col, 1)
  end)

  test.it("vertical movement skips collapsed fold contents", function(context)
    local view, doc = open_editor(context, numbered_lines(8), { wrapping = false })
    view:add_fold_region { line1 = 3, line2 = 5 }
    doc:set_selection(3, 1)

    command.perform "doc:move-to-next-line"

    test.same({ doc:get_selection() }, { 6, 1, 6, 1 })
  end)

  test.it("select-to-next-line skips collapsed fold contents", function(context)
    local view, doc = open_editor(context, numbered_lines(8), { wrapping = false })
    view:add_fold_region { line1 = 3, line2 = 5 }
    doc:set_selection(3, 1)

    command.perform "doc:select-to-next-line"

    test.same({ doc:get_selection() }, { 6, 1, 3, 1 })
  end)

  test.it("wrapped vertical movement skips collapsed fold contents", function(context)
    local view, doc = open_editor(context, numbered_lines(8), { wrapping = true })
    view:add_fold_region { line1 = 3, line2 = 5 }
    doc:set_selection(3, 1)

    command.perform "doc:move-to-next-line"

    test.same({ doc:get_selection() }, { 6, 1, 6, 1 })
  end)

  test.it("vertical movement does not enter an EOF fold", function(context)
    local view, doc = open_editor(context, numbered_lines(5), { wrapping = false })
    view:add_fold_region { line1 = 3, line2 = 5 }
    doc:set_selection(3, 1)

    command.perform "doc:move-to-next-line"

    test.same({ doc:get_selection() }, { 3, 1, 3, 1 })
  end)

  test.it("moving upward onto a fold widget snaps to its boundary", function(context)
    local view, doc = open_editor(context, numbered_lines(5), { wrapping = false })
    view:add_fold_region { line1 = 2, line2 = 3 }
    doc:set_selection(4, 5)

    command.perform "doc:move-to-previous-line"

    test.same({ doc:get_selection() }, { 2, 1, 2, 1 })
  end)

  test.it("wrapped movement treats a folded long start line as one widget row", function(context)
    local view, doc = open_editor(context, "one\n" .. string.rep("long ", 40) .. "\nhidden\nafter", { wrapping = true })
    view.size.x = 120
    view:update_wrap_cache()
    view:add_fold_region { line1 = 2, line2 = 3 }
    doc:set_selection(2, 1)

    command.perform "doc:move-to-next-line"

    test.same({ doc:get_selection() }, { 4, 1, 4, 1 })
  end)

  test.it("wrapped movement preserves columns on ordinary rows when folds exist elsewhere", function(context)
    local view, doc = open_editor(context, "abcdef\nghijkl\nfold\nhidden\nmore", { wrapping = true })
    view:add_fold_region { line1 = 3, line2 = 4 }
    doc:set_selection(1, 5)

    command.perform "doc:move-to-next-line"

    local line, col = doc:get_selection()
    test.equal(line, 2)
    test.ok(col > 1, "expected wrapped movement to preserve horizontal column")
  end)

  test.it("wrapped movement stays on a visible wrapped row before jumping to a preceding fold", function(context)
    local view, doc = open_editor(context, "one\nfold\nhidden\n" .. string.rep("after ", 40), { wrapping = true })
    view.size.x = 120
    view:update_wrap_cache()
    view:add_fold_region { line1 = 2, line2 = 3 }
    doc:set_selection(4, 30)

    command.perform "doc:move-to-previous-line"

    local line = doc:get_selection()
    test.equal(line, 4)
  end)

  test.it("selection crossing a fold copies hidden text", function(context)
    local view, doc = open_editor(context, numbered_lines(8), { wrapping = false })
    view:add_fold_region { line1 = 3, line2 = 5 }

    doc:set_selection(2, 1, 6, 1)

    test.equal(doc:get_selection_text(), "line 2\nline 3\nline 4\nline 5\n")
  end)

  test.it("draws selected fold widget background when the whole folded range is selected", function(context)
    local view, doc = open_editor(context, numbered_lines(8), { wrapping = false })
    local fold = view:add_fold_region { line1 = 3, line2 = 5 }
    doc:set_selection(3, 1, 6, 1)

    local old_draw_rect = renderer.draw_rect
    local old_draw_text = renderer.draw_text
    local first_color
    renderer.draw_rect = function(x, y, w, h, color)
      if not first_color then first_color = color end
    end
    renderer.draw_text = function() return 0 end
    local ok, err = pcall(function()
      view:draw_fold_widget_body(fold, view.position.x + view:get_gutter_width(), 0)
    end)
    renderer.draw_rect = old_draw_rect
    renderer.draw_text = old_draw_text
    if not ok then error(err, 0) end

    test.equal(first_color, style.selection)
  end)

  test.it("draws default fold widget text with a collapsed-content preview", function(context)
    local view = open_editor(context, "alpha\n  beta\ngamma", { wrapping = false })
    local fold = view:add_fold_region { line1 = 1, line2 = 3 }

    local old_draw_rect = renderer.draw_rect
    local old_draw_text = renderer.draw_text
    local drawn_text
    renderer.draw_rect = function() end
    renderer.draw_text = function(font, text, x, y, color)
      drawn_text = text
      return x + #tostring(text)
    end
    local ok, err = pcall(function()
      view:draw_fold_widget_body(fold, view.position.x + view:get_gutter_width(), 0)
    end)
    renderer.draw_rect = old_draw_rect
    renderer.draw_text = old_draw_text
    if not ok then error(err, 0) end

    test.equal(drawn_text, "alpha beta gamma  ⋯ 3 lines folded ⋯")
  end)

  test.it("truncates long default fold widget previews", function(context)
    local view = open_editor(context, string.rep("a", 60) .. "\nsecond", { wrapping = false })
    local fold = view:add_fold_region { line1 = 1, line2 = 2 }

    local old_draw_rect = renderer.draw_rect
    local old_draw_text = renderer.draw_text
    local drawn_text
    renderer.draw_rect = function() end
    renderer.draw_text = function(font, text, x, y, color)
      drawn_text = text
      return x + #tostring(text)
    end
    local ok, err = pcall(function()
      view:draw_fold_widget_body(fold, view.position.x + view:get_gutter_width(), 0)
    end)
    renderer.draw_rect = old_draw_rect
    renderer.draw_text = old_draw_text
    if not ok then error(err, 0) end

    test.equal(drawn_text, string.rep("a", 50) .. "…  ⋯ 2 lines folded ⋯")
  end)

  test.it("typing over a selection crossing a fold replaces hidden text", function(context)
    local view, doc = open_editor(context, numbered_lines(8), { wrapping = false })
    view:add_fold_region { line1 = 3, line2 = 5 }
    doc:set_selection(2, 1, 6, 1)

    doc:text_input("replacement\n")

    test.equal(doc:get_text(1, 1, math.huge, math.huge), "line 1\nreplacement\nline 6\nline 7\nline 8")
  end)

  test.it("select_and_reveal expands a fold covering the target", function(context)
    local view, doc = open_editor(context, numbered_lines(8), { wrapping = false })
    view:add_fold_region { line1 = 3, line2 = 5 }

    view:select_and_reveal(4, 1, 4, 3, { instant = true })

    test.equal(view:get_collapsed_fold_at_line(4), nil)
    test.same({ doc:get_selection() }, { 4, 1, 4, 3 })
  end)

  test.it("clicking a fold widget expands it", function(context)
    local view = open_editor(context, numbered_lines(8), { wrapping = false })
    view:add_fold_region { line1 = 3, line2 = 5 }
    local x, y = view:get_line_screen_position(3)

    view:on_mouse_pressed("left", x + style.padding.x, y + view:get_line_height() / 2, 1)

    test.equal(view:get_collapsed_fold_at_line(4), nil)
  end)

  test.it("same document views have independent fold state", function(context)
    local view1, doc = open_editor(context, numbered_lines(8), { wrapping = false })
    local view2 = track(context, "views", DocView(doc))
    view2.position.x, view2.position.y = 0, 0
    view2.size.x, view2.size.y = 320, 240
    view2:set_wrapping_enabled(false)

    view1:add_fold_region { line1 = 3, line2 = 5 }

    test.equal(view1:get_scrollable_line_count(), 6)
    test.equal(view2:get_scrollable_line_count(), 8)
  end)

  test.it("wrapping and folding compose for visual row counts", function(context)
    local text = "short\n" .. string.rep("word ", 30) .. "\ninside\nafter"
    local view = open_editor(context, text, { wrapping = true })
    view.size.x = 120
    view:update_wrap_cache()
    local before = view:get_scrollable_line_count()

    view:add_fold_region { line1 = 2, line2 = 3 }

    test.ok(before > view:get_scrollable_line_count(), "expected folding to remove wrapped visual rows")
    test.equal(view:get_total_visual_lines(), view:get_scrollable_line_count())
    test.equal(view:get_visual_row(3, 1), view:get_visual_row(2, 1))
    test.equal(view:get_collapsed_fold_at_line(3).line1, 2)
  end)

  test.it("per-line visual row helpers hide folded interior lines", function(context)
    local view = open_editor(context, numbered_lines(8), { wrapping = false })
    view:add_fold_region { line1 = 3, line2 = 5 }

    test.equal(view:get_visual_row_count_for_line(3), 1)
    test.equal(view:get_visual_row_count_for_line(4), 0)
    test.same({ view:get_visual_row_bounds_for_line(4, 1) }, { nil, nil })

    local iter = view:iter_visible_wrap_rows_for_line(4, 0)
    test.equal(iter(), nil)
  end)

  test.it("normal clicks do not use stale fold hit testing state", function(context)
    local view = open_editor(context, numbered_lines(8), { wrapping = false })
    view:add_fold_region { line1 = 3, line2 = 5 }
    local fold_x, fold_y = view:get_line_screen_position(3)
    local normal_x, normal_y = view:get_line_screen_position(7)

    view:resolve_screen_position(fold_x, fold_y)
    view:on_mouse_pressed("left", normal_x + style.padding.x, normal_y + view:get_line_height() / 2, 1)

    test.ok(view:get_collapsed_fold_at_line(4) ~= nil, "normal click should not expand a stale fold hit")
  end)

  test.it("manual fold commands use selection and indentation targets", function(context)
    local view, doc = open_editor(context, "function f()\n  one\n  two\nend\nnext", { wrapping = false })
    doc:set_selection(1, 1)

    command.perform "doc:fold-at-caret"

    test.ok(view:get_collapsed_fold_at_line(2) ~= nil, "expected indentation target to fold")
    command.perform "doc:unfold-at-caret"
    test.equal(view:get_collapsed_fold_at_line(2), nil)
    local region_count = #view.fold_regions
    command.perform "doc:fold-at-caret"
    test.equal(#view.fold_regions, region_count)
    command.perform "doc:unfold-at-caret"

    doc:set_selection(2, 1, 4, 1)
    command.perform "doc:fold-at-caret"
    local fold = view:get_collapsed_fold_at_line(2)
    test.ok(fold ~= nil, "expected explicit multi-line selection to fold")
    test.equal(fold.line1, 2)
    test.equal(fold.line2, 3)
  end)

  test.it("manual fold prefers a syntax-aware Fold Target when Tree-sitter is ready", function(context)
    local view, doc = open_editor(context, "test :: proc() {\n    os.read_entire\n}", { wrapping = false })
    doc:set_filename("fold_target.odin", "fold_target.odin")
    test.ok(wait_treesitter_ready(doc), "expected Odin Tree-sitter parse to become ready")
    doc:set_selection(1, 1)

    command.perform "doc:fold-at-caret"

    local fold = view:get_collapsed_fold_at_line(2)
    test.ok(fold ~= nil, "expected syntax-aware Fold Target to fold the procedure")
    test.equal(fold.line1, 1)
    test.equal(fold.line2, 3)
  end)

  test.it("manual fold on an indented leaf uses the nearest enclosing indentation block", function(context)
    local view, doc = open_editor(context, table.concat({
      "- Load existing purchase order data",
      "  - Aggregates by:",
      "    - company",
      "    - project",
      "    - sales partida",
      "    - purchase group",
      "  - Calculates:",
      "    - minimum order number",
    }, "\n"), { wrapping = false })
    doc:set_selection(3, 7)

    command.perform "doc:fold-at-caret"

    local fold = view:get_collapsed_fold_at_line(3)
    test.ok(fold ~= nil, "expected leaf bullet to fold the enclosing list block")
    test.equal(fold.line1, 2)
    test.equal(fold.line2, 6)
  end)

  test.it("manual fold on a code leaf uses the nearest enclosing indentation block", function(context)
    local view, doc = open_editor(context, "function f()\n  if x then\n    doThing()\n    doOther()\n  end\nend", { wrapping = false })
    doc:set_selection(3, 8)

    command.perform "doc:fold-at-caret"

    local fold = view:get_collapsed_fold_at_line(3)
    test.ok(fold ~= nil, "expected code leaf to fold the enclosing block")
    test.equal(fold.line1, 2)
    test.equal(fold.line2, 4)
  end)

  test.it("folding a parent absorbs already collapsed child folds", function(context)
    local view, doc = open_editor(context, table.concat({
      "- parent:",
      "  - child:",
      "    - leaf",
      "  - sibling:",
      "    - other",
    }, "\n"), { wrapping = false })

    doc:set_selection(1, 1)
    command.perform "doc:fold-at-caret"
    command.perform "doc:unfold-at-caret"

    doc:set_selection(3, 5)
    command.perform "doc:fold-at-caret"
    local child = view:get_collapsed_fold_at_line(3)
    test.ok(child ~= nil, "expected child fold")
    test.equal(child.line1, 2)

    doc:set_selection(1, 1)
    command.perform "doc:fold-at-caret"
    local parent = view:get_collapsed_fold_at_line(3)
    test.ok(parent ~= nil, "expected parent fold to replace child fold")
    test.equal(parent.line1, 1)
    test.equal(parent.line2, 5)
    test.equal(#view:get_collapsed_folds(), 1)
  end)

  test.it("unfold at caret expands all folded regions touched by a selection", function(context)
    local view, doc = open_editor(context, numbered_lines(10), { wrapping = false })
    view:add_fold_region { line1 = 3, line2 = 4 }
    view:add_fold_region { line1 = 7, line2 = 8 }
    doc:set_selection(2, 1, 9, 1)

    command.perform "doc:unfold-at-caret"

    test.equal(view:get_collapsed_fold_at_line(3), nil)
    test.equal(view:get_collapsed_fold_at_line(7), nil)
    test.equal(#view:get_collapsed_folds(), 0)
  end)

  test.it("fold ranges shift for edits before the fold and invalidate when touched", function(context)
    local view, doc = open_editor(context, numbered_lines(8), { wrapping = false })
    local fold = view:add_fold_region { line1 = 4, line2 = 6 }

    doc:insert(1, 1, "prefix\n")
    test.equal(fold.line1, 5)
    test.equal(fold.line2, 7)
    test.ok(view:get_collapsed_fold_at_line(6) ~= nil)

    doc:insert(6, 2, "touch")
    test.equal(view:get_collapsed_fold_at_line(6), nil)
  end)

  test.it("closing a document clears fold markers from its views", function(context)
    local view, doc = open_editor(context, numbered_lines(8), { wrapping = false })
    view:add_fold_region { line1 = 3, line2 = 5 }

    remove_doc(doc)

    test.equal(#view.fold_regions, 0)
  end)

  test.it("overlapping collapsed fold ranges are rejected", function(context)
    local view = open_editor(context, numbered_lines(8), { wrapping = false })

    local fold, err = view:add_fold_region { line1 = 2, line2 = 4 }
    local overlap, overlap_err = view:add_fold_region { line1 = 3, line2 = 6 }

    test.ok(fold ~= nil)
    test.equal(overlap, nil)
    test.ok(tostring(overlap_err):find("overlaps", 1, true) ~= nil)
  end)
end)
