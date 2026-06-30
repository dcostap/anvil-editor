local core = require "core"
local command = require "core.command"
local config = require "core.config"
local style = require "core.style"
local test = require "core.test"

require "plugins.intellij_find"

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

local function open_editor(context, text)
  local doc = track(context, "docs", core.open_doc())
  if text and text ~= "" then doc:text_input(text) end
  local view = track(context, "views", core.root_panel:open_doc(doc))
  core.set_active_view(view)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 220, 180
  view.scroll.x, view.scroll.to.x = 0, 0
  view.scroll.y, view.scroll.to.y = 0, 0
  return view, doc
end

local function visible_text_right(view)
  local _, _, scroll_w = view.v_scrollbar:get_track_rect()
  return view.scroll.x + math.max(0, view.size.x - scroll_w)
end

local function range_x(view, line, col1, col2)
  local gw = view:get_gutter_width()
  local x1 = view:get_col_x_offset(line, col1) + gw
  local x2 = view:get_col_x_offset(line, col2) + gw
  return math.min(x1, x2), math.max(x1, x2)
end

local function numbered_lines(count)
  local lines = {}
  for i = 1, count do lines[i] = "line " .. i end
  return table.concat(lines, "\n")
end

local function disable_wrapping(view)
  view:set_wrapping_enabled(false)
  view.scroll.x, view.scroll.to.x = 0, 0
end

test.describe("DocView selection scrolling", function()
  test.before_each(function(context)
    context.scroll_past_end = config.scroll_past_end
    context.scroll_context_lines = config.scroll_context_lines
  end)

  test.after_each(function(context)
    config.scroll_past_end = context.scroll_past_end
    config.scroll_context_lines = context.scroll_context_lines
    local root = core.root_panel.root_node
    for _, view in ipairs(context.views or {}) do
      local node = root:get_node_for_view(view)
      if node then node:remove_view(root, view) end
    end
    for _, doc in ipairs(context.docs or {}) do
      if doc:is_dirty() then doc:clean() end
      remove_doc(doc)
    end
  end)

  test.it("limits scroll-past-end to the final line's scroll context boundary", function(context)
    config.scroll_past_end = true
    config.scroll_context_lines = 3

    local view, doc = open_editor(context, numbered_lines(20))
    local lh = view:get_line_height()
    test.ok(lh * #doc.lines + style.padding.y * 2 > view.size.y, "expected test document to overflow vertically")

    view.scroll.to.y = view.size.y * 10
    view:clamp_scroll_position()
    view.scroll.y = view.scroll.to.y
    view:update_scrollbar()

    test.equal(view.scroll.y, view:get_scrollable_size() - view.size.y)
    test.equal(view.v_scrollbar.percent, 1)
    local _, last_y = view:get_line_screen_position(#doc.lines)
    test.equal(last_y + lh, view.position.y + view.size.y - config.scroll_context_lines * lh)
  end)

  test.it("does not add bottom overscroll when a fitting document is already past the context boundary", function(context)
    config.scroll_past_end = true
    config.scroll_context_lines = 1

    local view = open_editor(context, "one\ntwo\nthree")
    view.scroll.to.y = view.size.y
    view:clamp_scroll_position()

    test.equal(view.scroll.to.y, 0)
  end)

  test.it("does not end-scroll short documents when existing blank space satisfies context", function(context)
    config.scroll_past_end = true
    config.scroll_context_lines = 28

    local view = open_editor(context, numbered_lines(9))
    local lh = view:get_line_height()
    view.size.y = style.padding.y * 2 + lh * 30

    view:scroll_to_make_visible(9, 1, true)

    test.equal(view.scroll.to.y, 0)
    test.equal(view.scroll.y, 0)
  end)

  test.it("allows fitting documents to end-scroll when the caret enters bottom context", function(context)
    config.scroll_past_end = true
    config.scroll_context_lines = 28

    local view = open_editor(context, numbered_lines(29))
    local lh = view:get_line_height()
    view.size.y = style.padding.y * 2 + lh * 30

    view:scroll_to_make_visible(29, 1, true)

    local effective_context = view:get_visible_scroll_context_lines()
    local _, cursor_y = view:get_line_screen_position(29)
    test.ok(view.scroll.y > 0, "expected a fitting document near the bottom context to scroll")
    test.equal(cursor_y + lh, view.position.y + view.size.y - effective_context * lh)
  end)

  test.it("keeps mouse-originated clicks near the document end from forcing bottom context scrolling", function(context)
    config.scroll_past_end = true
    config.scroll_context_lines = 3

    local view, doc = open_editor(context, numbered_lines(20))
    view:update_scrollbar()
    local lh = view:get_line_height()
    local scroll_h = view:get_horizontal_scrollbar_height()
    local target_line = #doc.lines - 1
    local start_scroll = style.padding.y + (target_line - 1) * lh - (view.size.y - scroll_h - 2 * lh)
    test.ok(start_scroll > 0, "expected the target line to require an initial scroll offset")

    view.scroll.y, view.scroll.to.y = start_scroll, start_scroll
    view.mouse_selecting = { target_line, 1, "set" }
    view:scroll_to_make_visible(target_line, 1)

    test.equal(view.scroll.to.y, start_scroll)
  end)

  test.it("scroll_to_make_visible reveals an off-screen same-line range horizontally", function(context)
    local prefix = string.rep("x", 120)
    local view = open_editor(context, prefix .. "NEEDLE\n")
    disable_wrapping(view)
    local col1 = #prefix + 1
    local col2 = col1 + #"NEEDLE"

    view:scroll_to_make_visible(1, col1, true, { line2 = 1, col2 = col2 })

    local x1, x2 = range_x(view, 1, col1, col2)
    test.ok(view.scroll.x > 0, "expected horizontal scroll to move right for an off-screen match")
    test.ok(x1 >= view.scroll.x, "expected match start to be visible after horizontal reveal")
    test.ok(x2 <= visible_text_right(view) + 1, "expected match end to be visible after horizontal reveal")
  end)

  test.it("scroll_to_make_visible resets horizontal scroll when a range fits from baseline", function(context)
    local view = open_editor(context, "start NEEDLE then more text\n")
    disable_wrapping(view)
    view.scroll.x, view.scroll.to.x = 160, 160
    local col1 = 7
    local col2 = col1 + #"NEEDLE"

    view:scroll_to_make_visible(1, col1, true, { line2 = 1, col2 = col2 })

    test.equal(view.scroll.x, 0)
    test.equal(view.scroll.to.x, 0)
  end)

  test.it("DocView Prompt Bar find navigation horizontally reveals long-line matches", function(context)
    local prefix = string.rep("x", 120)
    local view = open_editor(context, prefix .. "NEEDLE\n")
    disable_wrapping(view)
    local col1 = #prefix + 1
    local col2 = col1 + #"NEEDLE"

    test.ok(command.perform("find-replace:find"))
    core.root_panel:on_text_input("NEEDLE")

    local x1, x2 = range_x(view, 1, col1, col2)
    test.ok(view.scroll.to.x > 0, "expected local find to horizontally scroll the owning Document View")
    test.ok(x1 >= view.scroll.to.x, "expected local find match start to be visible")
    test.ok(x2 <= (view.scroll.to.x + (visible_text_right(view) - view.scroll.x)) + 1, "expected local find match end to be visible")
  end)
end)
