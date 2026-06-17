-- mod-version:3

local core = require "core"
local style = require "core.style"
local Doc = require "core.doc"
local DocView = require "core.docview"
local command = require "core.command"

local drawwhitespace = {
  enabled = true,
  show_leading = true,
  show_trailing = true,
  show_middle = true,
  show_selected_only = false,

  show_middle_min = 1,

  color = style.whitespace,
  leading_color = style.whitespace,
  middle_color = nil,
  trailing_color = style.whitespace_trailing,

  substitutions = {
    {
      char = " ",
      sub = "·",
      show_leading = true,
      show_trailing = true,
      show_middle_min = 2,
    },
    {
      char = "\t",
      sub = "→",
      show_leading = true,
      show_trailing = true,
    },
  },
}


local function get_option(substitution, option)
  if substitution[option] == nil then
    return drawwhitespace[option]
  end
  return substitution[option]
end

local update = DocView.update
function DocView:update()
  update(self)
  if
    drawwhitespace.enabled
    and
    drawwhitespace.show_selected_only
  then
    local vl1, vl2 = self:get_visible_line_range()
    local cache_key = table.concat({
      tostring(self.doc:get_change_id()),
      tostring(self.doc.selection_revision or 0),
      tostring(vl1),
      tostring(vl2),
    }, ":")
    if self.drawwhitespace_selections_cache_key == cache_key then return end

    local selections = {}
    local col1, col2
    for _, l1, c1, l2, c2 in self.doc:get_selections(true) do
      if l1 > vl2 then break end
      if l2 < vl1 then goto skip end
      -- everything selected treat as not show_selected_only
      if l1 < vl1 and l2 > vl2 then
        selections.all = true
        goto out_of_loop
      end
      -- nothing selected so skip
      if l1 == l2 and c1 == c2 then goto skip end
      -- handle single line selection
      if l1 == l2 and l1 >= vl1 and l1 <= vl2 then
        col1, col2 = self:get_visible_cols_range(l1, 20)
        c1, c2 = math.max(col1, c1), math.min(col2, c2)
        selections[l1] = {c1, c2, self.doc.lines[l1]:sub(c1, c2)}
      -- multiple lines selection
      elseif l1 ~= l2 then
        -- first line
        if l1 >= vl1 and l1 <= vl2 then
          col1, col2 = self:get_visible_cols_range(l1, 20)
          col1 = math.max(c1, col1)
          selections[l1] = {col1, col2, self.doc.lines[l1]:sub(col1, col2)}
        end
        -- lines in between
        if l2 - l1 > 1 then
          for idx=l1+1, l2-1 do
            col1, col2 = self:get_visible_cols_range(idx, 20)
            selections[idx] = {col1, col2, self.doc.lines[idx]:sub(col1, col2)}
          end
        end
        -- last line
        if l2 >= vl1 and l2 <= vl2 then
          col1, col2 = self:get_visible_cols_range(l2, 20)
          col2 = math.min(c2, col2)
          selections[l2] = {col1, col2, self.doc.lines[l2]:sub(col1, col2)}
        end
      end
      ::skip::
    end
    ::out_of_loop::
    self.drawwhitespace_selections = selections
    self.drawwhitespace_selections_cache_key = cache_key
  elseif self.drawwhitespace_selections then
    self.drawwhitespace_selections = nil
    self.drawwhitespace_selections_cache_key = nil
  end
end

local function get_line_runs(self, idx)
  local cache = self.drawwhitespace_cache
  local change_id = self.doc:get_change_id()
  if not cache or cache.change_id ~= change_id then
    cache = { change_id = change_id, lines = {} }
    self.drawwhitespace_cache = cache
  end

  local entry = cache.lines[idx]
  local text = self.doc.lines[idx]
  if entry and entry.text == text then return entry end

  local line_len = #text
  local runs = {}
  for sidx, substitution in ipairs(drawwhitespace.substitutions) do
    local char = substitution.char
    local pattern = char .. "+"
    local offset = 1
    while true do
      local s, e = text:find(pattern, offset)
      if not s then break end
      runs[#runs + 1] = {
        substitution = sidx,
        start_col = s,
        end_col = e + 1,
        leading = s == 1,
        trailing = e + 1 >= line_len,
      }
      offset = e + 1
    end
  end

  entry = {
    text = text,
    line_len = line_len,
    runs = runs,
    ascii_no_tabs = text:find("[\128-\255\t]") == nil,
  }
  cache.lines[idx] = entry
  return entry
end

local marker_text_cache = {}
local marker_font_cache = setmetatable({}, { __mode = "k" })
local marker_width_cache = setmetatable({}, { __mode = "k" })
local syntax_fonts_signature_state = { by_name = {}, signature = nil, count = 0 }

local function repeated_marker(marker, count)
  local by_marker = marker_text_cache[marker]
  if not by_marker then
    by_marker = {}
    marker_text_cache[marker] = by_marker
  end

  if count <= 512 then
    local cached = by_marker[count]
    if cached then return cached end
    cached = string.rep(marker, count)
    by_marker[count] = cached
    return cached
  end

  return string.rep(marker, count)
end

local function marker_font(font)
  local size = font:get_size()
  local by_size = marker_font_cache[font]
  if not by_size then
    by_size = {}
    marker_font_cache[font] = by_size
  end

  if by_size[size] ~= nil then
    return by_size[size] or font
  end

  -- Code fonts in the first-party defaults have ligatures enabled. Repeated
  -- whitespace marker glyphs are semantically independent columns, so draw them
  -- with a no-ligature copy when the renderer can provide one.
  local ok, copy = pcall(function()
    return font:copy(size, { ligatures = false })
  end)
  if ok and copy then
    by_size[size] = copy
    return copy
  end

  by_size[size] = false
  core.log_quiet("draw-whitespace: using original font for whitespace markers; no-ligature copy failed: %s", copy)
  return font
end

local function marker_matches_space_advance(font, marker)
  local size = font:get_size()
  local key = tostring(size) .. "\0" .. marker
  local by_font = marker_width_cache[font]
  if not by_font then
    by_font = {}
    marker_width_cache[font] = by_font
  end

  local cached = by_font[key]
  if cached ~= nil then return cached end

  cached = math.abs(font:get_width(marker) - font:get_width(" ")) < 0.01
  by_font[key] = cached
  return cached
end

local function current_clip_x_range(self)
  local clip = core.clip_rect_stack and core.clip_rect_stack[#core.clip_rect_stack]
  if clip then
    return clip[1], clip[1] + clip[3]
  end

  local gw = self:get_gutter_width()
  return self.position.x + gw, self.position.x + self.size.x
end

local function syntax_fonts_signature()
  local fonts = style.syntax_fonts
  if next(fonts) == nil then
    if syntax_fonts_signature_state.count ~= 0 then
      syntax_fonts_signature_state = { by_name = {}, signature = nil, count = 0 }
    end
    return nil
  end

  local state = syntax_fonts_signature_state
  local seen = {}
  local count = 0
  local changed = false

  for name, font in pairs(fonts) do
    count = count + 1
    seen[name] = true
    local size = font and font.get_size and font:get_size() or ""
    local value = tostring(font) .. ":" .. tostring(size)
    if state.by_name[name] ~= value then
      state.by_name[name] = value
      changed = true
    end
  end

  if count ~= state.count then
    state.count = count
    changed = true
  end

  for name in pairs(state.by_name) do
    if not seen[name] then
      state.by_name[name] = nil
      changed = true
    end
  end

  if changed or not state.signature then
    local parts = {}
    for name, value in pairs(state.by_name) do
      parts[#parts + 1] = tostring(name) .. "=" .. value
    end
    table.sort(parts)
    state.signature = table.concat(parts, "\n")
  end

  return state.signature
end

local function get_line_x_cache(self, idx, entry)
  local font = self:get_font()
  local _, indent_size = self.doc:get_indent_info()
  local font_size = font:get_size()
  local fast_space_width
  local tokens
  local syntax_fonts_key = syntax_fonts_signature()

  -- The common case in this fork is an ASCII, tab-free source line drawn with
  -- one monospace code font and no syntax-specific font overrides. In that
  -- case whitespace columns are simple arithmetic; don't walk highlighter
  -- tokens and font widths just to place indentation dots.
  -- TODO: Guard this arithmetic fast path with explicit monospace-font
  -- detection before supporting proportional editor fonts; otherwise markers
  -- after non-space text can be horizontally misplaced.
  if entry.ascii_no_tabs and not self.wrapped_settings and not syntax_fonts_key then
    fast_space_width = font:get_width(" ")
  else
    local hline = self.doc.highlighter:get_render_line(idx)
    tokens = hline and hline.tokens
  end

  local x_cache = entry.x_cache
  if
    not x_cache
    or x_cache.font ~= font
    or x_cache.font_size ~= font_size
    or x_cache.indent_size ~= indent_size
    or x_cache.fast_space_width ~= fast_space_width
    or x_cache.tokens ~= tokens
    or x_cache.syntax_fonts_key ~= syntax_fonts_key
    or x_cache.wrapped_settings ~= self.wrapped_settings
  then
    x_cache = {
      font = font,
      font_size = font_size,
      indent_size = indent_size,
      fast_space_width = fast_space_width,
      tokens = tokens,
      syntax_fonts_key = syntax_fonts_key,
      wrapped_settings = self.wrapped_settings,
      offsets = {},
    }
    entry.x_cache = x_cache
  end

  return x_cache
end

local function cached_col_x_offset(self, idx, x_cache, col)
  if x_cache.fast_space_width then
    return (col - 1) * x_cache.fast_space_width
  end

  local offsets = x_cache.offsets
  local offset = offsets[col]
  if offset == nil then
    offset = self:get_col_x_offset(idx, col)
    offsets[col] = offset
  end
  return offset
end

local function draw_space_rects(self, idx, x, font, ty, start_col, end_col, color, x_cache)
  local count = end_col - start_col
  if count <= 0 then return end

  local start_x = cached_col_x_offset(self, idx, x_cache, start_col) + x
  local end_x = cached_col_x_offset(self, idx, x_cache, end_col) + x
  if end_x <= start_x then return end

  local clip_left, clip_right = current_clip_x_range(self)
  if end_x <= clip_left or start_x >= clip_right then return end

  local cell_width = (end_x - start_x) / count
  local dot_size = math.max(2, math.floor(2 * SCALE))
  local dot_origin = start_x + (cell_width - dot_size) / 2
  local dot_y = math.floor(ty + (font:get_height() - dot_size) / 2)

  -- get_visible_cols_range() is intentionally conservative and can hand us
  -- huge offscreen runs. Avoid spending a Lua/FFI call on dots the renderer
  -- would just clip away.
  local first = math.max(0, math.floor((clip_left - dot_size - dot_origin) / cell_width) - 1)
  local last = math.min(count - 1, math.ceil((clip_right - dot_origin) / cell_width) + 1)
  local draw_count = last - first + 1
  if draw_count <= 0 then return end

  if renderer.draw_rect_grid then
    renderer.draw_rect_grid(dot_origin + first * cell_width, dot_y, cell_width, dot_size, dot_size, draw_count, color)
    return
  end

  for n = first, last do
    local dot_x = math.floor(dot_origin + n * cell_width)
    if dot_x + dot_size > clip_left and dot_x < clip_right then
      renderer.draw_rect(dot_x, dot_y, dot_size, dot_size, color)
    end
  end
end

local function draw_whitespace_run(self, idx, x, y, font, ty, substitution, start_col, end_col, color, x_cache)
  if start_col >= end_col then return end

  if substitution.char == " " then
    local count = end_col - start_col
    local marker = substitution.sub or "·"
    if marker == "" then return end
    local font = marker_font(font)

    -- Spaces are by far the hot path. Draw one text run instead of one tiny
    -- rectangle per column when the marker glyph advances exactly like a space
    -- in the active font. This preserves per-column alignment while collapsing
    -- thousands of renderer calls per second into one call per whitespace run.
    if marker_matches_space_advance(font, marker) then
      renderer.draw_text(
        font,
        repeated_marker(marker, count),
        cached_col_x_offset(self, idx, x_cache, start_col) + x,
        ty,
        color
      )
    else
      draw_space_rects(self, idx, x, font, ty, start_col, end_col, color, x_cache)
    end
    return
  end

  -- Tabs still need per-column positioning because tab stops are contextual.
  for i = start_col, end_col - 1 do
    renderer.draw_text(font, substitution.sub, cached_col_x_offset(self, idx, x_cache, i) + x, ty, color)
  end
end

local draw_line_text = DocView.draw_line_text
function DocView:draw_line_text(idx, x, y)
  if
    not drawwhitespace.enabled
    or
    getmetatable(self) ~= DocView
  then
    return draw_line_text(self, idx, x, y)
  end

  if not self.drawwhitespace_selections then
    self.drawwhitespace_selections = {}
  end

  local font = (self:get_font() or style.syntax_fonts["whitespace"] or style.syntax_fonts["comment"])
  local ty = y + self:get_line_text_y_offset()
  local col1, col2, text
  if
    not drawwhitespace.show_selected_only
    or
    self.drawwhitespace_selections.all
  then
    col1, col2 = self:get_visible_cols_range(idx, 20)
    if col1 == 0 or col2 == 1 then goto not_selected end -- skip empty line
  else
    if not self.drawwhitespace_selections[idx] then goto not_selected end
    col1, col2, text = table.unpack(self.drawwhitespace_selections[idx])
  end

  if not drawwhitespace.show_selected_only or self.drawwhitespace_selections.all then
    local entry = get_line_runs(self, idx)
    local x_cache = get_line_x_cache(self, idx, entry)
    for _, run in ipairs(entry.runs) do
      local substitution = drawwhitespace.substitutions[run.substitution]
      local start_col = math.max(run.start_col, col1)
      local end_col = math.min(run.end_col, col2 + 1)
      if start_col < end_col then
        local draw = false
        local color = get_option(substitution, "color")
        if run.trailing then
          draw = get_option(substitution, "show_trailing")
          color = get_option(substitution, "trailing_color") or color
        elseif run.leading then
          draw = get_option(substitution, "show_leading")
          color = get_option(substitution, "leading_color") or color
        else
          draw = get_option(substitution, "show_middle")
            and (run.end_col - run.start_col >= get_option(substitution, "show_middle_min"))
          color = get_option(substitution, "middle_color") or color
        end
        if draw then
          draw_whitespace_run(self, idx, x, y, font, ty, substitution, start_col, end_col, color, x_cache)
        end
      end
    end
  else
    local line_len = #self.doc.lines[idx]
    -- TODO: Selected-only mode still builds full-line whitespace/x-offset
    -- caches before scanning the selected substring; consider a selection-local
    -- path if very long selected lines become hot again.
    local entry = get_line_runs(self, idx)
    local x_cache = get_line_x_cache(self, idx, entry)
    for _, substitution in pairs(drawwhitespace.substitutions) do
      local offset = 1
      local pattern = substitution.char.."+"
      while true do
        local s, e = text:find(pattern, offset)
        if not s then break end

        local as, ae = col1 + s - 1, col1 + e
        local draw = false
        local color = get_option(substitution, "color")
        if ae >= line_len then
          draw = get_option(substitution, "show_trailing")
          color = get_option(substitution, "trailing_color") or color
        elseif as == 1 then
          draw = get_option(substitution, "show_leading")
          color = get_option(substitution, "leading_color") or color
        else
          draw = get_option(substitution, "show_middle") and (ae - as >= get_option(substitution, "show_middle_min"))
          color = get_option(substitution, "middle_color") or color
        end
        if draw then
          draw_whitespace_run(self, idx, x, y, font, ty, substitution, as, ae, color, x_cache)
        end
        offset = e + 1
      end
    end
  end

  ::not_selected::
  return draw_line_text(self, idx, x, y)
end


command.add(nil, {
  ["draw-whitespace:toggle"]  = function()
    drawwhitespace.enabled = not drawwhitespace.enabled
  end,

  ["draw-whitespace:disable"] = function()
    drawwhitespace.enabled = false
  end,

  ["draw-whitespace:enable"]  = function()
    drawwhitespace.enabled = true
  end,
})
