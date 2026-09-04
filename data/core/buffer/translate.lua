local common = require "core.common"

-- functions for translating a Buffer position to another position these functions
-- can be passed to Buffer:move_to|select_to|delete_to()

local translate = {}


local function is_non_word(buffer, char)
  return buffer:get_non_word_chars():find(char, nil, true)
end


function translate.previous_char(buffer, line, col)
  repeat
    line, col = buffer:position_offset(line, col, -1)
  until not common.is_utf8_cont(buffer:get_char(line, col))
  return line, col
end


function translate.next_char(buffer, line, col)
  repeat
    line, col = buffer:position_offset(line, col, 1)
  until not common.is_utf8_cont(buffer:get_char(line, col))
  return line, col
end


function translate.previous_word_start(buffer, line, col)
  local prev
  while line > 1 or col > 1 do
    local l, c = buffer:position_offset(line, col, -1)
    local char = buffer:get_char(l, c)
    if prev and prev ~= char or not is_non_word(buffer, char) then
      break
    end
    prev, line, col = char, l, c
  end
  if prev and not prev:match("%s") then
    return line, col
  end
  return translate.start_of_word(buffer, line, col)
end


function translate.next_word_end(buffer, line, col)
  local prev
  local end_line, end_col = translate.end_of_buffer(buffer, line, col)
  while line < end_line or col < end_col do
    local char = buffer:get_char(line, col)
    if prev and prev ~= char or not is_non_word(buffer, char) then
      break
    end
    line, col = buffer:position_offset(line, col, 1)
    prev = char
  end
  return translate.end_of_word(buffer, line, col)
end


function translate.start_of_word(buffer, line, col)
  while true do
    local line2, col2 = buffer:position_offset(line, col, -1)
    local char = buffer:get_char(line2, col2)
    if is_non_word(buffer, char)
    or line == line2 and col == col2 then
      break
    end
    line, col = line2, col2
  end
  return line, col
end


function translate.end_of_word(buffer, line, col)
  while true do
    local line2, col2 = buffer:position_offset(line, col, 1)
    local char = buffer:get_char(line, col)
    if is_non_word(buffer, char)
    or line == line2 and col == col2 then
      break
    end
    line, col = line2, col2
  end
  return line, col
end


function translate.previous_block_start(buffer, line, col)
  while true do
    line = line - 1
    if line <= 1 then
      return 1, 1
    end
    if buffer.lines[line-1]:find("^%s*$")
    and not buffer.lines[line]:find("^%s*$") then
      return line, (buffer.lines[line]:find("%S"))
    end
  end
end


function translate.next_block_end(buffer, line, col)
  while true do
    if line >= #buffer.lines then
      return #buffer.lines, 1
    end
    if buffer.lines[line+1]:find("^%s*$")
    and not buffer.lines[line]:find("^%s*$") then
      return line+1, #buffer.lines[line+1]
    end
    line = line + 1
  end
end


local function start_of_indentation_col(buffer, line)
  local _, e = buffer.lines[line]:find("^[\t ]*")
  return e + 1
end

function translate.start_of_line(buffer, line, col)
  return line, col == 1 and start_of_indentation_col(buffer, line) or 1
end

function translate.start_of_indentation(buffer, line, col)
  local indent_col = start_of_indentation_col(buffer, line)
  return line, col > indent_col and indent_col or (col == 1 and indent_col or 1)
end

function translate.end_of_line(buffer, line, col)
  return line, math.huge
end


function translate.start_of_buffer(buffer, line, col)
  return 1, 1
end


function translate.end_of_buffer(buffer, line, col)
  return #buffer.lines, #buffer.lines[#buffer.lines]
end


return translate
