local links = require "core.markdown.links"

local parser = {}

local function trim(text)
  return (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

function parser.split_lines(text)
  local lines = {}
  text = (text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  if #lines == 0 then lines[1] = "" end
  return lines
end

local function is_blank(line)
  return line:match("^%s*$") ~= nil
end

local function range(line, col1, col2)
  return { line = line, col1 = col1, col2 = col2 }
end

local function add_span(spans, span)
  spans[#spans + 1] = span
end

local function ranges_overlap(a, b)
  return a.col1 < b.col2 and b.col1 < a.col2
end

local function range_is_covered(covered, col1, col2)
  local probe = { col1 = col1, col2 = col2 }
  for _, item in ipairs(covered) do
    if ranges_overlap(item, probe) then return true end
  end
  return false
end

local function mark_covered(covered, col1, col2)
  covered[#covered + 1] = { col1 = col1, col2 = col2 }
end

local function collect_escaped_ranges(line, covered)
  local i = 1
  while i < #line do
    if line:sub(i, i) == "\\" then
      mark_covered(covered, i + 1, i + 2)
      i = i + 2
    else
      i = i + 1
    end
  end
end

local function parse_code_spans(line, line_no, spans, covered, col_offset)
  local i = 1
  while i <= #line do
    if line:sub(i, i) == "`" then
      local count = 1
      while line:sub(i + count, i + count) == "`" do count = count + 1 end
      local fence = string.rep("`", count)
      local close = line:find(fence, i + count, true)
      if close then
        add_span(spans, {
          type = "code",
          line = line_no,
          col1 = i + col_offset,
          col2 = close + count + col_offset,
          marker_ranges = { range(line_no, i + col_offset, i + count + col_offset), range(line_no, close + col_offset, close + count + col_offset) },
          content_ranges = { range(line_no, i + count + col_offset, close + col_offset) },
          text = line:sub(i + count, close - 1),
        })
        mark_covered(covered, i, close + count)
        i = close + count
      else
        i = i + count
      end
    else
      i = i + 1
    end
  end
end

local function parse_delimited(line, line_no, spans, covered, marker, span_type, col_offset)
  local i = 1
  local marker_len = #marker
  while i <= #line - marker_len + 1 do
    if line:sub(i, i + marker_len - 1) == marker and not range_is_covered(covered, i, i + marker_len) then
      local close = line:find(marker, i + marker_len, true)
      while close and range_is_covered(covered, close, close + marker_len) do
        close = line:find(marker, close + marker_len, true)
      end
      if close and close > i + marker_len then
        add_span(spans, {
          type = span_type,
          line = line_no,
          col1 = i + col_offset,
          col2 = close + marker_len + col_offset,
          marker_ranges = { range(line_no, i + col_offset, i + marker_len + col_offset), range(line_no, close + col_offset, close + marker_len + col_offset) },
          content_ranges = { range(line_no, i + marker_len + col_offset, close + col_offset) },
          text = line:sub(i + marker_len, close - 1),
        })
        mark_covered(covered, i, close + marker_len)
        i = close + marker_len
      else
        i = i + marker_len
      end
    else
      i = i + 1
    end
  end
end

function parser.parse_inline(line, line_no, base_col)
  local spans = {}
  local covered = {}
  line_no = line_no or 1
  base_col = base_col or 1
  local col_offset = base_col - 1

  collect_escaped_ranges(line, covered)
  parse_code_spans(line, line_no, spans, covered, col_offset)

  for _, link in ipairs(links.find_links(line, line_no)) do
    if not range_is_covered(covered, link.source_col1, link.source_col2) then
      local adjusted_link = {}
      for key, value in pairs(link) do adjusted_link[key] = value end
      adjusted_link.source_col1 = link.source_col1 + col_offset
      adjusted_link.source_col2 = link.source_col2 + col_offset

      local span_type = link.kind
      if span_type == "markdown" then span_type = "link" end
      add_span(spans, {
        type = span_type,
        line = line_no,
        col1 = adjusted_link.source_col1,
        col2 = adjusted_link.source_col2,
        link = adjusted_link,
        text = link.display,
        marker_ranges = { range(line_no, adjusted_link.source_col1, adjusted_link.source_col2) },
        content_ranges = { range(line_no, adjusted_link.source_col1, adjusted_link.source_col2) },
      })
      mark_covered(covered, link.source_col1, link.source_col2)
    end
  end

  parse_delimited(line, line_no, spans, covered, "***", "strong_emphasis", col_offset)
  parse_delimited(line, line_no, spans, covered, "___", "strong_emphasis", col_offset)
  parse_delimited(line, line_no, spans, covered, "**", "strong", col_offset)
  parse_delimited(line, line_no, spans, covered, "__", "strong", col_offset)
  parse_delimited(line, line_no, spans, covered, "~~", "strikethrough", col_offset)
  parse_delimited(line, line_no, spans, covered, "*", "emphasis", col_offset)
  parse_delimited(line, line_no, spans, covered, "_", "emphasis", col_offset)

  table.sort(spans, function(a, b)
    if a.line == b.line then return a.col1 < b.col1 end
    return a.line < b.line
  end)
  return spans
end

local function parse_atx_heading(line, line_no)
  local indent, marks, after = line:match("^(%s*)(#+)(%s+.*)$")
  if not marks or #marks > 6 then return nil end

  local marker_col1 = #indent + 1
  local content_col1 = marker_col1 + #marks
  while line:sub(content_col1, content_col1):match("%s") do
    content_col1 = content_col1 + 1
  end

  local content_col2 = #line + 1
  local before_closing = line:match("^(.-)%s+#+%s*$")
  if before_closing and #before_closing >= content_col1 then
    content_col2 = #before_closing + 1
  else
    while content_col2 > content_col1 and line:sub(content_col2 - 1, content_col2 - 1):match("%s") do
      content_col2 = content_col2 - 1
    end
  end

  return {
    type = "heading",
    line1 = line_no,
    line2 = line_no,
    col1 = marker_col1,
    col2 = #line + 1,
    level = #marks,
    marker_col1 = marker_col1,
    marker_col2 = marker_col1 + #marks,
    content_col1 = content_col1,
    content_col2 = content_col2,
    text = line:sub(content_col1, content_col2 - 1),
    inline = parser.parse_inline(line:sub(content_col1, content_col2 - 1), line_no, content_col1),
  }
end

local function is_fence(line)
  return line:match("^%s*```") or line:match("^%s*~~~")
end

local function parse_fenced_code(lines, start_line)
  local line = lines[start_line]
  local indent, marker, info = line:match("^(%s*)([`~][`~][`~]+)%s*(.-)%s*$")
  if not marker then return nil end
  local fence_char = marker:sub(1, 1)
  local fence_len = #marker
  local i = start_line + 1
  while i <= #lines do
    local close = lines[i]:match("^%s*(" .. fence_char:rep(fence_len) .. fence_char .. "*)%s*$")
    if close then break end
    i = i + 1
  end
  return {
    type = "code",
    line1 = start_line,
    line2 = math.min(i, #lines),
    col1 = #indent + 1,
    col2 = #(lines[math.min(i, #lines)] or "") + 1,
    info = trim(info),
  }, math.min(i + 1, #lines + 1)
end

function parser.parse_blocks_from_lines(lines)
  local blocks = {}
  local i = 1
  while i <= #lines do
    local line = lines[i]
    if is_blank(line) then
      i = i + 1
    else
      local fence_block, next_i = parse_fenced_code(lines, i)
      if fence_block then
        blocks[#blocks + 1] = fence_block
        i = next_i
      else
        local heading = parse_atx_heading(line, i)
        if heading then
          blocks[#blocks + 1] = heading
          i = i + 1
        else
          local start_i = i
          local text_lines = {}
          while i <= #lines and not is_blank(lines[i]) and not parse_atx_heading(lines[i], i) and not is_fence(lines[i]) do
            text_lines[#text_lines + 1] = lines[i]
            i = i + 1
          end
          local inline = {}
          local block_links = {}
          for offset, text_line in ipairs(text_lines) do
            local line_no = start_i + offset - 1
            for _, span in ipairs(parser.parse_inline(text_line, line_no)) do
              inline[#inline + 1] = span
              if span.link then block_links[#block_links + 1] = span.link end
            end
          end
          blocks[#blocks + 1] = {
            type = "paragraph",
            line1 = start_i,
            line2 = i - 1,
            col1 = 1,
            col2 = #(lines[i - 1] or "") + 1,
            lines = text_lines,
            text = table.concat(text_lines, "\n"),
            inline = inline,
            links = block_links,
          }
        end
      end
    end
  end
  return blocks
end

function parser.parse(text)
  local lines = parser.split_lines(text)
  local blocks = parser.parse_blocks_from_lines(lines)
  local all_links = {}
  for _, block in ipairs(blocks) do
    if block.type == "heading" then
      local source = lines[block.line1] or ""
      for _, link in ipairs(links.find_links(source, block.line1)) do
        all_links[#all_links + 1] = link
      end
    elseif block.links then
      for _, link in ipairs(block.links) do all_links[#all_links + 1] = link end
    end
  end
  return {
    lines = lines,
    blocks = blocks,
    links = all_links,
  }
end

return parser
