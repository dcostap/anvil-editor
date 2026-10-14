-- Interactive Markdown table presentation: cell layout, wrapping and the
-- render fragments for each table row. Source table parsing and edits live
-- in core.markdown.tables.
local core = require "core"
local common = require "core.common"
local live_fonts = require "core.markdown.live_fonts"
local markdown_tables = require "core.markdown.tables"
local style = require "core.style"

local table_presentation = {}

local function perf_frame_add(key, amount)
  if not core.perf_frame_stats then return end
  local perf = package.loaded["core.perf"]
  if perf and perf.frame_add then perf.frame_add(key, amount or 1) end
end

local TABLE_MAX_PRESENTATION_ROWS = markdown_tables.MAX_PRESENTATION_ROWS
local TABLE_MAX_PRESENTATION_COLUMNS = markdown_tables.MAX_PRESENTATION_COLUMNS
local TABLE_MAX_CELL_PRESENTATION_BYTES = 4096
local TABLE_LAYOUT_GEOMETRY_CACHE_LIMIT = 4

local table_source_row = markdown_tables.source_row

local function table_cell_content(text, cell)
  local raw = text:sub(cell.col1, cell.col2 - 1)
  local leading = #(raw:match("^%s*") or "")
  local trailing = #(raw:match("%s*$") or "")
  local source_col1, source_col2 = cell.col1 + leading, cell.col2 - trailing
  if source_col1 > source_col2 then
    local empty_col = common.clamp(
      cell.col1 + math.floor(#raw / 2), cell.col1, cell.col2
    )
    return "", empty_col, empty_col
  end
  return raw:sub(leading + 1, #raw - trailing), source_col1, source_col2
end

local function table_cell_text(text, cell)
  return (table_cell_content(text, cell))
end

local function table_cell_presentation(view, text, source_col1, source_col2, header)
  local image_alt = text:match("^!%[([^%]]*)%]%(%s*data:image/[%w%+%.%-]+[;,]")
  if image_alt or #text > TABLE_MAX_CELL_PRESENTATION_BYTES then
    local display
    if image_alt then
      display = image_alt ~= "" and ("[Embedded image: " .. image_alt .. "]")
        or "[Embedded image]"
    else
      local parts, bytes = {}, 0
      for char in common.utf8_chars(text) do
        if bytes + #char > TABLE_MAX_CELL_PRESENTATION_BYTES then break end
        parts[#parts + 1] = char
        bytes = bytes + #char
      end
      display = table.concat(parts) .. "… [cell content truncated]"
    end
    perf_frame_add("markdown_live_table_cell_elisions", 1)
    return {
      text = display,
      source_col1 = source_col1,
      source_col2 = source_col2,
      font = header and live_fonts.inline_style(view, "strong") or live_fonts.body(view),
      color = header and style.markdown_live_table_header or style.markdown_live_table_cell,
      nowrap = true,
      source_elided = true,
    }
  end
  if not header then
    local ticks = text:match("^(`+)")
    if ticks and #text >= #ticks * 2 and text:sub(-#ticks) == ticks then
      return {
        text = text:sub(#ticks + 1, -#ticks - 1),
        source_col1 = source_col1 + #ticks,
        source_col2 = source_col2 - #ticks,
        font = live_fonts.inline_style(view, "code"),
        color = style.markdown_live_table_cell,
        background = style.markdown_live_inline_code_bg,
        literal_breaks = true,
      }
    end
  end
  return {
    text = text,
    source_col1 = source_col1,
    source_col2 = source_col2,
    font = header and live_fonts.inline_style(view, "strong") or live_fonts.body(view),
    color = header and style.markdown_live_table_header or style.markdown_live_table_cell,
  }
end

local function table_wrap_text(font, text, width)
  if text == "" then return { { text = "", col1 = 1, col2 = 1 } } end
  width = math.max(1, width)
  if font.text_layout then
    local layout = font:text_layout(text)
    local starts = layout:wrap(width, "word")
    local lines = {}
    for index, zero_start in ipairs(starts) do
      local col1 = zero_start + 1
      local col2 = (starts[index + 1] or #text) + 1
      while col1 < col2 and text:sub(col1, col1):match("%s") do col1 = col1 + 1 end
      while col2 > col1 and text:sub(col2 - 1, col2 - 1):match("%s") do col2 = col2 - 1 end
      lines[#lines + 1] = {
        text = text:sub(col1, col2 - 1),
        col1 = col1,
        col2 = col2,
      }
    end
    if #lines == 0 then lines[1] = { text = "", col1 = 1, col2 = 1 } end
    return lines
  end
  local lines = {}
  local line_start, line_end
  local function push_line()
    if line_start then
      lines[#lines + 1] = {
        text = text:sub(line_start, line_end),
        col1 = line_start,
        col2 = line_end + 1,
      }
      line_start, line_end = nil, nil
    end
  end

  local search = 1
  while true do
    local word_start, word_end = text:find("%S+", search)
    if not word_start then break end
    if line_start and font:get_width(text:sub(line_start, word_end)) <= width then
      line_end = word_end
    else
      push_line()
      local word = text:sub(word_start, word_end)
      if font:get_width(word) <= width then
        line_start, line_end = word_start, word_end
      else
        local chunk_start, chunk_end = word_start, word_start - 1
        local chunk = ""
        for char in common.utf8_chars(word) do
          if chunk ~= "" and font:get_width(chunk .. char) > width then
            lines[#lines + 1] = {
              text = chunk, col1 = chunk_start, col2 = chunk_end + 1,
            }
            chunk_start, chunk = chunk_end + 1, ""
          end
          chunk = chunk .. char
          chunk_end = chunk_end + #char
        end
        if chunk ~= "" then
          line_start, line_end = chunk_start, chunk_end
        end
      end
    end
    search = word_end + 1
  end
  push_line()
  if #lines == 0 then lines[1] = { text = "", col1 = 1, col2 = 1 } end
  return lines
end

local TABLE_BREAK_PATTERN = "<[bB][rR]%s*/?%s*>"

local function next_table_break(text, start)
  local escaped, ticks = false, 0
  local col = 1
  while col <= #text do
    local char = text:sub(col, col)
    if escaped then
      escaped = false
    elseif char == "\\" then
      escaped = true
    elseif char == "`" then
      local finish = col
      while text:sub(finish + 1, finish + 1) == "`" do finish = finish + 1 end
      local count = finish - col + 1
      if ticks == 0 then ticks = count elseif ticks == count then ticks = 0 end
      col = finish
    elseif ticks == 0 and col >= start and char == "<" then
      local col1, col2 = text:find(TABLE_BREAK_PATTERN, col)
      if col1 == col then return col1, col2 end
    end
    col = col + 1
  end
end

local function table_wrap_cell_text(font, text, width, literal_breaks)
  if literal_breaks then return table_wrap_text(font, text, width) end
  local lines = {}
  local start = 1
  while true do
    local break_col1, break_col2 = next_table_break(text, start)
    local finish = break_col1 or (#text + 1)
    local segment = text:sub(start, finish - 1)
    local wrapped = table_wrap_text(font, segment, width)
    for _, visual in ipairs(wrapped) do
      lines[#lines + 1] = {
        text = visual.text,
        col1 = start + (visual.col1 or 1) - 1,
        col2 = start + (visual.col2 or 1) - 1,
      }
    end
    if not break_col1 then break end
    start = break_col2 + 1
    if start > #text then
      lines[#lines + 1] = { text = "", col1 = start, col2 = start }
      break
    end
  end
  if #lines == 0 then lines[1] = { text = "", col1 = 1, col2 = 1 } end
  return lines
end

local function table_cell_natural_width(font, text, literal_breaks)
  if literal_breaks then return font:get_width(text) end
  local width, start = 0, 1
  while true do
    local break_col1, break_col2 = next_table_break(text, start)
    local finish = break_col1 or (#text + 1)
    width = math.max(width, font:get_width(text:sub(start, finish - 1)))
    if not break_col1 then return width end
    start = break_col2 + 1
  end
end

-- Inline Markdown inside cells ---------------------------------------------
--
-- Live Preview registers `table_presentation.inline_pieces(view, text, line,
-- reveal, base)`. It returns prose-style fragments that partition one source
-- row: formatting, links, and hidden syntax markers. A cell renders the pieces
-- inside its content range as styled runs. `reveal` is "none", "all" (every
-- marker visible, the widest presentation), or a selection state.

local function normalize_runs(line_text, pieces)
  local runs = {}
  local function add(run)
    if run.col2 > run.col1 or not run.hidden then runs[#runs + 1] = run end
  end
  for _, piece in ipairs(pieces or {}) do
    local col1 = piece.source_col1 or 1
    local col2 = piece.source_col2 or col1
    local function styled(run)
      run.font = piece.font
      run.color = piece.color
      run.background = piece.background
      run.strikethrough = piece.strikethrough
      run.underline = piece.underline
      run.plain = piece.plain
      run.link = piece.link ~= nil or nil
      return run
    end
    if piece.hidden or not piece.text then
      add({ col1 = col1, col2 = col2, hidden = true })
    elseif piece.text == line_text:sub(col1, col2 - 1) then
      add(styled({ col1 = col1, col2 = col2, text = piece.text, exact = true }))
    elseif piece.text_source_col1 and piece.text_source_col2
      and line_text:sub(piece.text_source_col1, piece.text_source_col2 - 1) == piece.text
    then
      add({ col1 = col1, col2 = piece.text_source_col1, hidden = true })
      add(styled({
        col1 = piece.text_source_col1, col2 = piece.text_source_col2,
        text = piece.text, exact = true,
      }))
      add({ col1 = piece.text_source_col2, col2 = col2, hidden = true })
    else
      add(styled({ col1 = col1, col2 = col2, text = piece.text }))
    end
  end
  return runs
end

local function slice_runs(runs, col1, col2)
  local sliced = {}
  for _, run in ipairs(runs) do
    if run.col2 > col1 and run.col1 < col2 then
      if run.exact or run.hidden then
        local a, b = math.max(col1, run.col1), math.min(col2, run.col2)
        local copy = {}
        for key, value in pairs(run) do copy[key] = value end
        copy.col1, copy.col2 = a, b
        if run.exact then copy.text = run.text:sub(a - run.col1 + 1, b - run.col1) end
        sliced[#sliced + 1] = copy
      elseif run.col1 >= col1 then
        sliced[#sliced + 1] = run
      end
    end
  end
  return sliced
end

local function runs_are_plain(runs)
  for _, run in ipairs(runs) do
    if not run.plain then return false end
  end
  return true
end

local function runs_natural_width(runs)
  local width = 0
  for _, run in ipairs(runs) do
    if not run.hidden and run.text ~= "" then width = width + run.font:get_width(run.text) end
  end
  return width
end

local function run_tokens(runs)
  local tokens = {}
  for _, run in ipairs(runs) do
    if run.hidden then
      tokens[#tokens + 1] = {
        run = run, col1 = run.col1, col2 = run.col2, text = "", hidden = true,
      }
    elseif not run.exact then
      tokens[#tokens + 1] = { run = run, col1 = run.col1, col2 = run.col2, text = run.text }
    else
      local text, position = run.text, 1
      while position <= #text do
        local first, last = text:find("^%s+", position)
        local space = first ~= nil
        if not space then first, last = text:find("^%S+", position) end
        tokens[#tokens + 1] = {
          run = run, exact = true, space = space,
          col1 = run.col1 + first - 1, col2 = run.col1 + last,
          text = text:sub(first, last),
        }
        position = last + 1
      end
    end
  end
  return tokens
end

local function token_width(token)
  if token.hidden or token.text == "" then return 0 end
  return token.run.font:get_width(token.text)
end

---Greedily wrap styled runs at word boundaries within `width`. Each line
---keeps its runs with x offsets and source columns for drawing and hit tests.
local function wrap_runs(runs, width, empty_col)
  width = math.max(1, width)
  local lines, line = {}, nil
  local function new_line()
    line = { tokens = {}, width = 0, content_width = 0 }
  end
  local function finish_line()
    lines[#lines + 1] = line
    new_line()
  end
  local function append(token, token_advance)
    line.tokens[#line.tokens + 1] = token
    line.width = line.width + token_advance
    if not token.space then line.content_width = line.width end
  end
  new_line()
  local tokens = run_tokens(runs)
  local index = 1
  while index <= #tokens do
    local token = tokens[index]
    if token.space then
      -- Spaces never start a wrapped line.
      if line.content_width > 0 then append(token, token_width(token)) end
      index = index + 1
    else
      local last, group_width = index, 0
      while last <= #tokens and not tokens[last].space do
        group_width = group_width + token_width(tokens[last])
        last = last + 1
      end
      if line.content_width > 0 and line.width + group_width > width then
        finish_line()
      end
      if line.width + group_width <= width then
        for position = index, last - 1 do
          append(tokens[position], token_width(tokens[position]))
        end
      else
        -- A word wider than the cell breaks between characters.
        for position = index, last - 1 do
          local item = tokens[position]
          if item.hidden or not item.exact then
            local advance = token_width(item)
            if line.content_width > 0 and line.width + advance > width then finish_line() end
            append(item, advance)
          else
            local char_col = item.col1
            for char in common.utf8_chars(item.text) do
              local advance = item.run.font:get_width(char)
              if line.content_width > 0 and line.width + advance > width then
                finish_line()
              end
              append({
                run = item.run, exact = true,
                col1 = char_col, col2 = char_col + #char, text = char,
              }, advance)
              char_col = char_col + #char
            end
          end
        end
      end
      index = last
    end
  end
  if #line.tokens > 0 or #lines == 0 then finish_line() end

  local wrapped = {}
  for _, entry in ipairs(lines) do
    local pieces, texts, x = {}, {}, 0
    for _, token in ipairs(entry.tokens) do
      local previous = pieces[#pieces]
      if previous and previous.source == token.run and previous.col2 == token.col1
        and previous.exact and token.exact
      then
        previous.text = previous.text .. token.text
        previous.col2 = token.col2
      else
        local run = token.run
        pieces[#pieces + 1] = {
          source = run, text = token.text, col1 = token.col1, col2 = token.col2,
          exact = token.exact or nil, hidden = token.hidden or nil,
          font = run.font, color = run.color, background = run.background,
          strikethrough = run.strikethrough, underline = run.underline,
        }
      end
    end
    for _, piece in ipairs(pieces) do
      piece.x = x
      piece.width = (piece.hidden or piece.text == "") and 0 or piece.font:get_width(piece.text)
      x = x + piece.width
      piece.source = nil
      texts[#texts + 1] = piece.text
    end
    local first, last = pieces[1], pieces[#pieces]
    wrapped[#wrapped + 1] = {
      text = table.concat(texts),
      runs = pieces,
      width = entry.content_width,
      source_col1 = first and first.col1 or empty_col,
      source_col2 = last and last.col2 or empty_col,
    }
  end
  return wrapped
end

local function cell_break_segments(text, source_col1)
  local segments, start = {}, 1
  while true do
    local break_col1, break_col2 = next_table_break(text, start)
    local finish = break_col1 or (#text + 1)
    segments[#segments + 1] = {
      col1 = source_col1 + start - 1, col2 = source_col1 + finish - 1,
    }
    if not break_col1 then break end
    start = break_col2 + 1
  end
  return segments
end

local function rich_cell_lines(presentation, width)
  local lines = {}
  for _, segment in ipairs(presentation.segments) do
    local runs = slice_runs(presentation.runs, segment.col1, segment.col2)
    for _, line in ipairs(wrap_runs(runs, width, segment.col1)) do
      lines[#lines + 1] = line
    end
  end
  return lines
end

local function rich_cell_natural_width(presentation)
  local width = 0
  for _, segment in ipairs(presentation.segments) do
    width = math.max(width, runs_natural_width(
      slice_runs(presentation.runs, segment.col1, segment.col2)
    ))
  end
  return width
end

---Return a rich presentation for a cell, or nil when its source is plain.
local function rich_presentation(runs, text, source_col1, source_col2, base)
  if not runs then return nil end
  local cell_runs = slice_runs(runs, source_col1, source_col2)
  if runs_are_plain(cell_runs) then return nil end
  local texts = {}
  for _, run in ipairs(cell_runs) do
    if not run.hidden then texts[#texts + 1] = run.text end
  end
  return {
    text = table.concat(texts),
    source_col1 = source_col1,
    source_col2 = source_col2,
    font = base.base_font,
    color = base.color,
    runs = cell_runs,
    segments = cell_break_segments(text, source_col1),
  }
end

local function presentation_has_link(presentation)
  for _, run in ipairs(presentation.runs or {}) do
    if run.link then return true end
  end
  return false
end

local function presentation_lines(presentation, width)
  if presentation.runs then return rich_cell_lines(presentation, width) end
  return table_wrap_cell_text(
    presentation.font, presentation.text, width, presentation.literal_breaks
  )
end

local function presentation_natural_width(presentation)
  if presentation.runs then return rich_cell_natural_width(presentation) end
  return table_cell_natural_width(
    presentation.font, presentation.text, presentation.literal_breaks
  )
end

local function inline_base(view, header)
  if header then
    return {
      base_font = live_fonts.inline_style(view, "strong"),
      base_bold = true,
      base_italic_font = live_fonts.inline_style(view, "strong_emphasis"),
      color = style.markdown_live_table_header,
    }
  end
  return { base_font = live_fonts.body(view), color = style.markdown_live_table_cell }
end

local function row_inline_runs(view, text, line, reveal, base)
  local provider = table_presentation.inline_pieces
  if not provider then return nil end
  local ok, pieces = pcall(provider, view, text, line, reveal, base)
  if not ok then
    core.log_quiet("Markdown table inline presentation failed at %s:%d: %s",
      view.buffer:get_name(), line, tostring(pieces))
    return nil
  end
  return pieces and normalize_runs(text, pieces) or nil
end

local function control_metrics(text_line_height)
  local size = math.max(math.floor(SCALE * 6), math.floor(text_line_height * 0.72 + 0.5))
  local hit_padding = math.max(math.floor(SCALE * 2), math.floor(size * 0.18 + 0.5))
  return size, hit_padding, size + hit_padding * 2
end

-- Table Scroll -------------------------------------------------------------
-- A table wider than the editor scrolls inside its own frame. Its rows share
-- one state, keyed by the header line, so the offset survives row rebuilds.

---Return the shared horizontal scroll state of the table whose header row
---is `line1`. Text View reads `x` when it draws and hit-tests the rows.
function table_presentation.scroll_state(view, line1)
  local states = view.__markdown_table_scroll
  if not states then
    states = {}
    view.__markdown_table_scroll = states
  end
  local state = states[line1]
  if not state then
    state = { x = 0, to = 0, max = 0 }
    states[line1] = state
  end
  return state
end

---Move scroll states with their tables after an edit adds or removes lines.
function table_presentation.remap_scroll_states(view, ranges)
  local states = view.__markdown_table_scroll
  if not (states and next(states)) then return end
  local remapped = {}
  for line1, state in pairs(states) do
    local delta, mapped = 0, nil
    for _, range in ipairs(ranges) do
      local old_line1 = range.old_line1 or range.new_line1 or 1
      local old_line2 = range.old_line2 or old_line1
      if line1 < old_line1 then
        mapped = line1 + delta
        break
      end
      if line1 <= old_line2 then
        local new_line1 = range.new_line1 or old_line1
        local new_line2 = math.max(new_line1, range.new_line2 or new_line1)
        mapped = math.min(new_line1 + line1 - old_line1, new_line2)
        break
      end
      delta = delta + (range.line_delta or 0)
    end
    mapped = mapped or line1 + delta
    if not remapped[mapped] or (state.x or 0) > 0 then remapped[mapped] = state end
  end
  view.__markdown_table_scroll = remapped
end

function table_presentation.available_width(view)
  -- Tables may use the full editor viewport even when prose has a narrower
  -- configured wrap column. This matches reading-mode table layout and avoids
  -- wrapping an otherwise fitting grid merely because of the prose guide.
  local scrollbar_width = view.v_scrollbar.expanded_size or style.expanded_scrollbar_size
  local width = view:get_presentation_viewport_width()
    - view:get_gutter_width() - scrollbar_width - style.padding.x
  return math.max(math.floor(SCALE * 160), width)
end

local function table_geometry_key(font, available_width)
  return table.concat({
    tostring(font), tostring(font:get_size()), tostring(available_width),
  }, ":")
end

---Return the cached layout for a table, built for the semantic `instance`
---that contains it, or nil when the table is presented as source.
function table_presentation.layout(view, table_node, instance)
  local font = live_fonts.body(view)
  local available_width = table_presentation.available_width(view)
  local line2 = table_node.source.line2
  if table_node.source.col2 == 1 and line2 > table_node.source.line1 then line2 = line2 - 1 end
  local line1 = table_node.source.line1
  if line2 - line1 + 1 > TABLE_MAX_PRESENTATION_ROWS then
    core.log_quiet("Markdown table presentation kept raw beyond %d rows at %s:%d",
      TABLE_MAX_PRESENTATION_ROWS, view.buffer:get_name(), line1)
    return nil
  end
  local theme_generation = core.color_theme_generation or 0
  local cache = view.__markdown_live_table_layout_cache
  -- Table presentations retain resolved style colors, so do not reuse the
  -- semantic geometry cache across a theme reload.
  if not cache or cache.generation ~= instance.generation
    or cache.theme_generation ~= theme_generation
  then
    local previous_buckets = cache and cache.theme_generation == theme_generation
      and cache.buckets or nil
    cache = {
      generation = instance.generation,
      theme_generation = theme_generation,
      buckets = {},
      bucket_order = {},
      previous_buckets = previous_buckets,
    }
    view.__markdown_live_table_layout_cache = cache
  end
  local geometry_key = table_geometry_key(font, available_width)
  local bucket = cache.buckets[geometry_key]
  if not bucket then
    bucket = {
      font = font, font_size = font:get_size(), available_width = available_width,
      layouts = {}, sources = {},
    }
    cache.buckets[geometry_key] = bucket
  end
  for index = #cache.bucket_order, 1, -1 do
    if cache.bucket_order[index] == geometry_key then table.remove(cache.bucket_order, index) end
  end
  cache.bucket_order[#cache.bucket_order + 1] = geometry_key
  while #cache.bucket_order > TABLE_LAYOUT_GEOMETRY_CACHE_LIMIT do
    local evicted = table.remove(cache.bucket_order, 1)
    cache.buckets[evicted] = nil
    perf_frame_add("markdown_live_table_geometry_bucket_evictions", 1)
  end
  cache.layouts = bucket.layouts
  local layouts, sources = bucket.layouts, bucket.sources
  local id = table_node.id
  -- A parse can stay pending across edits without a new semantic generation,
  -- so every cached result, including a raw fallback, must still match the
  -- complete source rows that produced it.
  if layouts[id] ~= nil then
    if markdown_tables.source_record_current(view.buffer, sources[id], line1, line2) then
      return layouts[id] or nil
    end
    perf_frame_add("markdown_live_table_layout_source_misses", 1)
    layouts[id], sources[id] = nil, nil
  end

  -- A semantic publication does not change every table. Reuse a layout only
  -- when its identity, geometry, source range and complete source still match.
  local previous_bucket = cache.previous_buckets and cache.previous_buckets[geometry_key]
  local previous = previous_bucket and previous_bucket.layouts[id]
  if previous and markdown_tables.source_record_current(
    view.buffer, previous_bucket.sources[id], line1, line2
  ) then
    layouts[id], sources[id] = previous, previous_bucket.sources[id]
    perf_frame_add("markdown_live_table_layout_reuses", 1)
    return previous
  end

  local function store(layout)
    layouts[id], sources[id] = layout, markdown_tables.source_record(view.buffer, line1, line2)
    return layout or nil
  end

  local rows, columns, canonical = {}, nil, true
  for line = line1, line2 do
    local text = (view.buffer.lines[line] or ""):gsub("\n$", "")
    local row = table_source_row(text)
    if not row or #row.cells == 0 or #row.cells > TABLE_MAX_PRESENTATION_COLUMNS then
      core.log_quiet("Markdown table presentation fell back to source at %s:%d",
        view.buffer:get_name(), line)
      return store(false)
    end
    columns = columns or #row.cells
    if #row.cells ~= columns then
      core.log_quiet("Markdown table presentation found inconsistent columns at %s:%d",
        view.buffer:get_name(), line)
      return store(false)
    end
    row.line, row.text = line, text
    canonical = canonical and row.canonical
    rows[line] = row
  end

  local pad = math.max(font:get_width(" ") * 2.25, SCALE * 9)
  local vertical_pad = math.max(math.floor(SCALE * 5), 2)
  local widths, presentations, active_presentations = {}, {}, {}
  local minimums = {}
  local selection_stable_layout = true
  for column = 1, columns do widths[column] = pad * 4 end
  for line = line1, line2 do
    if line ~= line1 + 1 then
      local row = rows[line]
      local base = inline_base(view, line == line1)
      local runs = row_inline_runs(view, row.text, line, "none", base)
      -- Every marker revealed is the widest presentation an active cell can
      -- show, so sizing for it keeps column widths stable while editing.
      local revealed_runs = runs and row_inline_runs(view, row.text, line, "all", base)
      presentations[line] = {}
      active_presentations[line] = {}
      for column, cell in ipairs(row.cells) do
        local text, source_col1, source_col2 = table_cell_content(row.text, cell)
        local presentation = table_cell_presentation(
          view, text, source_col1, source_col2, line == line1
        )
        if not presentation.source_elided then
          presentation = rich_presentation(runs, text, source_col1, source_col2, base)
            or presentation
        end
        presentations[line][column] = presentation
        if presentation.source_elided or presentation_has_link(presentation) then
          -- Revealing elided source or a link destination can add lines.
          selection_stable_layout = false
        else
          active_presentations[line][column] = rich_presentation(
            revealed_runs, text, source_col1, source_col2, base
          ) or {
            text = text,
            source_col1 = source_col1,
            source_col2 = source_col2,
            font = base.base_font,
          }
        end
        widths[column] = math.max(
          widths[column], presentation_natural_width(presentation) + pad * 2
        )
        local active = active_presentations[line][column]
        if active then
          widths[column] = math.max(
            widths[column], presentation_natural_width(active) + pad * 2
          )
        end
      end
    end
  end
  for column = 1, columns do
    local header_text = table_cell_text(rows[line1].text, rows[line1].cells[column])
    minimums[column] = math.max(
      pad * 2 + live_fonts.inline_style(view, "strong"):get_width(header_text),
      -- Below this floor dense grids become columns of individually wrapped
      -- glyphs. Keep a readable cell width and let Text View expose the
      -- table's horizontal overflow instead of crushing every column. A
      -- column with shorter content keeps its natural width.
      math.min(widths[column], pad * 2 + font:get_width("MMMMMMMM")),
      -- Empty and very short columns stay wide enough to read as cells and
      -- to click into.
      pad * 2 + font:get_width("MMMMM")
    )
    for row_line = line1, line2 do
      local presentation = presentations[row_line] and presentations[row_line][column]
      if presentation and presentation.nowrap then
        minimums[column] = math.max(
          minimums[column], presentation.font:get_width(presentation.text) + pad * 2
        )
      end
    end
    widths[column] = math.max(widths[column], minimums[column])
  end
  local alignments = {}
  for column, cell in ipairs(rows[line1 + 1].cells) do
    local marker = table_cell_text(rows[line1 + 1].text, cell)
    local left, right = marker:sub(1, 1) == ":", marker:sub(-1) == ":"
    alignments[column] = left and right and "center" or right and "right" or "left"
  end
  local separator_width = math.max(font:get_width(" "), math.max(1, SCALE * 3))
  local chrome_width = separator_width * (columns + 1)
  local content_budget = math.max(1, available_width - chrome_width)
  local natural_content_width, minimum_content_width = 0, 0
  for column, width in ipairs(widths) do
    natural_content_width = natural_content_width + width
    minimum_content_width = minimum_content_width + minimums[column]
  end
  if natural_content_width > content_budget then
    local target = math.max(content_budget, minimum_content_width)
    local flexible = math.max(1, natural_content_width - minimum_content_width)
    local shrink = natural_content_width - target
    for column, width in ipairs(widths) do
      local share = (width - minimums[column]) / flexible
      widths[column] = math.max(minimums[column], width - shrink * share)
    end
  end
  local total_width = chrome_width
  for _, width in ipairs(widths) do total_width = total_width + width end
  local row_heights, wrapped_cells = {}, {}
  local text_line_height = live_fonts.body_line_height(view)
  for row_line = line1, line2 do
    if row_line ~= line1 + 1 then
      wrapped_cells[row_line] = {}
      local row = rows[row_line]
      local max_lines = 1
      for column in ipairs(row.cells) do
        local presentation = presentations[row_line][column]
        local wrapped = presentation_lines(presentation, widths[column] - pad * 2)
        wrapped_cells[row_line][column] = wrapped
        max_lines = math.max(max_lines, #wrapped)
        local active = active_presentations[row_line][column]
        if active then
          max_lines = math.max(
            max_lines, #presentation_lines(active, widths[column] - pad * 2)
          )
        end
      end
      row_heights[row_line] = max_lines * text_line_height + vertical_pad * 2
    end
  end
  local _, _, control_hit_size = control_metrics(text_line_height)
  -- Scrolling ends past the last border so its Hover Insertion Control fits.
  local scroll_max = total_width > available_width
    and math.ceil(total_width + control_hit_size / 2 - available_width) or 0
  local layout = {
    id = table_node.id, line1 = line1, line2 = line2,
    viewport_width = available_width, scroll_max = scroll_max,
    delimiter_line = line1 + 1, rows = rows, columns = columns,
    widths = widths, alignments = alignments, padding = pad,
    vertical_padding = vertical_pad, text_line_height = text_line_height,
    row_heights = row_heights, wrapped_cells = wrapped_cells,
    presentations = presentations,
    active_presentations = active_presentations,
    selection_stable_layout = selection_stable_layout,
    separator_width = separator_width, total_width = total_width,
    canonical = canonical,
  }
  return store(layout)
end

-- Table handles ------------------------------------------------------------
-- A grip on a body row's left border and on top of each header cell. A click
-- selects the whole row or column; a drag moves it to the drop position.

local function line_bottom(view, line)
  local content = view:get_line_render(line)
  if content and content.table_content_height then
    return select(2, view:get_line_screen_position(line)) + content.table_content_height
  end
  if line < #view.buffer.lines then
    return select(2, view:get_line_screen_position(line + 1))
  end
  local render = view:get_line_render(line)
  local _, y = view:get_line_screen_position(line)
  return y + (render and render.table_row_height or view:get_line_height())
end

local function with_alpha(color, factor)
  local value = { table.unpack(color) }
  value[4] = (value[4] or 255) * factor
  return value
end

local function draw_grip(x, y, width, height, visibility, vertical)
  visibility = visibility * visibility * (3 - 2 * visibility)
  renderer.draw_rounded_rect(
    x, y, width, height, math.min(width, height) / 2,
    with_alpha(style.accent, visibility * 0.75)
  )
  local dot = math.max(1, math.floor(math.min(width, height) * 0.4 + 0.5))
  local dot_color = with_alpha(style.background, visibility)
  for index = -1, 1 do
    local cx = x + width / 2 + (vertical and 0 or index * dot * 2)
    local cy = y + height / 2 + (vertical and index * dot * 2 or 0)
    renderer.draw_rect(
      math.floor(cx - dot / 2 + 0.5), math.floor(cy - dot / 2 + 0.5), dot, dot, dot_color
    )
  end
end

-- Draw a drag preview inside the table's frame, like its rows.
local function draw_in_table_frame(owner, line, draw)
  local render = owner:get_line_render(line)
  local clip = render and render.horizontal_clip
  if not clip then return draw() end
  local scroll = render.horizontal_scroll
  local x = owner:get_line_screen_position(line) + (scroll and scroll.x or 0)
  core.push_clip_rect(x + clip.x1, owner.position.y, clip.x2 - clip.x1, owner.size.y)
  local ok, err = pcall(draw)
  core.pop_clip_rect()
  if not ok then error(err, 0) end
end

local function table_rows_for_drag(view, line)
  local context = markdown_tables.interactive_context(view, line, 1)
  if not context then return nil end
  local lines = {}
  for index, row in ipairs(context.editable_rows) do lines[index] = row.line end
  return context, lines
end

local function row_drag(view, spec, press_y)
  local context, lines = table_rows_for_drag(view, spec.line)
  if not context then return nil end
  local drag = { cursor = "hand", moved = false, from = context.grid_row }
  local threshold = math.max(3, spec.text_line_height * 0.25)
  function drag.on_move(self, owner, x, y)
    if not self.moved and math.abs(y - press_y) < threshold then return end
    self.moved = true
    local hovered = owner:resolve_screen_position(x, y)
    if hovered <= lines[2] - 1 or hovered < lines[1] then
      self.target = 2
    elseif hovered > lines[#lines] then
      self.target = #lines
    else
      for index, row_line in ipairs(lines) do
        if row_line == hovered then self.target = math.max(2, index) break end
      end
    end
  end
  function drag.draw(self, owner)
    if not (self.moved and self.target) then return end
    draw_in_table_frame(owner, lines[1], function() self:draw_preview(owner) end)
  end
  function drag.draw_preview(self, owner)
    local x, from_y = owner:get_line_screen_position(lines[self.from])
    local from_bottom = line_bottom(owner, lines[self.from])
    renderer.draw_rect(
      x, from_y, spec.table_width, from_bottom - from_y,
      with_alpha(style.accent, 0.12)
    )
    if self.target == self.from then return end
    local target_line = lines[self.target]
    local edge_y = self.target > self.from and line_bottom(owner, target_line)
      or select(2, owner:get_line_screen_position(target_line))
    local thickness = math.max(2, math.floor(SCALE * 2 + 0.5))
    renderer.draw_rect(
      x, math.floor(edge_y - thickness / 2), spec.table_width, thickness, style.accent
    )
  end
  function drag.on_release(self, owner)
    if self.moved and self.target and self.target ~= self.from then
      core.log_quiet(
        "Markdown table handle moved row %d to %d in %s",
        self.from, self.target, owner.buffer:get_name()
      )
      markdown_tables.move_row_to(owner, lines[self.from], self.target)
    elseif not self.moved then
      markdown_tables.select_row(owner, lines[self.from])
    end
  end
  return drag
end

local function column_drag(view, spec, column, press_x)
  local context, lines = table_rows_for_drag(view, spec.line)
  if not context then return nil end
  local drag = { cursor = "hand", moved = false, from = column }
  local threshold = math.max(3, spec.text_line_height * 0.25)
  local cell_x = spec.cell_x
  function drag.on_move(self, owner, x)
    if not self.moved and math.abs(x - press_x) < threshold then return end
    self.moved = true
    local render = owner:get_line_render(lines[1])
    local scroll, clip = render and render.horizontal_scroll, render and render.horizontal_clip
    if scroll and clip then
      local left = owner:get_line_screen_position(lines[1]) + scroll.x + clip.x1
      local edge = spec.text_line_height * 2
      local step = x < left + edge and x - (left + edge)
        or x > left + clip.x2 - edge and x - (left + clip.x2 - edge) or 0
      if step ~= 0 then
        owner:set_line_render_horizontal_scroll(scroll, scroll.x + step, true)
      end
    end
    local relative = x - owner:get_line_screen_position(lines[1])
    if relative < cell_x[1].x1 then
      self.target = 1
    elseif relative >= cell_x[#cell_x].x2 then
      self.target = #cell_x
    else
      for index, bounds in ipairs(cell_x) do
        if relative >= bounds.x1 and relative < bounds.x2 then self.target = index break end
      end
    end
  end
  function drag.draw(self, owner)
    if not (self.moved and self.target) then return end
    draw_in_table_frame(owner, lines[1], function() self:draw_preview(owner) end)
  end
  function drag.draw_preview(self, owner)
    local x, top = owner:get_line_screen_position(lines[1])
    local bottom = line_bottom(owner, lines[#lines])
    local from = cell_x[self.from]
    renderer.draw_rect(
      x + from.x1, top, from.x2 - from.x1, bottom - top, with_alpha(style.accent, 0.12)
    )
    if self.target == self.from then return end
    local target = cell_x[self.target]
    local edge_x = x + (self.target > self.from and target.x2 or target.x1)
    local thickness = math.max(2, math.floor(SCALE * 2 + 0.5))
    renderer.draw_rect(
      math.floor(edge_x - thickness / 2), top, thickness, bottom - top, style.accent
    )
  end
  function drag.on_release(self, owner)
    if self.moved and self.target and self.target ~= self.from then
      core.log_quiet(
        "Markdown table handle moved column %d to %d in %s",
        self.from, self.target, owner.buffer:get_name()
      )
      markdown_tables.move_column_to(owner, lines[1], self.from, self.target)
    elseif not self.moved then
      markdown_tables.select_column(owner, lines[1], self.from)
    end
  end
  return drag
end

local function append_table_handles(view, fragments, spec)
  local thickness = math.max(4, math.floor(SCALE * 5 + 0.5))
  local length = math.max(thickness * 3, math.floor(spec.text_line_height * 0.85 + 0.5))
  local function handle(kind, index, layout_x, hit_width, hit_height, draw, start_drag)
    fragments[#fragments + 1] = {
      source_col1 = spec.source_col,
      source_col2 = spec.source_col,
      text = "",
      width = 0,
      hit_width = hit_width,
      layout_x = layout_x,
      draw_y_offset = 0,
      semantic_id = spec.table_node.id .. ":handle:" .. kind .. ":" .. index,
      table_handle = kind,
      table_handle_index = index,
      widget = {
        width = hit_width,
        height = hit_height,
        proximity_radius = spec.proximity_radius,
        suppress_hover_overlay = true,
        cursor = "hand",
        draw = function(_, fragment, draw_x, draw_y)
          local visibility = fragment.hovered and 1 or fragment.proximity or 0
          if visibility > 0.01 then draw(draw_x, draw_y, visibility) end
        end,
        on_mouse_pressed = function(_, owner, _, button, x, y)
          if button ~= "left" then return false end
          local drag = start_drag(owner, x, y)
          if not drag then return false end
          owner:begin_render_widget_drag(drag)
          return true
        end,
      },
    }
  end

  if not spec.header then
    -- The pill sits in the first cell's leading padding, between the left
    -- border and the text, so the gutter and the table frame never crop it.
    local hit_width = spec.separator_width + spec.padding
    handle("row", spec.line, 0, hit_width, spec.row_height,
      function(draw_x, draw_y, visibility)
        local height = math.min(length, spec.row_height - 4)
        local center = draw_x + (spec.separator_width * 1.5 + spec.padding) / 2
        draw_grip(
          math.floor(center - thickness / 2 + 0.5),
          draw_y + (spec.row_height - height) / 2,
          thickness, height, visibility, true
        )
      end,
      function(owner, _, y) return row_drag(owner, spec, y) end
    )
    return
  end
  local hit_height = thickness + math.max(2, math.floor(SCALE * 3))
  for column, bounds in ipairs(spec.cell_x) do
    local width = math.min(length * 1.4, (bounds.x2 - bounds.x1) * 0.6)
    local hit_width = width + spec.control_hit_size * 0.5
    handle("column", column, (bounds.x1 + bounds.x2 - hit_width) / 2, hit_width, hit_height,
      function(draw_x, draw_y, visibility)
        draw_grip(
          draw_x + (hit_width - width) / 2,
          draw_y + math.max(1, math.floor(SCALE * 2)),
          width, thickness, visibility, false
        )
      end,
      function(owner, x) return column_drag(owner, spec, column, x) end
    )
  end
end

-- A scrollbar in a band below an overflowing table's last row. It stays in
-- the table's frame while the rows scroll.
local function append_table_scrollbar(view, fragments, spec)
  local region, layout = spec.region, spec.layout
  local thickness = math.max(4, math.floor(SCALE * 6 + 0.5))
  local gap = math.max(3, math.floor(SCALE * 5 + 0.5))
  local band = gap * 2 + thickness
  local viewport = layout.viewport_width
  local function thumb(x)
    local content = viewport + region.max
    local width = math.max(thickness * 4, viewport * viewport / content)
    local offset = region.max > 0 and (viewport - width) * region.x / region.max or 0
    return x + offset, width
  end
  local function frame_left(owner)
    return owner:get_line_screen_position(spec.line) + region.x
  end
  fragments[#fragments + 1] = {
    source_col1 = spec.source_col,
    source_col2 = spec.source_col,
    text = "",
    width = 0,
    -- Rows shift left by the scroll offset; this hit area spans every
    -- visible offset, and Text View clips it to the frame.
    hit_width = layout.total_width + viewport,
    layout_x = 0,
    draw_y_offset = spec.row_height,
    semantic_id = spec.semantic_id,
    table_scrollbar = true,
    widget = {
      width = layout.total_width + viewport,
      height = band,
      cursor = "arrow",
      track_hover = true,
      suppress_hover_overlay = true,
      draw = function(_, fragment, draw_x, draw_y)
        local left = draw_x + region.x
        local y = draw_y + spec.row_height + gap
        renderer.draw_rounded_rect(
          left, y, viewport, thickness, thickness / 2,
          with_alpha(style.markdown_live_table_separator, 0.35)
        )
        local thumb_x, thumb_width = thumb(left)
        local color = (region.dragging or fragment.hovered) and style.scrollbar_active
          or style.scrollbar_hover
        renderer.draw_rounded_rect(thumb_x, y, thumb_width, thickness, thickness / 2, color)
      end,
      on_mouse_pressed = function(_, owner, _, button, x)
        if button ~= "left" then return false end
        local left = frame_left(owner)
        local thumb_x, thumb_width = thumb(left)
        local grab = x - thumb_x
        if grab < 0 or grab > thumb_width then
          -- A press on the track centers the thumb there, then drags it.
          grab = thumb_width / 2
          local travel = math.max(1, viewport - thumb_width)
          owner:set_line_render_horizontal_scroll(
            region, (x - left - grab) / travel * region.max, true
          )
        end
        region.dragging = true
        owner:begin_render_widget_drag({
          cursor = "arrow",
          on_move = function(_, drag_owner, move_x)
            local travel = math.max(1, viewport - thumb_width)
            drag_owner:set_line_render_horizontal_scroll(
              region, (move_x - frame_left(drag_owner) - grab) / travel * region.max, true
            )
          end,
          on_release = function() region.dragging = nil end,
        })
        core.log_quiet("Markdown Table Scroll scrollbar pressed in %s", owner.buffer:get_name())
        return true
      end,
    },
  }
  return band
end

---Return a table row's fragments, its table layout, caret position rows and
---row height. Cells that hold a caret in `selection_state` present source.
function table_presentation.row_fragments(view, table_node, line, instance, selection_state)
  local layout = table_presentation.layout(view, table_node, instance)
  if not layout then return nil end
  local row = layout.rows[line]
  if not row then return nil end
  local region
  if layout.scroll_max > 0 then
    region = table_presentation.scroll_state(view, layout.line1)
    region.max = layout.scroll_max
    region.x = math.min(region.x or 0, region.max)
    region.to = math.min(region.to or region.x, region.max)
  end
  local extras = region and {
    horizontal_scroll = region,
    horizontal_clip = { x1 = 0, x2 = layout.viewport_width },
  } or {}
  if line == layout.delimiter_line then
    local thickness = math.max(1, math.floor(SCALE))
    return {
      {
        source_col1 = 1, source_col2 = #row.text + 1,
        width = layout.total_width,
        semantic_id = table_node.id .. ":delimiter",
        table_separator = true,
        widget = {
          width = layout.total_width,
          height = thickness,
          draw = function(_, _, x, y)
            renderer.draw_rect(x, y, layout.total_width, thickness,
              style.markdown_live_table_separator)
          end,
        },
      },
    }, layout, nil, nil, extras
  end

  local fragments = {}
  local header = line == layout.line1
  local row_height = layout.row_heights[line] or live_fonts.body_line_height(view)
  local row_presentations, row_wrapped = {}, {}
  local function cell_active(cell)
    for index = 1, #(selection_state and selection_state.selections or {}), 4 do
      local line1, col1 = selection_state.selections[index], selection_state.selections[index + 1]
      local line2, col2 = selection_state.selections[index + 2], selection_state.selections[index + 3]
      -- A Table Cell Selection covers the whole cell and keeps it rendered;
      -- only a caret or a partial selection edits the cell's source.
      if line1 == line and line2 == line
      and cell.content_col1 < cell.content_col2
      and math.min(col1, col2) == cell.content_col1
      and math.max(col1, col2) == cell.content_col2
      then
        goto continue_selection
      end
      if line1 == line and col1 >= cell.col1 and col1 <= cell.col2 then return true end
      if line2 == line and col2 >= cell.col1 and col2 <= cell.col2 then return true end
      ::continue_selection::
    end
    return false
  end
  local max_lines = 1
  local base = inline_base(view, header)
  local active_runs
  local active_columns = {}
  for column, cell in ipairs(row.cells) do
    local presentation = layout.presentations[line][column]
    local wrapped = layout.wrapped_cells[line][column]
    local active = cell_active(cell)
    active_columns[column] = active
    if active then
      -- An active cell reveals the Markdown source of the span holding the
      -- caret, like prose. Elided cells reveal their complete source.
      local text, source_col1, source_col2 = table_cell_content(row.text, cell)
      if active_runs == nil and not presentation.source_elided then
        active_runs = row_inline_runs(view, row.text, line, selection_state, base) or false
      end
      presentation = not presentation.source_elided and rich_presentation(
        active_runs or nil, text, source_col1, source_col2, base
      ) or {
        text = text,
        source_col1 = source_col1,
        source_col2 = source_col2,
        font = base.base_font,
        color = base.color,
      }
      wrapped = presentation_lines(
        presentation, layout.widths[column] - layout.padding * 2
      )
    end
    row_presentations[column], row_wrapped[column] = presentation, wrapped
    max_lines = math.max(max_lines, #wrapped)
  end
  row_height = math.max(
    row_height,
    max_lines * layout.text_line_height + layout.vertical_padding * 2
  )
  local function border_fragment(separator, id, first)
    local line_width = math.max(1, math.floor(SCALE))
    return {
      source_col1 = separator.col1, source_col2 = separator.col2,
      text = "", width = layout.separator_width,
      semantic_id = id,
      table_border = true,
      widget = {
        width = layout.separator_width,
        height = row_height,
        draw = function(_, _, x, y, row_height)
          renderer.draw_rect(x, y, layout.separator_width, row_height,
            style.markdown_live_table_background)
          if header then
            renderer.draw_rect(x, y, layout.separator_width, row_height,
              style.markdown_live_table_header_background)
          end
          renderer.draw_rect(
            x + math.floor((layout.separator_width - line_width) / 2), y,
            line_width, row_height, style.markdown_live_table_separator
          )
          if header then
            renderer.draw_rect(
              x, y, first and layout.total_width or layout.separator_width, line_width,
              style.markdown_live_table_separator
            )
          end
          if not header then
            renderer.draw_rect(
              x, y + row_height - line_width, layout.separator_width, line_width,
              style.markdown_live_table_separator
            )
          end
        end,
      },
    }
  end
  for column, cell in ipairs(row.cells) do
    local presentation = row_presentations[column]
    local cell_font = presentation.font
    local alignment = layout.alignments[column]
    local text_lines = {}
    for _, wrapped in ipairs(row_wrapped[column]) do
      local wrapped_text = wrapped.text or ""
      local text_width = wrapped.runs and wrapped.width or cell_font:get_width(wrapped_text)
      local offset = alignment == "right"
        and math.max(layout.padding, layout.widths[column] - text_width - layout.padding)
        or alignment == "center"
        and math.max(layout.padding, (layout.widths[column] - text_width) / 2)
        or layout.padding
      text_lines[#text_lines + 1] = {
        text = wrapped_text,
        x_offset = offset,
        runs = wrapped.runs,
        source_col1 = wrapped.runs and wrapped.source_col1
          or presentation.source_col1 + (wrapped.col1 or 1) - 1,
        source_col2 = wrapped.runs and wrapped.source_col2
          or presentation.source_col1 + (wrapped.col2 or 1) - 1,
      }
    end
    local separator = row.separators[column]
    fragments[#fragments + 1] = border_fragment(
      separator, table_node.id .. ":pipe:" .. line .. ":" .. column, column == 1
    )
    fragments[#fragments + 1] = {
      source_col1 = cell.col1, source_col2 = cell.col2,
      text = presentation.text,
      width = layout.widths[column],
      text_x_offset = text_lines[1] and text_lines[1].x_offset or layout.padding,
      text_source_col1 = presentation.source_col1,
      text_source_col2 = presentation.source_col2,
      text_lines = text_lines,
      text_line_height = layout.text_line_height,
      text_y_padding = layout.vertical_padding,
      text_line_background = presentation.background,
      text_line_background_padding = presentation.background and math.max(1, SCALE * 2) or nil,
      table_alignment = alignment,
      font = cell_font,
      color = presentation.color,
      background = style.markdown_live_table_background,
      background_overlay = active_columns[column] and style.markdown_live_table_active_cell
        or header and style.markdown_live_table_header_background or nil,
      background_under_selection = true,
      background_full_height = true,
      background_border_top = header and style.markdown_live_table_separator or nil,
      background_border_bottom = not header and style.markdown_live_table_separator or nil,
      semantic_id = table_node.id .. ":cell:" .. line .. ":" .. column,
      table_cell = true, table_header = header, table_column = column,
    }
  end
  local separator = row.separators[#row.cells + 1]
  fragments[#fragments + 1] = border_fragment(
    separator, table_node.id .. ":pipe:" .. line .. ":end"
  )
  local position_rows = {}
  local fragment_x = 0
  local cell_x = {}
  for _, fragment in ipairs(fragments) do
    -- A table row is one shared grid. Source-position mappings describe caret
    -- placement inside cells, but must never reposition the border/cell
    -- fragments themselves; empty and differently wrapped rows would then
    -- draw each column at different x coordinates.
    fragment.layout_x = fragment_x
    if fragment.table_cell then
      cell_x[fragment.table_column] = {
        x1 = fragment_x,
        x2 = fragment_x + (fragment.width or 0),
      }
      for visual_index, text_line in ipairs(fragment.text_lines or {}) do
        position_rows[#position_rows + 1] = {
          source_col1 = text_line.source_col1,
          source_col2 = text_line.source_col2,
          end_inclusive = true,
          x_offset = fragment_x + (text_line.x_offset or 0),
          hit_x1 = fragment_x,
          hit_x2 = fragment_x + (fragment.width or 0),
          y_offset = (fragment.text_y_padding or 0)
            + (visual_index - 1) * (fragment.text_line_height or layout.text_line_height),
          height = fragment.text_line_height or layout.text_line_height,
          runs = text_line.runs,
          navigation_group = fragment.table_column,
          navigation_index = visual_index,
          table_cell = fragment.table_column,
          cell_source_col1 = fragment.text_source_col1,
          cell_source_col2 = fragment.text_source_col2,
          selection_full_cell = visual_index == 1,
          selection_empty_cell = visual_index == 1
            and fragment.text_source_col1 == fragment.text_source_col2,
          selection_x1 = fragment_x,
          selection_x2 = fragment_x + (fragment.width or 0),
          selection_y = 0,
          selection_height = row_height,
          selection_outline = style.caret,
          -- The active cell's tint marks the caret row inside a table.
          suppress_line_highlight = true,
        }
      end
    end
    fragment_x = fragment_x + (fragment.width or 0)
  end

  local control_size, control_hit_padding, control_hit_size =
    control_metrics(layout.text_line_height)
  local control_proximity_radius = math.max(
    layout.text_line_height * 1.6, control_size * 2
  )
  local function insertion_control(kind, after, source_col, x, y_offset, action)
    local icon_thickness = math.max(1, math.floor(control_size * 0.11 + 0.5))
    local icon_length = math.max(icon_thickness * 3, math.floor(control_size * 0.44))
    fragments[#fragments + 1] = {
      source_col1 = source_col,
      source_col2 = source_col,
      text = "",
      width = 0,
      hit_width = control_hit_size,
      layout_x = x - control_hit_padding,
      draw_y_offset = y_offset - control_hit_padding,
      control_size = control_size,
      semantic_id = table_node.id .. ":insert:" .. kind .. ":" .. tostring(after),
      table_insert_control = kind,
      table_insert_after = after,
      widget = {
        width = control_hit_size,
        height = control_hit_size,
        proximity_radius = control_proximity_radius,
        suppress_hover_overlay = true,
        cursor = "hand",
        draw = function(_, fragment, draw_x, draw_y)
          local visibility = fragment.hovered and 1 or fragment.proximity or 0
          if visibility <= 0.01 then return end
          visibility = visibility * visibility * (3 - 2 * visibility)
          local button_x = draw_x + control_hit_padding
          local button_y = draw_y + (fragment.draw_y_offset or 0)
            + control_hit_padding
          local accent = { table.unpack(style.accent) }
          accent[4] = (accent[4] or 255) * visibility * (0.35 + visibility * 0.4)
          renderer.draw_rounded_rect(
            button_x, button_y, control_size, control_size, control_size / 2,
            accent
          )
          local center_x = button_x + control_size / 2
          local center_y = button_y + control_size / 2
          local foreground = { table.unpack(style.background) }
          foreground[4] = (foreground[4] or 255) * visibility
          renderer.draw_rect(
            center_x - icon_length / 2, center_y - icon_thickness / 2,
            icon_length, icon_thickness, foreground
          )
          renderer.draw_rect(
            center_x - icon_thickness / 2, center_y - icon_length / 2,
            icon_thickness, icon_length, foreground
          )
        end,
        on_mouse_pressed = function(_, owner, _, button)
          if button ~= "left" then return false end
          core.log_quiet(
            "Markdown table Hover Insertion Control: insert %s after %s at %s:%d",
            kind, tostring(after), owner.buffer:get_name(), line
          )
          return action(owner)
        end,
      },
    }
  end
  if header and layout.canonical then
    for column, bounds in ipairs(cell_x) do
      local target_column = column
      local cell = row.cells[column]
      insertion_control(
        "column", column, cell.col2,
        bounds.x2 - control_size / 2,
        math.max(0, (row_height - control_size) / 2),
        function(owner)
          owner.buffer:set_selection(
            line, row_presentations[target_column].source_col1
          )
          return markdown_tables.insert_column(owner, "right")
        end
      )
    end
  end
  local first_bounds = cell_x[1]
  local first_presentation = row_presentations[1]
  if layout.canonical and first_bounds and first_presentation then
    insertion_control(
      "row", line, first_presentation.source_col1,
      (first_bounds.x1 + first_bounds.x2 - control_size) / 2,
      math.max(0, row_height - control_size - math.max(1, SCALE * 2)),
      function(owner)
        owner.buffer:set_selection(line, first_presentation.source_col1)
        return markdown_tables.insert_row(owner, "below")
      end
    )
  end
  if layout.canonical and first_bounds and first_presentation then
    append_table_handles(view, fragments, {
      table_node = table_node, line = line, header = header,
      cell_x = cell_x, table_width = fragment_x, row_height = row_height,
      text_line_height = layout.text_line_height,
      source_col = first_presentation.source_col1,
      control_hit_size = control_hit_size,
      padding = layout.padding,
      separator_width = layout.separator_width,
      proximity_radius = control_proximity_radius,
    })
  end
  if region and line == layout.line2 then
    extras.table_content_height = row_height
    row_height = row_height + append_table_scrollbar(view, fragments, {
      region = region, layout = layout, row_height = row_height, line = line,
      source_col = row.separators[1].col1,
      semantic_id = table_node.id .. ":scrollbar",
    })
  end
  return fragments, layout, position_rows, row_height, extras
end

function table_presentation.geometry_signature(view)
  local font = live_fonts.body(view)
  return table.concat({
    tostring(table_presentation.available_width(view)),
    tostring(style.markdown_body_font),
    tostring(font:get_size()),
    tostring(core.color_theme_generation or 0),
  }, ":")
end

return table_presentation
