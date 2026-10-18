local core = require "core"
local command = require "core.command"
local config = require "core.config"
local Editor = require "core.editor"
local keymap = require "core.keymap"
local markdown = require "core.markdown"
local footnotes = require "core.markdown.footnotes"
local model = require "core.markdown.model"
local panes = require "core.panes"
local style = require "core.style"
local workers = require "core.worker_pool"
local test = require "core.test"

require "core.commands.markdown"

local function ready(instance)
  local deadline = system.get_time() + 5
  repeat
    local pool = workers.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if instance.status == "ready" then return end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  test.equal(instance.status, "ready", instance.reason)
end

local function document_text(buffer)
  return buffer:get_text(1, 1, math.huge, math.huge)
end

local function open_note_view(context, text, width)
  local buffer = core.open_buffer()
  buffer:set_filename("footnotes.md", nil)
  buffer:insert(1, 1, text)
  buffer:clear_undo_redo()
  context.buffers = context.buffers or {}
  table.insert(context.buffers, buffer)
  local view = panes.place(function() return Editor(buffer) end, { placement = "new", focus = true })
  context.view = view
  buffer:set_selection(#buffer.lines, 1)
  markdown.live_render.refresh_view(view)
  local instance = test.not_nil(model.peek(buffer))
  ready(instance)
  core.set_active_view(view)
  -- The root layout sizes Panes while the parse runs, so size the view after it.
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = width or 1400, 600
  view:update()
  return view, buffer, instance
end

local function visible_text(view, line)
  local parts = {}
  for _, fragment in ipairs(view:get_line_render(line).fragments) do
    if not fragment.hidden and not fragment.widget and fragment.text then
      parts[#parts + 1] = fragment.text
    end
  end
  return table.concat(parts)
end

-- A click as the root panel routes it to the view: an unhandled press
-- reaches the mouse bindings.
local function click(view, x, y)
  if not view:on_mouse_pressed("left", x, y, 1) then
    keymap.on_mouse_pressed("left", x, y, 1)
  end
  view:on_mouse_released("left", x, y)
end

local function fragment_with_text(view, line, text)
  for _, fragment in ipairs(view:get_line_render(line).fragments) do
    if not fragment.hidden and fragment.text == text then return fragment end
  end
end

test.describe("Markdown footnotes", function()
  test.before_each(function(context)
    panes.reset_for_tests()
    context.live = config.markdown_live_editor
    config.markdown_live_editor = true
  end)

  test.after_each(function(context)
    if context.view then footnotes.cancel_edit(context.view) end
    panes.reset_for_tests()
    for _, buffer in ipairs(context.buffers or {}) do
      if buffer:is_dirty() then buffer:clean() end
      for i = #core.buffers, 1, -1 do
        if core.buffers[i] == buffer then table.remove(core.buffers, i) end
      end
    end
    config.markdown_live_editor = context.live
  end)

  test.it("shows a reference as its small number", function(context)
    local view = open_note_view(context, "From Terrahawks[^1] it went.\n\n[^1]: A great show.\n\nend")
    test.equal(visible_text(view, 1), "From Terrahawks1 it went.")
    local number = test.not_nil(fragment_with_text(view, 1, "1"))
    test.equal(number.color, style.markdown_live_footnote)
    local body = test.not_nil(fragment_with_text(view, 1, "From Terrahawks"))
    test.ok(number.font:get_size() < body.font:get_size(), "the number is not smaller")
  end)

  test.it("hides definition lines until the caret enters them", function(context)
    local view, buffer = open_note_view(context,
      "From Terrahawks[^1] it went[^2].\n\n[^1]: A great show.\n\n[^2]: Later.\n\nend")
    -- One blank line stays between the paragraph and the next block.
    for line = 3, 6 do
      test.ok(view:is_line_hidden_by_fold(line), "line " .. line .. " shows")
    end
    for _, line in ipairs({ 1, 2, 7 }) do
      test.ok(not view:is_line_hidden_by_fold(line), "line " .. line .. " is hidden")
    end
    buffer:set_selection(3, 4)
    view:update()
    test.ok(not view:is_line_hidden_by_fold(3), "the definition at the caret stays hidden")
  end)

  test.it("shows each footnote's text in a card beside its reference", function(context)
    local view = open_note_view(context,
      "One[^1] and two[^2].\n\n[^1]: note one\n\n[^2]: note two\n\nThree[^3] here.\n\n[^3]: point\n\nend")
    test.ok(footnotes.column_rect(view) ~= nil)
    local layout = test.not_nil(footnotes.layout(view))
    test.equal(#layout.cards, 3)
    test.equal(layout.mode, "margin")
    local lane_x, lane_width = core.centered_editor.get_lane_rect(view)
    for _, card in ipairs(layout.cards) do
      test.ok(card.x >= lane_x + lane_width, "card overlaps the reading lane")
    end
    local first, second = layout.cards[1], layout.cards[2]
    test.ok(first.y <= first.reference_mid and first.y + first.h >= first.reference_mid,
      "card is not beside its reference line")
    test.ok(second.y >= first.y + first.h, "cards on one line overlap")
    test.equal(first.note.label, "1")
    test.equal(layout.cards[3].note.text, "point")
  end)

  test.it("shows no card for a reference without a definition", function(context)
    local view = open_note_view(context, "From Terrahawks[^1] it went.\n\nend")
    local layout = footnotes.layout(view)
    test.equal(layout and #layout.cards or 0, 0)
  end)

  test.it("adds a footnote after the word at the caret with its text below the paragraph", function(context)
    local view, buffer = open_note_view(context, "From Terrahawks it\nwent on.\n\nend")
    buffer:set_selection(1, 9)
    test.ok(command.perform("markdown:add_footnote"))
    local input = test.not_nil(footnotes.editing_input(view))
    test.equal(core.active_view, input)
    input:on_text_input("What a show")
    test.ok(command.perform("markdown:save_footnote"))
    test.equal(document_text(buffer),
      "From Terrahawks[^1] it\nwent on.\n\n[^1]: What a show\n\nend")
    test.equal(footnotes.editing_input(view), nil)
    test.equal(core.active_view, view)
  end)

  test.it("numbers a new footnote after the existing ones and keeps definitions in order", function(context)
    local view, buffer = open_note_view(context,
      "From Terrahawks[^1] it went on.\n\n[^1]: A great show.\n\nend")
    buffer:set_selection(1, 25)
    test.ok(command.perform("markdown:add_footnote"))
    footnotes.editing_input(view):on_text_input("Later")
    test.ok(command.perform("markdown:save_footnote"))
    test.equal(document_text(buffer),
      "From Terrahawks[^1] it went[^2] on.\n\n[^1]: A great show.\n\n[^2]: Later\n\nend")
  end)

  test.it("adds a footnote after the last word of a one-line paragraph", function(context)
    local view, buffer = open_note_view(context, "From Terrahawks it went\n\nend")
    buffer:set_selection(1, 21)
    test.ok(command.perform("markdown:add_footnote"))
    footnotes.editing_input(view):on_text_input("What a show")
    test.ok(command.perform("markdown:save_footnote"))
    test.equal(document_text(buffer), "From Terrahawks it went[^1]\n\n[^1]: What a show\n\nend")
  end)

  test.it("leaves the text unchanged when a new footnote is cancelled", function(context)
    local source = "From Terrahawks it went.\n\nend"
    local view, buffer = open_note_view(context, source)
    buffer:set_selection(1, 6, 1, 16)
    test.ok(command.perform("markdown:add_footnote"))
    footnotes.editing_input(view):on_text_input("draft")
    test.ok(command.perform("markdown:cancel_footnote"))
    test.equal(document_text(buffer), source)
    test.equal(core.active_view, view)
  end)

  test.it("adds no footnote inside code, where it would not render", function(context)
    local source = "Run `make all` now.\n\n```\nmake all\n```\n\n    indented code\n\nend"
    local view, buffer = open_note_view(context, source)
    for _, caret in ipairs({ { 1, 8 }, { 4, 3 }, { 7, 8 } }) do
      buffer:set_selection(caret[1], caret[2])
      command.perform("markdown:add_footnote")
      test.equal(footnotes.editing_input(view), nil)
      test.equal(document_text(buffer), source)
    end
    buffer:set_selection(1, 2)
    test.ok(command.perform("markdown:add_footnote"))
    test.not_nil(footnotes.editing_input(view))
  end)

  test.it("edits a footnote's text from its reference", function(context)
    local view, buffer = open_note_view(context,
      "From Terrahawks[^1] it went.\n\n[^1]: A great show.\n\nend")
    buffer:set_selection(1, 18)
    test.ok(command.perform("markdown:edit_footnote"))
    local input = test.not_nil(footnotes.editing_input(view))
    test.equal(input:get_text(), "A great show.")
    input:set_text("first\nsecond")
    test.ok(command.perform("markdown:save_footnote"))
    test.equal(document_text(buffer),
      "From Terrahawks[^1] it went.\n\n[^1]: first second\n\nend")
  end)

  test.it("keeps the footnote editor's text out of files on disk", function(context)
    local view, buffer = open_note_view(context,
      "From Terrahawks[^1] it went.\n\n[^1]: A great show.\n\nend")
    buffer:set_selection(1, 18)
    test.ok(command.perform("markdown:edit_footnote"))
    local input = footnotes.editing_input(view)
    input:on_text_input("!")
    -- A file name would make autosave write the editor's text to disk.
    test.equal(input.buffer.filename, nil)
    test.equal(input.buffer.abs_filename, nil)
    test.ok(model.is_markdown_buffer(input.buffer), "the footnote editor is not Markdown")
  end)

  test.it("removes a footnote saved empty with its definition", function(context)
    local view, buffer = open_note_view(context,
      "From Terrahawks[^1] it went.\n\n[^1]: A great show.\n\nend")
    buffer:set_selection(1, 18)
    test.ok(command.perform("markdown:edit_footnote"))
    footnotes.editing_input(view).buffer:remove(1, 1, math.huge, math.huge)
    test.ok(command.perform("markdown:save_footnote"))
    test.equal(document_text(buffer), "From Terrahawks it went.\n\nend")
  end)

  test.it("keeps the text column width of a document without footnotes", function(context)
    local plain = open_note_view(context, "Text reference here.\n\nend", 1000)
    plain:update()
    local plain_x, plain_width = core.centered_editor.get_lane_rect(plain)
    local view = open_note_view(context, "Text reference[^1] here.\n\n[^1]: note\n\nend", 1000)
    view:update()
    local lane_x, lane_width = core.centered_editor.get_lane_rect(view)
    test.equal(lane_x, plain_x)
    test.equal(lane_width, plain_width)
  end)

  test.it("shows a footnote below its block when the margin has no room", function(context)
    local view = open_note_view(context,
      "First reference[^1] line.\nSecond line.\n\n[^1]: note\n\nNext block.", 1000)
    view:update()
    test.equal(footnotes.column_rect(view), nil)
    local layout = test.not_nil(footnotes.layout(view))
    test.equal(layout.mode, "inline")
    local card = test.not_nil(layout.cards[1])
    local _, second_y = view:get_line_screen_position(2, 1)
    local _, next_y = view:get_line_screen_position(6, 1)
    test.ok(card.y >= second_y + view:get_line_height(), "card overlaps its block")
    test.ok(card.y + card.h <= next_y, "card overlaps the text below its block")
    local lane_x, lane_width = core.centered_editor.get_lane_rect(view)
    test.ok(card.x >= lane_x and card.x + card.w <= lane_x + lane_width, "card leaves the lane")
  end)

  test.it("grows an inline footnote as its edited text wraps", function(context)
    local view = open_note_view(context,
      "First reference[^1] line.\n\n[^1]: note\n\nNext block.", 1000)
    view.buffer:set_selection(1, 18)
    test.ok(command.perform("markdown:edit_footnote"))
    local input = footnotes.editing_input(view)
    view:update()
    test.equal(test.not_nil(footnotes.layout(view)).mode, "inline")
    local _, next_y = view:get_line_screen_position(5, 1)
    input:on_text_input(string.rep(" more words", 30))
    input:update()
    view:update()
    local card = test.not_nil(footnotes.layout(view)).cards[1]
    test.ok(card.editing)
    local _, grown_next_y = view:get_line_screen_position(5, 1)
    test.ok(grown_next_y > next_y, "text below the footnote did not move down")
    test.ok(card.y + card.h <= grown_next_y, "footnote card overlaps the text below")
    local end_x, end_y = input:get_line_screen_position(1, #input:get_text() + 1)
    test.ok(end_x <= card.x + card.w and end_y < card.y + card.h, "footnote text runs past its card")
  end)

  test.it("edits a long footnote in the same wrapped shape that the card shows", function(context)
    local long = "A long footnote that needs several rows in the margin card to show all of its words"
    local view = open_note_view(context, "From Terrahawks[^1].\n\n[^1]: " .. long .. "\n\nend")
    local shown = test.not_nil(footnotes.layout(view)).cards[1]
    view.buffer:set_selection(1, 18)
    test.ok(command.perform("markdown:edit_footnote"))
    local input = footnotes.editing_input(view)
    input:on_text_input("")
    local edited = test.not_nil(footnotes.layout(view)).cards[1]
    test.ok(edited.editing)
    test.equal(edited.h, shown.h)
    test.ok(input:get_total_visual_lines() > 1, "footnote editor does not wrap")
    local x, y = input:get_line_screen_position(1, 1)
    test.equal(x, shown.text_x)
    test.equal(y, shown.text_y)
    local row2_line, row2_col = input:get_visual_row_line_col(2)
    test.equal(input:get_line_screen_position(row2_line, row2_col), x)
    local end_x = input:get_line_screen_position(1, #long + 1)
    test.ok(end_x <= edited.x + edited.w, "footnote text runs past its card")
  end)

  test.it("keeps footnote cards clear of the expanded scrollbar", function(context)
    local view = open_note_view(context,
      "Text reference[^1].\n\n[^1]: note\n" .. string.rep("\nline", 200))
    view.buffer:set_selection(1, 1)
    view.scroll.y, view.scroll.to.y = 0, 0
    view.v_scrollbar:set_forced_status("expanded")
    view:update()
    local track_x, _, track_w = view.v_scrollbar:get_track_rect()
    test.ok(track_w > 0, "expected a scrollbar track")
    local card = test.not_nil(footnotes.layout(view)).cards[1]
    test.ok(card.x + card.w <= track_x, "footnote card overlaps the scrollbar")
  end)

  test.it("moves the footnote caret to a clicked position", function(context)
    local view = open_note_view(context, "From Terrahawks[^1].\n\n[^1]: A great show\n\nend")
    view.buffer:set_selection(1, 18)
    test.ok(command.perform("markdown:edit_footnote"))
    local input = footnotes.editing_input(view)
    view:update()
    view.__footnote_layout = footnotes.layout(view)
    local x, y = input:get_line_screen_position(1, 3)
    click(view, x + 1, y + 2)
    local line, col = input.buffer:get_selection()
    test.equal(line, 1)
    test.equal(col, 3)
  end)

  test.it("places the caret where the first click on a card lands", function(context)
    local view = open_note_view(context, "From Terrahawks[^1].\n\n[^1]: A great show\n\nend")
    view:update()
    local layout = test.not_nil(footnotes.layout(view))
    view.__footnote_layout = layout
    local x, y = layout.cards[1].text_view:get_line_screen_position(1, 3)
    click(view, x + 1, y + 2)
    local input = test.not_nil(footnotes.editing_input(view))
    test.equal(core.active_view, input)
    test.equal(input:get_text(), "A great show")
    local line, col = input.buffer:get_selection()
    test.equal(line, 1)
    test.equal(col, 3)
  end)

  test.it("shows inline Markdown in a footnote card without its syntax", function(context)
    local view = open_note_view(context,
      "From Terrahawks[^1].\n\n[^1]: A **great** show with `code` and [site](https://example.com)\n\nend")
    local card = test.not_nil(footnotes.layout(view)).cards[1]
    local text_view = card.text_view
    test.equal(visible_text(text_view, 1), "A great show with code and site")
    local strong = test.not_nil(fragment_with_text(text_view, 1, "great"))
    test.ok(strong.font ~= text_view:get_font(), "bold text uses the body font")
    local code = test.not_nil(fragment_with_text(text_view, 1, "code"))
    test.equal(code.background, style.markdown_live_inline_code_bg)
    local link = test.not_nil(fragment_with_text(text_view, 1, "site"))
    test.equal(link.color, style.markdown_live_link)
  end)

  test.it("reveals a footnote's Markdown syntax around the caret while editing", function(context)
    local view = open_note_view(context, "From Terrahawks[^1].\n\n[^1]: A **great** show\n\nend")
    view.buffer:set_selection(1, 18)
    test.ok(command.perform("markdown:edit_footnote"))
    local input = footnotes.editing_input(view)
    input.buffer:set_selection(1, 6)
    test.equal(visible_text(input, 1), "A **great** show")
    input.buffer:set_selection(1, #input:get_text() + 1)
    test.equal(visible_text(input, 1), "A great show")
  end)
end)
