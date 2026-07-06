-- Worker-safe Tree-sitter project index record construction helpers.
--
-- This module intentionally does not require core or UI modules. It converts
-- native Tree-sitter capture tables plus plain source lines into the compact
-- symbol/usage records consumed by the project index UI side.

local records = {}

function records.lines_from_text(text)
  local lines = {}
  local pos = 1
  text = tostring(text or "")
  while pos <= #text do
    local nl = text:find("\n", pos, true)
    if nl then
      lines[#lines + 1] = text:sub(pos, nl)
      pos = nl + 1
    else
      lines[#lines + 1] = text:sub(pos)
      break
    end
  end
  if #lines == 0 then lines[1] = "\n" end
  return lines
end

local function text_for_capture(lines, capture)
  if not capture then return "" end
  local start_line = capture.start_line or 1
  local end_line = capture.end_line or start_line
  local start_col = capture.start_col or 1
  local end_col = capture.end_col or start_col
  if start_line == end_line then
    local line = lines[start_line] or ""
    return line:sub(start_col, math.max(start_col - 1, end_col - 1))
  end
  local parts = {}
  for line_idx = start_line, end_line do
    local line = lines[line_idx] or ""
    if line_idx == start_line then
      parts[#parts + 1] = line:sub(start_col)
    elseif line_idx == end_line then
      parts[#parts + 1] = line:sub(1, math.max(0, end_col - 1))
    else
      parts[#parts + 1] = line
    end
  end
  return table.concat(parts)
end
records.text_for_capture = text_for_capture

local function trim_name(name)
  name = tostring(name or "")
  name = name:gsub("^%s+", ""):gsub("%s+$", "")
  return name:gsub("%s+", " ")
end

local function outline_kind(capture_name)
  return tostring(capture_name or ""):match("^outline%.(.+)$")
end

local function capture_kind(capture_name)
  return tostring(capture_name or ""):match("^definition%.(.+)$")
end
records.capture_kind = capture_kind

local function range_from_capture(capture)
  return {
    start = { line = capture.start_line, col = capture.start_col },
    ["end"] = { line = capture.end_line, col = capture.end_col },
  }
end

local function collapse_signature_text(text)
  text = tostring(text or "")
  text = text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return nil end
  return text
end

local function strip_signature_body(text)
  text = tostring(text or "")
  local body_start = text:find("{", 1, true)
  if body_start then text = text:sub(1, body_start - 1) end
  return text
end

local function collapse_text_with_span(text, span_start, span_end)
  text = tostring(text or "")
  span_start = tonumber(span_start) or 1
  span_end = tonumber(span_end) or 0
  local out = {}
  local source_to_out = {}
  local out_len = 0
  local pending_space = false
  local seen_text = false
  for i = 1, #text do
    local ch = text:sub(i, i)
    if ch:match("%s") then
      if seen_text then pending_space = true end
    else
      if pending_space then
        out_len = out_len + 1
        out[out_len] = " "
        pending_space = false
      end
      out_len = out_len + 1
      out[out_len] = ch
      source_to_out[i] = out_len
      seen_text = true
    end
  end
  local start_pos, end_pos
  for i = span_start, span_end do
    local pos = source_to_out[i]
    if pos then
      start_pos = start_pos or pos
      end_pos = pos
    end
  end
  local collapsed = table.concat(out)
  if collapsed == "" then return nil end
  return collapsed, start_pos and { start_pos, end_pos } or nil
end

local function declaration_preview(lines, item, name_capture)
  if not item or not name_capture then return nil end
  local raw = strip_signature_body(text_for_capture(lines, item))
  if raw == "" then return nil end
  local name_start = (name_capture.start_byte or 0) - (item.start_byte or 0) + 1
  local name_end = (name_capture.end_byte or 0) - (item.start_byte or 0)
  if name_start < 1 or name_end < name_start or name_start > #raw then return nil end
  name_end = math.min(name_end, #raw)
  return collapse_text_with_span(raw, name_start, name_end)
end

local function group_signature(lines, group, name)
  local captures = group and group.signatures
  if not captures or #captures == 0 then return nil end
  table.sort(captures, function(a, b)
    if a.start_byte ~= b.start_byte then return a.start_byte < b.start_byte end
    if a.end_byte ~= b.end_byte then return a.end_byte < b.end_byte end
    return tostring(a.capture) < tostring(b.capture)
  end)

  local params, returns, full = {}, {}, {}
  for _, capture in ipairs(captures) do
    local text = text_for_capture(lines, capture)
    if capture.capture == "signature.params" then
      params[#params + 1] = text
    elseif capture.capture == "signature.return" then
      returns[#returns + 1] = text
    else
      full[#full + 1] = text
    end
  end

  local signature
  if #params > 0 then
    signature = table.concat(params, " ")
    if #returns > 0 then signature = signature .. " -> " .. table.concat(returns, " ") end
  elseif #full > 0 then
    signature = strip_signature_body(table.concat(full, " "))
    signature = signature:gsub("^%s*proc%s*", "")
  end

  signature = collapse_signature_text(signature)
  if not signature or signature == "" then return nil end
  if name and name ~= "" then
    signature = signature:gsub("^" .. name:gsub("([^%w])", "%%%1") .. "%s*", "")
    signature = collapse_signature_text(signature)
  end
  return signature
end

local function symbol_from_group(lines, group)
  if not group or not group.item or not group.name then return nil end
  local name = trim_name(text_for_capture(lines, group.name))
  if name == "" then return nil end
  local item = group.item
  local declaration, declaration_name_span = declaration_preview(lines, item, group.name)
  return {
    name = name,
    kind = group.kind,
    signature = group_signature(lines, group, name),
    declaration = declaration,
    declaration_name_span = declaration_name_span,
    start_line = item.start_line,
    start_col = item.start_col,
    end_line = item.end_line,
    end_col = item.end_col,
    start_byte = item.start_byte,
    end_byte = item.end_byte,
    range = range_from_capture(item),
    name_range = range_from_capture(group.name),
    children = {},
  }
end

local function compare_symbols(a, b)
  if a.start_byte ~= b.start_byte then return a.start_byte < b.start_byte end
  if a.end_byte ~= b.end_byte then return a.end_byte > b.end_byte end
  return a.name < b.name
end

local function contains(parent, child)
  if not parent or not child then return false end
  if parent == child then return false end
  return parent.start_byte <= child.start_byte and parent.end_byte >= child.end_byte
      and (parent.start_byte ~= child.start_byte or parent.end_byte ~= child.end_byte)
end

local function assign_parents(symbols)
  local stack = {}
  for i, symbol in ipairs(symbols) do
    symbol.index = i
    while #stack > 0 and not contains(stack[#stack], symbol) do
      stack[#stack] = nil
    end
    local parent = stack[#stack]
    if parent then
      symbol.parent = parent.index
      symbol.parent_name = parent.name
      symbol.depth = (parent.depth or 0) + 1
      parent.children[#parent.children + 1] = i
    else
      symbol.depth = 0
    end
    stack[#stack + 1] = symbol
  end
end

local function add_symbol_capture_group(groups, capture)
  local match_id = capture.match_id or capture.order or 0
  local group = groups[match_id]
  if not group then
    group = {}
    groups[match_id] = group
  end
  local kind = outline_kind(capture.capture)
  if kind then
    if not group.item or (capture.end_byte - capture.start_byte) > (group.item.end_byte - group.item.start_byte) then
      group.item = capture
      group.kind = kind
    end
  elseif capture.capture == "name" then
    if not group.name or (capture.end_byte - capture.start_byte) < (group.name.end_byte - group.name.start_byte) then
      group.name = capture
    end
  elseif tostring(capture.capture):match("^signature") then
    group.signatures = group.signatures or {}
    group.signatures[#group.signatures + 1] = capture
  end
end

local function symbols_from_groups(groups, lines)
  local symbols = {}
  for _, group in pairs(groups) do
    local symbol = symbol_from_group(lines, group)
    if symbol then symbols[#symbols + 1] = symbol end
  end
  table.sort(symbols, compare_symbols)
  assign_parents(symbols)
  return symbols
end

function records.symbols_from_capture_iter(iter, lines)
  local groups = {}
  for capture in iter do
    add_symbol_capture_group(groups, capture)
  end
  return symbols_from_groups(groups, lines)
end

function records.symbols_from_captures(captures, lines)
  local groups = {}
  for _, capture in ipairs(captures or {}) do
    add_symbol_capture_group(groups, capture)
  end
  return symbols_from_groups(groups, lines)
end

function records.is_usage_capture(capture)
  local name = capture and capture.capture
  if not name then return false end
  return name == "reference"
      or name == "usage"
      or tostring(name):match("^usage%.") ~= nil
      or capture_kind(name) ~= nil
end

function records.usage_from_capture(path, relpath, lines, language, capture)
  local text = text_for_capture(lines, capture)
  if text == "" then return nil end
  local definition_kind = capture_kind(capture.capture)
  local line = lines[capture.start_line] or ""
  return {
    name = text,
    kind = definition_kind or "usage",
    capture = capture.capture,
    is_declaration = definition_kind ~= nil,
    path = path,
    file = relpath or path,
    relpath = relpath or path,
    language_id = language.id,
    text = text,
    line_text = line:gsub("\n$", ""),
    start_line = capture.start_line,
    start_col = capture.start_col,
    end_line = capture.end_line,
    end_col = capture.end_col,
    start_byte = capture.start_byte,
    end_byte = capture.end_byte,
    range = {
      start = { line = capture.start_line, col = capture.start_col },
      ["end"] = { line = capture.end_line, col = capture.end_col },
    },
    workspace_tree_sitter_fallback = true,
  }
end

function records.add_usage(usages_by_name, item)
  if not item then return false end
  local list = usages_by_name[item.name]
  if not list then
    list = {}
    usages_by_name[item.name] = list
  end
  list[#list + 1] = item
  return true
end

local function add_usage_capture(by_range, path, relpath, lines, language, capture)
  if records.is_usage_capture(capture) then
    local item = records.usage_from_capture(path, relpath, lines, language, capture)
    if item then
      local key = table.concat({ item.name, tostring(item.start_byte or 0), tostring(item.end_byte or 0) }, "\0")
      local existing = by_range[key]
      if not existing or (item.is_declaration and not existing.is_declaration) then
        by_range[key] = item
      end
    end
  end
end

local function usages_from_range_map(by_range)
  local usages_by_name = {}
  local count = 0
  for _, item in pairs(by_range) do
    if records.add_usage(usages_by_name, item) then count = count + 1 end
  end
  return usages_by_name, count
end

function records.usages_from_capture_iter(iter, path, relpath, lines, language)
  local by_range = {}
  for capture in iter do
    add_usage_capture(by_range, path, relpath, lines, language, capture)
  end
  return usages_from_range_map(by_range)
end

function records.usages_from_captures(captures, path, relpath, lines, language)
  local by_range = {}
  for _, capture in ipairs(captures or {}) do
    add_usage_capture(by_range, path, relpath, lines, language, capture)
  end
  return usages_from_range_map(by_range)
end

return records
