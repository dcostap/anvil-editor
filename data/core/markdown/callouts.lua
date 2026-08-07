local callouts = {}

local canonical_types = {
  note = "note",
  abstract = "abstract", summary = "abstract", tldr = "abstract",
  info = "info", todo = "todo",
  tip = "tip", hint = "tip", important = "tip",
  success = "success", check = "success", done = "success",
  question = "question", help = "question", faq = "question",
  warning = "warning", caution = "warning", attention = "warning",
  failure = "failure", fail = "failure", missing = "failure",
  danger = "danger", error = "danger",
  bug = "bug", example = "example",
  quote = "quote", cite = "quote",
}

local icons = {
  note = "✎", abstract = "≡", info = "i", todo = "☑",
  tip = "✦", success = "✓", question = "?", warning = "!",
  failure = "×", danger = "⚡", bug = "●", example = "◆", quote = "❝",
}

local function quote_prefix_ranges(text)
  local ranges, col = {}, 1
  while col <= #text do
    local _, rel2 = text:sub(col):find("^[ \t]*>[ \t]?")
    if not rel2 then break end
    local col2 = col + rel2
    ranges[#ranges + 1] = { col1 = col, col2 = col2 }
    col = col2
  end
  return ranges
end

function callouts.palette(style, canonical_type)
  local palette = style.markdown_live_callout_palette
  return palette and (palette[canonical_type] or palette.note) or nil
end

function callouts.parse_header(text, source_col1)
  source_col1 = source_col1 or 1
  local segment = text:sub(source_col1)
  local _, quote_end = segment:find("^[ \t]*>[ \t]*")
  if not quote_end then return nil end
  local marker_segment = segment:sub(quote_end + 1)
  local marker_start, marker_end, kind = marker_segment:find("^%[!([%w_-]+)%]")
  if not marker_start then return nil end
  local marker_col1 = source_col1 + quote_end
  local marker_col2 = marker_col1 + marker_end
  local after_marker = marker_segment:sub(marker_end + 1)
  local fold = after_marker:match("^([+-])")
  local fold_col1 = fold and marker_col2 or nil
  local after_fold = fold and after_marker:sub(2) or after_marker
  local spacing = after_fold:match("^[ \t]*") or ""
  local title_col1 = marker_col2 + (fold and 1 or 0) + #spacing
  local normalized_type = kind:lower()
  local canonical_type = canonical_types[normalized_type] or "note"
  local prefixes = quote_prefix_ranges(text)
  local nesting_depth = 1
  for index, prefix in ipairs(prefixes) do
    if source_col1 >= prefix.col1 and source_col1 < prefix.col2 then
      nesting_depth = index
      break
    end
  end
  local line_end = #text + 1
  return {
    col1 = source_col1,
    col2 = title_col1,
    type = normalized_type,
    canonical_type = canonical_type,
    known_type = canonical_types[normalized_type] ~= nil,
    fold = fold,
    fold_range = fold and {
      line1 = 0, col1 = fold_col1, line2 = 0, col2 = fold_col1 + 1,
    } or nil,
    marker_range = {
      line1 = 0, col1 = marker_col1, line2 = 0, col2 = marker_col2,
    },
    title = text:sub(title_col1),
    title_range = {
      line1 = 0, col1 = title_col1, line2 = 0, col2 = line_end,
    },
    display_type = normalized_type:gsub("[_-]+", " "):gsub("^%l", string.upper),
    spacing = spacing,
    nesting_depth = nesting_depth,
    icon = icons[canonical_type] or icons.note,
  }
end

function callouts.line_ranges(text, nesting_depth, line)
  local prefixes = quote_prefix_ranges(text)
  if #prefixes < nesting_depth then return nil end
  local prefix_ranges = {}
  for index = 1, nesting_depth do prefix_ranges[index] = prefixes[index] end
  local content_col1 = prefix_ranges[#prefix_ranges].col2
  return {
    quote_prefix_ranges = prefix_ranges,
    quote_prefix_range = {
      line1 = line, col1 = prefix_ranges[1].col1,
      line2 = line, col2 = content_col1,
    },
    content_range = {
      line1 = line, col1 = content_col1,
      line2 = line, col2 = #text + 1,
    },
  }
end

return callouts
