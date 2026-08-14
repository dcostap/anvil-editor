local common = require "core.common"
local core = require "core"
local syntax = require "core.syntax"

local language_mode = {}

local path_overrides = {}

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
  return changed or syntax_changed, nil
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
