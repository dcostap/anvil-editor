-- mod-version:3
local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local core_syntax = require "core.syntax"
local TextView = require "core.textview"
local Editor = require "core.editor"
local Buffer = require "core.buffer"

local detectindent = {}
local cache = setmetatable({}, { __mode = "k" })
local comments_cache = {}
local auto_detect_max_lines = 150


local function indent_occurrences_more_than_once(stat, idx)
  if stat[idx-1] and stat[idx-1] == stat[idx] then
    return true
  elseif stat[idx+1] and stat[idx+1] == stat[idx] then
    return true
  end
  return false
end


local function optimal_indent_from_stat(stat)
  if #stat == 0 then return nil, 0 end
  table.sort(stat, function(a, b) return a > b end)
  local best_indent = 0
  local best_score = 0
  local count = #stat
  for x=1, count do
    local indent = stat[x]
    local score = 0
    for y=1, count do
      if y ~= x and stat[y] % indent == 0 then
        score = score + 1
      elseif
        indent > stat[y]
        and
        (
          indent_occurrences_more_than_once(stat, y)
          or
          (y == count and stat[y] > 1)
        )
      then
        score = 0
        break
      end
    end
    if score > best_score then
      best_indent = indent
      best_score = score
    end
    if score > 0 then
      break
    end
  end
  return best_score > 0 and best_indent or nil, best_score
end


local function escape_comment_tokens(token)
  local special_chars = "*-%[].()+?^$"
  local escaped = ""
  for x=1, token:len() do
    local found = false
    for y=1, special_chars:len() do
      if token:sub(x, x) == special_chars:sub(y, y) then
        escaped = escaped .. "%" .. token:sub(x, x)
        found = true
        break
      end
    end
    if not found then
      escaped = escaped .. token:sub(x, x)
    end
  end
  return escaped
end


local function get_comment_patterns(syntax, _loop)
  _loop = _loop or 1
  if _loop > 5 then return end
  if comments_cache[syntax] then
    if #comments_cache[syntax] > 0 then
      return comments_cache[syntax]
    else
      return nil
    end
  end
  local comments = {}
  for idx=1, #syntax.patterns do
    local pattern = syntax.patterns[idx]
    local startp = ""
    if
      type(pattern.type) == "string"
      and
      (pattern.type == "comment" or pattern.type == "string")
    then
      local not_is_string = pattern.type ~= "string"
      if pattern.pattern then
        startp = type(pattern.pattern) == "table"
          and pattern.pattern[1] or pattern.pattern
        if not_is_string and startp:sub(1, 1) ~= "^" then
          startp = "^%s*" .. startp
        elseif not_is_string then
          startp = "^%s*" .. startp:sub(2, startp:len())
        end
        if type(pattern.pattern) == "table" then
          table.insert(comments, {"p", startp, pattern.pattern[2]})
        elseif not_is_string then
          table.insert(comments, {"p", startp})
        end
      elseif pattern.regex then
        startp = type(pattern.regex) == "table"
          and pattern.regex[1] or pattern.regex
        if not_is_string and startp:sub(1, 1) ~= "^" then
          startp = "^\\s*" .. startp
        elseif not_is_string then
          startp = "^\\s*" .. startp:sub(2, startp:len())
        end
        if type(pattern.regex) == "table" then
          table.insert(comments, {
            "r", regex.compile(startp), regex.compile(pattern.regex[2]), r=startp
          })
        elseif not_is_string then
          table.insert(comments, {"r", regex.compile(startp), r=startp})
        end
      end
    elseif pattern.syntax then
      local subsyntax = type(pattern.syntax) == 'table' and pattern.syntax
        or core_syntax.get("file"..pattern.syntax, "")
      local sub_comments = get_comment_patterns(subsyntax, _loop + 1)
      if sub_comments then
        for s=1, #sub_comments do
          table.insert(comments, sub_comments[s])
        end
      end
    end
  end
  if #comments == 0 then
    local single_line_comment = syntax.comment
      and escape_comment_tokens(syntax.comment) or nil
    local block_comment = nil
    if syntax.block_comment then
      block_comment = {
        escape_comment_tokens(syntax.block_comment[1]),
        escape_comment_tokens(syntax.block_comment[2])
      }
    end
    if single_line_comment then
      table.insert(comments, {"p", "^%s*" .. single_line_comment})
    end
    if block_comment then
      table.insert(comments, {"p", "^%s*" .. block_comment[1], block_comment[2]})
    end
  end
  -- Put comments first and strings last
  table.sort(comments, function(c1, c2)
    local comment1, comment2 = false, false
    if
      (c1[1] == "p" and string.find(c1[2], "^%s*", 1, true))
      or
      (c1[1] == "r" and string.find(c1["r"], "^\\s*", 1, true))
    then
      comment1 = true
    end
    if
      (c2[1] == "p" and string.find(c2[2], "^%s*", 1, true))
      or
      (c2[1] == "r" and string.find(c2["r"], "^\\s*", 1, true))
    then
      comment2 = true
    end
    return comment1 and not comment2
  end)
  comments_cache[syntax] = comments
  if #comments > 0 then
    return comments
  end
  return nil
end

local function is_markdown_syntax(syntax)
  local name = syntax and syntax.name
  return type(name) == "string"
    and name:lower():find("markdown", 1, true) ~= nil
end

local function line_body(line)
  return tostring(line or ""):gsub("[\r\n]+$", "")
end

local function markdown_fence_opener(line)
  local body = line_body(line)
  local indent, marker, info = body:match("^( *)(`+)(.*)$")
  if not marker then indent, marker, info = body:match("^( *)(~+)(.*)$") end
  if not marker or #indent > 3 or #marker < 3 then return nil end
  if marker:sub(1, 1) == "`" and info:find("`", 1, true) then return nil end
  return { marker = marker:sub(1, 1), length = #marker }
end

local function markdown_fence_closer(line, fence)
  local body = line_body(line)
  local indent, marker = body:match(
    "^( *)(" .. fence.marker:rep(fence.length) .. fence.marker .. "*)[ \t]*$"
  )
  return marker ~= nil and #indent <= 3
end

local function markdown_html_comment_start(line)
  local indent, body = line_body(line):match("^( *)(.*)$")
  if #indent > 3 or body:sub(1, 4) ~= "<!--" then return nil end
  return #indent + 1
end

local function get_markdown_non_empty_lines(lines)
  return coroutine.wrap(function()
    local i = 0
    local fence
    local in_html_comment = false
    for _, line in ipairs(lines) do
      local excluded = false
      if fence then
        excluded = true
        if markdown_fence_closer(line, fence) then fence = nil end
      elseif in_html_comment then
        excluded = true
        if line:find("-->", 1, true) then in_html_comment = false end
      else
        fence = markdown_fence_opener(line)
        if fence then
          excluded = true
        else
          local comment_start = markdown_html_comment_start(line)
          if comment_start then
            excluded = true
            if not line:find("-->", comment_start + 4, true) then
              in_html_comment = true
            end
          end
        end
      end
      if not excluded and line:gsub("^%s+", "") ~= "" then
        i = i + 1
        coroutine.yield(i, line)
      end
    end
  end)
end


local function get_non_empty_lines(syntax, lines)
  if is_markdown_syntax(syntax) then
    return get_markdown_non_empty_lines(lines)
  end
  return coroutine.wrap(function()
    local comments = get_comment_patterns(syntax)

    local i = 0
    local end_regex = nil
    local end_pattern = nil
    local inside_comment = false
    for _, line in ipairs(lines) do
      if line:gsub("^%s+", "") ~= "" then
        local is_comment = false
        if comments then
          if not inside_comment then
            for c=1, #comments do
              local comment = comments[c]
              if comment[1] == "p" then
                if comment[3] then
                  local start, ending = line:find(comment[2])
                  if start then
                    if not line:find(comment[3], ending+1) then
                      is_comment = true
                      inside_comment = true
                      end_pattern = comment[3]
                    end
                    break
                  end
                elseif line:find(comment[2]) then
                  is_comment = true
                  break
                end
              else
                if comment[3] then
                  local start, ending = regex.find_offsets(
                    comment[2], line, 1, regex.ANCHORED
                  )
                  if start then
                    if not regex.find_offsets(
                        comment[3], line, ending+1, regex.ANCHORED
                      )
                    then
                      is_comment = true
                      inside_comment = true
                      end_regex = comment[3]
                    end
                    break
                  end
                elseif regex.find_offsets(comment[2], line, 1, regex.ANCHORED) then
                  is_comment = true
                  break
                end
              end
            end
          elseif end_pattern and line:find(end_pattern) then
            is_comment = true
            inside_comment = false
            end_pattern = nil
          elseif end_regex and regex.find_offsets(end_regex, line) then
            is_comment = true
            inside_comment = false
            end_regex = nil
          end
        end
        if
          not is_comment
          and
          not inside_comment
        then
          i = i + 1
          coroutine.yield(i, line)
        end
      end
    end
  end)
end


local function detect_indent_stat(buffer)
  local stat = {}
  local tab_count = 0
  local runs = 1
  local max_lines = auto_detect_max_lines
  for i, text in get_non_empty_lines(buffer.syntax, buffer.lines) do
    local spaces = text:match("^ +")
    if spaces then table.insert(stat, spaces:len()) end
    local tabs = text:match("^\t+")
    if tabs then tab_count = tab_count + 1 end
    -- if nothing found for first lines try at least 4 more times
    if i == max_lines and runs < 5 and #stat == 0 and tab_count == 0 then
      max_lines = max_lines + auto_detect_max_lines
      runs = runs + 1
    -- Stop parsing when files is very long. Not needed for euristic determination.
    elseif i > max_lines then break end
  end
  local indent, score = optimal_indent_from_stat(stat)
  if tab_count > score then
    return "hard", config.indent_size, tab_count
  else
    return "soft", indent or config.indent_size, score or 0
  end
end

function detectindent.detect(buffer)
  return detect_indent_stat(buffer)
end


local function update_cache(buffer)
  local type, size, score = detect_indent_stat(buffer)
  local score_threshold = 2
  if score < score_threshold then
    -- use default values
    type = config.tab_type
    size = config.indent_size
  end
  cache[buffer] = { type = type, size = size, confirmed = (score >= score_threshold) }
  buffer.indent_info = cache[buffer]
  core.log_quiet(
    "Indent detection for %s: syntax=%s type=%s size=%d score=%d confirmed=%s",
    buffer:get_name(), tostring(buffer.syntax and buffer.syntax.name), type, size, score,
    tostring(score >= score_threshold)
  )
end

-- Override TextView to ensure we only apply detectindent to visible Text Views.
local textview_new = TextView.new
function TextView:new(...)
  textview_new(self, ...)
  self.init_detectindent = true
end

local textview_draw = TextView.draw
function TextView:draw(...)
  textview_draw(self, ...)
  if self.init_detectindent then
    -- perform detection only for Buffers loaded in the UI
    if #core.get_views_referencing_buffer(self.buffer) > 0 then
      local type, size, confirmed = self.buffer:get_indent_info()
      if not confirmed then
        update_cache(self.buffer)
      else
        cache[self.buffer] = { type = type, size = size, confirmed = confirmed }
      end
    end
    self.init_detectindent = nil
  end
end

local clean = Buffer.clean
function Buffer:clean(...)
  clean(self, ...)
  if cache[self] then
    local _, _, confirmed = self:get_indent_info()
    if not confirmed then
      update_cache(self)
    end
  end
end

local on_close = Buffer.on_close
function Buffer:on_close()
  on_close(self)
  if cache[self] then cache[self] = nil end
end


local function set_indent_type(buffer, type)
  local _, indent_size = buffer:get_indent_info()
  cache[buffer] = {
    type = type,
    size = indent_size,
    confirmed = true
  }
  buffer.indent_info = cache[buffer]
end

local function set_indent_type_command(dv)
  core.global_prompt_bar:enter("Specify indent style for this file", {
    submit = function(value)
      local buffer = dv.buffer
      value = value:lower()
      set_indent_type(buffer, value == "tabs" and "hard" or "soft")
    end,
    suggest = function(text)
      return common.fuzzy_match({"tabs", "spaces"}, text)
    end,
    validate = function(text)
      local t = text:lower()
      return t == "tabs" or t == "spaces"
    end
  })
end


local function set_indent_size(buffer, size)
  local indent_type = buffer:get_indent_info()
  cache[buffer] = {
    type = indent_type,
    size = size,
    confirmed = true
  }
  buffer.indent_info = cache[buffer]
end

local function set_indent_size_command(dv)
  core.global_prompt_bar:enter("Specify indent size for current file", {
    submit = function(value)
      value = math.floor(tonumber(value))
      local buffer = dv.buffer
      set_indent_size(buffer, value)
    end,
    validate = function(value)
      value = tonumber(value)
      return value ~= nil and value >= 1
    end
  })
end


command.add("core.textview", {
  ["indent:set-file-indent-type"] = set_indent_type_command,
  ["indent:set-file-indent-size"] = set_indent_size_command
})

command.add(
  function()
    return core.active_view:extends(Editor)
      and cache[core.active_view.buffer]
      and cache[core.active_view.buffer].type == "soft"
  end, {
  ["indent:switch-file-to-tabs-indentation"] = function()
    set_indent_type(core.active_view.buffer, "hard")
  end
})

command.add(
  function()
    return core.active_view:extends(Editor)
      and cache[core.active_view.buffer]
      and cache[core.active_view.buffer].type == "hard"
  end, {
  ["indent:switch-file-to-spaces-indentation"] = function()
    set_indent_type(core.active_view.buffer, "soft")
  end
})

return detectindent
