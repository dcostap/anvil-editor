-- Bundled font families for global Typography Roles.
local core = require "core"
local style = require "core.style"

local fonts = {}
local cache = setmetatable({}, {__mode = "k"})

local families = {
  caskaydia_cove = {name = "Caskaydia Cove Nerd Font Mono", regular = "CaskaydiaCoveNerdFontMono-Regular.ttf"},
  jetbrains_mono = {name = "JetBrains Mono", regular = "JetBrainsMono-Regular.ttf"},
  fira_sans = {name = "Fira Sans", regular = "FiraSans-Regular.ttf"},
  inter = {name = "Inter", regular = "Inter-Regular.ttf", strong = "Inter-SemiBold.ttf",
    emphasis = "Inter-Italic.ttf", strong_emphasis = "Inter-SemiBoldItalic.ttf"},
  crimson_pro = {name = "Crimson Pro", regular = "CrimsonPro-Regular.ttf", strong = "CrimsonPro-Bold.ttf",
    emphasis = "CrimsonPro-Italic.ttf", strong_emphasis = "CrimsonPro-SemiBoldItalic.ttf"},
  merriweather = {name = "Merriweather", regular = "Merriweather_24pt-SemiBold.ttf",
    emphasis = "Merriweather_24pt-SemiBoldItalic.ttf"},
  cormorant_garamond = {name = "Cormorant Garamond", regular = "CormorantGaramond-Medium.ttf",
    emphasis = "CormorantGaramond-MediumItalic.ttf"},
}

local categories = {
  {id = "interface", name = "Interface", roles = {"font"},
    choices = {"caskaydia_cove", "jetbrains_mono", "fira_sans", "inter", "crimson_pro"}},
  {id = "code", name = "Code", roles = {"code_font"},
    choices = {"caskaydia_cove", "jetbrains_mono"}},
  {id = "terminal", name = "Terminal", roles = {"terminal_font"},
    choices = {"caskaydia_cove", "jetbrains_mono"}},
  {id = "prose", name = "Prose", roles = {"prose_font", "markdown_body_font",
    "prose_strong_font", "prose_emphasis_font", "prose_strong_emphasis_font"},
    choices = {"crimson_pro", "inter", "fira_sans"}},
  {id = "headings", name = "Headings", roles = {"prose_heading_font", "prose_heading_emphasis_font", "big_font"},
    choices = {"cormorant_garamond", "merriweather", "crimson_pro", "inter", "fira_sans"}},
}

local function category_for(id)
  for _, category in ipairs(categories) do
    if category.id == id then return category end
  end
end

local function first_path(font)
  local path = font:get_path()
  return (type(path) == "table" and path[1] or path):gsub("\\", "/")
end

local function file_for(role, family)
  if role == "prose_strong_font" then return family.strong or family.regular, not family.strong, false end
  if role == "prose_emphasis_font" or role == "prose_heading_emphasis_font" then
    return family.emphasis or family.regular, false, not family.emphasis
  end
  if role == "prose_strong_emphasis_font" then
    return family.strong_emphasis or family.emphasis or family.strong or family.regular,
      not (family.strong_emphasis or family.strong), not (family.strong_emphasis or family.emphasis)
  end
  return family.regular, false, false
end

local function load_for(base, filename, bold, italic, ligatures)
  local size = base:get_size()
  local by_key = cache[base]
  if not by_key then by_key = {}; cache[base] = by_key end
  local key = table.concat({filename, tostring(bold), tostring(italic), tostring(ligatures), tostring(size)}, ":")
  if by_key[key] then return by_key[key] end
  local opts = {ligatures = ligatures, hinting = "full", bold = bold, italic = italic}
  local primary = renderer.font.load(DATADIR .. "/fonts/" .. filename, size, opts)
  local fallback = base:copy(size)
  if type(fallback) == "table" then
    fallback[1] = primary
  else
    fallback = renderer.font.group({primary, fallback})
  end
  by_key[key] = fallback
  return fallback
end

function fonts.categories()
  return categories
end

function fonts.choices(id)
  local category = category_for(id)
  if not category then return {} end
  local result = {}
  for _, choice in ipairs(category.choices) do
    result[#result + 1] = {id = choice, name = families[choice].name}
  end
  return result
end

function fonts.current(id)
  local category = category_for(id)
  if not category then return nil end
  local current = first_path(style[category.roles[1]])
  for _, choice in ipairs(category.choices) do
    local family = families[choice]
    if current:sub(-#family.regular) == family.regular then return choice end
  end
end

function fonts.apply(id, choice)
  local category, family = category_for(id), families[choice]
  if not category or not family then return false end
  local allowed = false
  for _, candidate in ipairs(category.choices) do
    if candidate == choice then allowed = true; break end
  end
  if not allowed then return false end

  for _, role in ipairs(category.roles) do
    local filename, bold, italic = file_for(role, family)
    style[role] = load_for(style[role], filename, bold, italic, id ~= "terminal")
  end
  if id == "terminal" then
    local size = style.terminal_font:get_size()
    local options = {ligatures = false, hinting = "full"}
    for _, variant in ipairs({"bold", "italic", "bold_italic"}) do
      options.bold = variant ~= "italic"
      options.italic = variant ~= "bold"
      style["terminal_" .. variant .. "_font"] = style.terminal_font:copy(size, options)
    end
  end
  core.color_theme_generation = (core.color_theme_generation or 0) + 1
  core.bump_render_style_generation("global-font-selection")
  core.log_quiet("Global %s font: %s", category.name, family.name)
  return true
end

return fonts
