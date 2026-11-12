local core = require "core"
local config = require "core.config"
local style = require "core.style"
local test = require "core.test"
local diffview = require "plugins.diffview"

local function ready(view)
  local deadline = system.get_time() + 3
  while view.updater_idx do
    test.ok(system.get_time() < deadline, "comparison did not finish")
    coroutine.yield(0.01)
  end
  view:update()
  view:update()
end

local function lines(prefix, count)
  local out = {}
  for i = 1, count do out[i] = prefix .. " " .. i end
  return table.concat(out, "\n") .. "\n"
end

local function open(context, before, after, notes)
  local view = diffview.open({
    contents = { diffview.content.text(before), diffview.content.text(after) },
    auto_reveal_first_change = false,
    notes = notes,
  }, true)
  context.view = view
  view.size.x, view.size.y = 1000, 2000
  ready(view)
  return view
end

local function line_y(surface, line)
  local _, y = surface:get_line_screen_position(line, 1)
  return y
end

-- Draw a surface and return the text and the card colours that it drew.
local function drawn(surface)
  local saved, texts, cards = {}, {}, {}
  for _, name in ipairs { "draw_rect", "draw_rect_grid", "draw_poly", "set_clip_rect", "draw_text_known_bounds" } do
    saved[name] = renderer[name]
    renderer[name] = function() end
  end
  saved.draw_text, saved.draw_rounded_rect = renderer.draw_text, renderer.draw_rounded_rect
  renderer.draw_text = function(font, text, x, ...)
    texts[#texts + 1] = text
    return x + font:get_width(text)
  end
  renderer.draw_rounded_rect = function(_, _, _, _, _, color) cards[#cards + 1] = color end
  local ok, err = pcall(function() surface:draw() end)
  for name, fn in pairs(saved) do renderer[name] = fn end
  if not ok then error(err, 0) end
  return table.concat(texts, "\n"), cards
end

test.describe("Diff Notes", function()
  test.before_each(function(context)
    context.layout = config.plugins.diffview.layout
    context.active_view = core.active_view
  end)

  test.after_each(function(context)
    config.plugins.diffview.layout = context.layout
    if context.restore then context.restore() end
    if context.view then context.view:on_close() end
    core.active_view = context.active_view
  end)

  test.it("shows a card below the noted line and keeps both sides level", function(context)
    config.plugins.diffview.layout = "side_by_side"
    local view = open(context, "one\ntwo\nthree\nfour\n", "one\ntwo\nthree changed\nfour\n",
      { { side = 2, line = 2, text = "Keeps the **save ID**" } })
    local a, b = view.buffer_view_a, view.buffer_view_b
    local height = b:get_line_height()
    test.ok(line_y(b, 3) - line_y(b, 2) > height * 2, "the card takes space below line 2")
    test.equal(line_y(a, 3), line_y(b, 3))
    test.equal(line_y(a, 4), line_y(b, 4))
    local text, cards = drawn(b)
    test.ok(text:find("Keeps the", 1, true), "the card shows the note text")
    test.ok(text:find("save ID", 1, true), "the card shows the note's formatted text")
    local card = false
    for _, color in ipairs(cards) do card = card or color == style.markdown_footnote_card_bg end
    test.ok(card, "the card uses the Footnote card colour")
  end)

  test.it("keeps the other side level when the note is on an added line", function(context)
    config.plugins.diffview.layout = "side_by_side"
    local before, after = "one\nfour\n", "one\ntwo\nthree\nfour\n"
    local plain = open(context, before, after)
    local offset = line_y(plain.buffer_view_b, 4) - line_y(plain.buffer_view_a, 2)
    plain:on_close()
    local view = open(context, before, after, { { side = 2, line = 2, end_line = 3, text = "New lines" } })
    local a, b = view.buffer_view_a, view.buffer_view_b
    test.ok(line_y(b, 4) - line_y(b, 3) > b:get_line_height() * 2, "the card follows the range's last line")
    test.equal(line_y(b, 4) - line_y(a, 2), offset)
  end)

  test.it("never folds noted unchanged lines", function(context)
    config.plugins.diffview.layout = "side_by_side"
    local fold_default = config.plugins.diffview.fold_unchanged_by_default
    config.plugins.diffview.fold_unchanged_by_default = true
    context.restore = function() config.plugins.diffview.fold_unchanged_by_default = fold_default end
    local body = lines("same", 80)
    local view = open(context, "old\n" .. body .. "old\n", "new\n" .. body .. "new\n",
      { { side = 1, line = 41, text = "Unchanged, but read this" } })
    test.ok(view.buffer_view_b:is_line_hidden_by_fold(20), "other unchanged lines still fold")
    test.ok(not view.buffer_view_a:is_line_hidden_by_fold(41), "the noted line stays shown")
    test.ok(not view.buffer_view_b:is_line_hidden_by_fold(41), "the other side shows the same line")
    test.equal(line_y(view.buffer_view_a, 42), line_y(view.buffer_view_b, 42))
  end)

  test.it("shows a note on a removed line below that line in the Unified Diff", function(context)
    config.plugins.diffview.layout = "unified"
    local view = open(context, "one\ngone 1\ngone 2\nfour\n", "one\nfour\n",
      { { side = 1, line = 2, text = "Removed on purpose" } })
    local surface = view:get_focus_view()
    local _, y1 = surface:get_source_screen_position(1, 2)
    local _, y2 = surface:get_source_screen_position(1, 3)
    test.ok(y2 - y1 > surface:get_line_height() * 2, "the card sits between the removed lines")
    test.ok(drawn(surface):find("Removed on purpose", 1, true), "the card shows the note text")
  end)

  test.it("moves the note with edits to its side", function(context)
    config.plugins.diffview.layout = "side_by_side"
    local note = { side = 2, line = 2, text = "Follows its line" }
    local view = open(context, "one\ntwo\nthree\n", "one\ntwo\nthree\n", { note })
    view.buffer_view_b.buffer:insert(1, 1, "inserted\n")
    ready(view)
    test.equal(note.line, 3)
    test.ok(line_y(view.buffer_view_b, 4) - line_y(view.buffer_view_b, 3) > view.buffer_view_b:get_line_height() * 2,
      "the card follows the moved line")
  end)
end)
