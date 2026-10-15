-- Fallback fonts for glyphs the bundled text fonts lack: emoji, symbols such as the braille spinners in
-- Terminal titles, and other scripts. The editor's fonts and the Project Sidebar's font group them after their
-- primary font.
local core = require "core"

local font_fallbacks = {}

-- The native renderer's FONT_FALLBACK_MAX. The primary font takes one slot.
local MAX_GROUP = 10

local candidates = {
  -- Keep color emoji early so broad Unicode fonts do not steal emoji glyphs.
  { "C:/Windows/Fonts/seguiemj.ttf" },
  -- Broad glyph coverage for the Unicode stress-test/general Windows installs.
  { "C:/Windows/Fonts/ARIALUNI.TTF" },
  -- Extra CJK/supplemental and common script coverage when Arial Unicode is absent/incomplete.
  { "C:/Windows/Fonts/YuGothR.ttc", "C:/Windows/Fonts/msgothic.ttc" },
  { "C:/Windows/Fonts/malgun.ttf" },
  { "C:/Windows/Fonts/seguisym.ttf" },
  { "C:/Windows/Fonts/segoeui.ttf", "C:/Windows/Fonts/NotoSans-Regular.ttf" },
  { "C:/Windows/Fonts/Nirmala.ttc" },
  { "C:/Windows/Fonts/LeelawUI.ttf" },
  -- These fill remaining slots on machines without some of the broader fonts above.
  { "C:/Windows/Fonts/NotoNaskhArabic-Regular.ttf", "C:/Windows/Fonts/NotoSansArabic-Regular.ttf" },
  { "C:/Windows/Fonts/NotoSansHebrew-Regular.ttf" },
  { "C:/Windows/Fonts/msjh.ttc", "C:/Windows/Fonts/mingliub.ttc" },
}

local function load_first(paths, size, fonts)
  for _, path in ipairs(paths) do
    if system.get_file_info(path) then
      local ok, font_or_error = pcall(renderer.font.load, path, size)
      if ok and font_or_error then
        fonts[#fonts + 1] = font_or_error
        core.log_quiet("Default font fallback loaded: %s", path)
        return
      end
      core.log_quiet("Default font fallback failed: %s (%s)", path, tostring(font_or_error))
    end
  end
end

---Loads the installed fallback fonts at `size`, as many as fit in a group after a primary font.
---@param size number
---@param role string names the fonts in the log
---@return renderer.font[]
function font_fallbacks.load(size, role)
  local fonts = {}
  for _, paths in ipairs(candidates) do
    if #fonts >= MAX_GROUP - 1 then break end
    load_first(paths, size, fonts)
  end
  core.log_quiet("Default %s font fallbacks loaded: %d", role, #fonts)
  return fonts
end

---Groups `primary` with fallbacks copied to its size.
---@param primary renderer.font
---@param fallbacks renderer.font[]
---@param options? table font options for the copies
---@return renderer.font
function font_fallbacks.group(primary, fallbacks, options)
  local size = primary:get_size()
  local fonts = { primary }
  for _, font in ipairs(fallbacks) do
    fonts[#fonts + 1] = options and font:copy(size, options)
      or (font:get_size() == size and font or font:copy(size))
  end
  return renderer.font.group(fonts)
end

return font_fallbacks
