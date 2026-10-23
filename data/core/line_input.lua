-- A one-line text input: its text, caret and selection, edited with the editor's line commands. The Project Sidebar
-- runs without the editor's Buffer and Text View, so its search field uses this.
-- Positions are byte offsets from 0 to #text, always at the start of a UTF-8 character.
local config = require "core.config"
local Object = require "core.object"

local LineInput = Object:extend()

local function continuation(text, pos)
  local byte = text:byte(pos + 1)
  return byte ~= nil and byte >= 0x80 and byte < 0xC0
end

local function previous_char(text, pos)
  pos = math.max(0, pos - 1)
  while pos > 0 and continuation(text, pos) do pos = pos - 1 end
  return pos
end

local function next_char(text, pos)
  pos = math.min(#text, pos + 1)
  while pos < #text and continuation(text, pos) do pos = pos + 1 end
  return pos
end

local function non_word(char)
  return char ~= "" and config.non_word_chars:find(char, 1, true) ~= nil
end

-- The editor's word rule: a run of one punctuation character is a word, and spaces join the word beside them.
local function previous_word_start(text, pos)
  local prev
  while pos > 0 do
    local p = previous_char(text, pos)
    local char = text:sub(p + 1, pos)
    if prev and prev ~= char or not non_word(char) then break end
    prev, pos = char, p
  end
  if prev and not prev:match("%s") then return pos end
  while pos > 0 do
    local p = previous_char(text, pos)
    if non_word(text:sub(p + 1, pos)) then break end
    pos = p
  end
  return pos
end

local function next_word_end(text, pos)
  local prev
  while pos < #text do
    local p = next_char(text, pos)
    local char = text:sub(pos + 1, p)
    if prev and prev ~= char or not non_word(char) then break end
    prev, pos = char, p
  end
  if prev and not prev:match("%s") then return pos end
  while pos < #text do
    local p = next_char(text, pos)
    if non_word(text:sub(pos + 1, p)) then break end
    pos = p
  end
  return pos
end

local function line_start() return 0 end
local function line_end(text) return #text end

-- Each target, named as in the editor's move_to_*, select_to_* and delete_to_* commands.
local TARGETS = {
  previous_char = previous_char,
  next_char = next_char,
  previous_word_start = previous_word_start,
  next_word_end = next_word_end,
  start_of_indentation = line_start,
  start_of_line = line_start,
  start_of_buffer = line_start,
  end_of_line = line_end,
  end_of_buffer = line_end,
}

-- The editor commands that a line input performs, without their "core:" prefix.
LineInput.COMMANDS = {"select_all", "backspace", "delete", "copy", "cut", "paste"}
for target in pairs(TARGETS) do
  for _, kind in ipairs {"move_to_", "select_to_", "delete_to_"} do
    LineInput.COMMANDS[#LineInput.COMMANDS + 1] = kind .. target
  end
end
table.sort(LineInput.COMMANDS)

function LineInput:new(text)
  self:set_text(text or "")
end

-- Replaces the text and puts the caret at its end.
function LineInput:set_text(text)
  self.text, self.caret, self.anchor = text, #text, #text
end

function LineInput:selection()
  return math.min(self.caret, self.anchor), math.max(self.caret, self.anchor)
end

-- Replaces the selection with `text`, and puts the caret after it. A line input keeps one line.
function LineInput:insert(text)
  text = text:gsub("\r?\n", " ")
  local first, last = self:selection()
  self.text = self.text:sub(1, first) .. text .. self.text:sub(last + 1)
  self.caret = first + #text
  self.anchor = self.caret
end

-- Moves the caret to `pos`. `select` keeps the anchor, so the selection grows or shrinks.
function LineInput:set_caret(pos, select)
  self.caret = math.max(0, math.min(#self.text, pos))
  while self.caret > 0 and continuation(self.text, self.caret) do self.caret = self.caret - 1 end
  if not select then self.anchor = self.caret end
end

-- Performs the editor command `name`. Returns false for a command that a line input does not have.
function LineInput:perform(name)
  local first, last = self:selection()
  local kind, target = name:match("^(%a+)_to_(.+)$")
  local find = target and TARGETS[target]
  if find then
    if kind == "move" and first ~= last and (target == "previous_char" or target == "next_char") then
      -- A character move ends a selection at its edge.
      self:set_caret(target == "previous_char" and first or last)
    elseif kind == "delete" and first ~= last then
      self:insert("")
    else
      self:set_caret(find(self.text, self.caret), kind ~= "move")
      if kind == "delete" then self:insert("") end
    end
    return true
  end
  if name == "select_all" then
    self.anchor, self.caret = 0, #self.text
  elseif name == "backspace" or name == "delete" then
    if first == last then
      self:set_caret((name == "backspace" and previous_char or next_char)(self.text, self.caret), true)
    end
    self:insert("")
  elseif name == "copy" or name == "cut" then
    if first ~= last then system.set_clipboard(self.text:sub(first + 1, last)) end
    if name == "cut" then self:insert("") end
  elseif name == "paste" then
    self:insert(system.get_clipboard() or "")
  else
    return false
  end
  return true
end

-- The caret offset nearest to `x` pixels from the text's left edge.
function LineInput:offset_at(font, x)
  local pos, left = 0, 0
  while pos < #self.text do
    local nxt = next_char(self.text, pos)
    local right = font:get_width(self.text:sub(1, nxt))
    if x < (left + right) / 2 then return pos end
    pos, left = nxt, right
  end
  return pos
end

return LineInput
