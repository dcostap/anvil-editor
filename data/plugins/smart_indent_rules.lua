-- mod-version:3 priority:1
local core = require "core"
local intelligence = require "core.language_intelligence"

local smart_indent = {}

local brace_indent_after = { "%{%s*$", "%(%s*$", "%[%s*$" }
local brace_outdent_before = { "^%s*%}", "^%s*%)", "^%s*%]" }
local trailing_operator_continuation = {
  "[%+%-%*/%%=<>!&|,%?:%.]$",
}

local function list(...)
  return { ... }
end

local rules = {
  javascript = {
    extensions = list("js", "mjs", "cjs"),
    line_comment = "//",
    block_comment = { "/*", "*/" },
    indent_after = brace_indent_after,
    outdent_before = brace_outdent_before,
    continuation = trailing_operator_continuation,
  },
  typescript = {
    extensions = list("ts", "mts", "cts"),
    line_comment = "//",
    block_comment = { "/*", "*/" },
    indent_after = brace_indent_after,
    outdent_before = brace_outdent_before,
    continuation = trailing_operator_continuation,
  },
  jsx = {
    extensions = list("jsx"),
    line_comment = "//",
    block_comment = { "/*", "*/" },
    indent_after = brace_indent_after,
    outdent_before = brace_outdent_before,
    continuation = trailing_operator_continuation,
  },
  tsx = {
    extensions = list("tsx"),
    line_comment = "//",
    block_comment = { "/*", "*/" },
    indent_after = brace_indent_after,
    outdent_before = brace_outdent_before,
    continuation = trailing_operator_continuation,
  },
  python = {
    extensions = list("py", "pyw", "pyi"),
    line_comment = "#",
    indent_after = { ":$" },
    continuation = trailing_operator_continuation,
  },
  java = {
    extensions = list("java"),
    line_comment = "//",
    block_comment = { "/*", "*/" },
    indent_after = brace_indent_after,
    outdent_before = brace_outdent_before,
  },
  c = {
    extensions = list("c", "h"),
    line_comment = "//",
    block_comment = { "/*", "*/" },
    indent_after = brace_indent_after,
    outdent_before = brace_outdent_before,
    case_patterns = list("^%s*case%s+", "^%s*default%s*:"),
  },
  cpp = {
    extensions = list("cc", "cpp", "cxx", "c++", "hh", "hpp", "hxx", "h++"),
    line_comment = "//",
    block_comment = { "/*", "*/" },
    indent_after = brace_indent_after,
    outdent_before = brace_outdent_before,
    case_patterns = list("^%s*case%s+", "^%s*default%s*:"),
  },
  csharp = {
    extensions = list("cs", "csx"),
    line_comment = "//",
    block_comment = { "/*", "*/" },
    indent_after = brace_indent_after,
    outdent_before = brace_outdent_before,
  },
  go = {
    extensions = list("go"),
    line_comment = "//",
    block_comment = { "/*", "*/" },
    indent_after = brace_indent_after,
    outdent_before = brace_outdent_before,
    case_patterns = list("^%s*case%s+", "^%s*default%s*:"),
  },
  rust = {
    extensions = list("rs"),
    line_comment = "//",
    block_comment = { "/*", "*/" },
    indent_after = brace_indent_after,
    outdent_before = brace_outdent_before,
  },
  php = {
    extensions = list("php", "phtml"),
    line_comment = "//",
    block_comment = { "/*", "*/" },
    indent_after = brace_indent_after,
    outdent_before = brace_outdent_before,
  },
  ruby = {
    extensions = list("rb", "rake"),
    filenames = list("Rakefile", "Gemfile"),
    line_comment = "#",
    indent_after = list("%f[%w]do%s*$", "%f[%w]then%s*$", "^%s*class%s+", "^%s*module%s+", "^%s*def%s+", "^%s*if%s+", "^%s*unless%s+", "^%s*case%s+", "^%s*begin%s*$"),
    outdent_before = list("^%s*end%f[%W]", "^%s*else%f[%W]", "^%s*elsif%f[%W]", "^%s*rescue%f[%W]", "^%s*ensure%f[%W]", "^%s*when%f[%W]"),
  },
  lua = {
    extensions = list("lua"),
    line_comment = "--",
    block_comment = { "--[[", "]]" },
    indent_after = list("%f[%w]then%s*$", "%f[%w]do%s*$", "%f[%w]function%s*[%w_%.:]*%s*%b()%s*$", "^%s*local%s+function%s+", "^%s*function%s+", "^%s*repeat%s*$", "^%s*else%s*$"),
    outdent_before = list("^%s*end%f[%W]", "^%s*until%f[%W]", "^%s*else%f[%W]", "^%s*elseif%f[%W]"),
  },
  shell = {
    extensions = list("sh", "bash", "zsh", "fish", "ksh"),
    filenames = list(".bashrc", ".zshrc", ".profile"),
    line_comment = "#",
    indent_after = list("%f[%w]then%s*$", "%f[%w]do%s*$", "%f[%w]case%s+.*%f[%w]in%s*$", "[%{%(%[]%s*$"),
    outdent_before = list("^%s*fi%f[%W]", "^%s*done%f[%W]", "^%s*esac%f[%W]"),
  },
  powershell = {
    extensions = list("ps1", "psm1", "psd1"),
    line_comment = "#",
    block_comment = { "<#", "#>" },
    indent_after = brace_indent_after,
    outdent_before = brace_outdent_before,
  },
  kotlin = { extensions = list("kt", "kts"), line_comment = "//", block_comment = { "/*", "*/" }, indent_after = brace_indent_after, outdent_before = brace_outdent_before },
  swift = { extensions = list("swift"), line_comment = "//", block_comment = { "/*", "*/" }, indent_after = brace_indent_after, outdent_before = brace_outdent_before },
  objective_c = { extensions = list("m", "mm"), line_comment = "//", block_comment = { "/*", "*/" }, indent_after = brace_indent_after, outdent_before = brace_outdent_before },
  scala = { extensions = list("scala", "sc"), line_comment = "//", block_comment = { "/*", "*/" }, indent_after = brace_indent_after, outdent_before = brace_outdent_before },
  dart = { extensions = list("dart"), line_comment = "//", block_comment = { "/*", "*/" }, indent_after = brace_indent_after, outdent_before = brace_outdent_before },
  r = { extensions = list("r", "R"), line_comment = "#", indent_after = brace_indent_after, outdent_before = brace_outdent_before },
  julia = { extensions = list("jl"), line_comment = "#", indent_after = list("%f[%w]function%s+", "%f[%w]do%s*$", "%f[%w]then%s*$", "^%s*if%s+", "^%s*for%s+", "^%s*while%s+", "^%s*begin%s*$", "^%s*let%s+"), outdent_before = list("^%s*end%f[%W]", "^%s*else%f[%W]", "^%s*elseif%f[%W]") },
  perl = { extensions = list("pl", "pm", "t"), line_comment = "#", indent_after = brace_indent_after, outdent_before = brace_outdent_before },
  groovy = { extensions = list("groovy", "gradle"), line_comment = "//", block_comment = { "/*", "*/" }, indent_after = brace_indent_after, outdent_before = brace_outdent_before },
  haskell = { extensions = list("hs", "lhs"), line_comment = "--", block_comment = { "{-", "-}" }, indent_after = list("%f[%w]where%s*$", "%f[%w]do%s*$", "%f[%w]of%s*$", "%f[%w]let%s*$"), outdent_before = list() },
  ocaml = { extensions = list("ml", "mli"), block_comment = { "(*", "*)" }, indent_after = list("%f[%w]then%s*$", "%f[%w]do%s*$", "%f[%w]struct%s*$", "%f[%w]sig%s*$", "%f[%w]begin%s*$"), outdent_before = list("^%s*end%f[%W]") },
  elixir = { extensions = list("ex", "exs"), line_comment = "#", indent_after = list("%f[%w]do%s*$", "^%s*def%s+", "^%s*defmodule%s+", "^%s*if%s+", "^%s*case%s+"), outdent_before = list("^%s*end%f[%W]", "^%s*else%f[%W]", "^%s*rescue%f[%W]") },
  erlang = { extensions = list("erl", "hrl"), line_comment = "%", indent_after = list("%-%>%s*$", "[%(%[%{]%s*$"), outdent_before = brace_outdent_before },
  clojure = { extensions = list("clj", "cljs", "cljc", "edn"), line_comment = ";;", indent_after = list("[%(%[%{]%s*$"), outdent_before = brace_outdent_before },
  fsharp = { extensions = list("fs", "fsi", "fsx"), line_comment = "//", block_comment = { "(*", "*)" }, indent_after = list("%f[%w]then%s*$", "%f[%w]do%s*$", "%-%>%s*$", "=%s*$"), outdent_before = list() },
  sql = { extensions = list("sql"), line_comment = "--", block_comment = { "/*", "*/" }, indent_after = list("%f[%w][Bb][Ee][Gg][Ii][Nn]%s*$", "%(%s*$"), outdent_before = list("^%s*[Ee][Nn][Dd]%f[%W]") },
  html = { extensions = list("html", "htm"), block_comment = { "<!--", "-->" }, indent_after = list("<[%w:_-][^>/]*>%s*$"), outdent_before = list("^%s*</") },
  css = { extensions = list("css"), block_comment = { "/*", "*/" }, indent_after = brace_indent_after, outdent_before = brace_outdent_before },
  scss = { extensions = list("scss", "sass"), line_comment = "//", block_comment = { "/*", "*/" }, indent_after = brace_indent_after, outdent_before = brace_outdent_before },
  less = { extensions = list("less"), line_comment = "//", block_comment = { "/*", "*/" }, indent_after = brace_indent_after, outdent_before = brace_outdent_before },
  json = { extensions = list("json"), indent_after = brace_indent_after, outdent_before = brace_outdent_before },
  jsonc = { extensions = list("jsonc", "json5"), line_comment = "//", block_comment = { "/*", "*/" }, indent_after = brace_indent_after, outdent_before = brace_outdent_before },
  yaml = { extensions = list("yaml", "yml"), line_comment = "#", indent_after = list(":%s*$", "^%s*%-%s+.*:%s*$"), outdent_before = list() },
  toml = { extensions = list("toml"), line_comment = "#", indent_after = brace_indent_after, outdent_before = brace_outdent_before },
  xml = { extensions = list("xml", "xsd", "xsl", "svg"), block_comment = { "<!--", "-->" }, indent_after = list("<[%w:_-][^>/]*>%s*$"), outdent_before = list("^%s*</") },
  markdown = { extensions = list("md", "markdown", "mdown"), line_comment = nil, indent_after = list("^%s*[%-%*%+]%s+.*:%s*$", "^%s*>%s+.*:%s*$"), outdent_before = list() },
  dockerfile = { filenames = list("Dockerfile", "Containerfile"), extensions = list("dockerfile"), line_comment = "#", indent_after = list("\\%s*$"), outdent_before = list() },
  makefile = { filenames = list("Makefile", "makefile", "GNUmakefile"), extensions = list("mk", "make"), line_comment = "#", indent_after = list(":%s*$"), outdent_before = list() },
  cmake = { extensions = list("cmake"), filenames = list("CMakeLists.txt"), line_comment = "#", indent_after = list("%f[%w]function%s*%b()%s*$", "%f[%w]macro%s*%b()%s*$", "%f[%w]if%s*%b()%s*$", "%f[%w]foreach%s*%b()%s*$", "%f[%w]while%s*%b()%s*$"), outdent_before = list("^%s*endfunction%f[%W]", "^%s*endmacro%f[%W]", "^%s*endif%f[%W]", "^%s*endforeach%f[%W]", "^%s*endwhile%f[%W]") },
  nix = { extensions = list("nix"), line_comment = "#", block_comment = { "/*", "*/" }, indent_after = brace_indent_after, outdent_before = brace_outdent_before },
  terraform = { extensions = list("tf", "tfvars", "hcl"), line_comment = "#", block_comment = { "/*", "*/" }, indent_after = brace_indent_after, outdent_before = brace_outdent_before },
  vue = { extensions = list("vue"), block_comment = { "<!--", "-->" }, indent_after = list("<[%w:_-][^>/]*>%s*$", "%{%s*$"), outdent_before = list("^%s*</", "^%s*%}") },
  svelte = { extensions = list("svelte"), block_comment = { "<!--", "-->" }, indent_after = list("<[%w:_-][^>/]*>%s*$", "%{%s*$"), outdent_before = list("^%s*</", "^%s*%}") },
  zig = { extensions = list("zig"), line_comment = "//", indent_after = brace_indent_after, outdent_before = brace_outdent_before },
  odin = { extensions = list("odin"), line_comment = "//", block_comment = { "/*", "*/" }, indent_after = brace_indent_after, outdent_before = brace_outdent_before },
}

smart_indent.rules = rules
smart_indent.supported_fields = {
  extensions = true,
  filenames = true,
  line_comment = true,
  block_comment = false, -- prefilled for upcoming comment-continuation/outdent work
  indent_after = true,
  continuation = true,
  outdent_before = false, -- prefilled for upcoming current-line outdent work
  case_patterns = false, -- prefilled for upcoming switch/case handling
}

local function lower_set(items)
  local set = {}
  for _, item in ipairs(items or {}) do set[tostring(item):lower()] = true end
  return set
end

local extension_to_rule = {}
local filename_to_rule = {}
for id, rule in pairs(rules) do
  rule.id = rule.id or id
  rule.extension_set = lower_set(rule.extensions)
  rule.filename_set = lower_set(rule.filenames)
  for ext in pairs(rule.extension_set) do extension_to_rule[ext] = rule end
  for filename in pairs(rule.filename_set) do filename_to_rule[filename] = rule end
end

local function basename(path)
  return tostring(path or ""):gsub("\\", "/"):match("([^/]+)$") or tostring(path or "")
end

local function extension(name)
  return tostring(name or ""):match("%.([^%.]+)$")
end

function smart_indent.rule_for_doc(doc)
  local name = basename(doc and (doc.filename or doc.abs_filename or doc:get_name()) or "")
  local lower_name = name:lower()
  local by_name = filename_to_rule[lower_name]
  if by_name then return by_name end
  local ext = extension(lower_name)
  return ext and extension_to_rule[ext] or nil
end

local function trim_right(text)
  return tostring(text or ""):gsub("[%s\r\n]+$", "")
end

local function line_comment_start(text, marker)
  text = tostring(text or "")
  if type(marker) ~= "string" or marker == "" then return nil end
  local escaped = false
  local quote
  local i = 1
  while i <= #text do
    local ch = text:sub(i, i)
    if escaped then
      escaped = false
    elseif ch == "\\" then
      escaped = true
    elseif quote then
      if ch == quote then quote = nil end
    elseif ch == '"' or ch == "'" then
      quote = ch
    elseif text:sub(i, i + #marker - 1) == marker then
      return i
    end
    i = i + 1
  end
end

local function code_before_line_comment(text, rule)
  local marker = rule and rule.line_comment
  local start = line_comment_start(text, marker)
  if not start then return text end
  return text:sub(1, start - 1)
end

local function has_unclosed_quote(text, quote)
  local escaped = false
  local open = false
  for i = 1, #text do
    local ch = text:sub(i, i)
    if escaped then
      escaped = false
    elseif ch == "\\" then
      escaped = true
    elseif ch == quote then
      open = not open
    end
  end
  return open
end

local function likely_inside_string(text)
  return has_unclosed_quote(text, '"') or has_unclosed_quote(text, "'")
end

local function matches_any(text, patterns)
  for _, pattern in ipairs(patterns or {}) do
    if text:match(pattern) then return true, pattern end
  end
  return false
end

local function one_indent(doc)
  local text = doc:get_indent_string(1)
  return text
end

function smart_indent.newline_continuation(doc, line, context)
  local rule = smart_indent.rule_for_doc(doc)
  if not rule then return nil, "no-rule", "unavailable" end
  context = context or {}
  local before = tostring(context.before_text or ""):gsub("[\r\n]+$", "")
  if before == "" then return nil, "blank-before", "unavailable" end
  if before:match("^%s*#!") then return nil, "shebang", "unavailable" end

  if rule.id == "markdown" then
    if matches_any(before, rule.indent_after) then return nil, "indent-after", "unavailable" end
    local indent, bullet = before:match("^(%s*)([%-%*%+])%s+%S")
    if indent then return indent .. bullet .. " ", nil, "fresh" end
    local ordered_indent, number = before:match("^(%s*)(%d+)%.%s+%S")
    if ordered_indent and number then return ordered_indent .. tostring(tonumber(number) + 1) .. ". ", nil, "fresh" end
    local quote_indent = before:match("^(%s*>%s*)%S")
    if quote_indent then return quote_indent, nil, "fresh" end
  end

  local marker = rule.line_comment
  if type(marker) == "string" and marker ~= "" then
    local escaped = marker:gsub("([^%w])", "%%%1")
    local indent, body = before:match("^(%s*)" .. escaped .. "%s*(.*%S)")
    if indent and body then return indent .. marker .. " ", nil, "fresh" end
  end

  return nil, "no-continuation", "unavailable"
end

function smart_indent.indent_for_line(doc, line, context)
  local rule = smart_indent.rule_for_doc(doc)
  if not rule then return nil, "no-rule", "unavailable" end
  context = context or {}
  if context.event ~= "newline" and context.event ~= "line" then return nil, "unsupported-context", "unavailable" end

  local source_text = context.before_text or context.previous_line_text or ""
  if context.event == "line" and source_text == "" and line and line > 1 then
    source_text = doc.lines[line - 1] or ""
  end

  local before = trim_right(code_before_line_comment(source_text, rule))
  if before == "" then return nil, "blank-before", "unavailable" end
  if likely_inside_string(before) then return nil, "inside-string", "unavailable" end

  local base_indent = context.base_indent or before:match("^[\t ]*") or ""
  local ok, pattern = matches_any(before, rule.indent_after)
  if ok then
    if core.log_quiet then
      core.log_quiet("Smart indent: %s matched %s for %s", rule.id, tostring(pattern), doc:get_name())
    end
    return base_indent .. one_indent(doc), nil, "fresh"
  end

  local continued = matches_any(before, rule.continuation)
  if continued then return base_indent .. one_indent(doc), nil, "fresh" end
  return nil, "no-match", "unavailable"
end

intelligence.register_provider({
  id = "smart-indent-rules",
  kind = "syntactic-current-document",
  priority = 20,
  indent_for_line = smart_indent.indent_for_line,
  newline_continuation = smart_indent.newline_continuation,
  is_available = function(doc, feature)
    return (feature == "indent_for_line" or feature == "newline_continuation")
      and smart_indent.rule_for_doc(doc) ~= nil
  end,
})

return smart_indent
