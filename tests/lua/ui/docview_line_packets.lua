local command = require "core.command"
local config = require "core.config"
local core = require "core"
local Doc = require "core.doc"
local DocView = require "core.docview"
local linewrapping = require "core.linewrapping"
local line_packets = require "core.docview_line_packets"
local style = require "core.style"
local test = require "core.test"
local tokenizer = require "core.tokenizer"

local drawwhitespace = require "plugins.drawwhitespace"
local indent_guides = require "plugins.indent_guides"
local function packet_window()
  return core.window
end

local function set_text(doc, text)
  doc.lines = {}
  for line in (text .. "\n"):gmatch("(.-\n)") do
    doc.lines[#doc.lines + 1] = line
  end
  if #doc.lines == 0 then doc.lines[1] = "\n" end
  doc:clear_undo_redo()
  doc:clean()
  doc:set_selection(1, 1)
end

local function new_view(context, text)
  local doc = Doc()
  set_text(doc, text or "")
  local view = DocView(doc)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 1000, 1000
  context.docs[#context.docs + 1] = doc
  context.views[#context.views + 1] = view
  return doc, view
end

local function round(value)
  return math.floor(value * 1000 + 0.5) / 1000
end

local function color_name(color)
  if color == style.whitespace then return "whitespace" end
  if color == style.whitespace_trailing then return "whitespace_trailing" end
  if color == style.indent_guide then return "indent_guide" end
  if color == style.indent_guide_active then return "indent_guide_active" end
  if color == style.syntax.keyword then return "keyword" end
  if color == style.syntax.string then return "string" end
  if color == style.syntax.number then return "number" end
  if color == style.syntax.normal then return "normal" end
  return "other"
end

local function capture_operations(view, origin_x, origin_y, draw)
  local operations = {}
  local default_font = view:get_font()
  local syntax_font = style.syntax_fonts.__line_packet_fixture
  local old_draw_text = renderer.draw_text
  local old_draw_text_known_bounds = renderer.draw_text_known_bounds
  local old_draw_rect = renderer.draw_rect
  local old_draw_rect_grid = renderer.draw_rect_grid
  local old_set_clip_rect = renderer.set_clip_rect

  local function font_name(font)
    if font == default_font then return "default" end
    if font == syntax_font then return "syntax" end
    return "derived"
  end

  renderer.draw_text = function(font, text, x, y, color, opts)
    local advance = font:get_width(tostring(text), opts)
    operations[#operations + 1] = {
      kind = "text",
      text = tostring(text),
      font = font_name(font),
      color = color_name(color),
      x = round(x - origin_x),
      y = round((y or origin_y) - origin_y),
      advance = round(advance),
      tab_offset = opts and opts.tab_offset and round(opts.tab_offset) or nil,
    }
    return x + advance
  end

  renderer.draw_text_known_bounds = function(
    font, text, x, y, bounds_x, bounds_y, width, height, color, opts
  )
    operations[#operations + 1] = {
      kind = "text_known_bounds",
      text = tostring(text),
      font = font_name(font),
      color = color_name(color),
      x = round(x - origin_x),
      y = round(y - origin_y),
      bounds_x = round(bounds_x - origin_x),
      bounds_y = round(bounds_y - origin_y),
      width = round(width),
      height = round(height),
      advance = round(font:get_width(tostring(text), opts)),
      tab_offset = opts and opts.tab_offset and round(opts.tab_offset) or nil,
    }
    return x + font:get_width(tostring(text), opts)
  end

  renderer.draw_rect = function(x, y, width, height, color)
    operations[#operations + 1] = {
      kind = "rect",
      color = color_name(color),
      x = round(x - origin_x),
      y = round(y - origin_y),
      width = round(width),
      height = round(height),
    }
  end

  renderer.draw_rect_grid = function(x, y, step_x, width, height, count, color)
    operations[#operations + 1] = {
      kind = "rect_grid",
      color = color_name(color),
      x = round(x - origin_x),
      y = round(y - origin_y),
      step_x = round(step_x),
      width = round(width),
      height = round(height),
      count = count,
    }
  end

  renderer.set_clip_rect = function() end
  local ok, err = pcall(draw)
  renderer.draw_text = old_draw_text
  renderer.draw_text_known_bounds = old_draw_text_known_bounds
  renderer.draw_rect = old_draw_rect
  renderer.draw_rect_grid = old_draw_rect_grid
  renderer.set_clip_rect = old_set_clip_rect
  if not ok then error(err, 0) end
  return operations
end

local function source_operations(operations)
  local result = {}
  for _, op in ipairs(operations) do
    if op.kind:find("text", 1, true)
    and (op.color == "normal" or op.color == "keyword"
      or op.color == "string" or op.color == "number") then
      result[#result + 1] = op
    end
  end
  return result
end

local function contributor_operations(operations, contributor)
  local result = {}
  for _, op in ipairs(operations) do
    if contributor == "whitespace" then
      if op.color == "whitespace" or op.color == "whitespace_trailing" then
        result[#result + 1] = op
      end
    elseif op.color == "indent_guide" or op.color == "indent_guide_active" then
      result[#result + 1] = op
    end
  end
  return result
end

local function configure_tokens(doc, tokens)
  local line = { text = doc.lines[1], tokens = tokens, source = "line-packet-fixture" }
  doc.highlighter.get_line = function() return line end
  doc.highlighter.get_render_line = function() return line end
end

local function configure_wrapping(view, width_cells, options)
  local cfg = config.plugins.linewrapping
  options = options or {}
  cfg.mode = options.mode or "letter"
  cfg.indent = options.indent or false
  cfg.wrapping_indent = options.wrapping_indent or 0
  cfg.guide = false
  cfg.require_tokenization = options.require_tokenization or false
  cfg.width_override = view:get_font():get_width(string.rep("x", width_cells))
  view:set_wrapping_enabled(true)
  linewrapping.update_docview_breaks(view)
end

local function draw_line_text_operations(view, line)
  local x, y = view:get_line_screen_position(line)
  return capture_operations(view, x, y, function()
    view:draw_line_text(line, x, y)
  end), x, y
end

local function draw_packet_line(window, view, line)
  local x, y = view:get_line_screen_position(line)
  local old_frame_active = core.render_frame_active
  core.render_frame_id = (core.render_frame_id or 0) + 1
  core.render_frame_active = true
  renderer.begin_frame(window)
  renderer.set_clip_rect(0, 0, 500, 300)
  view:draw_line_body(line, x, y)
  renderer.end_frame()
  core.render_frame_active = old_frame_active
end

test.describe("Document View line display packet parity baseline", function()
  test.before_each(function(context)
    context.docs = {}
    context.views = {}
    local cfg = config.plugins.linewrapping
    context.wrapping = {
      mode = cfg.mode,
      indent = cfg.indent,
      wrapping_indent = cfg.wrapping_indent,
      guide = cfg.guide,
      require_tokenization = cfg.require_tokenization,
    }
    context.wrapping_width_override = cfg.width_override
    context.syntax_font = style.syntax_fonts.__line_packet_fixture
    context.clip_rect_stack = core.clip_rect_stack
    context.draw_whitespace_enabled = command.get_status("draw-whitespace:toggle")
    context.draw_whitespace_selected_only = drawwhitespace.show_selected_only
    context.indent_guides_highlight_active = indent_guides.highlight_active
    context.line_height = config.line_height
    command.perform("draw-whitespace:toggle", false)
  end)

  test.after_each(function(context)
    command.perform(
      "draw-whitespace:toggle", context.draw_whitespace_enabled ~= false
    )
    drawwhitespace.show_selected_only = context.draw_whitespace_selected_only
    indent_guides.highlight_active = context.indent_guides_highlight_active
    config.line_height = context.line_height
    local cfg = config.plugins.linewrapping
    for key, value in pairs(context.wrapping) do cfg[key] = value end
    cfg.width_override = context.wrapping_width_override
    style.syntax_fonts.__line_packet_fixture = context.syntax_font
    core.clip_rect_stack = context.clip_rect_stack
    for _, view in ipairs(context.views) do line_packets.clear(view) end
    for _, doc in ipairs(context.docs) do doc:on_close() end
  end)

  test.it("captures token and Wrapped Visual Row boundaries from the legacy path", function(context)
    local fixtures = {
      {
        name = "one token",
        text = "abcdefgh",
        tokens = { "normal", "abcdefgh\n" },
        expected = {
          { text = "abcd", color = "normal", row = 0 },
          { text = "efgh\n", color = "normal", row = 1 },
        },
      },
      {
        name = "several syntax colors",
        text = "ab12xy",
        tokens = {
          "normal", "ab", "number", "12", "string", "xy\n",
        },
        width = 8,
        expected = {
          { text = "ab", color = "normal", row = 0 },
          { text = "12", color = "number", row = 0 },
          { text = "xy\n", color = "string", row = 0 },
        },
      },
      {
        name = "token boundary at wrap",
        text = "abcdEFGH",
        tokens = { "normal", "abcd", "keyword", "EFGH\n" },
        expected = {
          { text = "abcd", color = "normal", row = 0 },
          { text = "EFGH\n", color = "keyword", row = 1 },
        },
      },
      {
        name = "token spanning wrap",
        text = "abcdefGH",
        tokens = { "normal", "abcdef", "keyword", "GH\n" },
        expected = {
          { text = "abcd", color = "normal", row = 0 },
          { text = "ef", color = "normal", row = 1 },
          { text = "GH\n", color = "keyword", row = 1 },
        },
      },
    }

    for _, fixture in ipairs(fixtures) do
      local doc, view = new_view(context, fixture.text)
      configure_tokens(doc, fixture.tokens)
      configure_wrapping(view, fixture.width or 4)
      local operations = source_operations(draw_line_text_operations(view, 1))
      test.equal(#operations, #fixture.expected, fixture.name)
      local line_height = view:get_line_height()
      local text_y = operations[1].y
      for i, expected in ipairs(fixture.expected) do
        local op = operations[i]
        test.equal(op.text, expected.text, fixture.name)
        test.equal(op.color, expected.color, fixture.name)
        test.equal(op.y, round(text_y + expected.row * line_height), fixture.name)
      end
    end
  end)

  test.it("captures tabs, UTF-8, ligatures, syntax Fonts, and continuation indentation", function(context)
    local function captured_text(text, tokens, width, options)
      local doc, view = new_view(context, text)
      configure_tokens(doc, tokens)
      configure_wrapping(view, width, options)
      return source_operations(draw_line_text_operations(view, 1)), view
    end

    local tab_ops, tab_view = captured_text(
      "a\tb\tcd", { "normal", "a\tb\tcd\n" }, 4
    )
    local tab_text = {}
    for _, op in ipairs(tab_ops) do tab_text[#tab_text + 1] = op.text end
    test.equal(table.concat(tab_text), "a\tb\tcd\n")
    local tab_first_y = tab_ops[1].y
    for i, op in ipairs(tab_ops) do
      if op.text:find("\t", 1, true) then
        test.equal(op.kind, "text", "tabs require renderer measurement")
      end
      test.equal(op.x, 0, "each non-indented tabbed row starts at the line origin")
      test.equal(op.y, round(tab_first_y + (i - 1) * tab_view:get_line_height()))
      test.ok(op.advance >= 0)
    end

    local utf8_ops, utf8_view = captured_text(
      "éλ漢字", { "normal", "éλ漢字\n" }, 3
    )
    local utf8_text = {}
    for _, op in ipairs(utf8_ops) do utf8_text[#utf8_text + 1] = op.text end
    test.equal(table.concat(utf8_text), "éλ漢字\n")
    local utf8_first_y = utf8_ops[1].y
    for i, op in ipairs(utf8_ops) do
      local ok = pcall(function() return op.text:ulen(nil, nil, true) end)
      test.ok(ok, "expected every wrapped UTF-8 segment to end on a codepoint boundary")
      test.equal(op.kind, "text")
      test.equal(op.x, 0)
      test.equal(op.y, round(utf8_first_y + (i - 1) * utf8_view:get_line_height()))
    end

    local ligature_ops = captured_text(
      "office->affine", { "normal", "office->affine\n" }, 40
    )
    test.equal(#ligature_ops, 1)
    test.equal(ligature_ops[1].kind, "text")
    test.equal(ligature_ops[1].x, 0)

    local doc, syntax_view = new_view(context, "abCD")
    local default_font = syntax_view:get_font()
    style.syntax_fonts.__line_packet_fixture = default_font:copy(default_font:get_size())
    configure_tokens(doc, {
      "normal", "ab", "__line_packet_fixture", "CD\n",
    })
    configure_wrapping(syntax_view, 8)
    local syntax_ops = source_operations(draw_line_text_operations(syntax_view, 1))
    test.equal(syntax_ops[1].font, "default")
    test.equal(syntax_ops[2].font, "syntax")
    test.equal(syntax_ops[1].text, "ab")
    test.equal(syntax_ops[2].text, "CD\n")
    test.equal(syntax_ops[1].x, 0)
    test.equal(syntax_ops[2].x, syntax_ops[1].advance)
    test.equal(syntax_ops[1].y, syntax_ops[2].y)

    local indent_ops, indent_view = captured_text(
      "  abcdefghijkl",
      { "normal", "  abcdefghijkl\n" },
      6,
      { indent = true, wrapping_indent = 2 }
    )
    local first_row_y = round(indent_view:get_line_text_y_offset())
    local continuation_x
    for _, op in ipairs(indent_ops) do
      if op.y > first_row_y then
        continuation_x = op.x
        break
      end
    end
    test.equal(
      continuation_x,
      round(indent_view.wrapped_line_offsets[1]),
      "expected continuation-row source text to retain its exact indentation offset"
    )

    local tokenized_doc, tokenized_view = new_view(context, "aaWWWW")
    local tokenized_default = tokenized_view:get_font()
    style.syntax_fonts.__line_packet_fixture = tokenized_default:copy(
      tokenized_default:get_size() * 1.5
    )
    configure_tokens(tokenized_doc, {
      "normal", "aa", "__line_packet_fixture", "WWWW\n",
    })
    configure_wrapping(tokenized_view, 4, { require_tokenization = true })
    local tokenized_rows = linewrapping.get_wrapped_line_count(tokenized_view, 1)

    local plain_doc, plain_view = new_view(context, "aaWWWW")
    configure_tokens(plain_doc, {
      "normal", "aa", "__line_packet_fixture", "WWWW\n",
    })
    configure_wrapping(plain_view, 4, { require_tokenization = false })
    local plain_rows = linewrapping.get_wrapped_line_count(plain_view, 1)
    test.ok(tokenized_rows > plain_rows,
      "expected syntax Font metrics to participate in tokenization-dependent wrapping")
  end)

  test.it("captures whitespace classification and ordering from the legacy contributor", function(context)
    command.perform("draw-whitespace:toggle", true)
    local text = "  aa  \t"
    local doc, view = new_view(context, text)
    configure_tokens(doc, { "normal", text .. "\n" })
    configure_wrapping(view, 20)

    local operations = draw_line_text_operations(view, 1)
    local whitespace = contributor_operations(operations, "whitespace")
    local source = source_operations(operations)
    test.ok(#whitespace >= 3, "expected leading, middle, and trailing marker commands")
    test.ok(#source > 0, "expected source text after whitespace markers")

    local saw_normal, saw_trailing = false, false
    local first_source_index
    for i, op in ipairs(operations) do
      if op.color == "whitespace" then saw_normal = true end
      if op.color == "whitespace_trailing" then saw_trailing = true end
      if not first_source_index and (op.color == "normal" or op.color == "keyword"
        or op.color == "string" or op.color == "number") then
        first_source_index = i
      end
    end
    test.ok(saw_normal, "expected leading/middle marker color")
    test.ok(saw_trailing, "expected trailing marker color")
    for i, op in ipairs(operations) do
      if op.color == "whitespace" or op.color == "whitespace_trailing" then
        test.ok(i < first_source_index, "expected whitespace commands before source text")
      end
    end

    local wrapped_doc, wrapped_view = new_view(context, string.rep(" ", 20) .. "tail")
    configure_tokens(wrapped_doc, {
      "normal", string.rep(" ", 20) .. "tail\n",
    })
    configure_wrapping(wrapped_view, 6, { indent = false })
    local wrapped_whitespace = contributor_operations(
      draw_line_text_operations(wrapped_view, 1), "whitespace"
    )
    local rows = {}
    for _, op in ipairs(wrapped_whitespace) do rows[op.y] = true end
    local row_count = 0
    for _ in pairs(rows) do row_count = row_count + 1 end
    test.ok(row_count > 1, "expected marker commands on multiple Wrapped Visual Rows")
  end)

  test.it("captures blank-line Indent Guides and horizontal contributor clipping", function(context)
    command.perform("draw-whitespace:toggle", true)
    local doc, view = new_view(context, "    open\n        \n        close")
    view.size.x = view:get_font():get_width(string.rep("x", 40))
    local x, y = view:get_line_screen_position(2)
    local operations = capture_operations(view, x, y, function()
      view:draw_line_body(2, x, y)
    end)
    local guides = contributor_operations(operations, "indent_guides")
    test.ok(#guides > 0, "expected effective indentation to draw guides on a blank line")
    test.equal(guides[#guides].kind, "rect_grid")
    test.equal(guides[#guides].y, 0)
    test.equal(guides[#guides].height, round(view:get_line_height()))

    local clipped_doc, clipped_view = new_view(
      context, string.rep(" ", 120) .. "x"
    )
    local clipped_x, clipped_y = clipped_view:get_line_screen_position(1)
    local cell = clipped_view:get_font():get_width(" ")
    local clip_left = clipped_x + cell * 10
    local clip_right = clipped_x + cell * 18
    core.clip_rect_stack = { { clip_left, clipped_y, clip_right - clip_left,
      clipped_view:get_line_height() } }
    local clipped = capture_operations(clipped_view, clipped_x, clipped_y, function()
      clipped_view:draw_line_body(1, clipped_x, clipped_y)
    end)
    local clipped_whitespace = contributor_operations(clipped, "whitespace")
    local clipped_guides = contributor_operations(clipped, "indent_guides")
    test.ok(#clipped_whitespace > 0, "expected visible clipped whitespace markers")
    test.ok(#clipped_guides > 0, "expected visible clipped Indent Guides")

    local function horizontal_bounds(op)
      local left = clipped_x + op.x
      local right
      if op.kind == "rect_grid" then
        right = left + (op.count - 1) * op.step_x + op.width
      else
        right = left + (op.width or op.advance or cell)
      end
      return left, right
    end
    for _, op in ipairs(clipped_whitespace) do
      local left, right = horizontal_bounds(op)
      test.ok(right > clip_left and left < clip_right,
        "expected renderer-clipped whitespace marker bounds to cover the clip")
    end
    for _, op in ipairs(clipped_guides) do
      local left, right = horizontal_bounds(op)
      test.ok(left >= clip_left - cell * 3 and right <= clip_right + cell * 3,
        "expected legacy Indent Guide generation to stay within one indentation step of the clip")
      test.ok(op.count < 60, "expected clipping to bound the submitted guide count")
    end
  end)

  test.it("builds once and replays stable wrapped content and contributors", function(context)
    command.perform("draw-whitespace:toggle", true)
    local text = "        local value  =\t\"office\"  "
    local doc, view = new_view(context, text)
    view.__test_force_line_packets = true
    configure_tokens(doc, {
      "normal", "        ",
      "keyword", "local",
      "normal", " value  =\t",
      "string", "\"office\"",
      "normal", "  \n",
    })
    configure_wrapping(view, 10)
    local window = packet_window()
    local x, y = view:get_line_screen_position(1)
    local token_iterations = 0
    local old_each_token = tokenizer.each_token
    tokenizer.each_token = function(...)
      token_iterations = token_iterations + 1
      return old_each_token(...)
    end

    local ok, err = pcall(function()
      renderer.begin_frame(window)
      renderer.set_clip_rect(0, 0, 400, 200)
      view:draw_line_body(1, x, y)
      renderer.end_frame()

      local first = line_packets.diagnostics(view)
      test.equal(first.builds, 1)
      test.equal(first.misses, 1)
      test.ok(token_iterations > 0)
      local first_iterations = token_iterations

      local commands = test.not_nil(line_packets.inspect_line(view, 1))
      local content_text = {}
      local first_source_index
      local saw_content_marker = false
      local saw_guide = false
      for index, packet_command in ipairs(commands) do
        if packet_command.layer == renderer.display_packet.CONTENT then
          if packet_command.type == "rect_grid" then
            saw_content_marker = true
          elseif packet_command.type == "text" then
            if packet_command.text:find("·", 1, true)
            or packet_command.text:find("→", 1, true) then
              saw_content_marker = true
            else
              first_source_index = first_source_index or index
              content_text[#content_text + 1] = packet_command.text
            end
          end
        elseif packet_command.layer
          == renderer.display_packet.FOREGROUND_GUIDES then
          saw_guide = true
          test.equal(packet_command.row, 1)
        end
      end
      test.ok(saw_content_marker, "expected retained whitespace marker commands")
      test.ok(saw_guide, "expected retained foreground Indent Guide commands")
      test.equal(table.concat(content_text), text .. "\n")
      for index, packet_command in ipairs(commands) do
        if packet_command.layer == renderer.display_packet.CONTENT
        and (packet_command.type == "rect_grid"
          or packet_command.type == "text"
            and (packet_command.text:find("·", 1, true)
              or packet_command.text:find("→", 1, true))) then
          test.ok(index < first_source_index,
            "expected retained whitespace commands before source text")
        end
      end

      renderer.begin_frame(window)
      renderer.set_clip_rect(0, 0, 400, 200)
      view:draw_line_body(1, x, y)
      renderer.end_frame()

      local second = line_packets.diagnostics(view)
      test.equal(second.builds, 1)
      test.equal(second.hits, 1)
      test.equal(token_iterations, first_iterations,
        "expected stable replay not to traverse tokenizer segments again")
      local native = renderer.get_last_frame_stats()
      test.equal(native.display_packet_replays, 2)
      test.ok(native.display_packet_commands_replayed > 0)
    end)
    tokenizer.each_token = old_each_token
    if not ok then error(err, 0) end
  end)

  test.it("replays unwrapped lines while the caret moves", function(context)
    local doc, view = new_view(context, "first line\nsecond line\nthird line")
    view.__test_force_line_packets = true
    local window = packet_window()

    draw_packet_line(window, view, 1)
    local first = line_packets.diagnostics(view)
    test.is_nil(first.last_build_error)
    test.same(first.fallbacks, {})
    test.equal(first.builds, 1)
    test.equal(first.misses, 1)
    test.not_nil(line_packets.inspect_line(view, 1))

    doc:set_selection(2, 1)
    draw_packet_line(window, view, 1)
    local second = line_packets.diagnostics(view)
    test.equal(second.builds, 1)
    test.equal(second.hits, 1)
  end)

  test.it("keeps selected-only whitespace and active Indent Guides dynamic", function(context)
    command.perform("draw-whitespace:toggle", true)
    drawwhitespace.show_selected_only = true
    indent_guides.highlight_active = true
    local text = "        local value"
    local doc, view = new_view(context, text)
    view.__test_force_line_packets = true
    view.drawwhitespace_selections = {
      [1] = { 1, 9, text:sub(1, 9) },
    }
    configure_tokens(doc, { "normal", text .. "\n" })
    configure_wrapping(view, 12)
    doc:set_selection(1, 9, 1, 9)
    local window = packet_window()
    local x, y = view:get_line_screen_position(1)
    local whitespace_calls, active_guide_calls = 0, 0
    local old_draw_text = renderer.draw_text
    local old_draw_rect = renderer.draw_rect
    local old_draw_rect_grid = renderer.draw_rect_grid
    renderer.draw_text = function(font, value, sx, sy, color, options)
      if color == style.whitespace or color == style.whitespace_trailing then
        whitespace_calls = whitespace_calls + 1
      end
      return old_draw_text(font, value, sx, sy, color, options)
    end
    renderer.draw_rect = function(sx, sy, width, height, color)
      if color == style.whitespace or color == style.whitespace_trailing then
        whitespace_calls = whitespace_calls + 1
      elseif color == style.indent_guide_active then
        active_guide_calls = active_guide_calls + 1
      end
      return old_draw_rect(sx, sy, width, height, color)
    end
    renderer.draw_rect_grid = function(sx, sy, step, width, height, count, color)
      if color == style.whitespace or color == style.whitespace_trailing then
        whitespace_calls = whitespace_calls + 1
      end
      return old_draw_rect_grid(sx, sy, step, width, height, count, color)
    end

    local ok, err = pcall(function()
      renderer.begin_frame(window)
      renderer.set_clip_rect(0, 0, 400, 200)
      view:draw_line_body(1, x, y)
      renderer.end_frame()
    end)
    renderer.draw_text = old_draw_text
    renderer.draw_rect = old_draw_rect
    renderer.draw_rect_grid = old_draw_rect_grid
    if not ok then error(err, 0) end

    test.ok(whitespace_calls > 0,
      "expected selected-only marker work to remain on the legacy dynamic path")
    test.ok(active_guide_calls > 0,
      "expected active Indent Guide work to remain on the legacy dynamic path")
    local commands = test.not_nil(line_packets.inspect_line(view, 1))
    for _, packet_command in ipairs(commands) do
      test.ok(packet_command.layer ~= renderer.display_packet.FOREGROUND_GUIDES,
        "active guides must not be retained in the packet")
      if packet_command.type == "text" then
        test.ok(not packet_command.text:find("·", 1, true)
          and not packet_command.text:find("→", 1, true),
          "selected-only whitespace markers must not be retained in the packet")
      end
    end
  end)

  test.it("invalidates edited, retokenized, and recolored lines without rebuilding unaffected lines", function(context)
    local doc, view = new_view(context,
      "first line wraps here\nsecond line wraps here\nthird line wraps here")
    view.__test_force_line_packets = true
    configure_wrapping(view, 8)
    local window = packet_window()

    draw_packet_line(window, view, 1)
    draw_packet_line(window, view, 3)
    local initial = line_packets.diagnostics(view)
    test.equal(initial.builds, 2)

    doc:insert(1, 1, "x")
    draw_packet_line(window, view, 3)
    local after_edit = line_packets.diagnostics(view)
    test.equal(after_edit.builds, 2)
    test.ok(after_edit.hits > initial.hits,
      "expected an unaffected visible line to remain reusable")
    draw_packet_line(window, view, 1)
    test.equal(line_packets.diagnostics(view).builds, 3)

    doc.highlighter:soft_reset()
    draw_packet_line(window, view, 3)
    test.equal(line_packets.diagnostics(view).builds, 4,
      "expected highlighter reset with unchanged text to rebuild")

    local old_normal = style.syntax.normal
    style.syntax.normal = { 17, 33, 65, 255 }
    core.bump_render_style_generation("line-packet-test")
    local ok, err = pcall(function()
      draw_packet_line(window, view, 3)
      test.equal(line_packets.diagnostics(view).builds, 5)
      local commands = test.not_nil(line_packets.inspect_line(view, 3))
      local source
      for _, packet_command in ipairs(commands) do
        if packet_command.type == "text"
        and packet_command.layer == renderer.display_packet.CONTENT then
          source = packet_command
          break
        end
      end
      test.same(source.color, style.syntax.normal)
    end)
    style.syntax.normal = old_normal
    core.bump_render_style_generation("line-packet-test-restore")
    if not ok then error(err, 0) end
  end)

  test.it("bounds resident packet count and immediately clears native bytes", function(context)
    local doc, view = new_view(context,
      "line one wraps here\nline two wraps here\nline three wraps here\nline four wraps here")
    view.__test_force_line_packets = true
    view.__test_line_packet_max_count = 2
    configure_wrapping(view, 8)
    local window = packet_window()
    for line = 1, 4 do draw_packet_line(window, view, line) end
    local bounded = line_packets.diagnostics(view)
    test.equal(bounded.resident_packets, 2)
    test.ok(bounded.resident_bytes > 0)
    test.ok(bounded.evictions >= 2)

    local builds = bounded.builds
    draw_packet_line(window, view, 1)
    test.equal(line_packets.diagnostics(view).builds, builds + 1,
      "expected revisiting an evicted line to rebuild it")

    line_packets.clear(view)
    local cleared = line_packets.diagnostics(view)
    test.equal(cleared.resident_packets, 0)
    test.equal(cleared.resident_bytes, 0)
  end)

  test.it("evicts by native byte budget and bypasses oversized packets", function(context)
    local doc, view = new_view(context,
      "first retained line wraps here\nsecond retained line wraps here")
    view.__test_force_line_packets = true
    configure_wrapping(view, 8)
    local window = packet_window()

    draw_packet_line(window, view, 1)
    local first_bytes = line_packets.diagnostics(view).resident_bytes
    test.ok(first_bytes > 1)
    line_packets.clear(view)
    draw_packet_line(window, view, 2)
    local second_bytes = line_packets.diagnostics(view).resident_bytes
    test.ok(second_bytes > 1)
    line_packets.clear(view)
    view.__test_line_packet_max_bytes = math.max(first_bytes, second_bytes)
    draw_packet_line(window, view, 1)
    draw_packet_line(window, view, 2)
    local byte_bounded = line_packets.diagnostics(view)
    test.equal(byte_bounded.resident_packets, 1)
    test.ok(byte_bounded.resident_bytes <= view.__test_line_packet_max_bytes)
    test.ok(byte_bounded.evictions >= 1)

    line_packets.clear(view)
    view.__test_line_packet_max_bytes = 1
    draw_packet_line(window, view, 1)
    local oversized = line_packets.diagnostics(view)
    test.equal(oversized.resident_packets, 0)
    test.equal(oversized.resident_bytes, 0)
    test.equal(line_packets.inspect_line(view, 1), nil)
    local builds = oversized.builds
    draw_packet_line(window, view, 1)
    test.equal(line_packets.diagnostics(view).builds, builds + 1)
  end)

  test.it("rebuilds blank-line guide geometry after neighboring indentation changes", function(context)
    local doc, view = new_view(context, "        open\n    \n    close")
    view.__test_force_line_packets = true
    configure_wrapping(view, 20)
    local window = packet_window()
    draw_packet_line(window, view, 2)
    local function guide_count()
      local count = 0
      for _, packet_command in ipairs(line_packets.inspect_line(view, 2) or {}) do
        if packet_command.layer == renderer.display_packet.FOREGROUND_GUIDES then
          count = count + (packet_command.count or 1)
        end
      end
      return count
    end
    local before = guide_count()
    test.ok(before > 0)

    doc:remove(1, 1, 1, 9)
    draw_packet_line(window, view, 2)
    local after = guide_count()
    test.ok(after < before,
      "expected neighboring indentation to change retained blank-line guides")
  end)

  test.it("invalidates shifted suffix entries after structural edits", function(context)
    local doc, view = new_view(context, "alpha row\nbeta row\ngamma row")
    view.__test_force_line_packets = true
    configure_wrapping(view, 20)
    local window = packet_window()
    for line = 1, 3 do draw_packet_line(window, view, line) end
    test.equal(line_packets.diagnostics(view).resident_packets, 3)

    doc:insert(2, 1, "inserted row\n")
    test.equal(line_packets.diagnostics(view).resident_packets, 1)
    draw_packet_line(window, view, 3)
    local text = {}
    for _, packet_command in ipairs(line_packets.inspect_line(view, 3) or {}) do
      if packet_command.type == "text"
      and packet_command.layer == renderer.display_packet.CONTENT then
        text[#text + 1] = packet_command.text
      end
    end
    test.equal(table.concat(text), doc.lines[3]:sub(1, -2))

    doc:remove(2, 1, 3, 1)
    draw_packet_line(window, view, 2)
    text = {}
    for _, packet_command in ipairs(line_packets.inspect_line(view, 2) or {}) do
      if packet_command.type == "text"
      and packet_command.layer == renderer.display_packet.CONTENT then
        text[#text + 1] = packet_command.text
      end
    end
    test.equal(table.concat(text), doc.lines[2]:sub(1, -2))
  end)

  test.it("rebuilds suffix metadata after a preceding line changes wrapped row count", function(context)
    local doc, view = new_view(context,
      "short row\nlater cached row wraps here")
    view.__test_force_line_packets = true
    configure_wrapping(view, 8)
    local window = packet_window()
    draw_packet_line(window, view, 2)
    local initial = line_packets.diagnostics(view)
    local first_idx = linewrapping.get_line_idx_col_count(view, 2)

    doc:insert(1, 1, "this prefix adds several wrapped rows ")
    linewrapping.update_docview_breaks(view)
    local shifted_idx = linewrapping.get_line_idx_col_count(view, 2)
    test.ok(shifted_idx > first_idx)
    draw_packet_line(window, view, 2)
    test.equal(line_packets.diagnostics(view).builds, initial.builds + 1)
  end)

  test.it("rebuilds vertical packet geometry after line height changes", function(context)
    local _, view = new_view(context, "line height packet wraps here")
    view.__test_force_line_packets = true
    configure_wrapping(view, 8)
    local window = packet_window()
    draw_packet_line(window, view, 1)
    local initial = line_packets.diagnostics(view)

    config.line_height = config.line_height + 0.25
    draw_packet_line(window, view, 1)
    test.equal(line_packets.diagnostics(view).builds, initial.builds + 1)
  end)

  test.it("builds only a bounded visible slice of a pathological wrapped line", function(context)
    local doc, view = new_view(context, string.rep("x", 4000))
    view.__test_force_line_packets = true
    view.size.y = view:get_line_height() * 4
    configure_wrapping(view, 8)
    local total_rows = linewrapping.get_wrapped_line_count(view, 1)
    test.ok(total_rows > 128)
    view.scroll.y = view:get_line_height() * 100
    view.scroll.to.y = view.scroll.y
    local window = packet_window()
    draw_packet_line(window, view, 1)

    local commands = test.not_nil(line_packets.inspect_line(view, 1))
    local first_row, last_row, source_commands
    for _, packet_command in ipairs(commands) do
      if packet_command.layer == renderer.display_packet.CONTENT
      and packet_command.type == "text" then
        first_row = math.min(first_row or packet_command.row, packet_command.row)
        last_row = math.max(last_row or packet_command.row, packet_command.row)
        source_commands = (source_commands or 0) + 1
      end
    end
    test.ok(first_row and first_row > 1)
    test.ok(last_row - first_row < 12,
      "expected visible rows plus bounded overscan, not the complete line")
    test.ok(source_commands < total_rows / 4)
  end)

  test.it("reuses a bounded long-line packet while scrolling within its row chunk", function(context)
    local _, view = new_view(context, string.rep("x", 4000))
    view.__test_force_line_packets = true
    view.size.y = view:get_line_height() * 4
    configure_wrapping(view, 8)
    local window = packet_window()

    view.scroll.y = view:get_line_height() * 97
    view.scroll.to.y = view.scroll.y
    draw_packet_line(window, view, 1)
    local initial = line_packets.diagnostics(view)

    view.scroll.y = view:get_line_height() * 98
    view.scroll.to.y = view.scroll.y
    draw_packet_line(window, view, 1)
    local scrolled = line_packets.diagnostics(view)
    test.equal(scrolled.builds, initial.builds,
      "expected a small scroll within one packet row chunk to reuse the packet")
  end)

  test.it("reloads packet contributors without stacking drawing hooks", function(context)
    command.perform("draw-whitespace:toggle", true)
    local doc, view = new_view(context, "        value  ")
    view.__test_force_line_packets = true
    configure_wrapping(view, 20)
    local window = packet_window()
    draw_packet_line(window, view, 1)
    local function layer_counts()
      local content, guides = 0, 0
      for _, packet_command in ipairs(line_packets.inspect_line(view, 1) or {}) do
        if packet_command.layer == renderer.display_packet.CONTENT then
          content = content + 1
        elseif packet_command.layer == renderer.display_packet.FOREGROUND_GUIDES then
          guides = guides + 1
        end
      end
      return content, guides
    end
    local content_before, guides_before = layer_counts()
    test.ok(content_before > 0 and guides_before > 0)

    core.reload_module("core.docview_line_packets")
    core.reload_module("plugins.drawwhitespace")
    core.reload_module("plugins.indent_guides")
    draw_packet_line(window, view, 1)
    local content_after, guides_after = layer_counts()
    test.equal(content_after, content_before)
    test.equal(guides_after, guides_before)
    test.equal(renderer.get_last_frame_stats().display_packet_replays, 2)
  end)

  test.it("rebuilds contributor geometry when the horizontal clip changes", function(context)
    command.perform("draw-whitespace:toggle", true)
    local doc, view = new_view(context, string.rep(" ", 100) .. "x")
    view.__test_force_line_packets = true
    configure_wrapping(view, 200)
    local window = packet_window()
    core.clip_rect_stack = { { 0, 0, 80, 300 } }
    draw_packet_line(window, view, 1)
    test.equal(line_packets.diagnostics(view).builds, 1)
    core.clip_rect_stack = { { 80, 0, 80, 300 } }
    draw_packet_line(window, view, 1)
    test.equal(line_packets.diagnostics(view).builds, 2)
  end)

  test.it("rebuilds whitespace packets after configured marker colors change", function(context)
    command.perform("draw-whitespace:toggle", true)
    local doc, view = new_view(context, "value  middle")
    view.__test_force_line_packets = true
    configure_wrapping(view, 40)
    local window = packet_window()
    draw_packet_line(window, view, 1)
    local initial = line_packets.diagnostics(view)
    local substitution = drawwhitespace.substitutions[1]
    local old_color = substitution.middle_color
    local changed_color = { 23, 47, 89, 211 }
    local ok, err = pcall(function()
      substitution.middle_color = changed_color
      draw_packet_line(window, view, 1)
      test.equal(line_packets.diagnostics(view).builds, initial.builds + 1)
      local found = false
      for _, packet_command in ipairs(line_packets.inspect_line(view, 1) or {}) do
        if packet_command.layer == renderer.display_packet.CONTENT
        and (packet_command.type == "text" or packet_command.type == "rect"
          or packet_command.type == "rect_grid")
        and packet_command.color then
          if packet_command.color[1] == changed_color[1]
          and packet_command.color[2] == changed_color[2]
          and packet_command.color[3] == changed_color[3]
          and packet_command.color[4] == changed_color[4] then
            found = true
            break
          end
        end
      end
      test.ok(found, "expected rebuilt marker commands to use the configured color")
    end)
    substitution.middle_color = old_color
    if not ok then error(err, 0) end
  end)

  test.it("keeps independent packet layouts for two Document Views", function(context)
    local doc, narrow = new_view(context, "shared document line wraps many times")
    local wide = DocView(doc)
    wide.position.x, wide.position.y = 0, 0
    wide.size.x, wide.size.y = 1000, 1000
    context.views[#context.views + 1] = wide
    narrow.__test_force_line_packets = true
    wide.__test_force_line_packets = true
    configure_wrapping(narrow, 8)
    configure_wrapping(wide, 16)
    local window = packet_window()
    draw_packet_line(window, narrow, 1)
    draw_packet_line(window, wide, 1)
    test.equal(line_packets.diagnostics(narrow).builds, 1)
    test.equal(line_packets.diagnostics(wide).builds, 1)

    local function max_row(view)
      local value = 0
      for _, packet_command in ipairs(line_packets.inspect_line(view, 1) or {}) do
        value = math.max(value, packet_command.row or 0)
      end
      return value
    end
    test.ok(max_row(narrow) > max_row(wide))

    doc:insert(1, 1, "changed ")
    draw_packet_line(window, narrow, 1)
    draw_packet_line(window, wide, 1)
    test.equal(line_packets.diagnostics(narrow).builds, 2)
    test.equal(line_packets.diagnostics(wide).builds, 2)
  end)
end)
