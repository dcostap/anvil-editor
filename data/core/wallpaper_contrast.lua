-- Estimate how much of the wallpaper remains visible against a theme color.
local contrast = {}

local BLACK_FLOOR = 24 -- Dim display tones lose detail near black.
local MIN_VISIBILITY, MAX_VISIBILITY = 0.02, 0.14 -- Limit color noise behind text.

local function linear_channel(value)
  local channel = math.max(BLACK_FLOOR, value) / 255
  if channel <= 0.04045 then return channel / 12.92 end
  return ((channel + 0.055) / 1.055) ^ 2.4
end

local function lightness(image_color, background, visibility)
  local opacity = 1 - visibility
  local r = linear_channel(background[1] * opacity + image_color[1] * visibility)
  local g = linear_channel(background[2] * opacity + image_color[2] * visibility)
  local b = linear_channel(background[3] * opacity + image_color[3] * visibility)
  local l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ^ (1 / 3)
  local m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ^ (1 / 3)
  local s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ^ (1 / 3)
  return 0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s
end

function contrast.sample(image)
  -- Two representative tones suffice for a stable theme-level contrast target.
  local preview = image:scaled(24, 14, "linear")
  if not preview then return nil end
  local pixels = preview:get_pixels()
  local samples = {}
  for index = 1, #pixels, 4 do
    local r, g, b = pixels:byte(index, index + 2)
    samples[#samples + 1] = {
      r, g, b, brightness = 0.2126 * r + 0.7152 * g + 0.0722 * b,
    }
  end
  table.sort(samples, function(a, b) return a.brightness < b.brightness end)
  return samples[math.floor(#samples * 0.1)], samples[math.floor(#samples * 0.9)],
    samples[math.floor(#samples * 0.5)]
end

function contrast.visibility(low, high, middle_tone, background, reference, reference_visibility)
  if not low or not high then return reference_visibility end
  local function detail(color, visibility)
    return lightness(high, color, visibility) - lightness(low, color, visibility)
  end
  local target = detail(reference, reference_visibility)
  if target < 0.0001 then return reference_visibility end
  local minimum, maximum = MIN_VISIBILITY, MAX_VISIBILITY
  for _ = 1, 12 do
    local middle = (minimum + maximum) / 2
    if detail(background, middle) < target then
      minimum = middle
    else
      maximum = middle
    end
  end
  local visibility = (minimum + maximum) / 2
  -- A white surface can keep the image pale even when its tonal range matches.
  -- Move its middle tone away from the surface, with a limit for text clarity.
  local background_tone = 0.2126 * background[1] + 0.7152 * background[2]
    + 0.0722 * background[3]
  local light_fraction = math.min(1, math.max(0, (background_tone - 170) / 60))
  if light_fraction > 0 and middle_tone then
    local separation = math.abs(background_tone - middle_tone.brightness)
    visibility = math.max(visibility, light_fraction * 24 / math.max(1, separation))
  end
  return math.min(MAX_VISIBILITY, visibility)
end

return contrast
