local position = {}

local function normalize_encoding(encoding)
  encoding = (encoding or "utf-16"):lower():gsub("_", "-")
  if encoding == "utf8" then encoding = "utf-8" end
  if encoding == "utf16" then encoding = "utf-16" end
  return encoding
end

local function get_line(doc, line)
  if doc.get_utf8_line then
    return doc:get_utf8_line(line)
  end
  return doc.lines and doc.lines[line] or "\n"
end

local function line_count(doc)
  return doc.lines and #doc.lines or 1
end

local function line_content(raw)
  raw = raw or "\n"
  if raw:sub(-1) == "\n" then
    raw = raw:sub(1, -2)
    if raw:sub(-1) == "\r" then
      raw = raw:sub(1, -2)
    end
  end
  return raw
end

local function max_doc_col(raw)
  raw = raw or "\n"
  if raw:sub(-1) == "\n" then
    return #raw
  end
  return #raw + 1
end

local function clamp_number(value, fallback)
  value = tonumber(value)
  if not value or value ~= value then return fallback end
  return math.floor(value)
end

local function clamp_doc_position(doc, line, col)
  local nlines = math.max(line_count(doc), 1)
  line = clamp_number(line, 1)
  if line < 1 then line = 1 end
  if line > nlines then line = nlines end
  local raw = get_line(doc, line)
  local max_col = max_doc_col(raw)
  col = clamp_number(col, 1)
  if col < 1 then col = 1 end
  if col > max_col then col = max_col end
  return line, col, line_content(raw), max_col
end

local function utf8_decode_at(text, index)
  local b1 = text:byte(index)
  if not b1 then return nil, index end
  if b1 < 0x80 then
    return b1, index + 1
  end

  local needed, min_cp
  if b1 >= 0xC2 and b1 <= 0xDF then
    needed, min_cp = 2, 0x80
  elseif b1 >= 0xE0 and b1 <= 0xEF then
    needed, min_cp = 3, 0x800
  elseif b1 >= 0xF0 and b1 <= 0xF4 then
    needed, min_cp = 4, 0x10000
  else
    return b1, index + 1
  end

  if index + needed - 1 > #text then
    return b1, index + 1
  end

  local cp = b1 % (2 ^ (8 - needed - 1))
  for offset = 1, needed - 1 do
    local byte = text:byte(index + offset)
    if not byte or byte < 0x80 or byte > 0xBF then
      return b1, index + 1
    end
    cp = cp * 0x40 + (byte - 0x80)
  end
  if cp < min_cp or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then
    return b1, index + 1
  end
  return cp, index + needed
end

local function utf16_units_for_codepoint(cp)
  return cp and cp > 0xFFFF and 2 or 1
end

local function utf16_units_before_byte(text, byte_count)
  local units = 0
  local index = 1
  local limit = math.min(byte_count, #text)
  while index <= limit do
    local cp, next_index = utf8_decode_at(text, index)
    if not cp then break end
    if next_index - 1 > limit then
      break
    end
    units = units + utf16_units_for_codepoint(cp)
    index = next_index
  end
  return units
end

local function byte_col_from_utf16_units(text, target_units, bias)
  target_units = clamp_number(target_units, 0)
  if target_units <= 0 then return 1 end
  local units = 0
  local index = 1
  while index <= #text do
    local cp, next_index = utf8_decode_at(text, index)
    if not cp then break end
    local char_units = utf16_units_for_codepoint(cp)
    if units + char_units > target_units then
      if bias == "right" or bias == "after" or bias == "end" then
        return next_index
      end
      return index
    elseif units + char_units == target_units then
      return next_index
    end
    units = units + char_units
    index = next_index
  end
  return #text + 1
end

function position.doc_to_lsp(doc, line, col, encoding)
  encoding = normalize_encoding(encoding)
  local text
  line, col, text = clamp_doc_position(doc, line, col)
  local byte_count = math.min(math.max(col - 1, 0), #text)
  local character
  if encoding == "utf-8" then
    character = byte_count
  else
    character = utf16_units_before_byte(text, byte_count)
  end
  return { line = line - 1, character = character }
end

function position.lsp_to_doc(doc, lsp_position, encoding, bias)
  encoding = normalize_encoding(encoding)
  lsp_position = type(lsp_position) == "table" and lsp_position or {}
  local nlines = math.max(line_count(doc), 1)
  local lsp_line = clamp_number(lsp_position.line, 0)
  if lsp_line < 0 then lsp_line = 0 end
  if lsp_line > nlines - 1 then lsp_line = nlines - 1 end
  local line = lsp_line + 1
  local raw = get_line(doc, line)
  local text = line_content(raw)
  local max_col = max_doc_col(raw)
  local character = clamp_number(lsp_position.character, 0)
  if character < 0 then character = 0 end

  local col
  if encoding == "utf-8" then
    col = character + 1
  else
    col = byte_col_from_utf16_units(text, character, bias)
  end
  if col < 1 then col = 1 end
  if col > max_col then col = max_col end
  return line, col
end

local function doc_range_points(range)
  if range.line1 or range.col1 or range.line2 or range.col2 then
    return range.line1, range.col1, range.line2, range.col2
  end
  if range.start or range[1] and type(range[1]) == "table" then
    local start = range.start or range[1]
    local finish = range["end"] or range.finish or range[2]
    if start and finish then
      return start.line or start[1], start.col or start.column or start[2],
        finish.line or finish[1], finish.col or finish.column or finish[2]
    end
  end
  return range[1], range[2], range[3], range[4]
end

function position.range_doc_to_lsp(doc, range, encoding)
  local line1, col1, line2, col2 = doc_range_points(range or {})
  return {
    start = position.doc_to_lsp(doc, line1, col1, encoding),
    ["end"] = position.doc_to_lsp(doc, line2, col2, encoding),
  }
end

function position.range_lsp_to_doc(doc, range, encoding, bias)
  range = type(range) == "table" and range or {}
  local start = range.start or range[1] or {}
  local finish = range["end"] or range.finish or range[2] or {}
  local line1, col1 = position.lsp_to_doc(doc, start, encoding, bias)
  local line2, col2 = position.lsp_to_doc(doc, finish, encoding, bias)
  return {
    line1,
    col1,
    line2,
    col2,
    line1 = line1,
    col1 = col1,
    line2 = line2,
    col2 = col2,
  }
end

return position
