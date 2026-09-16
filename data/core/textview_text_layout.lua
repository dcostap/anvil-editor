local core = require "core"
local style = require "core.style"
local MAX_RUN_BYTES = 512
-- Keep a full viewport of rows plus reuse from the divider and caret queries.
local MAX_CACHED_ROWS = 256

-- Drawing and position mapping must use the same text, font, and tab origin.
local Layout = {}
Layout.__index = Layout

local font_key_frame, font_key_cache
local function font_key(font)
  -- Font metrics only change between frames. One frame reuses one result per font.
  local frame = core.render_frame_active and core.render_frame_id
  if frame and frame ~= font_key_frame then
    font_key_frame, font_key_cache = frame, {}
  end
  local cache = frame and font_key_cache
  local cached = cache and cache[font]
  if cached then return cached end
  local key
  if type(font) == "table" then
    local parts = { tostring(font) }
    for _, child in ipairs(font) do parts[#parts + 1] = font_key(child) end
    key = table.concat(parts, ":")
  else
    key = tostring(font) .. ":" .. font:get_generation()
      .. ":" .. font:get_surface_scale()
  end
  if cache then cache[font] = key end
  return key
end

local function same_tokens(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end

function Layout.get(view, line, first, last, leading, wrapped)
  local default_font = view:get_font()
  local _, tabs = view.buffer:get_indent_info()
  local override = view:decoration_text_color(line)
  local tokens = override and { "normal", view.buffer.lines[line] }
    or (wrapped and view.buffer.highlighter:get_line(line)
      or view.buffer.highlighter:get_render_line(line)).tokens
  local key = { tostring(first), tostring(last), tostring(leading), tostring(tabs),
    font_key(default_font), tostring(override) }
  local kinds = {}
  for i = 1, #tokens, 2 do
    local kind = tokens[i]
    if not kinds[kind] then
      kinds[kind] = true
      local font = not override and style.syntax_fonts[kind] or default_font
      key[#key + 1] = font_key(font or default_font)
      key[#key + 1] = tostring(override or style.syntax[kind] or style.syntax.normal)
    end
  end
  key = table.concat(key, "\0")
  local cache = view.__plain_text_layouts
  if not cache then
    -- Ring buffer: reuse keeps the newest rows, and eviction costs no shifting.
    cache = { slots = {}, head = 1, count = 0 }
    view.__plain_text_layouts = cache
    core.log_quiet("Shared text layout enabled for %s", view.buffer:get_name())
  end
  local token_id = override and view.buffer.lines[line] or tokens
  local slots, count = cache.slots, cache.count
  for i = 1, count do
    local entry = slots[i]
    if entry.key == key then
      if entry.token_id == token_id then return entry end
      -- Some providers hand out equal tokens in a new table. Accept them once.
      if same_tokens(entry.tokens, tokens) then
        entry.token_id = token_id
        return entry
      end
    end
  end

  local self = setmetatable({ key = key, tokens = {}, runs = {}, first = first,
    last = last, leading = leading, width = leading }, Layout)
  for i = 1, #tokens do self.tokens[i] = tokens[i] end
  local col = 1
  for i = 1, #tokens, 2 do
    local kind, text = tokens[i], tokens[i + 1]
    local from, to = math.max(col, first), math.min(col + #text, last)
    if from < to then
      local font = not override and style.syntax_fonts[kind] or default_font
      font = font or default_font
      local color = override or style.syntax[kind] or style.syntax.normal
      local segment = text:sub(from - col + 1, to - col)
      local previous = self.runs[#self.runs]
      if previous and previous.font == font and previous.color == color
        and #previous.text + #segment <= MAX_RUN_BYTES then
        previous.text = previous.text .. segment
        previous.last = to
      else
        self.runs[#self.runs + 1] = {
          font = font, color = color, text = segment, first = from, last = to,
        }
      end
    end
    col = col + #text
    if col >= last then break end
  end
  local runs = self.runs
  self.runs = {}
  for _, source in ipairs(runs) do
    local first_byte = 1
    while first_byte <= #source.text do
      local last_byte = math.min(#source.text, first_byte + MAX_RUN_BYTES - 1)
      if last_byte < #source.text then
        -- Keep bounded draw commands. Prefer a word boundary, then a UTF-8 boundary.
        local boundary = source.text:sub(first_byte, last_byte):match(".*()[ \t]")
        if boundary then last_byte = first_byte + boundary - 1 end
        while last_byte > first_byte do
          local byte = source.text:byte(last_byte + 1)
          if byte < 128 or byte >= 192 then break end
          last_byte = last_byte - 1
        end
      end
      self.runs[#self.runs + 1] = {
        font = source.font, color = source.color,
        text = source.text:sub(first_byte, last_byte),
        first = source.first + first_byte - 1, last = source.first + last_byte,
      }
      first_byte = last_byte + 1
    end
  end
  for _, run in ipairs(self.runs) do
    run.font:set_tab_size(tabs)
    run.x = self.width
    run.layout = run.font:text_layout(run.text, { tab_offset = run.x })
    run.width = run.layout:width()
    self.width = self.width + run.width
  end
  self.tabs = tabs
  self.token_id = token_id
  if count < MAX_CACHED_ROWS then
    count = count + 1
    slots[count] = self
    cache.count = count
  else
    slots[cache.head] = self
    cache.head = cache.head % MAX_CACHED_ROWS + 1
  end
  return self
end

function Layout:x_at(col)
  for _, run in ipairs(self.runs) do
    if col <= run.last then
      return run.x + run.layout:width_at(math.max(0, col - run.first))
    end
  end
  return self.width
end

function Layout:col_at(x)
  for _, run in ipairs(self.runs) do
    if x <= run.x + run.width then
      return run.first + run.layout:byte_at_x(x - run.x)
    end
  end
  return self.last
end

function Layout:add_to_packet(builder, layer, row, y)
  for _, run in ipairs(self.runs) do
    builder:add_text(layer, row, run.font, run.text, run.x, y, run.color,
      run.x, self.tabs)
  end
end

function Layout:draw(view, x, y)
  local stats = core.textview_frame_stats
  local right = view.position.x + view.size.x
  for _, run in ipairs(self.runs) do
    local overhang = run.font:get_height()
    if x + run.x - overhang > right then break end
    if x + run.x + run.width + overhang >= view.position.x then
      run.font:set_tab_size(self.tabs)
      local started = stats and system.get_time()
      renderer.draw_text(run.font, run.text, x + run.x, y, run.color,
        { tab_offset = run.x })
      if stats then
        stats.draw_text_calls = stats.draw_text_calls + 1
        stats.tokens = stats.tokens + 1
        stats.renderer_draw_text_ms = stats.renderer_draw_text_ms
          + (system.get_time() - started) * 1000
      end
    end
  end
end

return Layout
