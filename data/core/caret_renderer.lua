local CaretRenderer = {}
CaretRenderer.__index = CaretRenderer

local RELATIVE_CORNERS = {
  { -0.5, -0.5 },
  {  0.5, -0.5 },
  {  0.5,  0.5 },
  { -0.5,  0.5 },
}

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

local function destination(target, index)
  if index == 1 then return target.x, target.y end
  if index == 2 then return target.x + target.width, target.y end
  if index == 3 then return target.x + target.width, target.y + target.height end
  return target.x, target.y + target.height
end

local function reset_spring(corner, x, y)
  corner.x, corner.y = x, y
  corner.destination_x, corner.destination_y = x, y
  corner.offset_x, corner.offset_y = 0, 0
  corner.velocity_x, corner.velocity_y = 0, 0
  corner.animation_length = 0
end

local function update_spring(position, velocity, dt, animation_length)
  if animation_length <= dt or position == 0 then return 0, 0, false end
  local omega = 4 / animation_length
  local a = position
  local b = position * omega + velocity
  local decay = math.exp(-omega * dt)
  position = (a + b * dt) * decay
  velocity = decay * (-a * omega - b * dt * omega + b)
  if math.abs(position) < 0.01 then return 0, 0, false end
  return position, velocity, true
end

local function same_location(a, b)
  return a and b
    and a.owner == b.owner
    and a.line == b.line
    and a.col == b.col
end

local function same_shape(a, b)
  return a and b
    and a.x == b.x
    and a.y == b.y
    and a.width == b.width
    and a.height == b.height
end

function CaretRenderer.new()
  return setmetatable({ corners = {}, target = nil, previous_target = nil }, CaretRenderer)
end

function CaretRenderer:reset()
  self.corners = {}
  self.target = nil
  self.previous_target = nil
  self.last_time = nil
end

function CaretRenderer:begin_frame(enabled)
  self.target = nil
  if not enabled then self:reset() end
end

function CaretRenderer:submit(target)
  self.target = target
end

function CaretRenderer:reset_to_target(target)
  for index = 1, 4 do
    local x, y = destination(target, index)
    self.corners[index] = self.corners[index] or {}
    reset_spring(self.corners[index], x, y)
  end
  self.previous_target = target
end

function CaretRenderer:relocate(target)
  for index, corner in ipairs(self.corners) do
    local old_x, old_y = destination(self.previous_target, index)
    local new_x, new_y = destination(target, index)
    local dx, dy = new_x - old_x, new_y - old_y
    corner.x, corner.y = corner.x + dx, corner.y + dy
    corner.destination_x = corner.destination_x + dx
    corner.destination_y = corner.destination_y + dy
  end
  self.previous_target = target
end

function CaretRenderer:start_jump(target, animation_length, short_animation_length, trail_size)
  local alignments = {}
  local minimum, maximum = math.huge, -math.huge
  for index, corner in ipairs(self.corners) do
    local x, y = destination(target, index)
    local dx, dy = x - corner.destination_x, y - corner.destination_y
    local distance = math.sqrt(dx * dx + dy * dy)
    local direction_x = distance > 0 and dx / distance or 0
    local direction_y = distance > 0 and dy / distance or 0
    local relative = RELATIVE_CORNERS[index]
    local relative_length = math.sqrt(relative[1] * relative[1] + relative[2] * relative[2])
    local alignment = direction_x * relative[1] / relative_length
      + direction_y * relative[2] / relative_length
    alignments[index] = alignment
    minimum = math.min(minimum, alignment)
    maximum = math.max(maximum, alignment)
  end

  local range = maximum - minimum
  local old_target = self.previous_target
  local jump_x = target.x - old_target.x
  local jump_y = target.y - old_target.y
  local short_horizontal = math.abs(jump_x) <= 2.001 * math.max(1, target.cell_width or 1)
    and math.abs(jump_y) <= 0.001
  local leading = animation_length * (1 - clamp(trail_size, 0, 1))

  for index, corner in ipairs(self.corners) do
    local x, y = destination(target, index)
    local alignment = range > 0 and (alignments[index] - minimum) / range or 1
    corner.animation_length = short_horizontal
      and math.min(animation_length, short_animation_length)
      or animation_length + (leading - animation_length) * clamp(alignment, 0, 1)
    corner.offset_x = x - corner.x
    corner.offset_y = y - corner.y
    corner.destination_x, corner.destination_y = x, y
  end
  self.previous_target = target
end

local function snap_to_target_fraction(value, target_value)
  local fraction = target_value - math.floor(target_value)
  return math.floor(value - fraction + 0.5) + fraction
end

function CaretRenderer:draw(now, animation_length, short_animation_length, trail_size)
  local target = self.target
  if not target then return false end
  now = now or system.get_time()
  animation_length = math.max(0, animation_length or 0)
  short_animation_length = math.max(0, short_animation_length or animation_length)
  trail_size = clamp(trail_size or 0, 0, 1)

  local jumped = false
  if #self.corners == 0 or not self.previous_target then
    self:reset_to_target(target)
  elseif not same_shape(self.previous_target, target) then
    if same_location(self.previous_target, target) then
      self:relocate(target)
    else
      self:start_jump(target, animation_length, short_animation_length, trail_size)
      jumped = true
    end
  end

  local dt = self.last_time and clamp(now - self.last_time, 0, 1 / 30) or 0
  if jumped then dt = math.min(dt, 1 / 60) end
  self.last_time = now
  local animating = false
  local points = {}
  for index, corner in ipairs(self.corners) do
    local x_animating, y_animating
    corner.offset_x, corner.velocity_x, x_animating = update_spring(
      corner.offset_x, corner.velocity_x, dt, corner.animation_length
    )
    corner.offset_y, corner.velocity_y, y_animating = update_spring(
      corner.offset_y, corner.velocity_y, dt, corner.animation_length
    )
    corner.x = corner.destination_x - corner.offset_x
    corner.y = corner.destination_y - corner.offset_y
    animating = animating or x_animating or y_animating
    local target_x, target_y = destination(target, index)
    points[index] = {
      snap_to_target_fraction(corner.x, target_x),
      snap_to_target_fraction(corner.y, target_y),
    }
  end

  renderer.draw_poly(points, target.color)
  return animating
end

return CaretRenderer
