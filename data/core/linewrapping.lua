local core = require "core"
local common = require "core.common"
local config = require "core.config"
local file_context = require "core.file_context"
local style = require "core.style"

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
    if transaction and transaction.type == "load" then
      -- A loaded snapshot is a revision boundary. Let transaction/render
      -- providers reset their state first, then prepare the new wrapped layout
      -- in slices and adopt it atomically. The previous committed rows remain
      -- readable until the replacement is complete.
      docview.__wrap_reload_reconstruction_serial =
        (docview.__wrap_reload_reconstruction_serial or 0) + 1
      local serial = docview.__wrap_reload_reconstruction_serial
      core.add_thread(function()
        coroutine.yield(0)
        if docview.doc ~= doc
          or docview.__wrap_reload_reconstruction_serial ~= serial
          or not docview.wrapped_settings
        then
          return
        end
        local settings = docview.wrapped_settings
        core.log_quiet(
          "Preparing wrapped layout after loaded snapshot for %s revision=%d",
          doc:get_name(), doc.text_revision or 0
        )
        LineWrapping.reconstruct_breaks_async(
          docview, settings.font, settings.width, { budget_ms = 4 }
        )
      end)
      return
    end
    if #ranges == 1 then
      local range = ranges[1]
      if not LineWrapping.update_same_line_suffix_breaks(docview, range, transaction) then
        LineWrapping.update_breaks(docview, range.old_line1, range.old_line2, range.line_delta or 0)
      end
    elseif not LineWrapping.update_multiple_nonstructural_breaks(
      docview, ranges
    ) then
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
---@field continuation_indicator string
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
    label = "Continuation Indicator",
    description = "Prefix drawn in the visual indent before each soft-wrapped continuation row.",
    path = "continuation_indicator",
    type = "string",
    default = "↪"
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

local function perf_detail(key, amount)
  local perf = package.loaded["core.perf"]
  if perf and perf.is_recording and perf.is_recording() and perf.add_detail then
    perf.add_detail(key, amount or 1)
  end
end

local function perf_recording()
  local perf = package.loaded["core.perf"]
  return perf and perf.is_recording and perf.is_recording() and perf.add_detail
end

local function perf_diagnostics_active()
  return core.perf_frame_stats ~= nil or not not perf_recording()
end

local function perf_elapsed(key, start_time)
  if start_time then perf_frame_add(key, (system.get_time() - start_time) * 1000) end
end

-- Optimization iterator. The tokenizer is relatively slow, so if wrapping does
-- not need syntax fonts, expose the whole line as a single normal token.
local function spew_tokens(state, emitted)
  if emitted then return end
  local text = state.text or state.doc:get_utf8_line(state.line)
  if state.scol and state.scol > 1 then text = text:sub(state.scol) end
  return math.huge, "normal", text
end

local function get_tokens(doc, line, scol, line_text, measurement)
  local require_tokenization = measurement and measurement.require_tokenization
  if require_tokenization == nil then
    require_tokenization = config.plugins.linewrapping.require_tokenization
  end
  if require_tokenization then
    return doc.highlighter:each_token(line, scol)
  end
  return spew_tokens, { doc = doc, line = line, scol = scol, text = line_text }, nil
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

local function fast_ascii_width(text, cell_width, tab_width)
  local width = 0
  local pos = 1
  while true do
    local tab = text:find("\t", pos, true)
    if not tab then return width + (#text - pos + 1) * cell_width end
    width = width + (tab - pos) * cell_width + tab_width
    pos = tab + 1
  end
end

local function append_ascii_letter_splits_with_tabs(splits, text, start_col, xoffset, cell_width, tab_width, width, begin_width)
  local pos = 1
  local col = start_col
  while pos <= #text do
    local tab = text:find("\t", pos, true)
    local segment_len = (tab and tab or (#text + 1)) - pos
    if segment_len > 0 then
      xoffset = append_plain_ascii_letter_splits(splits, col, segment_len, xoffset, cell_width, width, begin_width)
      col = col + segment_len
      pos = pos + segment_len
    end
    if tab and pos == tab then
      xoffset = xoffset + tab_width
      if xoffset > width then
        splits[#splits + 1] = col
        xoffset = begin_width + tab_width
      end
      col = col + 1
      pos = pos + 1
    end
  end
  return xoffset
end

local function find_last_space(text, first, last)
  for i = last, first, -1 do
    if text:byte(i) == 32 then return i end
  end
end

local function append_plain_ascii_word_splits(splits, text, start_col, byte_len, xoffset, cell_width, width, begin_width)
  local pos = 1
  while pos <= byte_len do
    local remaining = byte_len - pos + 1
    local capacity = math.max(1, math.floor((width - xoffset) / cell_width))
    if remaining <= capacity then
      return xoffset + remaining * cell_width, nil, nil
    else
      local segment_end = pos + capacity - 1
      local space = find_last_space(text, pos, segment_end)
      if space and space >= pos then
        splits[#splits + 1] = start_col + space
        pos = space + 1
        xoffset = begin_width
      else
        splits[#splits + 1] = start_col + segment_end
        pos = segment_end + 1
        xoffset = begin_width
      end
    end
  end
  return xoffset, nil, nil
end

function LineWrapping.get_tokens(doc, line)
  return get_tokens(doc, line)
end

local function new_measurement_context(doc, default_font, docview)
  local _, indent_size = doc:get_indent_info()
  local default_cell_width = default_font:get_width(" ")
  local syntax_fonts = {}
  for name, font in pairs(style.syntax_fonts) do syntax_fonts[name] = font end
  local has_line_render_providers = false
  if docview and docview.get_line_render then
    has_line_render_providers = not docview.has_line_render_providers
      or docview:has_line_render_providers()
  end
  return {
    indent_size = indent_size or config.indent_size or 2,
    mode = config.plugins.linewrapping.mode,
    indent = config.plugins.linewrapping.indent,
    wrapping_indent = config.plugins.linewrapping.wrapping_indent,
    continuation_indent_size = config.indent_size or 4,
    require_tokenization = config.plugins.linewrapping.require_tokenization,
    syntax_fonts = syntax_fonts,
    cell_widths = { [default_font] = default_cell_width },
    char_widths = {},
    extra_indent_widths = {},
    has_line_render_providers = has_line_render_providers,
    perf_active = perf_diagnostics_active(),
  }
end

local function measurement_cell_width(context, font)
  if not context then return font:get_width(" ") end
  local width = context.cell_widths[font]
  if width == nil then
    width = font:get_width(" ")
    context.cell_widths[font] = width
  end
  return width
end

local function measurement_syntax_font(context, token_type, default_font)
  if context then return context.syntax_fonts[token_type] or default_font end
  return style.syntax_fonts[token_type] or default_font
end

local function measurement_char_widths(context, font)
  if not context then return {} end
  local widths = context.char_widths[font]
  if not widths then
    widths = {}
    context.char_widths[font] = widths
  end
  return widths
end

local function continuation_indent_width(font, text, measurement)
  local mode = measurement and measurement.wrapping_indent
    or config.plugins.linewrapping.wrapping_indent
  local indent = measurement and measurement.indent
  if indent == nil then indent = config.plugins.linewrapping.indent end
  if mode == "none" or indent == false then
    return 0
  end

  local width = 0
  local _, indent_end = text:find("^%s+")
  if indent_end then
    width = font:get_width(text:sub(1, indent_end))
  end

  local numeric_spaces = tonumber(mode)
  if numeric_spaces and numeric_spaces > 0 then
    local extra = measurement and measurement.extra_indent_widths[font]
    if extra == nil then
      extra = font:get_width(string.rep(" ", numeric_spaces))
      if measurement then measurement.extra_indent_widths[font] = extra end
    end
    width = width + extra
  elseif mode == "indent" or mode == "deepIndent" then
    local levels = mode == "deepIndent" and 2 or 1
    local spaces = (
      measurement and measurement.continuation_indent_size
      or config.indent_size or 4
    ) * levels
    local extra = measurement and measurement.extra_indent_widths[font]
    if extra == nil then
      extra = font:get_width(string.rep(" ", spaces))
      if measurement then measurement.extra_indent_widths[font] = extra end
    end
    width = width + extra
  end

  return width
end

function LineWrapping.continuation_indent_width(font, text)
  return continuation_indent_width(font, text)
end

-- Computes the breaks for a given line, width and mode. Returns a list of byte
-- columns where visual rows start, plus the continuation indent width.
local function line_continuation_indent_width(doc, default_font, line, measurement)
  for _, type, text in get_tokens(doc, line, nil, nil, measurement) do
    local font = measurement_syntax_font(measurement, type, default_font)
    return continuation_indent_width(font, text, measurement)
  end
  return 0
end

local function clamp_continuation_indent_width(indent_width, wrap_width)
  if wrap_width == math.huge or wrap_width <= 0 then return indent_width end
  return math.min(indent_width or 0, wrap_width * 0.5)
end

local function compute_rendered_line_breaks(
  docview, render_line, default_font, line, width, mode, start_col,
  initial_begin_width, measurement
)
  local text = docview.doc:get_utf8_line(line)
  local visible_end = #text - (text:sub(-1) == "\n" and 1 or 0)
  local begin_width = initial_begin_width
  local continuation_font = render_line.continuation_indent_font or default_font
  if begin_width == nil then
    begin_width = continuation_indent_width(
      continuation_font, text, measurement
    )
  end
  begin_width = clamp_continuation_indent_width(begin_width or 0, width)
  local splits = { start_col }
  local row_start = start_col
  local row_start_x
  local last_space
  local last_space_next_x
  local line_x_offset = render_line.x_offset or 0
  if render_line.continuation_indent_col then
    begin_width = docview:get_line_render_col_x_offset(
      render_line, render_line.continuation_indent_col
    ) - line_x_offset
      + continuation_indent_width(continuation_font, "", measurement)
    begin_width = clamp_continuation_indent_width(begin_width, width)
  end
  local rendered_x = docview.get_line_render_col_x_cursor
    and docview:get_line_render_col_x_cursor(render_line)
    or function(col) return docview:get_line_render_col_x_offset(render_line, col) end
  row_start_x = rendered_x(row_start)
  if docview.get_line_render_native_wrap then
    local native_splits = docview:get_line_render_native_wrap(
      render_line, width, mode, start_col, begin_width
    )
    if native_splits then return native_splits, begin_width, "rendered_native" end
  end
  local col = start_col
  local col_x = row_start_x
  for char in common.utf8_chars(text:sub(start_col, visible_end)) do
    local next_col = col + #char
    local next_x = rendered_x(next_col)
    if char == " " then
      last_space = col
      last_space_next_x = next_x
    end
    local leading = line_x_offset + (row_start > 1 and begin_width or 0)
    local row_width = leading + next_x - row_start_x
    if row_width > width and col > row_start then
      local split = col
      if mode == "word" and last_space and last_space >= row_start then split = last_space + 1 end
      if split <= row_start then split = col end
      if split > splits[#splits] then splits[#splits + 1] = split end
      row_start = split
      row_start_x = split == col and col_x or last_space_next_x or col_x
      if last_space and last_space < row_start then last_space = nil end
      leading = line_x_offset + (row_start > 1 and begin_width or 0)
      row_width = leading + next_x - row_start_x
      if row_width > width and col > row_start then
        splits[#splits + 1] = col
        row_start = col
        row_start_x = col_x
      end
    end
    col_x = next_x
    col = next_col
  end
  return splits, begin_width, "rendered_cursor"
end

-- Computes the breaks for a line suffix. `start_col` must be a valid byte
-- column, normally an existing cached visual-row start. Returns row starts for
-- the suffix, including `start_col`, plus the line continuation indent width.
function LineWrapping.compute_line_breaks_from_col(
  doc, default_font, line, width, mode, start_col, initial_begin_width,
  docview, measurement
)
  local perf_active = measurement and measurement.perf_active
  if perf_active == nil then
    perf_active = perf_diagnostics_active()
  end
  local perf_start = perf_active and system.get_time()
  local perf_bytes = 0
  local perf_branch
  local perf_ascii = true
  local perf_has_space = false
  local perf_has_tab = false
  local perf_has_non_ascii = false
  local require_tokenization = measurement and measurement.require_tokenization
  if require_tokenization == nil then
    require_tokenization = config.plugins.linewrapping.require_tokenization
  end
  start_col = math.max(1, start_col or 1)
  local begin_width = initial_begin_width
  if start_col > 1 and begin_width == nil then
    begin_width = line_continuation_indent_width(doc, default_font, line, measurement)
  end
  local xoffset, i, last_space, last_width = start_col > 1 and begin_width or 0, start_col, nil, 0
  local splits = { start_col }
  local line_text = doc:get_utf8_line(line)
  local visible_end_col = #line_text
  if line_text:sub(-1) == "\n" then visible_end_col = visible_end_col - 1 end
  local function finish(result_splits, result_begin_width, branch)
    if not perf_active then return result_splits, result_begin_width end
    local perf_elapsed_ms = perf_start and ((system.get_time() - perf_start) * 1000) or 0
    local branch_key = tostring(branch or perf_branch or "empty"):gsub("[^%w_]", "_")
    perf_frame_add("linewrapping_compute_line_breaks_calls", 1)
    perf_frame_add("linewrapping_compute_line_breaks_bytes", perf_bytes)
    perf_frame_add("linewrapping_compute_line_breaks_splits", #result_splits)
    perf_frame_add("linewrapping_compute_branch_" .. branch_key .. "_calls", 1)
    perf_frame_add("linewrapping_compute_branch_" .. branch_key .. "_bytes", perf_bytes)
    perf_frame_add("linewrapping_compute_branch_" .. branch_key .. "_ms", perf_elapsed_ms)
    local perf = package.loaded["core.perf"]
    if perf and perf.record_linewrap_compute and (perf_elapsed_ms > 2 or perf_bytes > 50000) then
      perf.record_linewrap_compute({
        elapsed_ms = perf_elapsed_ms,
        line = line,
        bytes = #line_text,
        visible_bytes = perf_bytes,
        splits = #result_splits,
        width = width,
        mode = mode,
        tokenized = require_tokenization,
        ascii = perf_ascii,
        has_space = perf_has_space,
        has_tab = perf_has_tab,
        has_non_ascii = perf_has_non_ascii,
        branch = branch or perf_branch or "empty",
      })
    end
    perf_frame_add("linewrapping_compute_line_breaks_ms", perf_elapsed_ms)
    return result_splits, result_begin_width
  end
  local may_have_render_line = docview and docview.get_line_render
    and (not measurement or measurement.has_line_render_providers)
  if may_have_render_line then
    local render_line = docview:get_line_render(line)
    if render_line and render_line.disable_wrapping then
      return finish({ start_col }, 0, "rendered_disabled")
    end
    local has_non_inline_widget = false
    for _, fragment in ipairs(render_line and render_line.fragments or {}) do
      if fragment.widget and fragment.widget.wrapping ~= "inline" then
        has_non_inline_widget = true
        break
      end
    end
    if render_line and not has_non_inline_widget then
      if perf_active then
        perf_bytes = math.max(0, visible_end_col - start_col + 1)
        local visible_text = line_text:sub(start_col, visible_end_col)
        perf_has_space = visible_text:find(" ", 1, true) ~= nil
        perf_has_tab = visible_text:find("\t", 1, true) ~= nil
        perf_has_non_ascii = visible_text:find("[\128-\255]") ~= nil
        perf_ascii = not perf_has_non_ascii
      end
      local rendered_splits, rendered_begin_width, rendered_branch = compute_rendered_line_breaks(
        docview, render_line, default_font, line, width, mode,
        start_col, begin_width, measurement
      )
      return finish(rendered_splits, rendered_begin_width, rendered_branch)
    end
  end
  begin_width = clamp_continuation_indent_width(begin_width or 0, width)
  local default_ascii_cell_width = measurement_cell_width(measurement, default_font)
  local note_branch
  if perf_active then
    note_branch = function(branch)
      if not perf_branch then
        perf_branch = branch
      elseif perf_branch ~= branch then
        perf_branch = "mixed"
      end
    end
  end
  for idx, type, text in get_tokens(
    doc, line, start_col, line_text, measurement
  ) do
    if i > visible_end_col then break end
    if i + #text - 1 > visible_end_col then
      text = text:sub(1, visible_end_col - i + 1)
    end
    if perf_active then perf_bytes = perf_bytes + #text end
    local font = measurement_syntax_font(measurement, type, default_font)
    if start_col == 1 and (idx == 1 or idx == math.huge) then
      begin_width = clamp_continuation_indent_width(
        continuation_indent_width(font, text, measurement), width
      )
    end
    local has_tab = text:find("\t", 1, true) ~= nil
    local has_non_ascii = text:find("[\128-\255]") ~= nil
    local ascii_font = not has_non_ascii
    local cell_width = font == default_font and default_ascii_cell_width
      or measurement_cell_width(measurement, font)
    local tab_width = cell_width * (
      measurement and measurement.indent_size
      or select(2, doc:get_indent_info()) or config.indent_size or 2
    )
    local ascii_cell_width = ascii_font and cell_width or nil
    local ascii_tab_width = ascii_font and tab_width or nil
    local has_space = ascii_font and text:find(" ", 1, true) ~= nil
    if perf_active then
      perf_ascii = perf_ascii and ascii_font
      perf_has_space = perf_has_space or has_space
      perf_has_tab = perf_has_tab or has_tab
      perf_has_non_ascii = perf_has_non_ascii or has_non_ascii
    end
    -- Avoid measuring enormous UTF-8 tokens as a whole only to discover they
    -- overflow and then measure them again character-by-character below.
    -- Long generated/minified lines can be hundreds of KB; whole-token shaping
    -- dominates interactive typing latency in that case.
    local force_incremental_width = (not ascii_font) and #text > 4096
    local w = force_incremental_width and (width + 1)
      or (ascii_font and (has_tab and fast_ascii_width(text, ascii_cell_width, ascii_tab_width) or (#text * ascii_cell_width)) or font:get_width(text))
    if xoffset + w > width then
      if ascii_font and mode ~= "word" then
        if note_branch then
          note_branch(font == default_font and (has_tab and "ascii_tabs_letter" or "plain_ascii_letter") or (has_tab and "ascii_tabs_syntax_letter" or "plain_ascii_syntax_letter"))
        end
        xoffset = has_tab
          and append_ascii_letter_splits_with_tabs(splits, text, i, xoffset, ascii_cell_width, ascii_tab_width, width, begin_width)
          or append_plain_ascii_letter_splits(splits, i, #text, xoffset, ascii_cell_width, width, begin_width)
        i = i + #text
        last_space = nil
      elseif ascii_font and idx == math.huge then
        if has_space and not has_tab then
          if note_branch then
            note_branch(font == default_font and "plain_ascii_word_row" or "plain_ascii_syntax_word_row")
          end
          xoffset, last_space, last_width = append_plain_ascii_word_splits(
            splits, text, i, #text, xoffset, ascii_cell_width, width, begin_width
          )
        elseif not has_space then
          if note_branch then
            note_branch(font == default_font and (has_tab and "ascii_tabs_word_longword_letter" or "plain_ascii_word_longword_letter") or (has_tab and "ascii_tabs_syntax_word_longword_letter" or "plain_ascii_syntax_word_longword_letter"))
          end
          xoffset = has_tab
            and append_ascii_letter_splits_with_tabs(splits, text, i, xoffset, ascii_cell_width, ascii_tab_width, width, begin_width)
            or append_plain_ascii_letter_splits(splits, i, #text, xoffset, ascii_cell_width, width, begin_width)
          last_space = nil
          last_width = nil
        else
          if note_branch then note_branch("ascii_tabs_word_spaces_slow") end
          ascii_font = false
          for char in common.utf8_chars(text) do
            w = font:get_width(char)
            xoffset = xoffset + w
            if xoffset > width then
              if last_space then
                table.insert(splits, last_space + 1)
                xoffset = begin_width + (xoffset - last_width)
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
        i = ascii_font and (i + #text) or i
      elseif idx == math.huge and font.wrap_text then
        if note_branch then note_branch("plain_utf8_native") end
        local native_splits = font:wrap_text(
          text, width, mode, 0, #text, xoffset, begin_width,
          cell_width, tab_width
        )
        for index = 2, #native_splits do
          splits[#splits + 1] = i + native_splits[index]
        end
        return finish(splits, begin_width, "plain_utf8_native")
      else
        if note_branch then
          note_branch(ascii_font and "plain_ascii_word_tokenized" or "slow_utf8")
        end
        local char_width_cache = not ascii_font
          and measurement_char_widths(measurement, font) or nil
        for char in common.utf8_chars(text) do
          if ascii_font then
            w = ascii_cell_width
          elseif char == "\t" then
            w = tab_width
          elseif #char == 1 then
            w = cell_width
          else
            w = char_width_cache[char]
            if not w then
              w = font:get_width(char)
              char_width_cache[char] = w
            end
          end
          xoffset = xoffset + w
          if xoffset > width then
            if mode == "word" and last_space then
              table.insert(splits, last_space + 1)
              xoffset = begin_width + (xoffset - last_width)
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
      if note_branch then
        note_branch(ascii_font and (font == default_font and (has_tab and "fits_ascii_tabs" or "fits_plain_ascii") or (has_tab and "fits_ascii_tabs_syntax" or "fits_plain_ascii_syntax")) or "fits_utf8")
      end
      xoffset = xoffset + w
      i = i + #text
    end
  end
  return finish(splits, begin_width)
end

function LineWrapping.compute_line_breaks(
  doc, default_font, line, width, mode, docview, measurement
)
  return LineWrapping.compute_line_breaks_from_col(
    doc, default_font, line, width, mode, 1, nil, docview, measurement
  )
end

function LineWrapping.clear_wrap_cache(docview)
  docview.__async_wrap_reconstruction = nil
  docview.__wrap_layout_generation = (docview.__wrap_layout_generation or 0) + 1
  docview.__composed_visual_row_cache = nil
  docview.wrapped_lines = nil
  docview.wrapped_line_to_idx = nil
  docview.wrapped_line_offsets = nil
  docview.wrapped_settings = nil
  docview.wrapped_doc_line_count = nil
  docview.wrapped_text_revision = nil
end

local function font_native_value(font, method, fallback)
  if not (font and font[method]) then return tostring(fallback) end
  local value = font[method](font)
  if type(value) ~= "table" then return tostring(value) end
  local parts = {}
  for index, item in ipairs(value) do parts[index] = tostring(item) end
  return table.concat(parts, ":")
end

local function wrap_settings_signature(docview, default_font, width)
  local _, indent_size = docview.doc:get_indent_info()
  local require_tokenization = config.plugins.linewrapping.require_tokenization
  local names = {}
  if require_tokenization then
    for name in pairs(style.syntax_fonts) do names[#names + 1] = name end
    table.sort(names)
  else
    names[1] = "normal"
  end
  local parts = {}
  for _, name in ipairs(names) do
    local font = style.syntax_fonts[name]
    parts[#parts + 1] = name
    parts[#parts + 1] = tostring(font)
    parts[#parts + 1] = tostring(font and font:get_size())
    parts[#parts + 1] = font_native_value(font, "get_generation", 0)
    parts[#parts + 1] = font_native_value(font, "get_surface_scale", 1)
  end
  local syntax_font_signature = table.concat(parts, "\0")
  return {
    width = width,
    font = default_font,
    font_size = default_font and default_font:get_size(),
    font_generation = font_native_value(default_font, "get_generation", 0),
    font_surface_scale = font_native_value(
      default_font, "get_surface_scale", 1
    ),
    mode = config.plugins.linewrapping.mode,
    indent = config.plugins.linewrapping.indent,
    wrapping_indent = config.plugins.linewrapping.wrapping_indent,
    continuation_indent_size = config.indent_size or 4,
    require_tokenization = require_tokenization,
    syntax_generation = require_tokenization
      and (docview.doc.highlighter.packet_reset_generation or 0) or 0,
    syntax_font_signature = syntax_font_signature,
    indent_size = indent_size,
  }
end

local function same_wrap_settings(a, b)
  if not a or not b then return false end
  return a.width == b.width
    and a.font == b.font
    and a.font_size == b.font_size
    and a.font_generation == b.font_generation
    and a.font_surface_scale == b.font_surface_scale
    and a.mode == b.mode
    and a.indent == b.indent
    and a.wrapping_indent == b.wrapping_indent
    and a.continuation_indent_size == b.continuation_indent_size
    and a.require_tokenization == b.require_tokenization
    and a.syntax_generation == b.syntax_generation
    and a.syntax_font_signature == b.syntax_font_signature
    and a.indent_size == b.indent_size
end

function LineWrapping.reconstruct_breaks(docview, default_font, width)
  docview.__async_wrap_reconstruction = nil
  docview.__wrap_layout_generation = (docview.__wrap_layout_generation or 0) + 1
  docview.__composed_visual_row_cache = nil
  local perf_active = core.perf_frame_stats ~= nil
  local perf_start = perf_active and system.get_time()
  local reconstructed_lines = 0
  if width ~= math.huge then
    local doc = docview.doc
    local measurement = new_measurement_context(doc, default_font, docview)
    docview.wrapped_lines = {}
    docview.wrapped_line_to_idx = {}
    docview.wrapped_line_offsets = {}
    docview.wrapped_settings = wrap_settings_signature(docview, default_font, width)
    docview.wrapped_doc_line_count = #doc.lines
    docview.wrapped_text_revision = doc.text_revision or 0
    local wrapped_row_count = 0
    for i = 1, #doc.lines do
      reconstructed_lines = reconstructed_lines + 1
      local breaks, offset = LineWrapping.compute_line_breaks(
        doc, default_font, i, width, measurement.mode,
        docview, measurement
      )
      docview.wrapped_line_offsets[i] = offset
      docview.wrapped_line_to_idx[i] = wrapped_row_count + 1
      for _, col in ipairs(breaks) do
        wrapped_row_count = wrapped_row_count + 1
        local row_offset = wrapped_row_count * 2
        docview.wrapped_lines[row_offset - 1] = i
        docview.wrapped_lines[row_offset] = col
      end
    end
  else
    LineWrapping.clear_wrap_cache(docview)
  end
  perf_frame_add("linewrapping_reconstruct_breaks_calls", 1)
  perf_frame_add("linewrapping_reconstruct_breaks_lines", reconstructed_lines)
  perf_elapsed("linewrapping_reconstruct_breaks_ms", perf_start)
end

---Rebuild a wrapped layout in bounded main-thread slices and atomically adopt
---it when complete. The existing layout remains readable while the new one is
---prepared, avoiding a whole-Document publication stall.
function LineWrapping.reconstruct_breaks_async(docview, default_font, width, opts)
  opts = opts or {}
  if width == math.huge then
    LineWrapping.clear_wrap_cache(docview)
    if opts.on_complete then opts.on_complete(true) end
    return true
  end
  local doc = docview.doc
  local measurement = new_measurement_context(doc, default_font, docview)
  local token = {
    doc = doc,
    revision = doc.text_revision or 0,
    line_count = #doc.lines,
    next_line = 1,
    wrapped_lines = {},
    wrapped_line_to_idx = {},
    wrapped_line_offsets = {},
    wrapped_row_count = 0,
    work_ms = 0,
    yields = 0,
    settings = wrap_settings_signature(docview, default_font, width),
    measurement = measurement,
    line_render_invalidation_generation =
      docview.__line_render_invalidation_generation or 0,
    has_line_render_providers = measurement.has_line_render_providers,
  }
  docview.__async_wrap_reconstruction = token
  perf_frame_add("linewrapping_async_reconstruct_calls", 1)

  local function base_current()
    return docview.__async_wrap_reconstruction == token
      and docview.doc == doc
      and (doc.text_revision or 0) == token.revision
      and #doc.lines == token.line_count
      and same_wrap_settings(
        token.settings,
        wrap_settings_signature(docview, default_font, width)
      )
  end

  local function line_render_current()
    return (docview.__line_render_invalidation_generation or 0)
        == token.line_render_invalidation_generation
      and (
        not docview.has_line_render_providers
        or docview:has_line_render_providers()
      ) == token.has_line_render_providers
  end

  local function current()
    return base_current()
      and line_render_current()
  end

  local function finish()
    if not current() then return false end
    docview.wrapped_lines = token.wrapped_lines
    docview.wrapped_line_to_idx = token.wrapped_line_to_idx
    docview.wrapped_line_offsets = token.wrapped_line_offsets
    docview.wrapped_settings = token.settings
    docview.wrapped_doc_line_count = token.line_count
    docview.wrapped_text_revision = token.revision
    docview.__wrap_layout_generation = (docview.__wrap_layout_generation or 0) + 1
    docview.__composed_visual_row_cache = nil
    docview.__line_render_wrap_change = nil
    docview.__async_wrap_reconstruction = nil
    perf_frame_add("linewrapping_async_reconstruct_commits", 1)
    core.log_quiet(
      "Committed sliced wrapped layout for %s: lines=%d rows=%d work_ms=%.3f yields=%d",
      doc:get_name(), token.line_count, token.wrapped_row_count,
      token.work_ms, token.yields
    )
    if opts.on_complete then
      local ok, err = pcall(opts.on_complete, true)
      if not ok then
        core.log_quiet("Async wrapped-layout completion failed for %s: %s", doc:get_name(), tostring(err))
      end
    end
    core.redraw = true
    return true
  end

  local budget_ms = math.max(1, tonumber(opts.budget_ms) or 4)
  local function advance()
    if not current() then
      if base_current() and not line_render_current() then
        docview.__async_wrap_reconstruction = nil
        perf_frame_add("linewrapping_async_reconstruct_restarts", 1)
        core.log_quiet(
          "Restarting sliced wrapped layout after line-render invalidation for %s at line %d/%d",
          doc:get_name(), token.next_line, token.line_count
        )
        LineWrapping.reconstruct_breaks_async(
          docview, default_font, width, opts
        )
        return "restarted"
      end
      if docview.__async_wrap_reconstruction == token then
        docview.__async_wrap_reconstruction = nil
        perf_frame_add("linewrapping_async_reconstruct_cancelled", 1)
        core.log_quiet(
          "Cancelled stale sliced wrapped layout for %s at line %d/%d",
          doc:get_name(), token.next_line, token.line_count
        )
        if opts.on_complete then pcall(opts.on_complete, false) end
      end
      return "cancelled"
    end
    token.measurement.perf_active = perf_diagnostics_active()
    local started = system.get_time()
    local lines = 0
    while token.next_line <= token.line_count do
      local line = token.next_line
      local breaks, offset = LineWrapping.compute_line_breaks(
        doc, default_font, line, width, token.measurement.mode,
        docview, token.measurement
      )
      token.wrapped_line_offsets[line] = offset
      token.wrapped_line_to_idx[line] = token.wrapped_row_count + 1
      for _, col in ipairs(breaks) do
        token.wrapped_row_count = token.wrapped_row_count + 1
        local row_offset = token.wrapped_row_count * 2
        token.wrapped_lines[row_offset - 1] = line
        token.wrapped_lines[row_offset] = col
      end
      token.next_line = line + 1
      lines = lines + 1
      if (system.get_time() - started) * 1000 >= budget_ms then break end
    end
    local work_ms = (system.get_time() - started) * 1000
    token.work_ms = token.work_ms + work_ms
    perf_frame_add("linewrapping_async_reconstruct_lines", lines)
    perf_frame_add("linewrapping_async_reconstruct_ms", work_ms)
    if token.next_line > token.line_count then
      finish()
      return "complete"
    end
    perf_frame_add("linewrapping_async_reconstruct_yields", 1)
    token.yields = token.yields + 1
    return "pending"
  end

  local status = advance()
  token.advance = advance
  if status == "pending" then
    core.log_quiet(
      "Continuing wrapped layout in slices for %s: lines=%d budget_ms=%.1f",
      doc:get_name(), token.line_count, budget_ms
    )
    core.add_thread(function()
      while advance() == "pending" do coroutine.yield(0.005) end
    end)
  end
  return status == "complete"
end

---Synchronously finish a pending sliced reconstruction when a caller requires
---immediate geometry (primarily deterministic headless/UI test setup).
function LineWrapping.complete_async_reconstruction(docview)
  if not docview then return nil end
  while docview.__async_wrap_reconstruction do
    local token = docview.__async_wrap_reconstruction
    if not token.advance then return false end
    local status = token.advance()
    if status == "complete" then return true end
    if status ~= "pending" and status ~= "restarted" then return false end
  end
  return true
end

local function rebuild_line_to_idx_from(docview, line, offset)
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
end

---Update the distinct Document lines touched by a batch of non-structural
---edits. Unaffected Wrapped Visual Rows are copied without remeasurement.
---Returns false when the transaction or view needs the conservative full
---reconstruction path.
function LineWrapping.update_multiple_nonstructural_breaks(docview, ranges)
  if not (docview and ranges and #ranges > 1) then return false end
  if not (
    docview.wrapped_settings
    and docview.wrapped_lines
    and docview.wrapped_line_to_idx
    and docview.wrapped_line_offsets
  ) then
    return false
  end
  if docview.has_line_render_providers
  and docview:has_line_render_providers() then
    return false
  end

  local doc = docview.doc
  local line_count = #doc.lines
  local revision = doc.text_revision or 0
  if docview.wrapped_doc_line_count ~= line_count
  or docview.wrapped_text_revision ~= revision - 1
  or not same_wrap_settings(
    docview.wrapped_settings,
    wrap_settings_signature(
      docview, docview.wrapped_settings.font,
      docview.wrapped_settings.width
    )
  ) then
    return false
  end

  local affected = {}
  local affected_lines = {}
  local affected_count = 0
  local first_line, last_line
  for _, range in ipairs(ranges) do
    local old_line1, old_line2 = range.old_line1, range.old_line2
    local new_line1, new_line2 = range.new_line1, range.new_line2
    if not (
      old_line1 and old_line2 and new_line1 and new_line2
      and (range.line_delta or 0) == 0
      and old_line1 == old_line2
      and new_line1 == new_line2
      and old_line1 == new_line1
      and new_line1 >= 1 and new_line1 <= line_count
    ) then
      return false
    end
    if not affected[new_line1] then
      affected[new_line1] = true
      affected_lines[#affected_lines + 1] = new_line1
      affected_count = affected_count + 1
      first_line = math.min(first_line or new_line1, new_line1)
      last_line = math.max(last_line or new_line1, new_line1)
    end
  end
  if affected_count == 0 then return false end
  table.sort(affected_lines)

  local perf_active = core.perf_frame_stats ~= nil
  local perf_start = perf_active and system.get_time()
  local old_wrapped_lines = docview.wrapped_lines
  local old_line_to_idx = docview.wrapped_line_to_idx
  local old_row_count = #old_wrapped_lines / 2
  local old_wrap_generation = docview.__wrap_layout_generation or 0
  local measurement = new_measurement_context(
    doc, docview.wrapped_settings.font, docview
  )
  local replacement_breaks = {}
  local replacement_offsets = {}

  for _, line in ipairs(affected_lines) do
    local breaks, begin_width = LineWrapping.compute_line_breaks(
      doc, docview.wrapped_settings.font, line,
      docview.wrapped_settings.width, measurement.mode,
      docview, measurement
    )
    replacement_breaks[line] = breaks
    replacement_offsets[line] = begin_width
  end

  -- Build one replacement row map instead of repeatedly splicing and
  -- renumbering the flat suffix for every cursor. This remains O(total rows),
  -- but text measurement is limited to the distinct affected lines.
  local new_wrapped_lines = {}
  local new_line_to_idx = {}
  local new_row_count = 0
  for line = 1, line_count do
    local first_idx = old_line_to_idx[line]
    local next_idx = old_line_to_idx[line + 1] or (old_row_count + 1)
    if not first_idx or next_idx <= first_idx then return false end
    new_line_to_idx[line] = new_row_count + 1
    local breaks = replacement_breaks[line]
    if breaks then
      for _, col in ipairs(breaks) do
        new_row_count = new_row_count + 1
        local offset = new_row_count * 2
        new_wrapped_lines[offset - 1] = line
        new_wrapped_lines[offset] = col
      end
    else
      for idx = first_idx, next_idx - 1 do
        local old_offset = idx * 2
        new_row_count = new_row_count + 1
        local new_offset = new_row_count * 2
        new_wrapped_lines[new_offset - 1] = old_wrapped_lines[old_offset - 1]
        new_wrapped_lines[new_offset] = old_wrapped_lines[old_offset]
      end
    end
  end

  local old_idx1 = old_line_to_idx[first_line]
  local old_idx2 = (old_line_to_idx[last_line + 1] or (old_row_count + 1)) - 1
  for _, line in ipairs(affected_lines) do
    docview.wrapped_line_offsets[line] = replacement_offsets[line]
  end
  docview.__async_wrap_reconstruction = nil
  docview.wrapped_lines = new_wrapped_lines
  docview.wrapped_line_to_idx = new_line_to_idx
  docview.wrapped_doc_line_count = line_count
  docview.wrapped_text_revision = revision
  docview.__wrap_layout_generation = old_wrap_generation + 1
  docview.__composed_visual_row_cache = nil
  docview.__line_render_wrap_change = {
    old_row_count = old_row_count,
    new_row_count = new_row_count,
    old_row1 = old_idx1,
    old_row2 = old_idx2,
    new_row1 = new_line_to_idx[first_line],
    new_row2 = (new_line_to_idx[last_line + 1] or (new_row_count + 1)) - 1,
    old_wrap_generation = old_wrap_generation,
  }

  perf_frame_add("linewrapping_update_breaks_calls", 1)
  perf_frame_add("linewrapping_update_breaks_lines", affected_count)
  perf_elapsed("linewrapping_update_breaks_ms", perf_start)
  return true
end

function LineWrapping.update_same_line_suffix_breaks(docview, range, transaction)
  if not (docview.wrapped_settings and docview.wrapped_lines and docview.wrapped_line_to_idx) then return false end
  -- Tokenized suffix iteration depends on tokenizer slicing by absolute byte
  -- column. Keep that more complex mode on the conservative full-line path.
  if config.plugins.linewrapping.require_tokenization then return false end
  local edits = transaction and transaction.edits
  local edit = edits and #edits == 1 and edits[1]
  if not edit then return false end
  if edit.line1 ~= edit.line2 or tostring(edit.text or ""):find("[\r\n]") then return false end
  if not range
  or (range.line_delta or 0) ~= 0
  or range.old_line1 ~= range.old_line2
  or range.new_line1 ~= range.new_line2
  or range.old_line1 ~= range.new_line1 then
    return false
  end

  local perf_active = core.perf_frame_stats ~= nil
  local perf_start = perf_active and system.get_time()
  local line = range.new_line1
  local first_idx = docview.wrapped_line_to_idx[line]
  if not first_idx then return false end
  local total = LineWrapping.get_total_wrapped_lines(docview)
  local next_first_idx = docview.wrapped_line_to_idx[line + 1] or (total + 1)
  local old_wrap_generation = docview.__wrap_layout_generation or 0
  if next_first_idx <= first_idx then return false end

  local affected_col = math.max(1, tonumber(edit.col1) or 1)
  local wrapping_indent = config.plugins.linewrapping.wrapping_indent
  if config.plugins.linewrapping.indent ~= false and wrapping_indent ~= "none" then
    local _, indent_end = tostring(docview.doc.lines[line] or ""):find("^[ \t]*")
    if affected_col <= (indent_end or 0) + 1 then return false end
  end
  local affected_idx = LineWrapping.get_line_idx_col_count(docview, line, affected_col, false)
  -- Recompute from the previous cached visual row.  For word wrapping, the row
  -- containing the edit can depend on scanning from the previous row start.
  local restart_idx = math.max(first_idx, affected_idx - 1)
  local restart_offset = (restart_idx - 1) * 2 + 1
  local restart_col = docview.wrapped_lines[restart_offset + 1]
  if not restart_col then return false end

  local begin_width = restart_col == 1 and nil or docview.wrapped_line_offsets[line]
  local measurement = new_measurement_context(
    docview.doc, docview.wrapped_settings.font, docview
  )
  local splits, new_begin_width = LineWrapping.compute_line_breaks_from_col(
    docview.doc,
    docview.wrapped_settings.font,
    line,
    docview.wrapped_settings.width,
    measurement.mode,
    restart_col,
    begin_width,
    docview,
    measurement
  )
  if restart_col == 1 then
    docview.wrapped_line_offsets[line] = new_begin_width
  end

  local new_pairs = {}
  for _, col in ipairs(splits) do
    new_pairs[#new_pairs + 1] = line
    new_pairs[#new_pairs + 1] = col
  end
  local old_suffix_rows = next_first_idx - restart_idx
  local new_suffix_rows = #new_pairs / 2
  local remove_count = old_suffix_rows * 2
  common.splice(docview.wrapped_lines, restart_offset, remove_count, new_pairs)
  local row_delta = new_suffix_rows - old_suffix_rows
  if row_delta ~= 0 then
    for logical_line = line + 1, #docview.wrapped_line_to_idx do
      docview.wrapped_line_to_idx[logical_line] = docview.wrapped_line_to_idx[logical_line] + row_delta
    end
  end

  local new_total = LineWrapping.get_total_wrapped_lines(docview)
  docview.wrapped_doc_line_count = #docview.doc.lines
  docview.wrapped_text_revision = docview.doc.text_revision or 0
  docview.__wrap_layout_generation = old_wrap_generation + 1
  docview.__composed_visual_row_cache = nil
  docview.__line_render_wrap_change = {
    old_row_count = total,
    new_row_count = new_total,
    old_row1 = first_idx,
    old_row2 = next_first_idx - 1,
    new_row1 = docview.wrapped_line_to_idx[line] or first_idx,
    new_row2 = (docview.wrapped_line_to_idx[line + 1] or (new_total + 1)) - 1,
    old_wrap_generation = old_wrap_generation,
  }

  perf_frame_add("linewrapping_update_breaks_partial_calls", 1)
  perf_frame_add("linewrapping_update_breaks_partial_preserved_rows", restart_idx - first_idx)
  perf_frame_add("linewrapping_update_breaks_calls", 1)
  perf_frame_add("linewrapping_update_breaks_lines", 1)
  perf_elapsed("linewrapping_update_breaks_ms", perf_start)
  return true
end

function LineWrapping.update_breaks(docview, old_line1, old_line2, net_lines)
  if perf_recording() then
    local caller = debug.getinfo(2, "Sl") or {}
    perf_detail(string.format(
      "linewrapping_update_breaks_range:range=%s-%s:net=%s:new_lines=%s:caller=%s:%s:revision=%s",
      tostring(old_line1), tostring(old_line2), tostring(net_lines or 0),
      tostring(math.max(0, (old_line2 or old_line1) - old_line1 + 1 + (net_lines or 0))),
      tostring(caller.short_src or caller.source or "unknown"),
      tostring(caller.currentline or 0),
      tostring(docview.doc and docview.doc.text_revision or "none")
    ), 1)
  end
  local perf_active = core.perf_frame_stats ~= nil
  local perf_start = perf_active and system.get_time()
  local perf_lines = 0
  local old_row_count = LineWrapping.get_total_wrapped_lines(docview)
  local old_wrap_generation = docview.__wrap_layout_generation or 0
  local old_idx1 = docview.wrapped_line_to_idx[old_line1] or 1
  local old_idx2 = (docview.wrapped_line_to_idx[old_line2 + 1] or ((#docview.wrapped_lines / 2) + 1)) - 1
  local offset = (old_idx1 - 1) * 2 + 1
  local remove_count = math.max(0, old_idx2 - old_idx1 + 1) * 2
  local new_line1 = old_line1
  local new_line2 = old_line2 + net_lines
  local new_pairs = {}
  local new_offsets = {}
  local measurement = new_measurement_context(
    docview.doc, docview.wrapped_settings.font, docview
  )

  for line = new_line1, new_line2 do
    perf_lines = perf_lines + 1
    local breaks, begin_width = LineWrapping.compute_line_breaks(
      docview.doc, docview.wrapped_settings.font, line,
      docview.wrapped_settings.width, measurement.mode,
      docview, measurement
    )
    new_offsets[#new_offsets + 1] = begin_width
    for _, b in ipairs(breaks) do
      new_pairs[#new_pairs + 1] = line
      new_pairs[#new_pairs + 1] = b
    end
  end

  -- When the recomputed wrapped layout is identical to the current one, skip
  -- the splice, row-map rebuild, and wrap-generation bump. Bumping
  -- unconditionally here made
  -- selection-only line-render invalidations (e.g. Markdown interactive
  -- table cell selection, hover changes) invalidate the whole visual metric
  -- cache on the next lookup, forcing an expensive full-document metric
  -- rebuild on every mouse press/release.
  if net_lines == 0 then
    local identical = #new_pairs == remove_count
    if identical then
      for i = 1, remove_count do
        if docview.wrapped_lines[offset + i - 1] ~= new_pairs[i] then
          identical = false
          break
        end
      end
    end
    if identical then
      for line = old_line1, old_line2 do
        if docview.wrapped_line_offsets[line] ~= new_offsets[line - old_line1 + 1] then
          identical = false
          break
        end
      end
    end
    if identical then
      docview.wrapped_doc_line_count = #docview.doc.lines
      docview.wrapped_text_revision = docview.doc.text_revision or 0
      docview.__line_render_wrap_change = nil
      perf_frame_add("linewrapping_update_breaks_calls", 1)
      perf_frame_add("linewrapping_update_breaks_unchanged_calls", 1)
      perf_frame_add("linewrapping_update_breaks_lines", perf_lines)
      perf_elapsed("linewrapping_update_breaks_ms", perf_start)
      return nil
    end
  end

  common.splice(docview.wrapped_lines, offset, remove_count, new_pairs)
  common.splice(docview.wrapped_line_offsets, old_line1, old_line2 - old_line1 + 1, new_offsets)

  if net_lines ~= 0 then
    for i = offset + #new_pairs, #docview.wrapped_lines, 2 do
      docview.wrapped_lines[i] = docview.wrapped_lines[i] + net_lines
    end
  end

  rebuild_line_to_idx_from(docview, old_line1, (old_idx1 - 1) * 2 + 1)
  docview.wrapped_doc_line_count = #docview.doc.lines
  docview.wrapped_text_revision = docview.doc.text_revision or 0
  docview.__wrap_layout_generation = (docview.__wrap_layout_generation or 0) + 1
  docview.__composed_visual_row_cache = nil
  local new_row_count = LineWrapping.get_total_wrapped_lines(docview)
  docview.__line_render_wrap_change = {
    old_row_count = old_row_count,
    new_row_count = new_row_count,
    old_row1 = old_idx1,
    old_row2 = old_idx2,
    new_row1 = docview.wrapped_line_to_idx[new_line1] or 1,
    new_row2 = (docview.wrapped_line_to_idx[new_line2 + 1] or (new_row_count + 1)) - 1,
    old_wrap_generation = old_wrap_generation,
  }
  perf_frame_add("linewrapping_update_breaks_calls", 1)
  perf_frame_add("linewrapping_update_breaks_lines", perf_lines)
  perf_elapsed("linewrapping_update_breaks_ms", perf_start)
  return docview.__line_render_wrap_change
end

function LineWrapping.guide_color()
  return config.plugins.linewrapping.guide_color or style.line_wrapping_guide
end

function LineWrapping.draw_guide(docview)
  if config.plugins.linewrapping.guide
  and file_context.is_editor_view(docview)
  and docview.wrapped_settings.width ~= math.huge then
    local x = docview:get_content_offset()
    local gw = docview:get_gutter_width()
    local guide_width = math.max(1, math.floor(SCALE))
    local guide_x = x + gw + docview.wrapped_settings.width
    local scrollbar_width = docview.v_scrollbar.expanded_size or style.expanded_scrollbar_size
    local content_left = docview.position.x + gw
    local content_right = docview.position.x + docview.size.x - scrollbar_width
    if guide_x <= content_left or guide_x + guide_width >= content_right then return end
    renderer.draw_rect(
      guide_x,
      docview.position.y,
      guide_width,
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

function LineWrapping.update_docview_breaks(docview, width)
  local perf_active = core.perf_frame_stats ~= nil
  local perf_start = perf_active and system.get_time()
  width = width or LineWrapping.compute_wrap_width(docview)
  local settings = wrap_settings_signature(docview, docview:get_font(), width)
  local stale_line_count = docview.wrapped_doc_line_count ~= #docview.doc.lines
  local stale_text = docview.wrapped_text_revision ~= (docview.doc.text_revision or 0)
  local settings_changed = not same_wrap_settings(docview.wrapped_settings, settings)
  if stale_line_count or stale_text or settings_changed then
    if stale_line_count then
      perf_frame_add("linewrapping_update_docview_breaks_line_count_changed", 1)
    elseif stale_text then
      perf_frame_add("linewrapping_update_docview_breaks_text_changed", 1)
    else
      perf_frame_add("linewrapping_update_docview_breaks_width_changed", 1)
    end
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
  local perf_active = core.perf_frame_stats ~= nil
  local perf_start = perf_active and system.get_time()
  local doc = docview.doc
  if not docview.wrapped_settings then
    perf_frame_add("linewrapping_get_line_idx_col_count_calls", 1)
    perf_elapsed("linewrapping_get_line_idx_col_count_ms", perf_start)
    return common.clamp(line, 1, #doc.lines), col, 1, 1
  end
  if line > #doc.lines then return LineWrapping.get_line_idx_col_count(docview, #doc.lines, #doc.lines[#doc.lines] + 1) end
  line = math.max(line, 1)
  local first_idx = docview.wrapped_line_to_idx[line] or 1
  local total = LineWrapping.get_total_wrapped_lines(docview)
  local next_first_idx = docview.wrapped_line_to_idx[line + 1] or (total + 1)
  local last_idx = math.max(first_idx, next_first_idx - 1)
  local idx, ncol, scol = first_idx, 1, 1
  if col then
    local lo, hi = first_idx, last_idx
    while lo <= hi do
      local mid = math.floor((lo + hi) / 2)
      local start_col = docview.wrapped_lines[(mid - 1) * 2 + 2]
      if start_col < col or (start_col == col and not line_end) then
        idx = mid
        scol = start_col
        lo = mid + 1
      else
        hi = mid - 1
      end
    end
    ncol = (col - scol) + 1
  end
  local count = next_first_idx - first_idx
  perf_frame_add("linewrapping_get_line_idx_col_count_calls", 1)
  perf_elapsed("linewrapping_get_line_idx_col_count_ms", perf_start)
  return idx, ncol, count, scol
end

function LineWrapping.get_line_col_from_index_and_x(docview, idx, x)
  local perf_active = core.perf_frame_stats ~= nil
  local perf_start = perf_active and system.get_time()
  local doc = docview.doc
  local line, col = LineWrapping.get_idx_line_col(docview, idx)
  if idx < 1 then
    perf_frame_add("linewrapping_get_line_col_from_index_and_x_calls", 1)
    perf_elapsed("linewrapping_get_line_col_from_index_and_x_ms", perf_start)
    return 1, 1, false
  end
  local row_end_col, soft_end = LineWrapping.get_idx_visual_end_col(docview, idx, line)
  local render_line = docview.get_line_render and docview:get_line_render(line)
  local xoffset = (render_line and render_line.x_offset or 0)
    + (col ~= 1 and docview.wrapped_line_offsets[line] or 0)
  if x < xoffset then
    perf_frame_add("linewrapping_get_line_col_from_index_and_x_calls", 1)
    perf_elapsed("linewrapping_get_line_col_from_index_and_x_ms", perf_start)
    return line, col, false
  end
  if render_line then
    local row_render_x = docview:get_line_render_col_x_offset(render_line, col)
    local target_x = row_render_x + math.max(0, x - xoffset)
    local target_col = docview:get_line_render_x_offset_col(render_line, target_x)
    target_col = common.clamp(target_col, col, row_end_col)
    perf_frame_add("linewrapping_get_line_col_from_index_and_x_calls", 1)
    perf_elapsed("linewrapping_get_line_col_from_index_and_x_ms", perf_start)
    return line, target_col, soft_end and target_col == row_end_col
  end
  local default_font = docview:get_font()
  local last_i, last_w = col, 0
  local token_start_col = 1
  for _, type, text in doc.highlighter:each_token(line) do
    local token_end_col = token_start_col + #text
    if token_end_col > col and token_start_col < row_end_col then
      local scan_start_col = math.max(token_start_col, col)
      local scan_end_col = math.min(token_end_col, row_end_col)
      local scan_text = text
      if scan_start_col > token_start_col or scan_end_col < token_end_col then
        scan_text = text:sub(scan_start_col - token_start_col + 1, scan_end_col - token_start_col)
      end
      local i = scan_start_col
      local font, w = style.syntax_fonts[type] or default_font, last_w
      for char in common.utf8_chars(scan_text) do
        if i >= row_end_col then
          if xoffset >= x then
            local target_col = xoffset - x > (w / 2) and last_i or row_end_col
            perf_frame_add("linewrapping_get_line_col_from_index_and_x_calls", 1)
            perf_elapsed("linewrapping_get_line_col_from_index_and_x_ms", perf_start)
            return line, target_col, soft_end and target_col == row_end_col
          end
          perf_frame_add("linewrapping_get_line_col_from_index_and_x_calls", 1)
          perf_elapsed("linewrapping_get_line_col_from_index_and_x_ms", perf_start)
          return line, row_end_col, soft_end
        end
        if xoffset >= x then
          perf_frame_add("linewrapping_get_line_col_from_index_and_x_calls", 1)
          perf_elapsed("linewrapping_get_line_col_from_index_and_x_ms", perf_start)
          return line, (xoffset - x > (w / 2) and last_i or i), false
        end
        w = font:get_width(char)
        last_w = w
        xoffset = xoffset + w
        last_i = i
        i = i + #char
      end
    end
    if token_end_col >= row_end_col then break end
    token_start_col = token_end_col
  end
  if xoffset >= x and last_w > 0 then
    local target_col = xoffset - x > (last_w / 2) and last_i or row_end_col
    perf_frame_add("linewrapping_get_line_col_from_index_and_x_calls", 1)
    perf_elapsed("linewrapping_get_line_col_from_index_and_x_ms", perf_start)
    return line, target_col, soft_end and target_col == row_end_col
  end
  perf_frame_add("linewrapping_get_line_col_from_index_and_x_calls", 1)
  perf_elapsed("linewrapping_get_line_col_from_index_and_x_ms", perf_start)
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
  local perf_active = core.perf_frame_stats ~= nil
  local perf_start = perf_active and system.get_time()
  local line_end = LineWrapping.has_wrapped_line_end_affinity(docview, line, col)
  local idx = LineWrapping.get_line_idx_col_count(docview, line, col, line_end)
  local last_x_offset = docview.last_x_offset or {}
  docview.last_x_offset = last_x_offset
  local x
  if last_x_offset.line == line and last_x_offset.col == col and last_x_offset.line_end == line_end then
    x = last_x_offset.offset
  else
    x = docview:get_col_x_offset(line, col, line_end)
  end
  local target_line, target_col, target_line_end = LineWrapping.get_line_col_from_index_and_x(docview, idx + idx_delta, x)
  last_x_offset.offset = x
  last_x_offset.line = target_line
  last_x_offset.col = target_col
  last_x_offset.line_end = target_line_end
  perf_frame_add("linewrapping_wrapped_visual_line_position_calls", 1)
  perf_elapsed("linewrapping_wrapped_visual_line_position_ms", perf_start)
  return target_line, target_col, target_line_end
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
