local core = require "core"
local style = require "core.style"
local DocView = require "core.docview"
local diagnostics = require "core.lsp.diagnostics"
local documents = require "core.lsp.documents"

local diagnostic_underlines = {}

local cache = setmetatable({}, { __mode = "k" })

local function doc_change_id(doc)
  if doc and doc.get_change_id then return doc:get_change_id() end
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

local function doc_sync_key(doc)
  if not doc then return "" end
  local states = documents.states_for_doc(doc)
  if #states == 0 then return "" end
  local parts = {}
  for _, state in ipairs(states) do
    local client = state.client or {}
    parts[#parts + 1] = table.concat({
      tostring(client.id or client.server_id or client),
      tostring(state.uri or ""),
      tostring(state.lsp_version or ""),
    }, "\31")
  end
  table.sort(parts)
  return table.concat(parts, "\30")
end

local function line_visual_end_col(doc, line)
  local text = doc and doc.lines and doc.lines[line] or ""
  if text:sub(-1) == "\n" then return math.max(1, #text) end
  return #text + 1
end

local function clamp_col(doc, line, col)
  return math.max(1, math.min(col or 1, line_visual_end_col(doc, line)))
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

local function build_line_ranges(doc)
  local by_line = {}
  for _, item in ipairs(diagnostics.current_document_items(doc)) do
    local diagnostic = item.diagnostic or {}
    local severity = tonumber(diagnostic.severity)
    if visible_severity(severity) and item.line1 then
      local line1 = math.max(1, item.line1)
      local line2 = math.min(item.line2 or line1, #(doc.lines or {}))
      for line = line1, line2 do
        local col1 = line == line1 and item.col1 or 1
        local col2 = line == line2 and item.col2 or line_visual_end_col(doc, line)
        col1 = clamp_col(doc, line, col1)
        col2 = clamp_col(doc, line, col2)
        if col2 < col1 then col1, col2 = col2, col1 end
        add_line_range(by_line, line, col1, col2, severity)
      end
    end
  end
  return by_line
end

local function cached_line_ranges(doc)
  if not doc then return {} end
  local generation = diagnostics.generation and diagnostics.generation() or 0
  local change_id = doc_change_id(doc)
  local sync_key = doc_sync_key(doc)
  local entry = cache[doc]
  if not entry or entry.generation ~= generation or entry.change_id ~= change_id
      or entry.sync_key ~= sync_key then
    entry = {
      generation = generation,
      change_id = change_id,
      sync_key = sync_key,
      by_line = build_line_ranges(doc),
    }
    cache[doc] = entry
  end
  return entry.by_line
end

function diagnostic_underlines.ranges_for_line(doc, line)
  return cached_line_ranges(doc)[line] or {}
end

local function underline_metrics(view, y)
  local font = view:get_font()
  local font_height = font:get_height()
  -- Match the editor font rather than the full visual row: the underline sits
  -- at the bottom of the rendered code text and scales like FreeType's own
  -- underline fallback in the native renderer.
  local thickness = math.max(1, math.ceil(font_height / 14))
  local baseline = y + view:get_line_text_y_offset() + font_height - thickness
  return baseline, thickness
end

local function draw_segment(view, x1, x2, y, severity)
  local color = severity_color(severity)
  if not color then return end
  if x2 <= x1 then
    local width = view:get_font():get_width(" ")
    x2 = x1 + math.max(width, style.caret_width or 1)
  end
  local uy, thickness = underline_metrics(view, y)
  renderer.draw_rect(x1, uy, x2 - x1, thickness, color)
end

local function draw_unwrapped_line(view, line, x, y, ranges)
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
  local row_end = next_line == line and next_start or line_visual_end_col(view.doc, line)
  return row_start, row_end
end

local function draw_wrapped_line(view, line, x, y, ranges)
  local first_idx = view.wrapped_line_to_idx and view.wrapped_line_to_idx[line]
  if not first_idx then return draw_unwrapped_line(view, line, x, y, ranges) end
  local last_idx = (view.wrapped_line_to_idx[line + 1] or (total_wrapped_lines(view) + 1)) - 1
  local lh = view:get_line_height()
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
        local row_y = y + (idx - first_idx) * lh
        local x1 = x + view:get_col_x_offset(line, col1)
        local x2 = x + view:get_col_x_offset(line, col2, col2 == row_end)
        draw_segment(view, x1, x2, row_y, range.severity)
      end
    end
  end
end

function diagnostic_underlines.draw_line(view, line, x, y)
  local ranges = diagnostic_underlines.ranges_for_line(view and view.doc, line)
  if #ranges == 0 then return false end
  if view.wrapped_settings and view.wrapped_lines and view.wrapped_line_to_idx then
    draw_wrapped_line(view, line, x, y, ranges)
  else
    draw_unwrapped_line(view, line, x, y, ranges)
  end
  return true
end

function diagnostic_underlines.install()
  if DocView.__lsp_diagnostic_underlines_installed then return false end
  local base_draw_line_body = DocView.draw_line_body
  DocView.__lsp_diagnostic_underlines_installed = true
  DocView.__lsp_diagnostic_underlines_base_draw_line_body = base_draw_line_body

  function DocView:draw_line_body(line, x, y)
    local height = base_draw_line_body(self, line, x, y)
    diagnostic_underlines.draw_line(self, line, x, y)
    return height
  end

  if core and core.log_quiet then
    core.log_quiet("LSP Diagnostic Underlines installed")
  end
  return true
end

diagnostic_underlines.install()

return diagnostic_underlines
