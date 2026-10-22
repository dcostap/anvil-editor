local test = require "core.test"

-- `renderer.wrap_fragment_lines` wraps rendered lines. Each fragment is one
-- record of 7 numbers: kind, source_col1, source_col2, width, text_x_offset,
-- text_source_col1, text_source_col2. A label without text columns has 0 for them.
local TEXT, HIDDEN, WIDGET = 0, 1, 2

local font = renderer.font.load(DATADIR .. "/fonts/JetBrainsMono-Regular.ttf", 14 * SCALE)
local cell = font:get_width("a")

local function text(col1, value, opts)
  opts = opts or {}
  local layout = font:text_layout(value, { tab_offset = opts.tab_offset or 0 })
  return {
    kind = TEXT, col1 = col1, col2 = opts.col2 or col1 + #value,
    width = opts.width or layout:width(), layout = layout,
    text_col1 = opts.text_col1, text_col2 = opts.text_col2,
  }
end

local function hidden(col1, col2)
  return { kind = HIDDEN, col1 = col1, col2 = col2, width = 0 }
end

local function widget(col1, col2, width)
  return { kind = WIDGET, col1 = col1, col2 = col2, width = width }
end

local function line(source, fragments, opts)
  opts = opts or {}
  local records, layouts = {}, {}
  for index, fragment in ipairs(fragments) do
    for _, value in ipairs {
      fragment.kind, fragment.col1, fragment.col2, fragment.width, 0,
      fragment.text_col1 or 0, fragment.text_col2 or 0,
    } do records[#records + 1] = value end
    layouts[index] = fragment.layout or false
  end
  return {
    text = source, start_col = opts.start_col or 1,
    x_offset = opts.x_offset or 0, begin_width = opts.begin_width or 0,
    fragments = records, layouts = layouts,
  }
end

local function wrap(source, fragments, width, mode, opts)
  return renderer.wrap_fragment_lines({ line(source, fragments, opts) }, width, mode)[1]
end

test.describe("Native fragment wrapping", function()
  test.it("gives hidden source no width", function()
    -- Visible text: "bold text".
    local source = "**bold** text"
    test.same(wrap(source, {
      hidden(1, 3), text(3, "bold"), hidden(7, 9), text(9, " text"),
    }, cell * 6, "word"), { 1, 10 })
  end)

  test.it("measures remapped text by its displayed width", function()
    -- Each "&amp;" shows as "&", so the third one does not fit 2 cells.
    local source = "&amp;&amp;&amp;"
    test.same(wrap(source, {
      text(1, "&", { col2 = 6 }), text(6, "&", { col2 = 11 }), text(11, "&", { col2 = 16 }),
    }, cell * 2, "letter"), { 1, 11 })
  end)

  test.it("measures a label by its text inside the source span", function()
    -- "[ab](u) cd" shows as "ab cd". "cd" does not fit 4 cells.
    local source = "[ab](u) cd"
    test.same(wrap(source, {
      text(1, "ab", { col2 = 8, text_col1 = 2, text_col2 = 4 }), text(8, " cd"),
    }, cell * 4, "word"), { 1, 9 })
  end)

  test.it("gives a widget its fixed width", function()
    -- "[ ]" shows as a widget of 2 cells: "☐ task item".
    local source = "[ ] task item"
    test.same(wrap(source, {
      widget(1, 4, cell * 2), text(4, " task item"),
    }, cell * 6, "word"), { 1, 5, 10 })
  end)

  test.it("measures a tab to the next tab stop", function()
    font:set_tab_size(4)
    local source = "\tab cd"
    -- The tab is 4 cells, so "\tab " fills 7 cells and "cd" wraps.
    test.same(wrap(source, { text(1, source) }, cell * 7, "word"), { 1, 5 })
  end)

  test.it("breaks a word that is wider than the row", function()
    local source = "abcdefgh ij"
    test.same(wrap(source, { text(1, source) }, cell * 3, "word"), { 1, 4, 7, 10 })
  end)

  test.it("finds word-wrap opportunities across fragment boundaries", function()
    -- A comma at the end of a fragment is an opportunity.
    test.same(wrap("alpha,beta,gamma", {
      text(1, "alpha,"), text(7, "beta,"), text(12, "gamma"),
    }, cell * 7, "word"), { 1, 7, 12 })
    -- A decimal point between digits in other fragments is not.
    test.same(wrap("12.34567", {
      text(1, "12"), text(3, "."), text(4, "34567"),
    }, cell * 4, "word"), { 1, 5 })
    -- A delimiter that does not fit starts the next row.
    test.same(wrap("aaa,bbb", {
      text(1, "aaa"), text(4, ","), text(5, "bbb"),
    }, cell * 3, "word"), { 1, 4, 7 })
  end)

  test.it("wraps many lines in one call", function()
    local first = "aaaa bbbb cccc"
    local second = "dd"
    local result = renderer.wrap_fragment_lines({
      -- Start after the first row. The continuation indent is 2 cells.
      line(first, { text(1, first) }, { start_col = 6, begin_width = cell * 2 }),
      line(second .. "\n", { text(1, second) }),
    }, cell * 7, "word")
    test.same(result, { { 6, 11 }, { 1 } })
  end)
end)
