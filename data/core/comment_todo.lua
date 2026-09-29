local tokenizer = require "core.tokenizer"

local comment_todo = {}

local function is_comment(type_name)
  return type_name == "comment" or type_name == "doc_comment"
    or type_name == "doccomment" or type_name:match("^comment%.") ~= nil
end

local function add_token(tokens, type_name, text)
  if text == "" then return end
  local n = #tokens
  if n > 0 and tokens[n - 1] == type_name then
    tokens[n] = tokens[n] .. text
  else
    tokens[n + 1], tokens[n + 2] = type_name, text
  end
end

local function line_info(highlighter, idx, raw_tokens)
  local text = highlighter.buffer:get_utf8_line(idx)
  if not text then return nil end
  local first, last = text:find("%S")
  if not first then return { comment = false } end
  last = text:match(".*()%S")
  local pos, first_comment, last_comment = 1
  local comment_text = {}
  local has_comment = false
  for _, type_name, part in tokenizer.each_token(raw_tokens) do
    local finish = pos + #part - 1
    if is_comment(type_name) then
      has_comment = true
      first_comment = first_comment or pos
      last_comment = finish
      comment_text[#comment_text + 1] = part
    end
    pos = finish + 1
  end
  if not has_comment then return { comment = false } end
  return {
    comment = true,
    todo = table.concat(comment_text):lower():find("%f[%w]todo%f[%W]") ~= nil,
    leading = first_comment <= first,
    trailing = last_comment >= last,
    -- A line comment after code does not join the comment on the next line.
    block_start = text:sub(first_comment):match("^/%*") ~= nil
      or text:sub(first_comment):match("^%-%-%[%[") ~= nil,
  }
end

-- Consecutive comment-only lines form one visual run. An inline block opener
-- also joins its following lines, but an inline // comment does not.
local function joins(previous, next_line)
  return previous and next_line and previous.comment and next_line.comment
    and previous.trailing and next_line.leading
    and (previous.leading or previous.block_start)
end

function comment_todo.apply(highlighter, idx, tokens, raw_tokens_at)
  local cache = highlighter.todo_comment_cache
  if not cache then
    cache = { groups = {}, info = {} }
    highlighter.todo_comment_cache = cache
  end
  local function info(line)
    if line < 1 or line > #highlighter.buffer.lines then return nil end
    if not cache.info[line] then
      cache.info[line] = line_info(highlighter, line, raw_tokens_at(line))
    end
    return cache.info[line]
  end

  local group = cache.groups[idx]
  if not group then
    local current = info(idx)
    if not current or not current.comment then return tokens end
    local first, last = idx, idx
    while joins(info(first - 1), info(first)) do first = first - 1 end
    while joins(info(last), info(last + 1)) do last = last + 1 end
    group = { first = first, last = last, todo = false }
    for line = first, last do
      group.todo = group.todo or info(line).todo
      cache.groups[line] = group
    end
  end
  if not group.todo then return tokens end

  local colored = {}
  for _, type_name, part in tokenizer.each_token(tokens) do
    add_token(colored, is_comment(type_name) and "warning" or type_name, part)
  end
  return colored
end

-- Invalidate rendered neighbors when an edit changes their shared comment run.
function comment_todo.invalidate(highlighter, first, last, invalidate_packets)
  local cache = highlighter.todo_comment_cache
  highlighter.todo_comment_cache = nil
  if not cache or not first then return end
  local seen = {}
  for line = math.max(1, first - 1), math.min(#highlighter.buffer.lines, (last or first) + 1) do
    local group = cache.groups[line]
    if group and not seen[group] then
      seen[group] = true
      invalidate_packets(group.first, group.last - group.first)
    end
  end
end

return comment_todo
