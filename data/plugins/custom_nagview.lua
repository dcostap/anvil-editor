-- mod-version:3
-- Local NagView override: keep core's public API/queue/focus behavior, but own
-- layout/drawing in one place. The nagbar background remains full-width while
-- message/buttons are centered in a capped content lane. Also supports styled
-- message tables used by local plugins.
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local NagView = require "core.nagview"

if not NagView.__custom_nagview_original_next then
  NagView.__custom_nagview_original_next = NagView.next
end

local old_next = NagView.__custom_nagview_original_next
local DEFAULT_MAX_CONTENT_WIDTH = 1100 -- logical pixels, scaled below

local function border_width()
  return common.round(1 * SCALE)
end

local function underline_width()
  return common.round(2 * SCALE)
end

local function underline_margin()
  return common.round(1 * SCALE)
end

local function max_content_width()
  return style.nagbar_max_content_width
      or config.nagbar_max_content_width
      or (DEFAULT_MAX_CONTENT_WIDTH * SCALE)
end

local function outside_overlay_color(amount)
  -- Simulate a translucent black overlay over style.nagbar instead of relying on
  -- renderer alpha blending, so the outside lanes remain visibly "red, dimmed"
  -- rather than turning into solid black on renderers/themes that treat alpha
  -- differently.
  local base = style.nagbar or { 128, 0, 0, 255 }
  amount = common.clamp(amount or 0, 0, 1)
  return {
    math.floor((base[1] or 0) * (1 - amount) + 0.5),
    math.floor((base[2] or 0) * (1 - amount) + 0.5),
    math.floor((base[3] or 0) * (1 - amount) + 0.5),
    base[4] or 255,
  }
end

local function is_styled_message(message)
  return type(message) == "table" and message.editree_styled_nag_message
end

local function styled_plain_text(message)
  local lines = {}
  for _, line in ipairs(message.lines or {}) do
    local text = {}
    for _, part in ipairs(line) do text[#text + 1] = part.text or "" end
    lines[#lines + 1] = table.concat(text)
  end
  return table.concat(lines, "\n")
end

local function part_style(part)
  return part.font or style.font, part.color or style.nagbar_text
end

local function line_height_for_font(font_height)
  return math.max(common.round(font_height * config.line_height), font_height)
end

local function push_text_token(tokens, part, text, is_space)
  if text == "" then return end
  local font, color = part_style(part)
  tokens[#tokens + 1] = {
    text = text,
    font = font,
    color = color,
    is_space = is_space,
    width = font:get_width(text),
  }
end

local function tokenize_message_line(line)
  local tokens = {}
  for _, part in ipairs(line) do
    local text = tostring(part.text or "")
    local pos = 1
    while pos <= #text do
      local s, e = text:find("%s+", pos)
      if s == pos then
        push_text_token(tokens, part, text:sub(s, e), true)
        pos = e + 1
      elseif s then
        push_text_token(tokens, part, text:sub(pos, s - 1), false)
        pos = s
      else
        push_text_token(tokens, part, text:sub(pos), false)
        break
      end
    end
  end
  return tokens
end

local function append_wrapped_line(lines, line, max_width)
  while line.fragments[#line.fragments] and line.fragments[#line.fragments].is_space do
    line.width = line.width - line.fragments[#line.fragments].width
    table.remove(line.fragments)
  end

  local height = line_height_for_font(line.font_height)
  lines[#lines + 1] = {
    width = line.width,
    height = height,
    fragments = line.fragments,
  }

  return { width = 0, font_height = style.font:get_height(), fragments = {} }, math.max(max_width, line.width)
end

local function split_long_token(token, max_width)
  if max_width <= 0 or token.width <= max_width then return { token } end
  local chunks = {}
  local start = 1
  while start <= #token.text do
    local lo, hi, best = start, #token.text, start
    while lo <= hi do
      local mid = math.floor((lo + hi) / 2)
      local text = token.text:sub(start, mid)
      if token.font:get_width(text) <= max_width or mid == start then
        best = mid
        lo = mid + 1
      else
        hi = mid - 1
      end
    end
    local text = token.text:sub(start, best)
    chunks[#chunks + 1] = {
      text = text,
      font = token.font,
      color = token.color,
      is_space = false,
      width = token.font:get_width(text),
    }
    start = best + 1
  end
  return chunks
end

local function layout_tokens(tokens, max_width)
  local lines, used_width = {}, 0
  local line = { width = 0, font_height = style.font:get_height(), fragments = {} }

  local function add_token(token)
    if token.is_space and #line.fragments == 0 then return end
    if token.is_space and line.width + token.width > max_width then
      line, used_width = append_wrapped_line(lines, line, used_width)
      return
    end
    if not token.is_space and #line.fragments > 0 and line.width + token.width > max_width then
      line, used_width = append_wrapped_line(lines, line, used_width)
    end
    line.fragments[#line.fragments + 1] = token
    line.width = line.width + token.width
    line.font_height = math.max(line.font_height, token.font:get_height())
  end

  for _, token in ipairs(tokens) do
    for _, chunk in ipairs(split_long_token(token, max_width)) do add_token(chunk) end
  end

  if #line.fragments > 0 or #lines == 0 then
    line, used_width = append_wrapped_line(lines, line, used_width)
  end
  return lines, used_width
end

local function plain_message_lines(message)
  local lines = {}
  for msg_line in tostring(message or ""):gmatch("(.-)\n") do
    lines[#lines + 1] = { { text = msg_line, font = style.font, color = style.nagbar_text } }
  end
  if #lines == 0 then lines[1] = { { text = "", font = style.font, color = style.nagbar_text } } end
  return lines
end

local function message_source_lines(message)
  return is_styled_message(message) and (message.lines or {}) or plain_message_lines(message)
end

local function layout_message_lines(message, max_width)
  local out, width, height = {}, 0, 0
  max_width = math.max(1, max_width or 1)
  for _, source_line in ipairs(message_source_lines(message)) do
    local wrapped, used = layout_tokens(tokenize_message_line(source_line), max_width)
    for _, line in ipairs(wrapped) do
      out[#out + 1] = line
      width = math.max(width, line.width)
      height = height + line.height
    end
  end
  if #out == 0 then
    local h = line_height_for_font(style.font:get_height())
    out[1] = { width = 0, height = h, fragments = {} }
    height = h
  end
  return out, width, height
end

local function queue_prefix_width(nag)
  if #(nag.queue or {}) == 0 then return 0 end
  return style.font:get_width(string.format("[%d]", #nag.queue)) + style.padding.x
end

local function leftmost_button_x(nag, content_x, content_width)
  if not nag.options or #nag.options == 0 then return math.huge end
  local x = content_x + content_width
  for i = #nag.options, 1, -1 do
    local opt = nag.options[i]
    local bw = style.font:get_width(opt.text) + 2 * border_width() + style.padding.x
    x = x - bw - style.padding.x
  end
  return x
end

function NagView:get_limited_content_bounds()
  local ox, oy = self:get_content_offset()
  local full_width = self.size.x
  local content_width = math.min(full_width, max_content_width())
  local content_x = ox + (full_width - content_width) / 2
  return content_x, oy, content_width, self.show_height, ox, full_width
end

function NagView:get_nag_layout()
  local content_x, oy, content_width, show_height, full_x, full_width = self:get_limited_content_bounds()
  local btn_h = self:get_buttons_height()
  local msg_x = content_x + style.padding.x + queue_prefix_width(self)
  local inline_buttons_left = leftmost_button_x(self, content_x, content_width)
  local inline_message_width = math.max(1, inline_buttons_left - style.padding.x - msg_x)
  local full_message_width = math.max(1, content_x + content_width - style.padding.x - msg_x)
  local inline_lines, inline_msg_w, inline_msg_h = layout_message_lines(self.message, inline_message_width)
  local stacked = #inline_lines > 1 or inline_msg_w > inline_message_width
  local msg_lines, msg_w, msg_h = inline_lines, inline_msg_w, inline_msg_h

  if stacked then
    msg_lines, msg_w, msg_h = layout_message_lines(self.message, full_message_width)
  end

  local desired_content_height = stacked and (msg_h + btn_h + style.padding.y) or math.max(msg_h, btn_h)
  local ok_window, _, window_h = pcall(system.get_window_size, core.window)
  window_h = ok_window and window_h or math.huge
  local max_content_height = math.max(btn_h, window_h - 2 * style.padding.y)
  local target_content_height = math.min(desired_content_height, max_content_height)
  local message_clip_height = stacked
    and math.max(0, target_content_height - btn_h - style.padding.y)
    or target_content_height
  local msg_y = stacked
    and (oy + style.padding.y)
    or (oy + style.padding.y + math.max(0, (target_content_height - msg_h) / 2))

  return {
    content_x = content_x,
    content_y = oy,
    content_width = content_width,
    show_height = show_height,
    full_x = full_x,
    full_width = full_width,
    message_x = msg_x,
    message_y = msg_y,
    message_width = msg_w,
    message_height = msg_h,
    message_clip_height = message_clip_height,
    message_lines = msg_lines,
    buttons_stacked = stacked,
    target_content_height = target_content_height,
    desired_content_height = desired_content_height,
  }
end

function NagView:get_target_height()
  if self.visible and self.title then
    return self:get_nag_layout().target_content_height + 2 * style.padding.y
  end
  return self.target_height + 2 * style.padding.y
end

function NagView:each_option()
  return coroutine.wrap(function()
    if not self.options then return end
    local bh = self:get_buttons_height()
    local ox, oy, content_width = self:get_limited_content_bounds()
    ox = ox + content_width
    oy = oy + self.show_height - bh - style.padding.y

    for i = #self.options, 1, -1 do
      local opt = self.options[i]
      local bw = style.font:get_width(opt.text) + 2 * border_width() + style.padding.x
      ox = ox - bw - style.padding.x
      coroutine.yield(i, opt, ox, oy, bw, bh)
    end
  end)
end

function NagView:get_message_height(...)
  local _, _, height = layout_message_lines(self.message, math.huge)
  return height
end

function NagView:next(...)
  local item = self.queue and self.queue[1]
  local styled = item and is_styled_message(item.message) and item.message
  if not styled then return old_next(self, ...) end

  -- Core NagView expects a string message. Feed it plain text so all existing
  -- queue/focus/mouse-hook behavior stays untouched, then restore the styled
  -- object for our renderer and height calculation.
  item.message = styled_plain_text(styled)
  old_next(self, ...)
  item.message = styled

  if self.title == item.title then
    self.message = styled
    self.target_height = math.max(self:get_message_height(), self:get_buttons_height())
  end
end

local function draw_options(self)
  for i, opt, bx, by, bw, bh in self:each_option() do
    local border = border_width()
    local fw, fh = bw - 2 * border, bh - 2 * border
    local fx, fy = bx + border, by + border

    renderer.draw_rect(bx, by, bw, bh, style.nagbar_text)
    renderer.draw_rect(fx, fy, fw, fh, style.nagbar)

    if i == self.hovered_item then
      local margin = underline_margin()
      local uw = fw - 2 * margin
      local halfuw = uw / 2
      local lx = fx + margin + halfuw - (halfuw * self.underline_progress)
      local ly = fy + fh - margin - underline_width()
      renderer.draw_rect(lx, ly, uw * self.underline_progress, underline_width(), style.nagbar_text)
    end

    common.draw_text(style.font, style.nagbar_text, opt.text, "center", fx, fy, fw, fh)
  end
end

local function draw_message_lines(lines, x, y)
  local yy = y
  for _, line in ipairs(lines or {}) do
    local xx = x
    for _, fragment in ipairs(line.fragments or {}) do
      renderer.draw_text(fragment.font, fragment.text, xx, yy + (line.height - fragment.font:get_height()) / 2, fragment.color)
      xx = xx + fragment.width
    end
    yy = yy + line.height
  end
end

local function draw_nagview(self)
  self:dim_window_content()

  local layout = self:get_nag_layout()
  local content_x = layout.content_x
  local oy = layout.content_y
  local content_width = layout.content_width
  local full_x = layout.full_x
  local full_width = layout.full_width

  -- Full-width visual bar; capped centered content lane.
  renderer.draw_rect(full_x, oy, full_width, self.show_height, style.nagbar)

  local overflow = math.max(0, full_width - content_width)
  if overflow > 0 then
    local fade = common.clamp(overflow / math.max(1, 40 * SCALE), 0, 1)
    local side_w = overflow / 2
    local color = outside_overlay_color(0.25 * fade)
    renderer.draw_rect(full_x, oy, side_w, self.show_height, color)
    renderer.draw_rect(content_x + content_width, oy, side_w, self.show_height, color)
  end

  core.push_clip_rect(content_x, oy, content_width, self.show_height)

  if #self.queue > 0 then
    local str = string.format("[%d]", #self.queue)
    common.draw_text(style.font, style.nagbar_text, str, "left", content_x + style.padding.x, oy, content_width, self.show_height)
  end

  core.push_clip_rect(
    layout.message_x,
    layout.message_y,
    math.max(0, content_x + content_width - style.padding.x - layout.message_x),
    layout.message_clip_height
  )
  draw_message_lines(layout.message_lines, layout.message_x, layout.message_y)
  core.pop_clip_rect()

  draw_options(self)
  self:draw_scrollbar()
  core.pop_clip_rect()
end

function NagView:draw()
  if (not self.visible and self.show_height <= 0) or not self.title then
    return
  end
  core.root_view:defer_draw(draw_nagview, self)
end
