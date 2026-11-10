local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local Object = require "core.object"
local ui = require "core.ui"
local surface = require "core.ui.surface"

-- Layout nodes place a Dialog's controls. Nodes and controls share these methods:
--   width()             the natural width, which a Row uses
--   height(w)           the height at width `w`
--   place(x, y, w, h)   take a rect, and place the children in it
--   draw_node(dialog)   draw. A control draws its focus ring when it has the Dialog's keyboard focus.
--   collect(list)       add the visible controls to `list`, in Tab order
--   on_wheel(x, y, dy)  scroll, for a node under the pointer. Returns true when it scrolled.
-- A container takes its children in the array part of its options: `layout.Column { gap = 8, a, b }`.
-- Gaps and widths in options are pixels at scale 1. A child with `grow = true` takes a Row's free width.
local layout = {}

local function px(value)
  return math.floor(value * SCALE + 0.5)
end

local Node = Object:extend()
layout.Node = Node

function Node:new(options)
  options = options or {}
  self.x, self.y, self.w, self.h = 0, 0, 0, 0
  self.visible = options.visible ~= false
  self.grow = options.grow
  self.children = {}
  for _, child in ipairs(options) do self.children[#self.children + 1] = child end
end

function Node:width() return 0 end
function Node:height() return 0 end

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
-- Column: children from the top down, each as wide as the column.

local Column = Node:extend()
layout.Column = Column

---@param options { gap: number? }
function Column:new(options)
  Column.super.new(self, options)
  self.gap = options.gap or 16
end

function Column:width()
  local widest = 0
  for _, child in ipairs(self.children) do
    if child.visible then widest = math.max(widest, child:width()) end
  end
  return widest
end

function Column:height(w)
  local h, count = 0, 0
  for _, child in ipairs(self.children) do
    if child.visible then
      h, count = h + child:height(w), count + 1
    end
  end
  return h + math.max(0, count - 1) * px(self.gap)
end

function Column:place(x, y, w, h)
  Column.super.place(self, x, y, w, h)
  local cy = y
  for _, child in ipairs(self.children) do
    if child.visible then
      local ch = child:height(w)
      child:place(x, cy, w, ch)
      cy = cy + ch + px(self.gap)
    end
  end
end

------------------------------------------------------------------------------------------------------------------
-- Row: children from left to right at their natural widths. `justify` places them along the row: "start", "end",
-- "center" or "between". `align` places each child in the row's height: "center", the default, or "start".

local Row = Node:extend()
layout.Row = Row

---@param options { gap: number?, justify: string?, align: string? }
function Row:new(options)
  Row.super.new(self, options)
  self.gap = options.gap or 8
  self.justify = options.justify or "start"
  self.align = options.align or "center"
  self.widths = {}
end

function Row:width()
  local w, count = 0, 0
  for _, child in ipairs(self.children) do
    if child.visible then w, count = w + child:width(), count + 1 end
  end
  return w + math.max(0, count - 1) * px(self.gap)
end

-- Fills self.widths with each visible child's width in `w`. Returns the free width and the child count.
local function row_widths(self, w)
  local widths, used, count, growing = self.widths, 0, 0, 0
  for i, child in ipairs(self.children) do
    if child.visible then
      widths[i] = child.grow and 0 or math.min(w, child:width())
      used, count = used + widths[i], count + 1
      if child.grow then growing = growing + 1 end
    end
  end
  local free = math.max(0, w - used - math.max(0, count - 1) * px(self.gap))
  if growing > 0 then
    for i, child in ipairs(self.children) do
      if child.visible and child.grow then widths[i] = math.floor(free / growing) end
    end
    free = 0
  end
  return free, count
end

function Row:height(w)
  row_widths(self, w)
  local h = 0
  for i, child in ipairs(self.children) do
    if child.visible then h = math.max(h, child:height(self.widths[i])) end
  end
  return h
end

function Row:place(x, y, w, h)
  Row.super.place(self, x, y, w, h)
  local free, count = row_widths(self, w)
  local gap = px(self.gap)
  local cx = x
  if self.justify == "end" then
    cx = x + free
  elseif self.justify == "center" then
    cx = x + math.floor(free / 2)
  elseif self.justify == "between" and count > 1 then
    gap = gap + free / (count - 1)
  end
  for i, child in ipairs(self.children) do
    if child.visible then
      local cw = self.widths[i]
      local ch = math.min(h, child:height(cw))
      local cy = self.align == "start" and y or y + math.floor((h - ch) / 2)
      child:place(math.floor(cx), cy, cw, ch)
      cx = cx + cw + gap
    end
  end
end

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
  if self.wrap_key ~= w or self.wrap_font ~= font or self.wrap_text ~= self.text then
    self.wrap_key, self.wrap_font, self.wrap_text = w, font, self.text
    if self.wraps then
      wrap(font, self.text, w, self.lines)
    else
      self.lines[1] = self.text
      for i = #self.lines, 2, -1 do self.lines[i] = nil end
    end
  end
  return self.lines, font
end

function Text:width()
  local font, widest = ui.role_font(self.role), 0
  for line in (self.text .. "\n"):gmatch("(.-)\n") do widest = math.max(widest, font:get_width(line)) end
  return math.ceil(widest)
end

function Text:height(w)
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

function Field:width()
  local w = math.max(self.title:width(), self.description and self.description:width() or 0)
  if self.control then
    w = self.stacked and math.max(w, self.control:width()) or w + px(24) + self.control:width()
  end
  return w
end

function Field:height(w)
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

function Group:width()
  local widest = 0
  for _, child in ipairs(self.children) do
    if child.visible then widest = math.max(widest, child:width()) end
  end
  return widest + 2 * ui.metrics().row_pad_x
end

function Group:height(w)
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
-- Separator: a horizontal line. Spacer: empty height.

local Separator = Node:extend()
layout.Separator = Separator

function Separator:height() return ui.metrics().border end

function Separator:draw_node()
  renderer.draw_rect(self.x, self.y, self.w, self.h, style.dialog_line)
end

local Spacer = Node:extend()
layout.Spacer = Spacer

---@param options { height: number }
function Spacer:new(options)
  Spacer.super.new(self, options)
  self.size = options.height or 0
end

function Spacer:height() return px(self.size) end

------------------------------------------------------------------------------------------------------------------
-- Scroll: shows its child in its own height, and scrolls it with the wheel.
-- Controls outside the visible area do not take the pointer. A newly focused control scrolls into view.

local Scroll = Node:extend()
layout.Scroll = Scroll
Scroll.scrolls = true

---@param options { height: number? } A fixed height, at scale 1. Without it, the child's height.
function Scroll:new(options)
  Scroll.super.new(self, options)
  self.fixed_h = options.height
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
function Scroll:width() return self:child():width() end
function Scroll:height(w)
  if self.fixed_h then return px(self.fixed_h) end
  return self:child():height(w) + 2 * inset()
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
  local child = self:child()
  local pad = inset()
  local child_h = child:height(w)
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
  for i = #self.controls, 1, -1 do self.controls[i] = nil end
  child:collect(self.controls)
end

function Scroll:draw_node(dialog)
  local clip = self.clip
  core.push_clip_rect(clip.x, clip.y, clip.w, clip.h)
  self:child():draw_node(dialog)
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
  if self:child():on_wheel(x, y, dy) then return true end
  if self:max_scroll() <= 0 then return false end
  self.scroll_to = math.max(0, math.min(self.scroll_to - dy * config.mouse_wheel_scroll, self:max_scroll()))
  core.redraw = true
  return true
end

layout.px = px

return layout
