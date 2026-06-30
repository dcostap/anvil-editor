local core = require "core"
local common = require "core.common"
local style = require "core.style"
local config = require "core.config"

local LineWrapping = {}

---@class config.plugins.linewrapping
---@field mode "letter" | "word"
---@field width_override? number | function():number
---@field guide boolean
---@field guide_color? renderer.color
---@field indent boolean
---@field wrapping_indent integer | "none" | "indent" | "deepIndent"
---@field enable_by_default boolean
---@field require_tokenization boolean
config.plugins.linewrapping.config_spec = {
  name = "Line Wrapping",
  {
    label = "Mode",
    description = "The type of wrapping to perform.",
    path = "mode",
    type = "selection",
    default = "letter",
    values = {
      {"Letters", "letter"},
      {"Words", "word"}
    }
  },
  {
    label = "Guide",
    description = "Whether or not to draw a guide.",
    path = "guide",
    type = "toggle",
    default = true
  },
  {
    label = "Indent",
    description = "Whether or not to follow the indentation of wrapped line.",
    path = "indent",
    type = "toggle",
    default = true
  },
  {
    label = "Wrapping Indent",
    description = "Extra visual indentation before wrapped continuation lines.",
    path = "wrapping_indent",
    type = "selection",
    default = 0,
    values = {
      {"None", "none"},
      {"Follow Indent", "indent"},
      {"Deep Indent", "deepIndent"},
      {"0 spaces", 0},
      {"2 spaces", 2},
      {"4 spaces", 4},
      {"6 spaces", 6},
      {"8 spaces", 8},
    }
  },
  {
    label = "Enable by Default",
    description = "Whether or not to enable wrapping by default when opening files.",
    path = "enable_by_default",
    type = "toggle",
    default = false
  },
  {
    label = "Require Tokenization",
    description = "Use tokenization when applying wrapping.",
    path = "require_tokenization",
    type = "toggle",
    default = false
  }
}

local function perf_frame_add(key, amount)
  local perf = package.loaded["core.perf"]
  if perf and perf.frame_add then perf.frame_add(key, amount or 1) end
end

local function perf_elapsed(key, start_time)
  if start_time then perf_frame_add(key, (system.get_time() - start_time) * 1000) end
end

-- Optimization iterator. The tokenizer is relatively slow, so if wrapping does
-- not need syntax fonts, expose the whole line as a single normal token.
local function spew_tokens(doc, line)
  if line < math.huge then return math.huge, "normal", doc:get_utf8_line(line) end
end

local function get_tokens(doc, line)
  if config.plugins.linewrapping.require_tokenization then
    return doc.highlighter:each_token(line)
  end
  return spew_tokens, doc, line
end

function LineWrapping.get_tokens(doc, line)
  return get_tokens(doc, line)
end

function LineWrapping.continuation_indent_width(font, text)
  local mode = config.plugins.linewrapping.wrapping_indent
  if mode == "none" or config.plugins.linewrapping.indent == false then
    return 0
  end

  local width = 0
  local _, indent_end = text:find("^%s+")
  if indent_end then
    width = font:get_width(text:sub(1, indent_end))
  end

  local numeric_spaces = tonumber(mode)
  if numeric_spaces and numeric_spaces > 0 then
    width = width + font:get_width(string.rep(" ", numeric_spaces))
  elseif mode == "indent" or mode == "deepIndent" then
    local levels = mode == "deepIndent" and 2 or 1
    width = width + font:get_width(string.rep(" ", (config.indent_size or 4) * levels))
  end

  return width
end

-- Computes the breaks for a given line, width and mode. Returns a list of byte
-- columns where visual rows start, plus the continuation indent width.
function LineWrapping.compute_line_breaks(doc, default_font, line, width, mode)
  local perf_active = core.perf_frame_stats ~= nil
  local perf_start = perf_active and system.get_time()
  local perf_bytes = 0
  local xoffset, i, last_space, last_width, begin_width = 0, 1, nil, 0, 0
  local splits = { 1 }
  local default_ascii_cell_width = default_font:get_width(" ")
  for idx, type, text in get_tokens(doc, line) do
    perf_bytes = perf_bytes + #text
    local font = style.syntax_fonts[type] or default_font
    if idx == 1 or idx == math.huge then
      begin_width = LineWrapping.continuation_indent_width(font, text)
    end
    local plain_ascii_default_font = font == default_font and not text:find("[\t\128-\255]")
    local w = plain_ascii_default_font and (#text * default_ascii_cell_width) or font:get_width(text)
    if xoffset + w > width then
      for char in common.utf8_chars(text) do
        w = plain_ascii_default_font and default_ascii_cell_width or font:get_width(char)
        xoffset = xoffset + w
        if xoffset > width then
          if mode == "word" and last_space then
            table.insert(splits, last_space + 1)
            xoffset = w + begin_width + (xoffset - last_width)
          else
            table.insert(splits, i)
            xoffset = w + begin_width
          end
          last_space = nil
        elseif char == " " then
          last_space = i
          last_width = xoffset
        end
        i = i + #char
      end
    else
      xoffset = xoffset + w
      i = i + #text
    end
  end
  perf_frame_add("linewrapping_compute_line_breaks_calls", 1)
  perf_frame_add("linewrapping_compute_line_breaks_bytes", perf_bytes)
  perf_frame_add("linewrapping_compute_line_breaks_splits", #splits)
  perf_elapsed("linewrapping_compute_line_breaks_ms", perf_start)
  return splits, begin_width
end

function LineWrapping.clear_wrap_cache(docview)
  docview.wrapped_lines = nil
  docview.wrapped_line_to_idx = nil
  docview.wrapped_line_offsets = nil
  docview.wrapped_settings = nil
end

function LineWrapping.reconstruct_breaks(docview, default_font, width, line_offset)
  local perf_active = core.perf_frame_stats ~= nil
  local perf_start = perf_active and system.get_time()
  local reconstructed_lines = 0
  if width ~= math.huge then
    local doc = docview.doc
    docview.wrapped_lines = {}
    docview.wrapped_line_to_idx = {}
    docview.wrapped_line_offsets = {}
    docview.wrapped_settings = { width = width, font = default_font }
    for i = line_offset or 1, #doc.lines do
      reconstructed_lines = reconstructed_lines + 1
      local breaks, offset = LineWrapping.compute_line_breaks(doc, default_font, i, width, config.plugins.linewrapping.mode)
      table.insert(docview.wrapped_line_offsets, offset)
      for _, col in ipairs(breaks) do
        table.insert(docview.wrapped_lines, i)
        table.insert(docview.wrapped_lines, col)
      end
    end
    local last_wrap = nil
    for i = 1, #docview.wrapped_lines, 2 do
      if not last_wrap or last_wrap ~= docview.wrapped_lines[i] then
        table.insert(docview.wrapped_line_to_idx, (i + 1) / 2)
        last_wrap = docview.wrapped_lines[i]
      end
    end
  else
    LineWrapping.clear_wrap_cache(docview)
  end
  perf_frame_add("linewrapping_reconstruct_breaks_calls", 1)
  perf_frame_add("linewrapping_reconstruct_breaks_lines", reconstructed_lines)
  perf_elapsed("linewrapping_reconstruct_breaks_ms", perf_start)
end

function LineWrapping.update_breaks(docview, old_line1, old_line2, net_lines)
  local perf_active = core.perf_frame_stats ~= nil
  local perf_start = perf_active and system.get_time()
  local perf_lines = 0
  local old_idx1 = docview.wrapped_line_to_idx[old_line1] or 1
  local old_idx2 = (docview.wrapped_line_to_idx[old_line2 + 1] or ((#docview.wrapped_lines / 2) + 1)) - 1
  local offset = (old_idx1 - 1) * 2 + 1
  for _ = old_idx1, old_idx2 do
    table.remove(docview.wrapped_lines, offset)
    table.remove(docview.wrapped_lines, offset)
  end
  for _ = old_line1, old_line2 do
    table.remove(docview.wrapped_line_offsets, old_line1)
  end
  if net_lines ~= 0 then
    for i = offset, #docview.wrapped_lines, 2 do
      docview.wrapped_lines[i] = docview.wrapped_lines[i] + net_lines
    end
  end
  local new_line1 = old_line1
  local new_line2 = old_line2 + net_lines
  for line = new_line1, new_line2 do
    perf_lines = perf_lines + 1
    local breaks, begin_width = LineWrapping.compute_line_breaks(docview.doc, docview.wrapped_settings.font, line, docview.wrapped_settings.width, config.plugins.linewrapping.mode)
    table.insert(docview.wrapped_line_offsets, line, begin_width)
    for _, b in ipairs(breaks) do
      table.insert(docview.wrapped_lines, offset, b)
      table.insert(docview.wrapped_lines, offset, line)
      offset = offset + 2
    end
  end
  local line = old_line1
  offset = (old_idx1 - 1) * 2 + 1
  while offset < #docview.wrapped_lines do
    if docview.wrapped_lines[offset + 1] == 1 then
      docview.wrapped_line_to_idx[line] = ((offset - 1) / 2) + 1
      line = line + 1
    end
    offset = offset + 2
  end
  while line <= #docview.wrapped_line_to_idx do
    table.remove(docview.wrapped_line_to_idx)
  end
  perf_frame_add("linewrapping_update_breaks_calls", 1)
  perf_frame_add("linewrapping_update_breaks_lines", perf_lines)
  perf_elapsed("linewrapping_update_breaks_ms", perf_start)
end

function LineWrapping.guide_color()
  return config.plugins.linewrapping.guide_color or style.line_wrapping_guide
end

function LineWrapping.draw_guide(docview)
  if config.plugins.linewrapping.guide and docview.wrapped_settings.width ~= math.huge then
    local x = docview:get_content_offset()
    local gw = docview:get_gutter_width()
    renderer.draw_rect(
      x + gw + docview.wrapped_settings.width,
      docview.position.y,
      math.max(1, math.floor(SCALE)),
      docview.size.y,
      LineWrapping.guide_color()
    )
  end
end

function LineWrapping.compute_wrap_width(docview)
  local scrollbar_width = docview.v_scrollbar.expanded_size or style.expanded_scrollbar_size
  local override = config.plugins.linewrapping.width_override
  if type(override) == "function" then return override(docview) end
  return override or (docview.size.x - docview:get_gutter_width() - scrollbar_width)
end

function LineWrapping.update_docview_breaks(docview)
  local perf_active = core.perf_frame_stats ~= nil
  local perf_start = perf_active and system.get_time()
  local width = LineWrapping.compute_wrap_width(docview)
  if not docview.wrapped_settings or docview.wrapped_settings.width == nil or width ~= docview.wrapped_settings.width then
    perf_frame_add("linewrapping_update_docview_breaks_width_changed", 1)
    docview.scroll.to.x = 0
    LineWrapping.reconstruct_breaks(docview, docview:get_font(), width)
  end
  perf_frame_add("linewrapping_update_docview_breaks_calls", 1)
  perf_elapsed("linewrapping_update_docview_breaks_ms", perf_start)
end

function LineWrapping.get_idx_line_col(docview, idx)
  local doc = docview.doc
  if not docview.wrapped_settings then
    if idx > #doc.lines then return #doc.lines, #doc.lines[#doc.lines] + 1 end
    return idx, 1
  end
  if idx < 1 then return 1, 1 end
  local offset = (idx - 1) * 2 + 1
  if offset > #docview.wrapped_lines then return #doc.lines, #doc.lines[#doc.lines] + 1 end
  return docview.wrapped_lines[offset], docview.wrapped_lines[offset + 1]
end

function LineWrapping.get_total_wrapped_lines(docview)
  if not docview.wrapped_settings then return docview.doc and #docview.doc.lines end
  return #docview.wrapped_lines / 2
end

local function selection_state_key(doc)
  return table.concat(doc.selections, "\31") .. "\30" .. tostring(doc.last_selection)
end
LineWrapping.selection_state_key = selection_state_key

function LineWrapping.position_key(line, col)
  return tostring(line) .. ":" .. tostring(col)
end

function LineWrapping.clear_wrapped_line_end_affinity(docview)
  docview.wrapped_line_end_affinity = nil
end

function LineWrapping.set_wrapped_line_end_affinity(docview, positions)
  if positions and next(positions) then
    docview.wrapped_line_end_affinity = {
      selection_key = selection_state_key(docview.doc),
      positions = positions,
    }
  else
    LineWrapping.clear_wrapped_line_end_affinity(docview)
  end
end

function LineWrapping.has_wrapped_line_end_affinity(docview, line, col)
  local state = docview and docview.wrapped_line_end_affinity
  if not state or not line or not col or not docview.doc then return false end
  if state.selection_key ~= selection_state_key(docview.doc) then
    LineWrapping.clear_wrapped_line_end_affinity(docview)
    return false
  end
  return state.positions[LineWrapping.position_key(line, col)] == true
end

function LineWrapping.get_idx_visual_end_col(docview, idx, line)
  local nline, ncol = LineWrapping.get_idx_line_col(docview, idx + 1)
  if nline == line then return ncol, true end
  return #docview.doc.lines[line], false
end

function LineWrapping.get_line_idx_col_count(docview, line, col, line_end)
  local doc = docview.doc
  if not docview.wrapped_settings then return common.clamp(line, 1, #doc.lines), col, 1, 1 end
  if line > #doc.lines then return LineWrapping.get_line_idx_col_count(docview, #doc.lines, #doc.lines[#doc.lines] + 1) end
  line = math.max(line, 1)
  local idx = docview.wrapped_line_to_idx[line] or 1
  local ncol, scol = 1, 1
  if col then
    local i = idx + 1
    while line == docview.wrapped_lines[(i - 1) * 2 + 1] and col >= docview.wrapped_lines[(i - 1) * 2 + 2] do
      local nscol = docview.wrapped_lines[(i - 1) * 2 + 2]
      if line_end and col == nscol then break end
      scol = nscol
      i = i + 1
      idx = idx + 1
    end
    ncol = (col - scol) + 1
  end
  local count = (docview.wrapped_line_to_idx[line + 1] or (LineWrapping.get_total_wrapped_lines(docview) + 1)) - (docview.wrapped_line_to_idx[line] or LineWrapping.get_total_wrapped_lines(docview))
  return idx, ncol, count, scol
end

function LineWrapping.get_line_col_from_index_and_x(docview, idx, x)
  local doc = docview.doc
  local line, col = LineWrapping.get_idx_line_col(docview, idx)
  if idx < 1 then return 1, 1, false end
  local row_end_col, soft_end = LineWrapping.get_idx_visual_end_col(docview, idx, line)
  local xoffset, last_i, i, last_w = (col ~= 1 and docview.wrapped_line_offsets[line] or 0), col, 1, 0
  if x < xoffset then return line, col, false end
  local default_font = docview:get_font()
  for _, type, text in doc.highlighter:each_token(line) do
    local font, w = style.syntax_fonts[type] or default_font, last_w
    for char in common.utf8_chars(text) do
      if i >= row_end_col then
        if xoffset >= x then
          local target_col = xoffset - x > (w / 2) and last_i or row_end_col
          return line, target_col, soft_end and target_col == row_end_col
        end
        return line, row_end_col, soft_end
      end
      if i >= col then
        if xoffset >= x then
          return line, (xoffset - x > (w / 2) and last_i or i), false
        end
        w = font:get_width(char)
        last_w = w
        xoffset = xoffset + w
      end
      last_i = i
      i = i + #char
    end
  end
  if i >= row_end_col and xoffset >= x and last_w > 0 then
    local target_col = xoffset - x > (last_w / 2) and last_i or row_end_col
    return line, target_col, soft_end and target_col == row_end_col
  end
  return line, row_end_col, soft_end
end

function LineWrapping.get_idx_line_length(docview, idx)
  local doc = docview.doc
  if not docview.wrapped_settings then
    if idx > #doc.lines then return #doc.lines[#doc.lines] + 1 end
    return #doc.lines[idx]
  end
  local offset = (idx - 1) * 2 + 1
  if docview.wrapped_lines[offset + 2] and docview.wrapped_lines[offset + 2] == docview.wrapped_lines[offset] then
    return docview.wrapped_lines[offset + 3] - docview.wrapped_lines[offset + 1]
  end
  return #doc.lines[docview.wrapped_lines[offset]] - docview.wrapped_lines[offset + 1] + 1
end

function LineWrapping.get_wrapped_line_count(docview, line)
  if not docview.wrapped_settings then return 1 end
  local total = #docview.wrapped_lines / 2
  local first = docview.wrapped_line_to_idx[line] or total
  local next_first = docview.wrapped_line_to_idx[line + 1] or (total + 1)
  return math.max(1, next_first - first)
end

return LineWrapping
