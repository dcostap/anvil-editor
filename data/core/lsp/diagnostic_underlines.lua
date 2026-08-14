local core = require "core"
local style = require "core.style"
local TextView = require "core.textview"
local diagnostic_markers = require "core.lsp.diagnostic_markers"

local diagnostic_underlines = {}

local SQUIGGLE_Y_OFFSET = 2

local cache = setmetatable({}, { __mode = "k" })

local function buffer_change_id(buffer)
  if buffer and buffer.get_change_id then return buffer:get_change_id() end
  return nil
end

local function visible_severity(severity)
  severity = tonumber(severity)
  return severity == 1 or severity == 2
end

local function severity_color(severity)
  severity = tonumber(severity)
  if severity == 1 then return style.diagnostic_error_underline or style.error end
  if severity == 2 then return style.diagnostic_warning_underline or style.warn or style.error end
  return style.line_hint
end

local function line_visual_end_col(buffer, line)
  local text = buffer and buffer.lines and buffer.lines[line] or ""
  if text:sub(-1) == "\n" then return math.max(1, #text) end
  return #text + 1
end

local function clamp_col(buffer, line, col)
  return math.max(1, math.min(col or 1, line_visual_end_col(buffer, line)))
end

local function add_line_range(by_line, line, col1, col2, severity)
  local list = by_line[line]
  if not list then
    list = {}
    by_line[line] = list
  end
  list[#list + 1] = {
    line = line,
    col1 = col1,
    col2 = col2,
    severity = severity,
  }
end

local function build_line_ranges(buffer)
  local by_line = {}
  for _, item in ipairs(diagnostic_markers.visual_buffer_items(buffer)) do
    local diagnostic = item.diagnostic or {}
    local severity = tonumber(diagnostic.severity)
    if visible_severity(severity) and item.line1 then
      local line1 = math.max(1, item.line1)
      local line2 = math.min(item.line2 or line1, #(buffer.lines or {}))
      for line = line1, line2 do
        local col1 = line == line1 and item.col1 or 1
        local col2 = line == line2 and item.col2 or line_visual_end_col(buffer, line)
        col1 = clamp_col(buffer, line, col1)
        col2 = clamp_col(buffer, line, col2)
        if col2 < col1 then col1, col2 = col2, col1 end
        add_line_range(by_line, line, col1, col2, severity)
      end
    end
  end
  return by_line
end

local function cached_line_ranges(buffer)
  if not buffer then return {} end
  local generation = diagnostic_markers.generation and diagnostic_markers.generation() or 0
  local change_id = buffer_change_id(buffer)
  local entry = cache[buffer]
  if not entry or entry.generation ~= generation or entry.change_id ~= change_id then
    entry = {
      generation = generation,
      change_id = change_id,
      by_line = build_line_ranges(buffer),
    }
    cache[buffer] = entry
  end
  return entry.by_line
end

function diagnostic_underlines.ranges_for_line(buffer, line)
  return cached_line_ranges(buffer)[line] or {}
end

local function squiggle_metrics(view, y, content_height, content_font_height)
  local font_height = content_font_height or view:get_font():get_height()
  -- Match the rendered text font rather than the full visual row: the squiggle
  -- sits at the bottom of the rendered text and scales with the same font that
  -- produced the diagnostic text range.
  local thickness = math.max(1, math.ceil(font_height / 14))
  local wave_height = math.max(thickness * 2, math.ceil(font_height / 7))
  local step = math.max(wave_height, math.ceil(font_height / 4))
  local text_bottom = content_height
    and y + content_height
    or y + view:get_line_text_y_offset() + font_height
  local bottom = text_bottom - math.ceil(thickness / 2) + SQUIGGLE_Y_OFFSET
  local top = bottom - wave_height
  return top, bottom, thickness, step
end

local function rounded_point(x, y)
  return { math.floor(x + 0.5), math.floor(y + 0.5) }
end

local function draw_squiggle(x1, x2, top, bottom, thickness, step, color)
  local half_up = math.floor(thickness / 2)
  local half_down = math.ceil(thickness / 2)
  local centers = { { x = x1, y = top } }
  local index = 0
  local x = x1
  while x < x2 do
    index = index + 1
    x = math.min(x2, x1 + index * step)
    centers[#centers + 1] = { x = x, y = index % 2 == 1 and bottom or top }
  end
  if #centers < 2 then return end

  local points = {}
  for i = 1, #centers do
    local point = centers[i]
    points[#points + 1] = rounded_point(point.x, point.y - half_up)
  end
  for i = #centers, 1, -1 do
    local point = centers[i]
    points[#points + 1] = rounded_point(point.x, point.y + half_down)
  end
  renderer.draw_poly(points, color)
end

local function draw_segment(view, x1, x2, y, severity, content_height, font_height)
  local color = severity_color(severity)
  if not color then return end
  if x2 <= x1 then
    local width = view:get_font():get_width(" ")
    x2 = x1 + math.max(width, style.caret_width or 1)
  end
  local top, bottom, thickness, step = squiggle_metrics(
    view, y, content_height, font_height
  )
  draw_squiggle(x1, x2, top, bottom, thickness, step, color)
end

local function rendered_font_height(view, line, col1, col2)
  local render_line = view:get_line_render(line)
  if not render_line then return nil end
  local height
  for _, fragment in ipairs(view:iter_line_render_fragments(render_line)) do
    local fragment_col1 = fragment.source_col1 or 1
    local fragment_col2 = fragment.source_col2 or fragment_col1
    if not fragment.hidden and col2 > fragment_col1 and col1 < fragment_col2 then
      local font = fragment.font or view:get_font()
      height = math.max(height or 0, font:get_height())
    end
  end
  return height
end

local function draw_rendered_range(view, line, x, y, range)
  local font_height = rendered_font_height(view, line, range.col1, range.col2)
  if range.col1 == range.col2 then
    local x1 = x + view:get_col_x_offset(line, range.col1)
    local row_y, row_height = view:get_position_highlight_geometry(
      line, range.col1, false
    )
    draw_segment(view, x1, x1, row_y, range.severity, row_height, font_height)
    return
  end
  for x1, row_y, x2, row_height in view:iter_text_range_screen_segments(
    line, range.col1, range.col2, x, y
  ) do
    draw_segment(view, x1, x2, row_y, range.severity, row_height, font_height)
  end
end

local function draw_unwrapped_line(view, line, x, y, ranges)
  if view:get_line_render(line) then
    for _, range in ipairs(ranges) do
      draw_rendered_range(view, line, x, y, range)
    end
    return
  end
  for _, range in ipairs(ranges) do
    local x1 = x + view:get_col_x_offset(line, range.col1)
    local x2 = x + view:get_col_x_offset(line, range.col2)
    draw_segment(view, x1, x2, y, range.severity)
  end
end

local function total_wrapped_lines(view)
  return #(view.wrapped_lines or {}) / 2
end

local function wrapped_line_bounds(view, line, idx)
  local offset = (idx - 1) * 2
  if view.wrapped_lines[offset + 1] ~= line then return nil end
  local row_start = view.wrapped_lines[offset + 2] or 1
  local next_line = view.wrapped_lines[offset + 3]
  local next_start = view.wrapped_lines[offset + 4]
  local row_end = next_line == line and next_start or line_visual_end_col(view.buffer, line)
  return row_start, row_end
end

local function draw_wrapped_line(view, line, x, y, ranges)
  if view:get_line_render(line) then
    for _, range in ipairs(ranges) do
      draw_rendered_range(view, line, x, y, range)
    end
    return
  end
  local logical_first_idx = view.wrapped_line_to_idx and view.wrapped_line_to_idx[line]
  if not logical_first_idx then return draw_unwrapped_line(view, line, x, y, ranges) end
  local logical_last_idx = (view.wrapped_line_to_idx[line + 1] or (total_wrapped_lines(view) + 1)) - 1
  local first_idx = math.max(logical_first_idx, view.__wrapped_draw_first_idx or logical_first_idx)
  local last_idx = math.min(logical_last_idx, view.__wrapped_draw_last_idx or logical_last_idx)
  if last_idx < first_idx then return end
  local first_y_offset = view:get_visual_row_y_offset(logical_first_idx)
  for _, range in ipairs(ranges) do
    for idx = first_idx, last_idx do
      local row_start, row_end = wrapped_line_bounds(view, line, idx)
      local zero_width = range.col1 == range.col2
      local intersects = row_start and row_end and (
        zero_width
          and range.col1 >= row_start
          and (range.col1 < row_end or idx == last_idx and range.col1 == row_end)
        or not zero_width and range.col2 > row_start and range.col1 < row_end
      )
      if intersects then
        local col1 = math.max(range.col1, row_start)
        local col2 = zero_width and col1 or math.min(range.col2, row_end)
        local row_y = y + view:get_visual_row_y_offset(idx) - first_y_offset
        local x1 = x + view:get_col_x_offset(line, col1, false)
        local x2 = x + view:get_col_x_offset(line, col2, col2 == row_end)
        draw_segment(view, x1, x2, row_y, range.severity)
      end
    end
  end
end

function diagnostic_underlines.draw_line(view, line, x, y)
  local ranges = diagnostic_underlines.ranges_for_line(view and view.buffer, line)
  if #ranges == 0 then return false end
  if view.wrapped_settings and view.wrapped_lines and view.wrapped_line_to_idx then
    draw_wrapped_line(view, line, x, y, ranges)
  else
    draw_unwrapped_line(view, line, x, y, ranges)
  end
  return true
end

function diagnostic_underlines.install()
  TextView.__lsp_diagnostic_underlines_module = diagnostic_underlines
  if TextView.__lsp_diagnostic_underlines_installed then return false end
  TextView.__lsp_diagnostic_underlines_installed = true
  if core and core.log_quiet then
    core.log_quiet("LSP Diagnostic Underlines registered with Text View")
  end
  return true
end

diagnostic_underlines.install()

return diagnostic_underlines
