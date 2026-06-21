local core = require "core"
local common = require "core.common"
local tokenizer = require "core.tokenizer"
local Object = require "core.object"

local language_intelligence
local language_intelligence_checked = false

local function get_language_intelligence()
  if not language_intelligence_checked then
    language_intelligence_checked = true
    local ok, module = pcall(require, "core.language_intelligence")
    if ok then language_intelligence = module end
  end
  return language_intelligence
end


local Highlighter = Object:extend()

function Highlighter:__tostring() return "Highlighter" end

function Highlighter:new(doc)
  self.doc = doc
  self.running = false
  self:reset()
end

-- init incremental syntax highlighting
function Highlighter:start()
  if self.running then return end
  self.running = true
  core.add_thread(function()
    local views = #core.get_views_referencing_doc(self.doc)
    local prev_line = 0
    while self.first_invalid_line <= self.max_wanted_line do
      if not self.doc then return end
      local line_count = #self.doc.lines
      if self.first_invalid_line > line_count then break end
      local max = math.min(self.first_invalid_line + 40, self.max_wanted_line, line_count)
      local line
      local retokenized_from
      for i = self.first_invalid_line, max do
        local prev = (i > 1) and self.lines[i - 1]
        local state = prev and prev.state
        line = self.lines[i]
        if line and line.resume and (line.init_state ~= state or line.text ~= self.doc:get_utf8_line(i)) then
          -- Reset the progress if no longer valid
          line.resume = nil
        end
        if not (line and line.init_state == state and line.text == self.doc:get_utf8_line(i) and not line.resume) then
          retokenized_from = retokenized_from or i
          self.lines[i] = self:tokenize_line(i, state, line and line.resume)
          if not self.lines[i] then
            self.first_invalid_line = i
            break
          end
          if self.lines[i].resume then
            self.first_invalid_line = i
            goto yield
          end
        elseif retokenized_from then
          self:update_notify(retokenized_from, i - retokenized_from - 1)
          retokenized_from = nil
        end
      end

      self.first_invalid_line = max + 1
      ::yield::
      -- depending on installed plugins notifying can be expensive with long
      -- lines so we perform only on first and last tokenization
      if
        retokenized_from and (
          prev_line ~= retokenized_from
          or
          not (line and line.resume and #line.text > 200)
        )
      then
        prev_line = retokenized_from
        self:update_notify(retokenized_from, max - retokenized_from)
      end
      core.redraw = true
      coroutine.yield()

      -- stop tokenizer if the doc was originally referenced by a docview
      -- but it was closed, helps when closing files that have huge lines
      -- and tokenization is taking a long time
      if views > 0 and #core.get_views_referencing_doc(self.doc) == 0 then
        break
      end
    end
    self.max_wanted_line = 0
    self.running = false
  end, self)
end

local function set_max_wanted_lines(self, amount)
  self.max_wanted_line = amount
  if self.first_invalid_line <= self.max_wanted_line then
    self:start()
  end
end


function Highlighter:reset()
  self.lines = {}
  self:soft_reset()
end

function Highlighter:soft_reset()
  for i=1,#self.lines do
    self.lines[i] = false
  end
  self:invalidate_render_cache()
  self.first_invalid_line = 1
  self.max_wanted_line = 0
end

function Highlighter:invalidate(idx)
  self.first_invalid_line = math.min(self.first_invalid_line, idx)
  set_max_wanted_lines(self, math.min(self.max_wanted_line, #self.doc.lines))
end

function Highlighter:insert_notify(line, n)
  self:invalidate(line)
  self:invalidate_render_cache(line)
  local blanks = { }
  for i = 1, n do
    blanks[i] = false
  end
  common.splice(self.lines, line, 0, blanks)
end

function Highlighter:remove_notify(line, n)
  self:invalidate(line)
  self:invalidate_render_cache(line)
  common.splice(self.lines, line, n)
end

function Highlighter:batch_notify(changed_ranges)
  local first_line
  local line_delta = 0
  local applied = 0
  for _, range in ipairs(changed_ranges or {}) do
    local old_line1 = range.old_line1
    local new_line1 = range.new_line1
    if old_line1 and new_line1 then
      first_line = math.min(first_line or new_line1, new_line1)
      local remove_count = math.max(0, range.old_line_count or ((range.old_line2 or old_line1) - old_line1 + 1))
      local insert_count = math.max(0, range.new_line_count or ((range.new_line2 or new_line1) - new_line1 + 1))
      local blanks = {}
      for i = 1, insert_count do blanks[i] = false end
      common.splice(self.lines, old_line1 + line_delta, remove_count, blanks)
      line_delta = line_delta + insert_count - remove_count
      applied = applied + 1
    end
  end
  if not first_line then return end
  self:invalidate_render_cache(first_line, #self.doc.lines)
  self:invalidate(first_line)
  if core and core.log_quiet and applied > 1 then
    core.log_quiet("Highlighter batch update shifted %d changed range(s) from line %d", applied, first_line)
  end
end

function Highlighter:update_notify(line, n)
  -- plugins can hook here to be notified that lines have been retokenized
  self.doc:clear_cache(line, n)
end

function Highlighter:invalidate_render_cache(first_line, last_line)
  self.render_line_frame_cache = nil
  local intelligence = get_language_intelligence()
  if intelligence and self.doc then
    intelligence.invalidate_render_cache(self.doc, first_line, last_line)
  end
  if self.doc and first_line then
    self.doc:clear_cache(first_line, (last_line or first_line) - first_line)
  elseif self.doc then
    self.doc:clear_cache(1, #self.doc.lines)
  end
end


function Highlighter:tokenize_line(idx, state, resume)
  local text = self.doc:get_utf8_line(idx)
  if not text then return nil end
  local res = {}
  res.init_state = state
  res.text = text
  res.tokens, res.state, res.resume = tokenizer.tokenize(self.doc.syntax, res.text, state, resume)
  return res
end


function Highlighter:get_line(idx)
  if not self.doc then return {text="", tokens={"normal", ""}} end
  local line = self.lines[idx]
  if not line or line.text ~= self.doc:get_utf8_line(idx) then
    local prev = self.lines[idx - 1]
    line = self:tokenize_line(idx, prev and prev.state)
    if not line then return {text="", tokens={"normal", ""}} end
    self.lines[idx] = line
    self:update_notify(idx, 0)
  end
  set_max_wanted_lines(self, math.max(self.max_wanted_line, idx))
  return line
end


function Highlighter:each_token(idx, scol)
  return tokenizer.each_token(self:get_line(idx).tokens, scol)
end

function Highlighter:get_render_line(idx)
  if not self.doc then return {text="", tokens={"normal", ""}, source="tokenizer"} end

  local function make_line(text, tokens, source)
    return { text = text, tokens = tokens, source = source }
  end

  local text = self.doc:get_utf8_line(idx) or ""
  local frame_cache
  local frame_id = core.render_frame_active and core.render_frame_id
  if frame_id then
    frame_cache = self.render_line_frame_cache
    if not frame_cache or frame_cache.frame_id ~= frame_id then
      frame_cache = { frame_id = frame_id, lines = {} }
      self.render_line_frame_cache = frame_cache
    end

    local cached = frame_cache.lines[idx]
    if cached and cached.text == text then
      return make_line(cached.render_text, cached.tokens, cached.source)
    end
  end

  local function finish(render_text, tokens, source)
    if frame_cache then
      frame_cache.lines[idx] = {
        text = text,
        render_text = render_text,
        tokens = tokens,
        source = source,
      }
    end
    return make_line(render_text, tokens, source)
  end

  local intelligence = get_language_intelligence()
  if intelligence then
    local tokens, _, provider_id = intelligence.render_tokens(self.doc, idx)
    if tokens then
      return finish(text, tokens, provider_id or "language-intelligence")
    end
  end
  local line = self:get_line(idx)
  return finish(line.text, line.tokens, "tokenizer")
end

function Highlighter:each_render_token(idx, scol)
  return tokenizer.each_token(self:get_render_line(idx).tokens, scol)
end

return Highlighter
