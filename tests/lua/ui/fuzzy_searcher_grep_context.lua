local test = require "core.test"
local core = require "core"
local style = require "core.style"
local fuzzy_searcher = require "plugins.fuzzy_searcher"
local symbol_index = require "core.treesitter.symbol_index"
local symbol_icons = require "core.symbol_icons"
local file_icons = require "core.file_icons"

local helpers = fuzzy_searcher._test

test.describe("Fuzzy Searcher Text Search context", function()
  local saved

  test.before_each(function()
    saved = {
      enclosing_symbol = symbol_index.enclosing_symbol,
      draw_text = renderer.draw_text,
      draw_rect = renderer.draw_rect,
      draw_canvas = renderer.draw_canvas,
      draw_file_icon = file_icons.draw,
      draw_symbol_icon = symbol_icons.draw,
    }
  end)

  test.after_each(function()
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    symbol_index.enclosing_symbol = saved.enclosing_symbol
    renderer.draw_text = saved.draw_text
    renderer.draw_rect = saved.draw_rect
    renderer.draw_canvas = saved.draw_canvas
    file_icons.draw = saved.draw_file_icon
    symbol_icons.draw = saved.draw_symbol_icon
  end)

  test.it("draws the enclosing function without parameters at the file column edge", function()
    renderer.draw_canvas = function() end
    local calls = {}
    symbol_index.enclosing_symbol = function(path, line, col, opts)
      test.equal(path, "C:/project/src/parser.lua")
      test.equal(line, 42)
      test.equal(col, 9)
      test.same(opts.kinds, { "function", "method" })
      return {
        name = "parse_expression",
        kind = "function",
        declaration = "Parser::parse_expression(Token token)",
        declaration_name_span = { 9, 24 },
      }
    end
    renderer.draw_text = function(font, text, x, _, color)
      calls[#calls + 1] = { text = text, x = x, color = color }
      return x + font:get_width(text)
    end
    renderer.draw_rect = function() end
    file_icons.draw = function() end
    symbol_icons.draw = function() end

    helpers.draw_grep_result_row(style.font, {
      kind = "grep",
      file = "src/parser.lua",
      abs_path = "C:/project/src/parser.lua",
      line = 42,
      col = 9,
      text = "return parse_expression(token)",
      exact = true,
      grep_query = "parse_expression",
    }, 0, 0, 1400, false)

    local context_call, signature_call
    for _, call in ipairs(calls) do
      if call.text == "parse_expression" then context_call = call; break end
    end
    for _, call in ipairs(calls) do
      if call.text == "(Token token)" then signature_call = call end
    end
    test.not_nil(context_call, "expected the enclosing function name in the Text Search row")
    test.is_nil(signature_call, "did not expect function parameters in the Text Search row")
    test.equal(context_call.color, style.text)
    test.ok(context_call.x > 200, "expected the function context on the right of the file column")
  end)

  test.it("keeps only edit-time metadata in text results", function()
    local calls = {}
    renderer.draw_canvas = function() end
    symbol_index.enclosing_symbol = function() end
    renderer.draw_text = function(font, text, x)
      calls[#calls + 1] = { text = text, x = x, right = x + font:get_width(text) }
      return x + font:get_width(text)
    end
    renderer.draw_rect = function() end
    file_icons.draw = function() end
    local row = {
      kind = "grep", file = "example.lua", line = 12, col = 1,
      text = "matched content", file_size = 123456,
      file_modified = os.time() - 7200, exact = true,
    }
    local width = 2400
    helpers.draw_grep_result_row(style.font, row, 0, 0, width, false)
    local size_text = require("plugins.path_tree").format_file_size(row.file_size)
    local found_age, found_inline_match = false, false
    for _, call in ipairs(calls) do
      test.ok(call.text ~= size_text, "Text Search must not show file size metadata")
      if call.text == "2h" then found_age = true end
      if call.text == row.text then found_inline_match = true end
    end
    test.ok(found_age, "Text Search must keep edit-time metadata")
    test.ok(found_inline_match, "the match must stay in its separate inline column")
  end)

  test.it("left-aligns enclosing symbols with different label widths", function()
    local symbols = {
      [10] = {
        name = "run",
        kind = "method",
        declaration = "void Worker::run()",
        declaration_name_span = { 14, 16 },
      },
      [20] = {
        name = "render_to_image_buffer",
        kind = "method",
        declaration = "int TMessagePanel::render_to_image_buffer()",
        declaration_name_span = { 20, 41 },
      },
    }
    symbol_index.enclosing_symbol = function(_, line)
      return symbols[line]
    end
    local line_right, directory_count = nil, 0
    local picker = fuzzy_searcher.open_static_results("Text Search", {
      {
        kind = "grep", file = "src/Panel.cpp", abs_path = "C:/project/src/Panel.cpp",
        line = 10, col = 1, text = "matched content", exact = true,
      },
      {
        kind = "grep", file = "src/Command.cpp", abs_path = "C:/project/src/Command.cpp",
        line = 20, col = 1, text = "matched content", exact = true,
      },
    })
    picker.position.x, picker.position.y = 0, 0
    picker:set_size(1400, 500)
    picker.open_transition_complete = true
    picker.update_selected_preview = function() end
    picker:update()

    local original_draw_rounded_rect = renderer.draw_rounded_rect
    local original_draw_text_known_bounds = renderer.draw_text_known_bounds
    local original_set_clip_rect = renderer.set_clip_rect
    local symbol_x = {}
    symbol_icons.draw = function(_, x)
      symbol_x[#symbol_x + 1] = x
    end
    renderer.draw_text = function(font, text, x)
      if text:find(":10", 1, true) == 1 or text:find(":20", 1, true) == 1 then
        line_right = math.max(line_right or 0, x + font:get_width(text))
      end
      if text == "src/" then directory_count = directory_count + 1 end
      return x + font:get_width(text)
    end
    renderer.draw_rect = function() end
    renderer.draw_rounded_rect = function() end
    renderer.draw_text_known_bounds = function() end
    renderer.set_clip_rect = function() end
    renderer.draw_canvas = function() end
    file_icons.draw = function() end
    local ok, err = pcall(function() picker:draw() end)
    renderer.draw_rounded_rect = original_draw_rounded_rect
    renderer.draw_text_known_bounds = original_draw_text_known_bounds
    renderer.set_clip_rect = original_set_clip_rect
    if not ok then error(err, 0) end

    test.equal(#symbol_x, 2, "expected one enclosing symbol icon per row")
    test.equal(symbol_x[1], symbol_x[2],
      "enclosing symbol labels must start at one column")
    test.not_nil(line_right, "expected the file line suffix")
    local layout_slack = math.max(1, math.ceil(2 * (SCALE or 1)))
    test.ok(symbol_x[1] - line_right
        <= math.max(8 * (SCALE or 1), style.padding.x * 2) + layout_slack + 1,
      "the symbol column must start after the filename without unused space")
    test.equal(directory_count, 2, "Text Search must keep complete file paths when they fit")
  end)

  test.it("keeps grouped text rows collapsed when scrolling starts inside a file group", function()
    local results = {}
    for index = 1, 30 do
      results[#results + 1] = {
        kind = "grep", file = "src/basegame.cpp", abs_path = "C:/project/src/basegame.cpp",
        line = index == 1 and 12 or 347 + index,
        text = "match " .. tostring(index), file_size = 122 * 1024,
      }
    end
    local picker = fuzzy_searcher.open_static_results("Text Search", results)
    picker.position.x, picker.position.y = 0, 0
    picker:set_size(1200, 500)
    picker.selected = 20
    picker.viewport_offset = 20
    picker.open_transition_complete = true
    picker.update_selected_preview = function() end
    picker:refresh_static()
    picker:update()
    picker.viewport_offset = 20

    local metrics = picker:list_metrics()
    local visible = {}
    local saved_draw_text = renderer.draw_text
    local saved_draw_rect = renderer.draw_rect
    local saved_draw_rounded_rect = renderer.draw_rounded_rect
    local saved_draw_text_known_bounds = renderer.draw_text_known_bounds
    local saved_set_clip_rect = renderer.set_clip_rect
    local saved_draw_canvas = renderer.draw_canvas
    renderer.draw_text = function(font, text, x, y)
      if y >= metrics.results_top then visible[#visible + 1] = text end
      return x + font:get_width(text)
    end
    renderer.draw_rect = function() end
    renderer.draw_rounded_rect = function() end
    renderer.draw_text_known_bounds = function() end
    renderer.set_clip_rect = function() end
    renderer.draw_canvas = function() end
    local ok, err = pcall(function() picker:draw() end)
    renderer.draw_text = saved_draw_text
    renderer.draw_rect = saved_draw_rect
    renderer.draw_rounded_rect = saved_draw_rounded_rect
    renderer.draw_text_known_bounds = saved_draw_text_known_bounds
    renderer.set_clip_rect = saved_set_clip_rect
    renderer.draw_canvas = saved_draw_canvas
    if not ok then error(err, 0) end

    test.ok(#visible > 0, "expected visible text-search rows")
    for _, text in ipairs(visible) do
      test.ok(not text:find("basegame", 1, true),
        "a continuation row must not redraw the file name at the viewport top: " .. text)
    end
  end)

  test.it("keeps the full filename before an optional declaration", function()
    local calls = {}
    local symbol_x
    renderer.draw_canvas = function() end
    symbol_index.enclosing_symbol = function()
      return {
        name = "ApplyCollisionAlt",
        kind = "function",
        declaration = "CPhysical::ApplyCollisionAlt(CEntity *B, CColPoint &colpoint, float &impulse)",
        declaration_name_span = { 12, 28 },
      }
    end
    renderer.draw_text = function(font, text, x)
      calls[#calls + 1] = { font = font, text = text, x = x }
      return x + font:get_width(text)
    end
    renderer.draw_rect = function() end
    file_icons.draw = function() end
    symbol_icons.draw = function(_, x)
      symbol_x = x
    end

    helpers.draw_grep_result_row(style.font, {
      kind = "grep",
      file = "src/a/very/long/path/PhysicalCollisionManager.cpp",
      abs_path = "C:/project/src/parser.lua",
      line = 42,
      col = 9,
      text = "return parse_expression(token)",
      exact = true,
      grep_query = "parse_expression",
    }, 0, 0, 1100, false)

    local line_call
    for _, call in ipairs(calls) do
      if call.text:find(":42", 1, true) == 1 then line_call = call; break end
    end
    test.not_nil(line_call, "expected the file line suffix")
    local filename_call
    for _, call in ipairs(calls) do
      if call.text == "PhysicalCollisionManager.cpp" then filename_call = call; break end
    end
    test.not_nil(filename_call, "expected the complete filename")
    if symbol_x then
      local line_end = line_call.x + line_call.font:get_width(line_call.text)
      test.ok(
        symbol_x - line_end >= style.padding.x * 2,
        "expected two horizontal padding units before the declaration"
      )
    end
  end)
end)
