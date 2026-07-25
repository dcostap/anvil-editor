local core = require "core"
local style = require "core.style"

local file_icons = {}

local function utf8_codepoint(codepoint)
  return string.char(
    0xE0 + math.floor(codepoint / 0x1000),
    0x80 + math.floor(codepoint / 0x40) % 0x40,
    0x80 + codepoint % 0x40
  )
end

local COLORS = {
  blue   = { dark = { 0x51, 0x9a, 0xba, 255 }, light = { 0x49, 0x8b, 0xa7, 255 } },
  red    = { dark = { 0xcc, 0x3e, 0x44, 255 }, light = { 0xb8, 0x38, 0x3d, 255 } },
  green  = { dark = { 0x8d, 0xc1, 0x49, 255 }, light = { 0x7f, 0xae, 0x42, 255 } },
  yellow = { dark = { 0xcb, 0xcb, 0x41, 255 }, light = { 0xb7, 0xb7, 0x3b, 255 } },
  orange = { dark = { 0xe3, 0x79, 0x33, 255 }, light = { 0xcc, 0x6d, 0x2e, 255 } },
  pink   = { dark = { 0xf5, 0x53, 0x85, 255 }, light = { 0xdd, 0x4b, 0x78, 255 } },
  purple = { dark = { 0xa0, 0x74, 0xc4, 255 }, light = { 0x90, 0x68, 0xb0, 255 } },
  gray   = { dark = { 0x6d, 0x80, 0x86, 255 }, light = { 0x62, 0x73, 0x79, 255 } },
  white  = { dark = { 0xd4, 0xd7, 0xd6, 255 }, light = { 0xbf, 0xc2, 0xc1, 255 } },
  dark   = { dark = { 0x41, 0x53, 0x5b, 255 }, light = { 0x3b, 0x4b, 0x52, 255 } },
}

local function icon(codepoint, color)
  return { glyph = utf8_codepoint(codepoint), color = color }
end

local ICONS = {
  asm = icon(0xE004, "red"),
  audio = icon(0xE005, "purple"),
  bazel = icon(0xE007, "green"),
  c_sharp = icon(0xE00B, "blue"),
  c = icon(0xE00C, "blue"),
  clock = icon(0xE012, "blue"),
  clojure = icon(0xE013, "green"),
  coffee = icon(0xE016, "yellow"),
  config = icon(0xE019, "gray"),
  cpp = icon(0xE01A, "blue"),
  css = icon(0xE01D, "blue"),
  csv = icon(0xE01E, "green"),
  dart = icon(0xE021, "blue"),
  db = icon(0xE022, "pink"),
  default = icon(0xE023, "white"),
  docker = icon(0xE025, "blue"),
  elixir = icon(0xE028, "purple"),
  elm = icon(0xE02A, "blue"),
  eslint = icon(0xE02C, "purple"),
  f_sharp = icon(0xE02E, "blue"),
  font = icon(0xE033, "red"),
  git = icon(0xE034, "dark"),
  go = icon(0xE03A, "blue"),
  graphql = icon(0xE03E, "pink"),
  haskell = icon(0xE044, "purple"),
  html = icon(0xE048, "orange"),
  image = icon(0xE04C, "purple"),
  info = icon(0xE04D, "blue"),
  java = icon(0xE050, "red"),
  javascript = icon(0xE051, "yellow"),
  json = icon(0xE055, "yellow"),
  julia = icon(0xE056, "purple"),
  kotlin = icon(0xE058, "orange"),
  less = icon(0xE059, "blue"),
  license = icon(0xE05A, "yellow"),
  lock = icon(0xE05D, "green"),
  lua = icon(0xE05E, "blue"),
  makefile = icon(0xE05F, "orange"),
  markdown = icon(0xE060, "blue"),
  maven = icon(0xE061, "red"),
  notebook = icon(0xE066, "blue"),
  npm = icon(0xE067, "red"),
  ocaml = icon(0xE06A, "orange"),
  pdf = icon(0xE06D, "red"),
  perl = icon(0xE06E, "blue"),
  php = icon(0xE070, "purple"),
  powershell = icon(0xE074, "blue"),
  python = icon(0xE07B, "blue"),
  react = icon(0xE07D, "blue"),
  ruby = icon(0xE081, "red"),
  rust = icon(0xE082, "gray"),
  sass = icon(0xE084, "pink"),
  scala = icon(0xE086, "red"),
  shell = icon(0xE089, "green"),
  svelte = icon(0xE090, "red"),
  svg = icon(0xE091, "purple"),
  swift = icon(0xE092, "orange"),
  terraform = icon(0xE093, "purple"),
  tex = icon(0xE094, "blue"),
  tsconfig = icon(0xE097, "blue"),
  typescript = icon(0xE099, "blue"),
  video = icon(0xE09B, "pink"),
  vue = icon(0xE09C, "green"),
  wasm = icon(0xE09D, "purple"),
  windows = icon(0xE0A1, "blue"),
  word = icon(0xE0A2, "blue"),
  xls = icon(0xE0A3, "green"),
  xml = icon(0xE0A4, "orange"),
  yml = icon(0xE0A6, "purple"),
  zig = icon(0xE0A7, "orange"),
  zip = icon(0xE0A8, "red"),
}

local EXTENSIONS = {
  c = "c", h = "c",
  cc = "cpp", cpp = "cpp", cxx = "cpp", hh = "cpp", hpp = "cpp", hxx = "cpp",
  cs = "c_sharp", fs = "f_sharp", fsx = "f_sharp",
  lua = "lua", py = "python", pyw = "python",
  js = "javascript", mjs = "javascript", cjs = "javascript",
  ts = "typescript", mts = "typescript", cts = "typescript", jsx = "react", tsx = "react",
  json = "json", jsonc = "json", jsonl = "json", ipynb = "notebook",
  md = "markdown", markdown = "markdown", mdx = "markdown",
  html = "html", htm = "html", xhtml = "html",
  css = "css", less = "less", scss = "sass", sass = "sass",
  rs = "rust", go = "go", java = "java", kt = "kotlin", kts = "kotlin",
  rb = "ruby", php = "php", pl = "perl", pm = "perl", scala = "scala",
  swift = "swift", dart = "dart", zig = "zig", ml = "ocaml", mli = "ocaml",
  ex = "elixir", exs = "elixir", elm = "elm", clj = "clojure", cljs = "clojure",
  hs = "haskell", lhs = "haskell", jl = "julia", coffee = "coffee",
  sh = "shell", bash = "shell", zsh = "shell", fish = "shell",
  ps1 = "powershell", psm1 = "powershell", psd1 = "powershell",
  bat = "windows", cmd = "windows",
  yml = "yml", yaml = "yml", toml = "config", ini = "config", cfg = "config",
  conf = "config", config = "config", properties = "config", env = "config",
  xml = "xml", xsd = "xml", xsl = "xml", xslt = "xml",
  sql = "db", sqlite = "db", db = "db",
  graphql = "graphql", gql = "graphql", tf = "terraform", tfvars = "terraform",
  dockerfile = "docker", bazel = "bazel", bzl = "bazel", asm = "asm", s = "asm",
  tex = "tex", latex = "tex",
  png = "image", jpg = "image", jpeg = "image", gif = "image", webp = "image",
  bmp = "image", ico = "image", avif = "image", tiff = "image", tif = "image",
  svg = "svg", pdf = "pdf",
  mp3 = "audio", wav = "audio", flac = "audio", ogg = "audio",
  mp4 = "video", mov = "video", avi = "video", webm = "video", mpg = "video", mpeg = "video",
  zip = "zip", rar = "zip", ["7z"] = "zip", gz = "zip", bz2 = "zip", xz = "zip", tar = "zip",
  ttf = "font", otf = "font", woff = "font", woff2 = "font", eot = "font",
  csv = "csv", xls = "xls", xlsx = "xls", doc = "word", docx = "word",
  wasm = "wasm", vue = "vue", svelte = "svelte",
  lock = "lock",
}

local FILENAMES = {
  ["readme"] = "info", ["readme.md"] = "info", ["readme.txt"] = "info",
  ["changelog"] = "clock", ["changelog.md"] = "clock", ["changelog.txt"] = "clock",
  ["changes"] = "clock", ["changes.md"] = "clock", ["changes.txt"] = "clock",
  ["license"] = "license", ["license.md"] = "license", ["license.txt"] = "license",
  ["licence"] = "license", ["licence.md"] = "license", ["licence.txt"] = "license",
  ["copying"] = "license", ["copying.md"] = "license", ["copying.txt"] = "license",
  ["makefile"] = "makefile", ["gnumakefile"] = "makefile", ["cmakelists.txt"] = "makefile",
  ["dockerfile"] = "docker", ["docker-compose.yml"] = "docker", ["docker-compose.yaml"] = "docker",
  ["package.json"] = "npm", ["package-lock.json"] = "npm", ["npm-shrinkwrap.json"] = "npm",
  ["tsconfig.json"] = "tsconfig", ["jsconfig.json"] = "tsconfig",
  ["pom.xml"] = "maven",
  [".gitignore"] = "git", [".gitattributes"] = "git", [".gitmodules"] = "git", [".gitconfig"] = "git",
  [".eslintrc"] = "eslint", [".eslintignore"] = "eslint",
  [".env"] = "config", [".editorconfig"] = "config",
}

local font_cache = {}
local font_failures = {}

local function basename(path)
  return tostring(path or ""):match("[^/\\]+$") or tostring(path or "")
end

local function dark_theme()
  local background = style.background
  if type(background) == "table" and type(background[1]) == "table" then background = background[1] end
  if type(background) ~= "table" then return true end
  local r = tonumber(background[1]) or 0
  local g = tonumber(background[2]) or 0
  local b = tonumber(background[3]) or 0
  return r * 0.2126 + g * 0.7152 + b * 0.0722 < 145
end

function file_icons.resolve(path, is_directory)
  if is_directory then return nil end
  local name = basename(path):lower()
  local resolved = FILENAMES[name]
  if resolved then return resolved end

  if name:match("%.(spec|test)%.tsx?$") then return "react" end
  if name:match("%.(spec|test)%.jsx?$") then return "javascript" end
  local extension = name:match("%.([^%.]+)$")
  return EXTENSIONS[extension] or "default"
end

function file_icons.size_for_row(row_height)
  local scale = SCALE or 1
  local desired = math.max(1, math.floor(16 * scale + 0.5))
  if row_height then
    desired = math.min(desired, math.max(1, math.floor(row_height - math.max(2, 2 * scale))))
  end
  return desired
end

function file_icons.column_width(row_height, size)
  size = size or file_icons.size_for_row(row_height)
  return size + 4 * (SCALE or 1)
end

local function get_font(size)
  local key = tostring(size)
  if font_cache[key] then return font_cache[key] end
  if font_failures[key] then return nil, font_failures[key] end
  local path = DATADIR .. PATHSEP .. "icons" .. PATHSEP .. "file_types" .. PATHSEP .. "seti.ttf"
  local ok, font_or_error = pcall(renderer.font.load, path, size, {
    antialiasing = "grayscale",
    hinting = "full",
  })
  if not ok or not font_or_error then
    local err = tostring(font_or_error or "could not load Seti font")
    font_failures[key] = err
    core.log_quiet("File icon font load failed path=%s size=%d: %s", path, size, err)
    return nil, err
  end
  font_cache[key] = font_or_error
  return font_or_error
end

function file_icons.get(path, size, is_directory)
  local name = file_icons.resolve(path, is_directory)
  local definition = name and ICONS[name]
  if not definition then return nil, nil, nil, name end
  size = math.max(1, math.floor(tonumber(size) or file_icons.size_for_row()))
  local font, err = get_font(size)
  if not font then return nil, nil, nil, name, err end
  local variant = dark_theme() and "dark" or "light"
  return font, definition.glyph, COLORS[definition.color][variant], name
end

function file_icons.draw(path, x, y, row_height, size, is_directory)
  size = size or file_icons.size_for_row(row_height)
  -- Seti's glyph artwork occupies only part of each font em. VS Code renders
  -- the font at 150%; do the same, capped close to the row height so adjacent
  -- rows cannot collide.
  local scale = SCALE or 1
  local render_size = math.floor(size * 1.5 + 0.5)
  if row_height then
    render_size = math.min(render_size, math.floor(row_height + 2 * scale))
  end
  local font, glyph, color = file_icons.get(path, render_size, is_directory)
  if not font then return false end
  local glyph_width = font:get_width(glyph)
  local draw_x = x + math.floor((size - glyph_width) / 2)
  local draw_y = y + math.floor(((row_height or size) - font:get_height()) / 2)
  renderer.draw_text(font, glyph, math.floor(draw_x), math.floor(draw_y), color)
  return true, file_icons.column_width(row_height, size)
end

function file_icons.reset_cache()
  font_cache = {}
  font_failures = {}
end

return file_icons
