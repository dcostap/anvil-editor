local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local Object = require "core.object"
local ui = require "core.ui"
local surface = require "core.ui.surface"

-- Layout nodes place a Dialog's controls, in the manner of CSS flexbox. Nodes and controls share these methods:
--   width()             the natural width
--   height(w)           the height at width `w`
--   place(x, y, w, h)   take a rect, and place the children in it
--   draw_node(dialog)   draw. A control draws its focus ring when it has the Dialog's keyboard focus.
--   collect(list)       add the visible controls to `list`, in Tab order
--   on_wheel(x, y, dy)  nodes only: scroll, for a node under the pointer. Returns true when it scrolled.
--                       The Dialog gives the wheel to the control under the pointer first.
-- A new kind of node gives its own size with content_width() and content_height(w). A control uses measure().
--
-- A container takes its children in the array part of its options: `layout.Column { gap = 8, a, b }`.
-- Each node and control takes these size options, in pixels at scale 1:
--   width, height                      a fixed size
--   min_width, max_width               limits for its width, also when a Row grows or shrinks it
--   min_height, max_height             limits for its height
--   grow                               a weight for a share of the free space along a Row or Column. true is 1.
-- Row and Column take:
--   gap                                the space between children
--   padding                            space inside the edges: one number, { vertical, horizontal }, or
--                                      { top, right, bottom, left }
--   justify                            where the children go along the axis when space is free:
--                                      "start", "center", "end" or "between"
--   align                              where each child goes across the axis: "start", "center", "end" or
--                                      "stretch". A Row centres by default, and a Column stretches.
-- A Row gives growing children only the free width, in proportion to their weights. When the children are too
-- wide, it shrinks each child in proportion to its width, down to its min_width, and text wraps.
-- A Column gives growing children the free height on top of their natural heights. It does not shrink them.
local layout = {}

local function px(value)
  return math.floor(value * SCALE + 0.5)
end

---Read the size options into `self`. Nodes and controls both call this.
function layout.init_size(self, options)
  self.grow = options.grow == true and 1 or options.grow or 0
  self.fixed_w, self.fixed_h = options.width, options.height
  self.min_w, self.max_w = options.min_width, options.max_width
  self.min_h, self.max_h = options.min_height, options.max_height
end

local function limits(fixed, min, max)
  if fixed then return px(fixed), px(fixed) end
  return min and px(min) or 0, max and px(max) or math.huge
end

local function clamp(value, low, high)
  return math.max(low, math.min(high, value))
end

local Node = Object:extend()
layout.Node = Node

function Node:new(options)
  options = options or {}
  self.x, self.y, self.w, self.h = 0, 0, 0, 0
  self.visible = options.visible ~= false
  layout.init_size(self, options)
  self.children = {}
  for _, child in ipairs(options) do self.children[#self.children + 1] = child end
end

function Node:content_width() return 0 end
function Node:content_height() return 0 end

---The smallest and largest widths that the size options allow.
function Node:width_limits() return limits(self.fixed_w, self.min_w, self.max_w) end
function Node:height_limits() return limits(self.fixed_h, self.min_h, self.max_h) end

function Node:width()
  return clamp(self:content_width(), self:width_limits())
end

function Node:height(w)
  return clamp(self:content_height(w), self:height_limits())
end

function Node:place(x, y, w, h)
  self.x, self.y, self.w, self.h = x, y, w, h
end

function Node:draw_node(dialog)
  for _, child in ipairs(self.children) do
    if child.visible then child:draw_node(dialog) end
  end
end

function Node:collect(list)
  for _, child in ipairs(self.children) do
    if child.visible then child:collect(list) end
  end
end

local function inside(node, x, y)
  return x >= node.x and y >= node.y and x < node.x + node.w and y < node.y + node.h
end

function Node:on_wheel(x, y, dy)
  for _, child in ipairs(self.children) do
    if child.visible and child.on_wheel and inside(child, x, y) and child:on_wheel(x, y, dy) then return true end
  end
  return false
end

---Replace the children.
function Node:set_children(children)
  self.children = children
  core.redraw = true
end

------------------------------------------------------------------------------------------------------------------
-- Row and Column: children along an axis, with the options above.

local Flex = Node:extend()
layout.Flex = Flex

---@param options { gap: number?, padding: number|number[]?, justify: string?, align: string? }
function Flex:new(options)
  Flex.super.new(self, options)
  self.gap = options.gap or self.default_gap
  self.justify = options.justify or "start"
  self.align = options.align or self.default_align
  local p = options.padding or 0
  if type(p) == "number" then p = { p, p, p, p } elseif #p == 2 then p = { p[1], p[2], p[1], p[2] } end
  self.padding = p
  -- Each visible child's size along the axis, and its limits. Reused in each frame.
  self.sizes, self.lows, self.highs, self.frozen = {}, {}, {}, {}
end

-- The padding in pixels: top, right, bottom, left.
local function padding(self)
  local p = self.padding
  return px(p[1]), px(p[2]), px(p[3]), px(p[4])
end

local function child_count(self)
  local count = 0
  for _, child in ipairs(self.children) do
    if child.visible then count = count + 1 end
  end
  return count
end

-- The width of a Column's child in the inner width `w`.
local function column_child_width(self, child, w)
  local low, high = child:width_limits()
  if self.align == "stretch" then return clamp(w, low, high) end
  return clamp(math.min(child:width(), w), low, high)
end

-- Grow or shrink the sizes by `free` pixels. A child that reaches a limit keeps it, and the others share the
-- rest. Returns the space that is still free.
local function flex(self, free, count)
  local sizes, lows, highs, frozen = self.sizes, self.lows, self.highs, self.frozen
  local growing = free > 0
  for _ = 1, count do
    if free == 0 then break end
    local total = 0
    for i, child in ipairs(self.children) do
      if child.visible and not frozen[i] then total = total + (growing and child.grow or sizes[i]) end
    end
    if total <= 0 then break end
    local spent, violated = 0, false
    for i, child in ipairs(self.children) do
      local weight = child.visible and not frozen[i] and (growing and child.grow or sizes[i])
      if weight and weight > 0 then
        local target = sizes[i] + free * weight / total
        local limited = clamp(target, lows[i], highs[i])
        if limited ~= target then
          spent, violated = spent + limited - sizes[i], true
          sizes[i], frozen[i] = limited, true
        end
      end
    end
    if violated then
      free = free - spent
    else
      for i, child in ipairs(self.children) do
        local weight = child.visible and not frozen[i] and (growing and child.grow or sizes[i])
        if weight and weight > 0 then sizes[i] = sizes[i] + free * weight / total end
      end
      free = 0
    end
  end
  return free
end

-- Fill self.sizes with each visible child's size along the axis, in `main` pixels. `cross` is the inner width of
-- a Column. Returns the free space and the child count.
local function resolve(self, main, cross)
  local sizes, lows, highs, frozen = self.sizes, self.lows, self.highs, self.frozen
  local used, count = 0, 0
  for i, child in ipairs(self.children) do
    if child.visible then
      local low, high, natural
      if self.row then
        low, high = child:width_limits()
        natural = child.grow > 0 and low or child:width()
      else
        -- A Column does not shrink its children, so a natural height is also the smallest height.
        low, high = child:height_limits()
        natural = child:height(column_child_width(self, child, cross))
        low = math.max(low, natural)
      end
      lows[i], highs[i], frozen[i] = low, high, false
      sizes[i] = clamp(natural, low, high)
      used, count = used + sizes[i], count + 1
    end
  end
  local free = main - used - math.max(0, count - 1) * px(self.gap)
  return flex(self, free, count), count
end

function Flex:content_width()
  local top, right, bottom, left = padding(self)
  local w = 0
  for _, child in ipairs(self.children) do
    if child.visible then
      local cw = child:width()
      w = self.row and w + cw or math.max(w, cw)
    end
  end
  if self.row then w = w + math.max(0, child_count(self) - 1) * px(self.gap) end
  return w + left + right
end

function Flex:content_height(w)
  local top, right, bottom, left = padding(self)
  local inner = w - left - right
  local h = 0
  if self.row then
    resolve(self, inner)
    for i, child in ipairs(self.children) do
      if child.visible then h = math.max(h, child:height(math.floor(self.sizes[i]))) end
    end
  else
    for _, child in ipairs(self.children) do
      if child.visible then h = h + child:height(column_child_width(self, child, inner)) end
    end
    h = h + math.max(0, child_count(self) - 1) * px(self.gap)
  end
  return h + top + bottom
end

-- The offset of a child of size `size` in `space`, for `align`.
local function aligned(align, space, size)
  if align == "end" then return space - size end
  if align == "center" then return math.floor((space - size) / 2) end
  return 0
end

function Flex:place(x, y, w, h)
  Flex.super.place(self, x, y, w, h)
  local top, right, bottom, left = padding(self)
  local inner_w, inner_h = w - left - right, h - top - bottom
  local free, count = resolve(self, self.row and inner_w or inner_h, inner_w)
  local gap = px(self.gap)
  local pos = 0
  free = math.max(0, free)
  if self.justify == "end" then
    pos = free
  elseif self.justify == "center" then
    pos = math.floor(free / 2)
  elseif self.justify == "between" and count > 1 then
    gap = gap + free / (count - 1)
  end
  for i, child in ipairs(self.children) do
    if child.visible then
      -- Whole pixels: each child starts where the one before it ended, so no gap opens between them.
      local start, finish = math.floor(pos + 0.5), math.floor(pos + self.sizes[i] + 0.5)
      local size = finish - start
      if self.row then
        local low, high = child:height_limits()
        local ch = clamp(self.align == "stretch" and inner_h or math.min(inner_h, child:height(size)), low, high)
        child:place(x + left + start, y + top + aligned(self.align, inner_h, ch), size, ch)
      else
        local cw = column_child_width(self, child, inner_w)
        child:place(x + left + aligned(self.align, inner_w, cw), y + top + start, cw, size)
      end
      pos = pos + self.sizes[i] + gap
    end
  end
end

local Row = Flex:extend()
layout.Row = Row
Row.row = true
Row.default_gap = 8
Row.default_align = "center"

local Column = Flex:extend()
layout.Column = Column
Column.row = false
Column.default_gap = 16
Column.default_align = "stretch"

------------------------------------------------------------------------------------------------------------------
-- Text: wrapped text in a text role, such as "title", "label" or "description".

local Text = Node:extend()
layout.Text = Text

---Break `text` into lines that fit `width`, at spaces. `lines` takes the result.
local function wrap(font, text, width, lines)
  for i = #lines, 1, -1 do lines[i] = nil end
  for paragraph in (text .. "\n"):gmatch("(.-)\n") do
    local line = ""
    for word in paragraph:gmatch("%S+") do
      local candidate = line == "" and word or line .. " " .. word
      if line ~= "" and font:get_width(candidate) > width then
        lines[#lines + 1] = line
        line = word
      else
        line = candidate
      end
    end
    lines[#lines + 1] = line
  end
  return lines
end

---@param options { text: string, role: string?, color: table?, wrap: boolean?, align: string? }
function Text:new(options)
  Text.super.new(self, options)
  self.text = options.text or ""
  self.role = options.role or "body"
  self.color = options.color
  self.wraps = options.wrap ~= false
  self.align = options.align or "left"
  self.lines = {}
end

function Text:set_text(text)
  if text ~= self.text then
    self.text = text
    self.wrap_key = nil
    core.redraw = true
  end
end

function Text:lines_for(w)
  local font = ui.role_font(self.role)
  -- Zoom changes a font's size in place, so the size is part of the key.
  local size = font:get_size()
  if self.wrap_key ~= w or self.wrap_font ~= font or self.wrap_size ~= size or self.wrap_text ~= self.text then
    self.wrap_key, self.wrap_font, self.wrap_size, self.wrap_text = w, font, size, self.text
    if self.wraps then
      wrap(font, self.text, w, self.lines)
    else
      self.lines[1] = self.text
      for i = #self.lines, 2, -1 do self.lines[i] = nil end
    end
  end
  return self.lines, font
end

function Text:content_width()
  local font, widest = ui.role_font(self.role), 0
  for line in (self.text .. "\n"):gmatch("(.-)\n") do widest = math.max(widest, font:get_width(line)) end
  return math.ceil(widest)
end

function Text:content_height(w)
  local lines, font = self:lines_for(w)
  return #lines * font:get_height()
end

function Text:draw_node()
  local lines, font = self:lines_for(self.w)
  local color = self.color or ui.role_color(self.role)
  local line_h = font:get_height()
  for i, line in ipairs(lines) do
    local text = self.wraps and line or ui.fit_text(font, line, self.w)
    common.draw_text(font, color, text, self.align, self.x, self.y + (i - 1) * line_h, self.w, line_h)
  end
end

------------------------------------------------------------------------------------------------------------------
-- Field: a title and an optional description, with a control at the right, as in a settings row.
-- `stacked = true` puts the control below the text at the full width, for a text field.

local Field = Node:extend()
layout.Field = Field

---@param options { title: string, description: string?, control: table?, stacked: boolean? }
function Field:new(options)
  Field.super.new(self, options)
  self.title = Text { text = options.title or "", role = "label" }
  self.description = options.description and Text { text = options.description, role = "description" }
  self.control = options.control
  self.stacked = options.stacked
end

local function text_height(self, w)
  local h = self.title:height(w)
  if self.description then h = h + ui.metrics().text_gap + self.description:height(w) end
  return h
end

local function control_width(self, w)
  return math.min(math.floor(w * 0.6), self.control:width())
end

function Field:content_width()
  local w = math.max(self.title:width(), self.description and self.description:width() or 0)
  if self.control then
    w = self.stacked and math.max(w, self.control:width()) or w + px(24) + self.control:width()
  end
  return w
end

function Field:content_height(w)
  local control = self.control and self.control.visible and self.control
  if not control then return text_height(self, w) end
  if self.stacked then return text_height(self, w) + px(8) + control:height(w) end
  local cw = control_width(self, w)
  return math.max(text_height(self, w - cw - px(24)), control:height(cw))
end

function Field:place(x, y, w, h)
  Field.super.place(self, x, y, w, h)
  local control = self.control and self.control.visible and self.control
  local tw = w
  if control and not self.stacked then tw = w - control_width(self, w) - px(24) end
  local th = text_height(self, tw)
  local ty = (control and not self.stacked) and y + math.floor((h - th) / 2) or y
  local title_h = self.title:height(tw)
  self.title:place(x, ty, tw, title_h)
  if self.description then
    local gap = ui.metrics().text_gap
    self.description:place(x, ty + title_h + gap, tw, self.description:height(tw))
  end
  if control then
    if self.stacked then
      control:place(x, y + th + px(8), w, control:height(w))
    else
      local cw = control_width(self, w)
      local ch = control:height(cw)
      control:place(x + w - cw, y + math.floor((h - ch) / 2), cw, ch)
    end
  end
end

function Field:draw_node(dialog)
  self.title:draw_node(dialog)
  if self.description then self.description:draw_node(dialog) end
  if self.control and self.control.visible then self.control:draw_node(dialog) end
end

function Field:collect(list)
  if self.control and self.control.visible then self.control:collect(list) end
end

------------------------------------------------------------------------------------------------------------------
-- Group: rows on a card, with a line between rows, and an optional title above the card.

local Group = Node:extend()
layout.Group = Group

---@param options { title: string? }
function Group:new(options)
  Group.super.new(self, options)
  self.title = options.title and Text { text = options.title, role = "meta", wrap = false }
end

local function title_space(self, w)
  return self.title and self.title:height(w) + px(8) or 0
end

local function row_inner(w)
  return w - 2 * ui.metrics().row_pad_x
end

function Group:content_width()
  local widest = 0
  for _, child in ipairs(self.children) do
    if child.visible then widest = math.max(widest, child:width()) end
  end
  return widest + 2 * ui.metrics().row_pad_x
end

function Group:content_height(w)
  local m = ui.metrics()
  local h, count = title_space(self, w), 0
  for _, child in ipairs(self.children) do
    if child.visible then
      h, count = h + child:height(row_inner(w)) + 2 * m.row_pad_y, count + 1
    end
  end
  return h + math.max(0, count - 1) * m.border
end

function Group:place(x, y, w, h)
  Group.super.place(self, x, y, w, h)
  local m = ui.metrics()
  local cy = y
  if self.title then
    self.title:place(x + m.border, cy, w, self.title:height(w))
    cy = cy + title_space(self, w)
  end
  self.card_y = cy
  for _, child in ipairs(self.children) do
    if child.visible then
      local ch = child:height(row_inner(w))
      child:place(x + m.row_pad_x, cy + m.row_pad_y, row_inner(w), ch)
      cy = cy + ch + 2 * m.row_pad_y + m.border
    end
  end
end

function Group:draw_node(dialog)
  local m = ui.metrics()
  if self.title then self.title:draw_node(dialog) end
  local cy = self.card_y or self.y
  surface.draw("group", self.x, cy, self.w, self.y + self.h - cy, m.group_radius)
  local first = true
  for _, child in ipairs(self.children) do
    if child.visible then
      if not first then
        renderer.draw_rect(self.x + m.border, child.y - m.row_pad_y - m.border, self.w - 2 * m.border, m.border,
          style.dialog_line)
      end
      first = false
      child:draw_node(dialog)
    end
  end
end

------------------------------------------------------------------------------------------------------------------
-- Separator: a horizontal line. Spacer: empty space, with a fixed size or a grow weight.

local Separator = Node:extend()
layout.Separator = Separator

function Separator:content_height() return ui.metrics().border end

function Separator:draw_node()
  renderer.draw_rect(self.x, self.y, self.w, self.h, style.dialog_line)
end

local Spacer = Node:extend()
layout.Spacer = Spacer

------------------------------------------------------------------------------------------------------------------
-- Scroll: shows its child in its own height, and scrolls it with the wheel.
-- Controls outside the visible area do not take the pointer. A newly focused control scrolls into view.

local Scroll = Node:extend()
layout.Scroll = Scroll
Scroll.scrolls = true

-- Without a fixed `height` or a `max_height`, a Scroll is as tall as its child. Its child is at least as tall as
-- the Scroll, so the child's growing children can fill it.
function Scroll:new(options)
  Scroll.super.new(self, options)
  self.scroll, self.scroll_to = 0, 0
  self.content_h = 0
  -- Focus rings reach past the sides, so the clip does too.
  self.clip = { x = 0, y = 0, w = 0, h = 0 }
  self.controls = {}
end

-- The space above and below the child, for the focus rings of its first and last controls.
local function inset()
  local m = ui.metrics()
  return m.ring + m.border
end

function Scroll:child() return self.children[1] end

-- The child, when it is visible.
local function shown(self)
  local child = self.children[1]
  return child.visible and child
end

function Scroll:content_width()
  local child = shown(self)
  return child and child:width() or 0
end

function Scroll:content_height(w)
  local child = shown(self)
  return child and child:height(w) + 2 * inset() or 0
end

---Replace the child, and scroll to its top.
function Scroll:set_child(child)
  self.children[1] = child
  self:reset()
  core.redraw = true
end

function Scroll:max_scroll()
  return math.max(0, self.content_h - self.h)
end

---Scroll to the top, without a glide.
function Scroll:reset()
  self.scroll, self.scroll_to = 0, 0
end

local function intersect(a, b, out)
  if not a then
    out.x, out.y, out.w, out.h = b.x, b.y, b.w, b.h
    return out
  end
  local x1, y1 = math.max(a.x, b.x), math.max(a.y, b.y)
  local x2, y2 = math.min(a.x + a.w, b.x + b.w), math.min(a.y + a.h, b.y + b.h)
  out.x, out.y, out.w, out.h = x1, y1, math.max(0, x2 - x1), math.max(0, y2 - y1)
  return out
end

local function reveal(self, focused)
  if not focused or focused == self.revealed then return end
  self.revealed = focused
  local found = false
  for _, control in ipairs(self.controls) do
    if control == focused then found = true end
  end
  if not found then return end
  local margin = px(12)
  local top = focused.y - (self.y - self.scroll)
  if top - margin < self.scroll_to then
    self.scroll_to = top - margin
  elseif top + focused.h + margin > self.scroll_to + self.h then
    self.scroll_to = top + focused.h + margin - self.h
  end
end

function Scroll:place(x, y, w, h)
  Scroll.super.place(self, x, y, w, h)
  local controls = self.controls
  local child = shown(self)
  if not child then
    self.content_h, self.scroll, self.scroll_to = 0, 0, 0
    for i = #controls, 1, -1 do controls[i] = nil end
    return
  end
  local pad = inset()
  local child_h = math.max(child:height(w), h - 2 * pad)
  self.content_h = child_h + 2 * pad
  self.scroll_to = math.max(0, math.min(self.scroll_to, self:max_scroll()))
  reveal(self, ui.layout_focus)
  self.scroll_to = math.max(0, math.min(self.scroll_to, self:max_scroll()))
  self.scroll = math.max(0, math.min(ui.approach(self, "scroll", self.scroll_to, 24), self:max_scroll()))
  -- The clip takes focus rings at the sides, and the scroll bar at the right.
  local outer = ui.layout_clip
  self.clip_area = self.clip_area or {}
  local area = self.clip_area
  area.x, area.y, area.w, area.h = x - pad, y, w + pad + px(12), h
  ui.layout_clip = intersect(outer, area, self.clip)
  child:place(x, y + pad - math.floor(self.scroll + 0.5), w, child_h)
  ui.layout_clip = outer
  -- reveal() reads the controls of the last place, so they change only here.
  for i = #controls, 1, -1 do controls[i] = nil end
  child:collect(controls)
end

function Scroll:draw_node(dialog)
  local clip = self.clip
  local child = shown(self)
  if not child then return end
  core.push_clip_rect(clip.x, clip.y, clip.w, clip.h)
  child:draw_node(dialog)
  local max = self:max_scroll()
  if max > 0 then
    local bar_w = px(4)
    local thumb_h = math.max(px(24), self.h * self.h / self.content_h)
    local thumb_y = self.y + (self.h - thumb_h) * (self.scroll / max)
    renderer.draw_rounded_rect(self.x + self.w + px(6), thumb_y, bar_w, thumb_h, bar_w / 2,
      ui.fade(style.dialog_text_dim, 0.6))
  end
  core.pop_clip_rect()
end

function Scroll:on_wheel(x, y, dy)
  local child = shown(self)
  if not child then return false end
  if child.on_wheel and child:on_wheel(x, y, dy) then return true end
  if self:max_scroll() <= 0 then return false end
  self.scroll_to = math.max(0, math.min(self.scroll_to - dy * config.mouse_wheel_scroll, self:max_scroll()))
  core.redraw = true
  return true
end

layout.px = px

return layout
