-- mod-version:3
local core = require "core"
local config = require "core.config"
local style = require "core.style"
local TextView = require "core.textview"

local smoothcaret = {
  enabled = false,
  rate = 0.65,
}

local textview_update = TextView.update
function TextView:update()
  textview_update(self)

  if not smoothcaret.enabled then return end

  local minline, maxline = self:get_visible_line_range()

  -- We need to keep track of all the carets
  if not self.carets then
    self.carets = { }
  end
  -- and we need the list of visible ones that `TextView:draw_caret` will use in succession
  self.visible_carets = { }

  local idx, v_idx = 1, 1
  for _, line, col in self.buffer:get_selections() do
    local x, y = self:get_line_screen_position(line, col)
    -- Keep the position relative to the whole View
    -- This way scrolling won't animate the caret
    x = x + self.scroll.x
    y = y + self.scroll.y

    if not self.carets[idx] then
      self.carets[idx] = { current = { x = x, y = y }, target = { x = x, y = y } }
    end

    local c = self.carets[idx]
    c.target.x = x
    c.target.y = y

    -- Chech if the number of carets changed
    if self.last_n_selections ~= #self.buffer.selections then
      -- Don't animate when there are new carets
      c.current.x = x
      c.current.y = y
    else
      self:move_towards(c.current, "x", c.target.x, smoothcaret.rate)
      self:move_towards(c.current, "y", c.target.y, smoothcaret.rate)
    end

    -- Keep track of visible carets
    if line >= minline and line <= maxline then
      self.visible_carets[v_idx] = self.carets[idx]
      v_idx = v_idx + 1
    end
    idx = idx + 1
  end
  self.last_n_selections = #self.buffer.selections

  -- Remove unused carets to avoid animating new ones when they are added
  for i = idx, #self.carets do
    self.carets[i] = nil
  end

  if self.mouse_selecting ~= self.last_mouse_selecting then
    self.last_mouse_selecting = self.mouse_selecting
    -- Show the caret on click, so that it can be seen moving towards the new position
    if self.mouse_selecting then
      core.blink_timer = core.blink_timer + config.blink_period / 2
      core.redraw = true
    end
  end

  -- This is used by `TextView:draw_caret` to keep track of the current caret per view.
  self.smoothcaret_draw_caret_idx = 1
end

local textview_draw_caret = TextView.draw_caret

local function perf_scope_begin(name)
  if not core.perf_draw_scope_active then return nil end
  local perf = package.loaded["core.perf"]
  return perf and perf.scope_begin and perf.scope_begin(name) or nil
end

local function perf_scope_end(token)
  if not token then return end
  local perf = package.loaded["core.perf"]
  if perf and perf.scope_end then perf.scope_end(token) end
end

function TextView:draw_caret(x, y, line, col, caret_idx_arg, color)
  local scope = perf_scope_begin("smooth_caret")
  if not smoothcaret.enabled then
    textview_draw_caret(self, x, y, line, col, caret_idx_arg, color)
    perf_scope_end(scope)
    return
  end

  local idx = caret_idx_arg or self.smoothcaret_draw_caret_idx or 1
  local c = self.visible_carets and self.visible_carets[idx]
    or { current = { x = x, y = y } }
  textview_draw_caret(self, c.current.x - self.scroll.x, c.current.y - self.scroll.y, line, col, caret_idx_arg, color)

  self.smoothcaret_draw_caret_idx = idx + 1
  perf_scope_end(scope)
end
