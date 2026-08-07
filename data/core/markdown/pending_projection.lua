local projection = {}
local parser = require "core.markdown.parser"

local HTML_BLOCK_TAGS = {
  address = true, article = true, aside = true, base = true, basefont = true,
  blockquote = true, body = true, caption = true, center = true, col = true,
  colgroup = true, dd = true, details = true, dialog = true, dir = true,
  div = true, dl = true, dt = true, fieldset = true, figcaption = true,
  figure = true, footer = true, form = true, frame = true, frameset = true,
  h1 = true, h2 = true, h3 = true, h4 = true, h5 = true, h6 = true,
  head = true, header = true, hr = true, html = true, iframe = true,
  legend = true, li = true, link = true, main = true, menu = true,
  menuitem = true, nav = true, noframes = true, ol = true, optgroup = true,
  option = true, p = true, param = true, search = true, section = true,
  summary = true, table = true, tbody = true, td = true, tfoot = true,
  th = true, thead = true, title = true, tr = true, track = true, ul = true,
}

local function html_block_mode(text)
  local first = 1
  while first <= 4 do
    local byte = text:byte(first)
    if byte ~= 32 and byte ~= 9 then break end
    first = first + 1
  end
  if first > 4 or text:byte(first) ~= 60 then return nil end
  local lower = text:lower()
  if lower:match("^%s*<!%-%-") then return "-->" end
  if lower:match("^%s*<%?") then return "?>" end
  if lower:match("^%s*<!%[cdata%[") then return "]]>" end
  for _, tag in ipairs({ "script", "pre", "style", "textarea" }) do
    if lower:match("^%s*<" .. tag .. "[%s>]") then return "</" .. tag .. ">" end
  end
  local tag = lower:match("^%s*</?([%a][%w-]*)[%s>/]")
  if tag and HTML_BLOCK_TAGS[tag] then return "blank" end
end

local function fence_marker(line)
  local indent, ticks = line:match("^(%s*)(`+)")
  if ticks and #indent <= 3 and #ticks >= 3 then return "`", #ticks end
  local tildes
  indent, tildes = line:match("^(%s*)(~+)")
  if tildes and #indent <= 3 and #tildes >= 3 then return "~", #tildes end
end

local function closes_fence(line, marker, count)
  local indent, run, rest = line:match(
    "^(%s*)(" .. (marker == "`" and "`+" or "~+") .. ")(%s*)$"
  )
  return run and #indent <= 3 and #run >= count and rest ~= nil
end

local function marker_is_escaped(text, col)
  local slashes = 0
  for index = col - 1, 1, -1 do
    if text:sub(index, index) ~= "\\" then break end
    slashes = slashes + 1
  end
  return slashes % 2 == 1
end

local function inline_context_marker_signature(text)
  local parts = {}
  local col = 1
  while col <= #text do
    local marker = text:sub(col, col)
    if marker == "%" or marker == "`" or marker == "$" then
      local col2 = col + 1
      while text:sub(col2, col2) == marker do col2 = col2 + 1 end
      parts[#parts + 1] = table.concat({
        marker,
        tostring(col2 - col),
        marker_is_escaped(text, col) and "escaped" or "active",
      }, ":")
      col = col2
    else
      col = col + 1
    end
  end
  return table.concat(parts, "|")
end

function projection.raw_context_signature(text)
  text = tostring(text or ""):gsub("\n$", "")
  local indent, run, rest = text:match("^(%s*)(`+)(.*)$")
  local marker = "`"
  if not run or #run < 3 or #indent > 3 then
    indent, run, rest = text:match("^(%s*)(~+)(.*)$")
    marker = "~"
  end
  local fence = "none"
  if run and #run >= 3 and #indent <= 3 then
    fence = table.concat({
      marker,
      tostring(#run),
      rest:match("^%s*$") and "bare" or "info",
    }, ":")
  end
  return fence .. "\0" .. inline_context_marker_signature(text)
end

function projection.source_topology(lines, line_limit)
  local line_count = math.min(#(lines or {}), line_limit or #(lines or {}))
  local fenced = {}
  local whole_comment_lines = {}
  local math_lines = {}
  local frontmatter_lines = {}
  local html_lines = {}
  local fence_delimiters = {}
  local first = ((lines or {})[1] or ""):gsub("\n$", "")
  local frontmatter_delimiter = first:match("^%s*([%-%+][%-%+][%-%+])%s*$")
  if frontmatter_delimiter == "---" or frontmatter_delimiter == "+++" then
    local frontmatter_close_pattern = frontmatter_delimiter == "+++"
      and "^%s*%+%+%+%s*$" or "^%s*%-%-%-%s*$"
    frontmatter_lines[1] = true
    for line = 2, line_count do
      frontmatter_lines[line] = true
      local text = (lines[line] or ""):gsub("\n$", "")
      local closes_frontmatter = text:match(frontmatter_close_pattern) ~= nil
      if frontmatter_delimiter == "---" then
        closes_frontmatter = closes_frontmatter
          or text:match("^%s*%.%.%.%s*$") ~= nil
      end
      if closes_frontmatter then
        break
      end
    end
  end
  local fence, fence_count
  local comment_open = false
  local math_open = false
  local html_mode

  local function scan_comments(line, text)
    local started_open = comment_open
    local first, last
    local code_ranges = {}
    if text:find("%%", 1, true) and text:find("`", 1, true) then
      local tick = 1
      while tick <= #text do
        local open = text:find("`", tick, true)
        if not open then break end
        local count = 1
        while text:sub(open + count, open + count) == "`" do count = count + 1 end
        if marker_is_escaped(text, open) then
          tick = open + count
        else
          local run = string.rep("`", count)
          local close = text:find(run, open + count, true)
          while close and (text:sub(close - 1, close - 1) == "`"
            or text:sub(close + count, close + count) == "`")
          do
            close = text:find(run, close + count, true)
          end
          if close then
            code_ranges[#code_ranges + 1] = { col1 = open, col2 = close + count }
            tick = close + count
          else
            tick = open + count
          end
        end
      end
    end
    local function inside_code(col)
      for _, range in ipairs(code_ranges) do
        if col >= range.col1 and col < range.col2 then return true end
      end
      return false
    end
    local col = 1
    while true do
      local comment_marker = text:find("%%", col, true)
      if not comment_marker then break end
      if not marker_is_escaped(text, comment_marker)
        and not inside_code(comment_marker)
      then
        first = first or comment_marker
        last = comment_marker + 2
        comment_open = not comment_open
      end
      col = comment_marker + 2
    end
    if started_open and (comment_open or (first == 1 and last == #text + 1)) then
      whole_comment_lines[line] = true
    elseif started_open and not first then
      whole_comment_lines[line] = true
    elseif not started_open and comment_open and first == 1 then
      whole_comment_lines[line] = true
    end
  end

  for line = 1, line_count do
    local source = lines[line] or ""
    local text = source:gsub("\n$", "")
    local first_byte = text:byte(1)
    local math_delimiter = (first_byte == 36 or first_byte == 32 or first_byte == 9)
      and text:match("^%s*%$%$%s*$") ~= nil
    if frontmatter_lines[line] then
      -- YAML frontmatter owns its contents before Markdown block constructs.
    elseif fence then
      fenced[line] = true
      if closes_fence(text, fence, fence_count) then
        fence_delimiters[line] = "close"
        fence, fence_count = nil, nil
      end
    elseif comment_open then
      scan_comments(line, text)
    elseif math_open then
      math_lines[line] = true
      if math_delimiter then math_open = false end
    elseif html_mode then
      if html_mode == "blank" and text:match("^%s*$") then
        html_mode = nil
      else
        html_lines[line] = true
        if html_mode ~= "blank" and text:lower():find(html_mode, 1, true) then
          html_mode = nil
        end
      end
    else
      fence, fence_count = fence_marker(text)
      if fence then
        fenced[line] = true
        fence_delimiters[line] = "open"
      elseif math_delimiter then
        math_lines[line] = true
        math_open = true
      else
        html_mode = (first_byte == 60 or first_byte == 32 or first_byte == 9)
          and html_block_mode(text) or nil
        if html_mode then
          html_lines[line] = true
          if html_mode ~= "blank" and text:lower():find(html_mode, 1, true) then
            html_mode = nil
          end
        else
          scan_comments(line, text)
        end
      end
    end
  end
  return fenced, whole_comment_lines, math_lines, frontmatter_lines, html_lines,
    fence_delimiters
end

function projection.list_signature(text)
  text = tostring(text or ""):gsub("\n$", "")
  local indent, bullet = text:match("^([\t ]*)([-%*%+])[\t ]+%[[ xX]%]")
  if indent then return "task:" .. tostring(#indent) .. ":" .. bullet end
  indent, bullet = text:match("^([\t ]*)([-%*%+])[\t ]+")
  if indent then return "unordered:" .. tostring(#indent) .. ":" .. bullet end
  local number, delimiter
  indent, number, delimiter = text:match("^([\t ]*)(%d+)([.)])[\t ]+")
  if indent then return "ordered:" .. tostring(#indent) .. ":" .. delimiter end
  return ""
end

function projection.edit_changes_list_structure(edit)
  return edit and projection.list_signature(edit.old_text)
    ~= projection.list_signature(edit.text)
end

function projection.block_signature(text)
  -- Nested lists can use tab indentation. Recognize their marker before the
  -- generic indented-block branch so indentation does not look like a change
  -- from list presentation to code/prose presentation.
  if projection.list_signature(text) ~= "" then return "list" end
  local indent, body = text:match("^([ ]*)(.*)$")
  if not body or #indent > 3 then return "indented" end
  if body:match("^```+") or body:match("^~~~+") then return "fence" end
  if html_block_mode(text) then return "html" end
  if body:match("^>") then return "quote" end
  if body:match("^#{1,6}%s") then return "heading" end
  local setext = body:gsub("%s", "")
  if setext:match("^=+$") or setext:match("^%-+$") then
    return "setext-or-rule:" .. math.min(#setext, 3)
  end
  if body:match("^%*%s*%*%s*%*[%s*]*$")
    or body:match("^_%s*_%s*_[%s_]*$")
    or body:match("^%-%s*%-%s*%-[%s%-]*$")
  then
    return "rule"
  end
  if body:match("^%[[^%]]+%]:") then return "reference" end
  if body == "---" or body == "+++" then return "frontmatter-or-rule" end
  return "prose"
end

function projection.ordered_changed_ranges(transaction)
  local ranges = {}
  for _, range in ipairs(transaction and transaction.changed_ranges or {}) do
    ranges[#ranges + 1] = range
  end
  table.sort(ranges, function(left, right)
    return (left.old_line1 or left.new_line1 or 1)
      < (right.old_line1 or right.new_line1 or 1)
  end)
  return ranges
end

function projection.transaction_changes_list_structure(doc, transaction, pre_edit_lines)
  for _, range in ipairs(transaction and transaction.changed_ranges or {}) do
    local old_line = range.old_line1 or range.new_line1 or 1
    local new_line = range.new_line1 or old_line
    local previous = pre_edit_lines and pre_edit_lines[old_line]
    if projection.list_signature(previous and previous.source_text or "")
      ~= projection.list_signature(doc.lines[new_line] or "")
    then
      return true
    end
  end
  return false
end

function projection.transaction_changes_block_context(doc, transaction, pre_edit_lines)
  local changed = false
  local global = false
  for _, range in ipairs(projection.ordered_changed_ranges(transaction)) do
    local old_line = range.old_line1 or range.new_line1 or 1
    local new_line = range.new_line1 or old_line
    local previous = pre_edit_lines and pre_edit_lines[old_line]
    local old_text = previous and previous.source_text or ""
    local new_text = (doc.lines[new_line] or ""):gsub("\n$", "")
    local old_signature = projection.block_signature(old_text)
    local new_signature = projection.block_signature(new_text)
    if (old_signature == "reference" or new_signature == "reference")
      and old_text ~= new_text
    then
      global = true
    end
    if previous and (previous.comment or previous.math or previous.frontmatter) then
      changed = true
    end
    if old_signature ~= new_signature then
      changed = true
    end
  end
  return changed or global, global
end

local function link_target_signature(text)
  text = tostring(text or ""):gsub("\n$", "")
  -- A list marker such as "- " also matches the permissive Setext
  -- underline shape below, but it is not a link target owned by the
  -- following block. Do not widen pending presentation for ordinary list
  -- edits as though a reference/heading target changed.
  if projection.list_signature(text) ~= "" then return "" end
  local body = text:match("^%s*#{1,6}%s+(.+)$")
  if body then return "heading:" .. body end
  local setext = text:match("^%s*([=%-]+)%s*$")
  if setext then return "setext:" .. setext:sub(1, 1) end
  local block = text:match("%^([%w_-]+)%s*$")
  if block then return "block:" .. block end
  local label, target = text:match("^%s*%[([^%]]+)%]:%s*(.-)%s*$")
  if label then return "reference:" .. label:lower() .. ":" .. target end
  return ""
end

function projection.transaction_changes_link_targets(doc, transaction, pre_edit_lines)
  for _, range in ipairs(projection.ordered_changed_ranges(transaction)) do
    local old_line1 = range.old_line1 or range.new_line1 or 1
    local old_line2 = range.old_line2 or old_line1
    local new_line1 = range.new_line1 or old_line1
    local new_line2 = range.new_line2 or new_line1
    for line = old_line1, old_line2 do
      local previous = pre_edit_lines and pre_edit_lines[line]
      if previous and link_target_signature(previous.source_text) ~= "" then return true end
    end
    for line = new_line1, new_line2 do
      if link_target_signature(doc.lines[line]) ~= "" then return true end
    end
  end
  return false
end

function projection.transaction_changes_frontmatter(doc, transaction, pre_edit_lines)
  local function delimiter(text)
    text = tostring(text or ""):gsub("\n$", "")
    return text:match("^%s*%-%-%-%s*$") ~= nil
      or text:match("^%s*%+%+%+%s*$") ~= nil
      or text:match("^%s*%.%.%.%s*$") ~= nil
  end
  for _, range in ipairs(projection.ordered_changed_ranges(transaction)) do
    local old_line = range.old_line1 or range.new_line1 or 1
    local new_line = range.new_line1 or old_line
    local previous = pre_edit_lines and pre_edit_lines[old_line]
    if delimiter(previous and previous.source_text) ~= delimiter(doc.lines[new_line]) then
      return true
    end
  end
  return false
end

function projection.transaction_changes_html(doc, transaction, pre_edit_lines)
  for _, range in ipairs(projection.ordered_changed_ranges(transaction)) do
    local old_line = range.old_line1 or range.new_line1 or 1
    local new_line = range.new_line1 or old_line
    local previous = pre_edit_lines and pre_edit_lines[old_line]
    local old_mode = html_block_mode(previous and previous.source_text or "")
    local new_mode = html_block_mode((doc.lines[new_line] or ""):gsub("\n$", ""))
    if old_mode ~= new_mode then return true end
  end
  return false
end

function projection.transaction_changes_raw_context(doc, transaction, pre_edit_lines)
  if transaction and transaction.type == "load" then return true end
  local ranges = projection.ordered_changed_ranges(transaction)
  if #ranges == 0 then return false end
  local function signatures(line1, line2, source)
    local values = {}
    for line = line1, line2 do
      local text = source(line)
      if text == nil then return nil end
      local signature = projection.raw_context_signature(text)
      -- Ordinary shifted lines all have the same empty signature. Omitting
      -- them lets a newline insertion compare the actual delimiter topology
      -- rather than unrelated lines that merely moved to a new number.
      if signature ~= "none\0" then values[#values + 1] = signature end
    end
    return table.concat(values, "\1")
  end
  for _, range in ipairs(ranges) do
    local old_line1 = range.old_line1 or range.new_line1 or 1
    local old_line2 = range.old_line2 or old_line1
    local new_line1 = range.new_line1 or old_line1
    local new_line2 = range.new_line2 or new_line1
    local old = signatures(old_line1, old_line2, function(line)
      local previous = pre_edit_lines and pre_edit_lines[line]
      return previous and previous.source_text
    end)
    local new = signatures(new_line1, new_line2, function(line)
      return (doc.lines[line] or ""):gsub("\n$", "")
    end)
    if old == nil or old ~= new then return true end
  end
  return false
end

function projection.map_unchanged_line(ranges, old_line)
  local delta = 0
  for _, range in ipairs(ranges) do
    local old_line1 = range.old_line1 or range.new_line1 or 1
    local old_line2 = range.old_line2 or old_line1
    if old_line < old_line1 then return old_line + delta end
    if old_line <= old_line2 then return nil end
    delta = delta + (range.line_delta or 0)
  end
  return old_line + delta
end

function projection.inline_spans(text, line, base_col)
  base_col = base_col or 1
  local spans = parser.parse_inline(text, line, base_col)
  local offset = base_col - 1
  local covered = {}
  for _, span in ipairs(spans) do
    covered[#covered + 1] = {
      col1 = span.col1 - offset,
      col2 = span.col2 - offset,
    }
  end
  local function overlaps(col1, col2)
    for _, range in ipairs(covered) do
      if col1 < range.col2 and col2 > range.col1 then return true end
    end
    return false
  end
  local function parse_pair(marker, kind, hidden)
    local col = 1
    while col <= #text do
      local open = text:find(marker, col, true)
      if not open then break end
      if marker_is_escaped(text, open) or overlaps(open, open + #marker) then
        col = open + #marker
      else
        local close = text:find(marker, open + #marker, true)
        while close and (marker_is_escaped(text, close)
          or overlaps(close, close + #marker))
        do
          close = text:find(marker, close + #marker, true)
        end
        if not close or close == open + #marker then
          col = open + #marker
        else
          local col2 = close + #marker
          spans[#spans + 1] = {
            type = kind,
            line = line,
            col1 = open + offset,
            col2 = col2 + offset,
            text = hidden and "" or text:sub(open + #marker, close - 1),
            marker_ranges = {
              { line1 = line, col1 = open + offset, line2 = line, col2 = open + #marker + offset },
              { line1 = line, col1 = close + offset, line2 = line, col2 = col2 + offset },
            },
            content_ranges = {
              {
                line1 = line,
                col1 = open + #marker + offset,
                line2 = line,
                col2 = close + offset,
              },
            },
          }
          covered[#covered + 1] = { col1 = open, col2 = col2 }
          col = col2
        end
      end
    end
  end
  parse_pair("%%", "comment", true)
  parse_pair("==", "highlight", false)
  table.sort(spans, function(left, right) return left.col1 < right.col1 end)
  return spans
end

return projection
