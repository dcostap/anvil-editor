local common = require "core.common"

local links = {}

local function trim(text)
  return (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function split_once(text, sep)
  local index = text:find(sep, 1, true)
  if not index then return text end
  return text:sub(1, index - 1), text:sub(index + #sep)
end

function links.parse_resize(text)
  if type(text) ~= "string" then return nil end
  local width, height = text:match("^(%d+)[xX](%d+)$")
  if width then
    return { width = tonumber(width), height = tonumber(height) }
  end
  width = text:match("^(%d+)$")
  if width then
    return { width = tonumber(width) }
  end
end

local function parse_subtarget(raw_target)
  local path, fragment = split_once(raw_target or "", "#")
  if not fragment and path:sub(1, 1) == "^" then
    fragment = path
    path = ""
  end

  local subtarget
  if fragment and fragment ~= "" then
    if fragment:sub(1, 1) == "^" then
      subtarget = { type = "block", id = fragment:sub(2) }
    else
      subtarget = { type = "heading", text = fragment }
    end
  end

  return path or "", subtarget
end

local function display_name_for_target(path, subtarget)
  if path and path ~= "" then
    local name = common.basename(path):gsub("%.md$", "")
    return name ~= "" and name or path
  elseif subtarget then
    return subtarget.text or subtarget.id or ""
  end
  return ""
end

local function apply_target_model(result, raw_target, alias)
  local path, subtarget = parse_subtarget(raw_target)
  result.raw_target = raw_target
  result.path = path
  result.subtarget = subtarget
  result.alias = alias
  result.display = alias or display_name_for_target(path, subtarget)
  return result
end

function links.parse_wikilink_at(text, start_col, source_line)
  source_line = source_line or 1
  local is_embed = text:sub(start_col, start_col) == "!"
  local open_col = is_embed and start_col + 1 or start_col
  if text:sub(open_col, open_col + 1) ~= "[[" then
    return nil
  end

  local close_col = text:find("]]", open_col + 2, true)
  if not close_col then return nil end

  local inner = text:sub(open_col + 2, close_col - 1)
  local raw_target, suffix = split_once(inner, "|")
  raw_target = trim(raw_target)
  suffix = suffix and trim(suffix) or nil

  local resize
  local alias = suffix
  if is_embed and suffix then
    resize = links.parse_resize(suffix)
    if resize then alias = nil end
  end

  local result = apply_target_model({
    kind = is_embed and "embed" or "wiki",
    source_line = source_line,
    source_col1 = start_col,
    source_col2 = close_col + 2,
    is_embed = is_embed,
    resize = resize,
  }, raw_target, alias)

  return result, close_col + 2
end

local function find_matching_bracket(text, open_col)
  local depth = 0
  local escaped = false
  for i = open_col, #text do
    local ch = text:sub(i, i)
    if escaped then
      escaped = false
    elseif ch == "\\" then
      escaped = true
    elseif ch == "[" then
      depth = depth + 1
    elseif ch == "]" then
      depth = depth - 1
      if depth == 0 then return i end
    end
  end
end

local function parse_parenthesized_target(text, open_col)
  if text:sub(open_col, open_col) ~= "(" then return nil end
  local depth = 0
  local escaped = false
  for i = open_col, #text do
    local ch = text:sub(i, i)
    if escaped then
      escaped = false
    elseif ch == "\\" then
      escaped = true
    elseif ch == "(" then
      depth = depth + 1
    elseif ch == ")" then
      depth = depth - 1
      if depth == 0 then
        local body = trim(text:sub(open_col + 1, i - 1))
        local target
        if body:sub(1, 1) == "<" then
          local close = body:find(">", 2, true)
          target = close and body:sub(2, close - 1) or body
        else
          target = body:match("^(%S+)") or ""
        end
        return target, i
      end
    end
  end
end

function links.parse_markdown_link_at(text, start_col, source_line)
  source_line = source_line or 1
  local is_image = text:sub(start_col, start_col) == "!"
  local label_open = is_image and start_col + 1 or start_col
  if text:sub(label_open, label_open) ~= "[" then return nil end

  local label_close = find_matching_bracket(text, label_open)
  if not label_close or text:sub(label_close + 1, label_close + 1) ~= "(" then
    return nil
  end

  local target, finish = parse_parenthesized_target(text, label_close + 1)
  if not finish or target == "" then return nil end

  local label = text:sub(label_open + 1, label_close - 1)
  local alias = label
  local resize
  if is_image then
    local plain_alt, suffix = split_once(label, "|")
    if suffix then
      local parsed_resize = links.parse_resize(trim(suffix))
      if parsed_resize then
        alias = plain_alt
        resize = parsed_resize
      end
    end
  end

  local result = apply_target_model({
    kind = is_image and "image" or "markdown",
    source_line = source_line,
    source_col1 = start_col,
    source_col2 = finish + 1,
    is_embed = is_image,
    resize = resize,
  }, target, alias)
  if is_image then
    result.alt = alias
  end
  return result, finish + 1
end

local function semantic_range_text(text, range)
  if not range then return nil end
  return text:sub(range.col1, range.col2 - 1)
end

function links.from_semantic_node(text, source_line, node)
  if not (node and node.source and node.source.line1 == source_line and node.source.line2 == source_line) then
    return nil
  end
  local attributes = node.attributes or {}
  local kind, raw_target, alias, resize
  if node.type == "wiki_link" or node.type == "embed" then
    kind = node.type == "embed" and "embed" or "wiki"
    raw_target = trim(semantic_range_text(text, attributes.target))
    if attributes.alias then
      alias = trim(semantic_range_text(text, attributes.alias))
    else
      local source = semantic_range_text(text, node.source) or ""
      alias = source:find("|", 1, true) and "" or nil
    end
    if kind == "embed" and alias then
      resize = links.parse_resize(alias)
      if resize then alias = nil end
    end
  elseif node.type == "link" or node.type == "image" then
    kind = node.type == "image" and "image" or "markdown"
    raw_target = trim(semantic_range_text(text, attributes.link_destination))
    alias = semantic_range_text(text, attributes.link_text or attributes.image_alt)
    if alias == nil then
      local source = semantic_range_text(text, node.source) or ""
      alias = source:match("^!?%[(.*)%]%(")
    end
    if raw_target and raw_target:sub(1, 1) == "<" and raw_target:sub(-1) == ">" then
      raw_target = raw_target:sub(2, -2)
    end
    if kind == "image" and alias then
      local plain_alt, suffix = split_once(alias, "|")
      if suffix then
        resize = links.parse_resize(trim(suffix))
        if resize then alias = plain_alt end
      end
    end
  else
    return nil
  end
  if not raw_target or raw_target == "" then return nil end
  local result = apply_target_model({
    kind = kind,
    source_line = source_line,
    source_col1 = node.source.col1,
    source_col2 = node.source.col2,
    is_embed = kind == "embed" or kind == "image",
    resize = resize,
    semantic_id = node.id,
  }, raw_target, alias)
  if kind == "image" then result.alt = alias end
  return result
end

function links.find_links(text, source_line)
  local found = {}
  local i = 1
  while i <= #text do
    local link, next_col
    local ch = text:sub(i, i)
    if ch == "!" and text:sub(i + 1, i + 2) == "[[" then
      link, next_col = links.parse_wikilink_at(text, i, source_line)
    elseif ch == "[" and text:sub(i + 1, i + 1) == "[" then
      link, next_col = links.parse_wikilink_at(text, i, source_line)
    elseif ch == "!" and text:sub(i + 1, i + 1) == "[" then
      link, next_col = links.parse_markdown_link_at(text, i, source_line)
    elseif ch == "[" then
      link, next_col = links.parse_markdown_link_at(text, i, source_line)
    end

    if link then
      found[#found + 1] = link
      i = next_col
    else
      i = i + 1
    end
  end
  return found
end

return links
