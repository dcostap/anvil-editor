local core = require "core"
local common = require "core.common"
local style = require "core.style"
local config = require "core.config"

local LineWrapping = {}

local views_by_doc = setmetatable({}, { __mode = "k" })
local width_providers = {}

function LineWrapping.register_width_provider(id, fn)
  assert(type(id) == "string" and id ~= "", "line wrapping width provider id must be a non-empty string")
  assert(fn == nil or type(fn) == "function", "line wrapping width provider must be a function or nil")
  width_providers[id] = fn
end

function LineWrapping.unregister_width_provider(id)
  width_providers[id] = nil
end

local function configured_width_override(docview)
  local override = config.plugins.linewrapping.width_override
  if type(override) == "function" then return override(docview) end
  return override
end

local function provided_wrap_width(docview)
  for id, provider in pairs(width_providers) do
    local ok, width = pcall(provider, docview)
    if ok and width ~= nil then return width end
    if not ok and core and core.log_quiet then
      core.log_quiet("Line wrapping width provider %s failed for %s: %s", tostring(id), tostring(docview), tostring(width))
    end
  end
end

local function compact_views(doc, views)
  local compacted = setmetatable({}, { __mode = "v" })
  for _, view in pairs(views) do
    if view and view.doc == doc then
      compacted[#compacted + 1] = view
    end
  end
  if #compacted > 0 then
    views_by_doc[doc] = compacted
    return compacted
  end
  views_by_doc[doc] = nil
end

function LineWrapping.register_docview(docview)
  local doc = docview and docview.doc
  if not doc then return end
  local views = views_by_doc[doc]
  if views then
    views = compact_views(doc, views)
  end
  if not views then
    views = setmetatable({}, { __mode = "v" })
    views_by_doc[doc] = views
  end
  for _, view in pairs(views) do
    if view == docview then return end
  end
  views[#views + 1] = docview
end

function LineWrapping.unregister_docview(docview)
  local doc = docview and docview.doc
  local views = doc and views_by_doc[doc]
  if not views then return end
  local compacted = setmetatable({}, { __mode = "v" })
  for _, view in pairs(views) do
    if view and view ~= docview and view.doc == doc then
      compacted[#compacted + 1] = view
    end
  end
  views_by_doc[doc] = #compacted > 0 and compacted or nil
end

local function each_wrapped_docview(doc, fn)
  local views = views_by_doc[doc]
  if not views then return end
  views = compact_views(doc, views)
  if not views then return end
  for _, docview in ipairs(views) do
    if docview.wrapped_settings then
      fn(docview)
    end
  end
end

function LineWrapping.notify_doc_raw_insert(doc, line, old_lines)
  each_wrapped_docview(doc, function(docview)
    local lines = #doc.lines - old_lines
    LineWrapping.update_breaks(docview, line, line, lines)
  end)
end

function LineWrapping.notify_doc_raw_remove(doc, line1, line2, old_lines)
  each_wrapped_docview(doc, function(docview)
    local lines = #doc.lines - old_lines
    LineWrapping.update_breaks(docview, line1, line2, lines)
  end)
end

function LineWrapping.notify_doc_text_input(doc, result)
  if not result or not result.changed then return end
  each_wrapped_docview(doc, function(docview)
    LineWrapping.set_wrapped_line_end_affinity(docview, LineWrapping.collect_soft_wrap_row_start_affinity(docview))
  end)
end

function LineWrapping.notify_doc_text_transaction(doc, transaction)
  local ranges = transaction and transaction.changed_ranges
  if not ranges then return end
  each_wrapped_docview(doc, function(docview)
    if #ranges == 1 then
      local range = ranges[1]
      LineWrapping.update_breaks(docview, range.old_line1, range.old_line2, range.line_delta or 0)
    else
      LineWrapping.reconstruct_breaks(docview, docview.wrapped_settings.font, docview.wrapped_settings.width)
    end
  end)
end

function LineWrapping.notify_doc_close(doc)
  views_by_doc[doc] = nil
end

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
    description = "Extra visual spaces added before wrapped continuation lines. Runtime also accepts 'none', 'indent', and 'deepIndent'.",
    path = "wrapping_indent",
    type = "number",
    default = 0
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

local function append_plain_ascii_letter_splits(splits, start_col, byte_len, xoffset, cell_width, width, begin_width)
  local token_end = start_col + byte_len - 1
  local first_capacity = math.floor((width - xoffset) / cell_width)
  local split_col = start_col + math.max(0, first_capacity)
  if split_col > token_end then
    return xoffset + byte_len * cell_width
  end

  local continuation_capacity = math.max(1, math.floor((width - begin_width) / cell_width))
  local last_row_start = split_col
  repeat
    splits[#splits + 1] = split_col
    last_row_start = split_col
    split_col = split_col + continuation_capacity
  until split_col > token_end

  return begin_width + (token_end - last_row_start + 1) * cell_width
end

local function append_plain_ascii_word_splits(splits, text, start_col, byte_len, xoffset, cell_width, width, begin_width, last_space, last_width)
  local col = start_col
  local token_end = start_col + byte_len - 1
  for j = 1, byte_len do
    xoffset = xoffset + cell_width
    if xoffset > width then
      if last_space then
        splits[#splits + 1] = last_space + 1
        xoffset = cell_width + begin_width + (xoffset - last_width)
      else
        splits[#splits + 1] = col
        xoffset = cell_width + begin_width
      end
      last_space = nil
      last_width = nil
    elseif text:byte(j) == 32 then
      last_space = col
      last_width = xoffset
    end
    col = col + 1
  end
  if last_space and last_space > token_end then
    last_space = nil
    last_width = nil
  end
  return xoffset, last_space, last_width
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
  local line_text = doc:get_utf8_line(line)
  local visible_end_col = #line_text
  if line_text:sub(-1) == "\n" then visible_end_col = visible_end_col - 1 end
  local default_ascii_cell_width = default_font:get_width(" ")
  for idx, type, text in get_tokens(doc, line) do
    if i > visible_end_col then break end
    if i + #text - 1 > visible_end_col then
      text = text:sub(1, visible_end_col - i + 1)
    end
    perf_bytes = perf_bytes + #text
    local font = style.syntax_fonts[type] or default_font
    if idx == 1 or idx == math.huge then
      begin_width = LineWrapping.continuation_indent_width(font, text)
    end
    local plain_ascii_default_font = font == default_font and not text:find("[\t\128-\255]")
    local w = plain_ascii_default_font and (#text * default_ascii_cell_width) or font:get_width(text)
    if xoffset + w > width then
      if plain_ascii_default_font and mode ~= "word" then
        xoffset = append_plain_ascii_letter_splits(splits, i, #text, xoffset, default_ascii_cell_width, width, begin_width)
        i = i + #text
        last_space = nil
      elseif plain_ascii_default_font then
        xoffset, last_space, last_width = append_plain_ascii_word_splits(
          splits, text, i, #text, xoffset, default_ascii_cell_width, width, begin_width, last_space, last_width
        )
        i = i + #text
      else
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

local function wrap_settings_signature(docview, default_font, width)
  local _, indent_size = docview.doc:get_indent_info()
  return {
    width = width,
    font = default_font,
    font_size = default_font and default_font:get_size(),
    mode = config.plugins.linewrapping.mode,
    indent = config.plugins.linewrapping.indent,
    wrapping_indent = config.plugins.linewrapping.wrapping_indent,
    require_tokenization = config.plugins.linewrapping.require_tokenization,
    indent_size = indent_size,
  }
end

local function same_wrap_settings(a, b)
  if not a or not b then return false end
  return a.width == b.width
    and a.font == b.font
    and a.font_size == b.font_size
    and a.mode == b.mode
    and a.indent == b.indent
    and a.wrapping_indent == b.wrapping_indent
    and a.require_tokenization == b.require_tokenization
    and a.indent_size == b.indent_size
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
    docview.wrapped_settings = wrap_settings_signature(docview, default_font, width)
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
  local remove_count = math.max(0, old_idx2 - old_idx1 + 1) * 2
  local new_line1 = old_line1
  local new_line2 = old_line2 + net_lines
  local new_pairs = {}
  local new_offsets = {}

  for line = new_line1, new_line2 do
    perf_lines = perf_lines + 1
    local breaks, begin_width = LineWrapping.compute_line_breaks(docview.doc, docview.wrapped_settings.font, line, docview.wrapped_settings.width, config.plugins.linewrapping.mode)
    new_offsets[#new_offsets + 1] = begin_width
    for _, b in ipairs(breaks) do
      new_pairs[#new_pairs + 1] = line
      new_pairs[#new_pairs + 1] = b
    end
  end

  common.splice(docview.wrapped_lines, offset, remove_count, new_pairs)
  common.splice(docview.wrapped_line_offsets, old_line1, old_line2 - old_line1 + 1, new_offsets)

  if net_lines ~= 0 then
    for i = offset + #new_pairs, #docview.wrapped_lines, 2 do
      docview.wrapped_lines[i] = docview.wrapped_lines[i] + net_lines
    end
  end

  local line = old_line1
  offset = (old_idx1 - 1) * 2 + 1
  -- Every logical line contributes an initial visual-row entry at column 1.
  -- Use that invariant to rebuild the logical-line -> first visual-row map
  -- after the flat wrapped_lines array has been spliced.
  while offset <= #docview.wrapped_lines do
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
  return configured_width_override(docview)
    or provided_wrap_width(docview)
    or (docview.size.x - docview:get_gutter_width() - scrollbar_width)
end

function LineWrapping.update_docview_breaks(docview)
  local perf_active = core.perf_frame_stats ~= nil
  local perf_start = perf_active and system.get_time()
  local width = LineWrapping.compute_wrap_width(docview)
  local settings = wrap_settings_signature(docview, docview:get_font(), width)
  if not same_wrap_settings(docview.wrapped_settings, settings) then
    perf_frame_add("linewrapping_update_docview_breaks_width_changed", 1)
    docview.scroll.to.x = 0
    LineWrapping.reconstruct_breaks(docview, settings.font, width)
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

function LineWrapping.apply_resolved_line_end_affinity(docview)
  if not (docview and docview.wrapped_settings) then return end
  local resolved = docview.wrapped_last_resolved_line_end
  docview.wrapped_last_resolved_line_end = nil
  if not resolved then
    LineWrapping.clear_wrapped_line_end_affinity(docview)
    return
  end
  local positions = {}
  for _, line1, col1 in docview.doc:get_selections(false) do
    if line1 == resolved[1] and col1 == resolved[2] then
      positions[LineWrapping.position_key(line1, col1)] = true
    end
  end
  LineWrapping.set_wrapped_line_end_affinity(docview, positions)
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

function LineWrapping.is_soft_wrap_row_start(docview, line, col)
  if not docview.wrapped_settings or not line or not col then return false end
  local first_idx = docview.wrapped_line_to_idx[line]
  if not first_idx then return false end
  local idx, _, _, row_start_col = LineWrapping.get_line_idx_col_count(docview, line, col, false)
  return idx > first_idx and row_start_col == col
end

function LineWrapping.collect_soft_wrap_row_start_affinity(docview)
  local positions = {}
  if not docview.wrapped_settings then return positions end
  for _, line1, col1, line2, col2 in docview.doc:get_selections(false) do
    if line1 == line2 and col1 == col2 and LineWrapping.is_soft_wrap_row_start(docview, line1, col1) then
      positions[LineWrapping.position_key(line1, col1)] = true
    end
  end
  return positions
end

function LineWrapping.copy_selection_list(selections)
  local copy = {}
  for i = 1, #selections do copy[i] = selections[i] end
  return copy
end

function LineWrapping.position_before(line1, col1, line2, col2)
  return line1 < line2 or (line1 == line2 and col1 < col2)
end

function LineWrapping.sort_position_pair(line1, col1, line2, col2)
  if LineWrapping.position_before(line2, col2, line1, col1) then
    return line2, col2, line1, col1
  end
  return line1, col1, line2, col2
end

function LineWrapping.old_selection_advanced_to(old_selections, line, col)
  for i = 1, #old_selections, 4 do
    local line1, col1 = old_selections[i], old_selections[i + 1]
    local line2, col2 = old_selections[i + 2], old_selections[i + 3]
    if LineWrapping.position_before(line1, col1, line, col) then
      return true
    end
    local sline1, scol1, sline2, scol2 = LineWrapping.sort_position_pair(line1, col1, line2, col2)
    if sline2 == line and scol2 == col and LineWrapping.position_before(sline1, scol1, sline2, scol2) then
      return true
    end
  end
  return false
end

function LineWrapping.collect_forward_endpoint_affinity(docview, old_selections)
  local positions = {}
  if not docview.wrapped_settings then return positions end
  for _, line1, col1 in docview.doc:get_selections(false) do
    if LineWrapping.is_soft_wrap_row_start(docview, line1, col1)
    and LineWrapping.old_selection_advanced_to(old_selections, line1, col1) then
      positions[LineWrapping.position_key(line1, col1)] = true
    end
  end
  return positions
end

function LineWrapping.wrapped_visual_line_position(docview, line, col, idx_delta)
  local line_end = LineWrapping.has_wrapped_line_end_affinity(docview, line, col)
  local idx = LineWrapping.get_line_idx_col_count(docview, line, col, line_end)
  return LineWrapping.get_line_col_from_index_and_x(docview, idx + idx_delta, docview:get_col_x_offset(line, col, line_end))
end

function LineWrapping.wrapped_end_of_line_position(docview, doc, line, col, logical_end_of_line)
  local line_end = LineWrapping.has_wrapped_line_end_affinity(docview, line, col)
  local idx = LineWrapping.get_line_idx_col_count(docview, line, col, line_end)
  local nline, ncol = LineWrapping.get_idx_line_col(docview, idx + 1)
  if nline ~= line then
    local end_line, end_col = logical_end_of_line(doc, line, col)
    end_line, end_col = doc:sanitize_position(end_line, end_col)
    return end_line, end_col, false
  end
  if line_end and col == ncol then
    local end_line, end_col = logical_end_of_line(doc, line, col)
    end_line, end_col = doc:sanitize_position(end_line, end_col)
    return end_line, end_col, false
  end
  return line, ncol, true
end

function LineWrapping.wrapped_start_of_line_position(docview, doc, line, col, logical_start_of_line)
  local line_end = LineWrapping.has_wrapped_line_end_affinity(docview, line, col)
  local _, _, _, scol = LineWrapping.get_line_idx_col_count(docview, line, col, line_end)
  if col == scol then return logical_start_of_line(doc, line, col) end
  return line, scol
end

function LineWrapping.wrapped_start_of_indentation_position(docview, doc, line, col, logical_start_of_indentation)
  local line_end = LineWrapping.has_wrapped_line_end_affinity(docview, line, col)
  local _, _, _, scol = LineWrapping.get_line_idx_col_count(docview, line, col, line_end)
  if col == scol then return logical_start_of_indentation(doc, line, col) end
  if scol ~= 1 then return line, scol end
  return logical_start_of_indentation(doc, line, col)
end

return LineWrapping
