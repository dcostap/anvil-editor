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

-- Every file-oriented glyph in the pinned Seti font. UI-only glyphs such as
-- checkboxes and search controls are intentionally omitted.
local ICONS = {
  r = icon(0xE001, "blue"),
  argdown = icon(0xE003, "blue"),
  asm = icon(0xE004, "red"),
  audio = icon(0xE005, "purple"),
  babel = icon(0xE006, "yellow"),
  bazel = icon(0xE007, "green"),
  bicep = icon(0xE008, "blue"),
  bower = icon(0xE009, "orange"),
  bsl = icon(0xE00A, "red"),
  c_sharp = icon(0xE00B, "blue"),
  c = icon(0xE00C, "blue"),
  cake = icon(0xE00D, "red"),
  cake_php = icon(0xE00E, "red"),
  clock = icon(0xE012, "blue"),
  clojure = icon(0xE013, "green"),
  code_climate = icon(0xE014, "green"),
  code_search = icon(0xE015, "purple"),
  coffee = icon(0xE016, "yellow"),
  coldfusion = icon(0xE018, "blue"),
  config = icon(0xE019, "gray"),
  cpp = icon(0xE01A, "blue"),
  crystal = icon(0xE01B, "white"),
  crystal_embedded = icon(0xE01C, "white"),
  css = icon(0xE01D, "blue"),
  csv = icon(0xE01E, "green"),
  cu = icon(0xE01F, "green"),
  d = icon(0xE020, "red"),
  dart = icon(0xE021, "blue"),
  db = icon(0xE022, "pink"),
  default = icon(0xE023, "white"),
  docker = icon(0xE025, "blue"),
  editorconfig = icon(0xE026, "red"),
  ejs = icon(0xE027, "yellow"),
  elixir = icon(0xE028, "purple"),
  elixir_script = icon(0xE029, "purple"),
  elm = icon(0xE02A, "blue"),
  eslint = icon(0xE02C, "purple"),
  ethereum = icon(0xE02D, "blue"),
  f_sharp = icon(0xE02E, "blue"),
  favicon = icon(0xE02F, "yellow"),
  firebase = icon(0xE030, "orange"),
  firefox = icon(0xE031, "orange"),
  font = icon(0xE033, "red"),
  git = icon(0xE034, "dark"),
  github = icon(0xE037, "white"),
  gitlab = icon(0xE038, "orange"),
  go_legacy = icon(0xE039, "blue"),
  go = icon(0xE03A, "blue"),
  godot = icon(0xE03B, "blue"),
  gradle = icon(0xE03C, "blue"),
  grails = icon(0xE03D, "green"),
  graphql = icon(0xE03E, "pink"),
  grunt = icon(0xE03F, "orange"),
  gulp = icon(0xE040, "red"),
  hacklang = icon(0xE041, "orange"),
  haml = icon(0xE042, "red"),
  happenings = icon(0xE043, "blue"),
  haskell = icon(0xE044, "purple"),
  haxe = icon(0xE045, "orange"),
  heroku = icon(0xE046, "purple"),
  hex = icon(0xE047, "red"),
  html = icon(0xE048, "orange"),
  html_erb = icon(0xE049, "red"),
  ignored = icon(0xE04A, "dark"),
  illustrator = icon(0xE04B, "yellow"),
  image = icon(0xE04C, "purple"),
  info = icon(0xE04D, "blue"),
  ionic = icon(0xE04E, "blue"),
  jade = icon(0xE04F, "red"),
  java = icon(0xE050, "red"),
  javascript = icon(0xE051, "yellow"),
  jenkins = icon(0xE052, "red"),
  jinja = icon(0xE053, "red"),
  json = icon(0xE055, "yellow"),
  julia = icon(0xE056, "purple"),
  karma = icon(0xE057, "green"),
  kotlin = icon(0xE058, "orange"),
  less = icon(0xE059, "blue"),
  license = icon(0xE05A, "yellow"),
  liquid = icon(0xE05B, "green"),
  livescript = icon(0xE05C, "blue"),
  lock = icon(0xE05D, "green"),
  lua = icon(0xE05E, "blue"),
  makefile = icon(0xE05F, "orange"),
  markdown = icon(0xE060, "blue"),
  maven = icon(0xE061, "red"),
  mdo = icon(0xE062, "red"),
  mustache = icon(0xE063, "orange"),
  nim = icon(0xE065, "yellow"),
  notebook = icon(0xE066, "blue"),
  npm = icon(0xE067, "red"),
  npm_ignored = icon(0xE068, "dark"),
  nunjucks = icon(0xE069, "green"),
  ocaml = icon(0xE06A, "orange"),
  odata = icon(0xE06B, "orange"),
  pddl = icon(0xE06C, "purple"),
  pdf = icon(0xE06D, "red"),
  perl = icon(0xE06E, "blue"),
  photoshop = icon(0xE06F, "blue"),
  php = icon(0xE070, "purple"),
  pipeline = icon(0xE071, "orange"),
  plan = icon(0xE072, "green"),
  platformio = icon(0xE073, "orange"),
  powershell = icon(0xE074, "blue"),
  prisma = icon(0xE075, "blue"),
  prolog = icon(0xE077, "orange"),
  pug = icon(0xE078, "red"),
  puppet = icon(0xE079, "yellow"),
  purescript = icon(0xE07A, "white"),
  python = icon(0xE07B, "blue"),
  rails = icon(0xE07C, "red"),
  react = icon(0xE07D, "blue"),
  reasonml = icon(0xE07E, "red"),
  rescript = icon(0xE07F, "red"),
  rollup = icon(0xE080, "red"),
  ruby = icon(0xE081, "red"),
  rust = icon(0xE082, "gray"),
  salesforce = icon(0xE083, "blue"),
  sass = icon(0xE084, "pink"),
  sbt = icon(0xE085, "blue"),
  scala = icon(0xE086, "red"),
  shell = icon(0xE089, "green"),
  slim = icon(0xE08A, "orange"),
  smarty = icon(0xE08B, "yellow"),
  spring = icon(0xE08C, "green"),
  stylelint = icon(0xE08D, "white"),
  stylus = icon(0xE08E, "green"),
  sublime = icon(0xE08F, "orange"),
  svelte = icon(0xE090, "red"),
  svg = icon(0xE091, "purple"),
  swift = icon(0xE092, "orange"),
  terraform = icon(0xE093, "purple"),
  tex = icon(0xE094, "blue"),
  todo = icon(0xE096, "blue"),
  tsconfig = icon(0xE097, "blue"),
  twig = icon(0xE098, "green"),
  typescript = icon(0xE099, "blue"),
  vala = icon(0xE09A, "gray"),
  video = icon(0xE09B, "pink"),
  vue = icon(0xE09C, "green"),
  wasm = icon(0xE09D, "purple"),
  wat = icon(0xE09E, "purple"),
  webpack = icon(0xE09F, "blue"),
  wgt = icon(0xE0A0, "blue"),
  windows = icon(0xE0A1, "blue"),
  word = icon(0xE0A2, "blue"),
  xls = icon(0xE0A3, "green"),
  xml = icon(0xE0A4, "orange"),
  yarn = icon(0xE0A5, "blue"),
  yml = icon(0xE0A6, "purple"),
  zig = icon(0xE0A7, "orange"),
  zip = icon(0xE0A8, "red"),
}

-- Keys may be simple or compound extensions. The resolver checks longest
-- suffixes first, so names such as app.test.tsx and theme.css.map retain their
-- more specific associations.
local EXTENSIONS = {
  bsl = "bsl", mdo = "mdo", cls = "salesforce", apex = "salesforce",
  asm = "asm", s = "asm", bicep = "bicep",
  bzl = "bazel", bazel = "bazel", bazelignore = "bazel", bazelversion = "bazel",
  c = "c", h = "c", m = "c",
  cc = "cpp", cpp = "cpp", cxx = "cpp", ["c++"] = "cpp",
  hh = "cpp", hpp = "cpp", hxx = "cpp", ["h++"] = "cpp", mm = "cpp",
  ipp = "cpp", tpp = "cpp", inl = "cpp",
  cs = "c_sharp", csx = "c_sharp", cshtml = "html",
  aspx = "html", ascx = "html", asax = "html", master = "html",
  fs = "f_sharp", fsx = "f_sharp", fsi = "f_sharp",
  clj = "clojure", cljs = "clojure", cljc = "clojure", edn = "clojure",
  cfc = "coldfusion", cfm = "coldfusion",
  coffee = "coffee", litcoffee = "coffee",
  config = "config", cfg = "config", conf = "config", ini = "config",
  toml = "config", properties = "config", kdl = "config", nix = "config",
  direnv = "config", static = "config", slugignore = "config", htaccess = "config",
  editorconfig = "editorconfig", tmp = "clock",
  cr = "crystal", ecr = "crystal_embedded", slang = "crystal_embedded",
  cson = "json", json = "json", jsonc = "json", json5 = "json",
  jsonl = "json", geojson = "json", har = "json",
  css = "css", ["css.map"] = "css", sss = "css", pcss = "css", postcss = "css",
  csv = "csv", xls = "xls", xlsx = "xls", ods = "xls",
  cu = "cu", cuh = "cu", hu = "cu", cake = "cake", ctp = "cake_php", d = "d",
  buffer = "word", docx = "word", odt = "word", rtf = "word",
  ejs = "ejs", ex = "elixir", exs = "elixir_script", elm = "elm",
  ico = "favicon", gitignore = "git", gitconfig = "git", gitkeep = "git",
  gitattributes = "git", gitmodules = "git",
  go = "go", slide = "go_legacy", article = "go_legacy",
  gd = "godot", godot = "godot", tres = "godot", tscn = "godot",
  gradle = "gradle", groovy = "grails", gsp = "grails",
  gql = "graphql", graphql = "graphql", graphqls = "graphql",
  hack = "hacklang", haml = "haml", handlebars = "mustache", hbs = "mustache", hjs = "mustache",
  hs = "haskell", lhs = "haskell", hx = "haxe", hxs = "haxe", hxp = "haxe", hxml = "haxe",
  html = "html", htm = "html", xhtml = "html", shtml = "html", component = "html", astro = "html",
  jade = "jade", java = "java", class = "java", classpath = "java",
  js = "javascript", ["js.map"] = "javascript", cjs = "javascript", ["cjs.map"] = "javascript",
  mjs = "javascript", ["mjs.map"] = "javascript", es = "javascript", es5 = "javascript",
  es6 = "javascript", es7 = "javascript",
  ["spec.js"] = "javascript", ["spec.cjs"] = "javascript", ["spec.mjs"] = "javascript",
  ["test.js"] = "javascript", ["test.cjs"] = "javascript", ["test.mjs"] = "javascript",
  jsx = "react", cjsx = "react", tsx = "react",
  ["spec.jsx"] = "react", ["test.jsx"] = "react", ["spec.tsx"] = "react", ["test.tsx"] = "react",
  ts = "typescript", mts = "typescript", cts = "typescript",
  ["spec.ts"] = "typescript", ["test.ts"] = "typescript", ["d.ts"] = "typescript",
  jinja = "jinja", jinja2 = "jinja", jl = "julia", kt = "kotlin", kts = "kotlin",
  dart = "dart", less = "less", liquid = "liquid", ls = "livescript", lua = "lua",
  markdown = "markdown", md = "markdown", mdx = "markdown", mdown = "markdown", mkd = "markdown", mkdn = "markdown",
  argdown = "argdown", ad = "argdown", mustache = "mustache", stache = "mustache",
  nim = "nim", nims = "nim", ["github-issues"] = "github", ipynb = "notebook",
  njk = "nunjucks", nunjucks = "nunjucks", nunjs = "nunjucks", nunj = "nunjucks",
  njs = "nunjucks", nj = "nunjucks",
  ["npm-debug.log"] = "npm_ignored", npmignore = "npm", npmrc = "npm",
  ml = "ocaml", mli = "ocaml", cmx = "ocaml", cmxa = "ocaml", odata = "odata",
  pl = "perl", pm = "perl", php = "php", ["php.inc"] = "php", ["blade.php"] = "php",
  pipeline = "pipeline", pddl = "pddl", plan = "plan", happenings = "happenings",
  ps1 = "powershell", psd1 = "powershell", psm1 = "powershell", prisma = "prisma",
  pug = "pug", pp = "puppet", epp = "puppet", purs = "purescript",
  py = "python", pyw = "python", pyi = "python", pyx = "python", pxd = "python",
  re = "reasonml", res = "rescript", resi = "rescript", r = "r", rmd = "r",
  rb = "ruby", erb = "html_erb", ["erb.html"] = "html_erb", ["html.erb"] = "html_erb",
  rs = "rust", ron = "rust", sass = "sass", scss = "sass", springbeans = "spring",
  slim = "slim", ["smarty.tpl"] = "smarty", tpl = "smarty", sbt = "sbt", scala = "scala",
  sol = "ethereum", styl = "stylus", svelte = "svelte", swift = "swift",
  sql = "db", sqlite = "db", sqlite3 = "db", db = "db", db3 = "db", soql = "db",
  tf = "terraform", ["tf.json"] = "terraform", tfvars = "terraform", ["tfvars.json"] = "terraform",
  tex = "tex", latex = "tex", sty = "tex", dtx = "tex", ins = "tex", txt = "default",
  twig = "twig", vala = "vala", vapi = "vala", vue = "vue", wasm = "wasm", wat = "wat",
  xml = "xml", xsd = "xml", xsl = "xml", xslt = "xml", yml = "yml", yaml = "yml",
  pro = "prolog", zig = "zig", jar = "zip", war = "zip", ear = "zip",
  zip = "zip", rar = "zip", ["7z"] = "zip", gz = "zip", bz2 = "zip", xz = "zip",
  tar = "zip", tgz = "zip", tbz = "zip", tbz2 = "zip", apk = "zip", deb = "zip", rpm = "zip",
  wgt = "wgt", ai = "illustrator", psd = "photoshop", pdf = "pdf",
  eot = "font", ttf = "font", woff = "font", woff2 = "font", otf = "font",
  avif = "image", gif = "image", jpg = "image", jpeg = "image", png = "image",
  pxm = "image", svg = "svg", svgx = "image", tiff = "image", tif = "image",
  webp = "image", bmp = "image", heic = "image", heif = "image", raw = "image",
  ["sublime-project"] = "sublime", ["sublime-workspace"] = "sublime", ["code-search"] = "code_search",
  sh = "shell", bash = "shell", zsh = "shell", fish = "shell", zshrc = "shell", bashrc = "shell",
  mov = "video", ogv = "video", webm = "video", avi = "video", mpg = "video",
  mpeg = "video", mp4 = "video", mkv = "video", m4v = "video", wmv = "video",
  mp3 = "audio", ogg = "audio", wav = "audio", flac = "audio", m4a = "audio",
  aac = "audio", opus = "audio",
  ["3ds"] = "svg", ["3dm"] = "svg", stl = "svg", obj = "svg", dae = "svg",
  bat = "windows", cmd = "windows",
  key = "lock", cert = "lock", cer = "lock", crt = "lock", pem = "lock", lock = "lock",
}

local FILENAMES = {
  ["readme"] = "info", ["readme.md"] = "info", ["readme.txt"] = "info",
  ["changelog"] = "clock", ["changelog.md"] = "clock", ["changelog.txt"] = "clock",
  ["changes"] = "clock", ["changes.md"] = "clock", ["changes.txt"] = "clock",
  ["version"] = "clock", ["version.md"] = "clock", ["version.txt"] = "clock",
  ["license"] = "license", ["license.md"] = "license", ["license.txt"] = "license",
  ["licence"] = "license", ["licence.md"] = "license", ["licence.txt"] = "license",
  ["copying"] = "license", ["copying.md"] = "license", ["copying.txt"] = "license",
  ["compiling"] = "license", ["compiling.md"] = "license", ["compiling.txt"] = "license",
  ["contributing"] = "license", ["contributing.md"] = "license", ["contributing.txt"] = "license",
  ["todo"] = "todo", ["todo.md"] = "todo", ["todo.txt"] = "todo",
  ["makefile"] = "makefile", ["gnumakefile"] = "makefile", ["qmakefile"] = "makefile",
  ["omakefile"] = "makefile", ["cmakelists.txt"] = "makefile", ["makefile.am"] = "makefile",
  ["makefile.in"] = "makefile", ["cmakepresets.json"] = "makefile", ["cmakeuserpresets.json"] = "makefile",
  ["meson.build"] = "config", ["meson_options.txt"] = "config",
  ["dockerfile"] = "docker", ["containerfile"] = "docker", [".dockerignore"] = "docker",
  ["docker-healthcheck"] = "docker", ["docker-compose.yml"] = "docker",
  ["docker-compose.yaml"] = "docker", ["docker-compose.override.yml"] = "docker",
  ["docker-compose.override.yaml"] = "docker", ["compose.yml"] = "docker", ["compose.yaml"] = "docker",
  ["package.json"] = "npm", ["package-lock.json"] = "npm", ["npm-shrinkwrap.json"] = "npm",
  ["pnpm-lock.yaml"] = "npm", ["bun.lockb"] = "npm", ["npm-debug.log"] = "npm_ignored",
  ["yarn.lock"] = "yarn", ["yarn.clean"] = "yarn",
  ["bower.json"] = "bower", [".bowerrc"] = "bower",
  ["tsconfig.json"] = "tsconfig", ["jsconfig.json"] = "tsconfig", ["deno.json"] = "typescript",
  ["deno.jsonc"] = "typescript",
  ["cargo.toml"] = "rust", ["cargo.lock"] = "rust",
  ["go.mod"] = "go", ["go.sum"] = "go", ["go.work"] = "go",
  ["gemfile"] = "ruby", ["rakefile"] = "ruby", ["guardfile"] = "ruby", ["procfile"] = "heroku",
  ["pyproject.toml"] = "python", ["pipfile"] = "python", ["pipfile.lock"] = "python",
  ["requirements.txt"] = "python", ["setup.py"] = "python", ["tox.ini"] = "python",
  ["composer.json"] = "php", ["composer.lock"] = "php",
  ["mix.exs"] = "hex", ["mix.lock"] = "hex",
  ["pom.xml"] = "maven", ["mvnw"] = "maven",
  ["build.gradle"] = "gradle", ["settings.gradle"] = "gradle",
  ["build.gradle.kts"] = "gradle", ["settings.gradle.kts"] = "gradle", ["gradle.properties"] = "gradle",
  ["build"] = "bazel", ["build.bazel"] = "bazel", ["workspace"] = "bazel", ["workspace.bazel"] = "bazel",
  [".bazelrc"] = "bazel", ["jenkinsfile"] = "jenkins",
  ["karma.conf.js"] = "karma", ["karma.conf.cjs"] = "karma", ["karma.conf.mjs"] = "karma",
  ["karma.conf.coffee"] = "karma",
  ["gulpfile"] = "gulp", ["gulpfile.js"] = "gulp", ["gruntfile.js"] = "grunt",
  ["gruntfile.babel.js"] = "grunt", ["gruntfile.coffee"] = "grunt",
  ["webpack.config.js"] = "webpack", ["webpack.config.cjs"] = "webpack",
  ["webpack.config.mjs"] = "webpack", ["webpack.config.ts"] = "webpack",
  ["rollup.config.js"] = "rollup", ["rollup.config.cjs"] = "rollup",
  ["rollup.config.mjs"] = "rollup", ["rollup.config.ts"] = "rollup",
  ["babel.config.js"] = "babel", ["babel.config.cjs"] = "babel", ["babel.config.json"] = "babel",
  [".babelrc"] = "babel", [".babelrc.js"] = "babel", [".babelrc.cjs"] = "babel",
  [".eslintrc"] = "eslint", [".eslintrc.js"] = "eslint", [".eslintrc.cjs"] = "eslint",
  [".eslintrc.json"] = "eslint", [".eslintrc.yml"] = "eslint", [".eslintrc.yaml"] = "eslint",
  [".eslintignore"] = "eslint", ["eslint.config.js"] = "eslint", ["eslint.config.cjs"] = "eslint",
  ["eslint.config.mjs"] = "eslint",
  [".stylelintrc"] = "stylelint", [".stylelintrc.js"] = "stylelint", [".stylelintrc.json"] = "stylelint",
  [".stylelintrc.yml"] = "stylelint", [".stylelintrc.yaml"] = "stylelint",
  [".stylelintignore"] = "stylelint", ["stylelint.config.js"] = "stylelint",
  ["stylelint.config.cjs"] = "stylelint", ["stylelint.config.mjs"] = "stylelint",
  ["firebase.json"] = "firebase", [".firebaserc"] = "firebase", [".gitlab-ci.yml"] = "gitlab",
  [".codeclimate.yml"] = "code_climate", ["ionic.config.json"] = "ionic", ["ionic.project"] = "ionic",
  ["platformio.ini"] = "platformio", ["mime.types"] = "config", ["sass-lint.yml"] = "sass",
  ["swagger.json"] = "json", ["swagger.yml"] = "json", ["swagger.yaml"] = "json",
  [".gitignore"] = "git", [".gitattributes"] = "git", [".gitmodules"] = "git",
  [".gitconfig"] = "git", ["commit_editmsg"] = "git", ["merge_msg"] = "git",
  [".editorconfig"] = "editorconfig", [".prettierrc"] = "config", [".prettierignore"] = "config",
  [".env"] = "config", [".direnv"] = "config", [".htaccess"] = "config",
  [".clang-format"] = "config", [".clang-tidy"] = "config", [".clangd"] = "config",
  [".bashrc"] = "shell", [".zshrc"] = "shell", [".profile"] = "shell", [".bash_profile"] = "shell",
  [".jshintrc"] = "javascript", [".jscsrc"] = "javascript",
  ["geckodriver"] = "firefox", [".ds_store"] = "ignored",
}

local extension_order = {}
for extension in pairs(EXTENSIONS) do extension_order[#extension_order + 1] = extension end
table.sort(extension_order, function(a, b)
  if #a ~= #b then return #a > #b end
  return a < b
end)

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

local function resolve_name(path)
  local normalized = tostring(path or ""):lower():gsub("\\", "/")
  local name = basename(normalized)
  local resolved = FILENAMES[name]
  if resolved then return resolved end

  if name:match("^dockerfile[%.%_%-]") or name:match("^containerfile[%.%_%-]") then return "docker" end
  if name:match("^requirements.*%.txt$") then return "python" end
  if name:match("^%.env[%.%_%-]") then return "config" end
  if name:match("^webpack%..+%.([cm]?[jt]s)$") then return "webpack" end
  if name:match("^rollup%.config%.") then return "rollup" end
  if name:match("^vite%.config%.") then
    return name:match("%.([mc]?ts)$") and "typescript" or "javascript"
  end
  if normalized:find("/.github/workflows/", 1, true) and name:match("%.ya?ml$") then return "github" end

  for _, extension in ipairs(extension_order) do
    local suffix = "." .. extension
    if #name > #suffix and name:sub(-#suffix) == suffix then
      return EXTENSIONS[extension]
    end
  end
  return "default"
end

function file_icons.resolve(path, is_directory)
  if is_directory then return nil end
  return resolve_name(path)
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
