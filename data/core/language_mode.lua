local common = require "core.common"
local core = require "core"
local syntax = require "core.syntax"

local language_mode = {}

local path_overrides = {}
local DETECTION_DEBOUNCE_SECONDS = 0.2
local MIN_DETECTION_BYTES = 20
local SAMPLE_BLOCK_BYTES = 4096
local MIN_DETECTION_CONFIDENCE = 0.2
local MIN_DETECTION_CONFIDENCE_GAP = 0.2
local MIN_LANGUAGE_SWITCH_CONFIDENCE_GAP = 0.5

local model_language_ids = {
  asm = "asm", batch = "bat", c = "c", clojure = "clojure", cmake = "cmake",
  cobol = "cobol", cpp = "cpp", cs = "cs", css = "css", dart = "dart",
  dockerfile = "Dockerfile", elixir = "elixir", erlang = "erlang", gemfile = "ruby",
  gemspec = "ruby", go = "go", gradle = "groovy", groovy = "groovy", haskell = "hs",
  html = "html", ini = "ini", java = "java", javascript = "javascript", json = "json",
  julia = "julia", kotlin = "kotlin", lisp = "lisp", lua = "lua", markdown = "markdown",
  objectivec = "Objective-C", ocaml = "ocaml", perl = "perl", php = "php",
  powershell = "PowerShell", python = "python", r = "R", ruby = "ruby", rust = "rust",
  scala = "scala", shell = "sh", sql = "sql", swift = "swift", toml = "toml",
  typescript = "typescript", vba = "vba", verilog = "verilog", xml = "xml", yaml = "yaml",
}

local function normalized_path(path)
  if type(path) ~= "string" or path == "" then return nil end
  local ok, result = pcall(common.normalize_path, path)
  return ok and result or path
end

local function path_key(path)
  path = normalized_path(path)
  return path and common.path_compare_key(path) or nil
end

---Returns the normalized file path represented by a Buffer.
---@param buffer core.buffer
---@return string?
function language_mode.buffer_path(buffer)
  if not buffer then return nil end
  local path = buffer.abs_filename
  if not path and buffer.filename then
    local project = core.root_project and core.root_project()
    if project and project.path then path = project.path .. PATHSEP .. buffer.filename end
  end
  return normalized_path(path)
end

---Resolves a persisted/user-entered Language Mode name.
---@param mode string|false|nil
---@return table? syntax_definition
---@return string? canonical_name
---@return string? error
function language_mode.resolve(mode)
  if mode == nil or mode == false then return nil, nil end
  local requested = tostring(mode):gsub("^%s+", ""):gsub("%s+$", "")
  if requested == "" or requested:lower() == "automatic" then return nil, nil end
  if requested:lower():gsub("[%W_]", "") == "plaintext" then
    return syntax.plain_text_syntax, syntax.plain_text_syntax.name
  end
  local resolved = syntax.resolve_language(requested, { source = "language-mode" })
  if not resolved then return nil, nil, "Unknown Language Mode: " .. requested end
  return resolved, resolved.name
end

local function stored_override(path)
  local entry = path_overrides[path_key(path)]
  return entry and entry.mode or nil
end

---Returns the explicit mode for a Buffer, including its named-file Workspace association.
---@param buffer core.buffer
---@param path? string
---@return string?
function language_mode.override_for_buffer(buffer, path)
  if buffer.language_mode_override then return buffer.language_mode_override end
  local mode = stored_override(path or language_mode.buffer_path(buffer))
  if mode then buffer.language_mode_override = mode end
  return mode
end

local function set_path_override(path, mode)
  local key = path_key(path)
  if not key then return end
  if mode then
    path_overrides[key] = { path = normalized_path(path), mode = mode }
  else
    path_overrides[key] = nil
  end
end

---Moves a Buffer-owned override when its path changes, including untitled Save As.
---@param buffer core.buffer
---@param old_path? string
---@param new_path? string
function language_mode.on_buffer_path_changed(buffer, old_path, new_path)
  if buffer and new_path then language_mode.cancel_content_detection(buffer) end
  local mode = buffer and buffer.language_mode_override
  if not mode then return end
  if old_path and (not new_path or path_key(old_path) ~= path_key(new_path)) then
    set_path_override(old_path, nil)
  end
  if new_path then set_path_override(new_path, mode) end
end

---Sets or clears a Buffer's explicit Language Mode.
---@param buffer core.buffer
---@param mode string|false|nil
---@param opts? { persist?:boolean, reason?:string }
---@return boolean changed
---@return string? error
function language_mode.set_buffer_mode(buffer, mode, opts)
  opts = opts or {}
  local resolved, canonical_name, err = language_mode.resolve(mode)
  if err then return false, err end

  local old_mode = buffer.language_mode_override
  local changed = old_mode ~= canonical_name
  buffer.language_mode_override = canonical_name
  language_mode.cancel_content_detection(buffer)
  if opts.persist ~= false then
    set_path_override(language_mode.buffer_path(buffer), canonical_name)
  end

  local syntax_changed = buffer:reset_syntax({ reason = opts.reason or "language-mode" })
  core.log_quiet(
    "Language Mode: %s %s -> %s (syntax_changed=%s)",
    tostring(buffer.get_name and buffer:get_name() or buffer),
    tostring(old_mode or "Automatic"),
    tostring(canonical_name or "Automatic"),
    tostring(syntax_changed)
  )
  if not canonical_name then language_mode.request_content_detection(buffer) end
  return changed or syntax_changed, nil
end

---Sets or clears the sticky Language Mode inferred from Buffer content.
---@param buffer core.buffer
---@param mode string|nil
---@param opts? { reason?:string }
---@return boolean changed
---@return string? error
function language_mode.set_buffer_inference(buffer, mode, opts)
  opts = opts or {}
  local _, canonical_name, err = language_mode.resolve(mode)
  if err then return false, err end

  local old_mode = buffer.language_mode_inferred
  buffer.language_mode_inferred = canonical_name
  buffer.language_mode_inferred_slug = opts.slug
  local syntax_changed = buffer:reset_syntax({ reason = opts.reason or "language-mode-inference" })
  core.log_quiet(
    "Language Mode inference: %s %s -> %s (syntax_changed=%s)",
    tostring(buffer.get_name and buffer:get_name() or buffer),
    tostring(old_mode or "none"),
    tostring(canonical_name or "none"),
    tostring(syntax_changed)
  )
  return old_mode ~= canonical_name or syntax_changed
end

local function detection_eligible(buffer)
  return buffer and buffer.intellij_untitled and buffer.new_file and not buffer.filename
    and not buffer.binary and not buffer.language_mode_override
end

local function content_sample(buffer)
  local first, first_bytes = {}, 0
  for _, line in ipairs(buffer.lines or {}) do
    if first_bytes >= SAMPLE_BLOCK_BYTES then break end
    local take = line:sub(1, SAMPLE_BLOCK_BYTES - first_bytes)
    first[#first + 1], first_bytes = take, first_bytes + #take
  end
  local first_text = table.concat(first)
  if first_bytes < SAMPLE_BLOCK_BYTES then return first_text end

  local last, last_bytes = {}, 0
  for index = #(buffer.lines or {}), 1, -1 do
    if last_bytes >= SAMPLE_BLOCK_BYTES then break end
    local line = buffer.lines[index]
    local remaining = SAMPLE_BLOCK_BYTES - last_bytes
    local take = #line <= remaining and line or line:sub(#line - remaining + 1)
    table.insert(last, 1, take)
    last_bytes = last_bytes + #take
  end
  return first_text .. table.concat(last)
end

local function parse_scores(value)
  local scores = {}
  for slug, score in tostring(value or ""):gmatch("([%w_]+)%s+([%d%.eE%+%-]+)") do
    score = tonumber(score)
    if score then scores[#scores + 1] = { slug = slug, score = score } end
  end
  table.sort(scores, function(a, b)
    return a.score == b.score and a.slug < b.slug or a.score > b.score
  end)
  return scores
end

local function syntax_for_slug(slug)
  local id = model_language_ids[slug]
  return id and syntax.resolve_language(id, { source = "content-detection" }) or nil
end

local function detected_candidate(scores)
  local pending, confirmed = {}, {}
  for _, candidate in ipairs(scores) do
    local previous = pending[#pending]
    if previous and previous.score - candidate.score >= MIN_DETECTION_CONFIDENCE_GAP then
      for _, item in ipairs(pending) do confirmed[#confirmed + 1] = item end
      pending = {}
    end
    if candidate.score < MIN_DETECTION_CONFIDENCE then break end
    pending[#pending + 1] = candidate
  end
  for _, candidate in ipairs(confirmed) do
    local detected = syntax_for_slug(candidate.slug)
    if detected then return detected, candidate end
  end
end

local function current_inference_score(buffer, scores)
  if not buffer.language_mode_inferred then return nil end
  for _, candidate in ipairs(scores) do
    if candidate.slug == buffer.language_mode_inferred_slug then return candidate.score end
    local candidate_syntax = syntax_for_slug(candidate.slug)
    if candidate_syntax and candidate_syntax.name == buffer.language_mode_inferred then
      return candidate.score
    end
  end
end

local function apply_detection(buffer, generation, revision, value)
  if buffer.language_detection_generation ~= generation
      or buffer.text_revision ~= revision or not detection_eligible(buffer) then
    return
  end
  local scores = parse_scores(value)
  local detected, candidate = detected_candidate(scores)
  if not detected or not candidate then return end
  if detected.name == buffer.language_mode_inferred then
    buffer.language_mode_inferred_slug = candidate.slug
    return
  end
  local current_score = current_inference_score(buffer, scores)
  if current_score and candidate.score <= current_score + MIN_LANGUAGE_SWITCH_CONFIDENCE_GAP then
    return
  end
  local changed = language_mode.set_buffer_inference(buffer, detected.name, {
    reason = "content-detection",
    slug = candidate.slug,
  })
  core.log_quiet(
    "Language Mode content detection: %s result=%s confidence=%.3f",
    buffer:get_name(), detected.name, candidate.score
  )
  if changed then
    local ok, recovery = pcall(require, "plugins.untitled_recovery")
    if ok and recovery.update_buffer_metadata then
      recovery.update_buffer_metadata(buffer, "Language Mode inference")
    end
  end
end

---Cancels a pending content-based Language Mode request.
---@param buffer core.buffer
function language_mode.cancel_content_detection(buffer)
  if not buffer then return end
  buffer.language_detection_generation = (buffer.language_detection_generation or 0) + 1
  local handle = buffer.language_detection_handle
  buffer.language_detection_handle = nil
  if handle then
    local pool = require("core.worker_pool").current_system()
    if pool then pool:cancel(handle) end
  end
end

---Requests content-based Language Mode detection for an Automatic Untitled Buffer.
---@param buffer core.buffer
---@return boolean scheduled
function language_mode.request_content_detection(buffer)
  language_mode.cancel_content_detection(buffer)
  if not detection_eligible(buffer) then return false end
  local sample = content_sample(buffer)
  if #sample < MIN_DETECTION_BYTES then return false end
  local generation = buffer.language_detection_generation
  local revision = buffer.text_revision
  core.add_thread(function()
    coroutine.yield(DETECTION_DEBOUNCE_SECONDS)
    if buffer.language_detection_generation ~= generation
        or buffer.text_revision ~= revision or not detection_eligible(buffer) then
      return
    end
    local pool = require("core.worker_pool").system()
    local handle, err = pool:submit {
      kind = "language-detection",
      native = true,
      native_kind = "language_detect",
      priority = "interactive",
      generation = generation,
      native_payload = {
        path = DATADIR .. PATHSEP .. "models" .. PATHSEP .. "betlang-source-student-q4.bin",
        text = sample,
      },
      is_stale = function()
        return buffer.language_detection_generation ~= generation
          or buffer.text_revision ~= revision or not detection_eligible(buffer)
      end,
      on_result = function(message)
        apply_detection(buffer, generation, revision, message.value)
      end,
      on_error = function(message)
        core.log_quiet("Language Mode content detection failed for %s: %s",
          buffer:get_name(), tostring(message.error))
      end,
    }
    if not handle then
      core.log_quiet("Language Mode content detection submission failed for %s: %s",
        buffer:get_name(), tostring(err))
      return
    end
    buffer.language_detection_handle = handle
  end)
  return true
end

function language_mode.on_text_transaction(buffer, transaction)
  if transaction and transaction.changed
      and (detection_eligible(buffer) or buffer.language_detection_handle) then
    language_mode.request_content_detection(buffer)
  end
end

---Returns picker-ready Language Mode choices.
---@return table[] choices
function language_mode.choices()
  local choices = {
    { text = "Automatic", automatic = true, info = "Detect from file name or content" },
    { text = syntax.plain_text_syntax.name, mode = syntax.plain_text_syntax.name },
  }
  local names = {}
  for _, item in ipairs(syntax.items) do
    if item.name and item.name ~= syntax.plain_text_syntax.name then names[item.name] = true end
  end
  local sorted = {}
  for name in pairs(names) do sorted[#sorted + 1] = name end
  table.sort(sorted, function(a, b) return a:lower() < b:lower() end)
  for _, name in ipairs(sorted) do choices[#choices + 1] = { text = name, mode = name } end
  return choices
end

---Finds an exact choice by its displayed name.
---@param text string
---@return table?
function language_mode.find_choice(text)
  local wanted = tostring(text or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  for _, item in ipairs(language_mode.choices()) do
    if item.text:lower() == wanted then return item end
  end
end

---Loads the named-file associations belonging to the current Project Workspace.
---@param state? { entries?:table[] }
function language_mode.load_workspace_state(state)
  path_overrides = {}
  local entries = type(state) == "table" and type(state.entries) == "table" and state.entries or {}
  local loaded = 0
  for _, entry in ipairs(entries) do
    if type(entry) == "table" and type(entry.path) == "string" and type(entry.mode) == "string" then
      set_path_override(entry.path, entry.mode)
      loaded = loaded + 1
    end
  end
  core.log_quiet("Language Mode: loaded %d Project Workspace override(s)", loaded)
end

---Serializes the current Project's named-file associations.
---@return { entries:table[] }
function language_mode.save_workspace_state()
  local entries = {}
  for _, entry in pairs(path_overrides) do
    entries[#entries + 1] = { path = entry.path, mode = entry.mode }
  end
  table.sort(entries, function(a, b) return path_key(a.path) < path_key(b.path) end)
  return { entries = entries }
end

syntax.add_registry_listener(language_mode, function()
  for _, buffer in ipairs(core.buffers or {}) do
    if buffer.language_mode_override and buffer.reset_syntax then
      buffer:reset_syntax({ reason = "language-mode-registry-change" })
    end
  end
end)

return language_mode
