local common = require "core.common"
local core   = require "core"

---Functions to add and get syntax definitions.
---@class core.syntax
local syntax = {}

syntax.items = {}

syntax.plain_text_syntax = { name = "Plain Text", patterns = {}, symbols = {} }
syntax.min_content_confidence = 0.8

local language_aliases = {}
local language_cache = {}
local registry_generation = 0
local registry_listeners = setmetatable({}, { __mode = "k" })

local function notify_registry_changed(reason)
  registry_generation = registry_generation + 1
  language_cache = {}
  for id, callback in pairs(registry_listeners) do
    local ok, err = pcall(callback, registry_generation, reason)
    if not ok then
      core.log_quiet(
        "Syntax registry listener %s failed after %s change: %s",
        tostring(id), reason, tostring(err)
      )
    end
  end
end


---Checks whether the pattern / regex compiles correctly and matches something.
---A pattern / regex must not match an empty string.
---@param pattern_type "regex"|"pattern"
---@param pattern string
---@return boolean ok
---@return string? error
local function check_pattern(pattern_type, pattern)
  local ok, err, mstart, mend
  if pattern_type == "regex" then
    ok, err = regex.compile(pattern)
    if ok then
      mstart, mend = regex.find_offsets(ok, "")
      if mstart and mstart > mend then
        ok, err = false, "Regex matches an empty string"
      end
    end
  else
    ok, mstart, mend = pcall(string.ufind, "", pattern)
    if ok and mstart and mstart > mend then
      ok, err = false, "Pattern matches an empty string"
    elseif not ok then
      err = mstart --[[@as string]]
    end
  end
  return ok --[[@as boolean]], err
end

function syntax.add(t)
  if type(t.space_handling) ~= "boolean" then t.space_handling = true end

  if t.patterns then
    -- do a sanity check on the patterns / regex to make sure they are actually correct
    for i, pattern in ipairs(t.patterns) do
      local p, ok, err, name = pattern.pattern or pattern.regex, nil, nil, nil
      if type(p) == "table" then
        for j = 1, 2 do
          ok, err = check_pattern(pattern.pattern and "pattern" or "regex", p[j])
          if not ok then name = string.format("#%d:%d <%s>", i, j, p[j]) end
        end
      elseif type(p) == "string" then
        ok, err = check_pattern(pattern.pattern and "pattern" or "regex", p)
        if not ok then name = string.format("#%d <%s>", i, p) end
      else
        ok, err, name = false, "Missing pattern or regex", "#"..i
      end
      if not ok then
        pattern.disabled = true
        core.warn("Malformed pattern %s in %s language plugin: %s", name, t.name, err)
      end
    end

    -- the rule %s+ gives us a performance gain for the tokenizer in lines with
    -- long amounts of consecutive spaces, can be disabled by plugins where it
    -- causes conflicts by declaring the table property: space_handling = false
    if t.space_handling then
      table.insert(t.patterns, { pattern = "%s+", type = "normal" })
    end

    -- this rule gives us additional performance gain by matching every word
    -- that was not matched by the syntax patterns as a single token, preventing
    -- the tokenizer from iterating over each character individually which is a
    -- lot slower since iteration occurs in lua instead of C and adding to that
    -- it will also try to match every pattern to a single char (same as spaces)
    table.insert(t.patterns, { pattern = "%w+%f[%s]", type = "normal" })
  end

  table.insert(syntax.items, t)
  notify_registry_changed("syntax")
end


local function find_match(string, field)
  local best_match = 0
  local best_syntax
  for i = #syntax.items, 1, -1 do
    local t = syntax.items[i]
    local s, e = common.match_pattern(string, t[field] or {})
    if s and e - s > best_match then
      best_match = e - s
      best_syntax = t
    end
  end
  return best_syntax
end

---Finds a loaded syntax without substituting the plain-text fallback.
---@param filename? string
---@param header? string
---@return table? syntax_definition
function syntax.find(filename, header)
  return (filename and find_match(filename, "files"))
      or (header and find_match(header, "headers"))
end

function syntax.get(filename, header)
  return syntax.find(filename, header) or syntax.plain_text_syntax
end

---Finds one language from strong content evidence.
---Detectors return confidence from 0 to 1. The strongest unique result wins.
---@param text string
---@return table? syntax_definition
---@return number? confidence
function syntax.detect_content(text)
  local best, best_confidence, tied_with
  for _, item in ipairs(syntax.items) do
    local confidence
    local header_start = common.match_pattern(text, item.headers or {})
    if header_start then confidence = 1 end

    if item.detect_content then
      local ok, detected_confidence = pcall(item.detect_content, text)
      if not ok then
        core.log_quiet(
          "Content detector failed for %s: %s", tostring(item.name), tostring(detected_confidence)
        )
      elseif detected_confidence ~= nil then
        if type(detected_confidence) ~= "number"
            or detected_confidence ~= detected_confidence
            or detected_confidence < 0 or detected_confidence > 1 then
          core.log_quiet(
            "Content detector returned invalid confidence for %s: %s",
            tostring(item.name), tostring(detected_confidence)
          )
        else
          confidence = math.max(confidence or 0, detected_confidence)
        end
      end
    end

    if confidence and confidence >= syntax.min_content_confidence then
      if not best_confidence or confidence > best_confidence then
        best, best_confidence, tied_with = item, confidence, nil
      elseif confidence == best_confidence and item ~= best then
        tied_with = item
      end
    end
  end

  if tied_with then
    core.log_quiet(
      "Content detection tied at %.2f between %s and %s",
      best_confidence, tostring(best.name), tostring(tied_with.name)
    )
    return nil
  end
  return best, best_confidence
end


local function trim(text)
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function normalize_identifier(identifier)
  identifier = trim(identifier or ""):lower()
  identifier = identifier:gsub("^language%-", "", 1)
  identifier = identifier:gsub("^lang%-", "", 1)
  return identifier
end

local function normalize_syntax_name(name)
  return (name or ""):lower():gsub("[%W_]+", "")
end

---Returns the current loaded-syntax and language-alias registry generation.
---@return integer
function syntax.get_registry_generation()
  return registry_generation
end

---Registers a callback for loaded-syntax and language-alias changes.
---@param id any
---@param callback fun(generation:integer, reason:"syntax"|"alias")
function syntax.add_registry_listener(id, callback)
  assert(id ~= nil, "syntax registry listener id is required")
  assert(type(callback) == "function", "syntax registry listener callback is required")
  registry_listeners[id] = callback
end

---Removes a syntax-registry callback.
---@param id any
function syntax.remove_registry_listener(id)
  registry_listeners[id] = nil
end

---Registers a normalized language alias. Existing aliases win unless explicitly replaced.
---@param alias string
---@param canonical_id string
---@param options? { replace?:boolean }
---@return boolean changed
function syntax.add_language_alias(alias, canonical_id, options)
  alias = normalize_identifier(alias)
  canonical_id = normalize_identifier(canonical_id)
  assert(alias ~= "", "language alias must not be empty")
  assert(canonical_id ~= "", "canonical language id must not be empty")

  local existing = language_aliases[alias]
  if existing == canonical_id then
    return false
  end
  if existing and not (options and options.replace) then
    core.log_quiet(
      "Ignoring conflicting syntax language alias %s -> %s; already registered as %s",
      alias, canonical_id, existing
    )
    return false
  end

  language_aliases[alias] = canonical_id
  notify_registry_changed("alias")
  return true
end

---Resolves a language id or Markdown fence info string to a loaded syntax.
---Only the first whitespace-delimited word participates in resolution.
---@param info_or_id? string
---@param options? { source?:string }
---@return table? resolved
---@return { requested:string, normalized:string, canonical_id:string, reason:"alias"|"extension"|"syntax-name"|"missing"|"empty", source:string? } metadata
function syntax.resolve_language(info_or_id, options)
  local info = trim(tostring(info_or_id or ""))
  local requested = info:match("^(%S+)") or ""
  local normalized = normalize_identifier(requested)
  if normalized == "" then
    return nil, {
      requested = requested,
      normalized = "",
      canonical_id = "",
      reason = "empty",
      source = options and options.source
    }
  end

  local cached = language_cache[normalized]
  if cached and cached.generation == registry_generation then
    return cached.resolved, {
      requested = requested,
      normalized = normalized,
      canonical_id = cached.canonical_id,
      reason = cached.reason,
      source = options and options.source
    }
  end

  local canonical_id = language_aliases[normalized] or normalized
  local reason = language_aliases[normalized] and "alias" or nil
  local resolved = syntax.find("codeblock." .. canonical_id)
  if resolved and not reason then
    reason = "extension"
  end

  if not resolved then
    local wanted_name = normalize_syntax_name(canonical_id)
    for i = #syntax.items, 1, -1 do
      local item = syntax.items[i]
      if normalize_syntax_name(item.name) == wanted_name then
        resolved = item
        if not reason then reason = "syntax-name" end
        break
      end
    end
  end

  if not resolved then
    reason = "missing"
  end
  cached = {
    generation = registry_generation,
    resolved = resolved,
    canonical_id = canonical_id,
    reason = reason
  }
  language_cache[normalized] = cached

  return resolved, {
    requested = requested,
    normalized = normalized,
    canonical_id = canonical_id,
    reason = reason,
    source = options and options.source
  }
end


local default_language_aliases = {
  bash = "sh",
  ["c#"] = "cs",
  cc = "cpp",
  ["c++"] = "cpp",
  cxx = "cpp",
  h = "cpp",
  hpp = "cpp",
  javascript = "javascript",
  js = "javascript",
  mjs = "javascript",
  markdown = "markdown",
  md = "markdown",
  py = "python",
  python = "python",
  ts = "typescript",
  typescript = "typescript"
}

for alias, canonical_id in pairs(default_language_aliases) do
  syntax.add_language_alias(alias, canonical_id)
end


return syntax
