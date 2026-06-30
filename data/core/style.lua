local common = require "core.common"
local style = {}

style.divider_size = common.round(1 * SCALE)
style.scrollbar_size = common.round(18 * SCALE)
style.expanded_scrollbar_size = common.round(36 * SCALE)
style.minimum_thumb_size = common.round(28 * SCALE)
style.contracted_scrollbar_margin = common.round(8 * SCALE)
style.expanded_scrollbar_margin = common.round(12 * SCALE)
style.scrollbar_resize_edge_guard = 0
style.scrollbar_end_padding = common.round(4 * SCALE)
style.caret_width = common.round(2 * SCALE)
style.tab_min_width = common.round(110 * SCALE)
style.tab_max_width = common.round(250 * SCALE)
style.tab_width = style.tab_min_width

style.padding = {
  x = common.round(14 * SCALE),
  y = common.round(7 * SCALE),
}

style.margin = {
  tab = {
    top = common.round(-style.divider_size * SCALE)
  }
}

-- The function renderer.font.load can accept an option table as a second optional argument.
-- It shoud be like the following:
--
-- {antialiasing= "grayscale", hinting = "full"}
--
-- The possible values for each option are:
-- - for antialiasing: grayscale, subpixel
-- - for hinting: none, slight, full
--
-- The defaults values are antialiasing subpixel and hinting slight for optimal visualization
-- on ordinary LCD monitor with RGB patterns.
--
-- On High DPI monitor or non RGB monitor you may consider using antialiasing grayscale instead.
-- The antialiasing grayscale with full hinting is interesting for crisp font rendering.
style.font = renderer.font.load(DATADIR .. "/fonts/FiraSans-Regular.ttf", 15 * SCALE)
style.big_font = style.font:copy(46 * SCALE)
style.icon_font = renderer.font.load(DATADIR .. "/fonts/icons.ttf", 16 * SCALE, {antialiasing="grayscale", hinting="full"})
style.icon_big_font = style.icon_font:copy(23 * SCALE)
style.code_font = renderer.font.load(DATADIR .. "/fonts/JetBrainsMono-Regular.ttf", 15 * SCALE)

local scaled_font_cache = {}

---Return a cached copy of a font at a specific size.
---@param font renderer.font
---@param size number
---@return renderer.font
function style.get_scaled_font(font, size)
  local key = tostring(font) .. ":" .. tostring(size)
  local cached = scaled_font_cache[key]
  if cached then return cached end
  local ok, scaled = pcall(function()
    return font:copy(size)
  end)
  scaled = ok and scaled or font
  scaled_font_cache[key] = scaled
  return scaled
end

---Return a cached font one scaled point smaller than the given font.
---@param font renderer.font
---@return renderer.font
function style.get_small_font(font)
  return style.get_scaled_font(font, math.max(8 * SCALE, font:get_size() - 1 * SCALE))
end

local syntax_fallback_mt = {}

function syntax_fallback_mt:__index(key)
  if type(key) ~= "string" then return nil end
  local parent = key:match("^(.*)%.[^%.]+$")
  while parent do
    local value = rawget(self, parent)
    if value ~= nil then return value end
    parent = parent:match("^(.*)%.[^%.]+$")
  end
end

function style.apply_syntax_fallbacks(syntax)
  return setmetatable(syntax or {}, syntax_fallback_mt)
end

style.syntax = style.apply_syntax_fallbacks({})

-- This can be used to override fonts per syntax group.
-- The syntax highlighter will take existing values from this table and
-- override style.code_font on a per-token basis, so you can choose to eg.
-- render comments in an italic font if you want to.
style.syntax_fonts = {}
-- style.syntax_fonts["comment"] = renderer.font.load(path_to_font, size_of_font, rendering_options)

style.log = {}

return style
