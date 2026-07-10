local parser = require "core.markdown.parser"

local anchors = {}

local function trim(text)
  return (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

function anchors.normalize_heading(text)
  text = trim(text):lower()
  text = text:gsub("`([^`]*)`", "%1")
  text = text:gsub("[%*_~%[%]%(%)!#]", "")
  text = text:gsub("&amp;", "and")
  text = text:gsub("[^%w%s%-%_]+", "")
  text = trim(text):gsub("%s+", "-")
  return text
end

function anchors.collect_headings(blocks)
  local result = {}
  local seen = {}
  local hierarchy = {}
  for _, block in ipairs(blocks or {}) do
    if block.type == "heading" then
      local base = anchors.normalize_heading(block.text or "")
      local slug = base
      if seen[base] then
        seen[base] = seen[base] + 1
        slug = base .. "-" .. seen[base]
      else
        seen[base] = 0
      end
      local level = block.level or 1
      for i = level, #hierarchy do hierarchy[i] = nil end
      hierarchy[level] = block.text or ""
      local path = {}
      for i = 1, level do
        if hierarchy[i] and hierarchy[i] ~= "" then path[#path + 1] = hierarchy[i] end
      end
      local path_slugs = {}
      for _, part in ipairs(path) do path_slugs[#path_slugs + 1] = anchors.normalize_heading(part) end
      result[#result + 1] = {
        type = "heading",
        text = block.text,
        slug = slug,
        path = path,
        path_text = table.concat(path, "#"),
        path_slug = table.concat(path_slugs, "#"),
        line = block.line1,
        level = level,
        block = block,
      }
    end
  end
  return result
end

local function is_in_span(spans, col1, col2)
  for _, span in ipairs(spans or {}) do
    if span.col1 < col2 and col1 < span.col2 then return true end
  end
  return false
end

local function has_block_id_boundary(line, col1, col2)
  local before = col1 > 1 and line:sub(col1 - 1, col1 - 1) or ""
  local after = line:sub(col2 + 1, col2 + 1)
  return (before == "" or before:match("%s"))
    and (after == "" or after:match("%s") or after:match("[.,;:!?%)]"))
end

function anchors.find_block_ids_in_lines(lines)
  local result = {}
  for line_no, line in ipairs(lines or {}) do
    local spans = parser.parse_inline(line, line_no)
    local start = 1
    while true do
      local col1, col2, id = line:find("%^(%w[%w%-]*)", start)
      if not col1 then break end
      if has_block_id_boundary(line, col1, col2) and not is_in_span(spans, col1, col2 + 1) then
        result[#result + 1] = {
          type = "block",
          id = id,
          line = line_no,
          col1 = col1,
          col2 = col2 + 1,
        }
      end
      start = col2 + 1
    end
  end
  return result
end

function anchors.index_document(text_or_parse_result)
  local parsed = type(text_or_parse_result) == "table" and text_or_parse_result
    or parser.parse(text_or_parse_result or "")
  return {
    headings = anchors.collect_headings(parsed.blocks),
    blocks = anchors.find_block_ids_in_lines(parsed.lines),
  }
end

return anchors
