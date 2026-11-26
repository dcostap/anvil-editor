-- A text input: its text, caret and selection, edited with the editor's line commands. The Project Sidebar runs
-- without the editor's Buffer and Text View, so its search field uses this. An input keeps one line, unless it is
-- made with `multiline`; then Home and End work in the caret's line. Its owner moves between lines, because only
-- the owner knows how the text wraps.
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

local function line_start(text, pos)
  while pos > 0 and text:byte(pos) ~= 10 do pos = pos - 1 end
  return pos
end

local function line_end(text, pos)
  return (text:find("\n", pos + 1, true) or #text + 1) - 1
end

local function buffer_start() return 0 end
local function buffer_end(text) return #text end

-- Each target, named as in the editor's move_to_*, select_to_* and delete_to_* commands.
local TARGETS = {
  previous_char = previous_char,
  next_char = next_char,
  previous_word_start = previous_word_start,
  next_word_end = next_word_end,
  start_of_indentation = line_start,
  start_of_line = line_start,
  start_of_buffer = buffer_start,
  end_of_line = line_end,
  end_of_buffer = buffer_end,
}

-- The editor commands that a line input performs, without their "core:" prefix.
LineInput.COMMANDS = {"select_all", "backspace", "delete", "copy", "cut", "paste", "undo", "redo"}
for target in pairs(TARGETS) do
  for _, kind in ipairs {"move_to_", "select_to_", "delete_to_"} do
    LineInput.COMMANDS[#LineInput.COMMANDS + 1] = kind .. target
  end
end
table.sort(LineInput.COMMANDS)

-- Undo keeps at most this many steps.
local MAX_UNDO = 100

function LineInput:new(text, multiline)
  self.multiline = multiline == true
  self:set_text(text or "")
end

-- Replaces the text and puts the caret at its end. Undo starts again.
function LineInput:set_text(text)
  self.text, self.caret, self.anchor = text, #text, #text
  self.undo_steps, self.redo_steps, self.typing_at = {}, {}, nil
end

function LineInput:selection()
  return math.min(self.caret, self.anchor), math.max(self.caret, self.anchor)
end

-- Replaces the selection with `text`, and puts the caret after it. A one-line input turns line breaks into spaces.
-- Each insert is an undo step, but typed characters in a row make one step.
function LineInput:insert(text)
  if self.multiline then text = text:gsub("\r\n?", "\n") else text = text:gsub("\r?\n", " ") end
  local first, last = self:selection()
  if text == "" and first == last then return end
  local typing = text ~= "" and first == last and not text:find("\n")
  if not (typing and self.typing_at == first) then
    table.insert(self.undo_steps, {self.text, self.caret, self.anchor})
    if #self.undo_steps > MAX_UNDO then table.remove(self.undo_steps, 1) end
  end
  self.redo_steps = {}
  self.text = self.text:sub(1, first) .. text .. self.text:sub(last + 1)
  self.caret = first + #text
  self.anchor = self.caret
  self.typing_at = typing and self.caret or nil
end

-- Puts back the last state of `from`, and keeps the current state in `to`.
local function restore(self, from, to)
  local step = table.remove(from)
  if not step then return end
  to[#to + 1] = {self.text, self.caret, self.anchor}
  self.text, self.caret, self.anchor = step[1], step[2], step[3]
  self.typing_at = nil
end

-- Moves the caret to `pos`. `select` keeps the anchor, so the selection grows or shrinks.
function LineInput:set_caret(pos, select)
  self.caret = math.max(0, math.min(#self.text, pos))
  while self.caret > 0 and continuation(self.text, self.caret) do self.caret = self.caret - 1 end
  if not select then self.anchor = self.caret end
  self.typing_at = nil
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
  elseif name == "undo" then
    restore(self, self.undo_steps, self.redo_steps)
  elseif name == "redo" then
    restore(self, self.redo_steps, self.undo_steps)
  else
    return false
  end
  return true
end

-- The caret offset nearest to `x` pixels from the left edge of the text from `first` to `last` (default: all).
function LineInput:offset_at(font, x, first, last)
  first, last = first or 0, last or #self.text
  local pos, left = first, 0
  while pos < last do
    local nxt = next_char(self.text, pos)
    local right = font:get_width(self.text:sub(first + 1, nxt))
    if x < (left + right) / 2 then return pos end
    pos, left = nxt, right
  end
  return pos
end

return LineInput
