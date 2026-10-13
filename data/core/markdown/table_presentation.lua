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

  local pad = math.max(font:get_width(" ") * 1.5, SCALE * 6)
  local vertical_pad = math.max(math.floor(SCALE * 5), 2)
  local widths, presentations, active_presentations = {}, {}, {}
  local minimums = {}
  local selection_stable_layout = true
  for column = 1, columns do widths[column] = pad * 4 end
  for line = line1, line2 do
    if line ~= line1 + 1 then
      local row = rows[line]
      presentations[line] = {}
      active_presentations[line] = {}
      for column, cell in ipairs(row.cells) do
        local text, source_col1, source_col2 = table_cell_content(row.text, cell)
        local presentation = table_cell_presentation(
          view, text, source_col1, source_col2, line == line1
        )
        presentations[line][column] = presentation
        if presentation.source_elided then
          selection_stable_layout = false
        else
          active_presentations[line][column] = {
            text = text,
            source_col1 = source_col1,
            source_col2 = source_col2,
            font = line == line1 and live_fonts.inline_style(view, "strong") or font,
          }
        end
        widths[column] = math.max(
          widths[column], table_cell_natural_width(
            presentation.font, presentation.text, presentation.literal_breaks
          ) + pad * 2
        )
        local active = active_presentations[line][column]
        if active then
          widths[column] = math.max(
            widths[column],
            table_cell_natural_width(active.font, active.text) + pad * 2
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
      -- table's horizontal overflow instead of crushing every column.
      pad * 2 + font:get_width("MMMMMMMM")
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
      for column, cell in ipairs(row.cells) do
        local presentation = presentations[row_line][column]
        local wrapped = table_wrap_cell_text(
          presentation.font, presentation.text, widths[column] - pad * 2,
          presentation.literal_breaks
        )
        wrapped_cells[row_line][column] = wrapped
        max_lines = math.max(max_lines, #wrapped)
        local active = active_presentations[row_line][column]
        if active then
          max_lines = math.max(
            max_lines,
            #table_wrap_cell_text(
              active.font, active.text, widths[column] - pad * 2
            )
          )
        end
      end
      row_heights[row_line] = max_lines * text_line_height + vertical_pad * 2
    end
  end
  local layout = {
    id = table_node.id, line1 = line1, line2 = line2,
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

function table_presentation.cached_horizontal_extent(view)
  local cache = view.__markdown_live_table_layout_cache
  if not cache then return 0 end
  local font = live_fonts.body(view)
  local bucket = cache.buckets[table_geometry_key(font, table_presentation.available_width(view))]
  local width = 0
  for _, layout in pairs(bucket and bucket.layouts or {}) do
    if layout then width = math.max(width, tonumber(layout.total_width) or 0) end
  end
  return width
end

---Return a table row's fragments, its table layout, caret position rows and
---row height. Cells that hold a caret in `selection_state` present source.
function table_presentation.row_fragments(view, table_node, line, instance, selection_state)
  local layout = table_presentation.layout(view, table_node, instance)
  if not layout then return nil end
  local row = layout.rows[line]
  if not row then return nil end
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
    }, layout
  end

  local fragments = {}
  local header = line == layout.line1
  local row_height = layout.row_heights[line] or live_fonts.body_line_height(view)
  local row_presentations, row_wrapped = {}, {}
  local function cell_active(cell)
    for index = 1, #(selection_state and selection_state.selections or {}), 4 do
      local line1, col1 = selection_state.selections[index], selection_state.selections[index + 1]
      local line2, col2 = selection_state.selections[index + 2], selection_state.selections[index + 3]
      if line1 == line and col1 >= cell.col1 and col1 <= cell.col2 then return true end
      if line2 == line and col2 >= cell.col1 and col2 <= cell.col2 then return true end
    end
    return false
  end
  local max_lines = 1
  for column, cell in ipairs(row.cells) do
    local presentation = layout.presentations[line][column]
    local wrapped = layout.wrapped_cells[line][column]
    if cell_active(cell) then
      local text, source_col1, source_col2 = table_cell_content(row.text, cell)
      presentation = {
        text = text,
        source_col1 = source_col1,
        source_col2 = source_col2,
        font = header and live_fonts.inline_style(view, "strong") or live_fonts.body(view),
        color = header and style.markdown_live_table_header or style.markdown_live_table_cell,
      }
      wrapped = table_wrap_cell_text(
        presentation.font, text, layout.widths[column] - layout.padding * 2,
        presentation.literal_breaks
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
      local text_width = cell_font:get_width(wrapped_text)
      local offset = alignment == "right"
        and math.max(layout.padding, layout.widths[column] - text_width - layout.padding)
        or alignment == "center"
        and math.max(layout.padding, (layout.widths[column] - text_width) / 2)
        or layout.padding
      text_lines[#text_lines + 1] = {
        text = wrapped_text,
        x_offset = offset,
        source_col1 = presentation.source_col1 + (wrapped.col1 or 1) - 1,
        source_col2 = presentation.source_col1 + (wrapped.col2 or 1) - 1,
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
        }
      end
    end
    fragment_x = fragment_x + (fragment.width or 0)
  end

  local control_size = math.max(
    math.floor(SCALE * 6),
    math.floor(layout.text_line_height * 0.72 + 0.5)
  )
  local control_hit_padding = math.max(
    math.floor(SCALE * 2), math.floor(control_size * 0.18 + 0.5)
  )
  local control_hit_size = control_size + control_hit_padding * 2
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
  return fragments, layout, position_rows, row_height
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
