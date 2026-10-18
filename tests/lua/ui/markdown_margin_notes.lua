local core = require "core"
local command = require "core.command"
local config = require "core.config"
local Editor = require "core.editor"
local keymap = require "core.keymap"
local markdown = require "core.markdown"
local margin_notes = require "core.markdown.margin_notes"
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

local function line_text(buffer, line)
  return (buffer.lines[line] or ""):gsub("\n$", "")
end

local function open_note_view(context, text, width)
  local buffer = core.open_buffer()
  buffer:set_filename("margin-notes.md", nil)
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

test.describe("Markdown margin notes", function()
  test.before_each(function(context)
    panes.reset_for_tests()
    context.live = config.markdown_live_editor
    config.markdown_live_editor = true
  end)

  test.after_each(function(context)
    if context.view then margin_notes.cancel_edit(context.view) end
    panes.reset_for_tests()
    for _, buffer in ipairs(context.buffers or {}) do
      if buffer:is_dirty() then buffer:clean() end
      for i = #core.buffers, 1, -1 do
        if core.buffers[i] == buffer then table.remove(core.buffers, i) end
      end
    end
    config.markdown_live_editor = context.live
  end)

  test.it("hides the note syntax and tints its anchor text", function(context)
    local view = open_note_view(context,
      "From {==Terrahawks==}{>>A great show<<} it went {>>aside<<}on.\n\nend")
    test.equal(visible_text(view, 1), "From Terrahawks it went on.")
    local anchor = test.not_nil(fragment_with_text(view, 1, "Terrahawks"))
    test.equal(anchor.background, style.markdown_live_margin_note_bg)
  end)

  test.it("tints every part of an anchor that contains a link", function(context)
    local view = open_note_view(context,
      "{==Tests I ran ([with my harness](https://example.com)), where I played.==}{>>note<<}\n\nend")
    for _, caret in ipairs({ { 3, 1 }, { 1, 5 } }) do
      view.buffer:set_selection(caret[1], caret[2])
      for _, text in ipairs({ "Tests I ran (", "with my harness", "), where I played." }) do
        local fragment = test.not_nil(fragment_with_text(view, 1, text), text)
        test.equal(fragment.background, style.markdown_live_margin_note_bg, text)
      end
    end
  end)

  test.it("keeps the note syntax hidden while the caret is inside it", function(context)
    local view = open_note_view(context, "From {==Terrahawks==}{>>A great show<<} it went.\n\nend")
    for _, col in ipairs({ 7, 12, 25 }) do
      view.buffer:set_selection(1, col)
      test.equal(visible_text(view, 1), "From Terrahawks it went.", "caret at column " .. col)
    end
  end)

  test.it("adds a note to the selection and saves the typed text", function(context)
    local view, buffer = open_note_view(context, "From Terrahawks it went.\n\nend")
    buffer:set_selection(1, 6, 1, 16)
    test.ok(command.perform("markdown:add_margin_note"))
    local input = test.not_nil(margin_notes.editing_input(view))
    test.equal(core.active_view, input)
    input:on_text_input("What a show")
    test.ok(command.perform("markdown:save_margin_note"))
    test.equal(line_text(buffer, 1), "From {==Terrahawks==}{>>What a show<<} it went.")
    test.equal(margin_notes.editing_input(view), nil)
    test.equal(core.active_view, view)
  end)

  test.it("anchors a new note to the word at the caret", function(context)
    local view, buffer = open_note_view(context, "From Terrahawks it went.\n\nend")
    buffer:set_selection(1, 9)
    test.ok(command.perform("markdown:add_margin_note"))
    margin_notes.editing_input(view):on_text_input("note")
    test.ok(command.perform("markdown:save_margin_note"))
    test.equal(line_text(buffer, 1), "From {==Terrahawks==}{>>note<<} it went.")
  end)

  test.it("leaves the text unchanged when a new note is cancelled", function(context)
    local view, buffer = open_note_view(context, "From Terrahawks it went.\n\nend")
    buffer:set_selection(1, 6, 1, 16)
    test.ok(command.perform("markdown:add_margin_note"))
    margin_notes.editing_input(view):on_text_input("draft")
    test.ok(command.perform("markdown:cancel_margin_note"))
    test.equal(line_text(buffer, 1), "From Terrahawks it went.")
    test.equal(core.active_view, view)
  end)

  test.it("removes a note saved empty and keeps its anchor text", function(context)
    local view, buffer = open_note_view(context,
      "From {==Terrahawks==}{>>A great show<<} it went.\n\nend")
    buffer:set_selection(1, 10)
    test.ok(command.perform("markdown:edit_margin_note"))
    local input = test.not_nil(margin_notes.editing_input(view))
    test.equal(input:get_text(), "A great show")
    input.buffer:remove(1, 1, math.huge, math.huge)
    test.ok(command.perform("markdown:save_margin_note"))
    test.equal(line_text(buffer, 1), "From Terrahawks it went.")
  end)

  test.it("keeps a note on one line when its text has line breaks", function(context)
    local view, buffer = open_note_view(context, "From {==Terrahawks==}{>>old<<} it went.\n\nend")
    buffer:set_selection(1, 10)
    test.ok(command.perform("markdown:edit_margin_note"))
    local input = margin_notes.editing_input(view)
    input:set_text("first\nsecond <<} third")
    test.ok(command.perform("markdown:save_margin_note"))
    test.equal(line_text(buffer, 1), "From {==Terrahawks==}{>>first second << } third<<} it went.")
  end)

  test.it("stacks note cards in the margin beside their anchors", function(context)
    local view = open_note_view(context,
      "One {==first==}{>>note one<<} and {==second==}{>>note two<<}.\n\nTwo {>>point<<} here.\n\nend")
    test.ok(margin_notes.column_rect(view) ~= nil)
    local layout = test.not_nil(margin_notes.layout(view))
    test.equal(#layout.cards, 3)
    test.equal(layout.mode, "margin")
    local lane_x, lane_width = core.centered_editor.get_lane_rect(view)
    for _, card in ipairs(layout.cards) do
      test.ok(card.x >= lane_x + lane_width, "card overlaps the reading lane")
    end
    local first, second = layout.cards[1], layout.cards[2]
    test.ok(first.y <= first.anchor_mid and first.y + first.h >= first.anchor_mid,
      "card is not beside its anchor line")
    test.ok(second.y >= first.y + first.h, "cards on one line overlap")
    test.equal(layout.cards[3].note.text, "point")
  end)

  test.it("keeps the text column width of a document without notes", function(context)
    local plain = open_note_view(context, "Text anchor here.\n\nend", 1000)
    plain:update()
    local plain_x, plain_width = core.centered_editor.get_lane_rect(plain)
    local view = open_note_view(context, "Text {==anchor==}{>>note<<} here.\n\nend", 1000)
    view:update()
    local lane_x, lane_width = core.centered_editor.get_lane_rect(view)
    test.equal(lane_x, plain_x)
    test.equal(lane_width, plain_width)
  end)

  test.it("shows a note inline below its block when the margin has no room", function(context)
    local view = open_note_view(context,
      "First {==anchor==}{>>note<<} line.\nSecond line.\n\nNext block.", 1000)
    view.buffer:set_selection(4, 1)
    view:update()
    test.equal(margin_notes.column_rect(view), nil)
    local layout = test.not_nil(margin_notes.layout(view))
    test.equal(layout.mode, "inline")
    local card = test.not_nil(layout.cards[1])
    local _, second_y = view:get_line_screen_position(2, 1)
    local _, blank_y = view:get_line_screen_position(3, 1)
    test.ok(card.y >= second_y + view:get_line_height(), "card overlaps its block")
    test.ok(card.y + card.h <= blank_y, "card overlaps the text below its block")
    local lane_x, lane_width = core.centered_editor.get_lane_rect(view)
    test.ok(card.x >= lane_x and card.x + card.w <= lane_x + lane_width, "card leaves the lane")
  end)

  test.it("grows an inline note as its edited text wraps", function(context)
    local view = open_note_view(context,
      "First {==anchor==}{>>note<<} line.\n\nNext block.", 1000)
    view.buffer:set_selection(1, 10)
    test.ok(command.perform("markdown:edit_margin_note"))
    local input = margin_notes.editing_input(view)
    view:update()
    test.equal(test.not_nil(margin_notes.layout(view)).mode, "inline")
    local _, next_y = view:get_line_screen_position(3, 1)
    input:on_text_input(string.rep(" more words", 30))
    input:update()
    view:update()
    local card = test.not_nil(margin_notes.layout(view)).cards[1]
    test.ok(card.editing)
    local _, grown_next_y = view:get_line_screen_position(3, 1)
    test.ok(grown_next_y > next_y, "text below the note did not move down")
    test.ok(card.y + card.h <= grown_next_y, "note card overlaps the text below")
    local end_x, end_y = input:get_line_screen_position(1, #input:get_text() + 1)
    test.ok(end_x <= card.x + card.w and end_y < card.y + card.h, "note text runs past its card")
  end)

  test.it("edits a long note in the same wrapped shape that the card shows", function(context)
    local long = "A long note that needs several rows in the margin card to show all of its words"
    local view = open_note_view(context, "From {==Terrahawks==}{>>" .. long .. "<<}.\n\nend")
    local shown = test.not_nil(margin_notes.layout(view)).cards[1]
    view.buffer:set_selection(1, 10)
    test.ok(command.perform("markdown:edit_margin_note"))
    local input = margin_notes.editing_input(view)
    input:on_text_input("")
    local edited = test.not_nil(margin_notes.layout(view)).cards[1]
    test.ok(edited.editing)
    test.equal(edited.h, shown.h)
    test.ok(input:get_total_visual_lines() > 1, "note editor does not wrap")
    local x, y = input:get_line_screen_position(1, 1)
    test.equal(x, shown.text_x)
    test.equal(y, shown.text_y)
    local row2_line, row2_col = input:get_visual_row_line_col(2)
    test.equal(input:get_line_screen_position(row2_line, row2_col), x)
    local end_x = input:get_line_screen_position(1, #long + 1)
    test.ok(end_x <= edited.x + edited.w, "note text runs past its card")
  end)

  test.it("keeps note cards clear of the expanded scrollbar", function(context)
    local view = open_note_view(context,
      "Text {==anchor==}{>>note<<}.\n" .. string.rep("\nline", 200))
    view.buffer:set_selection(1, 1)
    view.scroll.y, view.scroll.to.y = 0, 0
    view.v_scrollbar:set_forced_status("expanded")
    view:update()
    local track_x, _, track_w = view.v_scrollbar:get_track_rect()
    test.ok(track_w > 0, "expected a scrollbar track")
    local card = test.not_nil(margin_notes.layout(view)).cards[1]
    test.ok(card.x + card.w <= track_x, "note card overlaps the scrollbar")
  end)

  test.it("moves the note caret to a clicked position", function(context)
    local view = open_note_view(context, "From {==Terrahawks==}{>>A great show<<}.\n\nend")
    view.buffer:set_selection(1, 10)
    test.ok(command.perform("markdown:edit_margin_note"))
    local input = margin_notes.editing_input(view)
    view:update()
    view.__margin_note_layout = margin_notes.layout(view)
    local x, y = input:get_line_screen_position(1, 3)
    click(view, x + 1, y + 2)
    local line, col = input.buffer:get_selection()
    test.equal(line, 1)
    test.equal(col, 3)
  end)

  test.it("places the caret where the first click on a note lands", function(context)
    local view = open_note_view(context, "From {==Terrahawks==}{>>A great show<<}.\n\nend")
    view:update()
    local layout = test.not_nil(margin_notes.layout(view))
    view.__margin_note_layout = layout
    local x, y = layout.cards[1].text_view:get_line_screen_position(1, 3)
    click(view, x + 1, y + 2)
    local input = test.not_nil(margin_notes.editing_input(view))
    local line, col = input.buffer:get_selection()
    test.equal(line, 1)
    test.equal(col, 3)
  end)

  test.it("opens the editor when a card is clicked", function(context)
    local view = open_note_view(context, "From {==Terrahawks==}{>>A great show<<}.\n\nend")
    view:update()
    local layout = test.not_nil(margin_notes.layout(view))
    view.__margin_note_layout = layout
    local card = layout.cards[1]
    view:on_mouse_pressed("left", card.x + 4, card.y + 4, 1)
    local input = test.not_nil(margin_notes.editing_input(view))
    test.equal(core.active_view, input)
    test.equal(input:get_text(), "A great show")
  end)
end)
