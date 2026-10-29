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

-- Tables write the separator as `\|`. A note name cannot hold `|` or `\`,
-- so the first pipe separates the target from the alias either way.
local function split_wiki_inner(inner)
  local raw_target, alias = split_once(inner, "|")
  if alias then
    raw_target = raw_target:gsub("\\$", "")
    alias = alias:gsub("\\|", "|")
  end
  return raw_target, alias
end

local function split_last(text, sep)
  local index = nil
  while true do
    local found = text:find(sep, (index or 0) + 1, true)
    if not found then break end
    index = found
  end
  if index then return text:sub(1, index - 1), text:sub(index + #sep) end
end

local function percent_decode(text)
  return (text or ""):gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)
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

-- An image label holds its size alone or as its last "|" part, as in
-- Obsidian: "300", "Alt|300" or "Alt|640x480".
local function split_resize(label)
  local resize = links.parse_resize(trim(label))
  if resize then return nil, resize end
  local alt, last = label:match("^(.*)|([^|]*)$")
  resize = last and links.parse_resize(trim(last))
  if resize then return alt, resize end
  return label, nil
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
  local filesystem_destination = result.kind == "markdown" or result.kind == "image"
    or result.kind == "reference"
  if filesystem_destination and not path:match("^[%a][%w+.-]*:") then
    path = percent_decode(path)
    if subtarget then
      if subtarget.text then subtarget.text = percent_decode(subtarget.text) end
      if subtarget.id then subtarget.id = percent_decode(subtarget.id) end
    end
  end
  result.raw_target = raw_target
  result.path = path
  result.subtarget = subtarget
  result.alias = alias
  result.display = alias or display_name_for_target(path, subtarget)
  return result
end

function links.from_target(kind, raw_target, alias, fields)
  local result = fields or {}
  result.kind = kind
  return apply_target_model(result, trim(raw_target), alias)
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
  local raw_target, suffix = split_wiki_inner(inner)
  raw_target = trim(raw_target)
  suffix = suffix and trim(suffix) or nil

  local resize
  local alias = suffix
  if is_embed and suffix then
    alias, resize = split_resize(suffix)
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

-- Returns the column of the bracket that closes the one at `open_col`.
-- Scanning jumps between brackets and escapes, so a long embedded data URI
-- costs one search instead of one Lua step per byte.
local function find_closing_delimiter(text, open_col, open, close, pattern)
  local depth = 0
  local i = open_col
  while true do
    i = text:find(pattern, i)
    if not i then return nil end
    local ch = text:sub(i, i)
    if ch == "\\" then
      i = i + 1
    elseif ch == open then
      depth = depth + 1
    elseif ch == close then
      depth = depth - 1
      if depth == 0 then return i end
    end
    i = i + 1
  end
end

local function find_matching_bracket(text, open_col)
  return find_closing_delimiter(text, open_col, "[", "]", "[%[%]\\]")
end

local function parse_parenthesized_target(text, open_col)
  if text:sub(open_col, open_col) ~= "(" then return nil end
  local i = find_closing_delimiter(text, open_col, "(", ")", "[()\\]")
  if not i then return nil end
  local body_start, body_end = open_col + 1, i - 1
  while body_start <= body_end and text:sub(body_start, body_start):match("%s") do
    body_start = body_start + 1
  end
  while body_end >= body_start and text:sub(body_end, body_end):match("%s") do
    body_end = body_end - 1
  end
  local target
  local destination_col1, destination_col2
  if text:sub(body_start, body_start) == "<" then
    local close = text:find(">", body_start + 1, true)
    if close and close > body_end then close = nil end
    destination_col1 = close and body_start + 1 or body_start
    destination_col2 = close or body_end + 1
    target = text:sub(destination_col1, destination_col2 - 1)
  else
    destination_col1 = body_start
    local space = text:find("%s", body_start)
    destination_col2 = (space and space <= body_end) and space or body_end + 1
    target = text:sub(destination_col1, destination_col2 - 1)
  end
  return target, i, destination_col1, destination_col2
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

  local target, finish, destination_col1, destination_col2 =
    parse_parenthesized_target(text, label_close + 1)
  if not finish or target == "" then return nil end

  local label = text:sub(label_open + 1, label_close - 1)
  local alias = label
  local resize
  if is_image then
    alias, resize = split_resize(label)
  end

  local result = apply_target_model({
    kind = is_image and "image" or "markdown",
    source_line = source_line,
    source_col1 = start_col,
    source_col2 = finish + 1,
    is_embed = is_image,
    resize = resize,
    link_text_range = {
      line1 = source_line, col1 = label_open + 1,
      line2 = source_line, col2 = label_close,
    },
    link_destination_range = {
      line1 = source_line, col1 = destination_col1,
      line2 = source_line, col2 = destination_col2,
    },
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
      alias = trim(semantic_range_text(text, attributes.alias):gsub("\\|", "|"))
    else
      local source = semantic_range_text(text, node.source) or ""
      alias = source:find("|", 1, true) and "" or nil
    end
    if kind == "embed" and alias then
      alias, resize = split_resize(alias)
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
      alias, resize = split_resize(alias)
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

-- The label and target columns of `source` when it is one complete image
-- link. An end column is exclusive.
local function image_parts(source)
  if source:sub(1, 3) == "![[" then
    local link, finish = links.parse_wikilink_at(source, 1)
    if not link or finish ~= #source + 1 then return nil end
    local bar = source:find("|", 4, true)
    local escaped = bar and source:sub(bar - 1, bar - 1) == "\\"
    return {
      wiki = true, bar = escaped and "\\|" or "|",
      target_col1 = 4, target_col2 = bar and (escaped and bar - 1 or bar) or #source - 1,
      label_col1 = bar and bar + 1 or #source - 1, label_col2 = #source - 1,
    }
  end
  local link, finish = links.parse_markdown_link_at(source, 1)
  if not (link and link.kind == "image" and finish == #source + 1) then return nil end
  return {
    target_col1 = link.link_destination_range.col1,
    target_col2 = link.link_destination_range.col2,
    label_col1 = link.link_text_range.col1,
    label_col2 = link.link_text_range.col2,
    bar = "|",
  }
end

-- Obsidian's rule: a size label becomes the new size; a label that ends
-- with a size gets the new size there; another label gets it appended.
local function label_with_width(label, width, bar)
  local size = width and tostring(width) or ""
  if label == "" or links.parse_resize(trim(label)) then return size end
  local alt, last = split_last(label, bar)
  if alt and links.parse_resize(trim(last)) then
    return width and alt .. bar .. size or alt
  end
  return width and label .. bar .. size or label
end

---Return the source of an image link with its width set to `width`, or
---with no size when `width` is nil. Returns nil when `source` is not one
---complete image link, such as a reference image.
---@param source string
---@param width integer?
---@return string?
function links.with_image_width(source, width)
  local parts = image_parts(source)
  if not parts then return nil end
  local label = label_with_width(
    source:sub(parts.label_col1, parts.label_col2 - 1), width, parts.bar
  )
  if parts.wiki then
    local target = source:sub(4, parts.target_col2 - 1)
    return "![[" .. target .. (label ~= "" and parts.bar .. label or "") .. "]]"
  end
  return source:sub(1, parts.label_col1 - 1) .. label .. source:sub(parts.label_col2)
end

---Return the columns of the target in an image link's source. The end
---column is exclusive.
---@param source string
---@return integer? col1
---@return integer? col2
function links.image_target_range(source)
  local parts = image_parts(source)
  if not parts then return nil end
  return parts.target_col1, parts.target_col2
end

function links.find_links(text, source_line)
  local found = {}
  local i = 1
  while true do
    i = text:find("[!%[]", i)
    if not i then break end
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
